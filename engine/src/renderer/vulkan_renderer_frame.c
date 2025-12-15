/**
 * @file vulkan_renderer_frame.c
 * @brief Frame rendering and synchronization logic
 *
 * This file contains the frame drawing loop and device loss recovery logic.
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
#include "cardinal/core/transform.h"
#include "cardinal/core/window.h"
#include "cardinal/renderer/renderer.h"
#include "cardinal/renderer/renderer_internal.h"
#include <cardinal/renderer/vulkan_swapchain.h>

#include "cardinal/assets/material_ref_counting.h"
#include "cardinal/core/ref_counting.h"
#include "cardinal/renderer/vulkan_barrier_validation.h"
#include "cardinal/renderer/vulkan_commands.h"
#include "cardinal/renderer/vulkan_mesh_shader.h"
#include "cardinal/renderer/vulkan_mt.h"
#include "cardinal/renderer/vulkan_pbr.h"
#include "cardinal/renderer/vulkan_sync_manager.h"
#include "vulkan_buffer_manager.h"
#include "vulkan_simple_pipelines.h"
#include "vulkan_state.h"
#include <cardinal/renderer/util/vulkan_buffer_utils.h>
#include <cardinal/renderer/vulkan_commands.h>
#include <cardinal/renderer/vulkan_instance.h>
#include <cardinal/renderer/vulkan_pipeline.h>

// Forward declarations
static bool vk_recover_from_device_loss(VulkanState* s);

static uint64_t cardinal_now_ms(void) {
    return (uint64_t)(glfwGetTime() * 1000.0);
}

/**
 * @brief Attempts to recover from device loss by recreating all Vulkan resources.
 * @param s Pointer to the VulkanState structure.
 * @param window Pointer to the CardinalWindow for surface recreation.
 * @return true if recovery succeeds, false otherwise.
 */
static bool vk_recover_from_device_loss(VulkanState* s) {
    if (!s || s->recovery.recovery_in_progress) {
        return false;
    }

    // Check if we've exceeded maximum recovery attempts
    if (s->recovery.attempt_count >= s->recovery.max_attempts) {
        CARDINAL_LOG_ERROR("[RECOVERY] Maximum device loss recovery attempts (%u) exceeded",
                           s->recovery.max_attempts);
        s->recovery.recovery_in_progress = false;
        if (s->recovery.recovery_complete_callback) {
            s->recovery.recovery_complete_callback(s->recovery.callback_user_data, false);
        }
        return false;
    }

    s->recovery.recovery_in_progress = true;
    s->recovery.attempt_count++;

    CARDINAL_LOG_WARN("[RECOVERY] Attempting device loss recovery (attempt %u/%u)",
                      s->recovery.attempt_count, s->recovery.max_attempts);

    // Notify application of device loss
    if (s->recovery.device_loss_callback) {
        s->recovery.device_loss_callback(s->recovery.callback_user_data);
    }

    // Validate device state before attempting recovery
    VkResult device_status = VK_SUCCESS;
    if (s->context.device) {
        device_status = vkDeviceWaitIdle(s->context.device);
        if (device_status == VK_ERROR_DEVICE_LOST) {
            CARDINAL_LOG_WARN("[RECOVERY] Device confirmed lost, proceeding with recovery");
        } else if (device_status != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[RECOVERY] Unexpected device error during recovery validation: %d",
                               device_status);
            s->recovery.recovery_in_progress = false;
            return false;
        }
    }

    // Store original state for potential rollback
    bool had_valid_swapchain = (s->swapchain.handle != VK_NULL_HANDLE);
    const CardinalScene* stored_scene = s->current_scene;

    // Step 1: Destroy all device-dependent resources in reverse order
    // Destroy scene buffers first (they might rely on sync objects)
    destroy_scene_buffers(s);

    // Destroy command buffers and synchronization objects
    vk_destroy_commands_sync(s);

    // Destroy pipelines
    if (s->pipelines.use_pbr_pipeline) {
        vk_pbr_pipeline_destroy(&s->pipelines.pbr_pipeline, s->context.device, &s->allocator);
        s->pipelines.use_pbr_pipeline = false;
    }
    if (s->pipelines.use_mesh_shader_pipeline) {
        // Wait for all GPU operations to complete before destroying mesh shader pipeline
        vkDeviceWaitIdle(s->context.device);
        vk_mesh_shader_destroy_pipeline(s, &s->pipelines.mesh_shader_pipeline);
        s->pipelines.use_mesh_shader_pipeline = false;
    }
    vk_destroy_simple_pipelines(s);
    vk_destroy_pipeline(s);

    // Destroy swapchain
    vk_destroy_swapchain(s);

    // Step 2: Recreate all resources with validation at each step
    bool success = true;
    const char* failure_point = NULL;

    // Recreate device (this also recreates the logical device)
    if (!vk_create_device(s)) {
        failure_point = "device";
        success = false;
    }

    // Recreate swapchain
    if (success && !vk_create_swapchain(s)) {
        failure_point = "swapchain";
        success = false;
    }

    // Recreate pipeline
    if (success && !vk_create_pipeline(s)) {
        failure_point = "pipeline";
        success = false;
    }

    // Recreate simple pipelines
    if (success && !vk_create_simple_pipelines(s)) {
        failure_point = "simple pipelines";
        success = false;
    }

    // Recreate PBR pipeline if it was enabled
    if (success && stored_scene) {
        if (!vk_pbr_pipeline_create(&s->pipelines.pbr_pipeline, s->context.device,
                                    s->context.physical_device, s->swapchain.format,
                                    s->swapchain.depth_format, s->commands.pools[0],
                                    s->context.graphics_queue, &s->allocator, s)) {
            failure_point = "PBR pipeline";
            success = false;
        } else {
            s->pipelines.use_pbr_pipeline = true;

            // Reload scene into PBR pipeline
            if (!vk_pbr_load_scene(&s->pipelines.pbr_pipeline, s->context.device,
                                   s->context.physical_device, s->commands.pools[0],
                                   s->context.graphics_queue, stored_scene, &s->allocator, s)) {
                failure_point = "PBR scene reload";
                success = false;
            }
        }
    }

    // Recreate mesh shader pipeline if it was enabled and supported
    if (success && s->context.supports_mesh_shader) {
        // Create default mesh shader pipeline configuration
        MeshShaderPipelineConfig config = {0};
        const char* shaders_dir = getenv("CARDINAL_SHADERS_DIR");
        if (!shaders_dir || !shaders_dir[0])
            shaders_dir = "assets/shaders";
        char mesh_path[512], task_path[512], frag_path[512];
        snprintf(mesh_path, sizeof(mesh_path), "%s/%s", shaders_dir, "mesh.mesh.spv");
        snprintf(task_path, sizeof(task_path), "%s/%s", shaders_dir, "task.task.spv");
        snprintf(frag_path, sizeof(frag_path), "%s/%s", shaders_dir, "mesh.frag.spv");
        config.mesh_shader_path = mesh_path;
        config.task_shader_path = task_path;
        config.fragment_shader_path = frag_path;
        config.max_vertices_per_meshlet = 64;
        config.max_primitives_per_meshlet = 126;
        config.cull_mode = VK_CULL_MODE_BACK_BIT;
        config.front_face = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        config.polygon_mode = VK_POLYGON_MODE_FILL;
        config.blend_enable = false;
        config.depth_test_enable = true;
        config.depth_write_enable = true;
        config.depth_compare_op = VK_COMPARE_OP_LESS;

        if (!vk_mesh_shader_create_pipeline(s, &config, s->swapchain.format,
                                            s->swapchain.depth_format,
                                            &s->pipelines.mesh_shader_pipeline)) {
            failure_point = "mesh shader pipeline";
            success = false;
        } else {
            s->pipelines.use_mesh_shader_pipeline = true;
        }
    }

    // Recreate command buffers and synchronization
    if (success && !vk_create_commands_sync(s)) {
        failure_point = "commands and synchronization";
        success = false;
    }

    // Recreate scene buffers if scene exists
    if (success && stored_scene) {
        // Note: create_scene_buffers function doesn't exist in the original code
        // This would need to be implemented or replaced with appropriate scene buffer recreation
        s->current_scene = stored_scene;
    }

    if (success) {
        CARDINAL_LOG_INFO("[RECOVERY] Device loss recovery completed successfully");
        s->recovery.device_lost = false;
        s->recovery.attempt_count = 0; // Reset on successful recovery
    } else {
        CARDINAL_LOG_ERROR("[RECOVERY] Device loss recovery failed at: %s",
                           failure_point ? failure_point : "unknown");

        // Implement fallback: try to at least maintain a minimal valid state
        if (!had_valid_swapchain) {
            CARDINAL_LOG_WARN("[RECOVERY] Attempting minimal fallback recovery");
            // Try to recreate just the essential components for a graceful shutdown
            // At minimum, ensure we have basic Vulkan state to prevent crashes
            if (s->context.device && vk_create_swapchain(s)) {
                vk_create_pipeline(s);
                vk_create_commands_sync(s);
                CARDINAL_LOG_INFO("[RECOVERY] Minimal fallback recovery succeeded");
            }
        }
    }

    s->recovery.recovery_in_progress = false;

    // Notify application of recovery completion
    if (s->recovery.recovery_complete_callback) {
        s->recovery.recovery_complete_callback(s->recovery.callback_user_data, success);
    }

    return success;
}

/**
 * @brief Checks if rendering is feasible (window not minimized, extent valid).
 */
static bool check_render_feasibility(VulkanState* s) {
    if (s->recovery.window && cardinal_window_is_minimized(s->recovery.window)) {
        CARDINAL_LOG_DEBUG("[SWAPCHAIN] Frame %u: Window minimized, skipping frame",
                           s->sync.current_frame);
        return false;
    }
    if (s->swapchain.extent.width == 0 || s->swapchain.extent.height == 0) {
        CARDINAL_LOG_WARN("[SWAPCHAIN] Frame %u: Zero swapchain extent, skipping frame",
                          s->sync.current_frame);
        s->swapchain.recreation_pending = true;
        return false;
    }
    return true;
}

/**
 * @brief Handles pending swapchain recreation.
 */
static bool handle_pending_recreation(CardinalRenderer* renderer, VulkanState* s) {
    if (s->swapchain.window_resize_pending) {
        CARDINAL_LOG_INFO("[SWAPCHAIN] Frame %u: Window resize pending", s->sync.current_frame);
        s->swapchain.recreation_pending = true;
    }

    if (!s->swapchain.recreation_pending)
        return true;

    CARDINAL_LOG_INFO("[SWAPCHAIN] Frame %u: Handling pending swapchain recreation",
                      s->sync.current_frame);
    if (vk_recreate_swapchain(s)) {
        if (!vk_recreate_images_in_flight(s)) {
            CARDINAL_LOG_ERROR("[SWAPCHAIN] Frame %u: Failed to recreate image tracking",
                               s->sync.current_frame);
            return false;
        }
        s->swapchain.recreation_pending = false;
        s->swapchain.window_resize_pending = false;
        CARDINAL_LOG_INFO("[SWAPCHAIN] Frame %u: Recreation successful", s->sync.current_frame);

        if (s->scene_upload_pending && s->pending_scene_upload) {
            CARDINAL_LOG_INFO("[UPLOAD] Performing deferred scene upload");
            cardinal_renderer_upload_scene(renderer, s->pending_scene_upload);
            s->scene_upload_pending = false;
            s->pending_scene_upload = NULL;
        }
        return true;
    }

    if (s->swapchain.consecutive_recreation_failures >= 6) {
        s->swapchain.recreation_pending = false;
        CARDINAL_LOG_WARN("[SWAPCHAIN] Clearing pending recreation after failures");
    }

    if (s->recovery.device_lost && s->recovery.attempt_count < s->recovery.max_attempts) {
        vk_recover_from_device_loss(s);
    }
    return false;
}

/**
 * @brief Waits for the current frame's fence.
 */
static bool wait_for_fence(VulkanState* s) {
    VkFence current_fence = s->sync.in_flight_fences[s->sync.current_frame];
    VkResult fence_status = vkGetFenceStatus(s->context.device, current_fence);

    if (fence_status == VK_SUCCESS) {
        CARDINAL_LOG_DEBUG("[SYNC] Frame %u: GPU ahead, skipping wait", s->sync.current_frame);
    } else if (fence_status == VK_NOT_READY) {
        VkResult wait_res =
            vkWaitForFences(s->context.device, 1, &current_fence, VK_TRUE, UINT64_MAX);
        if (wait_res != VK_SUCCESS) {
            if (wait_res == VK_ERROR_DEVICE_LOST) {
                s->recovery.device_lost = true;
                if (s->recovery.attempt_count < s->recovery.max_attempts)
                    vk_recover_from_device_loss(s);
            } else {
                CARDINAL_LOG_ERROR("[SYNC] Frame %u: Fence wait failed: %d", s->sync.current_frame,
                                   wait_res);
            }
            return false;
        }
    } else {
        if (fence_status == VK_ERROR_DEVICE_LOST) {
            s->recovery.device_lost = true;
            if (s->recovery.attempt_count < s->recovery.max_attempts)
                vk_recover_from_device_loss(s);
        } else {
            CARDINAL_LOG_ERROR("[SYNC] Frame %u: Fence status check failed: %d",
                               s->sync.current_frame, fence_status);
        }
        return false;
    }

    vkResetFences(s->context.device, 1, &current_fence);
    return true;
}

/**
 * @brief Handles headless rendering path.
 */
static void render_frame_headless(VulkanState* s, uint64_t signal_value) {
    if (!s->commands.buffers)
        return;
    VkCommandBuffer cmd = s->commands.buffers[s->sync.current_frame];

    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                   .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    vkBeginCommandBuffer(cmd, &bi);
    vkEndCommandBuffer(cmd);

    VkSemaphoreSubmitInfo signal_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                                         .semaphore = s->sync_manager
                                                          ? s->sync_manager->timeline_semaphore
                                                          : s->sync.timeline_semaphore,
                                         .value = signal_value,
                                         .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT};

    VkCommandBufferSubmitInfo cb_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
                                         .commandBuffer = cmd};
    VkSubmitInfo2 si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
                        .commandBufferInfoCount = 1,
                        .pCommandBufferInfos = &cb_info,
                        .signalSemaphoreInfoCount = 1,
                        .pSignalSemaphoreInfos = &signal_info};

    VkFence fence = s->sync.in_flight_fences[s->sync.current_frame];
    VkResult res = s->context.vkQueueSubmit2
                       ? s->context.vkQueueSubmit2(s->context.graphics_queue, 1, &si, fence)
                       : vkQueueSubmit2(s->context.graphics_queue, 1, &si, fence);

    if (res == VK_SUCCESS) {
        vkWaitForFences(s->context.device, 1, &fence, VK_TRUE, UINT64_MAX);
        s->sync.current_frame_value = signal_value;
        s->sync.current_frame = (s->sync.current_frame + 1) % s->sync.max_frames_in_flight;
        s->commands.current_buffer_index = 1 - s->commands.current_buffer_index;
    }
}

/**
 * @brief Acquires the next swapchain image.
 */
static bool acquire_next_image(VulkanState* s, uint32_t* out_image_index) {
    if (s->swapchain.handle == VK_NULL_HANDLE || !s->swapchain.image_views ||
        s->swapchain.image_count == 0) {
        if (!vk_recreate_swapchain(s) || !vk_recreate_images_in_flight(s)) {
            return false;
        }
    }

    VkSemaphore sem = s->sync.image_acquired_semaphores[s->sync.current_frame];
    VkResult res = vkAcquireNextImageKHR(s->context.device, s->swapchain.handle, UINT64_MAX, sem,
                                         VK_NULL_HANDLE, out_image_index);

    if (res == VK_ERROR_OUT_OF_DATE_KHR || res == VK_SUBOPTIMAL_KHR) {
        vk_recreate_swapchain(s);
        vk_recreate_images_in_flight(s);
        return false;
    } else if (res == VK_ERROR_DEVICE_LOST) {
        s->recovery.device_lost = true;
        if (s->recovery.attempt_count < s->recovery.max_attempts)
            vk_recover_from_device_loss(s);
        return false;
    } else if (res != VK_SUCCESS) {
        return false;
    }
    return true;
}

/**
 * @brief Submits the command buffer to the graphics queue.
 */
static bool submit_command_buffer(VulkanState* s, VkCommandBuffer cmd, VkSemaphore acquire_sem,
                                  uint64_t signal_value) {
    VkSemaphoreSubmitInfo wait_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                                       .semaphore = acquire_sem,
                                       .stageMask =
                                           VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT};

    VkSemaphoreSubmitInfo signal_infos[2] = {
        {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
         .semaphore = s->sync.render_finished_semaphores[s->sync.current_frame],
         .stageMask = VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT},
        {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
         .semaphore = s->sync.timeline_semaphore,
         .value = signal_value,
         .stageMask = VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT}
    };

    VkCommandBufferSubmitInfo cmd_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
                                          .commandBuffer = cmd};

    VkSubmitInfo2 submit_info = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
                                 .waitSemaphoreInfoCount = 1,
                                 .pWaitSemaphoreInfos = &wait_info,
                                 .commandBufferInfoCount = 1,
                                 .pCommandBufferInfos = &cmd_info,
                                 .signalSemaphoreInfoCount = 2,
                                 .pSignalSemaphoreInfos = signal_infos};

    VkResult res = s->context.vkQueueSubmit2(s->context.graphics_queue, 1, &submit_info,
                                             s->sync.in_flight_fences[s->sync.current_frame]);

    if (res == VK_ERROR_DEVICE_LOST) {
        s->recovery.device_lost = true;
        if (s->recovery.attempt_count < s->recovery.max_attempts)
            vk_recover_from_device_loss(s);
        return false;
    } else if (res != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Queue submit failed: %d", res);
        return false;
    }
    return true;
}

/**
 * @brief Presents the image to the presentation queue.
 */
static void present_swapchain_image(VulkanState* s, uint32_t image_index, uint64_t signal_value) {
    if (s->swapchain.skip_present) {
        vkQueueWaitIdle(s->context.graphics_queue);
        s->swapchain.recreation_pending = true;
        s->sync.current_frame_value = signal_value;
        s->sync.current_frame = (s->sync.current_frame + 1) % s->sync.max_frames_in_flight;
        s->commands.current_buffer_index = 1 - s->commands.current_buffer_index;
        return;
    }

    VkSemaphore wait_sem = s->sync.render_finished_semaphores[s->sync.current_frame];
    VkPresentInfoKHR present_info = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
                                     .waitSemaphoreCount = 1,
                                     .pWaitSemaphores = &wait_sem,
                                     .swapchainCount = 1,
                                     .pSwapchains = &s->swapchain.handle,
                                     .pImageIndices = &image_index};

    VkResult res = vkQueuePresentKHR(s->context.present_queue, &present_info);

    if (res == VK_ERROR_OUT_OF_DATE_KHR || res == VK_SUBOPTIMAL_KHR) {
        s->swapchain.recreation_pending = true;
    } else if (res == VK_ERROR_DEVICE_LOST || res == VK_ERROR_SURFACE_LOST_KHR) {
        s->recovery.device_lost = true;
        if (s->recovery.attempt_count < s->recovery.max_attempts)
            vk_recover_from_device_loss(s);
        return;
    } else if (res != VK_SUCCESS) {
        if (res == VK_ERROR_OUT_OF_HOST_MEMORY || res == VK_ERROR_OUT_OF_DEVICE_MEMORY) {
            s->recovery.device_lost = true;
            if (s->recovery.attempt_count < s->recovery.max_attempts)
                vk_recover_from_device_loss(s);
        }
        return;
    }

    s->sync.current_frame_value = signal_value;
    s->sync.current_frame = (s->sync.current_frame + 1) % s->sync.max_frames_in_flight;
    s->commands.current_buffer_index = 1 - s->commands.current_buffer_index;
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

    if (!check_render_feasibility(s))
        return;
    if (!handle_pending_recreation(renderer, s))
        return;

    CARDINAL_LOG_INFO("[SYNC] Frame %u: Starting draw_frame", s->sync.current_frame);

    if (!wait_for_fence(s))
        return;

    // Prepare mesh shader rendering
    if (s->current_rendering_mode == CARDINAL_RENDERING_MODE_MESH_SHADER) {
        vk_prepare_mesh_shader_rendering(s);
    }

    uint64_t frame_base = s->sync.current_frame_value;
    uint64_t signal_after_render =
        s->sync_manager ? vulkan_sync_manager_get_next_timeline_value(s->sync_manager)
                        : (frame_base + 1);

    if (s->swapchain.headless_mode) {
        render_frame_headless(s, signal_after_render);
        return;
    }

    uint32_t image_index;
    if (!acquire_next_image(s, &image_index))
        return;

    vk_record_cmd(s, image_index);

    VkCommandBuffer cmd_buf = (s->commands.current_buffer_index == 0)
                                  ? s->commands.buffers[s->sync.current_frame]
                                  : s->commands.secondary_buffers[s->sync.current_frame];

    if (!cmd_buf)
        return;

    if (!submit_command_buffer(s, cmd_buf, s->sync.image_acquired_semaphores[s->sync.current_frame],
                               signal_after_render))
        return;

    vk_mesh_shader_process_pending_cleanup(s);

    present_swapchain_image(s, image_index, signal_after_render);
}
