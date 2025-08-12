#include <vulkan/vulkan.h>
#include <stdlib.h>
#include <string.h>
#include "vulkan_state.h"
#include "vulkan_commands.h"
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
    VkCommandPoolCreateInfo cp = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cp.queueFamilyIndex = s->graphics_queue_family;
    cp.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT | VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
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

s->image_available_semaphores = (VkSemaphore*)calloc(s->max_frames_in_flight, sizeof(VkSemaphore));
s->render_finished_semaphores = (VkSemaphore*)calloc(s->max_frames_in_flight, sizeof(VkSemaphore));
s->in_flight_fences = (VkFence*)calloc(s->max_frames_in_flight, sizeof(VkFence));

// Allocate images_in_flight array based on swapchain image count
CARDINAL_LOG_INFO("[INIT] Allocating images_in_flight for %u swapchain images", s->swapchain_image_count);
s->images_in_flight = (VkFence*)calloc(s->swapchain_image_count, sizeof(VkFence));
for (uint32_t i = 0; i < s->swapchain_image_count; ++i) s->images_in_flight[i] = VK_NULL_HANDLE;

VkSemaphoreCreateInfo si = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
VkFenceCreateInfo fi = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
CARDINAL_LOG_INFO("[INIT] Creating sync objects for %u frames in flight", s->max_frames_in_flight);
for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
    VkResult sem1_result = vkCreateSemaphore(s->device, &si, NULL, &s->image_available_semaphores[i]);
    VkResult sem2_result = vkCreateSemaphore(s->device, &si, NULL, &s->render_finished_semaphores[i]);
    VkResult fence_result = vkCreateFence(s->device, &fi, NULL, &s->in_flight_fences[i]);
    CARDINAL_LOG_INFO("[INIT] Frame %u: image_sem=%p (result=%d), render_sem=%p (result=%d), fence=%p (result=%d, signaled)", 
                      i, (void*)s->image_available_semaphores[i], sem1_result, 
                      (void*)s->render_finished_semaphores[i], sem2_result,
                      (void*)s->in_flight_fences[i], fence_result);
}

return true;
}

/**
 * @brief Recreates the images in flight array after swapchain changes.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 * 
 * @todo Optimize memory management for frequent recreations.
 */
bool vk_recreate_images_in_flight(VulkanState* s) {
    if (!s) return false;
    
    // Free old array
    free(s->images_in_flight);
    
    // Allocate new array based on current swapchain image count
    CARDINAL_LOG_INFO("[INIT] Recreating images_in_flight for %u swapchain images", s->swapchain_image_count);
    s->images_in_flight = (VkFence*)calloc(s->swapchain_image_count, sizeof(VkFence));
    if (!s->images_in_flight) {
        CARDINAL_LOG_ERROR("[INIT] Failed to allocate images_in_flight array");
        return false;
    }
    
    for (uint32_t i = 0; i < s->swapchain_image_count; ++i) {
        s->images_in_flight[i] = VK_NULL_HANDLE;
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
if (s->in_flight_fences) {
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) if (s->in_flight_fences[i]) vkDestroyFence(s->device, s->in_flight_fences[i], NULL);
    free(s->in_flight_fences); s->in_flight_fences = NULL;
}
if (s->render_finished_semaphores) {
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) if (s->render_finished_semaphores[i]) vkDestroySemaphore(s->device, s->render_finished_semaphores[i], NULL);
    free(s->render_finished_semaphores); s->render_finished_semaphores = NULL;
}
if (s->image_available_semaphores) {
    for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) if (s->image_available_semaphores[i]) vkDestroySemaphore(s->device, s->image_available_semaphores[i], NULL);
    free(s->image_available_semaphores); s->image_available_semaphores = NULL;
}
free(s->images_in_flight); s->images_in_flight = NULL;
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

// Reset the command buffer - safe because we waited for the fence
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

VkRenderPassBeginInfo rp = (VkRenderPassBeginInfo){ .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
rp.renderPass = s->render_pass;
rp.framebuffer = s->framebuffers[image_index];
rp.renderArea.extent = s->swapchain_extent;
rp.clearValueCount = 2;
rp.pClearValues = clears;

vkCmdBeginRenderPass(cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);

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

// Draw PBR scene if enabled, otherwise use simple pipeline
if (s->use_pbr_pipeline && s->pbr_pipeline.initialized && s->current_scene) {
    vk_pbr_render(&s->pbr_pipeline, cmd, s->current_scene);
} else if (s->pipeline) {
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, s->pipeline);
    vkCmdDraw(cmd, 3, 1, 0, 0);
}

// Allow optional UI callback to record draw calls (e.g., ImGui)
if (s->ui_record_callback) {
    s->ui_record_callback(cmd);
}

vkCmdEndRenderPass(cmd);

CARDINAL_LOG_INFO("[CMD] Frame %u: Ending command buffer %p", s->current_frame, (void*)cmd);
VkResult end_result = vkEndCommandBuffer(cmd);
CARDINAL_LOG_INFO("[CMD] Frame %u: End result: %d", s->current_frame, end_result);

if (end_result != VK_SUCCESS) {
    CARDINAL_LOG_ERROR("[CMD] Frame %u: Failed to end command buffer: %d", s->current_frame, end_result);
    return;
}
}
