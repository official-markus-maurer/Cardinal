const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const math = @import("../core/math.zig");
const types = @import("vulkan_types.zig");
const window = @import("../core/window.zig");

const renderer_log = log.ScopedLogger("RENDERER");

const c = @import("vulkan_c.zig").c;

const vk_instance = @import("vulkan_instance.zig");
const vk_swapchain = @import("vulkan_swapchain.zig");
const vk_pipeline = @import("vulkan_pipeline.zig");
const vk_pso = @import("vulkan_pso.zig");
const vk_commands = @import("vulkan_commands.zig");
const vk_sync_manager = @import("vulkan_sync_manager.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const vk_ssao = @import("vulkan_ssao.zig");
const vk_skybox = @import("vulkan_skybox.zig");
const vk_mesh_shader = @import("vulkan_mesh_shader.zig");
const vk_compute = @import("vulkan_compute.zig");
const texture_loader = @import("../assets/texture_loader.zig");
const vk_simple_pipelines = @import("vulkan_simple_pipelines.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const buffer_mgr = @import("vulkan_buffer_manager.zig");
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");
const vk_barrier_validation = @import("vulkan_barrier_validation.zig");
const ref_counting = @import("../core/ref_counting.zig");
const asset_manager = @import("../assets/asset_manager.zig");
const transform = @import("../core/transform.zig");
const render_graph = @import("render_graph.zig");
const vk_post_process = @import("vulkan_post_process.zig");
const vk_texture_manager = @import("vulkan_texture_manager.zig");
const vk_shadows = @import("vulkan_shadows.zig");

// Helper to cast opaque pointer to VulkanState
fn get_state(renderer: ?*types.CardinalRenderer) ?*types.VulkanState {
    if (renderer == null) return null;
    return @ptrCast(@alignCast(renderer.?._opaque));
}

fn pbr_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    var clears: [2]c.VkClearValue = undefined;
    clears[0].color.float32[0] = state.config.pbr_clear_color[0];
    clears[0].color.float32[1] = state.config.pbr_clear_color[1];
    clears[0].color.float32[2] = state.config.pbr_clear_color[2];
    clears[0].color.float32[3] = state.config.pbr_clear_color[3];
    clears[1].depthStencil.depth = 1.0;
    clears[1].depthStencil.stencil = 0;

    var depth_view: ?c.VkImageView = null;
    var color_view: ?c.VkImageView = null;
    var use_depth = false;

    if (state.render_graph) |rg_ptr| {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        if (rg.resources.get(types.RESOURCE_ID_DEPTHBUFFER)) |res| {
            depth_view = res.image_view;
            use_depth = (depth_view != null);
        }
        if (rg.resources.get(types.RESOURCE_ID_HDR_COLOR)) |res| {
            color_view = res.image_view;
        }
    }

    if (!use_depth) {
        use_depth = state.swapchain.depth_image_view != null and state.swapchain.depth_image != null;
    }

    const use_secondary = (state.commands.scene_secondary_buffers != null);
    const flags: c.VkRenderingFlags = if (use_secondary) c.VK_RENDERING_CONTENTS_SECONDARY_COMMAND_BUFFERS_BIT else 0;

    const should_clear_depth = (state.pipelines.depth_pipeline == null or state.current_rendering_mode != types.CardinalRenderingMode.NORMAL);

    renderer_log.info("PBR pass frame {d}: use_depth={any}, depth_view={any}, color_view={any}, clear_depth={any}, mode={any}", .{ state.sync.current_frame, use_depth, depth_view, color_view, should_clear_depth, state.current_rendering_mode });

    if (vk_commands.vk_begin_rendering_impl(state, cmd, state.current_image_index, use_depth, depth_view, color_view, &clears, true, should_clear_depth, flags, true)) {
        if (use_depth and depth_view != null) {
            // Log the image view used for rendering
        }

        if (use_secondary) {
            vk_commands.vk_record_scene_with_secondary_buffers(state, cmd, state.current_image_index, use_depth, &clears);
        } else {
            vk_commands.vk_record_scene_content(state, cmd);
        }

        vk_commands.vk_end_rendering(state, cmd);
    }
}

fn post_process_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    var input_view: ?c.VkImageView = null;
    if (state.render_graph) |rg_ptr| {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        if (rg.resources.get(types.RESOURCE_ID_HDR_COLOR)) |res| {
            input_view = res.image_view;
        }
    }

    var clears: [1]c.VkClearValue = undefined;
    clears[0].color.float32[0] = 0.0;
    clears[0].color.float32[1] = 0.0;
    clears[0].color.float32[2] = 0.0;
    clears[0].color.float32[3] = 1.0;

    // Render to Swapchain (Backbuffer)
    // begin_dynamic_rendering_ext defaults to swapchain view if color_view is null
    renderer_log.info("Post-process pass frame {d}: hdr_view={any}", .{ state.sync.current_frame, input_view });

    if (vk_commands.vk_begin_rendering_impl(state, cmd, state.current_image_index, false, null, null, &clears, true, false, 0, true)) {
        if (input_view) |view| {
            vk_post_process.draw(state, cmd, state.sync.current_frame, view);
        }
        vk_commands.vk_end_rendering(state, cmd);
    }
}

fn bloom_compute_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    var input_view: ?c.VkImageView = null;
    if (state.render_graph) |rg_ptr| {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        if (rg.resources.get(types.RESOURCE_ID_HDR_COLOR)) |res| {
            input_view = res.image_view;
        }
    }

    if (input_view) |view| {
        vk_post_process.compute_bloom(state, cmd, state.sync.current_frame, view);
    }
}

fn skybox_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    var clears: [1]c.VkClearValue = undefined;
    clears[0].color.float32[0] = 0.0;
    clears[0].color.float32[1] = 0.0;
    clears[0].color.float32[2] = 0.0;
    clears[0].color.float32[3] = 1.0;

    var use_depth = false;
    if (state.render_graph) |rg_ptr| {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        use_depth = rg.resources.get(types.RESOURCE_ID_DEPTHBUFFER) != null;
    }
    if (!use_depth) {
        use_depth = state.swapchain.depth_image_view != null and state.swapchain.depth_image != null;
    }

    if (state.pipelines.use_skybox_pipeline and state.pipelines.skybox_pipeline.initialized and state.pipelines.skybox_pipeline.texture.is_allocated) {
        if (state.pipelines.use_pbr_pipeline and state.pipelines.pbr_pipeline.uniformBuffersMapped[state.sync.current_frame] != null) {
            const ubo = @as(*types.PBRUniformBufferObject, @ptrCast(@alignCast(state.pipelines.pbr_pipeline.uniformBuffersMapped[state.sync.current_frame])));
            if (vk_commands.vk_begin_rendering_impl(state, cmd, state.current_image_index, use_depth, null, null, &clears, false, false, 0, true)) {
                var view: math.Mat4 = undefined;
                var proj: math.Mat4 = undefined;
                view.data = ubo.view;
                proj.data = ubo.proj;
                vk_skybox.render(&state.pipelines.skybox_pipeline, cmd, view, proj);
                vk_commands.vk_end_rendering(state, cmd);
            }
        }
    }
}

fn ui_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    if (state.ui_record_callback == null) return;
    var clears: [1]c.VkClearValue = undefined;
    clears[0].color.float32[0] = 0.0;
    clears[0].color.float32[1] = 0.0;
    clears[0].color.float32[2] = 0.0;
    clears[0].color.float32[3] = 1.0;

    var use_depth = false;
    if (state.render_graph) |rg_ptr| {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        use_depth = rg.resources.get(types.RESOURCE_ID_DEPTHBUFFER) != null;
    }
    if (!use_depth) {
        use_depth = state.swapchain.depth_image_view != null and state.swapchain.depth_image != null;
    }

    if (vk_commands.vk_begin_rendering_impl(state, cmd, state.current_image_index, use_depth, null, null, &clears, false, false, 0, true)) {
        state.ui_record_callback.?(cmd);
        vk_commands.vk_end_rendering(state, cmd);
    }
}

fn present_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    _ = cmd;
    _ = state;
    // No drawing; Render Graph will insert the transition to PRESENT_SRC_KHR via outputs/state.
}

// Window resize callback
fn vk_handle_window_resize(width: u32, height: u32, user_data: ?*anyopaque) callconv(.c) void {
    const s: *types.VulkanState = @ptrCast(@alignCast(user_data orelse return));
    s.swapchain.window_resize_pending = true;
    s.swapchain.pending_width = width;
    s.swapchain.pending_height = height;
    s.swapchain.recreation_pending = true;
    renderer_log.info("Resize event: {d}x{d}, marking recreation pending", .{ width, height });
}

fn init_vulkan_core(s: *types.VulkanState, win: ?*window.CardinalWindow) bool {
    if (!vk_instance.vk_create_instance(@ptrCast(s))) {
        renderer_log.err("vk_create_instance failed", .{});
        return false;
    }
    if (!vk_instance.vk_create_surface(@ptrCast(s), @ptrCast(win))) {
        renderer_log.err("vk_create_surface failed", .{});
        return false;
    }
    if (!vk_instance.vk_pick_physical_device(@ptrCast(s))) {
        renderer_log.err("vk_pick_physical_device failed", .{});
        return false;
    }
    if (!vk_instance.vk_create_device(@ptrCast(s))) {
        renderer_log.err("vk_create_device failed", .{});
        return false;
    }
    return true;
}

pub export fn cardinal_renderer_set_post_process_params(renderer: ?*types.CardinalRenderer, params: ?*const types.PostProcessParams) callconv(.c) void {
    const s = get_state(renderer) orelse return;
    const pp = params orelse return;

    // Update the current params. The actual buffer update happens in the render loop (vk_post_process_draw)
    // for the current frame, ensuring we don't modify buffers currently in use by the GPU.
    if (s.pipelines.post_process_pipeline.initialized) {
        s.pipelines.post_process_pipeline.current_params = pp.*;
    }
}

pub export fn cardinal_renderer_set_frame_allocator(renderer: ?*types.CardinalRenderer, allocator: ?*anyopaque) callconv(.c) void {
    const s = get_state(renderer) orelse return;
    s.frame_allocator = allocator;
}

fn init_ref_counting() bool {
    // Initialize reference counting system (if not already initialized)
    if (!ref_counting.cardinal_ref_counting_init(256)) {
        renderer_log.debug("Reference counting system already initialized or failed to initialize", .{});
    }

    // Initialize unified asset manager
    asset_manager.init() catch {
        renderer_log.err("asset_manager.init() failed", .{});
        return false;
    };

    return true;
}

fn setup_function_pointers(s: *types.VulkanState) void {
    if (s.context.vkQueueSubmit2 == null) {
        const func = c.vkGetDeviceProcAddr(s.context.device, "vkQueueSubmit2");
        if (func) |f| {
            s.context.vkQueueSubmit2 = @ptrCast(f);
        } else {
            // Try KHR extension
            const func_khr = c.vkGetDeviceProcAddr(s.context.device, "vkQueueSubmit2KHR");
            if (func_khr) |f| {
                s.context.vkQueueSubmit2 = @ptrCast(f);
            }
        }
    }

    if (s.context.vkQueueSubmit2 == null) {
        renderer_log.warn("vkQueueSubmit2 not found via vkGetDeviceProcAddr, falling back to static linking (unsafe if not supported)", .{});
        s.context.vkQueueSubmit2 = c.vkQueueSubmit2;
    }

    if (s.context.vkCmdPipelineBarrier2 == null) {
        const func = c.vkGetDeviceProcAddr(s.context.device, "vkCmdPipelineBarrier2");
        if (func) |f| {
            s.context.vkCmdPipelineBarrier2 = @ptrCast(f);
        } else {
            const func_khr = c.vkGetDeviceProcAddr(s.context.device, "vkCmdPipelineBarrier2KHR");
            if (func_khr) |f| {
                s.context.vkCmdPipelineBarrier2 = @ptrCast(f);
            }
        }
    }

    if (s.context.vkCmdPipelineBarrier2 == null)
        s.context.vkCmdPipelineBarrier2 = c.vkCmdPipelineBarrier2;

    if (s.context.vkCmdBeginRendering == null) {
        const func = c.vkGetDeviceProcAddr(s.context.device, "vkCmdBeginRendering");
        if (func) |f| {
            s.context.vkCmdBeginRendering = @ptrCast(f);
        } else {
            const func_khr = c.vkGetDeviceProcAddr(s.context.device, "vkCmdBeginRenderingKHR");
            if (func_khr) |f| {
                s.context.vkCmdBeginRendering = @ptrCast(f);
            }
        }
    }

    if (s.context.vkCmdBeginRendering == null)
        s.context.vkCmdBeginRendering = c.vkCmdBeginRendering;

    if (s.context.vkCmdEndRendering == null) {
        const func = c.vkGetDeviceProcAddr(s.context.device, "vkCmdEndRendering");
        if (func) |f| {
            s.context.vkCmdEndRendering = @ptrCast(f);
        } else {
            const func_khr = c.vkGetDeviceProcAddr(s.context.device, "vkCmdEndRenderingKHR");
            if (func_khr) |f| {
                s.context.vkCmdEndRendering = @ptrCast(f);
            }
        }
    }

    if (s.context.vkCmdEndRendering == null)
        s.context.vkCmdEndRendering = c.vkCmdEndRendering;
}

fn init_sync_manager(s: *types.VulkanState) bool {
    // Point sync_manager to the embedded sync instance
    // This avoids dual-state issues where one manager resets the semaphore and the other holds a stale handle
    s.sync_manager = &s.sync;

    // Check if initialized (it should be, by vk_create_commands which calls create_sync_objects)
    if (!s.sync.initialized) {
        renderer_log.warn("Sync manager not initialized by commands, initializing now", .{});
        if (!vk_sync_manager.vulkan_sync_manager_init(&s.sync, s.context.device, s.context.graphics_queue, s.sync.max_frames_in_flight, s.config.timeline_max_ahead)) {
            return false;
        }
    }

    renderer_log.info("renderer_create: sync_manager (linked to embedded sync)", .{});
    return true;
}

fn init_pbr_pipeline_helper(s: *types.VulkanState) void {
    s.pipelines.use_pbr_pipeline = false;
    // PBR Pipeline renders to HDR attachment (Float16), not directly to swapchain
    if (vk_pbr.vk_pbr_pipeline_create(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device, s.context.physical_device, c.VK_FORMAT_R16G16B16A16_SFLOAT, s.swapchain.depth_format, s.commands.pools.?[0], s.context.graphics_queue, @ptrCast(&s.allocator), @ptrCast(s), s.pipelines.pipeline_cache)) {
        s.pipelines.use_pbr_pipeline = true;

        // Initialize Depth Pre-pass pipeline
        if (vk_pbr.vk_pbr_create_depth_prepass(s)) {
            renderer_log.info("renderer_create: Depth Pre-pass pipeline", .{});
        } else {
            renderer_log.err("vk_pbr_create_depth_prepass failed", .{});
        }

        renderer_log.info("renderer_create: PBR pipeline", .{});
    } else {
        renderer_log.err("vk_pbr_pipeline_create failed", .{});
    }
}

fn shadow_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    vk_shadows.vk_shadow_render(state, cmd);
}

fn depth_prepass_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    var clears: [2]c.VkClearValue = undefined;
    clears[1].depthStencil.depth = 1.0;
    clears[1].depthStencil.stencil = 0;

    var depth_view: ?c.VkImageView = null;
    var use_depth = false;

    if (state.render_graph) |rg_ptr| {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        if (rg.resources.get(types.RESOURCE_ID_DEPTHBUFFER)) |res| {
            depth_view = res.image_view;
            use_depth = (depth_view != null);
        }
    }

    if (!use_depth) {
        use_depth = state.swapchain.depth_image_view != null and state.swapchain.depth_image != null;
    }

    renderer_log.info("Depth pre-pass frame {d}: use_depth={any}, depth_view={any}", .{ state.sync.current_frame, use_depth, depth_view });

    if (vk_commands.vk_begin_rendering_impl(state, cmd, state.current_image_index, use_depth, depth_view, null, &clears, false, true, 0, false)) {
        if (state.pipelines.use_pbr_pipeline and state.pipelines.depth_pipeline != null) {
            vk_pbr.vk_pbr_render_depth_prepass(state, cmd, state.current_scene, state.sync.current_frame);
        }
        vk_commands.vk_end_rendering(state, cmd);
    }
}

fn ssao_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    if (!state.pipelines.use_ssao or !state.pipelines.ssao_pipeline.initialized) return;
    renderer_log.info("SSAO pass frame {d}: running", .{state.sync.current_frame});
    vk_ssao.vk_ssao_compute(state, cmd, state.sync.current_frame);
}

fn init_mesh_shader_paths(s: *types.VulkanState, mesh_path: *[512]u8, task_path: *[512]u8, frag_path: *[512]u8) void {
    var shaders_dir: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(&s.config.shader_dir)));

    const env_dir_c = c.getenv("CARDINAL_SHADERS_DIR");
    if (env_dir_c != null) {
        shaders_dir = std.mem.span(env_dir_c);
    }

    _ = std.fmt.bufPrintZ(mesh_path, "{s}/mesh.mesh.spv", .{shaders_dir}) catch |err| {
        renderer_log.warn("bufPrintZ failed for mesh shader path: {s}", .{@errorName(err)});
    };
    _ = std.fmt.bufPrintZ(task_path, "{s}/task.task.spv", .{shaders_dir}) catch |err| {
        renderer_log.warn("bufPrintZ failed for task shader path: {s}", .{@errorName(err)});
    };
    _ = std.fmt.bufPrintZ(frag_path, "{s}/mesh.frag.spv", .{shaders_dir}) catch |err| {
        renderer_log.warn("bufPrintZ failed for fragment shader path: {s}", .{@errorName(err)});
    };
}

fn init_mesh_shader_pipeline_helper(s: *types.VulkanState) void {
    s.pipelines.use_mesh_shader_pipeline = false;
    if (!s.context.supports_mesh_shader) {
        renderer_log.info("Mesh shaders not supported on this device", .{});
        return;
    }

    if (!vk_mesh_shader.vk_mesh_shader_init(@ptrCast(s))) {
        renderer_log.err("vk_mesh_shader_init failed", .{});
        return;
    }

    var config = std.mem.zeroes(types.MeshShaderPipelineConfig);

    var mesh_path: [512]u8 = undefined;
    var task_path: [512]u8 = undefined;
    var frag_path: [512]u8 = undefined;

    init_mesh_shader_paths(s, &mesh_path, &task_path, &frag_path);

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

    if (vk_mesh_shader.vk_mesh_shader_create_pipeline(@ptrCast(s), @ptrCast(&config), s.swapchain.format, s.swapchain.depth_format, @ptrCast(&s.pipelines.mesh_shader_pipeline), null)) {
        s.pipelines.use_mesh_shader_pipeline = true;
        renderer_log.info("renderer_create: Mesh shader pipeline", .{});
    } else {
        renderer_log.err("vk_mesh_shader_create_pipeline failed", .{});
    }
}

fn init_compute_pipeline_helper(s: *types.VulkanState) void {
    s.pipelines.compute_shader_initialized = false;
    s.pipelines.compute_descriptor_pool = null;
    s.pipelines.compute_command_pool = null;
    s.pipelines.compute_command_buffer = null;

    if (vk_compute.vk_compute_init(@ptrCast(s))) {
        s.pipelines.compute_shader_initialized = true;
        renderer_log.info("renderer_create: Compute shader support", .{});
    } else {
        renderer_log.err("vk_compute_init failed", .{});
    }
}

fn init_simple_pipelines_helper(s: *types.VulkanState) void {
    s.pipelines.uv_pipeline = null;
    s.pipelines.uv_pipeline_layout = null;
    s.pipelines.wireframe_pipeline = null;
    s.pipelines.wireframe_pipeline_layout = null;
    s.pipelines.simple_descriptor_manager = null;
    s.pipelines.simple_descriptor_set = null;
    s.pipelines.simple_uniform_buffer = std.mem.zeroes(types.VulkanBuffer);

    if (!vk_simple_pipelines.vk_create_simple_pipelines(s, null)) {
        renderer_log.err("vk_create_simple_pipelines failed", .{});
    } else {
        renderer_log.info("renderer_create: simple pipelines", .{});
    }
}

fn init_skybox_pipeline_helper(s: *types.VulkanState) void {
    s.pipelines.use_skybox_pipeline = false;
    if (vk_skybox.vk_skybox_pipeline_init(@ptrCast(&s.pipelines.skybox_pipeline), s.context.device, s.swapchain.format, s.swapchain.depth_format, @ptrCast(&s.allocator), @ptrCast(s))) {
        s.pipelines.use_skybox_pipeline = true;
        renderer_log.info("renderer_create: Skybox pipeline", .{});
    } else {
        renderer_log.err("vk_skybox_pipeline_init failed", .{});
    }
}

fn init_pipelines(s: *types.VulkanState) bool {
    init_pbr_pipeline_helper(s);
    init_mesh_shader_pipeline_helper(s);
    init_compute_pipeline_helper(s);
    init_skybox_pipeline_helper(s);
    // Initialize Post Process Pipeline first so its sampler is available to SSAO
    if (vk_post_process.vk_post_process_init(s)) {
        renderer_log.info("renderer_create: Post Process pipeline", .{});
    } else {
        renderer_log.err("vk_post_process_init failed", .{});
    }

    // Initialize SSAO (depends on post-process sampler)
    if (vk_ssao.vk_ssao_init(s)) {
        renderer_log.info("renderer_create: SSAO pipeline", .{});
    } else {
        renderer_log.err("vk_ssao_init failed", .{});
    }

    // Initialize rendering mode
    s.current_rendering_mode = types.CardinalRenderingMode.NORMAL;

    init_simple_pipelines_helper(s);

    return true;
}

pub export fn cardinal_renderer_create(out_renderer: ?*types.CardinalRenderer, win: ?*window.CardinalWindow, config: ?*const types.RendererConfig) callconv(.c) bool {
    if (out_renderer == null or win == null)
        return false;

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const s_ptr = memory.cardinal_calloc(mem_alloc, 1, @sizeOf(types.VulkanState));
    if (s_ptr == null) return false;
    const s: *types.VulkanState = @ptrCast(@alignCast(s_ptr));

    out_renderer.?._opaque = s;

    // Initialize Config
    if (config) |cfg| {
        s.config = cfg.*;
    } else {
        s.config = .{
            .shader_dir = "assets/shaders".* ++ .{0} ** (64 - "assets/shaders".len),
            .pipeline_dir = "assets/pipelines".* ++ .{0} ** (64 - "assets/pipelines".len),
            .texture_dir = "assets/textures".* ++ .{0} ** (64 - "assets/textures".len),
            .model_dir = "assets/models".* ++ .{0} ** (64 - "assets/models".len),
        };
    }

    // Initialize Render Graph
    const rg_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(render_graph.RenderGraph));
    if (rg_ptr != null) {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        const renderer_alloc = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
        rg.* = render_graph.RenderGraph.init(renderer_alloc);

        // Mesh Shader Prep (runs before rendering)
        const mesh_prep_pass = render_graph.RenderPass.init(renderer_alloc, "MeshShader Prep", (struct {
            fn cb(cmd: c.VkCommandBuffer, vs: *types.VulkanState) void {
                _ = cmd;
                vk_commands.vk_prepare_mesh_shader_rendering(@ptrCast(vs));
            }
        }).cb);
        rg.add_pass(mesh_prep_pass) catch {};

        // Shadow Pass (renders cascaded shadow maps for directional lights)
        var shadow_pass = render_graph.RenderPass.init(renderer_alloc, "Shadow Pass", shadow_pass_callback);
        shadow_pass.use_graphics_queue(s);
        shadow_pass.can_be_culled = false;
        shadow_pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_SHADOW_MAP,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
        }) catch {};
        rg.add_pass(shadow_pass) catch {};

        // Depth Pre-pass
        var depth_pass = render_graph.RenderPass.init(renderer_alloc, "Depth Pre-pass", depth_prepass_pass_callback);
        depth_pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_DEPTHBUFFER,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
        }) catch {};
        rg.add_pass(depth_pass) catch {};

        // SSAO Pass (Compute)
        var ssao_pass = render_graph.RenderPass.init(renderer_alloc, "SSAO Pass", ssao_pass_callback);
        if (s.config.enable_async_compute) {
            ssao_pass.use_compute_queue(s);
        }
        ssao_pass.add_input(renderer_alloc, .{
            .id = types.RESOURCE_ID_DEPTHBUFFER,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_SHADER_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
        }) catch {};
        ssao_pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_SSAO_BLURRED,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_SHADER_WRITE_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
            .layout = c.VK_IMAGE_LAYOUT_GENERAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch {};
        rg.add_pass(ssao_pass) catch {};

        // Add PBR Pass
        var pass = render_graph.RenderPass.init(renderer_alloc, "PBR Pass", pbr_pass_callback);

        pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_HDR_COLOR,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch |err| {
            renderer_log.err("Failed to add PBR pass color output: {s}", .{@errorName(err)});
        };

        pass.add_input(renderer_alloc, .{
            .id = types.RESOURCE_ID_DEPTHBUFFER,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
        }) catch {
            renderer_log.err("Failed to add PBR pass depth input", .{});
        };
        pass.add_input(renderer_alloc, .{
            .id = types.RESOURCE_ID_SHADOW_MAP,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_SHADER_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
        }) catch {
            renderer_log.err("Failed to add PBR pass shadow map input", .{});
        };
        pass.add_input(renderer_alloc, .{
            .id = types.RESOURCE_ID_SSAO_BLURRED,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_SHADER_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch {};

        pass.use_graphics_queue(s);
        rg.add_pass(pass) catch {
            renderer_log.err("Failed to add PBR pass", .{});
        };

        // Bloom Compute Pass
        var bloom_pass = render_graph.RenderPass.init(renderer_alloc, "Bloom Compute Pass", bloom_compute_pass_callback);
        if (s.config.enable_async_compute) {
            bloom_pass.use_compute_queue(s);
        }
        bloom_pass.add_input(renderer_alloc, .{
            .id = types.RESOURCE_ID_HDR_COLOR,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_SHADER_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
            .layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch {};
        bloom_pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_BLOOM,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_SHADER_WRITE_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
            .layout = c.VK_IMAGE_LAYOUT_GENERAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch {};
        rg.add_pass(bloom_pass) catch {};

        // Add Post Process Composite Pass
        var pp_pass = render_graph.RenderPass.init(renderer_alloc, "PostProcess Pass", post_process_pass_callback);

        pp_pass.add_input(renderer_alloc, .{
            .id = types.RESOURCE_ID_HDR_COLOR,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_SHADER_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch |err| {
            renderer_log.err("Failed to add PostProcess pass HDR input: {s}", .{@errorName(err)});
        };
        pp_pass.add_input(renderer_alloc, .{
            .id = types.RESOURCE_ID_BLOOM,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_SHADER_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch |err| {
            renderer_log.err("Failed to add PostProcess pass bloom input: {s}", .{@errorName(err)});
        };

        pp_pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_BACKBUFFER,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch |err| {
            renderer_log.err("Failed to add PostProcess pass output: {s}", .{@errorName(err)});
        };

        pp_pass.use_graphics_queue(s);
        rg.add_pass(pp_pass) catch {
            renderer_log.err("Failed to add PostProcess pass", .{});
        };

        var skybox_pass = render_graph.RenderPass.init(renderer_alloc, "Skybox Pass", skybox_pass_callback);
        skybox_pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_BACKBUFFER,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch {};
        skybox_pass.use_graphics_queue(s);
        rg.add_pass(skybox_pass) catch {};

        var ui_pass = render_graph.RenderPass.init(renderer_alloc, "UI Pass", ui_pass_callback);
        ui_pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_BACKBUFFER,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch {};
        ui_pass.use_graphics_queue(s);
        rg.add_pass(ui_pass) catch {};

        var present_pass = render_graph.RenderPass.init(renderer_alloc, "Present Pass", present_pass_callback);
        present_pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_BACKBUFFER,
            .type = .Image,
            .access_mask = 0,
            .stage_mask = c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
            .layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch {};
        present_pass.use_graphics_queue(s);
        rg.add_pass(present_pass) catch {};

        rg.compile() catch {
            renderer_log.err("Failed to compile render graph", .{});
        };
        renderer_log.info("Render Graph initialized: passes={d}", .{rg.passes.items.len});

        s.render_graph = rg;
    } else {
        renderer_log.err("Failed to allocate render graph", .{});
        return false;
    }

    // Initialize device loss recovery state
    s.recovery.device_lost = false;
    s.recovery.recovery_in_progress = false;
    s.recovery.attempt_count = 0;
    s.recovery.max_attempts = 3;
    s.recovery.window = @ptrCast(win);
    s.recovery.device_loss_callback = null;
    s.recovery.recovery_complete_callback = null;
    s.recovery.callback_user_data = null;

    // Register window resize callback
    win.?.resize_callback = vk_handle_window_resize;
    win.?.resize_user_data = s;

    // Initialize Material System
    const mat_sys_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(@import("vulkan_material_system.zig").MaterialSystem));
    if (mat_sys_ptr) |ptr| {
        const mat_sys = @as(*@import("vulkan_material_system.zig").MaterialSystem, @ptrCast(@alignCast(ptr)));
        const renderer_alloc = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
        mat_sys.* = @import("vulkan_material_system.zig").MaterialSystem.init(renderer_alloc);
        s.material_system = ptr;
        renderer_log.info("Material system initialized", .{});
    } else {
        renderer_log.err("Failed to allocate material system", .{});
        return false;
    }

    if (!init_vulkan_core(s, win))
        return false;

    // Load vkGetBufferDeviceAddress for VMA
    const vkGetBufferDeviceAddress = @as(c.PFN_vkGetBufferDeviceAddress, @ptrCast(c.vkGetDeviceProcAddr(s.context.device, "vkGetBufferDeviceAddress")));

    // Initialize VMA allocator
    if (!vk_allocator.init(&s.allocator, s.context.instance, s.context.physical_device, s.context.device, null, // vkGetDeviceBufferMemoryRequirements
        null, // vkGetDeviceImageMemoryRequirements
        vkGetBufferDeviceAddress, null, null, false))
    {
        renderer_log.err("Failed to initialize VMA allocator", .{});
        return false;
    }

    if (!init_ref_counting())
        return false;

    if (!vk_swapchain.vk_create_swapchain(@ptrCast(@alignCast(s)))) {
        renderer_log.err("vk_create_swapchain failed", .{});
        ref_counting.cardinal_ref_counting_shutdown();
        return false;
    }
    renderer_log.warn("renderer_create: swapchain created", .{});

    if (!vk_pipeline.vk_create_pipeline(@ptrCast(@alignCast(s)))) {
        renderer_log.err("vk_create_pipeline failed", .{});
        return false;
    }
    renderer_log.warn("renderer_create: pipeline created", .{});

    if (!vk_commands.vk_create_commands_sync(@ptrCast(@alignCast(s)))) {
        renderer_log.err("vk_create_commands_sync failed", .{});
        return false;
    }
    renderer_log.info("renderer_create: commands", .{});

    setup_function_pointers(s);

    if (!init_sync_manager(s))
        return false;
    if (!init_pipelines(s))
        return false;

    // Initialize barrier validation system
    if (!vk_barrier_validation.cardinal_barrier_validation_init(1000, false)) {
        renderer_log.err("cardinal_barrier_validation_init failed", .{});
        // Continue anyway, validation is optional
    } else {
        renderer_log.info("renderer_create: barrier validation", .{});
    }

    return true;
}

pub export fn cardinal_renderer_create_headless(out_renderer: ?*types.CardinalRenderer, width: u32, height: u32) callconv(.c) bool {
    if (out_renderer == null)
        return false;

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const s_ptr = memory.cardinal_calloc(mem_alloc, 1, @sizeOf(types.VulkanState));
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

    // Initialize Render Graph
    const rg_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(render_graph.RenderGraph));
    if (rg_ptr != null) {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        const renderer_alloc = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
        rg.* = render_graph.RenderGraph.init(renderer_alloc);

        // Add PBR Pass
        var pass = render_graph.RenderPass.init(renderer_alloc, "PBR Pass", pbr_pass_callback);

        pass.add_output(renderer_alloc, .{
            .id = types.RESOURCE_ID_BACKBUFFER,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        }) catch |err| {
            renderer_log.err("Failed to add PBR pass backbuffer output: {s}", .{@errorName(err)});
        };

        pass.add_input(renderer_alloc, .{
            .id = types.RESOURCE_ID_DEPTHBUFFER,
            .type = .Image,
            .access_mask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT,
            .stage_mask = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            .aspect_mask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
        }) catch {
            renderer_log.err("Failed to add PBR pass depth input", .{});
        };

        rg.add_pass(pass) catch {
            renderer_log.err("Failed to add PBR pass", .{});
        };

        rg.compile() catch {
            renderer_log.err("Failed to compile render graph", .{});
        };

        s.render_graph = rg;
    } else {
        renderer_log.err("Failed to allocate render graph", .{});
        return false;
    }

    renderer_log.warn("renderer_create_headless: begin", .{});
    if (!vk_instance.vk_create_instance(@ptrCast(s))) {
        renderer_log.err("vk_create_instance failed", .{});
        return false;
    }
    if (!vk_instance.vk_pick_physical_device(@ptrCast(s))) {
        renderer_log.err("vk_pick_physical_device failed", .{});
        return false;
    }
    if (!vk_instance.vk_create_device(@ptrCast(s))) {
        renderer_log.err("vk_create_device failed", .{});
        return false;
    }

    if (!vk_commands.vk_create_commands_sync(@ptrCast(s))) {
        renderer_log.err("vk_create_commands_sync failed", .{});
        return false;
    }

    const sync_mgr_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanSyncManager));
    if (sync_mgr_ptr == null) {
        renderer_log.err("Failed to allocate VulkanSyncManager", .{});
        return false;
    }
    s.sync_manager = @ptrCast(@alignCast(sync_mgr_ptr));

    if (!vk_sync_manager.vulkan_sync_manager_init(@ptrCast(s.sync_manager), s.context.device, s.context.graphics_queue, s.sync.max_frames_in_flight, s.config.timeline_max_ahead)) {
        renderer_log.err("vulkan_sync_manager_init failed", .{});
        memory.cardinal_free(mem_alloc, s.sync_manager);
        s.sync_manager = null;
        return false;
    }

    renderer_log.info("renderer_create_headless: success", .{});
    return true;
}

pub export fn cardinal_renderer_set_skip_present(renderer: ?*types.CardinalRenderer, skip: bool) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;
    s.swapchain.skip_present = skip;
}

pub export fn cardinal_renderer_set_headless_mode(renderer: ?*types.CardinalRenderer, enable: bool) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;
    s.swapchain.headless_mode = enable;
}

pub export fn cardinal_renderer_wait_idle(renderer: ?*types.CardinalRenderer) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;
    _ = c.vkDeviceWaitIdle(s.context.device);
}

pub export fn cardinal_renderer_wait_for_texture_uploads(renderer: ?*types.CardinalRenderer) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;
    if (s.pipelines.pbr_pipeline.textureManager) |mgr| {
        vk_texture_manager.vk_texture_manager_wait_idle(mgr);
    }
}

pub fn destroy_scene_buffers(vs: *types.VulkanState) void {
    renderer_log.info("destroy_scene_buffers: start", .{});

    // Ensure GPU has finished using previous scene buffers before destroying them.
    // We force a device wait idle here to be absolutely safe against race conditions and GPU usage.
    if (vs.context.device != null and !vs.recovery.device_lost) {
        renderer_log.info("destroy_scene_buffers: Calling vkDeviceWaitIdle to ensure safety", .{});
        const idle_res = c.vkDeviceWaitIdle(vs.context.device);
        if (idle_res != c.VK_SUCCESS) {
            renderer_log.err("destroy_scene_buffers: vkDeviceWaitIdle failed with {d}", .{idle_res});
            // We proceed, but expect trouble if device is lost.
        }
    }

    if (vs.scene_meshes == null) {
        renderer_log.info("destroy_scene_buffers: No meshes to destroy", .{});
        return;
    }

    renderer_log.info("destroy_scene_buffers: Destroying {d} meshes", .{vs.scene_mesh_count});

    var i: u32 = 0;
    while (i < vs.scene_mesh_count) : (i += 1) {
        var m = &vs.scene_meshes.?[i];
        if (m.vbuf != null) {
            renderer_log.debug("Destroying mesh {d} vbuf handle={any} alloc={any}", .{ i, m.vbuf, m.v_allocation });
            vk_allocator.free_buffer(@ptrCast(&vs.allocator), m.vbuf, m.v_allocation);
            m.vbuf = null;
            m.vmem = null;
            m.v_allocation = null;
        }
        if (m.ibuf != null) {
            renderer_log.debug("Destroying mesh {d} ibuf handle={any} alloc={any}", .{ i, m.ibuf, m.i_allocation });
            vk_allocator.free_buffer(@ptrCast(&vs.allocator), m.ibuf, m.i_allocation);
            m.ibuf = null;
            m.imem = null;
            m.i_allocation = null;
        }
    }
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    memory.cardinal_free(mem_alloc, vs.scene_meshes);
    vs.scene_meshes = null;
    vs.scene_mesh_count = 0;
    renderer_log.info("destroy_scene_buffers: completed", .{});
}

pub export fn cardinal_renderer_destroy(renderer: ?*types.CardinalRenderer) callconv(.c) void {
    if (renderer == null or renderer.?._opaque == null) return;
    const s = get_state(renderer) orelse return;

    renderer_log.info("Starting renderer destruction", .{});

    // destroy in reverse order
    destroy_scene_buffers(s);

    // Process deferred cleanups (buffers, images, command buffers) BEFORE destroying command pools
    vk_texture_utils.shutdown_staging_buffer_cleanups(&s.allocator);

    // Cleanup VulkanSyncManager
    if (s.sync_manager != null) {
        renderer_log.debug("Cleaning up sync manager pointer", .{});
        s.sync_manager = null;
    }

    // Cleanup compute shader support
    if (s.pipelines.compute_shader_initialized) {
        vk_compute.vk_compute_cleanup(@ptrCast(s));
        s.pipelines.compute_shader_initialized = false;
    }

    // Shutdown barrier validation system
    vk_barrier_validation.cardinal_barrier_validation_shutdown();

    // Destroy SSAO pipeline
    if (s.pipelines.use_ssao) {
        renderer_log.debug("Destroying SSAO pipeline", .{});
        vk_ssao.vk_ssao_destroy(s);
    }

    // Destroy simple pipelines
    renderer_log.debug("Destroying simple pipelines", .{});
    vk_simple_pipelines.vk_destroy_simple_pipelines(s);

    // Wait for all GPU operations to complete before destroying PBR pipeline
    if (s.context.device != null) {
        _ = c.vkDeviceWaitIdle(s.context.device);
    }

    // Destroy PBR pipeline
    if (s.pipelines.use_pbr_pipeline) {
        renderer_log.debug("Destroying PBR pipeline", .{});
        vk_pbr.vk_pbr_pipeline_destroy(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device, @ptrCast(&s.allocator));
        s.pipelines.use_pbr_pipeline = false;

        // Destroy Depth Pipeline
        if (s.pipelines.depth_pipeline != null) {
            c.vkDestroyPipeline(s.context.device, s.pipelines.depth_pipeline, null);
            s.pipelines.depth_pipeline = null;
        }
        if (s.pipelines.depth_pipeline_layout != null) {
            c.vkDestroyPipelineLayout(s.context.device, s.pipelines.depth_pipeline_layout, null);
            s.pipelines.depth_pipeline_layout = null;
        }
    }

    // Destroy Skybox pipeline
    if (s.pipelines.use_skybox_pipeline) {
        renderer_log.debug("Destroying Skybox pipeline", .{});
        vk_skybox.vk_skybox_pipeline_destroy(@ptrCast(&s.pipelines.skybox_pipeline), s.context.device, @ptrCast(&s.allocator));
        s.pipelines.use_skybox_pipeline = false;
    }

    // Destroy mesh shader pipeline BEFORE destroying allocator
    // Always cleanup mesh shader resources if they were initialized (checked inside cleanup)
    renderer_log.debug("Destroying mesh shader pipeline", .{});
    vk_mesh_shader.vk_mesh_shader_cleanup(@ptrCast(s));
    s.pipelines.use_mesh_shader_pipeline = false;

    // Destroy Post Process pipeline
    renderer_log.debug("Destroying Post Process pipeline", .{});
    vk_post_process.vk_post_process_destroy(s);
    s.pipelines.use_post_process = false;

    renderer_log.debug("Destroying base pipeline resources", .{});
    vk_pipeline.vk_destroy_pipeline(@ptrCast(s));
    vk_swapchain.vk_destroy_swapchain(@ptrCast(s));

    // Destroy Render Graph
    if (s.render_graph) |rg_ptr| {
        renderer_log.debug("Destroying Render Graph", .{});
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        rg.destroy_transient_resources(s);
        rg.deinit();

        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, rg);
        s.render_graph = null;
    }

    // Destroy Material System
    if (s.material_system) |ms_ptr| {
        renderer_log.debug("Destroying Material System", .{});
        const mat_sys = @as(*@import("vulkan_material_system.zig").MaterialSystem, @ptrCast(@alignCast(ms_ptr)));
        mat_sys.deinit();
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, ms_ptr);
        s.material_system = null;
    }

    // Destroy shader cache
    vk_pso.vk_pso_cleanup_shader_cache(s.context.device);

    // Shutdown pending texture/buffer cleanups
    vk_texture_utils.shutdown_staging_buffer_cleanups(&s.allocator);

    // Shutdown VMA allocator before destroying device
    vk_allocator.shutdown(&s.allocator);

    // Ensure all device objects are destroyed before instance
    vk_commands.vk_destroy_commands_sync(@ptrCast(s));

    vk_instance.vk_destroy_device_objects(@ptrCast(s));

    renderer_log.info("Freeing renderer state", .{});
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    memory.cardinal_free(mem_alloc, s);
    renderer.?._opaque = null;
}

pub export fn cardinal_renderer_internal_current_cmd(renderer: ?*types.CardinalRenderer, image_index: u32) callconv(.c) c.VkCommandBuffer {
    const s = get_state(renderer) orelse return null;
    _ = image_index;
    return s.commands.buffers.?[s.sync.current_frame];
}

pub export fn cardinal_renderer_internal_device(renderer: ?*types.CardinalRenderer) callconv(.c) c.VkDevice {
    const s = get_state(renderer) orelse return null;
    return s.context.device;
}

pub export fn cardinal_renderer_internal_physical_device(renderer: ?*types.CardinalRenderer) callconv(.c) c.VkPhysicalDevice {
    const s = get_state(renderer) orelse return null;
    return s.context.physical_device;
}

pub export fn cardinal_renderer_internal_graphics_queue(renderer: ?*types.CardinalRenderer) callconv(.c) c.VkQueue {
    const s = get_state(renderer) orelse return null;
    return s.context.graphics_queue;
}

fn create_perspective_matrix(fov: f32, aspect: f32, near_plane: f32, far_plane: f32, matrix: [*]f32) void {
    const m = math.Mat4.perspective(fov * std.math.pi / 180.0, aspect, near_plane, far_plane);
    @memcpy(matrix[0..16], &m.data);
}

fn create_view_matrix(eye: [*]const f32, center: [*]const f32, up: [*]const f32, matrix: [*]f32) void {
    const eye_v = math.Vec3.fromArray(eye[0..3].*);
    const center_v = math.Vec3.fromArray(center[0..3].*);
    const up_v = math.Vec3.fromArray(up[0..3].*);

    const m = math.Mat4.lookAt(eye_v, center_v, up_v);
    @memcpy(matrix[0..16], &m.data);
}

pub export fn cardinal_renderer_set_camera(renderer: ?*types.CardinalRenderer, camera: ?*const types.CardinalCamera) callconv(.c) void {
    if (renderer == null or camera == null) return;
    const s = get_state(renderer) orelse return;
    const cam = camera.?;

    if (!s.pipelines.use_pbr_pipeline) return;

    var ubo = std.mem.zeroes(types.PBRUniformBufferObject);

    // Create model matrix (identity for now)
    // transform.cardinal_matrix_identity(&ubo.model);

    // Create view matrix
    create_view_matrix(@ptrCast(&cam.position), @ptrCast(&cam.target), @ptrCast(&cam.up), &ubo.view);

    // Create projection matrix
    create_perspective_matrix(cam.fov, cam.aspect, cam.near_plane, cam.far_plane, &ubo.proj);

    // Set view position
    ubo.viewPos[0] = cam.position.x;
    ubo.viewPos[1] = cam.position.y;
    ubo.viewPos[2] = cam.position.z;

    // Set debug flags from pipeline state
    ubo.debugFlags = s.pipelines.pbr_pipeline.debug_flags;

    // Set ambient color from config
    ubo.ambientColor = s.config.pbr_ambient_color;

    // Update the stored UBO state
    s.pipelines.pbr_pipeline.current_ubo = ubo;
}

pub export fn cardinal_renderer_set_debug_flags(renderer: ?*types.CardinalRenderer, flags: f32) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;

    if (!s.pipelines.use_pbr_pipeline) return;

    // Update stored state
    s.pipelines.pbr_pipeline.debug_flags = flags;
    s.pipelines.pbr_pipeline.current_ubo.debugFlags = flags;
}

pub export fn cardinal_renderer_set_lights(renderer: ?*types.CardinalRenderer, lights: ?[*]const types.PBRLight, count: u32) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;

    if (!s.pipelines.use_pbr_pipeline) return;

    var lighting = std.mem.zeroes(types.PBRLightingBuffer);
    lighting.count = if (count > types.MAX_LIGHTS) types.MAX_LIGHTS else count;

    if (lights != null and count > 0) {
        var i: u32 = 0;
        while (i < lighting.count) : (i += 1) {
            lighting.lights[i] = lights.?[i];
        }
    }

    // Update stored lighting state
    s.pipelines.pbr_pipeline.current_lighting = lighting;
}

pub export fn cardinal_renderer_set_lighting(renderer: ?*types.CardinalRenderer, light: ?*const types.CardinalLight) callconv(.c) void {
    if (renderer == null or light == null) return;
    const s = get_state(renderer) orelse return;
    const l = light.?;

    if (!s.pipelines.use_pbr_pipeline) return;

    var lighting = std.mem.zeroes(types.PBRLightingBuffer);
    lighting.count = 1;

    // Set light direction
    lighting.lights[0].lightDirection[0] = l.direction.x;
    lighting.lights[0].lightDirection[1] = l.direction.y;
    lighting.lights[0].lightDirection[2] = l.direction.z;
    lighting.lights[0].lightDirection[3] = @floatFromInt(l.type);

    // Set light position
    lighting.lights[0].lightPosition[0] = l.position.x;
    lighting.lights[0].lightPosition[1] = l.position.y;
    lighting.lights[0].lightPosition[2] = l.position.z;
    lighting.lights[0].lightPosition[3] = 0.0;

    // Set light color and intensity
    lighting.lights[0].lightColor[0] = l.color.x;
    lighting.lights[0].lightColor[1] = l.color.y;
    lighting.lights[0].lightColor[2] = l.color.z;
    lighting.lights[0].lightColor[3] = l.intensity;

    // Set light params
    lighting.lights[0].params[0] = l.range;
    lighting.lights[0].params[1] = @cos(l.inner_cone);
    lighting.lights[0].params[2] = @cos(l.outer_cone);
    lighting.lights[0].params[3] = 0.0;

    // Update stored lighting state
    s.pipelines.pbr_pipeline.current_lighting = lighting;
}

pub export fn cardinal_renderer_set_skybox_from_data(renderer: ?*types.CardinalRenderer, data: ?*texture_loader.TextureData) callconv(.c) bool {
    if (renderer == null or data == null) return false;
    const s = get_state(renderer) orelse return false;

    if (!s.pipelines.use_skybox_pipeline) {
        renderer_log.warn("Skybox pipeline not enabled", .{});
        return false;
    }

    return vk_skybox.vk_skybox_load_from_data(@ptrCast(&s.pipelines.skybox_pipeline), s.context.device, @ptrCast(&s.allocator), s.commands.pools.?[0], s.context.graphics_queue, s.sync_manager, data.?.*);
}

pub export fn cardinal_renderer_set_skybox(renderer: ?*types.CardinalRenderer, path: ?[*:0]const u8) callconv(.c) bool {
    if (renderer == null or path == null) return false;
    const s = get_state(renderer) orelse return false;

    if (!s.pipelines.use_skybox_pipeline) {
        renderer_log.warn("Skybox pipeline not enabled", .{});
        return false;
    }

    const path_slice = std.mem.span(path.?);
    return vk_skybox.vk_skybox_load(@ptrCast(&s.pipelines.skybox_pipeline), s.context.device, @ptrCast(&s.allocator), s.commands.pools.?[0], s.context.graphics_queue, s.sync_manager, path_slice);
}

pub export fn cardinal_renderer_enable_pbr(renderer: ?*types.CardinalRenderer, enable: bool) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;

    if (enable and !s.pipelines.use_pbr_pipeline) {
        if (s.pipelines.pbr_pipeline.initialized) {
            // Wait for device idle before destroying pipeline resources
            _ = c.vkDeviceWaitIdle(s.context.device);
            vk_pbr.vk_pbr_pipeline_destroy(@ptrCast(&s.pipelines.pbr_pipeline), @ptrCast(s.context.device), @ptrCast(&s.allocator));
        }

        if (vk_pbr.vk_pbr_pipeline_create(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device, s.context.physical_device, c.VK_FORMAT_R16G16B16A16_SFLOAT, s.swapchain.depth_format, s.commands.pools.?[0], s.context.graphics_queue, @ptrCast(&s.allocator), @ptrCast(s), s.pipelines.pipeline_cache)) {
            s.pipelines.use_pbr_pipeline = true;

            // Initialize Depth Pre-pass pipeline
            if (vk_pbr.vk_pbr_create_depth_prepass(s)) {
                renderer_log.info("Depth Pre-pass pipeline enabled", .{});
            } else {
                renderer_log.err("vk_pbr_create_depth_prepass failed", .{});
            }

            if (s.current_scene != null) {
                if (!vk_pbr.vk_pbr_load_scene(@ptrCast(&s.pipelines.pbr_pipeline), @ptrCast(s.context.device), @ptrCast(s.context.physical_device), @ptrCast(s.commands.pools.?[0]), @ptrCast(s.context.graphics_queue), @ptrCast(s.current_scene), @ptrCast(&s.allocator), @ptrCast(@alignCast(s)))) {
                    renderer_log.err("Failed to load scene into PBR pipeline", .{});
                }
            }

            renderer_log.info("PBR pipeline enabled", .{});
        } else {
            renderer_log.err("Failed to enable PBR pipeline", .{});
        }
    } else if (!enable and s.pipelines.use_pbr_pipeline) {
        // Wait for device idle before destroying pipeline resources
        _ = c.vkDeviceWaitIdle(s.context.device);
        vk_pbr.vk_pbr_pipeline_destroy(@ptrCast(&s.pipelines.pbr_pipeline), @ptrCast(s.context.device), @ptrCast(&s.allocator));
        s.pipelines.use_pbr_pipeline = false;

        // Destroy Depth Pipeline
        if (s.pipelines.depth_pipeline != null) {
            c.vkDestroyPipeline(s.context.device, s.pipelines.depth_pipeline, null);
            s.pipelines.depth_pipeline = null;
        }
        if (s.pipelines.depth_pipeline_layout != null) {
            c.vkDestroyPipelineLayout(s.context.device, s.pipelines.depth_pipeline_layout, null);
            s.pipelines.depth_pipeline_layout = null;
        }

        renderer_log.info("PBR pipeline disabled", .{});
    }
}

pub export fn cardinal_renderer_is_pbr_enabled(renderer: ?*types.CardinalRenderer) callconv(.c) bool {
    if (renderer == null) return false;
    const s = get_state(renderer) orelse return false;
    return s.pipelines.use_pbr_pipeline;
}

pub export fn cardinal_renderer_enable_mesh_shader(renderer: ?*types.CardinalRenderer, enable: bool) callconv(.c) void {
    if (renderer == null) return;
    const s = get_state(renderer) orelse return;

    if (enable and !s.pipelines.use_mesh_shader_pipeline and s.context.supports_mesh_shader) {
        var config = std.mem.zeroes(types.MeshShaderPipelineConfig);

        var mesh_path: [512]u8 = undefined;
        var task_path: [512]u8 = undefined;
        var frag_path: [512]u8 = undefined;

        init_mesh_shader_paths(s, &mesh_path, &task_path, &frag_path);

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

        if (vk_mesh_shader.vk_mesh_shader_create_pipeline(@ptrCast(@alignCast(s)), @ptrCast(&config), @as(c.VkFormat, c.VK_FORMAT_R16G16B16A16_SFLOAT), s.swapchain.depth_format, @ptrCast(&s.pipelines.mesh_shader_pipeline), s.pipelines.pipeline_cache)) {
            s.pipelines.use_mesh_shader_pipeline = true;
            renderer_log.info("Mesh shader pipeline enabled", .{});
        } else {
            renderer_log.err("Failed to enable mesh shader pipeline", .{});
        }
    } else if (!enable and s.pipelines.use_mesh_shader_pipeline) {
        // Wait for device idle before destroying pipeline resources
        _ = c.vkDeviceWaitIdle(s.context.device);
        vk_mesh_shader.vk_mesh_shader_destroy_pipeline(@ptrCast(@alignCast(s)), @ptrCast(&s.pipelines.mesh_shader_pipeline));
        s.pipelines.use_mesh_shader_pipeline = false;
        renderer_log.info("Mesh shader pipeline disabled", .{});
    } else if (enable and !s.context.supports_mesh_shader) {
        renderer_log.warn("Mesh shaders not supported on this device", .{});
    }
}

pub export fn cardinal_renderer_is_mesh_shader_enabled(renderer: ?*types.CardinalRenderer) callconv(.c) bool {
    if (renderer == null) return false;
    const s = get_state(renderer) orelse return false;
    return s.pipelines.use_mesh_shader_pipeline;
}

pub export fn cardinal_renderer_supports_mesh_shader(renderer: ?*types.CardinalRenderer) callconv(.c) bool {
    if (renderer == null) return false;
    const s = get_state(renderer) orelse return false;
    return s.context.supports_mesh_shader;
}

pub export fn cardinal_renderer_internal_graphics_queue_family(renderer: ?*types.CardinalRenderer) callconv(.c) u32 {
    const s = get_state(renderer) orelse return 0;
    return s.context.graphics_queue_family;
}

pub export fn cardinal_renderer_internal_instance(renderer: ?*types.CardinalRenderer) callconv(.c) c.VkInstance {
    const s = get_state(renderer) orelse return null;
    return s.context.instance;
}

pub export fn cardinal_renderer_internal_swapchain_image_count(renderer: ?*types.CardinalRenderer) callconv(.c) u32 {
    const s = get_state(renderer) orelse return 0;
    return s.swapchain.image_count;
}

pub export fn cardinal_renderer_internal_swapchain_format(renderer: ?*types.CardinalRenderer) callconv(.c) c.VkFormat {
    const s = get_state(renderer) orelse return c.VK_FORMAT_UNDEFINED;
    return s.swapchain.format;
}

pub export fn cardinal_renderer_internal_depth_format(renderer: ?*types.CardinalRenderer) callconv(.c) c.VkFormat {
    const s = get_state(renderer) orelse return c.VK_FORMAT_UNDEFINED;
    return s.swapchain.depth_format;
}

pub export fn cardinal_renderer_internal_swapchain_extent(renderer: ?*types.CardinalRenderer) callconv(.c) c.VkExtent2D {
    const s = get_state(renderer) orelse return c.VkExtent2D{ .width = 0, .height = 0 };
    return s.swapchain.extent;
}

pub export fn cardinal_renderer_set_ui_callback(renderer: ?*types.CardinalRenderer, callback: ?*const fn (c.VkCommandBuffer) callconv(.c) void) callconv(.c) void {
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

        // Use synchronized submit
        const submit_result = vk_sync_manager.vulkan_sync_manager_submit_queue2(s.context.graphics_queue, 1, @ptrCast(&submit2), null, s.context.vkQueueSubmit2);

        if (submit_result == c.VK_SUCCESS) {
            // Wait for completion using timeline semaphore
            const wait_result = vk_sync_manager.vulkan_sync_manager_wait_timeline(sm, timeline_value, c.UINT64_MAX);
            if (wait_result == c.VK_SUCCESS) {
                const free_pool: c.VkCommandPool = if (s.commands.transient_pools != null) s.commands.transient_pools.?[s.sync.current_frame] else s.commands.pools.?[s.sync.current_frame];
                c.vkFreeCommandBuffers(s.context.device, free_pool, 1, &cmd);
            } else {
                renderer_log.warn("Timeline wait failed for immediate submit: {d}", .{wait_result});
            }
        } else {
            renderer_log.err("Failed to submit immediate command buffer: {d}", .{submit_result});
        }
    } else {
        // Fallback to old method if sync manager not available
        _ = vk_sync_manager.vulkan_sync_manager_submit_queue2(s.context.graphics_queue, 1, @ptrCast(&submit2), null, s.context.vkQueueSubmit2);
        const wait_result = c.vkQueueWaitIdle(s.context.graphics_queue);

        if (wait_result == c.VK_SUCCESS) {
            const free_pool: c.VkCommandPool = if (s.commands.transient_pools != null) s.commands.transient_pools.?[s.sync.current_frame] else s.commands.pools.?[s.sync.current_frame];
            c.vkFreeCommandBuffers(s.context.device, free_pool, 1, &cmd);
        } else {
            renderer_log.warn("Skipping command buffer free due to queue wait failure: {d}", .{wait_result});
        }
    }
}

pub export fn cardinal_renderer_immediate_submit(renderer: ?*types.CardinalRenderer, record: ?*const fn (c.VkCommandBuffer) callconv(.c) void) callconv(.c) void {
    const s = get_state(renderer) orelse return;

    var ai = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = if (s.commands.transient_pools != null) s.commands.transient_pools.?[s.sync.current_frame] else s.commands.pools.?[s.sync.current_frame],
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
    if (!mt_manager.thread_pools.?[0].is_active) {
        return false;
    }

    var ai = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = if (s.commands.transient_pools != null) s.commands.transient_pools.?[s.sync.current_frame] else s.commands.pools.?[s.sync.current_frame],
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
    if (!vk_commands.vulkan_mt.cardinal_mt_allocate_secondary_command_buffer(&mt_manager.thread_pools.?[0], &secondary_context)) {
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
    inheritance_info.queryFlags = 0;
    inheritance_info.pipelineStatistics = 0;

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

    // Set VK_RENDERING_CONTENTS_SECONDARY_COMMAND_BUFFERS_BIT when beginning rendering
    // This is required when executing secondary command buffers inside a dynamic rendering instance
    var rendering_info = std.mem.zeroes(c.VkRenderingInfo);
    rendering_info.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
    rendering_info.renderArea.extent = s.swapchain.extent;
    rendering_info.layerCount = 1;
    rendering_info.colorAttachmentCount = 1;
    rendering_info.flags = c.VK_RENDERING_CONTENTS_SECONDARY_COMMAND_BUFFERS_BIT;

    var color_attachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
    color_attachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    // Use the current frame's image view. Note: This assumes the image is available and in a compatible layout.
    // Since try_submit_secondary is often used for immediate operations, we might need to be careful about layout.
    // However, if the secondary buffer expects to draw, it needs a valid attachment.
    color_attachment.imageView = s.swapchain.image_views.?[s.sync.current_frame];
    color_attachment.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_LOAD;
    color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;

    rendering_info.pColorAttachments = &color_attachment;

    c.vkCmdBeginRendering(primary_cmd, &rendering_info);

    const contexts = @as([*]types.CardinalSecondaryCommandContext, @ptrCast(&secondary_context))[0..1];
    vk_commands.vulkan_mt.cardinal_mt_execute_secondary_command_buffers(primary_cmd, contexts);

    c.vkCmdEndRendering(primary_cmd);

    _ = c.vkEndCommandBuffer(primary_cmd);

    submit_and_wait(s, primary_cmd);
    return true;
}

pub export fn cardinal_renderer_immediate_submit_with_secondary(renderer: ?*types.CardinalRenderer, record: ?*const fn (c.VkCommandBuffer) callconv(.c) void, use_secondary: bool) callconv(.c) void {
    const s = get_state(renderer) orelse return;

    if (use_secondary) {
        if (try_submit_secondary(s, record)) {
            return;
        }
        renderer_log.warn("Secondary command buffer failed, falling back to primary", .{});
    }

    cardinal_renderer_immediate_submit(renderer, record);
}

pub export fn cardinal_renderer_upload_scene(renderer: ?*types.CardinalRenderer, scene: ?*const types.CardinalScene) callconv(.c) void {
    const s = get_state(renderer) orelse return;

    renderer_log.info("Starting scene upload; meshes={d}", .{if (scene != null) scene.?.mesh_count else 0});

    if (s.swapchain.recreation_pending or s.swapchain.window_resize_pending or
        s.recovery.recovery_in_progress or s.recovery.device_lost)
    {
        s.pending_scene_upload = @ptrCast(@constCast(scene));
        s.scene_upload_pending = true;
        renderer_log.warn("Deferring scene upload due to swapchain/recovery state", .{});
        return;
    }

    if (s.context.vkGetSemaphoreCounterValue != null and s.sync.timeline_semaphore != null) {
        var sem_val: u64 = 0;
        const sem_res = s.context.vkGetSemaphoreCounterValue.?(s.context.device, s.sync.timeline_semaphore, &sem_val);
        renderer_log.debug("Timeline before cleanup: value={d}, current_frame_value={d}, result={d}", .{ sem_val, s.sync.current_frame_value, sem_res });
    }

    renderer_log.debug("Destroying previous scene buffers", .{});
    destroy_scene_buffers(s);

    if (scene == null or scene.?.mesh_count == 0) {
        renderer_log.info("Scene cleared (no meshes)", .{});
        s.current_scene = null;

        // Also ensure PBR pipeline is cleared if enabled
        if (s.pipelines.use_pbr_pipeline) {
            if (!vk_pbr.vk_pbr_load_scene(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device, s.context.physical_device, s.commands.pools.?[0], s.context.graphics_queue, @ptrCast(scene), @ptrCast(&s.allocator), @ptrCast(s))) {
                renderer_log.err("Failed to clear PBR scene", .{});
            }
        }

        return;
    }

    // We no longer use individual scene meshes (legacy path).
    // PBR pipeline handles its own batched buffer creation in vk_pbr_load_scene.
    // s.scene_mesh_count = scene.?.mesh_count;
    s.scene_meshes = null;

    if (s.pipelines.use_pbr_pipeline) {
        renderer_log.info("Loading scene into PBR pipeline", .{});
        if (!vk_pbr.vk_pbr_load_scene(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device, s.context.physical_device, s.commands.pools.?[0], s.context.graphics_queue, @ptrCast(scene), @ptrCast(&s.allocator), @ptrCast(s))) {
            renderer_log.err("Failed to load scene into PBR pipeline", .{});
            // If PBR load fails, we should not set current_scene as valid to prevent rendering with mismatched buffers
            s.current_scene = null;
            return;
        }
    }

    s.current_scene = if (scene) |ptr| @ptrCast(@constCast(ptr)) else null;

    renderer_log.info("Scene upload completed successfully with {d} meshes", .{scene.?.mesh_count});
}

pub export fn cardinal_renderer_clear_scene(renderer: ?*types.CardinalRenderer) callconv(.c) void {
    const s = get_state(renderer) orelse return;

    _ = c.vkDeviceWaitIdle(s.context.device);

    destroy_scene_buffers(s);
    s.current_scene = null;

    if (s.pipelines.use_pbr_pipeline) {
        if (!vk_pbr.vk_pbr_load_scene(@ptrCast(&s.pipelines.pbr_pipeline), s.context.device, s.context.physical_device, s.commands.pools.?[0], s.context.graphics_queue, null, @ptrCast(&s.allocator), @ptrCast(s))) {
            renderer_log.err("Failed to clear PBR scene", .{});
        }
    }
}

pub export fn cardinal_renderer_set_rendering_mode(renderer: ?*types.CardinalRenderer, mode: types.CardinalRenderingMode) callconv(.c) void {
    const s = get_state(renderer) orelse {
        renderer_log.err("Invalid renderer state", .{});
        return;
    };

    const previous_mode = s.current_rendering_mode;
    s.current_rendering_mode = mode;

    if (mode == .MESH_SHADER and previous_mode != .MESH_SHADER) {
        cardinal_renderer_enable_mesh_shader(renderer, true);
    } else if (mode != .MESH_SHADER and previous_mode == .MESH_SHADER) {
        cardinal_renderer_enable_mesh_shader(renderer, false);
    }

    // Fix for UV/Wireframe mode when pipelines are missing (e.g. after post-process toggle or resize)
    if (mode == .UV or mode == .WIREFRAME) {
        if (s.pipelines.uv_pipeline == null or s.pipelines.wireframe_pipeline == null) {
            renderer_log.warn("UV/Wireframe pipelines missing, attempting to recreate...", .{});
            // Ensure clean state to avoid leaks
            vk_simple_pipelines.vk_destroy_simple_pipelines(s);
            if (!vk_simple_pipelines.vk_create_simple_pipelines(s, null)) {
                renderer_log.err("Failed to recreate simple pipelines for mode {any}", .{mode});
            }
        }
    }

    renderer_log.info("Rendering mode changed to: {d}", .{@intFromEnum(mode)});
}

pub export fn cardinal_renderer_get_rendering_mode(renderer: ?*types.CardinalRenderer) callconv(.c) types.CardinalRenderingMode {
    const s = get_state(renderer) orelse {
        renderer_log.err("Invalid renderer state", .{});
        return .NORMAL;
    };

    return s.current_rendering_mode;
}

pub export fn cardinal_renderer_set_device_loss_callbacks(renderer: ?*types.CardinalRenderer, device_loss_callback: ?*const fn (?*anyopaque) callconv(.c) void, recovery_complete_callback: ?*const fn (?*anyopaque, bool) callconv(.c) void, user_data: ?*anyopaque) callconv(.c) void {
    if (renderer == null) {
        renderer_log.err("Invalid renderer", .{});
        return;
    }

    const s = get_state(renderer) orelse {
        renderer_log.err("Invalid renderer state", .{});
        return;
    };

    s.recovery.device_loss_callback = device_loss_callback;
    s.recovery.recovery_complete_callback = recovery_complete_callback;
    s.recovery.callback_user_data = user_data;

    renderer_log.info("Device loss recovery callbacks set", .{});
}

pub export fn cardinal_renderer_is_device_lost(renderer: ?*types.CardinalRenderer) callconv(.c) bool {
    if (renderer == null) return false;
    const s = get_state(renderer) orelse return false;
    return s.recovery.device_lost;
}

pub export fn cardinal_renderer_get_recovery_stats(renderer: ?*types.CardinalRenderer, out_attempt_count: ?*u32, out_max_attempts: ?*u32) callconv(.c) bool {
    if (renderer == null or out_attempt_count == null or out_max_attempts == null) {
        return false;
    }

    const s = get_state(renderer) orelse return false;

    out_attempt_count.?.* = s.recovery.attempt_count;
    out_max_attempts.?.* = s.recovery.max_attempts;

    return true;
}
