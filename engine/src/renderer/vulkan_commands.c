#include <vulkan/vulkan.h>
#include <stdlib.h>
#include "vulkan_state.h"
#include "vulkan_commands.h"

bool vk_create_commands_sync(VulkanState* s) {
VkCommandPoolCreateInfo cp = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
cp.queueFamilyIndex = s->graphics_queue_family;
cp.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
if (vkCreateCommandPool(s->device, &cp, NULL, &s->command_pool) != VK_SUCCESS) return false;

s->command_buffers = (VkCommandBuffer*)malloc(sizeof(VkCommandBuffer)*s->swapchain_image_count);
VkCommandBufferAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
ai.commandPool = s->command_pool;
ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
ai.commandBufferCount = s->swapchain_image_count;
if (vkAllocateCommandBuffers(s->device, &ai, s->command_buffers) != VK_SUCCESS) return false;

VkSemaphoreCreateInfo si = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
vkCreateSemaphore(s->device, &si, NULL, &s->image_available);
vkCreateSemaphore(s->device, &si, NULL, &s->render_finished);

VkFenceCreateInfo fi = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
fi.flags = VK_FENCE_CREATE_SIGNALED_BIT;
vkCreateFence(s->device, &fi, NULL, &s->in_flight);

return true;
}

void vk_destroy_commands_sync(VulkanState* s) {
if (!s) return;
if (s->in_flight) vkDestroyFence(s->device, s->in_flight, NULL);
if (s->render_finished) vkDestroySemaphore(s->device, s->render_finished, NULL);
if (s->image_available) vkDestroySemaphore(s->device, s->image_available, NULL);
if (s->command_pool) vkDestroyCommandPool(s->device, s->command_pool, NULL);
free(s->command_buffers); s->command_buffers = NULL;
}

void vk_record_cmd(VulkanState* s, uint32_t image_index) {
VkCommandBuffer cmd = s->command_buffers[image_index];

VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
vkBeginCommandBuffer(cmd, &bi);

VkClearValue clear; clear.color.float32[0]=0.05f; clear.color.float32[1]=0.05f; clear.color.float32[2]=0.08f; clear.color.float32[3]=1.0f;

VkRenderPassBeginInfo rp = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
rp.renderPass = s->render_pass;
rp.framebuffer = s->framebuffers[image_index];
rp.renderArea.extent = s->swapchain_extent;
rp.clearValueCount = 1;
rp.pClearValues = &clear;

vkCmdBeginRenderPass(cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);

// Allow optional UI callback to record draw calls (e.g., ImGui)
if (s->ui_record_callback) {
    s->ui_record_callback(cmd);
}

// No draw calls; clearing only
vkCmdEndRenderPass(cmd);

vkEndCommandBuffer(cmd);
}