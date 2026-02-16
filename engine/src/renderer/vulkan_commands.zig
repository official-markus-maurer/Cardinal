const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const tracy = @import("../core/tracy.zig");
const platform = @import("../core/platform.zig");
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
const vk_ssao = @import("vulkan_ssao.zig");
const stack_allocator = @import("../core/stack_allocator.zig");

const cmd_log = log.ScopedLogger("COMMANDS");

const c = @import("vulkan_c.zig").c;

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

fn create_transient_command_pools(s: *types.VulkanState) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const pools_ptr = memory.cardinal_alloc(mem_alloc, s.sync.max_frames_in_flight * @sizeOf(c.VkCommandPool));
    if (pools_ptr == null) return false;

    s.commands.transient_pools = @as([*]c.VkCommandPool, @ptrCast(@alignCast(pools_ptr)));

    var i: u32 = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        const flags: c.VkCommandPoolCreateFlags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT | c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        if (!vk_utils.vk_utils_create_command_pool(s.context.device, s.context.graphics_queue_family, flags, &s.commands.transient_pools.?[i], "transient command pool")) {
            return false;
        }
    }
    cmd_log.warn("Created {d} transient command pools", .{s.sync.max_frames_in_flight});
    return true;
}

fn create_compute_transient_command_pools(s: *types.VulkanState) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const pools_ptr = memory.cardinal_alloc(mem_alloc, s.sync.max_frames_in_flight * @sizeOf(c.VkCommandPool));
    if (pools_ptr == null) return false;

    s.commands.compute_transient_pools = @as([*]c.VkCommandPool, @ptrCast(@alignCast(pools_ptr)));

    var i: u32 = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        const flags: c.VkCommandPoolCreateFlags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT | c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        if (!vk_utils.vk_utils_create_command_pool(s.context.device, s.context.compute_queue_family, flags, &s.commands.compute_transient_pools.?[i], "compute transient command pool")) {
            return false;
        }
    }
    cmd_log.warn("Created {d} compute transient command pools", .{s.sync.max_frames_in_flight});
    return true;
}

fn allocate_command_buffers(s: *types.VulkanState) bool {
    // Primary buffers
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    // Allocate extra space to prevent heap corruption if there's an alignment/stride mismatch
    const buffers_ptr = memory.cardinal_alloc(mem_alloc, (s.sync.max_frames_in_flight + 1) * @sizeOf(c.VkCommandBuffer));
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

    // Alternate Primary Buffers
    // Note: These are allocated as PRIMARY buffers.
    // They serve as an alternate set of primary command buffers (e.g., for double buffering
    // logic or separate submissions), distinct from Vulkan's VK_COMMAND_BUFFER_LEVEL_SECONDARY.
    const sec_buffers_ptr = memory.cardinal_alloc(mem_alloc, (s.sync.max_frames_in_flight + 1) * @sizeOf(c.VkCommandBuffer));
    if (sec_buffers_ptr == null) return false;
    s.commands.alternate_primary_buffers = @as([*]c.VkCommandBuffer, @ptrCast(@alignCast(sec_buffers_ptr)));

    i = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = s.commands.pools.?[i];
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;

        if (c.vkAllocateCommandBuffers(s.context.device, &ai, &s.commands.alternate_primary_buffers.?[i]) != c.VK_SUCCESS) {
            return false;
        }
    }
    cmd_log.warn("Allocated {d} alternate primary command buffers", .{s.sync.max_frames_in_flight});

    // Compute primary buffers (recorded on compute transient pools)
    const comp_buffers_ptr = memory.cardinal_alloc(mem_alloc, (s.sync.max_frames_in_flight + 1) * @sizeOf(c.VkCommandBuffer));
    if (comp_buffers_ptr == null) return false;
    s.commands.compute_primary_buffers = @as([*]c.VkCommandBuffer, @ptrCast(@alignCast(comp_buffers_ptr)));

    i = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = if (s.commands.compute_transient_pools != null) s.commands.compute_transient_pools.?[i] else s.commands.pools.?[i];
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;

        if (c.vkAllocateCommandBuffers(s.context.device, &ai, &s.commands.compute_primary_buffers.?[i]) != c.VK_SUCCESS) {
            return false;
        }
    }
    cmd_log.warn("Allocated {d} compute primary command buffers", .{s.sync.max_frames_in_flight});

    // Scene secondary buffers (real secondary level)
    const scene_sec_ptr = memory.cardinal_alloc(mem_alloc, (s.sync.max_frames_in_flight + 1) * @sizeOf(c.VkCommandBuffer));
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
    cmd_log.warn("Allocated {d} scene secondary command buffers", .{s.sync.max_frames_in_flight});

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
    cmd_log.info("Initializing sync objects via centralized manager", .{});
    return vk_sync_manager.vulkan_sync_manager_init(&s.sync, s.context.device, s.context.graphics_queue, s.sync.max_frames_in_flight, s.config.timeline_max_ahead);
}

fn select_command_buffer(s: *types.VulkanState) c.VkCommandBuffer {
    if (s.commands.current_buffer_index == 0) {
        if (s.commands.buffers == null) {
            cmd_log.err("Frame {d}: command_buffers array is null", .{s.sync.current_frame});
            return null;
        }
        return s.commands.buffers.?[s.sync.current_frame];
    } else {
        if (s.commands.alternate_primary_buffers == null) {
            cmd_log.err("Frame {d}: alternate_primary_buffers array is null", .{s.sync.current_frame});
            return null;
        }
        return s.commands.alternate_primary_buffers.?[s.sync.current_frame];
    }
}

fn validate_swapchain_image(s: *types.VulkanState, image_index: u32) bool {
    if (s.swapchain.image_count == 0 or image_index >= s.swapchain.image_count) {
        cmd_log.err("Frame {d}: Invalid image index {d} (count {d})", .{ s.sync.current_frame, image_index, s.swapchain.image_count });
        return false;
    }
    if (s.swapchain.images == null or s.swapchain.image_views == null) {
        cmd_log.err("Frame {d}: Swapchain image arrays are null", .{s.sync.current_frame});
        return false;
    }
    if (s.swapchain.image_layout_initialized == null) {
        cmd_log.err("Frame {d}: Image layout initialization array is null", .{s.sync.current_frame});
        return false;
    }
    if (s.swapchain.extent.width == 0 or s.swapchain.extent.height == 0) {
        cmd_log.err("Frame {d}: Invalid swapchain extent {d}x{d}", .{ s.sync.current_frame, s.swapchain.extent.width, s.swapchain.extent.height });
        return false;
    }
    return true;
}

fn begin_command_buffer(s: *types.VulkanState, cmd: c.VkCommandBuffer) bool {
    cmd_log.info("Frame {d}: Resetting command buffer {any}", .{ s.sync.current_frame, cmd });
    const reset_result = c.vkResetCommandBuffer(cmd, 0);
    if (reset_result != c.VK_SUCCESS) {
        cmd_log.err("Frame {d}: Failed to reset command buffer: {d}", .{ s.sync.current_frame, reset_result });
        return false;
    }

    var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    cmd_log.info("Frame {d}: Beginning command buffer {any} with flags {d}", .{ s.sync.current_frame, cmd, bi.flags });
    const begin_result = c.vkBeginCommandBuffer(cmd, &bi);
    if (begin_result != c.VK_SUCCESS) {
        cmd_log.err("Frame {d}: Failed to begin command buffer: {d}", .{ s.sync.current_frame, begin_result });
        return false;
    }
    return true;
}

fn transition_images(s: *types.VulkanState, cmd: c.VkCommandBuffer, image_index: u32, use_depth: bool) void {
    const thread_id = platform.get_current_thread_id();

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
            cmd_log.warn("Pipeline barrier validation failed for depth image transition", .{});
        }

        s.context.vkCmdPipelineBarrier2.?(cmd, &dep);
        s.swapchain.depth_layout_initialized = true;
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
        cmd_log.warn("Pipeline barrier validation failed for swapchain image transition", .{});
    }

    s.context.vkCmdPipelineBarrier2.?(cmd, &dep);
}

pub fn vk_begin_rendering(s: *types.VulkanState, cmd: c.VkCommandBuffer, image_index: u32, use_depth: bool, depth_view: ?c.VkImageView, clears: [*]const c.VkClearValue, should_clear: bool, flags: c.VkRenderingFlags) bool {
    return vk_begin_rendering_impl(s, cmd, image_index, use_depth, depth_view, null, clears, should_clear, should_clear, flags, true);
}

pub fn vk_begin_rendering_impl(s: *types.VulkanState, cmd: c.VkCommandBuffer, image_index: u32, use_depth: bool, depth_view: ?c.VkImageView, color_view: ?c.VkImageView, clears: [*]const c.VkClearValue, should_clear_color: bool, should_clear_depth: bool, flags: c.VkRenderingFlags, use_color: bool) bool {
    if (s.context.vkCmdBeginRendering == null or s.context.vkCmdEndRendering == null or s.context.vkCmdPipelineBarrier2 == null) {
        cmd_log.err("Frame {d}: Dynamic rendering functions not loaded", .{s.sync.current_frame});
        return false;
    }

    var colorAttachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
    if (use_color) {
        colorAttachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        colorAttachment.imageView = if (color_view) |cv| cv else s.swapchain.image_views.?[image_index];
        colorAttachment.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        colorAttachment.loadOp = if (should_clear_color) c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD;
        colorAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        colorAttachment.clearValue = clears[0];
    }

    var depthAttachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
    if (use_depth) {
        depthAttachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        depthAttachment.imageView = if (depth_view) |dv| dv else s.swapchain.depth_image_view;
        depthAttachment.imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        depthAttachment.loadOp = if (should_clear_depth) c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD;
        depthAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE; // Store depth for SSAO/PBR
        depthAttachment.clearValue = clears[1];
    }

    var renderingInfo = std.mem.zeroes(c.VkRenderingInfo);
    renderingInfo.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
    renderingInfo.flags = flags;
    renderingInfo.renderArea.offset.x = 0;
    renderingInfo.renderArea.offset.y = 0;
    renderingInfo.renderArea.extent = s.swapchain.extent;
    renderingInfo.layerCount = 1;
    renderingInfo.colorAttachmentCount = if (use_color) 1 else 0;
    renderingInfo.pColorAttachments = if (use_color) &colorAttachment else null;
    renderingInfo.pDepthAttachment = if (use_depth) &depthAttachment else null;

    s.context.vkCmdBeginRendering.?(cmd, &renderingInfo);

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

pub fn vk_end_rendering(s: *types.VulkanState, cmd: c.VkCommandBuffer) void {
    if (s.context.vkCmdEndRendering != null) {
        s.context.vkCmdEndRendering.?(cmd);
    }
}

fn end_recording(s: *types.VulkanState, cmd: c.VkCommandBuffer, image_index: u32) void {
    // Note: vkCmdEndRendering is now handled by end_dynamic_rendering or caller

    // Present barrier handled by Render Graph 'Present Pass' when available
    if (s.render_graph == null) {
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

        const thread_id = platform.get_current_thread_id();
        if (!vk_barrier_validation.cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
            cmd_log.warn("Pipeline barrier validation failed for swapchain present transition", .{});
        }

        s.context.vkCmdPipelineBarrier2.?(cmd, &dep);
    }

    cmd_log.info("Frame {d}: Ending command buffer {any}", .{ s.sync.current_frame, cmd });
    const end_result = c.vkEndCommandBuffer(cmd);
    cmd_log.info("Frame {d}: End result: {d}", .{ s.sync.current_frame, end_result });

    if (end_result != c.VK_SUCCESS) {
        cmd_log.err("Frame {d}: Failed to end command buffer: {d}", .{ s.sync.current_frame, end_result });
    }
}

fn vk_update_frame_uniforms(s: *types.VulkanState) void {
    if (s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
        vk_pbr.vk_pbr_update_uniforms(&s.pipelines.pbr_pipeline, &s.pipelines.pbr_pipeline.current_ubo, &s.pipelines.pbr_pipeline.current_lighting, s.sync.current_frame);

        // Update simple uniforms using PBR data if in UV/Wireframe mode
        if (s.current_rendering_mode == .UV or s.current_rendering_mode == .WIREFRAME) {
            var model = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
            vk_simple_pipelines.update_simple_uniforms(s, &model, &s.pipelines.pbr_pipeline.current_ubo.view, &s.pipelines.pbr_pipeline.current_ubo.proj, &s.pipelines.pbr_pipeline.current_ubo.viewPos);
        }
    }
}

pub fn vk_record_scene_content(s: *types.VulkanState, cmd: c.VkCommandBuffer) void {
    const zone = tracy.zoneS(@src(), "Record Scene Content");
    defer zone.end();

    // cmd_log.debug("vk_record_scene_content: Mode {any}", .{s.current_rendering_mode});

    switch (s.current_rendering_mode) {
        types.CardinalRenderingMode.NORMAL => {
            if (s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                vk_pbr.vk_pbr_render(&s.pipelines.pbr_pipeline, cmd, s.current_scene, s.sync.current_frame);
            }
        },
        types.CardinalRenderingMode.UV => {
            if (s.pipelines.uv_pipeline != null and s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                vk_simple_pipelines.render_simple(s, cmd, s.pipelines.uv_pipeline, s.pipelines.uv_pipeline_layout);
            } else {
                cmd_log.err("UV Mode skip: uv_pipe={any}, use_pbr={any}, pbr_init={any}", .{ s.pipelines.uv_pipeline, s.pipelines.use_pbr_pipeline, s.pipelines.pbr_pipeline.initialized });
            }
        },
        types.CardinalRenderingMode.WIREFRAME => {
            if (s.pipelines.wireframe_pipeline != null and s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                vk_simple_pipelines.render_simple(s, cmd, s.pipelines.wireframe_pipeline, s.pipelines.wireframe_pipeline_layout);
            } else {
                cmd_log.err("Wireframe Mode skip: wf_pipe={any}, use_pbr={any}, pbr_init={any}", .{ s.pipelines.wireframe_pipeline, s.pipelines.use_pbr_pipeline, s.pipelines.pbr_pipeline.initialized });
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

pub fn vk_record_scene_with_secondary_buffers(s: *types.VulkanState, primary_cmd: c.VkCommandBuffer, image_index: u32, use_depth: bool, clears: [*]const c.VkClearValue) void {
    _ = image_index;
    _ = clears;
    if (s.commands.scene_secondary_buffers == null) {
        // Fallback to inline
        vk_record_scene_content(s, primary_cmd);
        return;
    }

    // Select secondary buffer for current frame
    const sec_cmd = s.commands.scene_secondary_buffers.?[s.sync.current_frame];

    // Reset
    if (c.vkResetCommandBuffer(sec_cmd, 0) != c.VK_SUCCESS) {
        cmd_log.err("Failed to reset secondary command buffer", .{});
        return;
    }

    // Prepare Inheritance
    const color_format: c.VkFormat = c.VK_FORMAT_R16G16B16A16_SFLOAT;
    const depth_format = s.swapchain.depth_format;

    var inheritance_rendering_info = std.mem.zeroes(c.VkCommandBufferInheritanceRenderingInfo);
    inheritance_rendering_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_RENDERING_INFO;
    inheritance_rendering_info.colorAttachmentCount = 1;
    inheritance_rendering_info.pColorAttachmentFormats = &color_format;
    inheritance_rendering_info.depthAttachmentFormat = if (use_depth) depth_format else c.VK_FORMAT_UNDEFINED;
    inheritance_rendering_info.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
    inheritance_rendering_info.flags = 0;

    var inheritance_info = std.mem.zeroes(c.VkCommandBufferInheritanceInfo);
    inheritance_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO;
    inheritance_info.pNext = &inheritance_rendering_info;
    inheritance_info.renderPass = null;
    inheritance_info.subpass = 0;
    inheritance_info.framebuffer = null;

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT | c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    begin_info.pInheritanceInfo = &inheritance_info;

    // Begin Secondary
    if (c.vkBeginCommandBuffer(sec_cmd, &begin_info) != c.VK_SUCCESS) {
        cmd_log.err("Failed to begin secondary command buffer", .{});
        return;
    }

    // Set Viewport and Scissor (Required in secondary buffer if not inherited, but dynamic rendering inheritance is tricky.
    // Explicitly setting them is safer.)
    var vp = std.mem.zeroes(c.VkViewport);
    vp.x = 0;
    vp.y = 0;
    vp.width = @floatFromInt(s.swapchain.extent.width);
    vp.height = @floatFromInt(s.swapchain.extent.height);
    vp.minDepth = 0.0;
    vp.maxDepth = 1.0;
    c.vkCmdSetViewport(sec_cmd, 0, 1, &vp);

    var sc = std.mem.zeroes(c.VkRect2D);
    sc.offset.x = 0;
    sc.offset.y = 0;
    sc.extent = s.swapchain.extent;
    c.vkCmdSetScissor(sec_cmd, 0, 1, &sc);

    // Record Content
    vk_record_scene_content(s, sec_cmd);

    // End Secondary
    if (c.vkEndCommandBuffer(sec_cmd) != c.VK_SUCCESS) {
        cmd_log.err("Failed to end secondary command buffer", .{});
        return;
    }

    // Execute
    c.vkCmdExecuteCommands(primary_cmd, 1, &sec_cmd);
}

// Exported functions
pub export fn vk_create_commands_sync(s: ?*types.VulkanState) callconv(.c) bool {
    if (s == null) return false;
    const vs = s.?;

    vs.sync.max_frames_in_flight = 3;
    vs.sync.current_frame = 0;

    if (!create_command_pools(vs)) return false;
    if (!create_transient_command_pools(vs)) {
        cmd_log.warn("Failed to create transient command pools, continuing without them", .{});
        // Not fatal; immediate operations will fall back to main pools
        vs.commands.transient_pools = null;
    }
    if (!create_compute_transient_command_pools(vs)) {
        cmd_log.warn("Failed to create compute transient command pools, continuing without them", .{});
        vs.commands.compute_transient_pools = null;
    }
    if (!allocate_command_buffers(vs)) return false;

    vs.commands.current_buffer_index = 0;

    cmd_log.warn("Allocating swapchain_image_layout_initialized for {d} swapchain images", .{vs.swapchain.image_count});
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
        cmd_log.warn("Failed to initialize multi-threading subsystem, continuing without MT support", .{});
    } else {
        cmd_log.info("Multi-threading subsystem initialized with {d} threads", .{optimal_thread_count});
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

    cmd_log.info("Recreating swapchain_image_layout_initialized for {d} swapchain images", .{vs.swapchain.image_count});
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const layout_ptr = memory.cardinal_alloc(mem_alloc, vs.swapchain.image_count * @sizeOf(bool));
    if (layout_ptr == null) {
        cmd_log.err("Failed to allocate swapchain_image_layout_initialized array", .{});
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
    cmd_log.info("Multi-threading subsystem shutdown completed", .{});

    if (vs.context.device != null) {
        _ = c.vkDeviceWaitIdle(vs.context.device);
    }

    if (vs.sync.timeline_semaphore != null) {
        c.vkDestroySemaphore(vs.context.device, vs.sync.timeline_semaphore, null);
        vs.sync.timeline_semaphore = null;
    }

    if (vs.sync_manager != null) {
        const sm = @as(?*types.VulkanSyncManager, @ptrCast(vs.sync_manager));
        if (sm != null) {
            sm.?.timeline_semaphore = null;
            sm.?.initialized = false;
        }
    } else {
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

    if (vs.commands.alternate_primary_buffers != null) {
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.commands.alternate_primary_buffers)));
        vs.commands.alternate_primary_buffers = null;
    }

    if (vs.commands.compute_primary_buffers != null) {
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.commands.compute_primary_buffers)));
        vs.commands.compute_primary_buffers = null;
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
    if (vs.commands.transient_pools != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.commands.transient_pools.?[i] != null) {
                c.vkDestroyCommandPool(vs.context.device, vs.commands.transient_pools.?[i], null);
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.commands.transient_pools)));
        vs.commands.transient_pools = null;
    }
    if (vs.commands.compute_transient_pools != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.commands.compute_transient_pools.?[i] != null) {
                c.vkDestroyCommandPool(vs.context.device, vs.commands.compute_transient_pools.?[i], null);
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.commands.compute_transient_pools)));
        vs.commands.compute_transient_pools = null;
    }
}

pub export fn vk_record_cmd(s: ?*types.VulkanState, image_index: u32) callconv(.c) void {
    const zone = tracy.zoneS(@src(), "Record Command Buffer");
    defer zone.end();

    if (s == null) return;
    const vs = s.?;

    vs.current_image_index = image_index;

    // Update frame uniforms before any recording
    vk_update_frame_uniforms(vs);

    const cmd = select_command_buffer(vs);
    if (cmd == null) return;

    cmd_log.info("Frame {d}: Recording command buffer {any} (buffer {d}) for image {d}", .{ vs.sync.current_frame, cmd, vs.commands.current_buffer_index, image_index });

    if (!validate_swapchain_image(vs, image_index)) return;

    if (!begin_command_buffer(vs, cmd)) return;

    // cmd_log.debug("Started command buffer", .{});

    // Depth layout transitions handled by RenderGraph passes

    // Shadow/Depth/SSAO are scheduled via RenderGraph passes

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
            // Register the swapchain depth image directly.
            // This ensures we share the same depth buffer between RenderGraph passes and manual passes (like Skybox),
            // preventing layout mismatches and validation errors.
            rg.register_image(types.RESOURCE_ID_DEPTHBUFFER, vs.swapchain.depth_image) catch {};
        }

        // Update HDR Color Transient Image and reset its state for this frame
        const hdr_desc = render_graph.ImageDesc{
            .format = c.VK_FORMAT_R16G16B16A16_SFLOAT,
            .width = vs.swapchain.extent.width,
            .height = vs.swapchain.extent.height,
            .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
            .aspect_mask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        };
        rg.update_transient_image(types.RESOURCE_ID_HDR_COLOR, hdr_desc, vs) catch {};
        const hdr_state = render_graph.ResourceState{
            .access_mask = 0,
            .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        rg.set_resource_state(types.RESOURCE_ID_HDR_COLOR, hdr_state) catch |err| {
            cmd_log.err("Failed to set HDR color state: {s}", .{@errorName(err)});
        };
        if (vs.pipelines.use_ssao and vs.pipelines.ssao_pipeline.initialized) {
            rg.register_image(types.RESOURCE_ID_SSAO_BLURRED, vs.pipelines.ssao_pipeline.ssao_blur_image[vs.sync.current_frame]) catch {};
        }
        if (vs.pipelines.use_post_process and vs.pipelines.post_process_pipeline.initialized) {
            rg.register_image(types.RESOURCE_ID_BLOOM, vs.pipelines.post_process_pipeline.bloom_image) catch {};
        }
        if (vs.pipelines.use_pbr_pipeline and vs.pipelines.pbr_pipeline.shadowMapImage != null) {
            rg.register_image(types.RESOURCE_ID_SHADOW_MAP, vs.pipelines.pbr_pipeline.shadowMapImage) catch {};
        }

        // Update Initial States
        // Backbuffer (swapchain image)
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
        rg.set_resource_state(types.RESOURCE_ID_BACKBUFFER, bb_state) catch |err| {
            cmd_log.err("Failed to set backbuffer state: {s}", .{@errorName(err)});
        };

        // Depth buffer: treat as coming from an undefined state at the start of each frame.
        // The depth pre-pass will transition it to the correct attachment layout and clear it.
        if (use_depth) {
            const depth_state = render_graph.ResourceState{
                .access_mask = 0,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
                .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            };
            rg.set_resource_state(types.RESOURCE_ID_DEPTHBUFFER, depth_state) catch |err| {
                cmd_log.err("Failed to set depth buffer state: {s}", .{@errorName(err)});
            };
        }

        // SSAO blurred texture: also start from an undefined state each frame so the SSAO
        // pass can transition and write it before PBR samples it.
        if (vs.pipelines.use_ssao and vs.pipelines.ssao_pipeline.initialized) {
            const ssao_state = render_graph.ResourceState{
                .access_mask = 0,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
                .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            };
            rg.set_resource_state(types.RESOURCE_ID_SSAO_BLURRED, ssao_state) catch |err| {
                cmd_log.err("Failed to set SSAO blurred state: {s}", .{@errorName(err)});
            };
        }

        if (vs.pipelines.use_post_process and vs.pipelines.post_process_pipeline.initialized) {
            const bloom_state = render_graph.ResourceState{
                .access_mask = 0,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
                .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            };
            rg.set_resource_state(types.RESOURCE_ID_BLOOM, bloom_state) catch |err| {
                cmd_log.err("Failed to set bloom state: {s}", .{@errorName(err)});
            };
        }

        if (vs.pipelines.use_pbr_pipeline and vs.pipelines.pbr_pipeline.shadowMapImage != null) {
            const shadow_state = render_graph.ResourceState{
                .access_mask = 0,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
                .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            };
            rg.set_resource_state(types.RESOURCE_ID_SHADOW_MAP, shadow_state) catch |err| {
                cmd_log.err("Failed to set shadow map state: {s}", .{@errorName(err)});
            };
        }

        // Begin compute command buffer if async compute is enabled
        var compute_cmd: c.VkCommandBuffer = null;
        if (vs.config.enable_async_compute and vs.commands.compute_primary_buffers != null) {
            compute_cmd = vs.commands.compute_primary_buffers.?[vs.sync.current_frame];
            if (compute_cmd != null) {
                var bi_comp = std.mem.zeroes(c.VkCommandBufferBeginInfo);
                bi_comp.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
                bi_comp.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
                _ = c.vkBeginCommandBuffer(compute_cmd, &bi_comp);
            }
        }

        // Execute Graph (This inserts barriers and calls pass callback)
        rg.execute(cmd, compute_cmd, vs);

        // End compute command buffer if it has any commands
        if (compute_cmd != null) {
            _ = c.vkEndCommandBuffer(compute_cmd);
        }
    } else {
        cmd_log.err("RenderGraph is null! Cannot record scene.", .{});
    }

    // Skybox handled by RenderGraph passes

    // Transparent Pass is handled inside vk_pbr_render using sorted back-to-front rendering with the Blend pipeline.
    // See vk_pbr.zig for implementation.

    // Lighting Debug Rendering (Visualizes light positions)
    const lighting_buffer = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.lightingBuffers[vs.sync.current_frame] else null;
    if (vs.pipelines.use_pbr_pipeline and lighting_buffer != null and vs.pipelines.pbr_pipeline.debug_flags > 0.0) {}

    // UI handled by RenderGraph passes

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

    const lighting_buffer = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.lightingBuffers[vs.sync.current_frame] else null;
    const shadow_map_view = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.shadowMapView else null;
    const shadow_map_sampler = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.shadowMapSampler else null;
    const shadow_ubo = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.shadowUBOs[vs.sync.current_frame] else null;

    var texture_views: ?[*]c.VkImageView = null;
    var samplers: ?[*]c.VkSampler = null;
    var texture_count: u32 = 0;

    if (vs.pipelines.use_pbr_pipeline and vs.pipelines.pbr_pipeline.textureManager != null and
        vs.pipelines.pbr_pipeline.textureManager.?.textureCount > 0)
    {
        texture_count = vs.pipelines.pbr_pipeline.textureManager.?.textureCount;

        if (vs.frame_allocator) |fa_ptr| {
            const fa = @as(*stack_allocator.StackAllocator, @ptrCast(@alignCast(fa_ptr)));
            // Allocate from stack (no need to free)
            // We use the generic allocator interface or direct calls. Direct calls are better for slices.
            // We need aligned allocation for types.
            const views_slice = fa.allocator().alloc(c.VkImageView, texture_count) catch return;
            const samplers_slice = fa.allocator().alloc(c.VkSampler, texture_count) catch return;

            texture_views = views_slice.ptr;
            samplers = samplers_slice.ptr;
        } else {
            const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
            const views_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkImageView) * texture_count);
            const samplers_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkSampler) * texture_count);

            texture_views = if (views_ptr) |p| @as([*]c.VkImageView, @ptrCast(@alignCast(p))) else null;
            samplers = if (samplers_ptr) |p| @as([*]c.VkSampler, @ptrCast(@alignCast(p))) else null;
        }

        if (texture_views != null and samplers != null) {
            var i: u32 = 0;
            while (i < texture_count) : (i += 1) {
                texture_views.?[i] = vs.pipelines.pbr_pipeline.textureManager.?.textures.?[i].view;
                const texSampler = vs.pipelines.pbr_pipeline.textureManager.?.textures.?[i].sampler;
                samplers.?[i] = if (texSampler != null) texSampler else vs.pipelines.pbr_pipeline.textureManager.?.defaultSampler;
            }
        } else {
            // Cleanup if allocation failed (only for heap)
            if (vs.frame_allocator == null) {
                const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
                if (texture_views) |p| memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(p)));
                if (samplers) |p| memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(p)));
            }
            texture_views = null;
            samplers = null;
            texture_count = 0;
        }
    }

    if (!vk_mesh_shader.vk_mesh_shader_update_descriptor_buffers(@ptrCast(vs), &vs.pipelines.mesh_shader_pipeline, null, lighting_buffer, texture_views, samplers, texture_count, shadow_map_view, shadow_map_sampler, shadow_ubo)) {
        cmd_log.err("Failed to update descriptor buffers during preparation", .{});
    } else {
        cmd_log.debug("Updated descriptor buffers during preparation (bindless textures: {d})", .{texture_count});
    }

    if (vs.frame_allocator == null) {
        if (texture_views) |p| {
            const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(p)));
        }
        if (samplers) |p| {
            const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(p)));
        }
    }
}

pub fn vk_get_mt_command_manager() ?*types.CardinalMTCommandManager {
    // Accessing global g_cardinal_mt_subsystem from vulkan_mt.zig
    if (!vulkan_mt.g_cardinal_mt_subsystem.is_running) {
        cmd_log.warn("[MT] Multi-threading subsystem not initialized", .{});
        return null;
    }
    return &vulkan_mt.g_cardinal_mt_subsystem.command_manager;
}
