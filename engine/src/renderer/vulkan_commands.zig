const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("vulkan_state.h");
    @cInclude("cardinal/renderer/vulkan_commands.h");
    @cInclude("cardinal/renderer/vulkan_utils.h");
    @cInclude("cardinal/renderer/vulkan_barrier_validation.h");
    @cInclude("cardinal/renderer/vulkan_mt.h");
    @cInclude("cardinal/renderer/vulkan_pbr.h");
    @cInclude("vulkan_simple_pipelines.h");
    @cInclude("cardinal/renderer/vulkan_mesh_shader.h");
    @cInclude("cardinal/renderer/vulkan_texture_manager.h");
    
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
    } else {
        @cInclude("sys/syscall.h");
        @cInclude("unistd.h");
    }
});

// Helper to get current thread ID
fn get_current_thread_id() u32 {
    if (builtin.os.tag == .windows) {
        return c.GetCurrentThreadId();
    } else {
        return @intCast(c.syscall(c.SYS_gettid));
    }
}

// Internal helpers

fn create_command_pools(s: *c.VulkanState) bool {
    const pools_ptr = c.malloc(s.sync.max_frames_in_flight * @sizeOf(c.VkCommandPool));
    if (pools_ptr == null) return false;
    
    s.commands.pools = @as([*]c.VkCommandPool, @ptrCast(@alignCast(pools_ptr)));
    
    var i: u32 = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        if (!c.vk_utils_create_command_pool(s.context.device, s.context.graphics_queue_family,
                                          c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                                          &s.commands.pools[i], "graphics command pool")) {
            return false;
        }
    }
    log.cardinal_log_warn("[INIT] Created {d} command pools", .{s.sync.max_frames_in_flight});
    return true;
}

fn allocate_command_buffers(s: *c.VulkanState) bool {
    // Primary buffers
    const buffers_ptr = c.malloc(s.sync.max_frames_in_flight * @sizeOf(c.VkCommandBuffer));
    if (buffers_ptr == null) return false;
    s.commands.buffers = @as([*]c.VkCommandBuffer, @ptrCast(@alignCast(buffers_ptr)));

    var i: u32 = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = s.commands.pools[i];
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        
        if (c.vkAllocateCommandBuffers(s.context.device, &ai, &s.commands.buffers[i]) != c.VK_SUCCESS) {
            return false;
        }
    }
    log.cardinal_log_warn("[INIT] Allocated {d} primary command buffers", .{s.sync.max_frames_in_flight});

    // Secondary buffers
    const sec_buffers_ptr = c.malloc(s.sync.max_frames_in_flight * @sizeOf(c.VkCommandBuffer));
    if (sec_buffers_ptr == null) return false;
    s.commands.secondary_buffers = @as([*]c.VkCommandBuffer, @ptrCast(@alignCast(sec_buffers_ptr)));

    i = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        var ai = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        ai.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        ai.commandPool = s.commands.pools[i];
        ai.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY; // Allocated as PRIMARY as per C code comments
        ai.commandBufferCount = 1;

        if (c.vkAllocateCommandBuffers(s.context.device, &ai, &s.commands.secondary_buffers[i]) != c.VK_SUCCESS) {
            return false;
        }
    }
    log.cardinal_log_warn("[INIT] Allocated {d} secondary command buffers", .{s.sync.max_frames_in_flight});
    return true;
}

fn create_sync_objects(s: *c.VulkanState) bool {
    // Image acquired semaphores
    if (s.sync.image_acquired_semaphores != null) {
        var i: u32 = 0;
        while (i < s.sync.max_frames_in_flight) : (i += 1) {
            if (s.sync.image_acquired_semaphores[i] != null) {
                c.vkDestroySemaphore(s.context.device, s.sync.image_acquired_semaphores[i], null);
            }
        }
        c.free(@as(?*anyopaque, @ptrCast(s.sync.image_acquired_semaphores)));
        s.sync.image_acquired_semaphores = null;
    }
    
    const sem_ptr = c.calloc(s.sync.max_frames_in_flight, @sizeOf(c.VkSemaphore));
    if (sem_ptr == null) return false;
    s.sync.image_acquired_semaphores = @as([*]c.VkSemaphore, @ptrCast(@alignCast(sem_ptr)));

    var i: u32 = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        var sci = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        sci.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if (c.vkCreateSemaphore(s.context.device, &sci, null, &s.sync.image_acquired_semaphores[i]) != c.VK_SUCCESS) {
            log.cardinal_log_error("[INIT] Failed to create image acquired semaphore for frame {d}", .{i});
            return false;
        }
    }
    log.cardinal_log_warn("[INIT] Created {d} acquire semaphores", .{s.sync.max_frames_in_flight});

    // Render finished semaphores
    if (s.sync.render_finished_semaphores != null) {
        i = 0;
        while (i < s.sync.max_frames_in_flight) : (i += 1) {
            if (s.sync.render_finished_semaphores[i] != null) {
                c.vkDestroySemaphore(s.context.device, s.sync.render_finished_semaphores[i], null);
            }
        }
        c.free(@as(?*anyopaque, @ptrCast(s.sync.render_finished_semaphores)));
        s.sync.render_finished_semaphores = null;
    }
    
    const rf_sem_ptr = c.calloc(s.sync.max_frames_in_flight, @sizeOf(c.VkSemaphore));
    if (rf_sem_ptr == null) return false;
    s.sync.render_finished_semaphores = @as([*]c.VkSemaphore, @ptrCast(@alignCast(rf_sem_ptr)));

    i = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        var sci = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        sci.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if (c.vkCreateSemaphore(s.context.device, &sci, null, &s.sync.render_finished_semaphores[i]) != c.VK_SUCCESS) {
            log.cardinal_log_error("[INIT] Failed to create render finished semaphore for frame {d}", .{i});
            return false;
        }
    }
    log.cardinal_log_warn("[INIT] Created {d} render finished semaphores", .{s.sync.max_frames_in_flight});

    // In-flight fences
    if (s.sync.in_flight_fences != null) {
        i = 0;
        while (i < s.sync.max_frames_in_flight) : (i += 1) {
            if (s.sync.in_flight_fences[i] != null) {
                c.vkDestroyFence(s.context.device, s.sync.in_flight_fences[i], null);
            }
        }
        c.free(@as(?*anyopaque, @ptrCast(s.sync.in_flight_fences)));
        s.sync.in_flight_fences = null;
    }
    
    const fences_ptr = c.calloc(s.sync.max_frames_in_flight, @sizeOf(c.VkFence));
    if (fences_ptr == null) return false;
    s.sync.in_flight_fences = @as([*]c.VkFence, @ptrCast(@alignCast(fences_ptr)));

    i = 0;
    while (i < s.sync.max_frames_in_flight) : (i += 1) {
        if (!c.vk_utils_create_fence(s.context.device, &s.sync.in_flight_fences[i], true, "in-flight fence")) {
            log.cardinal_log_error("[INIT] Failed to create in-flight fence for frame {d}", .{i});
            return false;
        }
    }
    log.cardinal_log_warn("[INIT] Created {d} in-flight fences", .{s.sync.max_frames_in_flight});

    // Timeline semaphore
    var timelineTypeInfo = std.mem.zeroes(c.VkSemaphoreTypeCreateInfo);
    timelineTypeInfo.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
    timelineTypeInfo.semaphoreType = c.VK_SEMAPHORE_TYPE_TIMELINE;
    timelineTypeInfo.initialValue = 0;

    var semCI = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semCI.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    semCI.pNext = &timelineTypeInfo;

    const result = c.vkCreateSemaphore(s.context.device, &semCI, null, &s.sync.timeline_semaphore);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[INIT] Failed to create timeline semaphore: {d}", .{result});
        return false;
    }
    log.cardinal_log_warn("[INIT] Timeline semaphore created: {any}", .{s.sync.timeline_semaphore});

    return true;
}

fn select_command_buffer(s: *c.VulkanState) c.VkCommandBuffer {
    if (s.commands.current_buffer_index == 0) {
        if (s.commands.buffers == null) {
            log.cardinal_log_error("[CMD] Frame {d}: command_buffers array is null", .{s.sync.current_frame});
            return null;
        }
        return s.commands.buffers[s.sync.current_frame];
    } else {
        if (s.commands.secondary_buffers == null) {
            log.cardinal_log_error("[CMD] Frame {d}: secondary_command_buffers array is null", .{s.sync.current_frame});
            return null;
        }
        return s.commands.secondary_buffers[s.sync.current_frame];
    }
}

fn validate_swapchain_image(s: *c.VulkanState, image_index: u32) bool {
    if (s.swapchain.image_count == 0 or image_index >= s.swapchain.image_count) {
        log.cardinal_log_error("[CMD] Frame {d}: Invalid image index {d} (count {d})", .{s.sync.current_frame, image_index, s.swapchain.image_count});
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
        log.cardinal_log_error("[CMD] Frame {d}: Invalid swapchain extent {d}x{d}", .{s.sync.current_frame, s.swapchain.extent.width, s.swapchain.extent.height});
        return false;
    }
    return true;
}

fn begin_command_buffer(s: *c.VulkanState, cmd: c.VkCommandBuffer) bool {
    log.cardinal_log_info("[CMD] Frame {d}: Resetting command buffer {any}", .{s.sync.current_frame, cmd});
    const reset_result = c.vkResetCommandBuffer(cmd, 0);
    if (reset_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[CMD] Frame {d}: Failed to reset command buffer: {d}", .{s.sync.current_frame, reset_result});
        return false;
    }

    var bi = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    bi.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    
    log.cardinal_log_info("[CMD] Frame {d}: Beginning command buffer {any} with flags {d}", .{s.sync.current_frame, cmd, bi.flags});
    const begin_result = c.vkBeginCommandBuffer(cmd, &bi);
    if (begin_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[CMD] Frame {d}: Failed to begin command buffer: {d}", .{s.sync.current_frame, begin_result});
        return false;
    }
    return true;
}

fn transition_images(s: *c.VulkanState, cmd: c.VkCommandBuffer, image_index: u32, use_depth: bool) void {
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

        if (!c.cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
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
    barrier.image = s.swapchain.images[image_index];
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;

    if (!s.swapchain.image_layout_initialized[image_index]) {
        barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
        barrier.srcAccessMask = 0;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        s.swapchain.image_layout_initialized[image_index] = true;
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

    if (!c.cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
        log.cardinal_log_warn("[CMD] Pipeline barrier validation failed for swapchain image transition", .{});
    }

    if (s.context.vkCmdPipelineBarrier2 != null) {
        s.context.vkCmdPipelineBarrier2.?(cmd, &dep);
    }
}

fn begin_dynamic_rendering(s: *c.VulkanState, cmd: c.VkCommandBuffer, image_index: u32, use_depth: bool, clears: [*]c.VkClearValue) bool {
    if (s.context.vkCmdBeginRendering == null or s.context.vkCmdEndRendering == null or s.context.vkCmdPipelineBarrier2 == null) {
        log.cardinal_log_error("[CMD] Frame {d}: Dynamic rendering functions not loaded", .{s.sync.current_frame});
        return false;
    }

    var colorAttachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
    colorAttachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    colorAttachment.imageView = s.swapchain.image_views[image_index];
    colorAttachment.imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    colorAttachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
    colorAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
    colorAttachment.clearValue = clears[0];

    var depthAttachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
    if (use_depth) {
        depthAttachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        depthAttachment.imageView = s.swapchain.depth_image_view;
        depthAttachment.imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        depthAttachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        depthAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depthAttachment.clearValue = clears[1];
    }

    var renderingInfo = std.mem.zeroes(c.VkRenderingInfo);
    renderingInfo.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
    renderingInfo.flags = 0;
    renderingInfo.renderArea.offset.x = 0;
    renderingInfo.renderArea.offset.y = 0;
    renderingInfo.renderArea.extent = s.swapchain.extent;
    renderingInfo.layerCount = 1;
    renderingInfo.colorAttachmentCount = 1;
    renderingInfo.pColorAttachments = &colorAttachment;
    renderingInfo.pDepthAttachment = if (use_depth) &depthAttachment else null;

    s.context.vkCmdBeginRendering.?(cmd, &renderingInfo);

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

    return true;
}

fn end_recording(s: *c.VulkanState, cmd: c.VkCommandBuffer, image_index: u32) void {
    if (s.context.vkCmdEndRendering != null) {
        s.context.vkCmdEndRendering.?(cmd);
    }

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
    barrier.image = s.swapchain.images[image_index];
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
    if (!c.cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
        log.cardinal_log_warn("[CMD] Pipeline barrier validation failed for swapchain present transition", .{});
    }

    if (s.context.vkCmdPipelineBarrier2 != null) {
        s.context.vkCmdPipelineBarrier2.?(cmd, &dep);
    }

    log.cardinal_log_info("[CMD] Frame {d}: Ending command buffer {any}", .{s.sync.current_frame, cmd});
    const end_result = c.vkEndCommandBuffer(cmd);
    log.cardinal_log_info("[CMD] Frame {d}: End result: {d}", .{s.sync.current_frame, end_result});

    if (end_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[CMD] Frame {d}: Failed to end command buffer: {d}", .{s.sync.current_frame, end_result});
    }
}

fn vk_record_scene_commands(s: *c.VulkanState, cmd: c.VkCommandBuffer) void {
    switch (s.current_rendering_mode) {
        c.CARDINAL_RENDERING_MODE_NORMAL => {
             if (s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                 var ubo: c.PBRUniformBufferObject = undefined;
                 @memcpy(@as([*]u8, @ptrCast(&ubo))[0..@sizeOf(c.PBRUniformBufferObject)], 
                        @as([*]u8, @ptrCast(s.pipelines.pbr_pipeline.uniformBufferMapped))[0..@sizeOf(c.PBRUniformBufferObject)]);
                 
                 var lighting: c.PBRLightingData = undefined;
                 @memcpy(@as([*]u8, @ptrCast(&lighting))[0..@sizeOf(c.PBRLightingData)],
                        @as([*]u8, @ptrCast(s.pipelines.pbr_pipeline.lightingBufferMapped))[0..@sizeOf(c.PBRLightingData)]);
                 
                 c.vk_pbr_update_uniforms(&s.pipelines.pbr_pipeline, &ubo, &lighting);
                 c.vk_pbr_render(&s.pipelines.pbr_pipeline, cmd, s.current_scene);
             }
        },
        c.CARDINAL_RENDERING_MODE_UV => {
            if (s.pipelines.uv_pipeline != null and s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                 const pbr_ubo: *c.PBRUniformBufferObject = @ptrCast(@alignCast(s.pipelines.pbr_pipeline.uniformBufferMapped));
                 c.vk_update_simple_uniforms(s, &pbr_ubo.model, &pbr_ubo.view, &pbr_ubo.proj);
                 c.vk_render_simple(s, cmd, s.pipelines.uv_pipeline, s.pipelines.uv_pipeline_layout);
            }
        },
        c.CARDINAL_RENDERING_MODE_WIREFRAME => {
            if (s.pipelines.wireframe_pipeline != null and s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                 const pbr_ubo: *c.PBRUniformBufferObject = @ptrCast(@alignCast(s.pipelines.pbr_pipeline.uniformBufferMapped));
                 c.vk_update_simple_uniforms(s, &pbr_ubo.model, &pbr_ubo.view, &pbr_ubo.proj);
                 c.vk_render_simple(s, cmd, s.pipelines.wireframe_pipeline, s.pipelines.wireframe_pipeline_layout);
            }
        },
        c.CARDINAL_RENDERING_MODE_MESH_SHADER => {
             c.vk_mesh_shader_record_frame(s, cmd);
        },
        else => {
            log.cardinal_log_warn("Unknown rendering mode: {d}, falling back to PBR", .{s.current_rendering_mode});
            if (s.pipelines.use_pbr_pipeline and s.pipelines.pbr_pipeline.initialized) {
                var ubo = std.mem.zeroes(c.PBRUniformBufferObject);
                var lighting = std.mem.zeroes(c.PBRLightingData);
                
                if (s.pipelines.pbr_pipeline.uniformBufferMapped != null) {
                    @memcpy(@as([*]u8, @ptrCast(&ubo))[0..@sizeOf(c.PBRUniformBufferObject)], 
                           @as([*]u8, @ptrCast(s.pipelines.pbr_pipeline.uniformBufferMapped))[0..@sizeOf(c.PBRUniformBufferObject)]);
                }
                if (s.pipelines.pbr_pipeline.lightingBufferMapped != null) {
                    @memcpy(@as([*]u8, @ptrCast(&lighting))[0..@sizeOf(c.PBRLightingData)],
                           @as([*]u8, @ptrCast(s.pipelines.pbr_pipeline.lightingBufferMapped))[0..@sizeOf(c.PBRLightingData)]);
                }
                
                c.vk_pbr_update_uniforms(&s.pipelines.pbr_pipeline, &ubo, &lighting);
                c.vk_pbr_render(&s.pipelines.pbr_pipeline, cmd, s.current_scene);
            }
        }
    }
}

fn vk_record_scene_direct(s: *c.VulkanState, cmd: c.VkCommandBuffer) void {
    vk_record_scene_commands(s, cmd);
}

fn vk_record_scene_with_secondary_buffers(s: *c.VulkanState, primary_cmd: c.VkCommandBuffer, image_index: u32) void {
    _ = image_index;
    const mt_manager = vk_get_mt_command_manager();
    if (mt_manager == null or !mt_manager.?.thread_pools[0].is_active) {
        log.cardinal_log_warn("[MT] Secondary command buffers requested but MT subsystem not available", .{});
        vk_record_scene_direct(s, primary_cmd);
        return;
    }

    var secondary_context: c.CardinalSecondaryCommandContext = undefined;
    if (!c.cardinal_mt_allocate_secondary_command_buffer(&mt_manager.?.thread_pools[0], &secondary_context)) {
        log.cardinal_log_warn("[MT] Failed to allocate secondary command buffer, falling back to direct rendering", .{});
        vk_record_scene_direct(s, primary_cmd);
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

    if (!c.cardinal_mt_begin_secondary_command_buffer(&secondary_context, &inheritance_info)) {
        log.cardinal_log_error("[MT] Failed to begin secondary command buffer", .{});
        vk_record_scene_direct(s, primary_cmd);
        return;
    }

    const secondary_cmd = secondary_context.command_buffer;

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

    vk_record_scene_commands(s, secondary_cmd);

    if (!c.cardinal_mt_end_secondary_command_buffer(&secondary_context)) {
        log.cardinal_log_error("[MT] Failed to end secondary command buffer", .{});
        vk_record_scene_direct(s, primary_cmd);
        return;
    }

    c.cardinal_mt_execute_secondary_command_buffers(primary_cmd, &secondary_context, 1);
    log.cardinal_log_debug("[MT] Scene rendered using secondary command buffer", .{});
}

// Exported functions

pub export fn vk_create_commands_sync(s: ?*c.VulkanState) callconv(.c) bool {
    if (s == null) return false;
    const vs = s.?;

    vs.sync.max_frames_in_flight = 3;
    vs.sync.current_frame = 0;

    if (!create_command_pools(vs)) return false;
    if (!allocate_command_buffers(vs)) return false;

    vs.commands.current_buffer_index = 0;

    log.cardinal_log_warn("[INIT] Allocating swapchain_image_layout_initialized for {d} swapchain images", .{vs.swapchain.image_count});
    if (vs.swapchain.image_layout_initialized != null) {
        c.free(vs.swapchain.image_layout_initialized);
        vs.swapchain.image_layout_initialized = null;
    }
    
    const layout_ptr = c.calloc(vs.swapchain.image_count, @sizeOf(bool));
    if (layout_ptr == null) return false;
    vs.swapchain.image_layout_initialized = @as([*]bool, @ptrCast(@alignCast(layout_ptr)));

    if (!create_sync_objects(vs)) return false;

    vs.sync.current_frame_value = 0;
    vs.sync.image_available_value = 1;
    vs.sync.render_complete_value = 2;

    var optimal_thread_count = c.cardinal_mt_get_optimal_thread_count();
    if (optimal_thread_count > 4) {
        optimal_thread_count = 4;
    }

    if (!c.cardinal_mt_subsystem_init(vs, optimal_thread_count)) {
        log.cardinal_log_warn("[INIT] Failed to initialize multi-threading subsystem, continuing without MT support", .{});
    } else {
        log.cardinal_log_info("[INIT] Multi-threading subsystem initialized with {d} threads", .{optimal_thread_count});
    }

    return true;
}

pub export fn vk_recreate_images_in_flight(s: ?*c.VulkanState) callconv(.c) bool {
    if (s == null) return false;
    const vs = s.?;

    if (vs.swapchain.image_layout_initialized != null) {
        c.free(vs.swapchain.image_layout_initialized);
        vs.swapchain.image_layout_initialized = null;
    }
    
    log.cardinal_log_info("[INIT] Recreating swapchain_image_layout_initialized for {d} swapchain images", .{vs.swapchain.image_count});
    const layout_ptr = c.calloc(vs.swapchain.image_count, @sizeOf(bool));
    if (layout_ptr == null) {
        log.cardinal_log_error("[INIT] Failed to allocate swapchain_image_layout_initialized array", .{});
        return false;
    }
    vs.swapchain.image_layout_initialized = @as([*]bool, @ptrCast(@alignCast(layout_ptr)));
    return true;
}

pub export fn vk_destroy_commands_sync(s: ?*c.VulkanState) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    c.cardinal_mt_subsystem_shutdown();
    log.cardinal_log_info("[CLEANUP] Multi-threading subsystem shutdown completed", .{});

    if (vs.context.device != null) {
        _ = c.vkDeviceWaitIdle(vs.context.device);
    }

    if (vs.sync.timeline_semaphore != null) {
        c.vkDestroySemaphore(vs.context.device, vs.sync.timeline_semaphore, null);
        vs.sync.timeline_semaphore = null;
    }

    if (vs.sync.image_acquired_semaphores != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.sync.image_acquired_semaphores[i] != null) {
                c.vkDestroySemaphore(vs.context.device, vs.sync.image_acquired_semaphores[i], null);
            }
        }
        c.free(@as(?*anyopaque, @ptrCast(vs.sync.image_acquired_semaphores)));
        vs.sync.image_acquired_semaphores = null;
    }

    if (vs.sync.render_finished_semaphores != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.sync.render_finished_semaphores[i] != null) {
                c.vkDestroySemaphore(vs.context.device, vs.sync.render_finished_semaphores[i], null);
            }
        }
        c.free(@as(?*anyopaque, @ptrCast(vs.sync.render_finished_semaphores)));
        vs.sync.render_finished_semaphores = null;
    }

    if (vs.sync.in_flight_fences != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.sync.in_flight_fences[i] != null) {
                c.vkDestroyFence(vs.context.device, vs.sync.in_flight_fences[i], null);
            }
        }
        c.free(@as(?*anyopaque, @ptrCast(vs.sync.in_flight_fences)));
        vs.sync.in_flight_fences = null;
    }

    if (vs.swapchain.image_layout_initialized != null) {
        c.free(@as(?*anyopaque, @ptrCast(vs.swapchain.image_layout_initialized)));
        vs.swapchain.image_layout_initialized = null;
    }
    
    if (vs.commands.buffers != null) {
        c.free(@as(?*anyopaque, @ptrCast(vs.commands.buffers)));
        vs.commands.buffers = null;
    }

    if (vs.commands.secondary_buffers != null) {
        c.free(@as(?*anyopaque, @ptrCast(vs.commands.secondary_buffers)));
        vs.commands.secondary_buffers = null;
    }

    if (vs.commands.pools != null) {
        var i: u32 = 0;
        while (i < vs.sync.max_frames_in_flight) : (i += 1) {
            if (vs.commands.pools[i] != null) {
                c.vkDestroyCommandPool(vs.context.device, vs.commands.pools[i], null);
            }
        }
        c.free(@as(?*anyopaque, @ptrCast(vs.commands.pools)));
        vs.commands.pools = null;
    }
}

pub export fn vk_record_cmd(s: ?*c.VulkanState, image_index: u32) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    const cmd = select_command_buffer(vs);
    if (cmd == null) return;

    log.cardinal_log_info("[CMD] Frame {d}: Recording command buffer {any} (buffer {d}) for image {d}", 
                         .{vs.sync.current_frame, cmd, vs.commands.current_buffer_index, image_index});

    if (!validate_swapchain_image(vs, image_index)) return;
    if (!begin_command_buffer(vs, cmd)) return;

    var clears: [2]c.VkClearValue = undefined;
    clears[0].color.float32[0] = 0.05;
    clears[0].color.float32[1] = 0.05;
    clears[0].color.float32[2] = 0.08;
    clears[0].color.float32[3] = 1.0;
    clears[1].depthStencil.depth = 1.0;
    clears[1].depthStencil.stencil = 0;

    const use_depth = vs.swapchain.depth_image_view != null and vs.swapchain.depth_image != null;

    transition_images(vs, cmd, image_index, use_depth);

    if (!begin_dynamic_rendering(vs, cmd, image_index, use_depth, &clears)) {
        _ = c.vkEndCommandBuffer(cmd);
        return;
    }

    if (vs.current_scene != null) {
        const mt_manager = vk_get_mt_command_manager();
        if (mt_manager != null and mt_manager.?.thread_pools[0].is_active) {
            vk_record_scene_with_secondary_buffers(vs, cmd, image_index);
        } else {
            vk_record_scene_direct(vs, cmd);
        }
    }

    if (vs.ui_record_callback != null) {
        vs.ui_record_callback.?(cmd);
    }

    end_recording(vs, cmd, image_index);
}

pub export fn vk_prepare_mesh_shader_rendering(s: ?*c.VulkanState) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    if (!vs.pipelines.use_mesh_shader_pipeline or 
        vs.pipelines.mesh_shader_pipeline.pipeline == null or 
        vs.current_scene == null) {
        return;
    }

    const material_buffer = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.materialBuffer else null;
    const lighting_buffer = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.lightingBuffer else null;

    var texture_views: ?[*]c.VkImageView = null;
    var samplers: ?[*]c.VkSampler = null;
    var texture_count: u32 = 0;

    if (vs.pipelines.use_pbr_pipeline and vs.pipelines.pbr_pipeline.textureManager != null and
        vs.pipelines.pbr_pipeline.textureManager.*.textureCount > 0) {
        
        texture_count = vs.pipelines.pbr_pipeline.textureManager.*.textureCount;
        
        const views_ptr = c.malloc(@sizeOf(c.VkImageView) * texture_count);
        const samplers_ptr = c.malloc(@sizeOf(c.VkSampler) * texture_count);
        
        texture_views = if (views_ptr) |p| @as([*]c.VkImageView, @ptrCast(@alignCast(p))) else null;
        samplers = if (samplers_ptr) |p| @as([*]c.VkSampler, @ptrCast(@alignCast(p))) else null;

        if (texture_views != null and samplers != null) {
            var i: u32 = 0;
            while (i < texture_count) : (i += 1) {
                texture_views.?[i] = vs.pipelines.pbr_pipeline.textureManager.*.textures[i].view;
                const texSampler = vs.pipelines.pbr_pipeline.textureManager.*.textures[i].sampler;
                samplers.?[i] = if (texSampler != null) texSampler else vs.pipelines.pbr_pipeline.textureManager.*.defaultSampler;
            }
        } else {
            if (texture_views) |p| c.free(@as(?*anyopaque, @ptrCast(p)));
            if (samplers) |p| c.free(@as(?*anyopaque, @ptrCast(p)));
            texture_views = null;
            samplers = null;
            texture_count = 0;
        }
    }

    if (!c.vk_mesh_shader_update_descriptor_buffers(vs, &vs.pipelines.mesh_shader_pipeline, null,
                                                  material_buffer, lighting_buffer, texture_views,
                                                  samplers, texture_count)) {
        log.cardinal_log_error("[MESH_SHADER] Failed to update descriptor buffers during preparation", .{});
    } else {
        log.cardinal_log_debug("[MESH_SHADER] Updated descriptor buffers during preparation (bindless textures: {d})", .{texture_count});
    }

    if (texture_views) |p| c.free(@as(?*anyopaque, @ptrCast(p)));
    if (samplers) |p| c.free(@as(?*anyopaque, @ptrCast(p)));
}

pub export fn vk_get_mt_command_manager() callconv(.c) ?*c.CardinalMTCommandManager {
    // Note: accessing global g_cardinal_mt_subsystem from C. 
    // We should probably check if we can access it directly or if we need to export a getter from C side 
    // or if we should define it here.
    // The C code accesses g_cardinal_mt_subsystem which is defined in vulkan_mt.c (or .zig now).
    // vulkan_mt.zig defines `g_cardinal_mt_subsystem`.
    // Since we are in Zig, we can try to access it if it's public, or use the C import if it exposes it.
    // vulkan_mt.h declares `extern CardinalMTSubsystem g_cardinal_mt_subsystem;`.
    
    if (!c.g_cardinal_mt_subsystem.is_running) {
        log.cardinal_log_warn("[MT] Multi-threading subsystem not initialized", .{});
        return null;
    }
    return &c.g_cardinal_mt_subsystem.command_manager;
}

pub export fn vk_submit_mt_command_task(record_func: ?*const fn(?*anyopaque) callconv(.c) void, user_data: ?*anyopaque, callback: ?*const fn(?*anyopaque, bool) callconv(.c) void) callconv(.c) bool {
    if (record_func == null) {
        log.cardinal_log_error("[MT] Invalid record function for command task", .{});
        return false;
    }

    if (!c.g_cardinal_mt_subsystem.is_running) {
        log.cardinal_log_warn("[MT] Multi-threading subsystem not running, executing task synchronously", .{});
        record_func.?(user_data);
        if (callback) |cb| {
            cb(user_data, true);
        }
        return true;
    }

    const task = c.cardinal_mt_create_command_record_task(record_func, user_data, callback);
    if (task == null) {
        log.cardinal_log_error("[MT] Failed to create command record task", .{});
        return false;
    }

    return c.cardinal_mt_submit_task(task);
}
