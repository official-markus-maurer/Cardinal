#include <vulkan/vulkan.h>
#include <stdlib.h>
#include <string.h>
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

// Frames in flight setup (double buffering)
s->max_frames_in_flight = 2;
s->current_frame = 0;
s->image_available_semaphores = (VkSemaphore*)calloc(s->max_frames_in_flight, sizeof(VkSemaphore));
s->render_finished_semaphores = (VkSemaphore*)calloc(s->max_frames_in_flight, sizeof(VkSemaphore));
s->in_flight_fences = (VkFence*)calloc(s->max_frames_in_flight, sizeof(VkFence));
s->images_in_flight = (VkFence*)calloc(s->swapchain_image_count, sizeof(VkFence));
for (uint32_t i = 0; i < s->swapchain_image_count; ++i) s->images_in_flight[i] = VK_NULL_HANDLE;

VkSemaphoreCreateInfo si = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
VkFenceCreateInfo fi = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
for (uint32_t i = 0; i < s->max_frames_in_flight; ++i) {
    vkCreateSemaphore(s->device, &si, NULL, &s->image_available_semaphores[i]);
    vkCreateSemaphore(s->device, &si, NULL, &s->render_finished_semaphores[i]);
    vkCreateFence(s->device, &fi, NULL, &s->in_flight_fences[i]);
}

return true;
}

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
if (s->command_pool) vkDestroyCommandPool(s->device, s->command_pool, NULL);
free(s->command_buffers); s->command_buffers = NULL;
}

void vk_record_cmd(VulkanState* s, uint32_t image_index) {
VkCommandBuffer cmd = s->command_buffers[image_index];

// Reset the command buffer before recording
vkResetCommandBuffer(cmd, 0);

VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT; // Add proper usage flags
vkBeginCommandBuffer(cmd, &bi);

VkClearValue clear; clear.color.float32[0]=0.05f; clear.color.float32[1]=0.05f; clear.color.float32[2]=0.08f; clear.color.float32[3]=1.0f;

VkRenderPassBeginInfo rp = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
rp.renderPass = s->render_pass;
rp.framebuffer = s->framebuffers[image_index];
rp.renderArea.extent = s->swapchain_extent;
rp.clearValueCount = 1;
rp.pClearValues = &clear;

vkCmdBeginRenderPass(cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);

// Basic scene draw if available
if (s->pipeline) {
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, s->pipeline);
    for (uint32_t i = 0; i < s->scene_mesh_count; ++i) {
        GpuMesh* m = &s->scene_meshes[i];
        if (!m->vbuf || m->vtx_count == 0) continue;
        VkDeviceSize offsets = 0;
        vkCmdBindVertexBuffers(cmd, 0, 1, &m->vbuf, &offsets);
        if (m->ibuf && m->idx_count > 0) {
            vkCmdBindIndexBuffer(cmd, m->ibuf, 0, VK_INDEX_TYPE_UINT32);
            vkCmdDrawIndexed(cmd, m->idx_count, 1, 0, 0, 0);
        } else {
            vkCmdDraw(cmd, m->vtx_count, 1, 0, 0);
        }
    }
}

// Allow optional UI callback to record draw calls (e.g., ImGui)
if (s->ui_record_callback) {
    s->ui_record_callback(cmd);
}

vkCmdEndRenderPass(cmd);

vkEndCommandBuffer(cmd);
}