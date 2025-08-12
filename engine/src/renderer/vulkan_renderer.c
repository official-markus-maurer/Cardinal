#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <GLFW/glfw3.h>

#include "cardinal/core/window.h"
#include "cardinal/renderer/renderer.h"
#include "cardinal/renderer/renderer_internal.h"
#include "cardinal/core/log.h"
#include "vulkan_swapchain.h"

#include "vulkan_state.h"
#include "vulkan_instance.h"
#include "vulkan_swapchain.h"
#include "vulkan_pipeline.h"
#include "vulkan_commands.h"
#include "cardinal/renderer/vulkan_pbr.h"



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
    
    // Initialize PBR pipeline
    s->use_pbr_pipeline = true;
    if (s->use_pbr_pipeline) {
        if (!vk_pbr_pipeline_create(&s->pbr_pipeline, s->device, s->physical_device, 
                                   s->render_pass, s->command_pools[0], s->graphics_queue)) {
            LOG_ERROR("vk_pbr_pipeline_create failed");
            s->use_pbr_pipeline = false;
        } else {
            LOG_INFO("renderer_create: PBR pipeline");
        }
    }

    return true;
}

void cardinal_renderer_draw_frame(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;

    CARDINAL_LOG_INFO("[SYNC] Frame %u: Starting draw_frame", s->current_frame);
    
    // Wait for the current frame's fence to ensure the previous submission using this frame is complete
    CARDINAL_LOG_INFO("[SYNC] Frame %u: Waiting for fence %p", s->current_frame, (void*)s->in_flight_fences[s->current_frame]);
    VkResult fence_wait = vkWaitForFences(s->device, 1, &s->in_flight_fences[s->current_frame], VK_TRUE, UINT64_MAX);
    CARDINAL_LOG_INFO("[SYNC] Frame %u: Fence wait result: %d", s->current_frame, fence_wait);
    
    if (fence_wait == VK_ERROR_DEVICE_LOST) {
        CARDINAL_LOG_ERROR("[SYNC] Frame %u: DEVICE LOST during fence wait! GPU crashed", s->current_frame);
        return;
    }
    
    uint32_t image_index = 0;
    CARDINAL_LOG_INFO("[SYNC] Frame %u: Acquiring image with semaphore %p", s->current_frame, (void*)s->image_available_semaphores[s->current_frame]);
    VkResult ai = vkAcquireNextImageKHR(s->device, s->swapchain, UINT64_MAX, s->image_available_semaphores[s->current_frame], VK_NULL_HANDLE, &image_index);
    CARDINAL_LOG_INFO("[SYNC] Frame %u: Acquire result: %d, image_index: %u", s->current_frame, ai, image_index);
    if (ai == VK_ERROR_OUT_OF_DATE_KHR || ai == VK_SUBOPTIMAL_KHR) {
        // Swapchain is out of date (e.g., window resized), recreate it
        if (vk_recreate_swapchain(s)) {
            // Recreate images_in_flight array to match new swapchain image count
            vk_recreate_images_in_flight(s);
        }
        return; // Skip this frame
    } else if (ai != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SYNC] Frame %u: Failed to acquire swapchain image: %d", s->current_frame, ai);
        return;
    }

    // If a previous frame is using this image, wait for it
    if (s->images_in_flight[image_index] != VK_NULL_HANDLE) {
        VkResult wait_prev = vkWaitForFences(s->device, 1, &s->images_in_flight[image_index], VK_TRUE, UINT64_MAX);
        CARDINAL_LOG_INFO("[SYNC] Frame %u: Wait for previous fence on image %u result: %d", s->current_frame, image_index, wait_prev);
    }
    
    // Mark the image as now being in use by this frame
    s->images_in_flight[image_index] = s->in_flight_fences[s->current_frame];

    vk_record_cmd(s, image_index);

    VkSemaphore wait_semaphores[] = { s->image_available_semaphores[s->current_frame] };
    VkPipelineStageFlags wait_stages[] = { VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT };
    VkSemaphore signal_semaphores[] = { s->render_finished_semaphores[s->current_frame] };

    VkSubmitInfo submit_info = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO };
    submit_info.waitSemaphoreCount = 1;
    submit_info.pWaitSemaphores = wait_semaphores;
    submit_info.pWaitDstStageMask = wait_stages;
    submit_info.commandBufferCount = 1;
    VkCommandBuffer cmd_buf = s->command_buffers[s->current_frame];
    submit_info.pCommandBuffers = &cmd_buf;
    submit_info.signalSemaphoreCount = 1;
    submit_info.pSignalSemaphores = signal_semaphores;

    VkResult rf_reset = vkResetFences(s->device, 1, &s->in_flight_fences[s->current_frame]);
    CARDINAL_LOG_INFO("[SYNC] Frame %u: Reset fence result: %d", s->current_frame, rf_reset);

    CARDINAL_LOG_INFO("[SUBMIT] Frame %u: Submitting cmd %p", s->current_frame, (void*)cmd_buf);
    VkResult submit_res = vkQueueSubmit(s->graphics_queue, 1, &submit_info, s->in_flight_fences[s->current_frame]);
    CARDINAL_LOG_INFO("[SUBMIT] Frame %u: Submit result: %d", s->current_frame, submit_res);
    if (submit_res == VK_ERROR_DEVICE_LOST) {
        CARDINAL_LOG_ERROR("[SUBMIT] Frame %u: DEVICE LOST during submit!", s->current_frame);
        return;
    }

    VkPresentInfoKHR present_info = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR };
    present_info.waitSemaphoreCount = 1;
    present_info.pWaitSemaphores = signal_semaphores;
    present_info.swapchainCount = 1;
    present_info.pSwapchains = &s->swapchain;
    present_info.pImageIndices = &image_index;

    CARDINAL_LOG_INFO("[PRESENT] Frame %u: Presenting image %u", s->current_frame, image_index);
    VkResult present_res = vkQueuePresentKHR(s->present_queue, &present_info);
    CARDINAL_LOG_INFO("[PRESENT] Frame %u: Present result: %d", s->current_frame, present_res);

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

// Destroy PBR pipeline
if (s->use_pbr_pipeline) {
    vk_pbr_pipeline_destroy(&s->pbr_pipeline, s->device);
}

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
(void)image_index; // unused now
return s->command_buffers[s->current_frame];
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

// Helper function to create perspective projection matrix
static void create_perspective_matrix(float fov, float aspect, float near_plane, float far_plane, float* matrix) {
    memset(matrix, 0, 16 * sizeof(float));
    
    float tan_half_fov = tanf(fov * 0.5f * M_PI / 180.0f);
    
    matrix[0] = 1.0f / (aspect * tan_half_fov);  // [0][0]
    matrix[5] = -1.0f / tan_half_fov;            // [1][1] - Vulkan Y-flip (negative Y)
    matrix[10] = -(far_plane + near_plane) / (far_plane - near_plane);  // [2][2]
    matrix[11] = -1.0f;                          // [2][3]
    matrix[14] = -(2.0f * far_plane * near_plane) / (far_plane - near_plane);  // [3][2]
}

// Helper function to create view matrix (look-at)
static void create_view_matrix(const float* eye, const float* center, const float* up, float* matrix) {
    float f[3] = {center[0] - eye[0], center[1] - eye[1], center[2] - eye[2]};
    float f_len = sqrtf(f[0]*f[0] + f[1]*f[1] + f[2]*f[2]);
    f[0] /= f_len; f[1] /= f_len; f[2] /= f_len;
    
    float s[3] = {f[1]*up[2] - f[2]*up[1], f[2]*up[0] - f[0]*up[2], f[0]*up[1] - f[1]*up[0]};
    float s_len = sqrtf(s[0]*s[0] + s[1]*s[1] + s[2]*s[2]);
    s[0] /= s_len; s[1] /= s_len; s[2] /= s_len;
    
    float u[3] = {s[1]*f[2] - s[2]*f[1], s[2]*f[0] - s[0]*f[2], s[0]*f[1] - s[1]*f[0]};
    
    memset(matrix, 0, 16 * sizeof(float));
    matrix[0] = s[0];   matrix[4] = s[1];   matrix[8] = s[2];   matrix[12] = -(s[0]*eye[0] + s[1]*eye[1] + s[2]*eye[2]);
    matrix[1] = u[0];   matrix[5] = u[1];   matrix[9] = u[2];   matrix[13] = -(u[0]*eye[0] + u[1]*eye[1] + u[2]*eye[2]);
    matrix[2] = -f[0];  matrix[6] = -f[1];  matrix[10] = -f[2]; matrix[14] = f[0]*eye[0] + f[1]*eye[1] + f[2]*eye[2];
    matrix[15] = 1.0f;
}

// Helper function to create identity matrix
static void create_identity_matrix(float* matrix) {
    memset(matrix, 0, 16 * sizeof(float));
    matrix[0] = matrix[5] = matrix[10] = matrix[15] = 1.0f;
}

void cardinal_renderer_set_camera(CardinalRenderer* renderer, const CardinalCamera* camera) {
    if (!renderer || !camera) return;
    VulkanState* s = (VulkanState*)renderer->_opaque;
    
    if (!s->use_pbr_pipeline) return;
    
    PBRUniformBufferObject ubo = {0};
    
    // Create model matrix (identity for now)
    create_identity_matrix(ubo.model);
    
    // Create view matrix
    create_view_matrix(camera->position, camera->target, camera->up, ubo.view);
    
    // Create projection matrix
    create_perspective_matrix(camera->fov, camera->aspect, camera->near_plane, camera->far_plane, ubo.proj);
    
    // Set view position
    ubo.viewPos[0] = camera->position[0];
    ubo.viewPos[1] = camera->position[1];
    ubo.viewPos[2] = camera->position[2];
    
    // Update the uniform buffer
    memcpy(s->pbr_pipeline.uniformBufferMapped, &ubo, sizeof(PBRUniformBufferObject));
}

void cardinal_renderer_set_lighting(CardinalRenderer* renderer, const CardinalLight* light) {
    if (!renderer || !light) return;
    VulkanState* s = (VulkanState*)renderer->_opaque;
    
    if (!s->use_pbr_pipeline) return;
    
    PBRLightingData lighting = {0};
    
    // Set light direction
    lighting.lightDirection[0] = light->direction[0];
    lighting.lightDirection[1] = light->direction[1];
    lighting.lightDirection[2] = light->direction[2];
    
    // Set light color and intensity
    lighting.lightColor[0] = light->color[0];
    lighting.lightColor[1] = light->color[1];
    lighting.lightColor[2] = light->color[2];
    lighting.lightIntensity = light->intensity;
    
    // Set ambient color
    lighting.ambientColor[0] = light->ambient[0];
    lighting.ambientColor[1] = light->ambient[1];
    lighting.ambientColor[2] = light->ambient[2];
    
    // Update the lighting buffer
    memcpy(s->pbr_pipeline.lightingBufferMapped, &lighting, sizeof(PBRLightingData));
}

void cardinal_renderer_enable_pbr(CardinalRenderer* renderer, bool enable) {
    if (!renderer) return;
    VulkanState* s = (VulkanState*)renderer->_opaque;
    
    if (enable && !s->use_pbr_pipeline) {
        // Wait for all GPU operations to complete before creating new resources
        vkDeviceWaitIdle(s->device);
        
        // Try to create PBR pipeline if it doesn't exist
        if (vk_pbr_pipeline_create(&s->pbr_pipeline, s->device, s->physical_device,
                                  s->render_pass, s->command_pools[0], s->graphics_queue)) {
            s->use_pbr_pipeline = true;
            
            // Load current scene if one exists
            if (s->current_scene) {
                vk_pbr_load_scene(&s->pbr_pipeline, s->device, s->physical_device,
                                 s->command_pools[0], s->graphics_queue, s->current_scene);
            }
            
            CARDINAL_LOG_INFO("PBR pipeline enabled");
        } else {
            CARDINAL_LOG_ERROR("Failed to enable PBR pipeline");
        }
    } else if (!enable && s->use_pbr_pipeline) {
        // Wait for all GPU operations to complete before destroying resources
        vkDeviceWaitIdle(s->device);
        
        // Destroy PBR pipeline
        vk_pbr_pipeline_destroy(&s->pbr_pipeline, s->device);
        s->use_pbr_pipeline = false;
        CARDINAL_LOG_INFO("PBR pipeline disabled");
    }
}

bool cardinal_renderer_is_pbr_enabled(CardinalRenderer* renderer) {
    if (!renderer) return false;
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->use_pbr_pipeline;
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
    ai.commandPool = s->command_pools[s->current_frame];
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

    vkFreeCommandBuffers(s->device, s->command_pools[s->current_frame], 1, &cmd);
}

void cardinal_renderer_upload_scene(CardinalRenderer* renderer, const CardinalScene* scene) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    
    // Wait for all GPU operations to complete before modifying scene buffers
    vkDeviceWaitIdle(s->device);
    
    destroy_scene_buffers(s);
    if (!scene || scene->mesh_count == 0) return;

    s->scene_mesh_count = scene->mesh_count;
    s->scene_meshes = (GpuMesh*)calloc(s->scene_mesh_count, sizeof(GpuMesh));
    if (!s->scene_meshes) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for scene meshes");
        return;
    }

    for (uint32_t i=0;i<scene->mesh_count;i++) {
        const CardinalMesh* src = &scene->meshes[i];
        GpuMesh* dst = &s->scene_meshes[i];
        
        // Initialize to null handles
        dst->vbuf = VK_NULL_HANDLE;
        dst->vmem = VK_NULL_HANDLE;
        dst->ibuf = VK_NULL_HANDLE;
        dst->imem = VK_NULL_HANDLE;
        dst->vtx_count = 0;
        dst->idx_count = 0;
        
        dst->vtx_stride = sizeof(float)*8;
        VkDeviceSize vsize = (VkDeviceSize)src->vertex_count * dst->vtx_stride;
        VkDeviceSize isize = (VkDeviceSize)src->index_count * sizeof(uint32_t);

        if (!src->vertices || src->vertex_count == 0) {
            CARDINAL_LOG_ERROR("Mesh %u has no vertices", i);
            continue;
        }

        // Create CPU-visible buffers and upload directly (simple, not optimal)
        VkBufferCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
        vci.size = vsize; vci.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT; vci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        vkCreateBuffer(s->device, &vci, NULL, &dst->vbuf);
        VkMemoryRequirements vrq; vkGetBufferMemoryRequirements(s->device, dst->vbuf, &vrq);
        VkMemoryAllocateInfo vai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
        vai.allocationSize = vrq.size; vai.memoryTypeIndex = 0;
        // findMemoryType is in PBR file; replicate basic host visible here
        VkPhysicalDeviceMemoryProperties mem_props; vkGetPhysicalDeviceMemoryProperties(s->physical_device, &mem_props);
        for (uint32_t mt=0; mt<mem_props.memoryTypeCount; ++mt) {
            if ((vrq.memoryTypeBits & (1u<<mt)) && (mem_props.memoryTypes[mt].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) { vai.memoryTypeIndex = mt; break; }
        }
        vkAllocateMemory(s->device, &vai, NULL, &dst->vmem);
        vkBindBufferMemory(s->device, dst->vbuf, dst->vmem, 0);
        void* vmap = NULL; vkMapMemory(s->device, dst->vmem, 0, vsize, 0, &vmap); memcpy(vmap, src->vertices, (size_t)vsize); vkUnmapMemory(s->device, dst->vmem);

        if (src->index_count > 0 && src->indices) {
            VkBufferCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
            ici.size = isize; ici.usage = VK_BUFFER_USAGE_INDEX_BUFFER_BIT; ici.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            vkCreateBuffer(s->device, &ici, NULL, &dst->ibuf);
            VkMemoryRequirements irq; vkGetBufferMemoryRequirements(s->device, dst->ibuf, &irq);
            VkMemoryAllocateInfo iai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
            iai.allocationSize = irq.size; iai.memoryTypeIndex = 0;
            for (uint32_t mt=0; mt<mem_props.memoryTypeCount; ++mt) {
                if ((irq.memoryTypeBits & (1u<<mt)) && (mem_props.memoryTypes[mt].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) { iai.memoryTypeIndex = mt; break; }
            }
            vkAllocateMemory(s->device, &iai, NULL, &dst->imem);
            vkBindBufferMemory(s->device, dst->ibuf, dst->imem, 0);
            void* imap = NULL; vkMapMemory(s->device, dst->imem, 0, isize, 0, &imap); memcpy(imap, src->indices, (size_t)isize); vkUnmapMemory(s->device, dst->imem);
            dst->idx_count = src->index_count;
        }
        dst->vtx_count = src->vertex_count;

        CARDINAL_LOG_INFO("Successfully uploaded mesh %u: %u vertices, %u indices", i, src->vertex_count, src->index_count);
    }
    
    // Load scene into PBR pipeline if enabled
    if (s->use_pbr_pipeline) {
        vk_pbr_load_scene(&s->pbr_pipeline, s->device, s->physical_device,
                         s->command_pools[0], s->graphics_queue, scene);
    }

    // Remember pointer for PBR drawing path
    s->current_scene = scene;
}

void cardinal_renderer_clear_scene(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    
    // Wait for all GPU operations to complete before destroying scene buffers
    vkDeviceWaitIdle(s->device);
    
    destroy_scene_buffers(s);
}
