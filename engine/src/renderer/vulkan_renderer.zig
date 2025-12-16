const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");

const c = @import("vulkan_c.zig").c;

const vk_instance = @import("vulkan_instance.zig");
const vk_swapchain = @import("vulkan_swapchain.zig");
const vk_pipeline = @import("vulkan_pipeline.zig");
const vk_commands = @import("vulkan_commands.zig");
const vk_sync_manager = @import("vulkan_sync_manager.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const vk_mesh_shader = @import("vulkan_mesh_shader.zig");
const vk_compute = @import("vulkan_compute.zig");
const vk_simple_pipelines = @import("vulkan_simple_pipelines.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const vk_buffer_utils = @import("util/vulkan_buffer_utils.zig");

// Helper to cast opaque pointer to VulkanState
fn get_state(renderer: ?*c.CardinalRenderer) ?*types.VulkanState {
    if (renderer == null) return null;
    return @ptrCast(@alignCast(renderer.?._opaque));
}

// Window resize callback
fn vk_handle_window_resize(width: u32, height: u32, user_data: ?*anyopaque) callconv(.c) void {
    const s: *types.VulkanState = @ptrCast(@alignCast(user_data orelse return));
    s.swapchain.window_resize_pending = true;
    s.swapchain.pending_width = width;
    s.swapchain.pending_height = height;
    s.swapchain.recreation_pending = true;
    log.cardinal_log_info("[SWAPCHAIN] Resize event: {d}x{d}, marking recreation pending", .{width, height});
}

fn init_vulkan_core(s: *types.VulkanState, window: ?*c.CardinalWindow) bool {
    log.cardinal_log_warn("renderer_create: begin", .{});
    if (!vk_instance.vk_create_instance(@ptrCast(s))) {
        log.cardinal_log_error("vk_create_instance failed", .{});
        return false;
    }
    log.cardinal_log_info("renderer_create: instance", .{});
    if (!vk_instance.vk_create_surface(@ptrCast(s), @ptrCast(window))) {
        log.cardinal_log_error("vk_create_surface failed", .{});
        return false;
    }
    log.cardinal_log_info("renderer_create: surface", .{});
    if (!vk_instance.vk_pick_physical_device(@ptrCast(s))) {
        log.cardinal_log_error("vk_pick_physical_device failed", .{});
        return false;
    }
    log.cardinal_log_info("renderer_create: physical_device", .{});
    if (!vk_instance.vk_create_device(@ptrCast(s))) {
        log.cardinal_log_error("vk_create_device failed", .{});
        return false;
    }
    log.cardinal_log_info("renderer_create: device", .{});
    return true;
}

fn init_ref_counting() bool {
    // Initialize reference counting system (if not already initialized)
    if (!c.cardinal_ref_counting_init(256)) {
        // This is expected if already initialized by the application
        log.cardinal_log_debug("Reference counting system already initialized or failed to initialize", .{});
    }
    log.cardinal_log_info("renderer_create: ref_counting", .{});

    // Initialize material reference counting
    if (!c.cardinal_material_ref_init()) {
        log.cardinal_log_error("cardinal_material_ref_counting_init failed", .{});
        c.cardinal_ref_counting_shutdown();
        return false;
    }
    log.cardinal_log_info("renderer_create: material_ref_counting", .{});
    return true;
}

fn setup_function_pointers(s: *types.VulkanState) void {
    if (s.context.vkQueueSubmit2 == null)
        s.context.vkQueueSubmit2 = c.vkQueueSubmit2;
    if (s.context.vkCmdPipelineBarrier2 == null)
        s.context.vkCmdPipelineBarrier2 = c.vkCmdPipelineBarrier2;
    if (s.context.vkCmdBeginRendering == null)
        s.context.vkCmdBeginRendering = c.vkCmdBeginRendering;
    if (s.context.vkCmdEndRendering == null)
        s.context.vkCmdEndRendering = c.vkCmdEndRendering;
}

fn init_sync_manager(s: *types.VulkanState) bool {
    // Initialize centralized sync manager
    const sync_mgr_ptr = c.malloc(@sizeOf(types.VulkanSyncManager));
    if (sync_mgr_ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for VulkanSyncManager", .{});
        return false;
    }
    s.sync_manager = @ptrCast(@alignCast(sync_mgr_ptr));

    if (!vk_sync_manager.vulkan_sync_manager_init(@ptrCast(s.sync_manager), s.context.device, s.context.graphics_queue, s.sync.max_frames_in_flight)) {
        log.cardinal_log_error("vulkan_sync_manager_init failed", .{});
        c.free(s.sync_manager);
        s.sync_manager = null;
        return false;
    }
    log.cardinal_log_info("renderer_create: sync_manager", .{});

    // Ensure renderer and sync manager use the same timeline semaphore
    const sm = @as(?*types.VulkanSyncManager, @ptrCast(s.sync_manager));
    if (sm != null and sm.?.timeline_semaphore != null and
        s.sync.timeline_semaphore != sm.?.timeline_semaphore) {
        if (s.sync.timeline_semaphore != null) {
            c.vkDestroySemaphore(s.context.device, s.sync.timeline_semaphore, null);
            log.cardinal_log_info("[INIT] Replacing renderer timeline with sync_manager timeline", .{});
        }
        s.sync.timeline_semaphore = sm.?.timeline_semaphore;
    }
    return true;
}

fn init_pbr_pipeline_helper(s: *types.VulkanState) void {
    s.pipelines.use_pbr_pipeline = false;
    if (vk_pbr.vk_pbr_pipeline_create(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device,
                               s.context.physical_device, s.swapchain.format,
                               s.swapchain.depth_format, s.commands.pools.?[0],
                               s.context.graphics_queue, @ptrCast(&s.allocator), @ptrCast(s))) {
        s.pipelines.use_pbr_pipeline = true;
        log.cardinal_log_info("renderer_create: PBR pipeline", .{});
    } else {
        log.cardinal_log_error("vk_pbr_pipeline_create failed", .{});
    }
}

fn init_mesh_shader_pipeline_helper(s: *types.VulkanState) void {
    s.pipelines.use_mesh_shader_pipeline = false;
    if (!s.context.supports_mesh_shader) {
        log.cardinal_log_info("Mesh shaders not supported on this device", .{});
        return;
    }

    if (!vk_mesh_shader.vk_mesh_shader_init(@ptrCast(s))) {
        log.cardinal_log_error("vk_mesh_shader_init failed", .{});
        return;
    }

    var config = std.mem.zeroes(types.MeshShaderPipelineConfig);
    
    var shaders_dir: []const u8 = "assets/shaders";
    
    const env_dir_c = c.getenv("CARDINAL_SHADERS_DIR");
    if (env_dir_c != null) {
        shaders_dir = std.mem.span(env_dir_c);
    }

    var mesh_path: [512]u8 = undefined;
    var task_path: [512]u8 = undefined;
    var frag_path: [512]u8 = undefined;

    _ = std.fmt.bufPrintZ(&mesh_path, "{s}/mesh.mesh.spv", .{shaders_dir}) catch {};
    _ = std.fmt.bufPrintZ(&task_path, "{s}/task.task.spv", .{shaders_dir}) catch {};
    _ = std.fmt.bufPrintZ(&frag_path, "{s}/mesh.frag.spv", .{shaders_dir}) catch {};

    config.mesh_shader_path = @ptrCast(&mesh_path);
    config.task_shader_path = @ptrCast(&task_path);
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

    if (vk_mesh_shader.vk_mesh_shader_create_pipeline(@ptrCast(s), @ptrCast(&config), s.swapchain.format, s.swapchain.depth_format,
                                       @ptrCast(&s.pipelines.mesh_shader_pipeline))) {
        s.pipelines.use_mesh_shader_pipeline = true;
        log.cardinal_log_info("renderer_create: Mesh shader pipeline", .{});
    } else {
        log.cardinal_log_error("vk_mesh_shader_create_pipeline failed", .{});
    }
}

fn init_compute_pipeline_helper(s: *types.VulkanState) void {
    s.pipelines.compute_shader_initialized = false;
    s.pipelines.compute_descriptor_pool = null;
    s.pipelines.compute_command_pool = null;
    s.pipelines.compute_command_buffer = null;

    if (vk_compute.vk_compute_init(@ptrCast(s))) {
        s.pipelines.compute_shader_initialized = true;
        log.cardinal_log_info("renderer_create: Compute shader support", .{});
    } else {
        log.cardinal_log_error("vk_compute_init failed", .{});
    }
}

fn init_simple_pipelines_helper(s: *types.VulkanState) void {
    s.pipelines.uv_pipeline = null;
    s.pipelines.uv_pipeline_layout = null;
    s.pipelines.wireframe_pipeline = null;
    s.pipelines.wireframe_pipeline_layout = null;
    s.pipelines.simple_descriptor_layout = null;
    s.pipelines.simple_descriptor_pool = null;
    s.pipelines.simple_descriptor_set = null;
    s.pipelines.simple_uniform_buffer = null;
    s.pipelines.simple_uniform_buffer_memory = null;
    s.pipelines.simple_uniform_buffer_mapped = null;

    if (!vk_simple_pipelines.vk_create_simple_pipelines(@ptrCast(s))) {
        log.cardinal_log_error("vk_create_simple_pipelines failed", .{});
    } else {
        log.cardinal_log_info("renderer_create: simple pipelines", .{});
    }
}

fn init_pipelines(s: *types.VulkanState) bool {
    init_pbr_pipeline_helper(s);
    init_mesh_shader_pipeline_helper(s);
    init_compute_pipeline_helper(s);

    // Initialize rendering mode
    s.current_rendering_mode = types.CardinalRenderingMode.NORMAL;

    init_simple_pipelines_helper(s);

    return true;
}

pub export fn cardinal_renderer_create(out_renderer: ?*c.CardinalRenderer, window: ?*c.CardinalWindow) callconv(.c) bool {
    if (out_renderer == null or window == null)
        return false;
    
    const s_ptr = c.calloc(1, @sizeOf(types.VulkanState));
    if (s_ptr == null) return false;
    const s: *types.VulkanState = @ptrCast(@alignCast(s_ptr));
    
    out_renderer.?._opaque = s;

    // Initialize device loss recovery state
    s.recovery.device_lost = false;
    s.recovery.recovery_in_progress = false;
    s.recovery.attempt_count = 0;
    s.recovery.max_attempts = 3;
    s.recovery.window = window;
    s.recovery.device_loss_callback = null;
    s.recovery.recovery_complete_callback = null;
    s.recovery.callback_user_data = null;
    
    // Register window resize callback
    window.?.resize_callback = vk_handle_window_resize;
    window.?.resize_user_data = s;

    if (!init_vulkan_core(s, window))
        return false;
    if (!init_ref_counting())
        return false;

    if (!vk_swapchain.vk_create_swapchain(@ptrCast(@alignCast(s)))) {
        log.cardinal_log_error("vk_create_swapchain failed", .{});
        c.cardinal_material_ref_shutdown();
        c.cardinal_ref_counting_shutdown();
        return false;
    }
    log.cardinal_log_warn("renderer_create: swapchain created", .{});

    if (!vk_pipeline.vk_create_pipeline(@ptrCast(@alignCast(s)))) {
        log.cardinal_log_error("vk_create_pipeline failed", .{});
        return false;
    }
    log.cardinal_log_warn("renderer_create: pipeline created", .{});

    if (!vk_commands.vk_create_commands_sync(@ptrCast(@alignCast(s)))) {
        log.cardinal_log_error("vk_create_commands_sync failed", .{});
        return false;
    }
    log.cardinal_log_info("renderer_create: commands", .{});

    setup_function_pointers(s);

    if (!init_sync_manager(s))
        return false;
    if (!init_pipelines(s))
        return false;

    // Initialize barrier validation system
    if (!c.cardinal_barrier_validation_init(1000, false)) {
        log.cardinal_log_error("cardinal_barrier_validation_init failed", .{});
        // Continue anyway, validation is optional
    } else {
        log.cardinal_log_info("renderer_create: barrier validation", .{});
    }

    return true;
}

pub export fn cardinal_renderer_create_headless(out_renderer: ?*c.CardinalRenderer, width: u32, height: u32) callconv(.c) bool {
    if (out_renderer == null)
        return false;
    
    const s_ptr = c.calloc(1, @sizeOf(types.VulkanState));
    if (s_ptr == null) return false;
    const s: *types.VulkanState = @ptrCast(@alignCast(s_ptr));
    
    out_renderer.?._opaque = s;
    s.swapchain.headless_mode = true;
    s.swapchain.skip_present = true;
    s.recovery.window = null;
    s.swapchain.handle = null;
    s.swapchain.extent = c.VkExtent2D{ .width = width, .height = height };
    s.swapchain.image_count = 1;
    s.recovery.device_lost = false;
    s.recovery.recovery_in_progress = false;
    s.recovery.attempt_count = 0;
    s.recovery.max_attempts = 0;

    log.cardinal_log_warn("renderer_create_headless: begin", .{});
    if (!vk_instance.vk_create_instance(@ptrCast(s))) {
        log.cardinal_log_error("vk_create_instance failed", .{});
        return false;
    }
    if (!vk_instance.vk_pick_physical_device(@ptrCast(s))) {
        log.cardinal_log_error("vk_pick_physical_device failed", .{});
        return false;
    }
    if (!vk_instance.vk_create_device(@ptrCast(s))) {
        log.cardinal_log_error("vk_create_device failed", .{});
        return false;
    }

    if (!vk_commands.vk_create_commands_sync(@ptrCast(s))) {
        log.cardinal_log_error("vk_create_commands_sync failed", .{});
        return false;
    }

    const sync_mgr_ptr = c.malloc(@sizeOf(types.VulkanSyncManager));
    if (sync_mgr_ptr == null) {
        log.cardinal_log_error("Failed to allocate VulkanSyncManager", .{});
        return false;
    }
    s.sync_manager = @ptrCast(@alignCast(sync_mgr_ptr));

    if (!vk_sync_manager.vulkan_sync_manager_init(@ptrCast(s.sync_manager), s.context.device, s.context.graphics_queue, s.sync.max_frames_in_flight)) {
        log.cardinal_log_error("vulkan_sync_manager_init failed", .{});
        c.free(s.sync_manager);
        s.sync_manager = null;
        return false;
    }

    // Ensure function pointers fallback
    if (s.context.vkQueueSubmit2 == null)
        s.context.vkQueueSubmit2 = c.vkQueueSubmit2;
    if (s.context.vkCmdPipelineBarrier2 == null)
        s.context.vkCmdPipelineBarrier2 = c.vkCmdPipelineBarrier2;
    if (s.context.vkCmdBeginRendering == null)
        s.context.vkCmdBeginRendering = c.vkCmdBeginRendering;
    if (s.context.vkCmdEndRendering == null)
        s.context.vkCmdEndRendering = c.vkCmdEndRendering;

    log.cardinal_log_info("renderer_create_headless: success", .{});
    return true;
}

pub export fn cardinal_renderer_set_skip_present(renderer: ?*c.CardinalRenderer, skip: bool) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;
    s.swapchain.skip_present = skip;
}

pub export fn cardinal_renderer_set_headless_mode(renderer: ?*c.CardinalRenderer, enable: bool) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;
    s.swapchain.headless_mode = enable;
}

pub export fn cardinal_renderer_wait_idle(renderer: ?*c.CardinalRenderer) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;
    _ = c.vkDeviceWaitIdle(s.context.device);
}

pub fn destroy_scene_buffers(vs: *types.VulkanState) void {
    log.cardinal_log_debug("[RENDERER] destroy_scene_buffers: start", .{});

    // Ensure GPU has finished using previous scene buffers before destroying them
    // Skip wait if device is already lost, as semaphores might be invalid or device unresponsive
    const sm = @as(?*types.VulkanSyncManager, @ptrCast(vs.sync_manager));
    if (sm != null and sm.?.timeline_semaphore != null and !vs.recovery.device_lost) {
        var sem_value: u64 = 0;
        const get_res = vk_sync_manager.vulkan_sync_manager_get_timeline_value(@ptrCast(sm), &sem_value);
        log.cardinal_log_info("[RENDERER] destroy_scene_buffers: waiting timeline to reach current_frame_value={d} (semaphore current={d}, get_res={d})",
            .{vs.sync.current_frame_value, sem_value, get_res});

        if (get_res != c.VK_SUCCESS or sem_value < vs.sync.current_frame_value) {
            log.cardinal_log_warn("[RENDERER] Timeline behind or unavailable; using vkDeviceWaitIdle", .{});
            if (vs.context.device != null) {
                const idle_res = c.vkDeviceWaitIdle(vs.context.device);
                log.cardinal_log_debug("[RENDERER] destroy_scene_buffers: vkDeviceWaitIdle result={d}", .{idle_res});
            }
        } else {
            const wait_res = vk_sync_manager.vulkan_sync_manager_wait_timeline(@ptrCast(sm), vs.sync.current_frame_value, c.UINT64_MAX);
            if (wait_res == c.VK_SUCCESS) {
                log.cardinal_log_debug("[RENDERER] destroy_scene_buffers: timeline wait succeeded", .{});
            } else {
                log.cardinal_log_warn("[RENDERER] Timeline wait failed in destroy_scene_buffers: {d}; falling back to device wait idle", .{wait_res});
                if (vs.context.device != null) {
                    const idle_res = c.vkDeviceWaitIdle(vs.context.device);
                    log.cardinal_log_debug("[RENDERER] destroy_scene_buffers: vkDeviceWaitIdle result={d}", .{idle_res});
                }
            }
        }
    } else if (vs.context.device != null and !vs.recovery.device_lost) {
        log.cardinal_log_debug("[RENDERER] destroy_scene_buffers: no timeline; calling vkDeviceWaitIdle", .{});
        _ = c.vkDeviceWaitIdle(vs.context.device);
    }

    if (vs.scene_meshes == null) return;

    var i: u32 = 0;
    while (i < vs.scene_mesh_count) : (i += 1) {
        var m = &vs.scene_meshes.?[i];
        if (m.vbuf != null or m.vmem != null) {
            vk_allocator.vk_allocator_free_buffer(@ptrCast(&vs.allocator), @ptrCast(m.vbuf), @ptrCast(m.vmem));
            m.vbuf = null;
            m.vmem = null;
        }
        if (m.ibuf != null or m.imem != null) {
            vk_allocator.vk_allocator_free_buffer(@ptrCast(&vs.allocator), @ptrCast(m.ibuf), @ptrCast(m.imem));
            m.ibuf = null;
            m.imem = null;
        }
    }
    c.free(vs.scene_meshes);
    vs.scene_meshes = null;
    vs.scene_mesh_count = 0;
    log.cardinal_log_debug("[RENDERER] destroy_scene_buffers: completed", .{});
}

pub export fn cardinal_renderer_destroy(renderer: ?*c.CardinalRenderer) callconv(.c) void {
    if (renderer == null or renderer.?._opaque == null) return;
    const s = get_state(renderer) orelse return;

    log.cardinal_log_info("[DESTROY] Starting renderer destruction", .{});

    // destroy in reverse order
    destroy_scene_buffers(s);

    // Check if timeline semaphore is shared with sync manager to avoid double free
    const sm_check = @as(?*types.VulkanSyncManager, @ptrCast(s.sync_manager));
    if (sm_check != null and s.sync.timeline_semaphore == sm_check.?.timeline_semaphore) {
        s.sync.timeline_semaphore = null;
    }

    vk_commands.vk_destroy_commands_sync(@ptrCast(s));

    // Cleanup VulkanSyncManager
    if (s.sync_manager != null) {
        log.cardinal_log_debug("[DESTROY] Cleaning up sync manager", .{});
        const sm = @as(?*types.VulkanSyncManager, @ptrCast(s.sync_manager));
        vk_sync_manager.vulkan_sync_manager_destroy(@ptrCast(sm));
        c.free(s.sync_manager);
        s.sync_manager = null;
    }

    // Cleanup compute shader support
    if (s.pipelines.compute_shader_initialized) {
        vk_compute.vk_compute_cleanup(@ptrCast(s));
        s.pipelines.compute_shader_initialized = false;
    }

    // Shutdown reference counting systems
    c.cardinal_material_ref_shutdown();
    c.cardinal_ref_counting_shutdown();

    // Shutdown barrier validation system
    c.cardinal_barrier_validation_shutdown();

    // Destroy simple pipelines
    log.cardinal_log_debug("[DESTROY] Destroying simple pipelines", .{});
    vk_simple_pipelines.vk_destroy_simple_pipelines(@ptrCast(s));

    // Wait for all GPU operations to complete before destroying PBR pipeline
    if (s.context.device != null) {
        _ = c.vkDeviceWaitIdle(s.context.device);
    }

    // Destroy PBR pipeline
    if (s.pipelines.use_pbr_pipeline) {
        log.cardinal_log_debug("[DESTROY] Destroying PBR pipeline", .{});
        vk_pbr.vk_pbr_pipeline_destroy(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device, @ptrCast(&s.allocator));
        s.pipelines.use_pbr_pipeline = false;
    }

    // Destroy mesh shader pipeline BEFORE destroying allocator
    if (s.pipelines.use_mesh_shader_pipeline) {
        log.cardinal_log_debug("[DESTROY] Destroying mesh shader pipeline", .{});
        vk_mesh_shader.vk_mesh_shader_cleanup(@ptrCast(s));
        s.pipelines.use_mesh_shader_pipeline = false;
    }

    log.cardinal_log_debug("[DESTROY] Destroying base pipeline resources", .{});
    vk_pipeline.vk_destroy_pipeline(@ptrCast(s));
    vk_swapchain.vk_destroy_swapchain(@ptrCast(s));
    vk_instance.vk_destroy_device_objects(@ptrCast(s));

    log.cardinal_log_info("[DESTROY] Freeing renderer state", .{});
    c.free(s);
    renderer.?._opaque = null;
}

pub export fn cardinal_renderer_internal_current_cmd(renderer: ?*c.CardinalRenderer, image_index: u32) callconv(.c) c.VkCommandBuffer {
    const s = get_state(renderer) orelse return null;
    _ = image_index;
    return s.commands.buffers.?[s.sync.current_frame];
}

pub export fn cardinal_renderer_internal_device(renderer: ?*c.CardinalRenderer) callconv(.c) c.VkDevice {
    const s = get_state(renderer) orelse return null;
    return s.context.device;
}

pub export fn cardinal_renderer_internal_physical_device(renderer: ?*c.CardinalRenderer) callconv(.c) c.VkPhysicalDevice {
    const s = get_state(renderer) orelse return null;
    return s.context.physical_device;
}

pub export fn cardinal_renderer_internal_graphics_queue(renderer: ?*c.CardinalRenderer) callconv(.c) c.VkQueue {
    const s = get_state(renderer) orelse return null;
    return s.context.graphics_queue;
}

fn create_perspective_matrix(fov: f32, aspect: f32, near_plane: f32, far_plane: f32, matrix: [*]f32) void {
    @memset(matrix[0..16], 0);

    const tan_half_fov = std.math.tan(fov * 0.5 * std.math.pi / 180.0);

    matrix[0] = 1.0 / (aspect * tan_half_fov);
    matrix[5] = -1.0 / tan_half_fov;
    matrix[10] = far_plane / (near_plane - far_plane);
    matrix[11] = -1.0;
    matrix[14] = (near_plane * far_plane) / (near_plane - far_plane);
}

fn create_view_matrix(eye: [*]const f32, center: [*]const f32, up: [*]const f32, matrix: [*]f32) void {
    var f = [3]f32{ center[0] - eye[0], center[1] - eye[1], center[2] - eye[2] };
    const f_len = std.math.sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
    f[0] /= f_len;
    f[1] /= f_len;
    f[2] /= f_len;

    var s = [3]f32{ f[1] * up[2] - f[2] * up[1], f[2] * up[0] - f[0] * up[2], f[0] * up[1] - f[1] * up[0] };
    const s_len = std.math.sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
    s[0] /= s_len;
    s[1] /= s_len;
    s[2] /= s_len;

    const u = [3]f32{ s[1] * f[2] - s[2] * f[1], s[2] * f[0] - s[0] * f[2], s[0] * f[1] - s[1] * f[0] };

    @memset(matrix[0..16], 0);
    matrix[0] = s[0];
    matrix[4] = s[1];
    matrix[8] = s[2];
    matrix[12] = -(s[0] * eye[0] + s[1] * eye[1] + s[2] * eye[2]);
    matrix[1] = u[0];
    matrix[5] = u[1];
    matrix[9] = u[2];
    matrix[13] = -(u[0] * eye[0] + u[1] * eye[1] + u[2] * eye[2]);
    matrix[2] = -f[0];
    matrix[6] = -f[1];
    matrix[10] = -f[2];
    matrix[14] = f[0] * eye[0] + f[1] * eye[1] + f[2] * eye[2];
    matrix[15] = 1.0;
}

pub export fn cardinal_renderer_set_camera(renderer: ?*c.CardinalRenderer, camera: ?*const c.CardinalCamera) callconv(.c) void {
    if (renderer == null or camera == null) return;
    const s = get_state(renderer) orelse return;
    const cam = camera.?;

    if (!s.pipelines.use_pbr_pipeline) return;

    var ubo = std.mem.zeroes(c.PBRUniformBufferObject);

    // Create model matrix (identity for now)
    c.cardinal_matrix_identity(&ubo.model);

    // Create view matrix
    create_view_matrix(&cam.position, &cam.target, &cam.up, &ubo.view);

    // Create projection matrix
    create_perspective_matrix(cam.fov, cam.aspect, cam.near_plane, cam.far_plane, &ubo.proj);

    // Set view position
    ubo.viewPos[0] = cam.position[0];
    ubo.viewPos[1] = cam.position[1];
    ubo.viewPos[2] = cam.position[2];

    // Update the uniform buffer
    @memcpy(@as([*]u8, @ptrCast(s.pipelines.pbr_pipeline.uniformBufferMapped))[0..@sizeOf(c.PBRUniformBufferObject)], @as([*]const u8, @ptrCast(&ubo))[0..@sizeOf(c.PBRUniformBufferObject)]);

    // Also invoke the centralized PBR uniform updater
    var lighting: c.PBRLightingData = undefined;
    @memcpy(@as([*]u8, @ptrCast(&lighting))[0..@sizeOf(c.PBRLightingData)], @as([*]const u8, @ptrCast(s.pipelines.pbr_pipeline.lightingBufferMapped))[0..@sizeOf(c.PBRLightingData)]);
    vk_pbr.vk_pbr_update_uniforms(@ptrCast(&s.pipelines.pbr_pipeline), @ptrCast(&ubo), @ptrCast(&lighting));
}

pub export fn cardinal_renderer_set_lighting(renderer: ?*c.CardinalRenderer, light: ?*const c.CardinalLight) callconv(.c) void {
    if (renderer == null or light == null) return;
    const s = get_state(renderer) orelse return;
    const l = light.?;

    if (!s.pipelines.use_pbr_pipeline) return;

    var lighting = std.mem.zeroes(c.PBRLightingData);

    // Set light direction
    lighting.lightDirection[0] = l.direction[0];
    lighting.lightDirection[1] = l.direction[1];
    lighting.lightDirection[2] = l.direction[2];

    // Set light color and intensity
    lighting.lightColor[0] = l.color[0];
    lighting.lightColor[1] = l.color[1];
    lighting.lightColor[2] = l.color[2];
    lighting.lightIntensity = l.intensity;

    // Set ambient color
    lighting.ambientColor[0] = l.ambient[0];
    lighting.ambientColor[1] = l.ambient[1];
    lighting.ambientColor[2] = l.ambient[2];

    // Update the lighting buffer
    @memcpy(@as([*]u8, @ptrCast(s.pipelines.pbr_pipeline.lightingBufferMapped))[0..@sizeOf(c.PBRLightingData)], @as([*]const u8, @ptrCast(&lighting))[0..@sizeOf(c.PBRLightingData)]);

    // Also invoke the centralized PBR uniform updater
    var ubo: c.PBRUniformBufferObject = undefined;
    @memcpy(@as([*]u8, @ptrCast(&ubo))[0..@sizeOf(c.PBRUniformBufferObject)], @as([*]const u8, @ptrCast(s.pipelines.pbr_pipeline.uniformBufferMapped))[0..@sizeOf(c.PBRUniformBufferObject)]);
    vk_pbr.vk_pbr_update_uniforms(@ptrCast(&s.pipelines.pbr_pipeline), @ptrCast(&ubo), @ptrCast(&lighting));
}

pub export fn cardinal_renderer_enable_pbr(renderer: ?*c.CardinalRenderer, enable: bool) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;

    if (enable and !s.pipelines.use_pbr_pipeline) {
        if (s.pipelines.pbr_pipeline.initialized) {
            vk_pbr.vk_pbr_pipeline_destroy(@ptrCast(&s.pipelines.pbr_pipeline), @ptrCast(s.context.device), @ptrCast(&s.allocator));
        }

        if (vk_pbr.vk_pbr_pipeline_create(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device,
                                   s.context.physical_device, s.swapchain.format,
                                   s.swapchain.depth_format, s.commands.pools.?[0],
                                   s.context.graphics_queue, @ptrCast(&s.allocator), @ptrCast(s))) {
            s.pipelines.use_pbr_pipeline = true;

            if (s.current_scene != null) {
                if (!vk_pbr.vk_pbr_load_scene(@ptrCast(&s.pipelines.pbr_pipeline), @ptrCast(s.context.device),
                                   @ptrCast(s.context.physical_device), @ptrCast(s.commands.pools.?[0]),
                                   @ptrCast(s.context.graphics_queue), @ptrCast(s.current_scene), @ptrCast(&s.allocator), @ptrCast(@alignCast(s)))) {
                    log.cardinal_log_error("Failed to load scene into PBR pipeline", .{});
                }
            }

            log.cardinal_log_info("PBR pipeline enabled", .{});
        } else {
            log.cardinal_log_error("Failed to enable PBR pipeline", .{});
        }
    } else if (!enable and s.pipelines.use_pbr_pipeline) {
        vk_pbr.vk_pbr_pipeline_destroy(@ptrCast(&s.pipelines.pbr_pipeline), @ptrCast(s.context.device), @ptrCast(&s.allocator));
        s.pipelines.use_pbr_pipeline = false;
        log.cardinal_log_info("PBR pipeline disabled", .{});
    }
}

pub export fn cardinal_renderer_is_pbr_enabled(renderer: ?*c.CardinalRenderer) callconv(.c) bool {
    if (renderer == null) return false;
    const s = get_state(renderer) orelse return false;
    return s.pipelines.use_pbr_pipeline;
}

pub export fn cardinal_renderer_enable_mesh_shader(renderer: ?*c.CardinalRenderer, enable: bool) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;

    if (enable and !s.pipelines.use_mesh_shader_pipeline and s.context.supports_mesh_shader) {
        // Create default mesh shader pipeline configuration
        var config = std.mem.zeroes(types.MeshShaderPipelineConfig);
        
        var shaders_dir: []const u8 = "assets/shaders";
        const env_dir_c = c.getenv("CARDINAL_SHADERS_DIR");
        if (env_dir_c != null) {
            shaders_dir = std.mem.span(env_dir_c);
        }

        var mesh_path: [512]u8 = undefined;
        var task_path: [512]u8 = undefined;
        var frag_path: [512]u8 = undefined;

        _ = std.fmt.bufPrintZ(&mesh_path, "{s}/mesh.mesh.spv", .{shaders_dir}) catch {};
        _ = std.fmt.bufPrintZ(&task_path, "{s}/task.task.spv", .{shaders_dir}) catch {};
        _ = std.fmt.bufPrintZ(&frag_path, "{s}/mesh.frag.spv", .{shaders_dir}) catch {};

        config.mesh_shader_path = @ptrCast(&mesh_path);
        config.task_shader_path = @ptrCast(&task_path);
        config.fragment_shader_path = @ptrCast(&frag_path);
        config.max_vertices_per_meshlet = 64;
        config.max_primitives_per_meshlet = 126;
        config.cull_mode = c.VK_CULL_MODE_NONE;
        config.front_face = c.VK_FRONT_FACE_CLOCKWISE;
        config.polygon_mode = c.VK_POLYGON_MODE_FILL;
        config.blend_enable = false;
        config.depth_test_enable = true;
        config.depth_write_enable = true;
        config.depth_compare_op = c.VK_COMPARE_OP_LESS;

        if (vk_mesh_shader.vk_mesh_shader_create_pipeline(@ptrCast(@alignCast(s)), @ptrCast(&config), s.swapchain.format,
                                           s.swapchain.depth_format,
                                           @ptrCast(&s.pipelines.mesh_shader_pipeline))) {
            s.pipelines.use_mesh_shader_pipeline = true;
            log.cardinal_log_info("Mesh shader pipeline enabled", .{});
        } else {
            log.cardinal_log_error("Failed to enable mesh shader pipeline", .{});
        }
    } else if (!enable and s.pipelines.use_mesh_shader_pipeline) {
        vk_mesh_shader.vk_mesh_shader_destroy_pipeline(@ptrCast(@alignCast(s)), @ptrCast(&s.pipelines.mesh_shader_pipeline));
        s.pipelines.use_mesh_shader_pipeline = false;
        log.cardinal_log_info("Mesh shader pipeline disabled", .{});
    } else if (enable and !s.context.supports_mesh_shader) {
        log.cardinal_log_warn("Mesh shaders not supported on this device", .{});
    }
}

pub export fn cardinal_renderer_is_mesh_shader_enabled(renderer: ?*c.CardinalRenderer) callconv(.c) bool {
    if (renderer == null) return false;
    const s = get_state(renderer) orelse return false;
    return s.pipelines.use_mesh_shader_pipeline;
}

pub export fn cardinal_renderer_supports_mesh_shader(renderer: ?*c.CardinalRenderer) callconv(.c) bool {
    if (renderer == null) return false;
    const s = get_state(renderer) orelse return false;
    return s.context.supports_mesh_shader;
}

pub export fn cardinal_renderer_internal_graphics_queue_family(renderer: ?*c.CardinalRenderer) callconv(.c) u32 {
    const s = get_state(renderer) orelse return 0;
    return s.context.graphics_queue_family;
}

pub export fn cardinal_renderer_internal_instance(renderer: ?*c.CardinalRenderer) callconv(.c) c.VkInstance {
    const s = get_state(renderer) orelse return null;
    return s.context.instance;
}

pub export fn cardinal_renderer_internal_swapchain_image_count(renderer: ?*c.CardinalRenderer) callconv(.c) u32 {
    const s = get_state(renderer) orelse return 0;
    return s.swapchain.image_count;
}

pub export fn cardinal_renderer_internal_swapchain_format(renderer: ?*c.CardinalRenderer) callconv(.c) c.VkFormat {
    const s = get_state(renderer) orelse return c.VK_FORMAT_UNDEFINED;
    return s.swapchain.format;
}

pub export fn cardinal_renderer_internal_depth_format(renderer: ?*c.CardinalRenderer) callconv(.c) c.VkFormat {
    const s = get_state(renderer) orelse return c.VK_FORMAT_UNDEFINED;
    return s.swapchain.depth_format;
}

pub export fn cardinal_renderer_internal_swapchain_extent(renderer: ?*c.CardinalRenderer) callconv(.c) c.VkExtent2D {
    const s = get_state(renderer) orelse return c.VkExtent2D{ .width = 0, .height = 0 };
    return s.swapchain.extent;
}

pub export fn cardinal_renderer_set_ui_callback(renderer: ?*c.CardinalRenderer, callback: ?*const fn (c.VkCommandBuffer) callconv(.c) void) callconv(.c) void {
    const s = get_state(renderer) orelse return;
    s.ui_record_callback = callback;
}

// Submit and wait helper
fn submit_and_wait(s: *types.VulkanState, cmd: c.VkCommandBuffer) void {
    var cmd_info = c.VkCommandBufferSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .pNext = null,
        .commandBuffer = cmd,
        .deviceMask = 0,
    };
    var submit2 = c.VkSubmitInfo2{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .pNext = null,
        .flags = 0,
        .waitSemaphoreInfoCount = 0,
        .pWaitSemaphoreInfos = null,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmd_info,
        .signalSemaphoreInfoCount = 0,
        .pSignalSemaphoreInfos = null,
    };

    if (s.sync_manager != null) {
        const sm = s.sync_manager.?;
        const timeline_value = vk_sync_manager.vulkan_sync_manager_get_next_timeline_value(sm);

        var signal_semaphore_info = c.VkSemaphoreSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .pNext = null,
            .semaphore = sm.timeline_semaphore,
            .value = timeline_value,
            .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
            .deviceIndex = 0,
        };

        submit2.signalSemaphoreInfoCount = 1;
        submit2.pSignalSemaphoreInfos = &signal_semaphore_info;

        const submit_result = s.context.vkQueueSubmit2.?(s.context.graphics_queue, 1, &submit2, null);
        if (submit_result == c.VK_SUCCESS) {
            // Wait for completion using timeline semaphore
            const wait_result = vk_sync_manager.vulkan_sync_manager_wait_timeline(sm, timeline_value, c.UINT64_MAX);
            if (wait_result == c.VK_SUCCESS) {
                c.vkFreeCommandBuffers(s.context.device, s.commands.pools.?[s.sync.current_frame], 1, &cmd);
            } else {
                log.cardinal_log_warn("[SYNC] Timeline wait failed for immediate submit: {d}", .{wait_result});
            }
        } else {
            log.cardinal_log_error("[SYNC] Failed to submit immediate command buffer: {d}", .{submit_result});
        }
    } else {
        // Fallback to old method if sync manager not available
        _ = s.context.vkQueueSubmit2.?(s.context.graphics_queue, 1, &submit2, null);
        const wait_result = c.vkQueueWaitIdle(s.context.graphics_queue);

        if (wait_result == c.VK_SUCCESS) {
            c.vkFreeCommandBuffers(s.context.device, s.commands.pools.?[s.sync.current_frame], 1, &cmd);
        } else {
            log.cardinal_log_warn("[SYNC] Skipping command buffer free due to queue wait failure: {d}", .{wait_result});
        }
    }
}

pub export fn cardinal_renderer_immediate_submit(renderer: ?*c.CardinalRenderer, record: ?*const fn (c.VkCommandBuffer) callconv(.c) void) callconv(.c) void {
    const s = get_state(renderer) orelse return;

    var ai = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = s.commands.pools.?[s.sync.current_frame],
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    var cmd: c.VkCommandBuffer = null;
    _ = c.vkAllocateCommandBuffers(s.context.device, &ai, &cmd);

    var bi = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    _ = c.vkBeginCommandBuffer(cmd, &bi);

    if (record) |rec| {
        rec(cmd);
    }

    _ = c.vkEndCommandBuffer(cmd);

    submit_and_wait(s, cmd);
}

fn try_submit_secondary(s: *types.VulkanState, record: ?*const fn (c.VkCommandBuffer) callconv(.c) void) bool {
    const mt_manager = vk_commands.vk_get_mt_command_manager() orelse return false;
    if (!mt_manager.thread_pools[0].is_active) {
        return false;
    }

    var ai = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = s.commands.pools.?[s.sync.current_frame],
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    var primary_cmd: c.VkCommandBuffer = null;
    _ = c.vkAllocateCommandBuffers(s.context.device, &ai, &primary_cmd);

    var bi = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    _ = c.vkBeginCommandBuffer(primary_cmd, &bi);

    var secondary_context: types.CardinalSecondaryCommandContext = undefined;
    if (!vk_commands.vulkan_mt.cardinal_mt_allocate_secondary_command_buffer(&mt_manager.thread_pools[0], &secondary_context)) {
        _ = c.vkEndCommandBuffer(primary_cmd);
        return false;
    }

    var inheritance_rendering = std.mem.zeroes(c.VkCommandBufferInheritanceRenderingInfo);
    inheritance_rendering.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_RENDERING_INFO;
    inheritance_rendering.colorAttachmentCount = 1;
    var color_format = s.swapchain.format;
    inheritance_rendering.pColorAttachmentFormats = &color_format;
    inheritance_rendering.depthAttachmentFormat = s.swapchain.depth_format;
    inheritance_rendering.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var inheritance_info = std.mem.zeroes(c.VkCommandBufferInheritanceInfo);
    inheritance_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO;
    inheritance_info.pNext = &inheritance_rendering;
    inheritance_info.renderPass = null;
    inheritance_info.subpass = 0;
    inheritance_info.framebuffer = null;
    inheritance_info.occlusionQueryEnable = c.VK_FALSE;

    if (!vk_commands.vulkan_mt.cardinal_mt_begin_secondary_command_buffer(&secondary_context, &inheritance_info)) {
        _ = c.vkEndCommandBuffer(primary_cmd);
        return false;
    }

    if (record) |rec| {
        rec(secondary_context.command_buffer);
    }

    if (!vk_commands.vulkan_mt.cardinal_mt_end_secondary_command_buffer(&secondary_context)) {
        _ = c.vkEndCommandBuffer(primary_cmd);
        return false;
    }

    vk_commands.vulkan_mt.cardinal_mt_execute_secondary_command_buffers(primary_cmd, @ptrCast(&secondary_context), 1);
    _ = c.vkEndCommandBuffer(primary_cmd);

    submit_and_wait(s, primary_cmd);
    return true;
}

pub export fn cardinal_renderer_immediate_submit_with_secondary(renderer: ?*c.CardinalRenderer, record: ?*const fn (c.VkCommandBuffer) callconv(.c) void, use_secondary: bool) callconv(.c) void {
    const s = get_state(renderer) orelse return;

    if (use_secondary) {
        if (try_submit_secondary(s, record)) {
            return;
        }
        log.cardinal_log_warn("[SYNC] Secondary command buffer failed, falling back to primary", .{});
    }

    cardinal_renderer_immediate_submit(renderer, record);
}

fn upload_single_mesh(s: *types.VulkanState, src: *const c.CardinalMesh, dst: *types.GpuMesh, mesh_index: u32) bool {
    dst.vbuf = null;
    dst.vmem = null;
    dst.ibuf = null;
    dst.imem = null;
    dst.vtx_count = 0;
    dst.idx_count = 0;

    dst.vtx_stride = @sizeOf(c.CardinalVertex);
    const vsize: c.VkDeviceSize = src.vertex_count * dst.vtx_stride;
    const index_size: c.VkDeviceSize = src.index_count * @sizeOf(u32);

    log.cardinal_log_debug("[UPLOAD] Mesh {d}: vsize={d}, isize={d}, vertices={d}, indices={d}",
        .{mesh_index, vsize, index_size, src.vertex_count, src.index_count});

    if (src.vertices == null or src.vertex_count == 0) {
        log.cardinal_log_error("Mesh {d} has no vertices", .{mesh_index});
        return false;
    }

    log.cardinal_log_debug("[UPLOAD] Mesh {d}: staging vertex buffer", .{mesh_index});
    if (!vk_buffer_utils.vk_buffer_create_with_staging(
            @ptrCast(&s.allocator), s.context.device, s.commands.pools.?[0], s.context.graphics_queue,
            src.vertices, vsize, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &dst.vbuf, &dst.vmem, s)) {
        log.cardinal_log_error("Failed to create vertex buffer for mesh {d}", .{mesh_index});
        return false;
    }

    if (src.index_count > 0 and src.indices != null) {
        log.cardinal_log_debug("[UPLOAD] Mesh {d}: staging index buffer", .{mesh_index});
        if (vk_buffer_utils.vk_buffer_create_with_staging(
                @ptrCast(&s.allocator), s.context.device, s.commands.pools.?[0], s.context.graphics_queue,
                src.indices, index_size, c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, &dst.ibuf, &dst.imem, s)) {
            dst.idx_count = src.index_count;
        } else {
            log.cardinal_log_error("Failed to create index buffer for mesh {d}", .{mesh_index});
        }
    }
    dst.vtx_count = src.vertex_count;

    log.cardinal_log_debug("Successfully uploaded mesh {d}: {d} vertices, {d} indices", .{mesh_index, src.vertex_count, src.index_count});
    return true;
}

pub export fn cardinal_renderer_upload_scene(renderer: ?*c.CardinalRenderer, scene: ?*const c.CardinalScene) callconv(.c) void {
    const s = get_state(renderer) orelse return;

    log.cardinal_log_info("[UPLOAD] Starting scene upload; meshes={d}", .{if (scene != null) scene.?.mesh_count else 0});

    if (s.swapchain.recreation_pending or s.swapchain.window_resize_pending or
        s.recovery.recovery_in_progress or s.recovery.device_lost) {
        s.pending_scene_upload = @ptrCast(scene);
        s.scene_upload_pending = true;
        log.cardinal_log_warn("[UPLOAD] Deferring scene upload due to swapchain/recovery state", .{});
        return;
    }

    if (s.context.vkGetSemaphoreCounterValue != null and s.sync.timeline_semaphore != null) {
        var sem_val: u64 = 0;
        const sem_res = s.context.vkGetSemaphoreCounterValue.?(
            s.context.device, s.sync.timeline_semaphore, &sem_val);
        log.cardinal_log_debug("[UPLOAD][SYNC] Timeline before cleanup: value={d}, current_frame_value={d}, result={d}",
            .{sem_val, s.sync.current_frame_value, sem_res});
    }

    log.cardinal_log_debug("[UPLOAD] Destroying previous scene buffers", .{});
    destroy_scene_buffers(s);

    if (scene == null or scene.?.mesh_count == 0) {
        log.cardinal_log_warn("[UPLOAD] No scene or zero meshes; aborting upload", .{});
        return;
    }

    s.scene_mesh_count = scene.?.mesh_count;
    const meshes_ptr = c.calloc(s.scene_mesh_count, @sizeOf(types.GpuMesh));
    if (meshes_ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for scene meshes", .{});
        return;
    }
    s.scene_meshes = @ptrCast(@alignCast(meshes_ptr));

    log.cardinal_log_info("Uploading scene with {d} meshes using batched staging operations", .{scene.?.mesh_count});

    var i: u32 = 0;
    while (i < scene.?.mesh_count) : (i += 1) {
        const src = &scene.?.meshes[i];
        const dst = &s.scene_meshes.?[i];

        if (!upload_single_mesh(s, @ptrCast(src), dst, i)) {
            continue;
        }
    }

    if (s.pipelines.use_pbr_pipeline) {
        log.cardinal_log_info("[UPLOAD][PBR] Loading scene into PBR pipeline", .{});
        if (!vk_pbr.vk_pbr_load_scene(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device, s.context.physical_device,
                            s.commands.pools.?[0], s.context.graphics_queue, @ptrCast(scene), @ptrCast(&s.allocator), @ptrCast(s))) {
            log.cardinal_log_error("Failed to load scene into PBR pipeline", .{});
        }
    }

    s.current_scene = if (scene) |ptr| @ptrCast(ptr) else null;

    log.cardinal_log_info("Scene upload completed successfully with {d} meshes", .{scene.?.mesh_count});
}

pub export fn cardinal_renderer_clear_scene(renderer: ?*c.CardinalRenderer) callconv(.c) void {
    const s = get_state(renderer) orelse return;

    _ = c.vkDeviceWaitIdle(s.context.device);

    destroy_scene_buffers(s);
}

pub export fn cardinal_renderer_set_rendering_mode(renderer: ?*c.CardinalRenderer, mode: c.CardinalRenderingMode) callconv(.c) void {
    const s = get_state(renderer) orelse {
        log.cardinal_log_error("Invalid renderer state", .{});
        return;
    };

    const previous_mode = s.current_rendering_mode;
    s.current_rendering_mode = @enumFromInt(mode);

    if (mode == c.CARDINAL_RENDERING_MODE_MESH_SHADER and previous_mode != types.CardinalRenderingMode.MESH_SHADER) {
        cardinal_renderer_enable_mesh_shader(renderer, true);
    } else if (mode != c.CARDINAL_RENDERING_MODE_MESH_SHADER and previous_mode == types.CardinalRenderingMode.MESH_SHADER) {
        cardinal_renderer_enable_mesh_shader(renderer, false);
    }

    log.cardinal_log_info("Rendering mode changed to: {d}", .{mode});
}

pub export fn cardinal_renderer_get_rendering_mode(renderer: ?*c.CardinalRenderer) callconv(.c) c.CardinalRenderingMode {
    const s = get_state(renderer) orelse {
        log.cardinal_log_error("Invalid renderer state", .{});
        return c.CARDINAL_RENDERING_MODE_NORMAL;
    };

    return @intCast(@intFromEnum(s.current_rendering_mode));
}

pub export fn cardinal_renderer_set_device_loss_callbacks(
    renderer: ?*c.CardinalRenderer, 
    device_loss_callback: ?*const fn (?*anyopaque) callconv(.c) void,
    recovery_complete_callback: ?*const fn (?*anyopaque, bool) callconv(.c) void, 
    user_data: ?*anyopaque
) callconv(.c) void {
    if (renderer == null) {
        log.cardinal_log_error("Invalid renderer", .{});
        return;
    }

    const s = get_state(renderer) orelse {
        log.cardinal_log_error("Invalid renderer state", .{});
        return;
    };

    s.recovery.device_loss_callback = device_loss_callback;
    s.recovery.recovery_complete_callback = recovery_complete_callback;
    s.recovery.callback_user_data = user_data;

    log.cardinal_log_info("Device loss recovery callbacks set", .{});
}

pub export fn cardinal_renderer_is_device_lost(renderer: ?*c.CardinalRenderer) callconv(.c) bool {
    if (renderer == null) return false;
    const s = get_state(renderer) orelse return false;
    return s.recovery.device_lost;
}

pub export fn cardinal_renderer_get_recovery_stats(renderer: ?*c.CardinalRenderer, out_attempt_count: ?*u32, out_max_attempts: ?*u32) callconv(.c) bool {
    if (renderer == null or out_attempt_count == null or out_max_attempts == null) {
        return false;
    }

    const s = get_state(renderer) orelse return false;

    out_attempt_count.?.* = s.recovery.attempt_count;
    out_max_attempts.?.* = s.recovery.max_attempts;

    return true;
}
