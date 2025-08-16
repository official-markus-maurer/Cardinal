/**
 * @file vulkan_renderer.c
 * @brief Main Vulkan renderer implementation for Cardinal Engine
 *
 * This file contains the core implementation of the Cardinal Engine's Vulkan-based
 * renderer. It manages the complete rendering pipeline from initialization to
 * frame rendering, including Vulkan state management, resource creation, and
 * the main render loop.
 *
 * Key responsibilities:
 * - Vulkan instance and device initialization
 * - Swapchain creation and management
 * - Command buffer recording and submission
 * - PBR pipeline setup and rendering
 * - Frame synchronization and presentation
 * - Resource cleanup and destruction
 *
 * The renderer supports:
 * - Physically Based Rendering (PBR) with metallic-roughness workflow
 * - Dynamic scene loading and rendering
 * - Camera and lighting configuration
 * - UI integration through ImGui callbacks
 * - Immediate command submission for one-time operations
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
    #define M_PI 3.14159265358979323846
#endif
#include <GLFW/glfw3.h>

#include "cardinal/core/log.h"
#include "cardinal/core/window.h"
#include "cardinal/renderer/renderer.h"
#include "cardinal/renderer/renderer_internal.h"
#include <cardinal/renderer/vulkan_swapchain.h>

#include "cardinal/assets/material_ref_counting.h"
#include "cardinal/core/ref_counting.h"
#include "cardinal/renderer/vulkan_pbr.h"
#include "vulkan_simple_pipelines.h"
#include "vulkan_state.h"
#include <cardinal/renderer/util/vulkan_buffer_utils.h>
#include <cardinal/renderer/vulkan_commands.h>
#include <cardinal/renderer/vulkan_instance.h>
#include <cardinal/renderer/vulkan_pipeline.h>

/**
 * @brief Creates and initializes the Cardinal Renderer.
 *
 * This function sets up the Vulkan state including instance, device, swapchain, and pipelines.
 * @param out_renderer Pointer to the CardinalRenderer structure to initialize.
 * @param window Pointer to the CardinalWindow for surface creation.
 * @return true if creation succeeds, false otherwise.
 *
 * @todo Add support for Vulkan validation layers in debug mode.
 * @todo Investigate integrating ray tracing extensions for advanced rendering features.
 */
bool cardinal_renderer_create(CardinalRenderer* out_renderer, CardinalWindow* window) {
    if (!out_renderer || !window)
        return false;
    VulkanState* s = (VulkanState*)calloc(1, sizeof(VulkanState));
    out_renderer->_opaque = s;

    LOG_INFO("renderer_create: begin");
    if (!vk_create_instance(s)) {
        LOG_ERROR("vk_create_instance failed");
        return false;
    }
    LOG_INFO("renderer_create: instance");
    if (!vk_create_surface(s, window)) {
        LOG_ERROR("vk_create_surface failed");
        return false;
    }
    LOG_INFO("renderer_create: surface");
    if (!vk_pick_physical_device(s)) {
        LOG_ERROR("vk_pick_physical_device failed");
        return false;
    }
    LOG_INFO("renderer_create: physical_device");
    if (!vk_create_device(s)) {
        LOG_ERROR("vk_create_device failed");
        return false;
    }
    LOG_INFO("renderer_create: device");

    // Initialize reference counting system
    if (!cardinal_ref_counting_init(256)) {
        LOG_ERROR("cardinal_ref_counting_init failed");
        return false;
    }
    LOG_INFO("renderer_create: ref_counting");

    // Initialize material reference counting
    if (!cardinal_material_ref_init()) {
        LOG_ERROR("cardinal_material_ref_counting_init failed");
        cardinal_ref_counting_shutdown();
        return false;
    }
    LOG_INFO("renderer_create: material_ref_counting");

    if (!vk_create_swapchain(s)) {
        LOG_ERROR("vk_create_swapchain failed");
        cardinal_material_ref_shutdown();
        cardinal_ref_counting_shutdown();
        return false;
    }
    LOG_INFO("renderer_create: swapchain");
    if (!vk_create_pipeline(s)) {
        LOG_ERROR("vk_create_pipeline failed");
        return false;
    }
    LOG_INFO("renderer_create: pipeline");
    if (!vk_create_commands_sync(s)) {
        LOG_ERROR("vk_create_commands_sync failed");
        return false;
    }
    LOG_INFO("renderer_create: commands");

    // Initialize PBR pipeline
    s->use_pbr_pipeline = false;
    if (vk_pbr_pipeline_create(&s->pbr_pipeline, s->device, s->physical_device, s->swapchain_format,
                               s->depth_format, s->command_pools[0], s->graphics_queue,
                               &s->allocator)) {
        s->use_pbr_pipeline = true;
        LOG_INFO("renderer_create: PBR pipeline");
    } else {
        LOG_ERROR("vk_pbr_pipeline_create failed");
        s->use_pbr_pipeline = false;
    }

    // Initialize rendering mode
    s->current_rendering_mode = CARDINAL_RENDERING_MODE_NORMAL;

    // Initialize additional pipeline handles to null
    s->uv_pipeline = VK_NULL_HANDLE;
    s->uv_pipeline_layout = VK_NULL_HANDLE;
    s->wireframe_pipeline = VK_NULL_HANDLE;
    s->wireframe_pipeline_layout = VK_NULL_HANDLE;
    s->simple_descriptor_layout = VK_NULL_HANDLE;
    s->simple_descriptor_pool = VK_NULL_HANDLE;
    s->simple_descriptor_set = VK_NULL_HANDLE;
    s->simple_uniform_buffer = VK_NULL_HANDLE;
    s->simple_uniform_buffer_memory = VK_NULL_HANDLE;
    s->simple_uniform_buffer_mapped = NULL;

    // Create simple pipelines (UV and wireframe)
    if (!vk_create_simple_pipelines(s)) {
        LOG_ERROR("vk_create_simple_pipelines failed");
        // Continue anyway, only PBR will work
    } else {
        LOG_INFO("renderer_create: simple pipelines");
    }

    return true;
}

/**
 * @brief Draws a single frame using the renderer.
 *
 * Handles synchronization, command recording, submission, and presentation.
 * @param renderer Pointer to the initialized CardinalRenderer.
 *
 * @todo Optimize synchronization to reduce CPU-GPU stalls.
 * @todo Add error handling for swapchain recreation on window resize.
 */
void cardinal_renderer_draw_frame(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;

    CARDINAL_LOG_INFO("[SYNC] Frame %u: Starting draw_frame", s->current_frame);

    // Calculate current frame's timeline values
    uint64_t frame_base = s->current_frame_value;
    uint64_t wait_value = frame_base > 0 ? frame_base : 0; // Wait for previous frame completion
    uint64_t signal_after_render = frame_base + 1;         // Signal after rendering

    // Wait for previous frame completion using timeline semaphore (CPU-side wait)
    if (frame_base > 0) {
        VkSemaphoreWaitInfo wait_info = {0};
        wait_info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
        wait_info.semaphoreCount = 1;
        wait_info.pSemaphores = &s->timeline_semaphore;
        wait_info.pValues = &wait_value;

        VkResult wait_result = s->vkWaitSemaphores(s->device, &wait_info, UINT64_MAX);
        CARDINAL_LOG_INFO("[SYNC] Frame %u: Timeline wait for value %llu, result: %d",
                          s->current_frame, wait_value, wait_result);
        if (wait_result == VK_ERROR_DEVICE_LOST) {
            CARDINAL_LOG_ERROR("[SYNC] Frame %u: DEVICE LOST during timeline wait! GPU crashed",
                               s->current_frame);
            return;
        }
    }

    uint32_t image_index;
    CARDINAL_LOG_INFO("[SYNC] Frame %u: Acquiring image", s->current_frame);
    VkSemaphore acquire_semaphore = s->image_acquired_semaphores[s->current_frame];
    VkResult ai = vkAcquireNextImageKHR(s->device, s->swapchain, UINT64_MAX, acquire_semaphore,
                                        VK_NULL_HANDLE, &image_index);
    CARDINAL_LOG_INFO("[SYNC] Frame %u: Acquire result: %d, image_index: %u", s->current_frame, ai,
                      image_index);

    if (ai == VK_ERROR_OUT_OF_DATE_KHR || ai == VK_SUBOPTIMAL_KHR) {
        // Swapchain is out of date (e.g., window resized), recreate it
        if (vk_recreate_swapchain(s)) {
            // Recreate per-image initialization tracking to match new swapchain image count
            vk_recreate_images_in_flight(s);
        }
        return; // Skip this frame
    } else if (ai != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SYNC] Frame %u: Failed to acquire swapchain image: %d",
                           s->current_frame, ai);
        return;
    }

    // Record command buffer
    vk_record_cmd(s, image_index);

    VkCommandBuffer cmd_buf = s->command_buffers[s->current_frame];
    CARDINAL_LOG_INFO("[SUBMIT] Frame %u: Submitting cmd %p", s->current_frame, (void*)cmd_buf);

    // Wait on the binary acquire semaphore before executing rendering commands
    VkSemaphoreSubmitInfo wait_acquire = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                                          .semaphore = acquire_semaphore,
                                          .value = 0, // ignored for binary semaphores
                                          .stageMask =
                                              VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                                          .deviceIndex = 0};

    // Signal timeline semaphore when rendering completes
    VkSemaphoreSubmitInfo signal_timeline = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                                             .semaphore = s->timeline_semaphore,
                                             .value = signal_after_render,
                                             .stageMask = VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
                                             .deviceIndex = 0};

    VkCommandBufferSubmitInfo cmd_buffer_info = {.sType =
                                                     VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
                                                 .commandBuffer = cmd_buf,
                                                 .deviceMask = 0};

    VkSubmitInfo2 submit_info2 = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
                                  .waitSemaphoreInfoCount = 1,
                                  .pWaitSemaphoreInfos = &wait_acquire,
                                  .commandBufferInfoCount = 1,
                                  .pCommandBufferInfos = &cmd_buffer_info,
                                  .signalSemaphoreInfoCount = 1,
                                  .pSignalSemaphoreInfos = &signal_timeline};

    VkResult submit_res = s->vkQueueSubmit2(s->graphics_queue, 1, &submit_info2, VK_NULL_HANDLE);
    CARDINAL_LOG_INFO("[SUBMIT] Frame %u: Submit result: %d", s->current_frame, submit_res);
    if (submit_res == VK_ERROR_DEVICE_LOST) {
        CARDINAL_LOG_ERROR("[SUBMIT] Frame %u: DEVICE LOST during submit!", s->current_frame);
        return;
    }

    // Wait for rendering completion before present using timeline semaphore (CPU-side wait)
    VkSemaphoreWaitInfo render_wait = {0};
    render_wait.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
    render_wait.semaphoreCount = 1;
    render_wait.pSemaphores = &s->timeline_semaphore;
    render_wait.pValues = &signal_after_render;

    s->vkWaitSemaphores(s->device, &render_wait, UINT64_MAX);

    VkPresentInfoKHR present_info = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    present_info.waitSemaphoreCount = 0; // No binary semaphores needed; CPU guarantees completion
    present_info.pWaitSemaphores = NULL;
    present_info.swapchainCount = 1;
    present_info.pSwapchains = &s->swapchain;
    present_info.pImageIndices = &image_index;

    CARDINAL_LOG_INFO("[PRESENT] Frame %u: Presenting image %u", s->current_frame, image_index);
    VkResult present_res = vkQueuePresentKHR(s->present_queue, &present_info);
    CARDINAL_LOG_INFO("[PRESENT] Frame %u: Present result: %d", s->current_frame, present_res);
    (void)present_res; // Suppress unused variable warning

    // Update timeline values for next frame
    s->current_frame_value = signal_after_render;
    s->current_frame = (s->current_frame + 1) % s->max_frames_in_flight;
}

/**
 * @brief Waits for the device to become idle.
 * @param renderer Pointer to the CardinalRenderer.
 */
void cardinal_renderer_wait_idle(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    vkDeviceWaitIdle(s->device);
}

/**
 * @brief Destroys GPU buffers for the current scene.
 * @param s Pointer to the VulkanState structure.
 *
 * @todo Add reference counting for shared buffers.
 */
static void destroy_scene_buffers(VulkanState* s) {
    if (!s || !s->scene_meshes)
        return;
    for (uint32_t i = 0; i < s->scene_mesh_count; i++) {
        GpuMesh* m = &s->scene_meshes[i];
        if (m->vbuf != VK_NULL_HANDLE || m->vmem != VK_NULL_HANDLE) {
            vk_allocator_free_buffer(&s->allocator, m->vbuf, m->vmem);
            m->vbuf = VK_NULL_HANDLE;
            m->vmem = VK_NULL_HANDLE;
        }
        if (m->ibuf != VK_NULL_HANDLE || m->imem != VK_NULL_HANDLE) {
            vk_allocator_free_buffer(&s->allocator, m->ibuf, m->imem);
            m->ibuf = VK_NULL_HANDLE;
            m->imem = VK_NULL_HANDLE;
        }
    }
    free(s->scene_meshes);
    s->scene_meshes = NULL;
    s->scene_mesh_count = 0;
}

/**
 * @brief Destroys the renderer and frees resources.
 * @param renderer Pointer to the CardinalRenderer to destroy.
 *
 * @todo Ensure all resources are properly cleaned up to prevent leaks.
 */
void cardinal_renderer_destroy(CardinalRenderer* renderer) {
    if (!renderer || !renderer->_opaque)
        return;
    VulkanState* s = (VulkanState*)renderer->_opaque;

    // destroy in reverse order
    vk_destroy_commands_sync(s);
    destroy_scene_buffers(s);

    // Shutdown reference counting systems
    cardinal_material_ref_shutdown();
    cardinal_ref_counting_shutdown();

    // Destroy simple pipelines
    vk_destroy_simple_pipelines(s);

    // Destroy PBR pipeline
    if (s->use_pbr_pipeline) {
        vk_pbr_pipeline_destroy(&s->pbr_pipeline, s->device, &s->allocator);
    }

    vk_destroy_pipeline(s);
    vk_destroy_swapchain(s);
    vk_destroy_device_objects(s);

    free(s);
    renderer->_opaque = NULL;
}

VkCommandBuffer cardinal_renderer_internal_current_cmd(CardinalRenderer* renderer,
                                                       uint32_t image_index) {
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
/**
 * @brief Creates a perspective projection matrix.
 * @param fov Field of view in degrees.
 * @param aspect Aspect ratio.
 * @param near_plane Near clipping plane.
 * @param far_plane Far clipping plane.
 * @param matrix Output 4x4 matrix (16 floats).
 *
 * @todo Support orthographic projection as an alternative.
 */
static void create_perspective_matrix(float fov, float aspect, float near_plane, float far_plane,
                                      float* matrix) {
    memset(matrix, 0, 16 * sizeof(float));

    float tan_half_fov = tanf(fov * 0.5f * M_PI / 180.0f);

    matrix[0] = 1.0f / (aspect * tan_half_fov); // [0][0]
    matrix[5] = -1.0f / tan_half_fov;           // [1][1] - Vulkan Y-flip (negative Y)
    matrix[10] = -(far_plane + near_plane) / (far_plane - near_plane);        // [2][2]
    matrix[11] = -1.0f;                                                       // [2][3]
    matrix[14] = -(2.0f * far_plane * near_plane) / (far_plane - near_plane); // [3][2]
}

// Helper function to create view matrix (look-at)
/**
 * @brief Creates a view matrix (look-at).
 * @param eye Camera position.
 * @param center Target position.
 * @param up Up vector.
 * @param matrix Output 4x4 matrix (16 floats).
 *
 * @todo Add error checking for degenerate cases (e.g., eye == center).
 */
static void create_view_matrix(const float* eye, const float* center, const float* up,
                               float* matrix) {
    float f[3] = {center[0] - eye[0], center[1] - eye[1], center[2] - eye[2]};
    float f_len = sqrtf(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
    f[0] /= f_len;
    f[1] /= f_len;
    f[2] /= f_len;

    float s[3] = {f[1] * up[2] - f[2] * up[1], f[2] * up[0] - f[0] * up[2],
                  f[0] * up[1] - f[1] * up[0]};
    float s_len = sqrtf(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
    s[0] /= s_len;
    s[1] /= s_len;
    s[2] /= s_len;

    float u[3] = {s[1] * f[2] - s[2] * f[1], s[2] * f[0] - s[0] * f[2], s[0] * f[1] - s[1] * f[0]};

    memset(matrix, 0, 16 * sizeof(float));
    matrix[0] = s[0];
    matrix[4] = s[1];
    matrix[8] = s[2];
    matrix[12] = -(s[0] * eye[0] + s[1] * eye[1] + s[2] * eye[2]);
    matrix[1] = u[0];
    matrix[5] = u[1];
    matrix[9] = u[2];
    matrix[13] = -(u[0] * eye[0] + u[1] * eye[1] + u[2] * eye[2]);
    matrix[2] = -f[0];
    matrix[6] = -f[1];
    matrix[10] = -f[2];
    matrix[14] = f[0] * eye[0] + f[1] * eye[1] + f[2] * eye[2];
    matrix[15] = 1.0f;
}

// Helper function to create identity matrix
/**
 * @brief Creates an identity matrix.
 * @param matrix Output 4x4 matrix (16 floats).
 */
static void create_identity_matrix(float* matrix) {
    memset(matrix, 0, 16 * sizeof(float));
    matrix[0] = matrix[5] = matrix[10] = matrix[15] = 1.0f;
}

/**
 * @brief Sets the camera parameters for rendering.
 * @param renderer Pointer to the CardinalRenderer.
 * @param camera Pointer to the camera data.
 *
 * @todo Support multiple cameras or viewports.
 */
void cardinal_renderer_set_camera(CardinalRenderer* renderer, const CardinalCamera* camera) {
    if (!renderer || !camera)
        return;
    VulkanState* s = (VulkanState*)renderer->_opaque;

    if (!s->use_pbr_pipeline)
        return;

    PBRUniformBufferObject ubo = {0};

    // Create model matrix (identity for now)
    create_identity_matrix(ubo.model);

    // Create view matrix
    create_view_matrix(camera->position, camera->target, camera->up, ubo.view);

    // Create projection matrix
    create_perspective_matrix(camera->fov, camera->aspect, camera->near_plane, camera->far_plane,
                              ubo.proj);

    // Set view position
    ubo.viewPos[0] = camera->position[0];
    ubo.viewPos[1] = camera->position[1];
    ubo.viewPos[2] = camera->position[2];

    // Update the uniform buffer
    memcpy(s->pbr_pipeline.uniformBufferMapped, &ubo, sizeof(PBRUniformBufferObject));

    // Also invoke the centralized PBR uniform updater to keep both UBO and lighting in sync
    PBRLightingData lighting;
    memcpy(&lighting, s->pbr_pipeline.lightingBufferMapped, sizeof(PBRLightingData));
    vk_pbr_update_uniforms(&s->pbr_pipeline, &ubo, &lighting);
}

/**
 * @brief Sets the lighting parameters for PBR rendering.
 * @param renderer Pointer to the CardinalRenderer.
 * @param light Pointer to the light data.
 *
 * @todo Support multiple light sources.
 */
void cardinal_renderer_set_lighting(CardinalRenderer* renderer, const CardinalLight* light) {
    if (!renderer || !light)
        return;
    VulkanState* s = (VulkanState*)renderer->_opaque;

    if (!s->use_pbr_pipeline)
        return;

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

    // Also invoke the centralized PBR uniform updater to keep both UBO and lighting in sync
    PBRUniformBufferObject ubo;
    memcpy(&ubo, s->pbr_pipeline.uniformBufferMapped, sizeof(PBRUniformBufferObject));
    vk_pbr_update_uniforms(&s->pbr_pipeline, &ubo, &lighting);
}

/**
 * @brief Enables or disables PBR rendering pipeline.
 * @param renderer Pointer to the CardinalRenderer.
 * @param enable True to enable PBR, false to disable.
 *
 * @todo Add smooth transition between pipelines.
 */
void cardinal_renderer_enable_pbr(CardinalRenderer* renderer, bool enable) {
    if (!renderer)
        return;
    VulkanState* s = (VulkanState*)renderer->_opaque;

    if (enable && !s->use_pbr_pipeline) {
        // Wait for all GPU operations to complete before creating new resources
        vkDeviceWaitIdle(s->device);

        // Destroy existing PBR pipeline if it exists (in case of re-enabling)
        if (s->pbr_pipeline.initialized) {
            vk_pbr_pipeline_destroy(&s->pbr_pipeline, s->device, &s->allocator);
        }

        // Try to create PBR pipeline
        if (vk_pbr_pipeline_create(&s->pbr_pipeline, s->device, s->physical_device,
                                   s->swapchain_format, s->depth_format, s->command_pools[0],
                                   s->graphics_queue, &s->allocator)) {
            s->use_pbr_pipeline = true;

            // Load current scene if one exists
            if (s->current_scene) {
                vk_pbr_load_scene(&s->pbr_pipeline, s->device, s->physical_device,
                                  s->command_pools[0], s->graphics_queue, s->current_scene,
                                  &s->allocator);
            }

            CARDINAL_LOG_INFO("PBR pipeline enabled");
        } else {
            CARDINAL_LOG_ERROR("Failed to enable PBR pipeline");
        }
    } else if (!enable && s->use_pbr_pipeline) {
        // Wait for all GPU operations to complete before destroying resources
        vkDeviceWaitIdle(s->device);

        // Destroy PBR pipeline
        vk_pbr_pipeline_destroy(&s->pbr_pipeline, s->device, &s->allocator);
        s->use_pbr_pipeline = false;
        CARDINAL_LOG_INFO("PBR pipeline disabled");
    }
}

bool cardinal_renderer_is_pbr_enabled(CardinalRenderer* renderer) {
    if (!renderer)
        return false;
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

VkFormat cardinal_renderer_internal_swapchain_format(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->swapchain_format;
}

VkFormat cardinal_renderer_internal_depth_format(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->depth_format;
}

VkExtent2D cardinal_renderer_internal_swapchain_extent(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->swapchain_extent;
}

void cardinal_renderer_set_ui_callback(CardinalRenderer* renderer,
                                       void (*callback)(VkCommandBuffer cmd)) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    s->ui_record_callback = callback;
}

/**
 * @brief Submits an immediate command buffer for execution.
 * @param renderer Pointer to the CardinalRenderer.
 * @param record Callback to record commands.
 *
 * @todo Add support for secondary command buffers.
 */
void cardinal_renderer_immediate_submit(CardinalRenderer* renderer,
                                        void (*record)(VkCommandBuffer cmd)) {
    VulkanState* s = (VulkanState*)renderer->_opaque;

    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    ai.commandPool = s->command_pools[s->current_frame];
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;

    VkCommandBuffer cmd;
    vkAllocateCommandBuffers(s->device, &ai, &cmd);

    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &bi);

    if (record)
        record(cmd);

    vkEndCommandBuffer(cmd);

    VkCommandBufferSubmitInfo cmd_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
                                          .commandBuffer = cmd,
                                          .deviceMask = 0};
    VkSubmitInfo2 submit2 = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
                             .commandBufferInfoCount = 1,
                             .pCommandBufferInfos = &cmd_info};
    s->vkQueueSubmit2(s->graphics_queue, 1, &submit2, VK_NULL_HANDLE);
    vkQueueWaitIdle(s->graphics_queue);

    vkFreeCommandBuffers(s->device, s->command_pools[s->current_frame], 1, &cmd);
}

/**
 * @brief Uploads scene data to GPU buffers.
 * @param renderer Pointer to the CardinalRenderer.
 * @param scene Pointer to the scene data.
 *
 * @todo Optimize buffer uploads using staging buffers and transfers.
 * @todo Support scene updates without full re-upload.
 */
void cardinal_renderer_upload_scene(CardinalRenderer* renderer, const CardinalScene* scene) {
    VulkanState* s = (VulkanState*)renderer->_opaque;

    // Wait for all GPU operations to complete before modifying scene buffers
    vkDeviceWaitIdle(s->device);

    destroy_scene_buffers(s);
    if (!scene || scene->mesh_count == 0)
        return;

    s->scene_mesh_count = scene->mesh_count;
    s->scene_meshes = (GpuMesh*)calloc(s->scene_mesh_count, sizeof(GpuMesh));
    if (!s->scene_meshes) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for scene meshes");
        return;
    }

    CARDINAL_LOG_INFO("Uploading scene with %u meshes using optimized staging buffers",
                      scene->mesh_count);

    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* src = &scene->meshes[i];
        GpuMesh* dst = &s->scene_meshes[i];

        // Initialize to null handles
        dst->vbuf = VK_NULL_HANDLE;
        dst->vmem = VK_NULL_HANDLE;
        dst->ibuf = VK_NULL_HANDLE;
        dst->imem = VK_NULL_HANDLE;
        dst->vtx_count = 0;
        dst->idx_count = 0;

        dst->vtx_stride = sizeof(CardinalVertex);
        VkDeviceSize vsize = (VkDeviceSize)src->vertex_count * dst->vtx_stride;
        VkDeviceSize isize = (VkDeviceSize)src->index_count * sizeof(uint32_t);

        if (!src->vertices || src->vertex_count == 0) {
            CARDINAL_LOG_ERROR("Mesh %u has no vertices", i);
            continue;
        }

        // Create vertex buffer using staging buffer for optimal GPU performance
        if (!vk_buffer_create_with_staging(
                &s->allocator, s->device, s->command_pools[0], s->graphics_queue, src->vertices,
                vsize, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &dst->vbuf, &dst->vmem)) {
            CARDINAL_LOG_ERROR("Failed to create vertex buffer for mesh %u", i);
            continue;
        }

        if (src->index_count > 0 && src->indices) {
            // Create index buffer using staging buffer for optimal GPU performance
            if (!vk_buffer_create_with_staging(
                    &s->allocator, s->device, s->command_pools[0], s->graphics_queue, src->indices,
                    isize, VK_BUFFER_USAGE_INDEX_BUFFER_BIT, &dst->ibuf, &dst->imem)) {
                CARDINAL_LOG_ERROR("Failed to create index buffer for mesh %u", i);
            } else {
                dst->idx_count = src->index_count;
            }
        }
        dst->vtx_count = src->vertex_count;

        CARDINAL_LOG_INFO("Successfully uploaded mesh %u: %u vertices, %u indices", i,
                          src->vertex_count, src->index_count);
    }

    // Load scene into PBR pipeline if enabled
    if (s->use_pbr_pipeline) {
        vk_pbr_load_scene(&s->pbr_pipeline, s->device, s->physical_device, s->command_pools[0],
                          s->graphics_queue, scene, &s->allocator);
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

void cardinal_renderer_set_rendering_mode(CardinalRenderer* renderer, CardinalRenderingMode mode) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    if (!s) {
        CARDINAL_LOG_ERROR("Invalid renderer state");
        return;
    }

    s->current_rendering_mode = mode;
    CARDINAL_LOG_INFO("Rendering mode changed to: %d", mode);
}

CardinalRenderingMode cardinal_renderer_get_rendering_mode(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    if (!s) {
        CARDINAL_LOG_ERROR("Invalid renderer state");
        return CARDINAL_RENDERING_MODE_NORMAL;
    }

    return s->current_rendering_mode;
}
