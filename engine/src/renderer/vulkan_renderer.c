#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#include <GLFW/glfw3.h>

#include "cardinal/core/window.h"
#include "cardinal/renderer/renderer.h"
#include "cardinal/renderer/renderer_internal.h"
#include "cardinal/core/log.h"

#include "vulkan_state.h"
#include "vulkan_instance.h"
#include "vulkan_swapchain.h"
#include "vulkan_pipeline.h"
#include "vulkan_commands.h"

static uint32_t find_memory_type(VulkanState* s, uint32_t typeBits, VkMemoryPropertyFlags props) {
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(s->physical_device, &mp);
    for (uint32_t i=0;i<mp.memoryTypeCount;i++) {
        if ((typeBits & (1u<<i)) && (mp.memoryTypes[i].propertyFlags & props) == props) return i;
    }
    return UINT32_MAX;
}

static void create_buffer(VulkanState* s, VkDeviceSize size, VkBufferUsageFlags usage, VkMemoryPropertyFlags props, VkBuffer* out_buf, VkDeviceMemory* out_mem) {
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = size; bci.usage = usage; bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    vkCreateBuffer(s->device, &bci, NULL, out_buf);
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(s->device, *out_buf, &mr);
    VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = mr.size; ai.memoryTypeIndex = find_memory_type(s, mr.memoryTypeBits, props);
    vkAllocateMemory(s->device, &ai, NULL, out_mem);
    vkBindBufferMemory(s->device, *out_buf, *out_mem, 0);
}

// Logging provided by centralized core logger
// Logging now provided by core logger

bool cardinal_renderer_create(CardinalRenderer* out_renderer, CardinalWindow* window) {
    if (!out_renderer || !window) return false;
    VulkanState* s = (VulkanState*)calloc(1, sizeof(VulkanState));
    out_renderer->_opaque = s;

    LOG_INFO("renderer_create: begin");
    if (!vk_create_instance(s)) { LOG_ERROR("vk_create_instance failed"); return false; }
    LOG_INFO("renderer_create: instance");
    if (!vk_create_surface(s, window)) { LOG_ERROR("vk_create_surface failed"); return false; }
    LOG_INFO("renderer_create: surface");
    if (!vk_pick_physical_device(s)) { LOG_ERROR("vk_pick_physical_device failed"); return false; }
    LOG_INFO("renderer_create: physical_device");
    if (!vk_create_device(s)) { LOG_ERROR("vk_create_device failed"); return false; }
    LOG_INFO("renderer_create: device");
    if (!vk_create_swapchain(s)) { LOG_ERROR("vk_create_swapchain failed"); return false; }
    LOG_INFO("renderer_create: swapchain");
    if (!vk_create_renderpass_pipeline(s)) { LOG_ERROR("vk_create_renderpass_pipeline failed"); return false; }
    LOG_INFO("renderer_create: pipeline");
    if (!vk_create_commands_sync(s)) { LOG_ERROR("vk_create_commands_sync failed"); return false; }
    LOG_INFO("renderer_create: commands");

    return true;
}

void cardinal_renderer_draw_frame(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;

// Wait for current frame fence
vkWaitForFences(s->device, 1, &s->in_flight_fences[s->current_frame], VK_TRUE, UINT64_MAX);

uint32_t image_index = 0;
VkResult ai = vkAcquireNextImageKHR(s->device, s->swapchain, UINT64_MAX, s->image_available_semaphores[s->current_frame], VK_NULL_HANDLE, &image_index);
if (ai != VK_SUCCESS && ai != VK_SUBOPTIMAL_KHR) {
    return; // Skip frame if acquire failed
}

// If a previous frame is using this image, wait for it
if (s->images_in_flight[image_index] != VK_NULL_HANDLE) {
    vkWaitForFences(s->device, 1, &s->images_in_flight[image_index], VK_TRUE, UINT64_MAX);
}

// Reset fence for this frame AFTER all waits are done
vkResetFences(s->device, 1, &s->in_flight_fences[s->current_frame]);

// Mark the image as now being in use by this frame
s->images_in_flight[image_index] = s->in_flight_fences[s->current_frame];

vk_record_cmd(s, image_index);

VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO };
submit.waitSemaphoreCount = 1;
submit.pWaitSemaphores = &s->image_available_semaphores[s->current_frame];
submit.pWaitDstStageMask = &wait_stage;
submit.commandBufferCount = 1;
submit.pCommandBuffers = &s->command_buffers[image_index];
submit.signalSemaphoreCount = 1;
submit.pSignalSemaphores = &s->render_finished_semaphores[s->current_frame];

vkQueueSubmit(s->graphics_queue, 1, &submit, s->in_flight_fences[s->current_frame]);

VkPresentInfoKHR present = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR };
present.waitSemaphoreCount = 1;
present.pWaitSemaphores = &s->render_finished_semaphores[s->current_frame];
present.swapchainCount = 1;
present.pSwapchains = &s->swapchain;
present.pImageIndices = &image_index;
vkQueuePresentKHR(s->graphics_queue, &present);

// Advance to next frame
s->current_frame = (s->current_frame + 1) % s->max_frames_in_flight;
}

void cardinal_renderer_wait_idle(CardinalRenderer* renderer) {
VulkanState* s = (VulkanState*)renderer->_opaque;
vkDeviceWaitIdle(s->device);
}

static void destroy_scene_buffers(VulkanState* s) {
    if (!s || !s->scene_meshes) return;
    for (uint32_t i=0;i<s->scene_mesh_count;i++) {
        GpuMesh* m = &s->scene_meshes[i];
        if (m->vbuf) vkDestroyBuffer(s->device, m->vbuf, NULL);
        if (m->vmem) vkFreeMemory(s->device, m->vmem, NULL);
        if (m->ibuf) vkDestroyBuffer(s->device, m->ibuf, NULL);
        if (m->imem) vkFreeMemory(s->device, m->imem, NULL);
    }
    free(s->scene_meshes); s->scene_meshes = NULL; s->scene_mesh_count = 0;
}

void cardinal_renderer_destroy(CardinalRenderer* renderer) {
if (!renderer || !renderer->_opaque) return;
VulkanState* s = (VulkanState*)renderer->_opaque;

// destroy in reverse order
vk_destroy_commands_sync(s);
destroy_scene_buffers(s);
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

void cardinal_renderer_upload_scene(CardinalRenderer* renderer, const CardinalScene* scene) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    
    // Wait for all GPU operations to complete before modifying scene buffers
    vkDeviceWaitIdle(s->device);
    
    destroy_scene_buffers(s);
    if (!scene || scene->mesh_count == 0) return;

    s->scene_mesh_count = scene->mesh_count;
    s->scene_meshes = (GpuMesh*)calloc(s->scene_mesh_count, sizeof(GpuMesh));

    for (uint32_t i=0;i<scene->mesh_count;i++) {
        const CardinalMesh* src = &scene->meshes[i];
        GpuMesh* dst = &s->scene_meshes[i];
        dst->vtx_stride = sizeof(float)*8;
        VkDeviceSize vsize = (VkDeviceSize)src->vertex_count * dst->vtx_stride;
        VkDeviceSize isize = (VkDeviceSize)src->index_count * sizeof(uint32_t);

        // Create CPU-visible buffers and upload directly (simple, not optimal)
        create_buffer(s, vsize, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &dst->vbuf, &dst->vmem);
        void* p = NULL; if (vsize) { vkMapMemory(s->device, dst->vmem, 0, vsize, 0, &p); memcpy(p, src->vertices, (size_t)vsize); vkUnmapMemory(s->device, dst->vmem); }

        if (isize) {
            create_buffer(s, isize, VK_BUFFER_USAGE_INDEX_BUFFER_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &dst->ibuf, &dst->imem);
            void* ip = NULL; vkMapMemory(s->device, dst->imem, 0, isize, 0, &ip); memcpy(ip, src->indices, (size_t)isize); vkUnmapMemory(s->device, dst->imem);
        }

        dst->vtx_count = src->vertex_count;
        dst->idx_count = src->index_count;
    }
}

void cardinal_renderer_clear_scene(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    
    // Wait for all GPU operations to complete before destroying scene buffers
    vkDeviceWaitIdle(s->device);
    
    destroy_scene_buffers(s);
}
