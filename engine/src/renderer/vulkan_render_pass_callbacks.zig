//! Built-in render graph pass callbacks for the Vulkan renderer.
//!
//! Each callback records commands for a specific pass (PBR, post-process, shadows, UI) and is
//! typically referenced by a render graph `RenderPass`.
const std = @import("std");
const log = @import("../core/log.zig");
const math = @import("../core/math.zig");
const types = @import("vulkan_types.zig");
const render_graph = @import("render_graph.zig");
const vk_commands = @import("vulkan_commands.zig");
const vk_post_process = @import("vulkan_post_process.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const vk_shadows = @import("vulkan_shadows.zig");
const vk_skybox = @import("vulkan_skybox.zig");
const vk_ssao = @import("vulkan_ssao.zig");

const renderer_log = log.ScopedLogger("RENDERER");

const c = @import("vulkan_c.zig").c;

/// Records the main PBR scene rendering pass (optionally using secondary command buffers).
pub fn pbr_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    var clears: [2]c.VkClearValue = undefined;
    clears[0].color.float32[0] = state.config.pbr_clear_color[0];
    clears[0].color.float32[1] = state.config.pbr_clear_color[1];
    clears[0].color.float32[2] = state.config.pbr_clear_color[2];
    clears[0].color.float32[3] = state.config.pbr_clear_color[3];
    clears[1].depthStencil.depth = 1.0;
    clears[1].depthStencil.stencil = 0;

    var depth_view: ?c.VkImageView = null;
    var color_view: ?c.VkImageView = null;
    var color_format: c.VkFormat = state.swapchain.format;
    var use_depth = false;

    if (state.render_graph) |rg_ptr| {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        if (rg.resources.get(types.RESOURCE_ID_DEPTHBUFFER)) |res| {
            depth_view = res.image_view;
            use_depth = (depth_view != null);
        }
        if (rg.resources.get(types.RESOURCE_ID_HDR_COLOR)) |res| {
            color_view = res.image_view;
            if (res.desc) |d| {
                switch (d) {
                    .Image => |img| color_format = img.format,
                    else => {},
                }
            }
        }
    }

    if (!use_depth) {
        use_depth = state.swapchain.depth_image_view != null and state.swapchain.depth_image != null;
    }

    const use_secondary = (state.commands.scene_secondary_buffers != null);
    const flags: c.VkRenderingFlags = if (use_secondary) c.VK_RENDERING_CONTENTS_SECONDARY_COMMAND_BUFFERS_BIT else 0;

    const should_clear_depth = (state.pipelines.depth_pipeline == null or state.current_rendering_mode != types.CardinalRenderingMode.NORMAL);

    renderer_log.debug("PBR pass frame {d}: use_depth={any}, depth_view={any}, color_view={any}, clear_depth={any}, mode={any}", .{ state.sync.current_frame, use_depth, depth_view, color_view, should_clear_depth, state.current_rendering_mode });

    if (vk_commands.vk_begin_rendering_impl(state, cmd, state.current_image_index, use_depth, depth_view, color_view, &clears, true, should_clear_depth, flags, true)) {
        if (use_secondary) {
            vk_commands.vk_record_scene_with_secondary_buffers(state, cmd, state.current_image_index, use_depth, &clears, color_format);
        } else {
            vk_commands.vk_record_scene_content(state, cmd);
        }

        vk_commands.vk_end_rendering(state, cmd);
    }
}

/// Records fullscreen post-processing, sampling from the HDR color resource when present.
pub fn post_process_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
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

    renderer_log.debug("Post-process pass frame {d}: hdr_view={any}", .{ state.sync.current_frame, input_view });

    if (vk_commands.vk_begin_rendering_impl(state, cmd, state.current_image_index, false, null, null, &clears, true, false, 0, true)) {
        if (input_view) |view| {
            vk_post_process.draw(state, cmd, state.sync.current_frame, view);
        }
        vk_commands.vk_end_rendering(state, cmd);
    }
}

/// Runs a bloom compute dispatch over the HDR color resource when present.
pub fn bloom_compute_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
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

/// Renders the skybox using camera matrices from the PBR uniform buffer.
pub fn skybox_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
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
                vk_skybox.render(&state.pipelines.skybox_pipeline, cmd, view, proj, state.sync.current_frame);
                vk_commands.vk_end_rendering(state, cmd);
            }
        }
    }
}

/// Records the UI pass by invoking the external UI recording callback.
pub fn ui_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
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

/// Placeholder pass for present-only steps.
pub fn present_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    _ = cmd;
    _ = state;
}

/// Records the shadow map rendering pass.
pub fn shadow_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    vk_shadows.vk_shadow_render(state, cmd);
}

/// Records a depth-only prepass used by the PBR pipeline.
pub fn depth_prepass_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
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

    renderer_log.debug("Depth pre-pass frame {d}: use_depth={any}, depth_view={any}", .{ state.sync.current_frame, use_depth, depth_view });

    if (vk_commands.vk_begin_rendering_impl(state, cmd, state.current_image_index, use_depth, depth_view, null, &clears, false, true, 0, false)) {
        if (state.pipelines.use_pbr_pipeline and state.pipelines.depth_pipeline != null) {
            vk_pbr.vk_pbr_render_depth_prepass(state, cmd, state.current_scene, state.sync.current_frame);
        }
        vk_commands.vk_end_rendering(state, cmd);
    }
}

pub fn ssao_pass_callback(cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
    if (!state.pipelines.use_ssao or !state.pipelines.ssao_pipeline.initialized) return;
    renderer_log.debug("SSAO pass frame {d}: running", .{state.sync.current_frame});
    vk_ssao.vk_ssao_compute(state, cmd, state.sync.current_frame);
}
