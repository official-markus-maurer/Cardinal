#include "cardinal/core/log.h"
#include "cardinal/core/transform.h"
#include "cardinal/renderer/util/vulkan_descriptor_buffer_utils_minimal.h"
#include "cardinal/renderer/vulkan_barrier_validation.h"
#include "cardinal/renderer/vulkan_mesh_shader.h"
#include "cardinal/renderer/vulkan_mt.h"
#include "cardinal/renderer/vulkan_pbr.h"
#include "cardinal/renderer/vulkan_texture_manager.h"
#include "vulkan_simple_pipelines.h"
#include "vulkan_state.h"
#include <cardinal/renderer/vulkan_commands.h>
#include <cardinal/renderer/vulkan_utils.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#ifdef _WIN32
    #include <windows.h>
#else
    #include <sys/syscall.h>
    #include <unistd.h>
#endif

// Forward declarations for internal functions
static void vk_record_scene_with_secondary_buffers(VulkanState* s, VkCommandBuffer primary_cmd,
                                                   uint32_t image_index);
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
 * @brief Creates per-frame command pools.
 */
static bool create_command_pools(VulkanState* s) {
    s->commands.pools =
        (VkCommandPool*)malloc(sizeof(VkCommandPool) * s->sync.max_frames_in_flight);
    for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i) {
        if (!vk_utils_create_command_pool(s->context.device, s->context.graphics_queue_family,
                                          VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                                          &s->commands.pools[i], "graphics command pool"))
            return false;
    }
    CARDINAL_LOG_WARN("[INIT] Created %u command pools", s->sync.max_frames_in_flight);
    return true;
}

/**
 * @brief Allocates primary and secondary command buffers.
 */
static bool allocate_command_buffers(VulkanState* s) {
    // Allocate primary command buffers
    s->commands.buffers =
        (VkCommandBuffer*)malloc(sizeof(VkCommandBuffer) * s->sync.max_frames_in_flight);
    for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i) {
        VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        ai.commandPool = s->commands.pools[i];
        ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(s->context.device, &ai, &s->commands.buffers[i]) != VK_SUCCESS)
            return false;
    }
    CARDINAL_LOG_WARN("[INIT] Allocated %u primary command buffers", s->sync.max_frames_in_flight);

    // Allocate secondary command buffers
    s->commands.secondary_buffers =
        (VkCommandBuffer*)malloc(sizeof(VkCommandBuffer) * s->sync.max_frames_in_flight);
    for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i) {
        VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        ai.commandPool = s->commands.pools[i];
        ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(s->context.device, &ai, &s->commands.secondary_buffers[i]) !=
            VK_SUCCESS)
            return false;
    }
    CARDINAL_LOG_WARN("[INIT] Allocated %u secondary command buffers",
                      s->sync.max_frames_in_flight);
    return true;
}

/**
 * @brief Creates synchronization objects (semaphores and fences).
 */
static bool create_sync_objects(VulkanState* s) {
    // Image acquisition semaphores
    if (s->sync.image_acquired_semaphores) {
        free(s->sync.image_acquired_semaphores);
        s->sync.image_acquired_semaphores = NULL;
    }
    s->sync.image_acquired_semaphores =
        (VkSemaphore*)calloc(s->sync.max_frames_in_flight, sizeof(VkSemaphore));
    if (!s->sync.image_acquired_semaphores)
        return false;

    for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i) {
        VkSemaphoreCreateInfo sci = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        if (vkCreateSemaphore(s->context.device, &sci, NULL,
                              &s->sync.image_acquired_semaphores[i]) != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[INIT] Failed to create image acquired semaphore for frame %u", i);
            return false;
        }
    }
    CARDINAL_LOG_WARN("[INIT] Created %u acquire semaphores", s->sync.max_frames_in_flight);

    // Render finished semaphores
    if (s->sync.render_finished_semaphores) {
        free(s->sync.render_finished_semaphores);
        s->sync.render_finished_semaphores = NULL;
    }
    s->sync.render_finished_semaphores =
        (VkSemaphore*)calloc(s->sync.max_frames_in_flight, sizeof(VkSemaphore));
    if (!s->sync.render_finished_semaphores)
        return false;

    for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i) {
        VkSemaphoreCreateInfo sci = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        if (vkCreateSemaphore(s->context.device, &sci, NULL,
                              &s->sync.render_finished_semaphores[i]) != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[INIT] Failed to create render finished semaphore for frame %u", i);
            return false;
        }
    }
    CARDINAL_LOG_WARN("[INIT] Created %u render finished semaphores", s->sync.max_frames_in_flight);

    // In-flight fences
    if (s->sync.in_flight_fences) {
        free(s->sync.in_flight_fences);
        s->sync.in_flight_fences = NULL;
    }
    s->sync.in_flight_fences = (VkFence*)calloc(s->sync.max_frames_in_flight, sizeof(VkFence));
    if (!s->sync.in_flight_fences)
        return false;

    for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i) {
        if (!vk_utils_create_fence(s->context.device, &s->sync.in_flight_fences[i], true,
                                   "in-flight fence")) {
            CARDINAL_LOG_ERROR("[INIT] Failed to create in-flight fence for frame %u", i);
            return false;
        }
    }
    CARDINAL_LOG_WARN("[INIT] Created %u in-flight fences", s->sync.max_frames_in_flight);

    // Timeline semaphore
    VkSemaphoreTypeCreateInfo timelineTypeInfo = {.sType =
                                                      VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
                                                  .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
                                                  .initialValue = 0};
    VkSemaphoreCreateInfo semCI = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                                   .pNext = &timelineTypeInfo};

    VkResult result =
        vkCreateSemaphore(s->context.device, &semCI, NULL, &s->sync.timeline_semaphore);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[INIT] Failed to create timeline semaphore: %d", result);
        return false;
    }
    CARDINAL_LOG_WARN("[INIT] Timeline semaphore created: %p", (void*)s->sync.timeline_semaphore);

    return true;
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
    s->sync.max_frames_in_flight = 3;
    s->sync.current_frame = 0;

    if (!create_command_pools(s))
        return false;
    if (!allocate_command_buffers(s))
        return false;

    // Initialize double buffering index
    s->commands.current_buffer_index = 0;

    // Allocate swapchain image layout initialization tracking array
    CARDINAL_LOG_WARN(
        "[INIT] Allocating swapchain_image_layout_initialized for %u swapchain images",
        s->swapchain.image_count);
    if (s->swapchain.image_layout_initialized) {
        free(s->swapchain.image_layout_initialized);
        s->swapchain.image_layout_initialized = NULL;
    }
    s->swapchain.image_layout_initialized = (bool*)calloc(s->swapchain.image_count, sizeof(bool));
    if (!s->swapchain.image_layout_initialized)
        return false;

    if (!create_sync_objects(s))
        return false;

    // Initialize timeline values for first frame
    s->sync.current_frame_value = 0;
    s->sync.image_available_value = 1; // after acquire
    s->sync.render_complete_value = 2; // after submit

    // Initialize multi-threading subsystem for command buffer allocation
    uint32_t optimal_thread_count = cardinal_mt_get_optimal_thread_count();
    if (optimal_thread_count > 4) {
        optimal_thread_count = 4; // Limit to 4 threads for command buffer allocation
    }

    if (!cardinal_mt_subsystem_init(s, optimal_thread_count)) {
        CARDINAL_LOG_WARN(
            "[INIT] Failed to initialize multi-threading subsystem, continuing without MT support");
    } else {
        CARDINAL_LOG_INFO("[INIT] Multi-threading subsystem initialized with %u threads",
                          optimal_thread_count);
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
    if (s->swapchain.image_layout_initialized) {
        free(s->swapchain.image_layout_initialized);
        s->swapchain.image_layout_initialized = NULL;
    }
    CARDINAL_LOG_INFO(
        "[INIT] Recreating swapchain_image_layout_initialized for %u swapchain images",
        s->swapchain.image_count);
    s->swapchain.image_layout_initialized = (bool*)calloc(s->swapchain.image_count, sizeof(bool));
    if (!s->swapchain.image_layout_initialized) {
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
    if (s->context.device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(s->context.device);
    }

    // Destroy timeline semaphore
    if (s->sync.timeline_semaphore) {
        vkDestroySemaphore(s->context.device, s->sync.timeline_semaphore, NULL);
        s->sync.timeline_semaphore = VK_NULL_HANDLE;
    }

    // Destroy per-frame acquire semaphores
    if (s->sync.image_acquired_semaphores) {
        for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i) {
            if (s->sync.image_acquired_semaphores[i])
                vkDestroySemaphore(s->context.device, s->sync.image_acquired_semaphores[i], NULL);
        }
        free(s->sync.image_acquired_semaphores);
        s->sync.image_acquired_semaphores = NULL;
    }

    // Destroy per-frame render finished semaphores
    if (s->sync.render_finished_semaphores) {
        for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i) {
            if (s->sync.render_finished_semaphores[i])
                vkDestroySemaphore(s->context.device, s->sync.render_finished_semaphores[i], NULL);
        }
        free(s->sync.render_finished_semaphores);
        s->sync.render_finished_semaphores = NULL;
    }

    // Destroy per-frame in-flight fences
    if (s->sync.in_flight_fences) {
        for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i) {
            if (s->sync.in_flight_fences[i])
                vkDestroyFence(s->context.device, s->sync.in_flight_fences[i], NULL);
        }
        free(s->sync.in_flight_fences);
        s->sync.in_flight_fences = NULL;
    }

    free(s->swapchain.image_layout_initialized);
    s->swapchain.image_layout_initialized = NULL;
    if (s->commands.buffers) {
        free(s->commands.buffers);
        s->commands.buffers = NULL;
    }

    if (s->commands.secondary_buffers) {
        free(s->commands.secondary_buffers);
        s->commands.secondary_buffers = NULL;
    }
    if (s->commands.pools) {
        for (uint32_t i = 0; i < s->sync.max_frames_in_flight; ++i)
            if (s->commands.pools[i])
                vkDestroyCommandPool(s->context.device, s->commands.pools[i], NULL);
        free(s->commands.pools);
        s->commands.pools = NULL;
    }
}

/**
 * @brief Selects the command buffer for the current frame (primary or secondary).
 */
static VkCommandBuffer select_command_buffer(VulkanState* s) {
    if (s->commands.current_buffer_index == 0) {
        if (!s->commands.buffers) {
            CARDINAL_LOG_ERROR("[CMD] Frame %u: command_buffers array is null",
                               s->sync.current_frame);
            return VK_NULL_HANDLE;
        }
        return s->commands.buffers[s->sync.current_frame];
    } else {
        if (!s->commands.secondary_buffers) {
            CARDINAL_LOG_ERROR("[CMD] Frame %u: secondary_command_buffers array is null",
                               s->sync.current_frame);
            return VK_NULL_HANDLE;
        }
        return s->commands.secondary_buffers[s->sync.current_frame];
    }
}

/**
 * @brief Validates the swapchain image index and state.
 */
static bool validate_swapchain_image(VulkanState* s, uint32_t image_index) {
    if (s->swapchain.image_count == 0 || image_index >= s->swapchain.image_count) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Invalid image index %u (count %u)",
                           s->sync.current_frame, image_index, s->swapchain.image_count);
        return false;
    }
    if (!s->swapchain.images || !s->swapchain.image_views) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Swapchain image arrays are null",
                           s->sync.current_frame);
        return false;
    }
    if (!s->swapchain.image_layout_initialized) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Image layout initialization array is null",
                           s->sync.current_frame);
        return false;
    }
    if (s->swapchain.extent.width == 0 || s->swapchain.extent.height == 0) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Invalid swapchain extent %ux%u", s->sync.current_frame,
                           s->swapchain.extent.width, s->swapchain.extent.height);
        return false;
    }
    return true;
}

/**
 * @brief Resets and begins the command buffer.
 */
static bool begin_command_buffer(VulkanState* s, VkCommandBuffer cmd) {
    CARDINAL_LOG_INFO("[CMD] Frame %u: Resetting command buffer %p", s->sync.current_frame,
                      (void*)cmd);
    VkResult reset_result = vkResetCommandBuffer(cmd, 0);
    if (reset_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to reset command buffer: %d",
                           s->sync.current_frame, reset_result);
        return false;
    }

    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    CARDINAL_LOG_INFO("[CMD] Frame %u: Beginning command buffer %p with flags %u",
                      s->sync.current_frame, (void*)cmd, bi.flags);
    VkResult begin_result = vkBeginCommandBuffer(cmd, &bi);
    if (begin_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to begin command buffer: %d",
                           s->sync.current_frame, begin_result);
        return false;
    }
    return true;
}

/**
 * @brief Transitions image layouts for rendering.
 */
static void transition_images(VulkanState* s, VkCommandBuffer cmd, uint32_t image_index,
                              bool use_depth) {
    uint32_t thread_id = get_current_thread_id();

    // Depth transition
    if (use_depth && !s->swapchain.depth_layout_initialized) {
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
        barrier.image = s->swapchain.depth_image;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;

        VkDependencyInfo dep = {0};
        dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = 1;
        dep.pImageMemoryBarriers = &barrier;

        if (!cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
            CARDINAL_LOG_WARN(
                "[CMD] Pipeline barrier validation failed for depth image transition");
        }

        if (s->context.vkCmdPipelineBarrier2) {
            s->context.vkCmdPipelineBarrier2(cmd, &dep);
            s->swapchain.depth_layout_initialized = true;
        }
    }

    // Color attachment transition
    VkImageMemoryBarrier2 barrier = {0};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.image = s->swapchain.images[image_index];
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;

    if (!s->swapchain.image_layout_initialized[image_index]) {
        barrier.srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
        barrier.srcAccessMask = 0;
        barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        s->swapchain.image_layout_initialized[image_index] = true;
    } else {
        barrier.srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
        barrier.srcAccessMask = 0;
        barrier.oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    }

    barrier.dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    barrier.dstAccessMask =
        VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkDependencyInfo dep = {0};
    dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &barrier;

    if (!cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
        CARDINAL_LOG_WARN(
            "[CMD] Pipeline barrier validation failed for swapchain image transition");
    }

    s->context.vkCmdPipelineBarrier2(cmd, &dep);
}

/**
 * @brief Begins dynamic rendering.
 */
static bool begin_dynamic_rendering(VulkanState* s, VkCommandBuffer cmd, uint32_t image_index,
                                    bool use_depth, VkClearValue* clears) {
    if (!s->context.vkCmdBeginRendering || !s->context.vkCmdEndRendering ||
        !s->context.vkCmdPipelineBarrier2) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Dynamic rendering functions not loaded",
                           s->sync.current_frame);
        return false;
    }

    VkRenderingAttachmentInfo colorAttachment = {0};
    colorAttachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    colorAttachment.imageView = s->swapchain.image_views[image_index];
    colorAttachment.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    colorAttachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    colorAttachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    colorAttachment.clearValue = clears[0];

    VkRenderingAttachmentInfo depthAttachment = {0};
    if (use_depth) {
        depthAttachment.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        depthAttachment.imageView = s->swapchain.depth_image_view;
        depthAttachment.imageLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        depthAttachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        depthAttachment.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depthAttachment.clearValue = clears[1];
    }

    VkRenderingInfo renderingInfo = {0};
    renderingInfo.sType = VK_STRUCTURE_TYPE_RENDERING_INFO;
    // We are using PRIMARY command buffers for rendering (even the ones named 'secondary_buffers'
    // are allocated as PRIMARY). Therefore, we are recording inline commands directly into the
    // command buffer passed to vkCmdBeginRendering. We should NOT set
    // VK_RENDERING_CONTENTS_SECONDARY_COMMAND_BUFFERS_BIT unless we actually use
    // vkCmdExecuteCommands with true secondary buffers.
    renderingInfo.flags = 0;
    renderingInfo.renderArea.offset.x = 0;
    renderingInfo.renderArea.offset.y = 0;
    renderingInfo.renderArea.extent = s->swapchain.extent;
    renderingInfo.layerCount = 1;
    renderingInfo.colorAttachmentCount = 1;
    renderingInfo.pColorAttachments = &colorAttachment;
    renderingInfo.pDepthAttachment = use_depth ? &depthAttachment : NULL;

    s->context.vkCmdBeginRendering(cmd, &renderingInfo);

    // Set dynamic viewport and scissor
    VkViewport vp = {0};
    vp.x = 0;
    vp.y = 0;
    vp.width = (float)s->swapchain.extent.width;
    vp.height = (float)s->swapchain.extent.height;
    vp.minDepth = 0.0f;
    vp.maxDepth = 1.0f;
    vkCmdSetViewport(cmd, 0, 1, &vp);

    VkRect2D sc = {0};
    sc.offset.x = 0;
    sc.offset.y = 0;
    sc.extent = s->swapchain.extent;
    vkCmdSetScissor(cmd, 0, 1, &sc);

    return true;
}

/**
 * @brief Ends recording and transitions image for presentation.
 */
static void end_recording(VulkanState* s, VkCommandBuffer cmd, uint32_t image_index) {
    s->context.vkCmdEndRendering(cmd);

    // Transition to present
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
    barrier.image = s->swapchain.images[image_index];
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;

    VkDependencyInfo dep = {0};
    dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &barrier;

    uint32_t thread_id = get_current_thread_id();
    if (!cardinal_barrier_validation_validate_pipeline_barrier(&dep, cmd, thread_id)) {
        CARDINAL_LOG_WARN(
            "[CMD] Pipeline barrier validation failed for swapchain present transition");
    }

    s->context.vkCmdPipelineBarrier2(cmd, &dep);

    CARDINAL_LOG_INFO("[CMD] Frame %u: Ending command buffer %p", s->sync.current_frame,
                      (void*)cmd);
    VkResult end_result = vkEndCommandBuffer(cmd);
    CARDINAL_LOG_INFO("[CMD] Frame %u: End result: %d", s->sync.current_frame, end_result);

    if (end_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to end command buffer: %d",
                           s->sync.current_frame, end_result);
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
    // Note: Mesh shader descriptor set preparation is now handled in cardinal_renderer_draw_frame
    // before command buffer recording to prevent race conditions with swapchain recreation

    VkCommandBuffer cmd = select_command_buffer(s);
    if (cmd == VK_NULL_HANDLE)
        return;

    CARDINAL_LOG_INFO("[CMD] Frame %u: Recording command buffer %p (buffer %u) for image %u",
                      s->sync.current_frame, (void*)cmd, s->commands.current_buffer_index,
                      image_index);

    if (!validate_swapchain_image(s, image_index))
        return;
    if (!begin_command_buffer(s, cmd))
        return;

    VkClearValue clears[2];
    clears[0].color.float32[0] = 0.05f;
    clears[0].color.float32[1] = 0.05f;
    clears[0].color.float32[2] = 0.08f;
    clears[0].color.float32[3] = 1.0f;
    clears[1].depthStencil.depth = 1.0f;
    clears[1].depthStencil.stencil = 0;

    bool use_depth = s->swapchain.depth_image_view != VK_NULL_HANDLE &&
                     s->swapchain.depth_image != VK_NULL_HANDLE;

    transition_images(s, cmd, image_index, use_depth);

    if (!begin_dynamic_rendering(s, cmd, image_index, use_depth, clears)) {
        vkEndCommandBuffer(cmd);
        return;
    }

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

    end_recording(s, cmd, image_index);
}

// === Secondary Command Buffer Implementation ===

/**
 * @brief Record scene rendering using secondary command buffers for parallelism
 * @param s Vulkan state
 * @param primary_cmd Primary command buffer
 * @param image_index Swapchain image index
 */
static void vk_record_scene_with_secondary_buffers(VulkanState* s, VkCommandBuffer primary_cmd,
                                                   uint32_t image_index) {
    (void)image_index; // Suppress unreferenced parameter warning
    CardinalMTCommandManager* mt_manager = vk_get_mt_command_manager();
    if (!mt_manager || !mt_manager->thread_pools[0].is_active) {
        CARDINAL_LOG_WARN(
            "[MT] Secondary command buffers requested but MT subsystem not available");
        vk_record_scene_direct(s, primary_cmd);
        return;
    }

    // Allocate secondary command buffer for scene rendering
    CardinalSecondaryCommandContext secondary_context;
    if (!cardinal_mt_allocate_secondary_command_buffer(&mt_manager->thread_pools[0],
                                                       &secondary_context)) {
        CARDINAL_LOG_WARN(
            "[MT] Failed to allocate secondary command buffer, falling back to direct rendering");
        vk_record_scene_direct(s, primary_cmd);
        return;
    }

    // Set up inheritance info for secondary command buffer
    VkCommandBufferInheritanceRenderingInfo inheritance_rendering = {0};
    inheritance_rendering.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_RENDERING_INFO;
    inheritance_rendering.colorAttachmentCount = 1;
    VkFormat color_format = s->swapchain.format;
    inheritance_rendering.pColorAttachmentFormats = &color_format;
    inheritance_rendering.depthAttachmentFormat = s->swapchain.depth_format;
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
    vp.width = (float)s->swapchain.extent.width;
    vp.height = (float)s->swapchain.extent.height;
    vp.minDepth = 0.0f;
    vp.maxDepth = 1.0f;
    vkCmdSetViewport(secondary_cmd, 0, 1, &vp);

    VkRect2D sc = {0};
    sc.offset.x = 0;
    sc.offset.y = 0;
    sc.extent = s->swapchain.extent;
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
            if (s->pipelines.use_pbr_pipeline && s->pipelines.pbr_pipeline.initialized) {
                // Ensure PBR uniforms are updated before rendering
                PBRUniformBufferObject ubo;
                memcpy(&ubo, s->pipelines.pbr_pipeline.uniformBufferMapped,
                       sizeof(PBRUniformBufferObject));
                PBRLightingData lighting;
                memcpy(&lighting, s->pipelines.pbr_pipeline.lightingBufferMapped,
                       sizeof(PBRLightingData));
                vk_pbr_update_uniforms(&s->pipelines.pbr_pipeline, &ubo, &lighting);
                vk_pbr_render(&s->pipelines.pbr_pipeline, cmd, s->current_scene);
            }
            break;

        case CARDINAL_RENDERING_MODE_UV:
            // Use UV visualization pipeline
            if (s->pipelines.uv_pipeline != VK_NULL_HANDLE && s->pipelines.use_pbr_pipeline &&
                s->pipelines.pbr_pipeline.initialized) {
                // Copy matrices from PBR uniform buffer
                PBRUniformBufferObject* pbr_ubo =
                    (PBRUniformBufferObject*)s->pipelines.pbr_pipeline.uniformBufferMapped;
                vk_update_simple_uniforms(s, pbr_ubo->model, pbr_ubo->view, pbr_ubo->proj);
                vk_render_simple(s, cmd, s->pipelines.uv_pipeline, s->pipelines.uv_pipeline_layout);
            }
            break;

        case CARDINAL_RENDERING_MODE_WIREFRAME:
            // Use wireframe pipeline
            if (s->pipelines.wireframe_pipeline != VK_NULL_HANDLE &&
                s->pipelines.use_pbr_pipeline && s->pipelines.pbr_pipeline.initialized) {
                // Copy matrices from PBR uniform buffer
                PBRUniformBufferObject* pbr_ubo =
                    (PBRUniformBufferObject*)s->pipelines.pbr_pipeline.uniformBufferMapped;
                vk_update_simple_uniforms(s, pbr_ubo->model, pbr_ubo->view, pbr_ubo->proj);
                vk_render_simple(s, cmd, s->pipelines.wireframe_pipeline,
                                 s->pipelines.wireframe_pipeline_layout);
            }
            break;

        case CARDINAL_RENDERING_MODE_MESH_SHADER:
            // Use mesh shader pipeline
            vk_mesh_shader_record_frame(s, cmd);
            break;

        default:
            CARDINAL_LOG_WARN("Unknown rendering mode: %d, falling back to PBR",
                              s->current_rendering_mode);
            if (s->pipelines.use_pbr_pipeline && s->pipelines.pbr_pipeline.initialized) {
                PBRUniformBufferObject ubo = {0};
                PBRLightingData lighting = {0};
                if (s->pipelines.pbr_pipeline.uniformBufferMapped) {
                    memcpy(&ubo, s->pipelines.pbr_pipeline.uniformBufferMapped,
                           sizeof(PBRUniformBufferObject));
                }
                if (s->pipelines.pbr_pipeline.lightingBufferMapped) {
                    memcpy(&lighting, s->pipelines.pbr_pipeline.lightingBufferMapped,
                           sizeof(PBRLightingData));
                }
                vk_pbr_update_uniforms(&s->pipelines.pbr_pipeline, &ubo, &lighting);
                vk_pbr_render(&s->pipelines.pbr_pipeline, cmd, s->current_scene);
            }
            break;
    }
}

/**
 * @brief Prepares mesh shader rendering by updating descriptor sets before command buffer recording
 * @param s Vulkan state
 */
void vk_prepare_mesh_shader_rendering(VulkanState* s) {
    if (!s->pipelines.use_mesh_shader_pipeline ||
        s->pipelines.mesh_shader_pipeline.pipeline == VK_NULL_HANDLE || !s->current_scene) {
        return;
    }

    // Update fragment descriptor buffers with PBR data outside of command buffer recording
    // This prevents descriptor buffer updates during command buffer recording which causes
    // validation errors
    VkBuffer material_buffer =
        s->pipelines.use_pbr_pipeline ? s->pipelines.pbr_pipeline.materialBuffer : VK_NULL_HANDLE;
    VkBuffer lighting_buffer =
        s->pipelines.use_pbr_pipeline ? s->pipelines.pbr_pipeline.lightingBuffer : VK_NULL_HANDLE;

    // Allocate temporary array for texture views to extract from managed textures
    VkImageView* texture_views = NULL;
    VkSampler* samplers = NULL;
    uint32_t texture_count = 0;

    if (s->pipelines.use_pbr_pipeline && s->pipelines.pbr_pipeline.textureManager &&
        s->pipelines.pbr_pipeline.textureManager->textureCount > 0) {
        texture_count = s->pipelines.pbr_pipeline.textureManager->textureCount;
        texture_views = (VkImageView*)malloc(sizeof(VkImageView) * texture_count);
        samplers = (VkSampler*)malloc(sizeof(VkSampler) * texture_count);
        
        if (texture_views && samplers) {
            for (uint32_t i = 0; i < texture_count; i++) {
                texture_views[i] = s->pipelines.pbr_pipeline.textureManager->textures[i].view;
                VkSampler texSampler = s->pipelines.pbr_pipeline.textureManager->textures[i].sampler;
                samplers[i] = (texSampler != VK_NULL_HANDLE) 
                    ? texSampler 
                    : s->pipelines.pbr_pipeline.textureManager->defaultSampler;
            }
        } else {
            if (texture_views) free(texture_views);
            if (samplers) free(samplers);
            texture_views = NULL;
            samplers = NULL;
            texture_count = 0; // Allocation failed
        }
    }

    // Call the mesh shader descriptor buffer update function
    // Note: Using NULL for draw_data since this is preparation phase
    if (!vk_mesh_shader_update_descriptor_buffers(s, &s->pipelines.mesh_shader_pipeline, NULL,
                                                  material_buffer, lighting_buffer, texture_views,
                                                  samplers, texture_count)) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to update descriptor buffers during preparation");
    } else {
        CARDINAL_LOG_DEBUG(
            "[MESH_SHADER] Updated descriptor buffers during preparation (bindless textures: %u)",
            texture_count);
    }

    if (texture_views) free(texture_views);
    if (samplers) free(samplers);
}

// === Multi-Threading Support Functions ===

CardinalMTCommandManager* vk_get_mt_command_manager(void) {
    if (!g_cardinal_mt_subsystem.is_running) {
        CARDINAL_LOG_WARN("[MT] Multi-threading subsystem not initialized");
        return NULL;
    }
    return &g_cardinal_mt_subsystem.command_manager;
}

bool vk_submit_mt_command_task(void (*record_func)(void* data), void* user_data,
                               void (*callback)(void* data, bool success)) {
    if (!record_func) {
        CARDINAL_LOG_ERROR("[MT] Invalid record function for command task");
        return false;
    }

    if (!g_cardinal_mt_subsystem.is_running) {
        CARDINAL_LOG_WARN(
            "[MT] Multi-threading subsystem not running, executing task synchronously");
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
