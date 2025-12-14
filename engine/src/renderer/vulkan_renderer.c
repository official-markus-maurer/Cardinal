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
static void vk_handle_window_resize(uint32_t width, uint32_t height, void* user_data) {
    VulkanState* s = (VulkanState*)user_data;
    if (!s)
        return;
    s->swapchain.window_resize_pending = true;
    s->swapchain.pending_width = width;
    s->swapchain.pending_height = height;
    s->swapchain.recreation_pending = true;
    CARDINAL_LOG_INFO("[SWAPCHAIN] Resize event: %ux%u, marking recreation pending", width, height);
}

/**
 * @brief Initializes the core Vulkan instance, surface, and device.
 */
static bool init_vulkan_core(VulkanState* s, CardinalWindow* window) {
    CARDINAL_LOG_WARN("renderer_create: begin");
    if (!vk_create_instance(s)) {
        CARDINAL_LOG_ERROR("vk_create_instance failed");
        return false;
    }
    CARDINAL_LOG_INFO("renderer_create: instance");
    if (!vk_create_surface(s, window)) {
        CARDINAL_LOG_ERROR("vk_create_surface failed");
        return false;
    }
    CARDINAL_LOG_INFO("renderer_create: surface");
    if (!vk_pick_physical_device(s)) {
        CARDINAL_LOG_ERROR("vk_pick_physical_device failed");
        return false;
    }
    CARDINAL_LOG_INFO("renderer_create: physical_device");
    if (!vk_create_device(s)) {
        CARDINAL_LOG_ERROR("vk_create_device failed");
        return false;
    }
    CARDINAL_LOG_INFO("renderer_create: device");
    return true;
}

/**
 * @brief Initializes reference counting systems.
 */
static bool init_ref_counting(void) {
    // Initialize reference counting system (if not already initialized)
    if (!cardinal_ref_counting_init(256)) {
        // This is expected if already initialized by the application
        CARDINAL_LOG_DEBUG("Reference counting system already initialized or failed to initialize");
    }
    CARDINAL_LOG_INFO("renderer_create: ref_counting");

    // Initialize material reference counting
    if (!cardinal_material_ref_init()) {
        CARDINAL_LOG_ERROR("cardinal_material_ref_counting_init failed");
        cardinal_ref_counting_shutdown();
        return false;
    }
    CARDINAL_LOG_INFO("renderer_create: material_ref_counting");
    return true;
}

/**
 * @brief Sets up Vulkan function pointers in the context.
 */
static void setup_function_pointers(VulkanState* s) {
    if (!s->context.vkQueueSubmit2)
        s->context.vkQueueSubmit2 = vkQueueSubmit2;
    if (!s->context.vkCmdPipelineBarrier2)
        s->context.vkCmdPipelineBarrier2 = vkCmdPipelineBarrier2;
    if (!s->context.vkCmdBeginRendering)
        s->context.vkCmdBeginRendering = vkCmdBeginRendering;
    if (!s->context.vkCmdEndRendering)
        s->context.vkCmdEndRendering = vkCmdEndRendering;
}

/**
 * @brief Initializes the synchronization manager.
 */
static bool init_sync_manager(VulkanState* s) {
    // Initialize centralized sync manager
    s->sync_manager = malloc(sizeof(VulkanSyncManager));
    if (!s->sync_manager) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for VulkanSyncManager");
        return false;
    }
    if (!vulkan_sync_manager_init(s->sync_manager, s->context.device, s->context.graphics_queue,
                                  s->sync.max_frames_in_flight)) {
        CARDINAL_LOG_ERROR("vulkan_sync_manager_init failed");
        free(s->sync_manager);
        s->sync_manager = NULL;
        return false;
    }
    CARDINAL_LOG_INFO("renderer_create: sync_manager");

    // Ensure renderer and sync manager use the same timeline semaphore
    if (s->sync_manager && s->sync_manager->timeline_semaphore != VK_NULL_HANDLE &&
        s->sync.timeline_semaphore != s->sync_manager->timeline_semaphore) {
        if (s->sync.timeline_semaphore != VK_NULL_HANDLE) {
            vkDestroySemaphore(s->context.device, s->sync.timeline_semaphore, NULL);
            CARDINAL_LOG_INFO("[INIT] Replacing renderer timeline with sync_manager timeline");
        }
        s->sync.timeline_semaphore = s->sync_manager->timeline_semaphore;
    }
    return true;
}

/**
 * @brief Initializes the PBR pipeline.
 */
static void init_pbr_pipeline_helper(VulkanState* s) {
    s->pipelines.use_pbr_pipeline = false;
    if (vk_pbr_pipeline_create(&s->pipelines.pbr_pipeline, s->context.device,
                               s->context.physical_device, s->swapchain.format,
                               s->swapchain.depth_format, s->commands.pools[0],
                               s->context.graphics_queue, &s->allocator, s)) {
        s->pipelines.use_pbr_pipeline = true;
        CARDINAL_LOG_INFO("renderer_create: PBR pipeline");
    } else {
        CARDINAL_LOG_ERROR("vk_pbr_pipeline_create failed");
    }
}

/**
 * @brief Initializes the Mesh Shader pipeline.
 */
static void init_mesh_shader_pipeline_helper(VulkanState* s) {
    s->pipelines.use_mesh_shader_pipeline = false;
    if (!s->context.supports_mesh_shader) {
        CARDINAL_LOG_INFO("Mesh shaders not supported on this device");
        return;
    }

    if (!vk_mesh_shader_init(s)) {
        CARDINAL_LOG_ERROR("vk_mesh_shader_init failed");
        return;
    }

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

    if (vk_mesh_shader_create_pipeline(s, &config, s->swapchain.format,
                                       s->swapchain.depth_format,
                                       &s->pipelines.mesh_shader_pipeline)) {
        s->pipelines.use_mesh_shader_pipeline = true;
        CARDINAL_LOG_INFO("renderer_create: Mesh shader pipeline");
    } else {
        CARDINAL_LOG_ERROR("vk_mesh_shader_create_pipeline failed");
    }
}

/**
 * @brief Initializes the Compute pipeline.
 */
static void init_compute_pipeline_helper(VulkanState* s) {
    s->pipelines.compute_shader_initialized = false;
    s->pipelines.compute_descriptor_pool = VK_NULL_HANDLE;
    s->pipelines.compute_command_pool = VK_NULL_HANDLE;
    s->pipelines.compute_command_buffer = VK_NULL_HANDLE;

    if (vk_compute_init(s)) {
        s->pipelines.compute_shader_initialized = true;
        CARDINAL_LOG_INFO("renderer_create: Compute shader support");
    } else {
        CARDINAL_LOG_ERROR("vk_compute_init failed");
    }
}

/**
 * @brief Initializes Simple pipelines (UV, Wireframe).
 */
static void init_simple_pipelines_helper(VulkanState* s) {
    s->pipelines.uv_pipeline = VK_NULL_HANDLE;
    s->pipelines.uv_pipeline_layout = VK_NULL_HANDLE;
    s->pipelines.wireframe_pipeline = VK_NULL_HANDLE;
    s->pipelines.wireframe_pipeline_layout = VK_NULL_HANDLE;
    s->pipelines.simple_descriptor_layout = VK_NULL_HANDLE;
    s->pipelines.simple_descriptor_pool = VK_NULL_HANDLE;
    s->pipelines.simple_descriptor_set = VK_NULL_HANDLE;
    s->pipelines.simple_uniform_buffer = VK_NULL_HANDLE;
    s->pipelines.simple_uniform_buffer_memory = VK_NULL_HANDLE;
    s->pipelines.simple_uniform_buffer_mapped = NULL;

    if (!vk_create_simple_pipelines(s)) {
        CARDINAL_LOG_ERROR("vk_create_simple_pipelines failed");
    } else {
        CARDINAL_LOG_INFO("renderer_create: simple pipelines");
    }
}

/**
 * @brief Initializes PBR, Mesh Shader, Compute, and Simple pipelines.
 */
static bool init_pipelines(VulkanState* s) {
    init_pbr_pipeline_helper(s);
    init_mesh_shader_pipeline_helper(s);
    init_compute_pipeline_helper(s);
    
    // Initialize rendering mode
    s->current_rendering_mode = CARDINAL_RENDERING_MODE_NORMAL;
    
    init_simple_pipelines_helper(s);

    return true;
}

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

    // Initialize device loss recovery state
    s->recovery.device_lost = false;
    s->recovery.recovery_in_progress = false;
    s->recovery.attempt_count = 0;
    s->recovery.max_attempts = 3; // Allow up to 3 recovery attempts
    s->recovery.window = window;  // Store window reference for recovery
    s->recovery.device_loss_callback = NULL;
    s->recovery.recovery_complete_callback = NULL;
    s->recovery.callback_user_data = NULL;
    // Register window resize callback
    window->resize_callback = vk_handle_window_resize;
    window->resize_user_data = s;

    if (!init_vulkan_core(s, window)) return false;
    if (!init_ref_counting()) return false;

    if (!vk_create_swapchain(s)) {
        CARDINAL_LOG_ERROR("vk_create_swapchain failed");
        cardinal_material_ref_shutdown();
        cardinal_ref_counting_shutdown();
        return false;
    }
    CARDINAL_LOG_WARN("renderer_create: swapchain created");

    if (!vk_create_pipeline(s)) {
        CARDINAL_LOG_ERROR("vk_create_pipeline failed");
        return false;
    }
    CARDINAL_LOG_WARN("renderer_create: pipeline created");

    if (!vk_create_commands_sync(s)) {
        CARDINAL_LOG_ERROR("vk_create_commands_sync failed");
        return false;
    }
    CARDINAL_LOG_INFO("renderer_create: commands");

    setup_function_pointers(s);

    if (!init_sync_manager(s)) return false;
    if (!init_pipelines(s)) return false;

    // Initialize barrier validation system
    if (!cardinal_barrier_validation_init(1000, false)) {
        CARDINAL_LOG_ERROR("cardinal_barrier_validation_init failed");
        // Continue anyway, validation is optional
    } else {
        CARDINAL_LOG_INFO("renderer_create: barrier validation");
    }

    return true;
}

bool cardinal_renderer_create_headless(CardinalRenderer* out_renderer, uint32_t width,
                                       uint32_t height) {
    if (!out_renderer)
        return false;
    VulkanState* s = (VulkanState*)calloc(1, sizeof(VulkanState));
    out_renderer->_opaque = s;
    s->swapchain.headless_mode = true;
    s->swapchain.skip_present = true;
    s->recovery.window = NULL;
    s->swapchain.handle = VK_NULL_HANDLE;
    s->swapchain.extent = (VkExtent2D){width, height};
    s->swapchain.image_count = 1;
    s->recovery.device_lost = false;
    s->recovery.recovery_in_progress = false;
    s->recovery.attempt_count = 0;
    s->recovery.max_attempts = 0;

    CARDINAL_LOG_WARN("renderer_create_headless: begin");
    if (!vk_create_instance(s)) {
        CARDINAL_LOG_ERROR("vk_create_instance failed");
        return false;
    }
    if (!vk_pick_physical_device(s)) {
        CARDINAL_LOG_ERROR("vk_pick_physical_device failed");
        return false;
    }
    if (!vk_create_device(s)) {
        CARDINAL_LOG_ERROR("vk_create_device failed");
        return false;
    }

    if (!vk_create_commands_sync(s)) {
        CARDINAL_LOG_ERROR("vk_create_commands_sync failed");
        return false;
    }

    s->sync_manager = malloc(sizeof(VulkanSyncManager));
    if (!s->sync_manager) {
        CARDINAL_LOG_ERROR("Failed to allocate VulkanSyncManager");
        return false;
    }
    if (!vulkan_sync_manager_init(s->sync_manager, s->context.device, s->context.graphics_queue,
                                  s->sync.max_frames_in_flight)) {
        CARDINAL_LOG_ERROR("vulkan_sync_manager_init failed");
        free(s->sync_manager);
        s->sync_manager = NULL;
        return false;
    }

    // Ensure function pointers fallback
    if (!s->context.vkQueueSubmit2)
        s->context.vkQueueSubmit2 = vkQueueSubmit2;
    if (!s->context.vkCmdPipelineBarrier2)
        s->context.vkCmdPipelineBarrier2 = vkCmdPipelineBarrier2;
    if (!s->context.vkCmdBeginRendering)
        s->context.vkCmdBeginRendering = vkCmdBeginRendering;
    if (!s->context.vkCmdEndRendering)
        s->context.vkCmdEndRendering = vkCmdEndRendering;

    CARDINAL_LOG_INFO("renderer_create_headless: success");
    return true;
}

void cardinal_renderer_set_skip_present(CardinalRenderer* renderer, bool skip) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    s->swapchain.skip_present = skip;
}

void cardinal_renderer_set_headless_mode(CardinalRenderer* renderer, bool enable) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    s->swapchain.headless_mode = enable;
}

/**
 * @brief Waits for the device to become idle.
 * @param renderer Pointer to the CardinalRenderer.
 */
void cardinal_renderer_wait_idle(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    vkDeviceWaitIdle(s->context.device);
}

/**
 * @brief Destroys GPU buffers for the current scene.
 * @param s Pointer to the VulkanState structure.
 *
 * @todo Add reference counting for shared buffers.
 */
void destroy_scene_buffers(VulkanState* s) {
    if (!s)
        return;

    CARDINAL_LOG_DEBUG("[RENDERER] destroy_scene_buffers: start");

    // Ensure GPU has finished using previous scene buffers before destroying them
    // Skip wait if device is already lost, as semaphores might be invalid or device unresponsive
    if (s->sync_manager && s->sync_manager->timeline_semaphore != VK_NULL_HANDLE &&
        !s->recovery.device_lost) {
        uint64_t sem_value = 0;
        VkResult get_res = vulkan_sync_manager_get_timeline_value(s->sync_manager, &sem_value);
        CARDINAL_LOG_INFO("[RENDERER] destroy_scene_buffers: waiting timeline to reach "
                          "current_frame_value=%llu (semaphore current=%llu, get_res=%d)",
                          (unsigned long long)s->sync.current_frame_value,
                          (unsigned long long)sem_value, get_res);

        // If the semaphore isn't advancing (e.g., different timeline was used), avoid indefinite
        // wait
        if (get_res != VK_SUCCESS || sem_value < s->sync.current_frame_value) {
            CARDINAL_LOG_WARN("[RENDERER] Timeline behind or unavailable; using vkDeviceWaitIdle");
            if (s->context.device) {
                VkResult idle_res = vkDeviceWaitIdle(s->context.device);
                CARDINAL_LOG_DEBUG("[RENDERER] destroy_scene_buffers: vkDeviceWaitIdle result=%d",
                                   idle_res);
            }
        } else {
            VkResult wait_res = vulkan_sync_manager_wait_timeline(
                s->sync_manager, s->sync.current_frame_value, UINT64_MAX);
            if (wait_res == VK_SUCCESS) {
                CARDINAL_LOG_DEBUG("[RENDERER] destroy_scene_buffers: timeline wait succeeded");
            } else {
                CARDINAL_LOG_WARN("[RENDERER] Timeline wait failed in destroy_scene_buffers: %d; "
                                  "falling back to device wait idle",
                                  wait_res);
                if (s->context.device) {
                    VkResult idle_res = vkDeviceWaitIdle(s->context.device);
                    CARDINAL_LOG_DEBUG(
                        "[RENDERER] destroy_scene_buffers: vkDeviceWaitIdle result=%d", idle_res);
                }
            }
        }
    } else if (s->context.device && !s->recovery.device_lost) {
        CARDINAL_LOG_DEBUG(
            "[RENDERER] destroy_scene_buffers: no timeline; calling vkDeviceWaitIdle");
        vkDeviceWaitIdle(s->context.device);
    }

    if (!s->scene_meshes)
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
    CARDINAL_LOG_DEBUG("[RENDERER] destroy_scene_buffers: completed");
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

    CARDINAL_LOG_INFO("[DESTROY] Starting renderer destruction");

    // destroy in reverse order
    destroy_scene_buffers(s);

    vk_destroy_commands_sync(s);

    // Cleanup VulkanSyncManager
    if (s->sync_manager) {
        CARDINAL_LOG_DEBUG("[DESTROY] Cleaning up sync manager");
        vulkan_sync_manager_destroy(s->sync_manager);
        free(s->sync_manager);
        s->sync_manager = NULL;
    }

    // Cleanup compute shader support
    if (s->pipelines.compute_shader_initialized) {
        vk_compute_cleanup(s);
        s->pipelines.compute_shader_initialized = false;
    }

    // Shutdown reference counting systems
    cardinal_material_ref_shutdown();
    cardinal_ref_counting_shutdown();

    // Shutdown barrier validation system
    cardinal_barrier_validation_shutdown();

    // Destroy simple pipelines
    CARDINAL_LOG_DEBUG("[DESTROY] Destroying simple pipelines");
    vk_destroy_simple_pipelines(s);

    // Wait for all GPU operations to complete before destroying PBR pipeline
    // This ensures descriptor sets are not in use when destroyed
    if (s->context.device) {
        vkDeviceWaitIdle(s->context.device);
    }

    // Destroy PBR pipeline
    if (s->pipelines.use_pbr_pipeline) {
        CARDINAL_LOG_DEBUG("[DESTROY] Destroying PBR pipeline");
        vk_pbr_pipeline_destroy(&s->pipelines.pbr_pipeline, s->context.device, &s->allocator);
        s->pipelines.use_pbr_pipeline = false;
    }

    // Process any remaining pending mesh shader cleanup BEFORE destroying allocator
    vk_mesh_shader_process_pending_cleanup(s);

    // Free pending cleanup list
    if (s->pending_cleanup_draw_data) {
        CARDINAL_LOG_DEBUG("[DESTROY] Freeing pending cleanup list");
        free(s->pending_cleanup_draw_data);
        s->pending_cleanup_draw_data = NULL;
        s->pending_cleanup_count = 0;
        s->pending_cleanup_capacity = 0;
    }

    // Destroy mesh shader pipeline BEFORE destroying allocator
    if (s->pipelines.use_mesh_shader_pipeline) {
        CARDINAL_LOG_DEBUG("[DESTROY] Destroying mesh shader pipeline");
        vk_mesh_shader_destroy_pipeline(s, &s->pipelines.mesh_shader_pipeline);
        // vk_mesh_shader_cleanup is redundant here as we already handled pending list, 
        // but let's call it for completeness if it does other things in future.
        // We must ensure it handles NULL pointers gracefully.
        vk_mesh_shader_cleanup(s);
        s->pipelines.use_mesh_shader_pipeline = false;
    }

    CARDINAL_LOG_DEBUG("[DESTROY] Destroying base pipeline resources");
    vk_destroy_pipeline(s);
    vk_destroy_swapchain(s);
    vk_destroy_device_objects(s);

    CARDINAL_LOG_INFO("[DESTROY] Freeing renderer state");
    free(s);
    renderer->_opaque = NULL;
}

VkCommandBuffer cardinal_renderer_internal_current_cmd(CardinalRenderer* renderer,
                                                       uint32_t image_index) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    (void)image_index; // unused now
    return s->commands.buffers[s->sync.current_frame];
}

VkDevice cardinal_renderer_internal_device(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->context.device;
}

VkPhysicalDevice cardinal_renderer_internal_physical_device(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->context.physical_device;
}

VkQueue cardinal_renderer_internal_graphics_queue(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->context.graphics_queue;
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

    float tan_half_fov = tanf(fov * 0.5f * (float)M_PI / 180.0f);

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

    if (!s->pipelines.use_pbr_pipeline)
        return;

    PBRUniformBufferObject ubo = {0};

    // Create model matrix (identity for now)
    cardinal_matrix_identity(ubo.model);

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
    memcpy(s->pipelines.pbr_pipeline.uniformBufferMapped, &ubo, sizeof(PBRUniformBufferObject));

    // Also invoke the centralized PBR uniform updater to keep both UBO and lighting in sync
    PBRLightingData lighting;
    memcpy(&lighting, s->pipelines.pbr_pipeline.lightingBufferMapped, sizeof(PBRLightingData));
    vk_pbr_update_uniforms(&s->pipelines.pbr_pipeline, &ubo, &lighting);
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

    if (!s->pipelines.use_pbr_pipeline)
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
    memcpy(s->pipelines.pbr_pipeline.lightingBufferMapped, &lighting, sizeof(PBRLightingData));

    // Also invoke the centralized PBR uniform updater to keep both UBO and lighting in sync
    PBRUniformBufferObject ubo;
    memcpy(&ubo, s->pipelines.pbr_pipeline.uniformBufferMapped, sizeof(PBRUniformBufferObject));
    vk_pbr_update_uniforms(&s->pipelines.pbr_pipeline, &ubo, &lighting);
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

    if (enable && !s->pipelines.use_pbr_pipeline) {
        // Destroy existing PBR pipeline if it exists (in case of re-enabling)
        if (s->pipelines.pbr_pipeline.initialized) {
            vk_pbr_pipeline_destroy(&s->pipelines.pbr_pipeline, s->context.device, &s->allocator);
        }

        // Try to create PBR pipeline
        if (vk_pbr_pipeline_create(&s->pipelines.pbr_pipeline, s->context.device,
                                   s->context.physical_device, s->swapchain.format,
                                   s->swapchain.depth_format, s->commands.pools[0],
                                   s->context.graphics_queue, &s->allocator, s)) {
            s->pipelines.use_pbr_pipeline = true;

            // Load current scene if one exists
            if (s->current_scene) {
                vk_pbr_load_scene(&s->pipelines.pbr_pipeline, s->context.device,
                                  s->context.physical_device, s->commands.pools[0],
                                  s->context.graphics_queue, s->current_scene, &s->allocator, s);
            }

            CARDINAL_LOG_INFO("PBR pipeline enabled");
        } else {
            CARDINAL_LOG_ERROR("Failed to enable PBR pipeline");
        }
    } else if (!enable && s->pipelines.use_pbr_pipeline) {
        // Destroy PBR pipeline
        vk_pbr_pipeline_destroy(&s->pipelines.pbr_pipeline, s->context.device, &s->allocator);
        s->pipelines.use_pbr_pipeline = false;
        CARDINAL_LOG_INFO("PBR pipeline disabled");
    }
}

bool cardinal_renderer_is_pbr_enabled(CardinalRenderer* renderer) {
    if (!renderer)
        return false;
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->pipelines.use_pbr_pipeline;
}

/**
 * @brief Enables or disables mesh shader rendering pipeline.
 * @param renderer Pointer to the CardinalRenderer.
 * @param enable True to enable mesh shaders, false to disable.
 */
void cardinal_renderer_enable_mesh_shader(CardinalRenderer* renderer, bool enable) {
    if (!renderer)
        return;
    VulkanState* s = (VulkanState*)renderer->_opaque;

    if (enable && !s->pipelines.use_mesh_shader_pipeline && s->context.supports_mesh_shader) {
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

        // Try to create mesh shader pipeline
        if (vk_mesh_shader_create_pipeline(s, &config, s->swapchain.format,
                                           s->swapchain.depth_format,
                                           &s->pipelines.mesh_shader_pipeline)) {
            s->pipelines.use_mesh_shader_pipeline = true;
            CARDINAL_LOG_INFO("Mesh shader pipeline enabled");
        } else {
            CARDINAL_LOG_ERROR("Failed to enable mesh shader pipeline");
        }
    } else if (!enable && s->pipelines.use_mesh_shader_pipeline) {
        // Destroy mesh shader pipeline
        vk_mesh_shader_destroy_pipeline(s, &s->pipelines.mesh_shader_pipeline);
        s->pipelines.use_mesh_shader_pipeline = false;
        CARDINAL_LOG_INFO("Mesh shader pipeline disabled");
    } else if (enable && !s->context.supports_mesh_shader) {
        CARDINAL_LOG_WARN("Mesh shaders not supported on this device");
    }
}

bool cardinal_renderer_is_mesh_shader_enabled(CardinalRenderer* renderer) {
    if (!renderer)
        return false;
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->pipelines.use_mesh_shader_pipeline;
}

bool cardinal_renderer_supports_mesh_shader(CardinalRenderer* renderer) {
    if (!renderer)
        return false;
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->context.supports_mesh_shader;
}

uint32_t cardinal_renderer_internal_graphics_queue_family(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->context.graphics_queue_family;
}

VkInstance cardinal_renderer_internal_instance(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->context.instance;
}

uint32_t cardinal_renderer_internal_swapchain_image_count(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->swapchain.image_count;
}

VkFormat cardinal_renderer_internal_swapchain_format(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->swapchain.format;
}

VkFormat cardinal_renderer_internal_depth_format(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->swapchain.depth_format;
}

VkExtent2D cardinal_renderer_internal_swapchain_extent(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    return s->swapchain.extent;
}

void cardinal_renderer_set_ui_callback(CardinalRenderer* renderer,
                                       void (*callback)(VkCommandBuffer cmd)) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    s->ui_record_callback = callback;
}

/**
 * @brief Submits a command buffer and waits for completion.
 */
static void submit_and_wait(VulkanState* s, VkCommandBuffer cmd) {
    VkCommandBufferSubmitInfo cmd_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .commandBuffer = cmd,
        .deviceMask = 0
    };
    VkSubmitInfo2 submit2 = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmd_info
    };

    if (s->sync_manager) {
        uint64_t timeline_value = vulkan_sync_manager_get_next_timeline_value(s->sync_manager);

        VkSemaphoreSubmitInfo signal_semaphore_info = {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = s->sync_manager->timeline_semaphore,
            .value = timeline_value,
            .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT};

        submit2.signalSemaphoreInfoCount = 1;
        submit2.pSignalSemaphoreInfos = &signal_semaphore_info;

        VkResult submit_result =
            s->context.vkQueueSubmit2(s->context.graphics_queue, 1, &submit2, VK_NULL_HANDLE);
        if (submit_result == VK_SUCCESS) {
            // Wait for completion using timeline semaphore
            VkResult wait_result =
                vulkan_sync_manager_wait_timeline(s->sync_manager, timeline_value, UINT64_MAX);
            if (wait_result == VK_SUCCESS) {
                vkFreeCommandBuffers(s->context.device, s->commands.pools[s->sync.current_frame], 1,
                                     &cmd);
            } else {
                CARDINAL_LOG_WARN("[SYNC] Timeline wait failed for immediate submit: %d",
                                  wait_result);
            }
        } else {
            CARDINAL_LOG_ERROR("[SYNC] Failed to submit immediate command buffer: %d",
                               submit_result);
        }
    } else {
        // Fallback to old method if sync manager not available
        s->context.vkQueueSubmit2(s->context.graphics_queue, 1, &submit2, VK_NULL_HANDLE);
        VkResult wait_result = vkQueueWaitIdle(s->context.graphics_queue);

        if (wait_result == VK_SUCCESS) {
            vkFreeCommandBuffers(s->context.device, s->commands.pools[s->sync.current_frame], 1,
                                 &cmd);
        } else {
            CARDINAL_LOG_WARN("[SYNC] Skipping command buffer free due to queue wait failure: %d",
                              wait_result);
        }
    }
}

/**
 * @brief Submits an immediate command buffer for execution.
 * @param renderer Pointer to the CardinalRenderer.
 * @param record Callback to record commands.
 *
 * Now supports secondary command buffers when multi-threading subsystem is available.
 */
void cardinal_renderer_immediate_submit(CardinalRenderer* renderer,
                                        void (*record)(VkCommandBuffer cmd)) {
    VulkanState* s = (VulkanState*)renderer->_opaque;

    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    ai.commandPool = s->commands.pools[s->sync.current_frame];
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;

    VkCommandBuffer cmd;
    vkAllocateCommandBuffers(s->context.device, &ai, &cmd);

    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &bi);

    if (record)
        record(cmd);

    vkEndCommandBuffer(cmd);

    submit_and_wait(s, cmd);
}

/**
 * @brief Tries to submit using a secondary command buffer.
 */
static bool try_submit_secondary(VulkanState* s, void (*record)(VkCommandBuffer cmd)) {
    CardinalMTCommandManager* mt_manager = vk_get_mt_command_manager();
    if (!mt_manager || !mt_manager->thread_pools[0].is_active) {
        return false;
    }

    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    ai.commandPool = s->commands.pools[s->sync.current_frame];
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;

    VkCommandBuffer primary_cmd;
    vkAllocateCommandBuffers(s->context.device, &ai, &primary_cmd);

    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(primary_cmd, &bi);

    CardinalSecondaryCommandContext secondary_context;
    if (!cardinal_mt_allocate_secondary_command_buffer(&mt_manager->thread_pools[0], &secondary_context)) {
        vkEndCommandBuffer(primary_cmd);
        return false;
    }

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
    inheritance_info.renderPass = VK_NULL_HANDLE;
    inheritance_info.subpass = 0;
    inheritance_info.framebuffer = VK_NULL_HANDLE;
    inheritance_info.occlusionQueryEnable = VK_FALSE;

    if (!cardinal_mt_begin_secondary_command_buffer(&secondary_context, &inheritance_info)) {
        vkEndCommandBuffer(primary_cmd);
        return false;
    }

    if (record) {
        record(secondary_context.command_buffer);
    }

    if (!cardinal_mt_end_secondary_command_buffer(&secondary_context)) {
        vkEndCommandBuffer(primary_cmd);
        return false;
    }

    cardinal_mt_execute_secondary_command_buffers(primary_cmd, &secondary_context, 1);
    vkEndCommandBuffer(primary_cmd);

    submit_and_wait(s, primary_cmd);
    return true;
}

/**
 * @brief Submits an immediate command buffer with secondary command buffer support.
 * @param renderer Pointer to the CardinalRenderer.
 * @param record Callback to record commands.
 * @param use_secondary Whether to try using secondary command buffers.
 */
void cardinal_renderer_immediate_submit_with_secondary(CardinalRenderer* renderer,
                                                       void (*record)(VkCommandBuffer cmd),
                                                       bool use_secondary) {
    VulkanState* s = (VulkanState*)renderer->_opaque;

    // Check if secondary command buffers are requested and available
    if (use_secondary) {
        if (try_submit_secondary(s, record)) {
            return;
        }
        // Fallback to primary if secondary failed
        CARDINAL_LOG_WARN("[SYNC] Secondary command buffer failed, falling back to primary");
    }

    // Fallback to regular immediate submit
    cardinal_renderer_immediate_submit(renderer, record);
}

/**
 * @brief Uploads a single mesh to GPU.
 */
static bool upload_single_mesh(VulkanState* s, const CardinalMesh* src, GpuMesh* dst, uint32_t mesh_index) {
    dst->vbuf = VK_NULL_HANDLE;
    dst->vmem = VK_NULL_HANDLE;
    dst->ibuf = VK_NULL_HANDLE;
    dst->imem = VK_NULL_HANDLE;
    dst->vtx_count = 0;
    dst->idx_count = 0;

    dst->vtx_stride = sizeof(CardinalVertex);
    VkDeviceSize vsize = (VkDeviceSize)src->vertex_count * dst->vtx_stride;
    VkDeviceSize isize = (VkDeviceSize)src->index_count * sizeof(uint32_t);

    CARDINAL_LOG_DEBUG("[UPLOAD] Mesh %u: vsize=%llu, isize=%llu, vertices=%u, indices=%u", mesh_index,
                       (unsigned long long)vsize, (unsigned long long)isize, src->vertex_count,
                       src->index_count);

    if (!src->vertices || src->vertex_count == 0) {
        CARDINAL_LOG_ERROR("Mesh %u has no vertices", mesh_index);
        return false;
    }

    CARDINAL_LOG_DEBUG("[UPLOAD] Mesh %u: staging vertex buffer", mesh_index);
    if (!vk_buffer_create_with_staging(&s->allocator, s->context.device, s->commands.pools[0],
                                       s->context.graphics_queue, src->vertices, vsize,
                                       VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &dst->vbuf,
                                       &dst->vmem, s)) {
        CARDINAL_LOG_ERROR("Failed to create vertex buffer for mesh %u", mesh_index);
        return false;
    }

    if (src->index_count > 0 && src->indices) {
        CARDINAL_LOG_DEBUG("[UPLOAD] Mesh %u: staging index buffer", mesh_index);
        if (vk_buffer_create_with_staging(&s->allocator, s->context.device,
                                          s->commands.pools[0], s->context.graphics_queue,
                                          src->indices, isize, VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                                          &dst->ibuf, &dst->imem, s)) {
            dst->idx_count = src->index_count;
        } else {
            CARDINAL_LOG_ERROR("Failed to create index buffer for mesh %u", mesh_index);
        }
    }
    dst->vtx_count = src->vertex_count;

    CARDINAL_LOG_DEBUG("Successfully uploaded mesh %u: %u vertices, %u indices", mesh_index,
                       src->vertex_count, src->index_count);
    return true;
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

    CARDINAL_LOG_INFO("[UPLOAD] Starting scene upload; meshes=%u", scene ? scene->mesh_count : 0);

    if (s->swapchain.recreation_pending || s->swapchain.window_resize_pending ||
        s->recovery.recovery_in_progress || s->recovery.device_lost) {
        s->pending_scene_upload = scene;
        s->scene_upload_pending = true;
        CARDINAL_LOG_WARN("[UPLOAD] Deferring scene upload due to swapchain/recovery state");
        return;
    }

    if (s->context.vkGetSemaphoreCounterValue && s->sync.timeline_semaphore) {
        uint64_t sem_val = 0;
        VkResult sem_res = s->context.vkGetSemaphoreCounterValue(
            s->context.device, s->sync.timeline_semaphore, &sem_val);
        CARDINAL_LOG_DEBUG("[UPLOAD][SYNC] Timeline before cleanup: value=%llu, "
                           "current_frame_value=%llu, result=%d",
                           (unsigned long long)sem_val,
                           (unsigned long long)s->sync.current_frame_value, sem_res);
    }

    CARDINAL_LOG_DEBUG("[UPLOAD] Destroying previous scene buffers");
    destroy_scene_buffers(s);

    if (!scene || scene->mesh_count == 0) {
        CARDINAL_LOG_WARN("[UPLOAD] No scene or zero meshes; aborting upload");
        return;
    }

    s->scene_mesh_count = scene->mesh_count;
    s->scene_meshes = (GpuMesh*)calloc(s->scene_mesh_count, sizeof(GpuMesh));
    if (!s->scene_meshes) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for scene meshes");
        return;
    }

    CARDINAL_LOG_INFO("Uploading scene with %u meshes using batched staging operations",
                      scene->mesh_count);

    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* src = &scene->meshes[i];
        GpuMesh* dst = &s->scene_meshes[i];
        
        if (!upload_single_mesh(s, src, dst, i)) {
            continue;
        }
    }

    if (s->pipelines.use_pbr_pipeline) {
        CARDINAL_LOG_INFO("[UPLOAD][PBR] Loading scene into PBR pipeline");
        vk_pbr_load_scene(&s->pipelines.pbr_pipeline, s->context.device, s->context.physical_device,
                          s->commands.pools[0], s->context.graphics_queue, scene, &s->allocator, s);
    }

    // Keep a reference to the uploaded scene, but be careful about ownership.
    // The renderer does NOT own the scene data, it only reads from it during upload/record.
    // However, s->current_scene is used in draw_frame to determine if we should render.
    s->current_scene = scene;

    CARDINAL_LOG_INFO("Scene upload completed successfully with %u meshes", scene->mesh_count);
}

void cardinal_renderer_clear_scene(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;

    // Wait for all GPU operations to complete before destroying scene buffers
    vkDeviceWaitIdle(s->context.device);

    destroy_scene_buffers(s);
}

void cardinal_renderer_set_rendering_mode(CardinalRenderer* renderer, CardinalRenderingMode mode) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    if (!s) {
        CARDINAL_LOG_ERROR("Invalid renderer state");
        return;
    }

    // Store previous mode to detect changes
    CardinalRenderingMode previous_mode = s->current_rendering_mode;
    s->current_rendering_mode = mode;

    // Handle mesh shader pipeline enable/disable based on mode
    if (mode == CARDINAL_RENDERING_MODE_MESH_SHADER &&
        previous_mode != CARDINAL_RENDERING_MODE_MESH_SHADER) {
        // Switching to mesh shader mode - enable mesh shader pipeline
        cardinal_renderer_enable_mesh_shader(renderer, true);
    } else if (mode != CARDINAL_RENDERING_MODE_MESH_SHADER &&
               previous_mode == CARDINAL_RENDERING_MODE_MESH_SHADER) {
        // Switching away from mesh shader mode - disable mesh shader pipeline
        cardinal_renderer_enable_mesh_shader(renderer, false);
    }

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

void cardinal_renderer_set_device_loss_callbacks(
    CardinalRenderer* renderer, void (*device_loss_callback)(void* user_data),
    void (*recovery_complete_callback)(void* user_data, bool success), void* user_data) {
    if (!renderer) {
        CARDINAL_LOG_ERROR("Invalid renderer");
        return;
    }

    VulkanState* s = (VulkanState*)renderer->_opaque;
    if (!s) {
        CARDINAL_LOG_ERROR("Invalid renderer state");
        return;
    }

    s->recovery.device_loss_callback = device_loss_callback;
    s->recovery.recovery_complete_callback = recovery_complete_callback;
    s->recovery.callback_user_data = user_data;

    CARDINAL_LOG_INFO("Device loss recovery callbacks set");
}

bool cardinal_renderer_is_device_lost(CardinalRenderer* renderer) {
    if (!renderer) {
        return false;
    }

    VulkanState* s = (VulkanState*)renderer->_opaque;
    if (!s) {
        return false;
    }

    return s->recovery.device_lost;
}

bool cardinal_renderer_get_recovery_stats(CardinalRenderer* renderer, uint32_t* out_attempt_count,
                                          uint32_t* out_max_attempts) {
    if (!renderer || !out_attempt_count || !out_max_attempts) {
        return false;
    }

    VulkanState* s = (VulkanState*)renderer->_opaque;
    if (!s) {
        return false;
    }

    *out_attempt_count = s->recovery.attempt_count;
    *out_max_attempts = s->recovery.max_attempts;

    return true;
}
