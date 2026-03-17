//! Vulkan frame submission.
//!
//! Owns the per-frame draw entrypoint used by the C API.
const std = @import("std");
const log = @import("../core/log.zig");
const tracy = @import("../core/tracy.zig");
const types = @import("vulkan_types.zig");

const c = @import("vulkan_c.zig").c;

const frame_log = log.ScopedLogger("RENDER_FRAME");

const vk_swapchain = @import("vulkan_swapchain.zig");
const vk_commands = @import("vulkan_commands.zig");
const vk_sync_manager = @import("vulkan_sync_manager.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const vk_mesh_shader = @import("vulkan_mesh_shader.zig");
const vk_ssao = @import("vulkan_ssao.zig");
const vk_texture_manager = @import("vulkan_texture_manager.zig");
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");
const vk_renderer = @import("vulkan_renderer.zig");
const window = @import("../core/window.zig");
const vk_device_loss_recovery = @import("vulkan_device_loss_recovery.zig");

/// Returns a wall-clock-ish timestamp in milliseconds using GLFW.
fn cardinal_now_ms() u64 {
    return @intFromFloat(c.glfwGetTime() * 1000.0);
}

/// Casts an opaque renderer handle into the backing `VulkanState`.
fn get_state(renderer: ?*types.CardinalRenderer) ?*types.VulkanState {
    if (renderer == null) return null;
    return @ptrCast(@alignCast(renderer.?._opaque));
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
    if (s.recovery.device_lost) {
        if (s.recovery.attempt_count < s.recovery.max_attempts) {
            _ = vk_device_loss_recovery.recover_from_device_loss(s);
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
                    _ = vk_device_loss_recovery.recover_from_device_loss(s);
            } else {
                frame_log.err("Frame {d}: Fence wait failed: {d}", .{ s.sync.current_frame, wait_res });
            }
            return false;
        }
    } else {
        if (fence_status == c.VK_ERROR_DEVICE_LOST) {
            s.recovery.device_lost = true;
            if (s.recovery.attempt_count < s.recovery.max_attempts)
                _ = vk_device_loss_recovery.recover_from_device_loss(s);
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

    var res: c.VkResult = c.VK_SUCCESS;

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
            _ = vk_device_loss_recovery.recover_from_device_loss(s);
        return false;
    } else if (res != c.VK_SUCCESS) {
        return false;
    }
    return true;
}

fn submit_command_buffer(s: *types.VulkanState, cmd: c.VkCommandBuffer, acquire_sem: c.VkSemaphore, wait_timeline_value: ?u64, image_index: u32, signal_timeline_value: u64) bool {
    const zone = tracy.zoneS(@src(), "Submit Command Buffer");
    defer zone.end();

    const has_timeline_wait = (wait_timeline_value != null and s.sync.timeline_semaphore != null);
    const has_timeline_signal = (signal_timeline_value != 0 and s.sync.timeline_semaphore != null);

    const wait_info = c.VkSemaphoreSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = acquire_sem,
        .value = 0,
        .stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .deviceIndex = 0,
    };

    const timeline_wait_info = c.VkSemaphoreSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = s.sync.timeline_semaphore,
        .value = if (has_timeline_wait) wait_timeline_value.? else 0,
        .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .deviceIndex = 0,
    };

    var wait_infos = [2]c.VkSemaphoreSubmitInfo{ wait_info, timeline_wait_info };

    const binary_signal_info = c.VkSemaphoreSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = blk: {
            if (s.swapchain.image_present_semaphores != null and image_index < s.swapchain.image_count) {
                const img_sem = s.swapchain.image_present_semaphores.?[image_index];
                if (img_sem != null) break :blk img_sem;
            }
            break :blk s.sync.render_finished_semaphores.?[s.sync.current_frame];
        },
        .value = 0,
        .stageMask = c.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
        .deviceIndex = 0,
    };

    const timeline_signal_info = c.VkSemaphoreSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = s.sync.timeline_semaphore,
        .value = signal_timeline_value,
        .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .deviceIndex = 0,
    };

    var signal_infos = [2]c.VkSemaphoreSubmitInfo{ binary_signal_info, timeline_signal_info };

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
        .waitSemaphoreInfoCount = if (has_timeline_wait) 2 else 1,
        .pWaitSemaphoreInfos = &wait_infos[0],
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmd_info,
        .signalSemaphoreInfoCount = if (has_timeline_signal) 2 else 1,
        .pSignalSemaphoreInfos = &signal_infos[0],
    };

    var res: c.VkResult = c.VK_SUCCESS;

    res = vk_sync_manager.vulkan_sync_manager_submit_queue2(s.context.graphics_queue, 1, @ptrCast(&submit_info), s.sync.in_flight_fences.?[s.sync.current_frame], s.context.vkQueueSubmit2);

    if (res == c.VK_ERROR_DEVICE_LOST) {
        s.recovery.device_lost = true;
        if (s.recovery.attempt_count < s.recovery.max_attempts)
            _ = vk_device_loss_recovery.recover_from_device_loss(s);
        return false;
    } else if (res != c.VK_SUCCESS) {
        frame_log.err("Queue submit failed: {d}", .{res});
        return false;
    }
    return true;
}

fn submit_compute_command_buffer(s: *types.VulkanState, cmd: c.VkCommandBuffer, signal_value: u64, wait_timeline_value: ?u64) bool {
    const zone = tracy.zoneS(@src(), "Submit Compute Command Buffer");
    defer zone.end();

    const timeline_wait_info = c.VkSemaphoreSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = s.sync.timeline_semaphore,
        .value = if (wait_timeline_value) |v| v else 0,
        .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .deviceIndex = 0,
    };

    var wait_infos = [1]c.VkSemaphoreSubmitInfo{timeline_wait_info};

    var signal_infos = [1]c.VkSemaphoreSubmitInfo{.{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = s.sync.timeline_semaphore,
        .value = signal_value,
        .stageMask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
        .deviceIndex = 0,
    }};

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
        .waitSemaphoreInfoCount = if (wait_timeline_value != null) 1 else 0,
        .pWaitSemaphoreInfos = if (wait_timeline_value != null) &wait_infos[0] else null,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmd_info,
        .signalSemaphoreInfoCount = 1,
        .pSignalSemaphoreInfos = &signal_infos[0],
    };

    var res: c.VkResult = c.VK_SUCCESS;
    res = vk_sync_manager.vulkan_sync_manager_submit_queue2(s.context.compute_queue, 1, @ptrCast(&submit_info), null, s.context.vkQueueSubmit2);
    if (res == c.VK_ERROR_DEVICE_LOST) {
        s.recovery.device_lost = true;
        if (s.recovery.attempt_count < s.recovery.max_attempts)
            _ = vk_device_loss_recovery.recover_from_device_loss(s);
        return false;
    } else if (res != c.VK_SUCCESS) {
        frame_log.err("Compute queue submit failed: {d}", .{res});
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

    var wait_sem: c.VkSemaphore = s.sync.render_finished_semaphores.?[s.sync.current_frame];
    if (s.swapchain.image_present_semaphores != null and image_index < s.swapchain.image_count) {
        const img_sem = s.swapchain.image_present_semaphores.?[image_index];
        if (img_sem != null) {
            wait_sem = img_sem;
        }
    }
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
            _ = vk_device_loss_recovery.recover_from_device_loss(s);
        return;
    } else if (res != c.VK_SUCCESS) {
        if (res == c.VK_ERROR_OUT_OF_HOST_MEMORY or res == c.VK_ERROR_OUT_OF_DEVICE_MEMORY) {
            s.recovery.device_lost = true;
            if (s.recovery.attempt_count < s.recovery.max_attempts)
                _ = vk_device_loss_recovery.recover_from_device_loss(s);
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

    vk_mesh_shader.vk_mesh_shader_process_pending_cleanup(s);
    vk_texture_utils.process_staging_buffer_cleanups(@ptrCast(s.sync_manager), @ptrCast(&s.allocator));

    if (s.pipelines.use_skybox_pipeline) {
        const vk_skybox = @import("vulkan_skybox.zig");
        vk_skybox.vk_skybox_update(&s.pipelines.skybox_pipeline, s.context.device, &s.allocator, s.commands.pools.?[0], s.context.graphics_queue, s.sync_manager);
    }

    if (s.current_rendering_mode == .MESH_SHADER) {
        vk_commands.vk_prepare_mesh_shader_rendering(@ptrCast(s));
    }

    if (s.pipelines.use_pbr_pipeline) {
        vk_pbr.vk_pbr_update_uniforms(@ptrCast(&s.pipelines.pbr_pipeline), @ptrCast(&s.pipelines.pbr_pipeline.current_ubo), @ptrCast(&s.pipelines.pbr_pipeline.current_lighting), s.sync.current_frame);
    }

    if (s.pipelines.use_ssao and s.pipelines.ssao_pipeline.initialized) {
        if (s.pipelines.ssao_pipeline.width != s.swapchain.extent.width or s.pipelines.ssao_pipeline.height != s.swapchain.extent.height) {
            if (!vk_ssao.vk_ssao_resize(s, s.swapchain.extent.width, s.swapchain.extent.height)) {
                vk_ssao.vk_ssao_destroy(s);
            }
        }
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

    var reserved_upload_signal: ?u64 = null;
    var reserved_render_signal: ?u64 = null;
    if (s.sync_manager != null) {
        var reserved_values: [2]u64 = .{ 0, 0 };
        if (vk_sync_manager.vulkan_sync_manager_reserve_timeline_values(s.sync_manager, reserved_values[0..])) {
            reserved_upload_signal = reserved_values[0];
            reserved_render_signal = reserved_values[1];
        }
    }

    var texture_upload_signal: ?u64 = null;
    if (s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.textureManager != null) {
        texture_upload_signal = vk_texture_manager.vk_texture_manager_update_textures(s.pipelines.pbr_pipeline.textureManager.?, reserved_upload_signal);
    }

    vk_commands.vk_record_cmd(@ptrCast(s), image_index);

    if (s.sync_manager != null) {
        signal_after_render = reserved_render_signal orelse vk_sync_manager.vulkan_sync_manager_get_next_timeline_value(s.sync_manager);
    } else {
        signal_after_render = s.sync.current_frame_value + 1;
    }

    const cmd_buf = if (s.commands.current_buffer_index == 0)
        s.commands.buffers.?[s.sync.current_frame]
    else
        s.commands.alternate_primary_buffers.?[s.sync.current_frame];

    if (cmd_buf == null)
        return;

    if (!submit_command_buffer(
        s,
        cmd_buf,
        s.sync.image_acquired_semaphores.?[s.sync.current_frame],
        texture_upload_signal,
        image_index,
        signal_after_render,
    ))
        return;

    present_swapchain_image(s, image_index, signal_after_render);
}
