const std = @import("std");
const log = @import("../core/log.zig");
const tracy = @import("../core/tracy.zig");
const builtin = @import("builtin");
const types = @import("vulkan_types.zig");

const c = @import("vulkan_c.zig").c;

const frame_log = log.ScopedLogger("RENDER_FRAME");

const vk_instance = @import("vulkan_instance.zig");
const vk_swapchain = @import("vulkan_swapchain.zig");
const vk_pipeline = @import("vulkan_pipeline.zig");
const vk_commands = @import("vulkan_commands.zig");
const vk_sync_manager = @import("vulkan_sync_manager.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const vk_mesh_shader = @import("vulkan_mesh_shader.zig");
const vk_simple_pipelines = @import("vulkan_simple_pipelines.zig");
const vk_post_process = @import("vulkan_post_process.zig");
const vk_renderer = @import("vulkan_renderer.zig");
const vk_texture_manager = @import("vulkan_texture_manager.zig");
const vk_buffer_utils = @import("util/vulkan_buffer_utils.zig");
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const window = @import("../core/window.zig");

// Helper to get time in ms
fn cardinal_now_ms() u64 {
    return @intFromFloat(c.glfwGetTime() * 1000.0);
}

// Helper to cast opaque pointer to VulkanState
fn get_state(renderer: ?*types.CardinalRenderer) ?*types.VulkanState {
    if (renderer == null) return null;
    return @ptrCast(@alignCast(renderer.?._opaque));
}

fn vk_recover_from_device_loss(s: *types.VulkanState) bool {
    if (s.recovery.recovery_in_progress) {
        return false;
    }

    // Check if we've exceeded maximum recovery attempts
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

    // Notify application of device loss
    if (s.recovery.device_loss_callback) |callback| {
        callback(s.recovery.callback_user_data);
    }

    // Validate device state before attempting recovery
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

    // Store original state for potential rollback
    const had_valid_swapchain = (s.swapchain.handle != null);
    const stored_scene = s.current_scene;

    // Step 1: Destroy all device-dependent resources in reverse order
    // Destroy scene buffers first (they might rely on sync objects)
    vk_renderer.destroy_scene_buffers(s);

    // Destroy command buffers and synchronization objects
    vk_commands.vk_destroy_commands_sync(@ptrCast(s));

    // Destroy pipelines
    if (s.pipelines.use_pbr_pipeline) {
        vk_pbr.vk_pbr_pipeline_destroy(&s.pipelines.pbr_pipeline, s.context.device, &s.allocator);
        s.pipelines.use_pbr_pipeline = false;
    }
    if (s.pipelines.use_mesh_shader_pipeline) {
        // Wait for all GPU operations to complete before destroying mesh shader pipeline
        if (s.context.device != null) {
            _ = c.vkDeviceWaitIdle(s.context.device);
        }
        vk_mesh_shader.vk_mesh_shader_destroy_pipeline(s, &s.pipelines.mesh_shader_pipeline);
        s.pipelines.use_mesh_shader_pipeline = false;
    }
    vk_simple_pipelines.vk_destroy_simple_pipelines(s);
    vk_post_process.vk_post_process_destroy(s);
    vk_pipeline.vk_destroy_pipeline(s);

    // Destroy swapchain
    vk_swapchain.vk_destroy_swapchain(s);

    // Step 2: Recreate all resources with validation at each step
    var success = true;
    var failure_point: ?[]const u8 = null;

    // Recreate device (this also recreates the logical device)
    if (!vk_instance.vk_create_device(@ptrCast(s))) {
        failure_point = "device";
        success = false;
    }

    // Recreate swapchain
    if (success and !vk_swapchain.vk_create_swapchain(s)) {
        failure_point = "swapchain";
        success = false;
    }

    // Recreate pipeline
    if (success and !vk_pipeline.vk_create_pipeline(s)) {
        failure_point = "pipeline";
        success = false;
    }

    // Recreate simple pipelines
    if (success and !vk_simple_pipelines.vk_create_simple_pipelines(s, null)) {
        failure_point = "simple pipelines";
        success = false;
    }

    // Recreate post process pipeline
    if (success and !vk_post_process.vk_post_process_init(s)) {
        failure_point = "post process pipeline";
        success = false;
    }

    // Recreate PBR pipeline if it was enabled
    if (success and stored_scene != null) {
        if (!vk_pbr.vk_pbr_pipeline_create(&s.pipelines.pbr_pipeline, s.context.device, s.context.physical_device, s.swapchain.format, s.swapchain.depth_format, s.commands.pools.?[0], s.context.graphics_queue, &s.allocator, s, s.pipelines.pipeline_cache)) {
            failure_point = "PBR pipeline";
            success = false;
        } else {
            s.pipelines.use_pbr_pipeline = true;

            // Reload scene into PBR pipeline
            if (!vk_pbr.vk_pbr_load_scene(&s.pipelines.pbr_pipeline, s.context.device, s.context.physical_device, s.commands.pools.?[0], s.context.graphics_queue, stored_scene, &s.allocator, s)) {
                failure_point = "PBR scene reload";
                success = false;
            }
        }
    }

    // Recreate mesh shader pipeline if it was enabled and supported
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
            success = false;
        };
        _ = std.fmt.bufPrintZ(&mesh_path, "{s}/mesh.mesh.spv", .{shaders_dir}) catch |err| {
            frame_log.err("Failed to format mesh shader path: {s}", .{@errorName(err)});
            success = false;
        };
        _ = std.fmt.bufPrintZ(&frag_path, "{s}/mesh.frag.spv", .{shaders_dir}) catch |err| {
            frame_log.err("Failed to format fragment shader path: {s}", .{@errorName(err)});
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
            failure_point = "mesh shader pipeline";
            success = false;
        } else {
            s.pipelines.use_mesh_shader_pipeline = true;
        }
    }

    // Recreate command buffers and synchronization
    if (success and !vk_commands.vk_create_commands_sync(s)) {
        failure_point = "commands and synchronization";
        success = false;
    }

    // Recreate scene buffers if scene exists
    if (success and stored_scene != null) {
        s.current_scene = stored_scene;
    }

    if (success) {
        frame_log.info("[RECOVERY] Device loss recovery completed successfully", .{});
        s.recovery.device_lost = false;
        s.recovery.attempt_count = 0; // Reset on successful recovery
    } else {
        frame_log.err("[RECOVERY] Device loss recovery failed at: {any}", .{failure_point orelse "unknown"});

        // Implement fallback: try to at least maintain a minimal valid state
        if (!had_valid_swapchain) {
            frame_log.warn("[RECOVERY] Attempting minimal fallback recovery", .{});
            // Try to recreate just the essential components for a graceful shutdown
            // At minimum, ensure we have basic Vulkan state to prevent crashes
            if (s.context.device != null and vk_swapchain.vk_create_swapchain(@ptrCast(s))) {
                if (vk_pipeline.vk_create_pipeline(@ptrCast(s))) {
                    _ = vk_commands.vk_create_commands_sync(@ptrCast(s));
                }
                frame_log.info("[RECOVERY] Minimal fallback recovery succeeded", .{});
            }
        }
    }

    s.recovery.recovery_in_progress = false;

    // Notify application of recovery completion
    if (s.recovery.recovery_complete_callback) |callback| {
        callback(s.recovery.callback_user_data, success);
    }

    return success;
}

fn check_render_feasibility(s: *types.VulkanState) bool {
    var minimized = false;
    if (s.recovery.window != null) {
        const win = @as(*window.CardinalWindow, @ptrCast(@alignCast(s.recovery.window.?)));
        minimized = win.is_minimized;
    }

    if (minimized) {
        frame_log.debug("Frame {d}: Window minimized, skipping frame", .{s.sync.current_frame});
        return false;
    }
    if (s.swapchain.extent.width == 0 or s.swapchain.extent.height == 0) {
        frame_log.warn("Frame {d}: Zero swapchain extent, skipping frame", .{s.sync.current_frame});
        s.swapchain.recreation_pending = true;
        return false;
    }
    return true;
}

fn handle_pending_recreation(renderer: ?*types.CardinalRenderer, s: *types.VulkanState) bool {
    // Check device loss first
    if (s.recovery.device_lost) {
        if (s.recovery.attempt_count < s.recovery.max_attempts) {
            _ = vk_recover_from_device_loss(s);
        }
        return false;
    }

    if (s.swapchain.window_resize_pending) {
        frame_log.info("Frame {d}: Window resize pending", .{s.sync.current_frame});
        s.swapchain.recreation_pending = true;
    }

    if (!s.swapchain.recreation_pending)
        return true;

    frame_log.info("Frame {d}: Handling pending swapchain recreation", .{s.sync.current_frame});
    if (vk_swapchain.vk_recreate_swapchain(@ptrCast(s))) {
        if (!vk_commands.vk_recreate_images_in_flight(@ptrCast(s))) {
            frame_log.err("Frame {d}: Failed to recreate image tracking", .{s.sync.current_frame});
            return false;
        }
        s.swapchain.recreation_pending = false;
        s.swapchain.window_resize_pending = false;
        frame_log.info("Frame {d}: Recreation successful", .{s.sync.current_frame});

        if (s.scene_upload_pending and s.pending_scene_upload != null) {
            frame_log.info("[UPLOAD] Performing deferred scene upload", .{});
            vk_renderer.cardinal_renderer_upload_scene(renderer, @ptrCast(@alignCast(s.pending_scene_upload)));
            s.scene_upload_pending = false;
            s.pending_scene_upload = null;
        }
        return true;
    }

    if (s.swapchain.consecutive_recreation_failures >= 6) {
        s.swapchain.recreation_pending = false;
        frame_log.warn("Clearing pending recreation after failures", .{});
    }

    return false;
}

fn wait_for_fence(s: *types.VulkanState) bool {
    const zone = tracy.zoneS(@src(), "Wait For Fence");
    defer zone.end();

    if (s.sync.in_flight_fences == null) {
        frame_log.warn("Frame {d}: In-flight fences array is null, attempting lazy initialization", .{s.sync.current_frame});

        var max_frames = s.sync.max_frames_in_flight;
        if (max_frames == 0) max_frames = 3;

        if (s.context.device == null) {
            frame_log.err("Device is null, cannot initialize sync manager", .{});
            return false;
        }

        if (!vk_sync_manager.vulkan_sync_manager_init(&s.sync, s.context.device, s.context.graphics_queue, max_frames, s.config.timeline_max_ahead)) {
            frame_log.err("Lazy initialization failed", .{});
            return false;
        }

        // Update max frames in case it was 0
        s.sync.max_frames_in_flight = max_frames;
    }

    var current_fence = s.sync.in_flight_fences.?[s.sync.current_frame];
    if (current_fence == null) {
        frame_log.err("Frame {d}: Current fence is null", .{s.sync.current_frame});
        return false;
    }

    const fence_status = c.vkGetFenceStatus(s.context.device, current_fence);

    if (fence_status == c.VK_SUCCESS) {
        frame_log.debug("Frame {d}: GPU ahead, skipping wait", .{s.sync.current_frame});
    } else if (fence_status == c.VK_NOT_READY) {
        const wait_res = c.vkWaitForFences(s.context.device, 1, &current_fence, c.VK_TRUE, c.UINT64_MAX);
        if (wait_res != c.VK_SUCCESS) {
            if (wait_res == c.VK_ERROR_DEVICE_LOST) {
                s.recovery.device_lost = true;
                if (s.recovery.attempt_count < s.recovery.max_attempts)
                    _ = vk_recover_from_device_loss(s);
            } else {
                frame_log.err("Frame {d}: Fence wait failed: {d}", .{ s.sync.current_frame, wait_res });
            }
            return false;
        }
    } else {
        if (fence_status == c.VK_ERROR_DEVICE_LOST) {
            s.recovery.device_lost = true;
            if (s.recovery.attempt_count < s.recovery.max_attempts)
                _ = vk_recover_from_device_loss(s);
        } else {
            frame_log.err("Frame {d}: Fence status check failed: {d}", .{ s.sync.current_frame, fence_status });
        }
        return false;
    }

    _ = c.vkResetFences(s.context.device, 1, &current_fence);
    return true;
}

fn render_frame_headless(s: *types.VulkanState, signal_value: u64) void {
    if (s.commands.buffers == null)
        return;
    const cmd = s.commands.buffers.?[s.sync.current_frame];

    var bi = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    _ = c.vkBeginCommandBuffer(cmd, &bi);
    _ = c.vkEndCommandBuffer(cmd);

    const sm = s.sync_manager;
    const sem = if (sm != null) sm.?.timeline_semaphore else s.sync.timeline_semaphore;

    var signal_info = c.VkSemaphoreSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = sem,
        .value = signal_value,
        .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .deviceIndex = 0,
    };

    var cb_info = c.VkCommandBufferSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .pNext = null,
        .commandBuffer = cmd,
        .deviceMask = 0,
    };

    var si = c.VkSubmitInfo2{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .pNext = null,
        .flags = 0,
        .waitSemaphoreInfoCount = 0,
        .pWaitSemaphoreInfos = null,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cb_info,
        .signalSemaphoreInfoCount = 1,
        .pSignalSemaphoreInfos = &signal_info,
    };

    var fence = s.sync.in_flight_fences.?[s.sync.current_frame];

    // Check if vkQueueSubmit2 is available via function pointer
    var res: c.VkResult = c.VK_SUCCESS;

    // Use synchronized submit
    res = vk_sync_manager.vulkan_sync_manager_submit_queue2(s.context.graphics_queue, 1, @ptrCast(&si), fence, s.context.vkQueueSubmit2);

    if (res == c.VK_SUCCESS) {
        _ = c.vkWaitForFences(s.context.device, 1, &fence, c.VK_TRUE, c.UINT64_MAX);
        s.sync.current_frame_value = signal_value;
        s.sync.current_frame = (s.sync.current_frame + 1) % s.sync.max_frames_in_flight;
        s.commands.current_buffer_index = 1 - s.commands.current_buffer_index;
    }
}

fn acquire_next_image(s: *types.VulkanState, out_image_index: *u32) bool {
    if (s.swapchain.handle == null or s.swapchain.image_views == null or s.swapchain.image_count == 0) {
        if (!vk_swapchain.vk_recreate_swapchain(@ptrCast(s)) or !vk_commands.vk_recreate_images_in_flight(@ptrCast(s))) {
            return false;
        }
    }

    const sem = s.sync.image_acquired_semaphores.?[s.sync.current_frame];
    const res = c.vkAcquireNextImageKHR(s.context.device, s.swapchain.handle, c.UINT64_MAX, sem, null, out_image_index);

    if (res == c.VK_ERROR_OUT_OF_DATE_KHR or res == c.VK_SUBOPTIMAL_KHR) {
        _ = vk_swapchain.vk_recreate_swapchain(@ptrCast(s));
        _ = vk_commands.vk_recreate_images_in_flight(@ptrCast(s));
        return false;
    } else if (res == c.VK_ERROR_DEVICE_LOST) {
        s.recovery.device_lost = true;
        if (s.recovery.attempt_count < s.recovery.max_attempts)
            _ = vk_recover_from_device_loss(s);
        return false;
    } else if (res != c.VK_SUCCESS) {
        return false;
    }
    return true;
}

fn submit_command_buffer(s: *types.VulkanState, cmd: c.VkCommandBuffer, acquire_sem: c.VkSemaphore, signal_value: u64) bool {
    const zone = tracy.zoneS(@src(), "Submit Command Buffer");
    defer zone.end();

    var wait_info = c.VkSemaphoreSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = acquire_sem,
        .value = 0,
        .stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .deviceIndex = 0,
    };

    var signal_infos = [2]c.VkSemaphoreSubmitInfo{ .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = s.sync.render_finished_semaphores.?[s.sync.current_frame],
        .value = 0,
        .stageMask = c.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
        .deviceIndex = 0,
    }, .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = s.sync.timeline_semaphore,
        .value = signal_value,
        .stageMask = c.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
        .deviceIndex = 0,
    } };

    var cmd_info = c.VkCommandBufferSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .pNext = null,
        .commandBuffer = cmd,
        .deviceMask = 0,
    };

    var submit_info = c.VkSubmitInfo2{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .pNext = null,
        .flags = 0,
        .waitSemaphoreInfoCount = 1,
        .pWaitSemaphoreInfos = &wait_info,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmd_info,
        .signalSemaphoreInfoCount = 2,
        .pSignalSemaphoreInfos = &signal_infos[0],
    };

    // Check if vkQueueSubmit2 is available via function pointer
    var res: c.VkResult = c.VK_SUCCESS;

    // Use synchronized submit
    res = vk_sync_manager.vulkan_sync_manager_submit_queue2(s.context.graphics_queue, 1, @ptrCast(&submit_info), s.sync.in_flight_fences.?[s.sync.current_frame], s.context.vkQueueSubmit2);

    if (res == c.VK_ERROR_DEVICE_LOST) {
        s.recovery.device_lost = true;
        if (s.recovery.attempt_count < s.recovery.max_attempts)
            _ = vk_recover_from_device_loss(s);
        return false;
    } else if (res != c.VK_SUCCESS) {
        frame_log.err("Queue submit failed: {d}", .{res});
        return false;
    }
    return true;
}

fn present_swapchain_image(s: *types.VulkanState, image_index: u32, signal_value: u64) void {
    if (s.swapchain.skip_present) {
        _ = c.vkQueueWaitIdle(s.context.graphics_queue);
        s.swapchain.recreation_pending = true;
        s.sync.current_frame_value = signal_value;
        s.sync.current_frame = (s.sync.current_frame + 1) % s.sync.max_frames_in_flight;
        s.commands.current_buffer_index = 1 - s.commands.current_buffer_index;
        return;
    }

    var wait_sem = s.sync.render_finished_semaphores.?[s.sync.current_frame];
    var present_info = c.VkPresentInfoKHR{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = null,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &wait_sem,
        .swapchainCount = 1,
        .pSwapchains = &s.swapchain.handle,
        .pImageIndices = &image_index,
        .pResults = null,
    };

    const res = c.vkQueuePresentKHR(s.context.present_queue, &present_info);

    if (res == c.VK_ERROR_OUT_OF_DATE_KHR or res == c.VK_SUBOPTIMAL_KHR) {
        s.swapchain.recreation_pending = true;
    } else if (res == c.VK_ERROR_DEVICE_LOST or res == c.VK_ERROR_SURFACE_LOST_KHR) {
        s.recovery.device_lost = true;
        if (s.recovery.attempt_count < s.recovery.max_attempts)
            _ = vk_recover_from_device_loss(s);
        return;
    } else if (res != c.VK_SUCCESS) {
        if (res == c.VK_ERROR_OUT_OF_HOST_MEMORY or res == c.VK_ERROR_OUT_OF_DEVICE_MEMORY) {
            s.recovery.device_lost = true;
            if (s.recovery.attempt_count < s.recovery.max_attempts)
                _ = vk_recover_from_device_loss(s);
        }
        return;
    }

    s.sync.current_frame_value = signal_value;
    s.sync.current_frame = (s.sync.current_frame + 1) % s.sync.max_frames_in_flight;
    s.commands.current_buffer_index = 1 - s.commands.current_buffer_index;
}

pub export fn cardinal_renderer_draw_frame(renderer: ?*types.CardinalRenderer) callconv(.c) void {
    const zone = tracy.zoneS(@src(), "Renderer Draw Frame");
    defer zone.end();

    const s = get_state(renderer) orelse return;

    if (!check_render_feasibility(s))
        return;
    if (!handle_pending_recreation(renderer, s))
        return;

    frame_log.debug("Frame {d}: Starting draw_frame", .{s.sync.current_frame});

    if (!wait_for_fence(s)) {
        frame_log.warn("Frame {d}: Fence wait failed or timed out", .{s.sync.current_frame});
        return;
    }

    // Clean up resources from the previous execution of this frame slot
    vk_mesh_shader.vk_mesh_shader_process_pending_cleanup(s);
    vk_texture_utils.process_staging_buffer_cleanups(@ptrCast(s.sync_manager), @ptrCast(&s.allocator));

    // Update textures (async load completion)
    if (s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.textureManager != null) {
        // Redundant update for testing performance impact was removed
    }

    // Update skybox (async load completion)
    if (s.pipelines.use_skybox_pipeline) {
        const vk_skybox = @import("vulkan_skybox.zig");
        vk_skybox.vk_skybox_update(&s.pipelines.skybox_pipeline, s.context.device, &s.allocator, s.commands.pools.?[0], s.context.graphics_queue, s.sync_manager);
    }

    // Prepare mesh shader rendering
    if (s.current_rendering_mode == .MESH_SHADER) {
        vk_commands.vk_prepare_mesh_shader_rendering(@ptrCast(s));
    }

    var signal_after_render: u64 = 0;

    if (s.swapchain.headless_mode) {
        if (s.sync_manager != null) {
            signal_after_render = vk_sync_manager.vulkan_sync_manager_get_next_timeline_value(s.sync_manager);
        } else {
            signal_after_render = s.sync.current_frame_value + 1;
        }
        render_frame_headless(s, signal_after_render);
        return;
    }

    var image_index: u32 = 0;
    if (!acquire_next_image(s, &image_index))
        return;

    // Update textures (process async uploads)
    // This MUST happen before we reserve the timeline value for the frame signal,
    // because update_textures might submit its own command buffer and advance the timeline.
    if (s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.textureManager != null) {
        vk_texture_manager.vk_texture_manager_update_textures(s.pipelines.pbr_pipeline.textureManager.?);
    }

    if (s.sync_manager != null) {
        signal_after_render = vk_sync_manager.vulkan_sync_manager_get_next_timeline_value(s.sync_manager);
    } else {
        signal_after_render = s.sync.current_frame_value + 1;
    }

    vk_commands.vk_record_cmd(@ptrCast(s), image_index);

    const cmd_buf = if (s.commands.current_buffer_index == 0)
        s.commands.buffers.?[s.sync.current_frame]
    else
        s.commands.alternate_primary_buffers.?[s.sync.current_frame];

    if (cmd_buf == null)
        return;

    if (!submit_command_buffer(s, cmd_buf, s.sync.image_acquired_semaphores.?[s.sync.current_frame], signal_after_render))
        return;

    present_swapchain_image(s, image_index, signal_after_render);
}
