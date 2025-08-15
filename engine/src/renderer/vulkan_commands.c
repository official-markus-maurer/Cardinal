#include <vulkan/vulkan.h>
#include <stdlib.h>
#include <string.h>
#include "vulkan_state.h"
#include <cardinal/renderer/vulkan_commands.h>
#include "cardinal/core/log.h"
#include "cardinal/renderer/vulkan_pbr.h"

/**
 * @brief Creates command pools, buffers, and synchronization objects.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 * 
 * @todo Add support for multi-threaded command buffer allocation.
 */
bool vk_create_commands_sync(VulkanState* s) {
// Use 3 frames in flight for better buffering
s->max_frames_in_flight = 3;
s->current_frame = 0;

// Create per-frame command pools
s->command_pools = (VkCommandPool*)malloc(sizeof(VkCommandPool) * s->max_frames_in_flight);
for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
    VkCommandPoolCreateInfo cp = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
    cp.queueFamilyIndex = s->graphics_queue_family;
    if (vkCreateCommandPool(s->device, &cp, NULL, &s->command_pools[i]) != VK_SUCCESS) return false;
}

// Allocate command buffers per frame in flight, not per swapchain image
s->command_buffers = (VkCommandBuffer*)malloc(sizeof(VkCommandBuffer)*s->max_frames_in_flight);
for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
    VkCommandBufferAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    ai.commandPool = s->command_pools[i];
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(s->device, &ai, &s->command_buffers[i]) != VK_SUCCESS) return false;
}

// Allocate swapchain image layout initialization tracking array
CARDINAL_LOG_INFO("[INIT] Allocating swapchain_image_layout_initialized for %u swapchain images", s->swapchain_image_count);
if (s->swapchain_image_layout_initialized) { free(s->swapchain_image_layout_initialized); s->swapchain_image_layout_initialized = NULL; }
s->swapchain_image_layout_initialized = (bool*)calloc(s->swapchain_image_count, sizeof(bool));
if (!s->swapchain_image_layout_initialized) return false;

// Create per-frame binary semaphores for image acquisition
if (s->image_acquired_semaphores) { free(s->image_acquired_semaphores); s->image_acquired_semaphores = NULL; }
s->image_acquired_semaphores = (VkSemaphore*)calloc(s->max_frames_in_flight, sizeof(VkSemaphore));
if (!s->image_acquired_semaphores) return false;
for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
    VkSemaphoreCreateInfo sci = {0};
    sci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    if (vkCreateSemaphore(s->device, &sci, NULL, &s->image_acquired_semaphores[i]) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[INIT] Failed to create image acquired semaphore for frame %u", i);
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
s->image_available_value = 1;  // after acquire
s->render_complete_value = 2;  // after submit

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
    CARDINAL_LOG_INFO("[INIT] Recreating swapchain_image_layout_initialized for %u swapchain images", s->swapchain_image_count);
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
 * @todo Ensure thread-safe destruction.
 */
void vk_destroy_commands_sync(VulkanState* s) {
if (!s) return;

// Destroy timeline semaphore
if (s->timeline_semaphore) {
    vkDestroySemaphore(s->device, s->timeline_semaphore, NULL);
    s->timeline_semaphore = VK_NULL_HANDLE;
}

// Destroy per-frame acquire semaphores
if (s->image_acquired_semaphores) {
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
        if (s->image_acquired_semaphores[i]) vkDestroySemaphore(s->device, s->image_acquired_semaphores[i], NULL);
    }
    free(s->image_acquired_semaphores);
    s->image_acquired_semaphores = NULL;
}

free(s->swapchain_image_layout_initialized); s->swapchain_image_layout_initialized = NULL;
if (s->command_buffers) { free(s->command_buffers); s->command_buffers = NULL; }
if (s->command_pools) {
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) if (s->command_pools[i]) vkDestroyCommandPool(s->device, s->command_pools[i], NULL);
    free(s->command_pools); s->command_pools = NULL;
}
}

/**
 * @brief Records drawing commands into a command buffer.
 * @param s Vulkan state.
 * @param image_index Swapchain image index.
 * 
 * @todo Implement secondary command buffers for better parallelism.
 * @todo Enhance error handling for recording failures.
 */
void vk_record_cmd(VulkanState* s, uint32_t image_index) {
VkCommandBuffer cmd = s->command_buffers[s->current_frame];  // Use current frame, not image index

CARDINAL_LOG_INFO("[CMD] Frame %u: Recording command buffer %p for image %u", s->current_frame, (void*)cmd, image_index);

// Reset the command buffer - safe because we waited for the timeline semaphore
CARDINAL_LOG_INFO("[CMD] Frame %u: Resetting command buffer %p", s->current_frame, (void*)cmd);
VkResult reset_result = vkResetCommandBuffer(cmd, 0);
CARDINAL_LOG_INFO("[CMD] Frame %u: Reset result: %d", s->current_frame, reset_result);

if (reset_result != VK_SUCCESS) {
    CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to reset command buffer: %d", s->current_frame, reset_result);
    return;
}

VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
CARDINAL_LOG_INFO("[CMD] Frame %u: Beginning command buffer %p with flags %u", s->current_frame, (void*)cmd, bi.flags);
VkResult begin_result = vkBeginCommandBuffer(cmd, &bi);
CARDINAL_LOG_INFO("[CMD] Frame %u: Begin result: %d", s->current_frame, begin_result);

if (begin_result != VK_SUCCESS) {
    CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to begin command buffer: %d", s->current_frame, begin_result);
    return;
}

VkClearValue clears[2];
clears[0].color.float32[0] = 0.05f; clears[0].color.float32[1] = 0.05f; clears[0].color.float32[2] = 0.08f; clears[0].color.float32[3] = 1.0f;
clears[1].depthStencil.depth = 1.0f; clears[1].depthStencil.stencil = 0;

// Ensure depth image layout is transitioned once
if (!s->depth_layout_initialized) {
    VkImageMemoryBarrier2 barrier = {0};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
    barrier.srcAccessMask = 0;
    barrier.dstStageMask = VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT;
    barrier.dstAccessMask = VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
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
    barrier.dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
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
    s->vkCmdPipelineBarrier2(cmd, &dep);
    s->swapchain_image_layout_initialized[image_index] = true;
} else {
    VkImageMemoryBarrier2 barrier = {0};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    barrier.srcAccessMask = 0;
    barrier.dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;
    barrier.dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
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

// Draw PBR scene
if (s->use_pbr_pipeline && s->pbr_pipeline.initialized && s->current_scene) {
    // Ensure PBR uniforms are updated before rendering
    PBRUniformBufferObject ubo;
    memcpy(&ubo, s->pbr_pipeline.uniformBufferMapped, sizeof(PBRUniformBufferObject));
    PBRLightingData lighting;
    memcpy(&lighting, s->pbr_pipeline.lightingBufferMapped, sizeof(PBRLightingData));
    vk_pbr_update_uniforms(&s->pbr_pipeline, &ubo, &lighting);

    vk_pbr_render(&s->pbr_pipeline, cmd, s->current_scene);
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
s->vkCmdPipelineBarrier2(cmd, &dep);

CARDINAL_LOG_INFO("[CMD] Frame %u: Ending command buffer %p", s->current_frame, (void*)cmd);
VkResult end_result = vkEndCommandBuffer(cmd);
CARDINAL_LOG_INFO("[CMD] Frame %u: End result: %d", s->current_frame, end_result);

if (end_result != VK_SUCCESS) {
    CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to end command buffer: %d", s->current_frame, end_result);
    return;
}
}
