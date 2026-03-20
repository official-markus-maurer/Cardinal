//! Vulkan device-loss recovery.
//!
//! Attempts to tear down and recreate Vulkan objects after a `VK_ERROR_DEVICE_LOST`, restoring
//! pipelines and (when available) reloading the currently bound scene.
const std = @import("std");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");

const c = @import("vulkan_c.zig").c;

const frame_log = log.ScopedLogger("RENDER_FRAME");

const vk_instance = @import("vulkan_instance.zig");
const vk_swapchain = @import("vulkan_swapchain.zig");
const vk_pipeline = @import("vulkan_pipeline.zig");
const vk_commands = @import("vulkan_commands.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const vk_mesh_shader = @import("vulkan_mesh_shader.zig");
const vk_simple_pipelines = @import("vulkan_simple_pipelines.zig");
const vk_post_process = @import("vulkan_post_process.zig");
const vk_renderer = @import("vulkan_renderer.zig");

const FailurePoint = enum {
    device,
    swapchain,
    pipeline,
    commands_sync,
    simple_pipelines,
    post_process_pipeline,
    pbr_pipeline,
    pbr_scene_reload,
    mesh_shader_paths,
    mesh_shader_pipeline,
};

fn failurePointName(point: FailurePoint) []const u8 {
    return switch (point) {
        .device => "device",
        .swapchain => "swapchain",
        .pipeline => "pipeline",
        .commands_sync => "commands sync",
        .simple_pipelines => "simple pipelines",
        .post_process_pipeline => "post process pipeline",
        .pbr_pipeline => "PBR pipeline",
        .pbr_scene_reload => "PBR scene reload",
        .mesh_shader_paths => "mesh shader paths",
        .mesh_shader_pipeline => "mesh shader pipeline",
    };
}

/// Performs a best-effort recovery sequence, returning true when the renderer is usable again.
pub fn recover_from_device_loss(s: *types.VulkanState) bool {
    if (s.recovery.recovery_in_progress) {
        return false;
    }

    if (s.recovery.attempt_count >= s.recovery.max_attempts) {
        frame_log.err("[RECOVERY] Maximum device loss recovery attempts ({d}) exceeded", .{s.recovery.max_attempts});
        s.recovery.recovery_in_progress = false;
        if (s.recovery.recovery_complete_callback) |callback| {
            callback(s.recovery.callback_user_data, false);
        }
        return false;
    }

    s.recovery.recovery_in_progress = true;
    s.recovery.attempt_count += 1;

    frame_log.warn("[RECOVERY] Attempting device loss recovery (attempt {d}/{d})", .{ s.recovery.attempt_count, s.recovery.max_attempts });

    if (s.recovery.device_loss_callback) |callback| {
        callback(s.recovery.callback_user_data);
    }

    var device_status: c.VkResult = c.VK_SUCCESS;
    if (s.context.device != null) {
        device_status = c.vkDeviceWaitIdle(s.context.device);
        if (device_status == c.VK_ERROR_DEVICE_LOST) {
            frame_log.warn("[RECOVERY] Device confirmed lost, proceeding with recovery", .{});
        } else if (device_status != c.VK_SUCCESS) {
            frame_log.err("[RECOVERY] Unexpected device error during recovery validation: {d}", .{device_status});
            s.recovery.recovery_in_progress = false;
            return false;
        }
    }

    const stored_scene = s.current_scene;

    vk_renderer.destroy_scene_buffers(s);

    if (s.pipelines.use_pbr_pipeline) {
        vk_pbr.vk_pbr_pipeline_destroy(&s.pipelines.pbr_pipeline, s.context.device, &s.allocator);
        s.pipelines.use_pbr_pipeline = false;
    }
    if (s.pipelines.use_mesh_shader_pipeline) {
        if (s.context.device != null) {
            _ = c.vkDeviceWaitIdle(s.context.device);
        }
        vk_mesh_shader.vk_mesh_shader_destroy_pipeline(s, &s.pipelines.mesh_shader_pipeline);
        s.pipelines.use_mesh_shader_pipeline = false;
    }
    vk_simple_pipelines.vk_destroy_simple_pipelines(s);
    vk_post_process.vk_post_process_destroy(s);
    vk_pipeline.vk_destroy_pipeline(s);

    vk_commands.vk_destroy_commands_sync(@ptrCast(s));

    vk_swapchain.vk_destroy_swapchain(s);

    var success = true;
    var failure_point: ?FailurePoint = null;

    if (!vk_instance.vk_create_device(@ptrCast(s))) {
        failure_point = .device;
        success = false;
    }

    if (success and !vk_swapchain.vk_create_swapchain(s)) {
        failure_point = .swapchain;
        success = false;
    }

    if (success and !vk_pipeline.vk_create_pipeline(s)) {
        failure_point = .pipeline;
        success = false;
    }

    if (success and !vk_commands.vk_create_commands_sync(@ptrCast(s))) {
        failure_point = .commands_sync;
        success = false;
    }

    if (success and !vk_simple_pipelines.vk_create_simple_pipelines(s, null)) {
        failure_point = .simple_pipelines;
        success = false;
    }

    if (success and !vk_post_process.vk_post_process_init(s)) {
        failure_point = .post_process_pipeline;
        success = false;
    }

    if (success and stored_scene != null) {
        if (!vk_pbr.vk_pbr_pipeline_create(&s.pipelines.pbr_pipeline, s.context.device, s.context.physical_device, s.swapchain.format, s.swapchain.depth_format, s.commands.pools.?[0], s.context.graphics_queue, &s.allocator, s, s.pipelines.pipeline_cache)) {
            failure_point = .pbr_pipeline;
            success = false;
        } else {
            s.pipelines.use_pbr_pipeline = true;

            if (!vk_pbr.vk_pbr_load_scene(&s.pipelines.pbr_pipeline, s.context.device, s.context.physical_device, s.commands.pools.?[0], s.context.graphics_queue, stored_scene, &s.allocator, s)) {
                failure_point = .pbr_scene_reload;
                success = false;
            }
        }
    }

    if (success and s.context.supports_mesh_shader) {
        var config = std.mem.zeroes(types.MeshShaderPipelineConfig);
        var shaders_dir: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(&s.config.shader_dir)));
        const env_dir_c = c.getenv("CARDINAL_SHADERS_DIR");
        if (env_dir_c != null) {
            shaders_dir = std.mem.span(env_dir_c);
        }

        var task_path: [512]u8 = undefined;
        var mesh_path: [512]u8 = undefined;
        var frag_path: [512]u8 = undefined;

        _ = std.fmt.bufPrintZ(&task_path, "{s}/task.task.spv", .{shaders_dir}) catch |err| {
            frame_log.err("Failed to format task shader path: {s}", .{@errorName(err)});
            failure_point = .mesh_shader_paths;
            success = false;
        };
        _ = std.fmt.bufPrintZ(&mesh_path, "{s}/mesh.mesh.spv", .{shaders_dir}) catch |err| {
            frame_log.err("Failed to format mesh shader path: {s}", .{@errorName(err)});
            failure_point = .mesh_shader_paths;
            success = false;
        };
        _ = std.fmt.bufPrintZ(&frag_path, "{s}/mesh.frag.spv", .{shaders_dir}) catch |err| {
            frame_log.err("Failed to format fragment shader path: {s}", .{@errorName(err)});
            failure_point = .mesh_shader_paths;
            success = false;
        };

        config.task_shader_path = @ptrCast(&task_path);
        config.mesh_shader_path = @ptrCast(&mesh_path);
        config.fragment_shader_path = @ptrCast(&frag_path);
        config.max_vertices_per_meshlet = 64;
        config.max_primitives_per_meshlet = 126;
        config.cull_mode = c.VK_CULL_MODE_BACK_BIT;
        config.front_face = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        config.polygon_mode = c.VK_POLYGON_MODE_FILL;
        config.blend_enable = false;
        config.depth_test_enable = true;
        config.depth_write_enable = true;
        config.depth_compare_op = c.VK_COMPARE_OP_LESS;

        if (!vk_mesh_shader.vk_mesh_shader_create_pipeline(s, &config, s.swapchain.format, s.swapchain.depth_format, &s.pipelines.mesh_shader_pipeline, null)) {
            frame_log.err("Failed to initialize mesh shader pipeline", .{});
            failure_point = .mesh_shader_pipeline;
            success = false;
        } else {
            s.pipelines.use_mesh_shader_pipeline = true;
        }
    }

    if (success and !vk_commands.vk_create_commands_sync(s)) {
        failure_point = .commands_sync;
        success = false;
    }

    if (success and stored_scene != null) {
        s.current_scene = stored_scene;
    }

    if (success) {
        frame_log.info("[RECOVERY] Device loss recovery completed successfully", .{});
        s.recovery.device_lost = false;
        s.recovery.attempt_count = 0;
    } else {
        const fp_str = if (failure_point) |fp| failurePointName(fp) else "unknown";
        frame_log.err("[RECOVERY] Device loss recovery failed at: {s}", .{fp_str});
    }

    s.recovery.recovery_in_progress = false;

    if (s.recovery.recovery_complete_callback) |callback| {
        callback(s.recovery.callback_user_data, success);
    }

    return success;
}
