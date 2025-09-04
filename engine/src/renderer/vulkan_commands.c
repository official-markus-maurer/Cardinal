#include "cardinal/core/log.h"
#include "cardinal/renderer/vulkan_pbr.h"
#include "cardinal/renderer/vulkan_barrier_validation.h"
#include "vulkan_simple_pipelines.h"
#include "vulkan_state.h"
#include "cardinal/renderer/vulkan_mt.h"
#include <cardinal/renderer/vulkan_commands.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <sys/syscall.h>
#endif

// Forward declarations for internal functions
static void vk_record_scene_with_secondary_buffers(VulkanState* s, VkCommandBuffer primary_cmd, uint32_t image_index);
static void vk_record_scene_direct(VulkanState* s, VkCommandBuffer cmd);
static void vk_record_scene_commands(VulkanState* s, VkCommandBuffer cmd);

// Helper function to get current thread ID
static uint32_t get_current_thread_id(void) {
#ifdef _WIN32
    return GetCurrentThreadId();
#else
    return (uint32_t)syscall(SYS_gettid);
#endif
}

/**
 * @brief Creates command pools, buffers, and synchronization objects.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 *
 * Now includes multi-threaded command buffer allocation support.
 */
bool vk_create_commands_sync(VulkanState* s) {
    // Use 3 frames in flight for better buffering
    s->max_frames_in_flight = 3;
    s->current_frame = 0;

    // Create per-frame command pools
    s->command_pools = (VkCommandPool*)malloc(sizeof(VkCommandPool) * s->max_frames_in_flight);
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
        VkCommandPoolCreateInfo cp = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT};
        cp.queueFamilyIndex = s->graphics_queue_family;
        if (vkCreateCommandPool(s->device, &cp, NULL, &s->command_pools[i]) != VK_SUCCESS)
            return false;
    }

    // Allocate primary command buffers per frame in flight
    s->command_buffers =
        (VkCommandBuffer*)malloc(sizeof(VkCommandBuffer) * s->max_frames_in_flight);
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
        VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        ai.commandPool = s->command_pools[i];
        ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(s->device, &ai, &s->command_buffers[i]) != VK_SUCCESS)
            return false;
    }

    // Allocate secondary command buffers for double buffering
    s->secondary_command_buffers =
        (VkCommandBuffer*)malloc(sizeof(VkCommandBuffer) * s->max_frames_in_flight);
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
        VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        ai.commandPool = s->command_pools[i];
        ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(s->device, &ai, &s->secondary_command_buffers[i]) != VK_SUCCESS)
            return false;
    }

    // Initialize double buffering index
    s->current_command_buffer_index = 0;

    // Allocate swapchain image layout initialization tracking array
    CARDINAL_LOG_INFO(
        "[INIT] Allocating swapchain_image_layout_initialized for %u swapchain images",
        s->swapchain_image_count);
    if (s->swapchain_image_layout_initialized) {
        free(s->swapchain_image_layout_initialized);
        s->swapchain_image_layout_initialized = NULL;
    }
    s->swapchain_image_layout_initialized = (bool*)calloc(s->swapchain_image_count, sizeof(bool));
    if (!s->swapchain_image_layout_initialized)
        return false;

    // Create per-frame binary semaphores for image acquisition
    if (s->image_acquired_semaphores) {
        free(s->image_acquired_semaphores);
        s->image_acquired_semaphores = NULL;
    }
    s->image_acquired_semaphores =
        (VkSemaphore*)calloc(s->max_frames_in_flight, sizeof(VkSemaphore));
    if (!s->image_acquired_semaphores)
        return false;
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
        VkSemaphoreCreateInfo sci = {0};
        sci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if (vkCreateSemaphore(s->device, &sci, NULL, &s->image_acquired_semaphores[i]) !=
            VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[INIT] Failed to create image acquired semaphore for frame %u", i);
            return false;
        }
    }

    // Create per-frame binary semaphores for render completion (GPU-side sync)
    if (s->render_finished_semaphores) {
        free(s->render_finished_semaphores);
        s->render_finished_semaphores = NULL;
    }
    s->render_finished_semaphores =
        (VkSemaphore*)calloc(s->max_frames_in_flight, sizeof(VkSemaphore));
    if (!s->render_finished_semaphores)
        return false;
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
        VkSemaphoreCreateInfo sci = {0};
        sci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if (vkCreateSemaphore(s->device, &sci, NULL, &s->render_finished_semaphores[i]) !=
            VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[INIT] Failed to create render finished semaphore for frame %u", i);
            return false;
        }
    }

    // Create per-frame fences for CPU-GPU synchronization
    if (s->in_flight_fences) {
        free(s->in_flight_fences);
        s->in_flight_fences = NULL;
    }
    s->in_flight_fences = (VkFence*)calloc(s->max_frames_in_flight, sizeof(VkFence));
    if (!s->in_flight_fences)
        return false;
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
        VkFenceCreateInfo fci = {0};
        fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fci.flags = VK_FENCE_CREATE_SIGNALED_BIT; // Start signaled for first frame
        if (vkCreateFence(s->device, &fci, NULL, &s->in_flight_fences[i]) != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[INIT] Failed to create in-flight fence for frame %u", i);
            return false;
        }
    }

    // Create a single timeline semaphore for synchronization
    VkSemaphoreTypeCreateInfo timelineTypeInfo = {0};
    timelineTypeInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
    timelineTypeInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
    timelineTypeInfo.initialValue = 0;

    VkSemaphoreCreateInfo semCI = {0};
    semCI.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    semCI.pNext = &timelineTypeInfo;

    if (vkCreateSemaphore(s->device, &semCI, NULL, &s->timeline_semaphore) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[INIT] Failed to create timeline semaphore");
        return false;
    }
    CARDINAL_LOG_INFO("[INIT] Timeline semaphore created: %p", (void*)s->timeline_semaphore);

    // Initialize timeline values for first frame
    s->current_frame_value = 0;
    s->image_available_value = 1; // after acquire
    s->render_complete_value = 2; // after submit

    // Initialize multi-threading subsystem for command buffer allocation
    uint32_t optimal_thread_count = cardinal_mt_get_optimal_thread_count();
    if (optimal_thread_count > 4) {
        optimal_thread_count = 4; // Limit to 4 threads for command buffer allocation
    }
    
    if (!cardinal_mt_subsystem_init(s, optimal_thread_count)) {
        CARDINAL_LOG_WARN("[INIT] Failed to initialize multi-threading subsystem, continuing without MT support");
    } else {
        CARDINAL_LOG_INFO("[INIT] Multi-threading subsystem initialized with %u threads", optimal_thread_count);
    }

    return true;
}

/**
 * @brief Recreates per-image initialization tracking after swapchain changes.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 *
 * @todo Optimize memory management for frequent recreations.
 */
bool vk_recreate_images_in_flight(VulkanState* s) {
    // Repurposed: recreate swapchain_image_layout_initialized to match new swapchain image count
    if (s->swapchain_image_layout_initialized) {
        free(s->swapchain_image_layout_initialized);
        s->swapchain_image_layout_initialized = NULL;
    }
    CARDINAL_LOG_INFO(
        "[INIT] Recreating swapchain_image_layout_initialized for %u swapchain images",
        s->swapchain_image_count);
    s->swapchain_image_layout_initialized = (bool*)calloc(s->swapchain_image_count, sizeof(bool));
    if (!s->swapchain_image_layout_initialized) {
        CARDINAL_LOG_ERROR("[INIT] Failed to allocate swapchain_image_layout_initialized array");
        return false;
    }
    return true;
}

/**
 * @brief Destroys command pools, buffers, and sync objects.
 * @param s Vulkan state.
 *
 * Now includes thread-safe destruction with multi-threading support.
 */
void vk_destroy_commands_sync(VulkanState* s) {
    if (!s)
        return;

    // Shutdown multi-threading subsystem first
    cardinal_mt_subsystem_shutdown();
    CARDINAL_LOG_INFO("[CLEANUP] Multi-threading subsystem shutdown completed");

    // Ensure device is idle before destroying resources for thread safety
    if (s->device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(s->device);
    }

    // Destroy timeline semaphore
    if (s->timeline_semaphore) {
        vkDestroySemaphore(s->device, s->timeline_semaphore, NULL);
        s->timeline_semaphore = VK_NULL_HANDLE;
    }

    // Destroy per-frame acquire semaphores
    if (s->image_acquired_semaphores) {
        for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
            if (s->image_acquired_semaphores[i])
                vkDestroySemaphore(s->device, s->image_acquired_semaphores[i], NULL);
        }
        free(s->image_acquired_semaphores);
        s->image_acquired_semaphores = NULL;
    }

    // Destroy per-frame render finished semaphores
    if (s->render_finished_semaphores) {
        for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
            if (s->render_finished_semaphores[i])
                vkDestroySemaphore(s->device, s->render_finished_semaphores[i], NULL);
        }
        free(s->render_finished_semaphores);
        s->render_finished_semaphores = NULL;
    }

    // Destroy per-frame in-flight fences
    if (s->in_flight_fences) {
        for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
            if (s->in_flight_fences[i])
                vkDestroyFence(s->device, s->in_flight_fences[i], NULL);
        }
        free(s->in_flight_fences);
        s->in_flight_fences = NULL;
    }

    free(s->swapchain_image_layout_initialized);
    s->swapchain_image_layout_initialized = NULL;
    if (s->command_buffers) {
        free(s->command_buffers);
        s->command_buffers = NULL;
    }
    
    if (s->secondary_command_buffers) {
        free(s->secondary_command_buffers);
        s->secondary_command_buffers = NULL;
    }
    if (s->command_pools) {
        for (uint32_t i = 0; i < s->max_frames_in_flight; ++i)
            if (s->command_pools[i])
                vkDestroyCommandPool(s->device, s->command_pools[i], NULL);
        free(s->command_pools);
        s->command_pools = NULL;
    }
}

/**
 * @brief Records drawing commands into a command buffer.
 * @param s Vulkan state.
 * @param image_index Swapchain image index.
 *
 * Now supports secondary command buffers for better parallelism.
 * Enhanced error handling for recording failures.
 */
void vk_record_cmd(VulkanState* s, uint32_t image_index) {
    // Double buffering: alternate between primary and secondary command buffers
    // This allows CPU recording to overlap with GPU execution
    VkCommandBuffer cmd;
    if (s->current_command_buffer_index == 0) {
        cmd = s->command_buffers[s->current_frame];
    } else {
        cmd = s->secondary_command_buffers[s->current_frame];
    }

    CARDINAL_LOG_INFO("[CMD] Frame %u: Recording command buffer %p (buffer %u) for image %u", 
                      s->current_frame, (void*)cmd, s->current_command_buffer_index, image_index);

    // Reset the command buffer - safe because we waited for fence synchronization
    CARDINAL_LOG_INFO("[CMD] Frame %u: Resetting command buffer %p", s->current_frame, (void*)cmd);
    VkResult reset_result = vkResetCommandBuffer(cmd, 0);
    CARDINAL_LOG_INFO("[CMD] Frame %u: Reset result: %d", s->current_frame, reset_result);

    if (reset_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to reset command buffer: %d", s->current_frame,
                           reset_result);
        return;
    }

    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    CARDINAL_LOG_INFO("[CMD] Frame %u: Beginning command buffer %p with flags %u", s->current_frame,
                      (void*)cmd, bi.flags);
    VkResult begin_result = vkBeginCommandBuffer(cmd, &bi);
    CARDINAL_LOG_INFO("[CMD] Frame %u: Begin result: %d", s->current_frame, begin_result);

    if (begin_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to begin command buffer: %d", s->current_frame,
                           begin_result);
        return;
    }

    VkClearValue clears[2];
    clears[0].color.float32[0] = 0.05f;
    clears[0].color.float32[1] = 0.05f;
    clears[0].color.float32[2] = 0.08f;
    clears[0].color.float32[3] = 1.0f;
    clears[1].depthStencil.depth = 1.0f;
    clears[1].depthStencil.stencil = 0;

    // Ensure depth image layout is transitioned once
    if (!s->depth_layout_initialized) {
        VkImageMemoryBarrier2 barrier = {0};
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
        barrier.srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
        barrier.srcAccessMask = 0;
        barrier.dstStageMask = VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT |
                               VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT;
        barrier.dstAccessMask = VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                                VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = s->depth_image;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;

        VkDependencyInfo dep = {0};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = 1;
        dep.pImageMemoryBarriers = &barrier;
        
        // Validate pipeline barrier before execution
        uint32_t thread_id = get_current_thread_id();
        if (!cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
            CARDINAL_LOG_WARN("[CMD] Pipeline barrier validation failed for depth image transition");
        }
        
        s->vkCmdPipelineBarrier2(cmd, &dep);
        s->depth_layout_initialized = true;
    }

    // Transition swapchain image to COLOR_ATTACHMENT_OPTIMAL each frame
    if (!s->swapchain_image_layout_initialized[image_index]) {
        VkImageMemoryBarrier2 barrier = {0};
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
        barrier.srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
        barrier.srcAccessMask = 0;
        barrier.dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
        barrier.dstAccessMask =
            VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = s->swapchain_images[image_index];
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;

        VkDependencyInfo dep = {0};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = 1;
        dep.pImageMemoryBarriers = &barrier;
        
        // Validate pipeline barrier before execution
        uint32_t thread_id2 = get_current_thread_id();
        if (!cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id2)) {
            CARDINAL_LOG_WARN("[CMD] Pipeline barrier validation failed for swapchain image transition (first time)");
        }
        
        s->vkCmdPipelineBarrier2(cmd, &dep);
        s->swapchain_image_layout_initialized[image_index] = true;
    } else {
        VkImageMemoryBarrier2 barrier = {0};
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
        barrier.srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
        barrier.srcAccessMask = 0;
        barrier.dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
        barrier.dstAccessMask =
            VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = s->swapchain_images[image_index];
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;

        VkDependencyInfo dep = {0};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = 1;
        dep.pImageMemoryBarriers = &barrier;
        
        // Validate pipeline barrier before execution
        uint32_t thread_id3 = get_current_thread_id();
        if (!cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id3)) {
            CARDINAL_LOG_WARN("[CMD] Pipeline barrier validation failed for swapchain image transition (subsequent)");
        }
        
        s->vkCmdPipelineBarrier2(cmd, &dep);
    }

    // Use Vulkan 1.3 dynamic rendering (required)
    CARDINAL_LOG_DEBUG("[CMD] Frame %u: Using dynamic rendering", s->current_frame);

    // Color attachment for dynamic rendering
    VkRenderingAttachmentInfo colorAttachment = {0};
    colorAttachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    colorAttachment.imageView = s->swapchain_image_views[image_index];
    colorAttachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    colorAttachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    colorAttachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    colorAttachment.clearValue = clears[0];

    // Depth attachment for dynamic rendering
    VkRenderingAttachmentInfo depthAttachment = {0};
    depthAttachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    depthAttachment.imageView = s->depth_image_view;
    depthAttachment.imageLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    depthAttachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    depthAttachment.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    depthAttachment.clearValue = clears[1];

    // Rendering info
    VkRenderingInfo renderingInfo = {0};
    renderingInfo.sType = VK_STRUCTURE_TYPE_RENDERING_INFO;
    renderingInfo.renderArea.offset.x = 0;
    renderingInfo.renderArea.offset.y = 0;
    renderingInfo.renderArea.extent = s->swapchain_extent;
    renderingInfo.layerCount = 1;
    renderingInfo.colorAttachmentCount = 1;
    renderingInfo.pColorAttachments = &colorAttachment;
    renderingInfo.pDepthAttachment = &depthAttachment;
    renderingInfo.pStencilAttachment = NULL;

    s->vkCmdBeginRendering(cmd, &renderingInfo);

    // Set dynamic viewport and scissor to match swapchain extent
    VkViewport vp = {0};
    vp.x = 0;
    vp.y = 0;
    vp.width = (float)s->swapchain_extent.width;
    vp.height = (float)s->swapchain_extent.height;
    vp.minDepth = 0.0f;
    vp.maxDepth = 1.0f;
    vkCmdSetViewport(cmd, 0, 1, &vp);

    VkRect2D sc = {0};
    sc.offset.x = 0;
    sc.offset.y = 0;
    sc.extent = s->swapchain_extent;
    vkCmdSetScissor(cmd, 0, 1, &sc);

    // Render scene if we have one
    if (s->current_scene) {
        // Try to use secondary command buffers for parallel rendering if MT subsystem is available
        CardinalMTCommandManager* mt_manager = vk_get_mt_command_manager();
        if (mt_manager && mt_manager->thread_pools[0].is_active) {
            vk_record_scene_with_secondary_buffers(s, cmd, image_index);
        } else {
            // Fallback to direct rendering in primary command buffer
            vk_record_scene_direct(s, cmd);
        }
    }

    // Allow optional UI callback to record draw calls (e.g., ImGui)
    if (s->ui_record_callback) {
        s->ui_record_callback(cmd);
    }

    // End dynamic rendering
    s->vkCmdEndRendering(cmd);

    // Transition swapchain image to PRESENT for presentation using sync2
    VkImageMemoryBarrier2 barrier = {0};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    barrier.srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.dstStageMask = VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT;
    barrier.dstAccessMask = 0;
    barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = s->swapchain_images[image_index];
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;

    VkDependencyInfo dep = {0};
    dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &barrier;
    
    // Validate pipeline barrier before execution
    uint32_t thread_id4 = get_current_thread_id();
    if (!cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id4)) {
        CARDINAL_LOG_WARN("[CMD] Pipeline barrier validation failed for swapchain present transition");
    }
    
    s->vkCmdPipelineBarrier2(cmd, &dep);

    CARDINAL_LOG_INFO("[CMD] Frame %u: Ending command buffer %p", s->current_frame, (void*)cmd);
    VkResult end_result = vkEndCommandBuffer(cmd);
    CARDINAL_LOG_INFO("[CMD] Frame %u: End result: %d", s->current_frame, end_result);

    if (end_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to end command buffer: %d", s->current_frame,
                           end_result);
        return;
    }
}

// === Secondary Command Buffer Implementation ===

/**
 * @brief Record scene rendering using secondary command buffers for parallelism
 * @param s Vulkan state
 * @param primary_cmd Primary command buffer
 * @param image_index Swapchain image index
 */
static void vk_record_scene_with_secondary_buffers(VulkanState* s, VkCommandBuffer primary_cmd, uint32_t image_index) {
    (void)image_index; // Suppress unreferenced parameter warning
    CardinalMTCommandManager* mt_manager = vk_get_mt_command_manager();
    if (!mt_manager || !mt_manager->thread_pools[0].is_active) {
        CARDINAL_LOG_WARN("[MT] Secondary command buffers requested but MT subsystem not available");
        vk_record_scene_direct(s, primary_cmd);
        return;
    }
    
    // Allocate secondary command buffer for scene rendering
    CardinalSecondaryCommandContext secondary_context;
    if (!cardinal_mt_allocate_secondary_command_buffer(&mt_manager->thread_pools[0], &secondary_context)) {
        CARDINAL_LOG_WARN("[MT] Failed to allocate secondary command buffer, falling back to direct rendering");
        vk_record_scene_direct(s, primary_cmd);
        return;
    }
    
    // Set up inheritance info for secondary command buffer
    VkCommandBufferInheritanceRenderingInfo inheritance_rendering = {0};
    inheritance_rendering.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_RENDERING_INFO;
    inheritance_rendering.colorAttachmentCount = 1;
    VkFormat color_format = s->swapchain_format;
    inheritance_rendering.pColorAttachmentFormats = &color_format;
    inheritance_rendering.depthAttachmentFormat = s->depth_format;
    inheritance_rendering.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    
    VkCommandBufferInheritanceInfo inheritance_info = {0};
    inheritance_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO;
    inheritance_info.pNext = &inheritance_rendering;
    inheritance_info.renderPass = VK_NULL_HANDLE; // Using dynamic rendering
    inheritance_info.subpass = 0;
    inheritance_info.framebuffer = VK_NULL_HANDLE; // Using dynamic rendering
    inheritance_info.occlusionQueryEnable = VK_FALSE;
    inheritance_info.queryFlags = 0;
    inheritance_info.pipelineStatistics = 0;
    
    // Begin secondary command buffer
    if (!cardinal_mt_begin_secondary_command_buffer(&secondary_context, &inheritance_info)) {
        CARDINAL_LOG_ERROR("[MT] Failed to begin secondary command buffer");
        vk_record_scene_direct(s, primary_cmd);
        return;
    }
    
    // Record scene rendering commands into secondary buffer
    VkCommandBuffer secondary_cmd = secondary_context.command_buffer;
    
    // Set dynamic viewport and scissor for secondary buffer
    VkViewport vp = {0};
    vp.x = 0;
    vp.y = 0;
    vp.width = (float)s->swapchain_extent.width;
    vp.height = (float)s->swapchain_extent.height;
    vp.minDepth = 0.0f;
    vp.maxDepth = 1.0f;
    vkCmdSetViewport(secondary_cmd, 0, 1, &vp);
    
    VkRect2D sc = {0};
    sc.offset.x = 0;
    sc.offset.y = 0;
    sc.extent = s->swapchain_extent;
    vkCmdSetScissor(secondary_cmd, 0, 1, &sc);
    
    // Record scene rendering based on current mode
    vk_record_scene_commands(s, secondary_cmd);
    
    // End secondary command buffer
    if (!cardinal_mt_end_secondary_command_buffer(&secondary_context)) {
        CARDINAL_LOG_ERROR("[MT] Failed to end secondary command buffer");
        vk_record_scene_direct(s, primary_cmd);
        return;
    }
    
    // Execute secondary command buffer in primary
    cardinal_mt_execute_secondary_command_buffers(primary_cmd, &secondary_context, 1);
    
    CARDINAL_LOG_DEBUG("[MT] Scene rendered using secondary command buffer");
}

/**
 * @brief Record scene rendering directly in primary command buffer (fallback)
 * @param s Vulkan state
 * @param cmd Primary command buffer
 */
static void vk_record_scene_direct(VulkanState* s, VkCommandBuffer cmd) {
    vk_record_scene_commands(s, cmd);
}

/**
 * @brief Record scene rendering commands (shared between primary and secondary)
 * @param s Vulkan state
 * @param cmd Command buffer to record into
 */
static void vk_record_scene_commands(VulkanState* s, VkCommandBuffer cmd) {
    switch (s->current_rendering_mode) {
        case CARDINAL_RENDERING_MODE_NORMAL:
            // Use PBR pipeline for normal rendering
            if (s->use_pbr_pipeline && s->pbr_pipeline.initialized) {
                // Ensure PBR uniforms are updated before rendering
                PBRUniformBufferObject ubo;
                memcpy(&ubo, s->pbr_pipeline.uniformBufferMapped,
                       sizeof(PBRUniformBufferObject));
                PBRLightingData lighting;
                memcpy(&lighting, s->pbr_pipeline.lightingBufferMapped,
                       sizeof(PBRLightingData));
                vk_pbr_update_uniforms(&s->pbr_pipeline, &ubo, &lighting);
                vk_pbr_render(&s->pbr_pipeline, cmd, s->current_scene);
            }
            break;

        case CARDINAL_RENDERING_MODE_UV:
            // Use UV visualization pipeline
            if (s->uv_pipeline != VK_NULL_HANDLE && s->use_pbr_pipeline &&
                s->pbr_pipeline.initialized) {
                // Copy matrices from PBR uniform buffer
                PBRUniformBufferObject* pbr_ubo =
                    (PBRUniformBufferObject*)s->pbr_pipeline.uniformBufferMapped;
                vk_update_simple_uniforms(s, pbr_ubo->model, pbr_ubo->view, pbr_ubo->proj);
                vk_render_simple(s, cmd, s->uv_pipeline, s->uv_pipeline_layout);
            }
            break;

        case CARDINAL_RENDERING_MODE_WIREFRAME:
            // Use wireframe pipeline
            if (s->wireframe_pipeline != VK_NULL_HANDLE && s->use_pbr_pipeline &&
                s->pbr_pipeline.initialized) {
                // Copy matrices from PBR uniform buffer
                PBRUniformBufferObject* pbr_ubo =
                    (PBRUniformBufferObject*)s->pbr_pipeline.uniformBufferMapped;
                vk_update_simple_uniforms(s, pbr_ubo->model, pbr_ubo->view, pbr_ubo->proj);
                vk_render_simple(s, cmd, s->wireframe_pipeline, s->wireframe_pipeline_layout);
            }
            break;

        default:
            CARDINAL_LOG_WARN("Unknown rendering mode: %d, falling back to PBR",
                              s->current_rendering_mode);
            if (s->use_pbr_pipeline && s->pbr_pipeline.initialized) {
                PBRUniformBufferObject ubo;
                memcpy(&ubo, s->pbr_pipeline.uniformBufferMapped,
                       sizeof(PBRUniformBufferObject));
                PBRLightingData lighting;
                memcpy(&lighting, s->pbr_pipeline.lightingBufferMapped,
                       sizeof(PBRLightingData));
                vk_pbr_update_uniforms(&s->pbr_pipeline, &ubo, &lighting);
                vk_pbr_render(&s->pbr_pipeline, cmd, s->current_scene);
            }
            break;
    }
}

// === Multi-Threading Support Functions ===

CardinalMTCommandManager* vk_get_mt_command_manager(void) {
    if (!g_cardinal_mt_subsystem.is_running) {
        CARDINAL_LOG_WARN("[MT] Multi-threading subsystem not initialized");
        return NULL;
    }
    return &g_cardinal_mt_subsystem.command_manager;
}

bool vk_submit_mt_command_task(void (*record_func)(void* data),
                               void* user_data,
                               void (*callback)(void* data, bool success)) {
    if (!record_func) {
        CARDINAL_LOG_ERROR("[MT] Invalid record function for command task");
        return false;
    }
    
    if (!g_cardinal_mt_subsystem.is_running) {
        CARDINAL_LOG_WARN("[MT] Multi-threading subsystem not running, executing task synchronously");
        record_func(user_data);
        if (callback) {
            callback(user_data, true);
        }
        return true;
    }
    
    CardinalMTTask* task = cardinal_mt_create_command_record_task(record_func, user_data, callback);
    if (!task) {
        CARDINAL_LOG_ERROR("[MT] Failed to create command record task");
        return false;
    }
    
    return cardinal_mt_submit_task(task);
}
