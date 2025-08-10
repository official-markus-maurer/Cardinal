#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#include <GLFW/glfw3.h>

#include "cardinal/core/window.h"
#include "cardinal/renderer/renderer.h"
#include "cardinal/renderer/renderer_internal.h"

#include "vulkan_state.h"
#include "vulkan_instance.h"
#include "vulkan_swapchain.h"
#include "vulkan_pipeline.h"
#include "vulkan_commands.h"

bool cardinal_renderer_create(CardinalRenderer* out_renderer, CardinalWindow* window) {
if (!out_renderer || !window) return false;
VulkanState* s = (VulkanState*)calloc(1, sizeof(VulkanState));
out_renderer->_opaque = s;

if (!vk_create_instance(s)) return false;
if (!vk_create_surface(s, window)) return false;
if (!vk_pick_physical_device(s)) return false;
if (!vk_create_device(s)) return false;
if (!vk_create_swapchain(s)) return false;
if (!vk_create_renderpass_pipeline(s)) return false;
if (!vk_create_commands_sync(s)) return false;

return true;
}

void cardinal_renderer_draw_frame(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;

vkWaitForFences(s->device, 1, &s->in_flight, VK_TRUE, UINT64_MAX);
vkResetFences(s->device, 1, &s->in_flight);

uint32_t image_index = 0;
vkAcquireNextImageKHR(s->device, s->swapchain, UINT64_MAX, s->image_available, VK_NULL_HANDLE, &image_index);

vk_record_cmd(s, image_index);

VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO };
submit.waitSemaphoreCount = 1;
submit.pWaitSemaphores = &s->image_available;
submit.pWaitDstStageMask = &wait_stage;
submit.commandBufferCount = 1;
submit.pCommandBuffers = &s->command_buffers[image_index];
submit.signalSemaphoreCount = 1;
submit.pSignalSemaphores = &s->render_finished;
vkQueueSubmit(s->graphics_queue, 1, &submit, s->in_flight);

VkPresentInfoKHR present = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR };
present.waitSemaphoreCount = 1;
present.pWaitSemaphores = &s->render_finished;
present.swapchainCount = 1;
present.pSwapchains = &s->swapchain;
present.pImageIndices = &image_index;
vkQueuePresentKHR(s->graphics_queue, &present);
}

void cardinal_renderer_wait_idle(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;
vkDeviceWaitIdle(s->device);
}

void cardinal_renderer_destroy(CardinalRenderer* renderer) {
if (!renderer || !renderer->_opaque) return;
VulkanState* s = (VulkanState*)renderer->_opaque;

// destroy in reverse order
vk_destroy_commands_sync(s);
vk_destroy_renderpass_pipeline(s);
vk_destroy_swapchain(s);
vk_destroy_device_objects(s);

free(s);
renderer->_opaque = NULL;
}

// Internal API implementations for editor ImGui integration
VkRenderPass cardinal_renderer_internal_render_pass(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;
return s->render_pass;
}

VkCommandBuffer cardinal_renderer_internal_current_cmd(CardinalRenderer* renderer, uint32_t image_index) {
VulkanState* s = (VulkanState*)renderer->_opaque;
return s->command_buffers[image_index];
}

VkDevice cardinal_renderer_internal_device(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;
return s->device;
}

VkPhysicalDevice cardinal_renderer_internal_physical_device(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;
return s->physical_device;
}

VkQueue cardinal_renderer_internal_graphics_queue(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;
return s->graphics_queue;
}

uint32_t cardinal_renderer_internal_graphics_queue_family(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;
return s->graphics_queue_family;
}

VkInstance cardinal_renderer_internal_instance(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;
return s->instance;
}

uint32_t cardinal_renderer_internal_swapchain_image_count(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->swapchain_image_count;
}

void cardinal_renderer_set_ui_callback(CardinalRenderer* renderer, void (*callback)(VkCommandBuffer cmd)) {
VulkanState* s = (VulkanState*)renderer->_opaque;
s->ui_record_callback = callback;
}

void cardinal_renderer_immediate_submit(CardinalRenderer* renderer, void (*record)(VkCommandBuffer cmd)) {
    VulkanState* s = (VulkanState*)renderer->_opaque;

    VkCommandBufferAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    ai.commandPool = s->command_pool;
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;

    VkCommandBuffer cmd;
    vkAllocateCommandBuffers(s->device, &ai, &cmd);

    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &bi);

    if (record) record(cmd);

    vkEndCommandBuffer(cmd);

    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO };
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &cmd;

    vkQueueSubmit(s->graphics_queue, 1, &submit, VK_NULL_HANDLE);
    vkQueueWaitIdle(s->graphics_queue);

    vkFreeCommandBuffers(s->device, s->command_pool, 1, &cmd);
}
