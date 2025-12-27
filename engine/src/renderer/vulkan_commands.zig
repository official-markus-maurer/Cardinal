const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const math = @import("../core/math.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_types.zig");
const vk_utils = @import("vulkan_utils.zig");
const vk_barrier_validation = @import("vulkan_barrier_validation.zig");
pub const vulkan_mt = @import("vulkan_mt.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const vk_skybox = @import("vulkan_skybox.zig");
const vk_mesh_shader = @import("vulkan_mesh_shader.zig");
const vk_simple_pipelines = @import("vulkan_simple_pipelines.zig");
const vk_sync_manager = @import("vulkan_sync_manager.zig");
const render_graph = @import("render_graph.zig");
const vk_shadows = @import("vulkan_shadows.zig");

const cmd_log = log.ScopedLogger("COMMANDS");

const c = @import("vulkan_c.zig").c;

// Helper to get current thread ID
fn get_current_thread_id() u32 {
    if (builtin.os.tag == .windows) {
        return c.GetCurrentThreadId();
    } else {
        return @intCast(c.syscall(c.SYS_gettid));
    }
}

// Internal helpers

fn create_command_pools(s: *types.VulkanState) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const pools_ptr = memory.cardinal_alloc(mem_alloc, s.sync.max_frames_in_flight * @sizeOf(c.VkCommandPool));
    if (pools_ptr == null) return false;

    s.commands.pools = @as([*]c.VkCommandPool, @ptrCast(@alignCast(pools_ptr)));

    var i: u32 = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        if (!vk_utils.vk_utils_create_command_pool(s.context.device, s.context.graphics_queue_family, c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, &s.commands.pools.?[i], "graphics command pool")) {
            return false;
        }
    }
    cmd_log.warn("Created {d} command pools", .{s.sync.max_frames_in_flight});
    return true;
}

fn allocate_command_buffers(s: *types.VulkanState) bool {
    // Primary buffers
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const buffers_ptr = memory.cardinal_alloc(mem_alloc, s.sync.max_frames_in_flight * @sizeOf(c.VkCommandBuffer));
    if (buffers_ptr == null) return false;
    s.commands.buffers = @as([*]c.VkCommandBuffer, @ptrCast(@alignCast(buffers_ptr)));

    var i: u32 = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = s.commands.pools.?[i];
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;

        if (c.vkAllocateCommandBuffers(s.context.device, &ai, &s.commands.buffers.?[i]) != c.VK_SUCCESS) {
            return false;
        }
    }
    cmd_log.warn("Allocated {d} primary command buffers", .{s.sync.max_frames_in_flight});

    // Secondary buffers
    const sec_buffers_ptr = memory.cardinal_alloc(mem_alloc, s.sync.max_frames_in_flight * @sizeOf(c.VkCommandBuffer));
    if (sec_buffers_ptr == null) return false;
    s.commands.secondary_buffers = @as([*]c.VkCommandBuffer, @ptrCast(@alignCast(sec_buffers_ptr)));

    i = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = s.commands.pools.?[i];
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY; // Allocated as PRIMARY
        ai.commandBufferCount = 1;

        if (c.vkAllocateCommandBuffers(s.context.device, &ai, &s.commands.secondary_buffers.?[i]) != c.VK_SUCCESS) {
            return false;
        }
    }
    cmd_log.warn("Allocated {d} secondary command buffers", .{s.sync.max_frames_in_flight});

    // Scene secondary buffers (real secondary level)
    const scene_sec_ptr = memory.cardinal_alloc(mem_alloc, s.sync.max_frames_in_flight * @sizeOf(c.VkCommandBuffer));
    if (scene_sec_ptr == null) return false;
    s.commands.scene_secondary_buffers = @as([*]c.VkCommandBuffer, @ptrCast(@alignCast(scene_sec_ptr)));

    i = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = s.commands.pools.?[i];
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_SECONDARY;
        ai.commandBufferCount = 1;

        if (c.vkAllocateCommandBuffers(s.context.device, &ai, &s.commands.scene_secondary_buffers.?[i]) != c.VK_SUCCESS) {
            return false;
        }
    }
    log.cardinal_log_warn("[INIT] Allocated {d} scene secondary command buffers", .{s.sync.max_frames_in_flight});

    return true;
}

fn create_sync_objects(s: *types.VulkanState) bool {
    // Cleanup existing resources if any
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);

    // Image acquired semaphores
    if (s.sync.image_acquired_semaphores != null) {
        var i: u32 = 0;
        while (i < s.sync.max_frames_in_flight) : (i += 1) {
            if (s.sync.image_acquired_semaphores.?[i] != null) {
                c.vkDestroySemaphore(s.context.device, s.sync.image_acquired_semaphores.?[i], null);
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(s.sync.image_acquired_semaphores)));
        s.sync.image_acquired_semaphores = null;
    }

    // Render finished semaphores
    if (s.sync.render_finished_semaphores != null) {
        var i: u32 = 0;
        while (i < s.sync.max_frames_in_flight) : (i += 1) {
            if (s.sync.render_finished_semaphores.?[i] != null) {
                c.vkDestroySemaphore(s.context.device, s.sync.render_finished_semaphores.?[i], null);
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(s.sync.render_finished_semaphores)));
        s.sync.render_finished_semaphores = null;
    }

    // In-flight fences
    if (s.sync.in_flight_fences != null) {
        var i: u32 = 0;
        while (i < s.sync.max_frames_in_flight) : (i += 1) {
            if (s.sync.in_flight_fences.?[i] != null) {
                c.vkDestroyFence(s.context.device, s.sync.in_flight_fences.?[i], null);
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(s.sync.in_flight_fences)));
        s.sync.in_flight_fences = null;
    }

    // Timeline semaphore
    if (s.sync.timeline_semaphore != null) {
        c.vkDestroySemaphore(s.context.device, s.sync.timeline_semaphore, null);
        s.sync.timeline_semaphore = null;
    }

    // Initialize using centralized sync manager
    log.cardinal_log_info("[INIT] Initializing sync objects via centralized manager", .{});
    return vk_sync_manager.vulkan_sync_manager_init(&s.sync, s.context.device, s.context.graphics_queue, s.sync.max_frames_in_flight);
}

fn select_command_buffer(s: *types.VulkanState) c.VkCommandBuffer {
    if (s.commands.current_buffer_index == 0) {
        if (s.commands.buffers == null) {
            log.cardinal_log_error("[CMD] Frame {d}: command_buffers array is null", .{s.sync.current_frame});
            return null;
        }
        return s.commands.buffers.?[s.sync.current_frame];
    } else {
        if (s.commands.secondary_buffers == null) {
            log.cardinal_log_error("[CMD] Frame {d}: secondary_command_buffers array is null", .{s.sync.current_frame});
            return null;
        }
        return s.commands.secondary_buffers.?[s.sync.current_frame];
    }
}

fn validate_swapchain_image(s: *types.VulkanState, image_index: u32) bool {
    if (s.swapchain.image_count == 0 or image_index >= s.swapchain.image_count) {
        log.cardinal_log_error("[CMD] Frame {d}: Invalid image index {d} (count {d})", .{ s.sync.current_frame, image_index, s.swapchain.image_count });
        return false;
    }
    if (s.swapchain.images == null or s.swapchain.image_views == null) {
        log.cardinal_log_error("[CMD] Frame {d}: Swapchain image arrays are null", .{s.sync.current_frame});
        return false;
    }
    if (s.swapchain.image_layout_initialized == null) {
        log.cardinal_log_error("[CMD] Frame {d}: Image layout initialization array is null", .{s.sync.current_frame});
        return false;
    }
    if (s.swapchain.extent.width == 0 or s.swapchain.extent.height == 0) {
        log.cardinal_log_error("[CMD] Frame {d}: Invalid swapchain extent {d}x{d}", .{ s.sync.current_frame, s.swapchain.extent.width, s.swapchain.extent.height });
        return false;
    }
    return true;
}

fn begin_command_buffer(s: *types.VulkanState, cmd: c.VkCommandBuffer) bool {
    log.cardinal_log_info("[CMD] Frame {d}: Resetting command buffer {any}", .{ s.sync.current_frame, cmd });
    const reset_result = c.vkResetCommandBuffer(cmd, 0);
    if (reset_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[CMD] Frame {d}: Failed to reset command buffer: {d}", .{ s.sync.current_frame, reset_result });
        return false;
    }

    var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    log.cardinal_log_info("[CMD] Frame {d}: Beginning command buffer {any} with flags {d}", .{ s.sync.current_frame, cmd, bi.flags });
    const begin_result = c.vkBeginCommandBuffer(cmd, &bi);
    if (begin_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[CMD] Frame {d}: Failed to begin command buffer: {d}", .{ s.sync.current_frame, begin_result });
        return false;
    }
    return true;
}

fn transition_images(s: *types.VulkanState, cmd: c.VkCommandBuffer, image_index: u32, use_depth: bool) void {
    const thread_id = get_current_thread_id();

    // Depth transition
    if (use_depth and !s.swapchain.depth_layout_initialized) {
        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
        barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
        barrier.srcAccessMask = 0;
        barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = s.swapchain.depth_image;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;

        var dep = std.mem.zeroes(c.VkDependencyInfo);
        dep.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = 1;
        dep.pImageMemoryBarriers = &barrier;

        if (!vk_barrier_validation.cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
            log.cardinal_log_warn("[CMD] Pipeline barrier validation failed for depth image transition", .{});
        }

        if (s.context.vkCmdPipelineBarrier2 != null) {
            s.context.vkCmdPipelineBarrier2.?(cmd, &dep);
            s.swapchain.depth_layout_initialized = true;
        }
    }

    // Color attachment transition
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.image = s.swapchain.images.?[image_index];
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;

    if (!s.swapchain.image_layout_initialized.?[image_index]) {
        barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
        barrier.srcAccessMask = 0;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        s.swapchain.image_layout_initialized.?[image_index] = true;
    } else {
        barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
        barrier.srcAccessMask = 0;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    }

    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    var dep = std.mem.zeroes(c.VkDependencyInfo);
    dep.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &barrier;

    if (!vk_barrier_validation.cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
        log.cardinal_log_warn("[CMD] Pipeline barrier validation failed for swapchain image transition", .{});
    }

    if (s.context.vkCmdPipelineBarrier2 != null) {
        s.context.vkCmdPipelineBarrier2.?(cmd, &dep);
    }
}

pub fn begin_dynamic_rendering(s: *types.VulkanState, cmd: c.VkCommandBuffer, image_index: u32, use_depth: bool, clears: [*]c.VkClearValue, should_clear: bool, flags: c.VkRenderingFlags) bool {
    if (s.context.vkCmdBeginRendering == null or s.context.vkCmdEndRendering == null or s.context.vkCmdPipelineBarrier2 == null) {
        log.cardinal_log_error("[CMD] Frame {d}: Dynamic rendering functions not loaded", .{s.sync.current_frame});
        return false;
    }

    var colorAttachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
    colorAttachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    colorAttachment.imageView = s.swapchain.image_views.?[image_index];
    colorAttachment.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    colorAttachment.loadOp = if (should_clear) c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD;
    colorAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
    colorAttachment.clearValue = clears[0];

    var depthAttachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
    if (use_depth) {
        depthAttachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        depthAttachment.imageView = s.swapchain.depth_image_view;
        depthAttachment.imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        depthAttachment.loadOp = if (should_clear) c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD;
        depthAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depthAttachment.clearValue = clears[1];
    }

    var renderingInfo = std.mem.zeroes(c.VkRenderingInfo);
    renderingInfo.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
    renderingInfo.flags = flags;
    renderingInfo.renderArea.offset.x = 0;
    renderingInfo.renderArea.offset.y = 0;
    renderingInfo.renderArea.extent = s.swapchain.extent;
    renderingInfo.layerCount = 1;
    renderingInfo.colorAttachmentCount = 1;
    renderingInfo.pColorAttachments = &colorAttachment;
    renderingInfo.pDepthAttachment = if (use_depth) &depthAttachment else null;

    s.context.vkCmdBeginRendering.?(cmd, &renderingInfo);

    // Set viewport/scissor only if not using secondary buffers (as they usually set their own or inherit?
    // Actually, dynamic rendering with secondary buffers might expect viewport to be set in secondary buffers or inherited.
    // But vkCmdSetViewport is not allowed in Secondary buffer if it inherits?
    // Secondary buffers record their own commands.
    // If we use secondary buffers, we don't need to set viewport in primary buffer UNLESS we are using it for inheritance?
    // But let's keep it simple: always set it if flags == 0 (Inline).
    // If flags != 0, we are just executing secondary buffers, so no inline commands allowed.
    if (flags == 0) {
        var vp = std.mem.zeroes(c.VkViewport);
        vp.x = 0;
        vp.y = 0;
        vp.width = @floatFromInt(s.swapchain.extent.width);
        vp.height = @floatFromInt(s.swapchain.extent.height);
        vp.minDepth = 0.0;
        vp.maxDepth = 1.0;
        c.vkCmdSetViewport(cmd, 0, 1, &vp);

        var sc = std.mem.zeroes(c.VkRect2D);
        sc.offset.x = 0;
        sc.offset.y = 0;
        sc.extent = s.swapchain.extent;
        c.vkCmdSetScissor(cmd, 0, 1, &sc);
    }

    return true;
}

pub fn end_dynamic_rendering(s: *types.VulkanState, cmd: c.VkCommandBuffer) void {
    if (s.context.vkCmdEndRendering != null) {
        s.context.vkCmdEndRendering.?(cmd);
    }
}

fn end_recording(s: *types.VulkanState, cmd: c.VkCommandBuffer, image_index: u32) void {
    // Note: vkCmdEndRendering is now handled by end_dynamic_rendering or caller

    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    barrier.srcAccessMask = c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT;
    barrier.dstAccessMask = 0;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = s.swapchain.images.?[image_index];
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;

    var dep = std.mem.zeroes(c.VkDependencyInfo);
    dep.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &barrier;

    const thread_id = get_current_thread_id();
    if (!vk_barrier_validation.cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
        log.cardinal_log_warn("[CMD] Pipeline barrier validation failed for swapchain present transition", .{});
    }

    if (s.context.vkCmdPipelineBarrier2 != null) {
        s.context.vkCmdPipelineBarrier2.?(cmd, &dep);
    }

    log.cardinal_log_info("[CMD] Frame {d}: Ending command buffer {any}", .{ s.sync.current_frame, cmd });
    const end_result = c.vkEndCommandBuffer(cmd);
    log.cardinal_log_info("[CMD] Frame {d}: End result: {d}", .{ s.sync.current_frame, end_result });

    if (end_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[CMD] Frame {d}: Failed to end command buffer: {d}", .{ s.sync.current_frame, end_result });
    }
}

fn vk_update_frame_uniforms(s: *types.VulkanState) void {
    if (s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
        var ubo: types.PBRUniformBufferObject = undefined;
        @memcpy(@as([*]u8, @ptrCast(&ubo))[0..@sizeOf(types.PBRUniformBufferObject)], @as([*]u8, @ptrCast(s.pipelines.pbr_pipeline.uniformBufferMapped))[0..@sizeOf(types.PBRUniformBufferObject)]);

        var lighting: types.PBRLightingBuffer = undefined;
        @memcpy(@as([*]u8, @ptrCast(&lighting))[0..@sizeOf(types.PBRLightingBuffer)], @as([*]u8, @ptrCast(s.pipelines.pbr_pipeline.lightingBufferMapped))[0..@sizeOf(types.PBRLightingBuffer)]);

        vk_pbr.vk_pbr_update_uniforms(&s.pipelines.pbr_pipeline, &ubo, &lighting);

        // Update simple uniforms using PBR data if in UV/Wireframe mode
        if (s.current_rendering_mode == .UV or s.current_rendering_mode == .WIREFRAME) {
             vk_simple_pipelines.vk_update_simple_uniforms(s, @ptrCast(&ubo.model), @ptrCast(&ubo.view), @ptrCast(&ubo.proj));
        }
    }
}

pub fn vk_record_scene_content(s: *types.VulkanState, cmd: c.VkCommandBuffer) void {
    switch (s.current_rendering_mode) {
        types.CardinalRenderingMode.NORMAL => {
            if (s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                vk_pbr.vk_pbr_render(&s.pipelines.pbr_pipeline, cmd, s.current_scene);
            }
        },
        types.CardinalRenderingMode.UV => {
            if (s.pipelines.uv_pipeline != null and s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                vk_simple_pipelines.vk_render_simple(s, cmd, s.pipelines.uv_pipeline, s.pipelines.uv_pipeline_layout);
            }
        },
        types.CardinalRenderingMode.WIREFRAME => {
            if (s.pipelines.wireframe_pipeline != null and s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                vk_simple_pipelines.vk_render_simple(s, cmd, s.pipelines.wireframe_pipeline, s.pipelines.wireframe_pipeline_layout);
            }
        },
        types.CardinalRenderingMode.DEBUG => {
            // Debug rendering
        },
        types.CardinalRenderingMode.MESH_SHADER => {
            vk_mesh_shader.vk_mesh_shader_record_frame(s, cmd);
        },
    }
}

fn vk_record_scene_with_secondary_buffers(s: *types.VulkanState, primary_cmd: c.VkCommandBuffer, image_index: u32, use_depth: bool, clears: [*]c.VkClearValue) void {
    // Use dedicated secondary command buffer for the main thread
    // This avoids using the MT subsystem's thread pools which are prone to exhaustion/race conditions if not managed per-frame.

    if (s.commands.scene_secondary_buffers == null) {
        // Fallback if not allocated
        if (begin_dynamic_rendering(s, primary_cmd, image_index, use_depth, clears, true, 0)) {
            vk_record_scene_content(s, primary_cmd);
            end_dynamic_rendering(s, primary_cmd);
        }
        return;
    }

    var secondary_cmd = s.commands.scene_secondary_buffers.?[s.sync.current_frame];

    // Reset the secondary command buffer
    // Since it's allocated from a pool with VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, this is allowed.
    if (c.vkResetCommandBuffer(secondary_cmd, 0) != c.VK_SUCCESS) {
        log.cardinal_log_error("[CMD] Failed to reset scene secondary command buffer", .{});
        // Fallback
        if (begin_dynamic_rendering(s, primary_cmd, image_index, use_depth, clears, true, 0)) {
            vk_record_scene_content(s, primary_cmd);
            end_dynamic_rendering(s, primary_cmd);
        }
        return;
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

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT | c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    begin_info.pInheritanceInfo = &inheritance_info;

    if (c.vkBeginCommandBuffer(secondary_cmd, &begin_info) != c.VK_SUCCESS) {
        log.cardinal_log_error("[CMD] Failed to begin scene secondary command buffer", .{});
        return;
    }

    var vp = std.mem.zeroes(c.VkViewport);
    vp.x = 0;
    vp.y = 0;
    vp.width = @floatFromInt(s.swapchain.extent.width);
    vp.height = @floatFromInt(s.swapchain.extent.height);
    vp.minDepth = 0.0;
    vp.maxDepth = 1.0;
    c.vkCmdSetViewport(secondary_cmd, 0, 1, &vp);

    var sc = std.mem.zeroes(c.VkRect2D);
    sc.offset.x = 0;
    sc.offset.y = 0;
    sc.extent = s.swapchain.extent;
    c.vkCmdSetScissor(secondary_cmd, 0, 1, &sc);

    vk_record_scene_content(s, secondary_cmd);

    if (c.vkEndCommandBuffer(secondary_cmd) != c.VK_SUCCESS) {
        log.cardinal_log_error("[CMD] Failed to end scene secondary command buffer", .{});
        return;
    }

    // Pass slice of 1 context
    const cmd_buffers = @as([*]c.VkCommandBuffer, @ptrCast(&secondary_cmd))[0..1];

    // Execute with Secondary Bit
    if (begin_dynamic_rendering(s, primary_cmd, image_index, use_depth, clears, true, c.VK_RENDERING_CONTENTS_SECONDARY_COMMAND_BUFFERS_BIT)) {
        c.vkCmdExecuteCommands(primary_cmd, 1, cmd_buffers.ptr);
        end_dynamic_rendering(s, primary_cmd);
    }

    log.cardinal_log_debug("[CMD] Scene rendered using dedicated secondary command buffer", .{});
}

// Exported functions

pub export fn vk_create_commands_sync(s: ?*types.VulkanState) callconv(.c) bool {
    if (s == null) return false;
    const vs = s.?;

    vs.sync.max_frames_in_flight = 3;
    vs.sync.current_frame = 0;

    if (!create_command_pools(vs)) return false;
    if (!allocate_command_buffers(vs)) return false;

    vs.commands.current_buffer_index = 0;

    log.cardinal_log_warn("[INIT] Allocating swapchain_image_layout_initialized for {d} swapchain images", .{vs.swapchain.image_count});
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    if (vs.swapchain.image_layout_initialized != null) {
        memory.cardinal_free(mem_alloc, vs.swapchain.image_layout_initialized);
        vs.swapchain.image_layout_initialized = null;
    }

    const layout_ptr = memory.cardinal_alloc(mem_alloc, vs.swapchain.image_count * @sizeOf(bool));
    if (layout_ptr == null) return false;
    @memset(@as([*]u8, @ptrCast(layout_ptr))[0..(vs.swapchain.image_count * @sizeOf(bool))], 0);
    vs.swapchain.image_layout_initialized = @as([*]bool, @ptrCast(@alignCast(layout_ptr)));

    if (!create_sync_objects(vs)) return false;

    vs.sync.current_frame_value = 0;
    vs.sync.image_available_value = 1;
    vs.sync.render_complete_value = 2;

    var optimal_thread_count = vulkan_mt.cardinal_mt_get_optimal_thread_count();
    if (optimal_thread_count > 4) {
        optimal_thread_count = 4;
    }

    if (!vulkan_mt.cardinal_mt_subsystem_init(@ptrCast(vs), optimal_thread_count)) {
        log.cardinal_log_warn("[INIT] Failed to initialize multi-threading subsystem, continuing without MT support", .{});
    } else {
        log.cardinal_log_info("[INIT] Multi-threading subsystem initialized with {d} threads", .{optimal_thread_count});
    }

    return true;
}

pub export fn vk_recreate_images_in_flight(s: ?*types.VulkanState) callconv(.c) bool {
    if (s == null) return false;
    const vs = s.?;

    if (vs.swapchain.image_layout_initialized != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, vs.swapchain.image_layout_initialized);
        vs.swapchain.image_layout_initialized = null;
    }

    log.cardinal_log_info("[INIT] Recreating swapchain_image_layout_initialized for {d} swapchain images", .{vs.swapchain.image_count});
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const layout_ptr = memory.cardinal_alloc(mem_alloc, vs.swapchain.image_count * @sizeOf(bool));
    if (layout_ptr == null) {
        log.cardinal_log_error("[INIT] Failed to allocate swapchain_image_layout_initialized array", .{});
        return false;
    }
    @memset(@as([*]u8, @ptrCast(layout_ptr))[0..(vs.swapchain.image_count * @sizeOf(bool))], 0);
    vs.swapchain.image_layout_initialized = @as([*]bool, @ptrCast(@alignCast(layout_ptr)));
    return true;
}

pub export fn vk_destroy_commands_sync(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    vulkan_mt.cardinal_mt_subsystem_shutdown();
    log.cardinal_log_info("[CLEANUP] Multi-threading subsystem shutdown completed", .{});

    if (vs.context.device != null) {
        _ = c.vkDeviceWaitIdle(vs.context.device);
    }

    if (vs.sync.timeline_semaphore != null) {
        c.vkDestroySemaphore(vs.context.device, vs.sync.timeline_semaphore, null);
        vs.sync.timeline_semaphore = null;
    }

    // Since we are destroying the semaphore, we must also reset the sync manager state
    // to prevent use of stale handles or mismatched counters
    if (vs.sync_manager != null) {
        const sm = @as(?*types.VulkanSyncManager, @ptrCast(vs.sync_manager));
        if (sm != null) {
            sm.?.timeline_semaphore = null;
            sm.?.initialized = false;
        }
    } else {
        // If sync_manager pointer is null but we are destroying s.sync (embedded),
        // we should mark s.sync as uninitialized too.
        vs.sync.initialized = false;
    }

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);

    if (vs.sync.image_acquired_semaphores != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.sync.image_acquired_semaphores.?[i] != null) {
                c.vkDestroySemaphore(vs.context.device, vs.sync.image_acquired_semaphores.?[i], null);
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.sync.image_acquired_semaphores)));
        vs.sync.image_acquired_semaphores = null;
    }

    if (vs.sync.render_finished_semaphores != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.sync.render_finished_semaphores.?[i] != null) {
                c.vkDestroySemaphore(vs.context.device, vs.sync.render_finished_semaphores.?[i], null);
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.sync.render_finished_semaphores)));
        vs.sync.render_finished_semaphores = null;
    }

    if (vs.sync.in_flight_fences != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.sync.in_flight_fences.?[i] != null) {
                c.vkDestroyFence(vs.context.device, vs.sync.in_flight_fences.?[i], null);
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.sync.in_flight_fences)));
        vs.sync.in_flight_fences = null;
    }

    if (vs.swapchain.image_layout_initialized != null) {
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.swapchain.image_layout_initialized)));
        vs.swapchain.image_layout_initialized = null;
    }

    if (vs.commands.buffers != null) {
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.commands.buffers)));
        vs.commands.buffers = null;
    }

    if (vs.commands.secondary_buffers != null) {
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.commands.secondary_buffers)));
        vs.commands.secondary_buffers = null;
    }

    if (vs.commands.scene_secondary_buffers != null) {
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.commands.scene_secondary_buffers)));
        vs.commands.scene_secondary_buffers = null;
    }

    if (vs.commands.pools != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.commands.pools.?[i] != null) {
                c.vkDestroyCommandPool(vs.context.device, vs.commands.pools.?[i], null);
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.commands.pools)));
        vs.commands.pools = null;
    }
}

pub export fn vk_record_cmd(s: ?*types.VulkanState, image_index: u32) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    vs.current_image_index = image_index;

    // Update frame uniforms before any recording
    vk_update_frame_uniforms(vs);

    const cmd = select_command_buffer(vs);
    if (cmd == null) return;

    log.cardinal_log_info("[CMD] Frame {d}: Recording command buffer {any} (buffer {d}) for image {d}", .{ vs.sync.current_frame, cmd, vs.commands.current_buffer_index, image_index });

    if (!validate_swapchain_image(vs, image_index)) return;
    if (!begin_command_buffer(vs, cmd)) return;

    // Shadow Pass
    if (vs.pipelines.use_pbr_pipeline and vs.current_rendering_mode == types.CardinalRenderingMode.NORMAL) {
        vk_shadows.vk_shadow_render(vs, cmd);
    }

    var clears: [2]c.VkClearValue = undefined;
    clears[0].color.float32[0] = 0.05;
    clears[0].color.float32[1] = 0.05;
    clears[0].color.float32[2] = 0.08;
    clears[0].color.float32[3] = 1.0;
    clears[1].depthStencil.depth = 1.0;
    clears[1].depthStencil.stencil = 0;

    const use_depth = vs.swapchain.depth_image_view != null and vs.swapchain.depth_image != null;

    // Use RenderGraph if available
    if (vs.render_graph) |rg_ptr| {
        const rg = @as(*render_graph.RenderGraph, @ptrCast(@alignCast(rg_ptr)));
        
        // Register/Update resources
        rg.register_image(types.RESOURCE_ID_BACKBUFFER, vs.swapchain.images.?[image_index]) catch {};
        if (use_depth) {
            rg.register_image(types.RESOURCE_ID_DEPTHBUFFER, vs.swapchain.depth_image) catch {};
        }

        // Update Initial States
        var bb_state = render_graph.ResourceState{
            .access_mask = 0,
            .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        if (vs.swapchain.image_layout_initialized != null and vs.swapchain.image_layout_initialized.?[image_index]) {
            bb_state.layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
            bb_state.stage_mask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
        } else {
            vs.swapchain.image_layout_initialized.?[image_index] = true;
        }
        rg.set_resource_state(types.RESOURCE_ID_BACKBUFFER, bb_state) catch {};

        if (use_depth) {
            var db_state = render_graph.ResourceState{
                .access_mask = 0,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
                .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            };
            if (vs.swapchain.depth_layout_initialized) {
                db_state.layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
                db_state.stage_mask = c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT;
                db_state.access_mask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
            } else {
                vs.swapchain.depth_layout_initialized = true;
            }
            rg.set_resource_state(types.RESOURCE_ID_DEPTHBUFFER, db_state) catch {};
        }

        // Execute Graph (This inserts barriers and calls pass callback)
        rg.execute(cmd, vs);

    } else {
        transition_images(vs, cmd, image_index, use_depth);

        var scene_drawn = false;

        if (vs.current_scene != null) {
            if (vs.commands.scene_secondary_buffers != null) {
                vk_record_scene_with_secondary_buffers(vs, cmd, image_index, use_depth, &clears);
                scene_drawn = true;
            } else {
                if (begin_dynamic_rendering(vs, cmd, image_index, use_depth, &clears, true, 0)) {
                    vk_record_scene_content(vs, cmd);
                    end_dynamic_rendering(vs, cmd);
                    scene_drawn = true;
                }
            }
        } else {
            // Clear screen if no scene
            if (begin_dynamic_rendering(vs, cmd, image_index, use_depth, &clears, true, 0)) {
                end_dynamic_rendering(vs, cmd);
                scene_drawn = true;
            }
        }

    }

    // Skybox Rendering
    if (vs.pipelines.use_skybox_pipeline and vs.pipelines.skybox_pipeline.initialized and vs.pipelines.skybox_pipeline.texture.is_allocated) {
        if (vs.pipelines.use_pbr_pipeline and vs.pipelines.pbr_pipeline.uniformBufferMapped != null) {
            const ubo = @as(*types.PBRUniformBufferObject, @ptrCast(@alignCast(vs.pipelines.pbr_pipeline.uniformBufferMapped)));
            
            if (begin_dynamic_rendering(vs, cmd, image_index, use_depth, &clears, false, 0)) {
                var view: math.Mat4 = undefined;
                var proj: math.Mat4 = undefined;
                view.data = ubo.view;
                proj.data = ubo.proj;
                vk_skybox.render(&vs.pipelines.skybox_pipeline, cmd, view, proj);
                end_dynamic_rendering(vs, cmd);
            }
        }
    }

    if (vs.ui_record_callback != null) {
        // Load contents from previous pass (whether scene was drawn or just cleared)
        if (begin_dynamic_rendering(vs, cmd, image_index, use_depth, &clears, false, 0)) {
            vs.ui_record_callback.?(cmd);
            end_dynamic_rendering(vs, cmd);
        }
    }

    end_recording(vs, cmd, image_index);
}

pub export fn vk_prepare_mesh_shader_rendering(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    if (!vs.pipelines.use_mesh_shader_pipeline or
        vs.pipelines.mesh_shader_pipeline.pipeline == null or
        vs.current_scene == null)
    {
        return;
    }

    const material_buffer = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.materialBuffer else null;
    const lighting_buffer = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.lightingBuffer else null;

    var texture_views: ?[*]c.VkImageView = null;
    var samplers: ?[*]c.VkSampler = null;
    var texture_count: u32 = 0;

    if (vs.pipelines.use_pbr_pipeline and vs.pipelines.pbr_pipeline.textureManager != null and
        vs.pipelines.pbr_pipeline.textureManager.?.textureCount > 0)
    {
        texture_count = vs.pipelines.pbr_pipeline.textureManager.?.textureCount;

        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        const views_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkImageView) * texture_count);
        const samplers_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkSampler) * texture_count);

        texture_views = if (views_ptr) |p| @as([*]c.VkImageView, @ptrCast(@alignCast(p))) else null;
        samplers = if (samplers_ptr) |p| @as([*]c.VkSampler, @ptrCast(@alignCast(p))) else null;

        if (texture_views != null and samplers != null) {
            var i: u32 = 0;
            while (i < texture_count) : (i += 1) {
                texture_views.?[i] = vs.pipelines.pbr_pipeline.textureManager.?.textures.?[i].view;
                const texSampler = vs.pipelines.pbr_pipeline.textureManager.?.textures.?[i].sampler;
                samplers.?[i] = if (texSampler != null) texSampler else vs.pipelines.pbr_pipeline.textureManager.?.defaultSampler;
            }
        } else {
            if (texture_views) |p| memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(p)));
            if (samplers) |p| memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(p)));
            texture_views = null;
            samplers = null;
            texture_count = 0;
        }
    }

    if (!vk_mesh_shader.vk_mesh_shader_update_descriptor_buffers(@ptrCast(vs), &vs.pipelines.mesh_shader_pipeline, null, material_buffer, lighting_buffer, texture_views, samplers, texture_count)) {
        log.cardinal_log_error("[MESH_SHADER] Failed to update descriptor buffers during preparation", .{});
    } else {
        log.cardinal_log_debug("[MESH_SHADER] Updated descriptor buffers during preparation (bindless textures: {d})", .{texture_count});
    }

    if (texture_views) |p| {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(p)));
    }
    if (samplers) |p| {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(p)));
    }
}

pub fn vk_get_mt_command_manager() ?*types.CardinalMTCommandManager {
    // Accessing global g_cardinal_mt_subsystem from vulkan_mt.zig
    if (!vulkan_mt.g_cardinal_mt_subsystem.is_running) {
        log.cardinal_log_warn("[MT] Multi-threading subsystem not initialized", .{});
        return null;
    }
    return &vulkan_mt.g_cardinal_mt_subsystem.command_manager;
}
