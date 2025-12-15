#include "cardinal/core/log.h"
#include "cardinal/core/window.h"
#include "vulkan_simple_pipelines.h"
#include "vulkan_state.h"
#include <GLFW/glfw3.h>
#include <cardinal/renderer/vulkan_commands.h>
#include <cardinal/renderer/vulkan_mesh_shader.h>
#include <cardinal/renderer/vulkan_pipeline.h>
#include <cardinal/renderer/vulkan_swapchain.h>
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>
#ifdef _WIN32
    #include <windows.h>
#else
    #include <time.h>
#endif

// Helper functions
static uint64_t get_current_time_ms() {
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
#endif
}

static bool should_throttle_recreation(VulkanState* s) {
    if (!s->swapchain.frame_pacing_enabled) {
        return false;
    }

    uint64_t current_time = get_current_time_ms();
    uint64_t time_since_last = current_time - s->swapchain.last_recreation_time;

    // Throttle if less than 100ms since last recreation and we've had multiple failures
    if (time_since_last < 100 && s->swapchain.consecutive_recreation_failures > 0) {
        return true;
    }

    // More aggressive throttling if we've had many consecutive failures
    if (s->swapchain.consecutive_recreation_failures >= 3 && time_since_last < 500) {
        // Only log this warning once every 1000ms to reduce spam
        static uint64_t last_throttle_log = 0;
        if (current_time - last_throttle_log > 1000) {
            CARDINAL_LOG_WARN("[SWAPCHAIN] Aggressive throttling: %u consecutive failures",
                              s->swapchain.consecutive_recreation_failures);
            last_throttle_log = current_time;
        }
        return true;
    }

    // Extreme throttling for persistent failures
    if (s->swapchain.consecutive_recreation_failures >= 6) {
        // Wait much longer between attempts when we have many failures
        if (time_since_last < 2000) {
            return true;
        }
    }

    return false;
}

/**
 * @brief Chooses the optimal surface format from available options.
 * @param formats Array of available formats.
 * @param count Number of formats.
 * @return Selected surface format.
 *
 * @todo Add support for HDR formats like VK_FORMAT_B10G11R11_UFLOAT_PACK32.
 */
static VkSurfaceFormatKHR choose_surface_format(const VkSurfaceFormatKHR* formats, uint32_t count) {
    if (count == 0) {
        VkSurfaceFormatKHR fallback = {0};
        return fallback;
    }

    // Allow opting into HDR via environment variable CARDINAL_PREFER_HDR
    bool prefer_hdr = false;
    const char* env_hdr = getenv("CARDINAL_PREFER_HDR");
    if (env_hdr) {
        if (env_hdr[0] == '1' || env_hdr[0] == 'T' || env_hdr[0] == 't' || env_hdr[0] == 'Y' ||
            env_hdr[0] == 'y') {
            prefer_hdr = true;
        }
    }

    int best_score = -1;
    VkSurfaceFormatKHR best = formats[0];

    for (uint32_t i = 0; i < count; i++) {
        const VkSurfaceFormatKHR* f = &formats[i];
        int score = 0;

        // Color space preference
        if (prefer_hdr) {
            if (f->colorSpace == VK_COLOR_SPACE_HDR10_ST2084_EXT ||
                f->colorSpace == VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT ||
                f->colorSpace == VK_COLOR_SPACE_BT2020_LINEAR_EXT) {
                score += 50;
            }
        }
        // Prefer standard sRGB nonlinear by default
        if (f->colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            score += 10;
        }

        // Format preference ordering
        switch (f->format) {
            case VK_FORMAT_R16G16B16A16_SFLOAT:
                if (prefer_hdr)
                    score += 40; // High precision HDR only when requested
                break;
            case VK_FORMAT_A2B10G10R10_UNORM_PACK32:
                if (prefer_hdr)
                    score += 30; // 10-bit color when requested
                break;
            case VK_FORMAT_B8G8R8A8_UNORM:
                score += 20; // Common SRGB
                break;
            case VK_FORMAT_R8G8B8A8_UNORM:
                score += 15; // Acceptable fallback
                break;
            default:
                break;
        }

        if (score > best_score) {
            best_score = score;
            best = *f;
        }
    }

    return best;
}

/**
 * @brief Selects the preferred present mode.
 * @param modes Array of available present modes.
 * @param count Number of modes.
 * @return Selected present mode.
 *
 * @todo Support variable refresh rate modes if available (VK_KHR_variable_refresh).
 */
static VkPresentModeKHR choose_present_mode(const VkPresentModeKHR* modes, uint32_t count) {
    for (uint32_t i = 0; i < count; i++)
        if (modes[i] == VK_PRESENT_MODE_MAILBOX_KHR)
            return VK_PRESENT_MODE_MAILBOX_KHR;
    return VK_PRESENT_MODE_FIFO_KHR;
}

/**
 * @brief Waits for the device to be idle before creating the swapchain.
 */
static bool wait_device_idle_for_swapchain(VulkanState* s) {
    uint64_t t_idle0 = get_current_time_ms();
    VkResult res = vkDeviceWaitIdle(s->context.device);
    uint64_t dt = get_current_time_ms() - t_idle0;

    if (dt > 200) {
        CARDINAL_LOG_WARN("[WATCHDOG] Swapchain create: device wait idle duration %llu ms",
                          (unsigned long long)dt);
    }

    if (res == VK_ERROR_DEVICE_LOST) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Device lost during swapchain creation");
        s->recovery.device_lost = true;
        return false;
    } else if (res != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Device not ready for swapchain creation: %d", res);
        return false;
    }
    return true;
}

/**
 * @brief Retrieves surface capabilities, formats, and present modes.
 */
static bool get_surface_details(VulkanState* s, VkSurfaceCapabilitiesKHR* caps,
                                VkSurfaceFormatKHR* out_fmt, VkPresentModeKHR* out_mode) {
    if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(s->context.physical_device, s->context.surface,
                                                  caps) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get surface capabilities");
        return false;
    }

    if (caps->minImageCount == 0 || caps->maxImageExtent.width == 0 ||
        caps->maxImageExtent.height == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid surface capabilities detected");
        return false;
    }

    uint32_t count = 0;
    if (vkGetPhysicalDeviceSurfaceFormatsKHR(s->context.physical_device, s->context.surface, &count,
                                             NULL) != VK_SUCCESS ||
        count == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get surface formats");
        return false;
    }
    VkSurfaceFormatKHR* fmts = malloc(sizeof(VkSurfaceFormatKHR) * count);
    if (!fmts || vkGetPhysicalDeviceSurfaceFormatsKHR(
                     s->context.physical_device, s->context.surface, &count, fmts) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to retrieve surface formats");
        free(fmts);
        return false;
    }
    *out_fmt = choose_surface_format(fmts, count);
    free(fmts);

    if (vkGetPhysicalDeviceSurfacePresentModesKHR(s->context.physical_device, s->context.surface,
                                                  &count, NULL) != VK_SUCCESS ||
        count == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get present modes");
        return false;
    }
    VkPresentModeKHR* modes = malloc(sizeof(VkPresentModeKHR) * count);
    if (!modes ||
        vkGetPhysicalDeviceSurfacePresentModesKHR(s->context.physical_device, s->context.surface,
                                                  &count, modes) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to retrieve present modes");
        free(modes);
        return false;
    }
    *out_mode = choose_present_mode(modes, count);
    free(modes);

    return true;
}

/**
 * @brief Selects the swapchain extent based on window size and capabilities.
 */
static VkExtent2D select_swapchain_extent(VulkanState* s, const VkSurfaceCapabilitiesKHR* caps) {
    if (caps->currentExtent.width != UINT32_MAX) {
        return caps->currentExtent;
    }

    VkExtent2D extent = {800, 600};
    if (s->recovery.window && s->recovery.window->handle) {
        int w, h;
        glfwGetFramebufferSize((GLFWwindow*)s->recovery.window->handle, &w, &h);
        extent.width = (uint32_t)w;
        extent.height = (uint32_t)h;
    } else if (s->swapchain.window_resize_pending && s->swapchain.pending_width > 0) {
        extent.width = s->swapchain.pending_width;
        extent.height = s->swapchain.pending_height;
    }

    if (extent.width < caps->minImageExtent.width)
        extent.width = caps->minImageExtent.width;
    if (extent.width > caps->maxImageExtent.width)
        extent.width = caps->maxImageExtent.width;
    if (extent.height < caps->minImageExtent.height)
        extent.height = caps->minImageExtent.height;
    if (extent.height > caps->maxImageExtent.height)
        extent.height = caps->maxImageExtent.height;

    return extent;
}

/**
 * @brief Creates the Vulkan swapchain object.
 */
static bool create_swapchain_object(VulkanState* s, const VkSurfaceCapabilitiesKHR* caps,
                                    VkSurfaceFormatKHR fmt, VkPresentModeKHR mode,
                                    VkExtent2D extent) {
    uint32_t image_count = caps->minImageCount + 1;
    if (caps->maxImageCount > 0 && image_count > caps->maxImageCount)
        image_count = caps->maxImageCount;

    CARDINAL_LOG_INFO("[SWAPCHAIN] Creating swapchain: %ux%u, %u images, format %d", extent.width,
                      extent.height, image_count, fmt.format);

    VkSwapchainCreateInfoKHR sci = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
                                    .surface = s->context.surface,
                                    .minImageCount = image_count,
                                    .imageFormat = fmt.format,
                                    .imageColorSpace = fmt.colorSpace,
                                    .imageExtent = extent,
                                    .imageArrayLayers = 1,
                                    .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                                    .preTransform = caps->currentTransform,
                                    .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
                                    .presentMode = mode,
                                    .clipped = VK_TRUE};

    if (s->context.graphics_queue_family != s->context.present_queue_family) {
        uint32_t indices[] = {s->context.graphics_queue_family, s->context.present_queue_family};
        sci.imageSharingMode = VK_SHARING_MODE_CONCURRENT;
        sci.queueFamilyIndexCount = 2;
        sci.pQueueFamilyIndices = indices;
    } else {
        sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    }

    VkResult res = vkCreateSwapchainKHR(s->context.device, &sci, NULL, &s->swapchain.handle);
    if (res != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to create swapchain: %d", res);
        if (res == VK_ERROR_DEVICE_LOST)
            s->recovery.device_lost = true;
        return false;
    }

    s->swapchain.extent = extent;
    s->swapchain.format = fmt.format;
    return true;
}

/**
 * @brief Retrieves the images from the created swapchain.
 */
static bool retrieve_swapchain_images(VulkanState* s) {
    if (vkGetSwapchainImagesKHR(s->context.device, s->swapchain.handle, &s->swapchain.image_count,
                                NULL) != VK_SUCCESS ||
        s->swapchain.image_count == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get image count");
        return false;
    }

    s->swapchain.images = malloc(sizeof(VkImage) * s->swapchain.image_count);
    if (!s->swapchain.images ||
        vkGetSwapchainImagesKHR(s->context.device, s->swapchain.handle, &s->swapchain.image_count,
                                s->swapchain.images) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get images");
        return false;
    }
    return true;
}

/**
 * @brief Creates image views for the swapchain images.
 */
static bool create_swapchain_image_views(VulkanState* s) {
    s->swapchain.image_views = malloc(sizeof(VkImageView) * s->swapchain.image_count);
    if (!s->swapchain.image_views)
        return false;

    for (uint32_t i = 0; i < s->swapchain.image_count; i++)
        s->swapchain.image_views[i] = VK_NULL_HANDLE;

    for (uint32_t i = 0; i < s->swapchain.image_count; i++) {
        VkImageViewCreateInfo iv = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = s->swapchain.images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = s->swapchain.format,
            .subresourceRange = {
                                 .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1}
        };

        if (vkCreateImageView(s->context.device, &iv, NULL, &s->swapchain.image_views[i]) !=
            VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to create image view %u", i);
            for (uint32_t j = 0; j < i; j++)
                vkDestroyImageView(s->context.device, s->swapchain.image_views[j], NULL);
            free(s->swapchain.image_views);
            s->swapchain.image_views = NULL;
            return false;
        }
    }
    return true;
}

/**
 * @brief Creates the Vulkan swapchain.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 *
 * @todo Improve extent selection to handle window resizes dynamically.
 * @todo Add support for additional image usage flags for compute operations.
 */
bool vk_create_swapchain(VulkanState* s) {
    if (!s || !s->context.device || !s->context.physical_device || !s->context.surface) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid VulkanState or missing required components");
        return false;
    }

    if (!wait_device_idle_for_swapchain(s))
        return false;

    VkSurfaceCapabilitiesKHR caps;
    VkSurfaceFormatKHR fmt;
    VkPresentModeKHR mode;
    if (!get_surface_details(s, &caps, &fmt, &mode))
        return false;

    VkExtent2D extent = select_swapchain_extent(s, &caps);
    if (extent.width == 0 || extent.height == 0) {
        CARDINAL_LOG_WARN(
            "[SWAPCHAIN] Invalid swapchain extent: %ux%u (minimized?), skipping creation",
            extent.width, extent.height);
        return false;
    }

    if (!create_swapchain_object(s, &caps, fmt, mode, extent))
        return false;

    if (!retrieve_swapchain_images(s)) {
        vkDestroySwapchainKHR(s->context.device, s->swapchain.handle, NULL);
        s->swapchain.handle = VK_NULL_HANDLE;
        return false;
    }

    if (!create_swapchain_image_views(s)) {
        free(s->swapchain.images);
        s->swapchain.images = NULL;
        vkDestroySwapchainKHR(s->context.device, s->swapchain.handle, NULL);
        s->swapchain.handle = VK_NULL_HANDLE;
        return false;
    }

    // Initialize swapchain optimization state on successful creation
    s->swapchain.recreation_pending = false;
    s->swapchain.last_recreation_time = get_current_time_ms();
    s->swapchain.recreation_count++;
    s->swapchain.consecutive_recreation_failures = 0;
    s->swapchain.frame_pacing_enabled = true; // Enable frame pacing by default

    CARDINAL_LOG_INFO("[SWAPCHAIN] Successfully created swapchain with %u images (%ux%u)",
                      s->swapchain.image_count, s->swapchain.extent.width,
                      s->swapchain.extent.height);
    return true;
}

/**
 * @brief Destroys the swapchain and associated resources.
 * @param s Vulkan state.
 *
 * @todo Ensure all dependent resources are properly cleaned up before destruction.
 */
void vk_destroy_swapchain(VulkanState* s) {
    if (!s)
        return;
    if (s->swapchain.image_views) {
        for (uint32_t i = 0; i < s->swapchain.image_count; i++) {
            if (s->swapchain.image_views[i] != VK_NULL_HANDLE) {
                vkDestroyImageView(s->context.device, s->swapchain.image_views[i], NULL);
            }
        }
        free(s->swapchain.image_views);
        s->swapchain.image_views = NULL;
    }
    // No framebuffers to destroy when using dynamic rendering
    if (s->swapchain.images) {
        free(s->swapchain.images);
        s->swapchain.images = NULL;
    }
    if (s->swapchain.handle != VK_NULL_HANDLE) {
        vkDestroySwapchainKHR(s->context.device, s->swapchain.handle, NULL);
        s->swapchain.handle = VK_NULL_HANDLE;
    }
}

/**
 * @brief Backup state of the swapchain before recreation.
 */
typedef struct {
    VkSwapchainKHR handle;
    VkImage* images;
    VkImageView* image_views;
    uint32_t image_count;
    VkExtent2D extent;
    VkFormat format;
    bool* layout_initialized;
} SwapchainBackupState;

/**
 * @brief Backs up the current swapchain state and clears it from VulkanState.
 */
static void backup_swapchain_state(VulkanState* s, SwapchainBackupState* backup) {
    backup->handle = s->swapchain.handle;
    backup->images = s->swapchain.images;
    backup->image_views = s->swapchain.image_views;
    backup->image_count = s->swapchain.image_count;
    backup->extent = s->swapchain.extent;
    backup->format = s->swapchain.format;
    backup->layout_initialized = s->swapchain.image_layout_initialized;

    s->swapchain.handle = VK_NULL_HANDLE;
    s->swapchain.images = NULL;
    s->swapchain.image_views = NULL;
    s->swapchain.image_count = 0;
    s->swapchain.image_layout_initialized = NULL;
}

/**
 * @brief Restores the swapchain state from backup.
 */
static void restore_swapchain_state(VulkanState* s, SwapchainBackupState* backup) {
    s->swapchain.handle = backup->handle;
    s->swapchain.images = backup->images;
    s->swapchain.image_views = backup->image_views;
    s->swapchain.image_count = backup->image_count;
    s->swapchain.extent = backup->extent;
    s->swapchain.format = backup->format;
    s->swapchain.image_layout_initialized = backup->layout_initialized;
}

/**
 * @brief Handles cleanup and state restoration upon recreation failure.
 */
static bool handle_recreation_failure(VulkanState* s, SwapchainBackupState* old_state) {
    CARDINAL_LOG_ERROR("[SWAPCHAIN] Recreation failed");
    s->swapchain.consecutive_recreation_failures++;

    // Cleanup new swapchain if it exists
    if (s->swapchain.handle != VK_NULL_HANDLE) {
        vk_destroy_swapchain(s);
    }
    if (s->swapchain.image_layout_initialized) {
        free(s->swapchain.image_layout_initialized);
        s->swapchain.image_layout_initialized = NULL;
    }

    // Restore basic state
    s->swapchain.extent = old_state->extent;
    s->swapchain.format = old_state->format;

    // Notify application of recreation failure
    if (s->recovery.device_loss_callback) {
        s->recovery.device_loss_callback(s->recovery.callback_user_data);
    }

    return false;
}

/**
 * @brief Destroys the backed-up resources.
 */
static void destroy_backup_resources(VulkanState* s, SwapchainBackupState* backup) {
    if (backup->image_views) {
        for (uint32_t i = 0; i < backup->image_count; i++) {
            if (backup->image_views[i] != VK_NULL_HANDLE)
                vkDestroyImageView(s->context.device, backup->image_views[i], NULL);
        }
        free(backup->image_views);
    }
    if (backup->images)
        free(backup->images);
    if (backup->handle != VK_NULL_HANDLE)
        vkDestroySwapchainKHR(s->context.device, backup->handle, NULL);
    if (backup->layout_initialized)
        free(backup->layout_initialized);
}

/**
 * @brief Logic for recreating the mesh shader pipeline.
 */
static bool recreate_mesh_shader_pipeline_logic(VulkanState* s) {
    const char* base = getenv("CARDINAL_SHADERS_DIR");
    if (!base || base[0] == '\0')
        base = "assets/shaders";

    char mesh_path[512], task_path[512], frag_path[512];
    snprintf(mesh_path, sizeof(mesh_path), "%s/mesh.mesh.spv", base);
    snprintf(task_path, sizeof(task_path), "%s/task.task.spv", base);
    snprintf(frag_path, sizeof(frag_path), "%s/mesh.frag.spv", base);

    MeshShaderPipelineConfig config = {.mesh_shader_path = mesh_path,
                                       .task_shader_path = task_path,
                                       .fragment_shader_path = frag_path,
                                       .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                                       .polygon_mode = VK_POLYGON_MODE_FILL,
                                       .cull_mode = VK_CULL_MODE_BACK_BIT,
                                       .front_face = VK_FRONT_FACE_COUNTER_CLOCKWISE,
                                       .depth_test_enable = true,
                                       .depth_write_enable = true,
                                       .depth_compare_op = VK_COMPARE_OP_LESS,
                                       .blend_enable = false,
                                       .src_color_blend_factor = VK_BLEND_FACTOR_ONE,
                                       .dst_color_blend_factor = VK_BLEND_FACTOR_ZERO,
                                       .color_blend_op = VK_BLEND_OP_ADD,
                                       .max_vertices_per_meshlet = 64,
                                       .max_primitives_per_meshlet = 126};

    if (!vk_mesh_shader_create_pipeline(s, &config, s->swapchain.format, s->swapchain.depth_format,
                                        &s->pipelines.mesh_shader_pipeline)) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to recreate mesh shader pipeline");
        return false;
    }
    CARDINAL_LOG_INFO("[SWAPCHAIN] Mesh shader pipeline recreated successfully");
    return true;
}

/**
 * @brief Recreates the swapchain for window resize or other changes.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 *
 * @todo Optimize recreation to minimize frame drops during resize.
 * @todo Integrate with window event system for automatic recreation.
 */
bool vk_recreate_swapchain(VulkanState* s) {
    if (!s) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid VulkanState for recreation");
        return false;
    }

    if (!s->context.device) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] No valid device for swapchain recreation");
        return false;
    }

    // Check if we should throttle recreation attempts
    if (should_throttle_recreation(s)) {
        return false;
    }

    CARDINAL_LOG_INFO("[SWAPCHAIN] Starting swapchain recreation");

    // Update recreation tracking
    s->swapchain.last_recreation_time = get_current_time_ms();

    // Store original state for potential rollback
    SwapchainBackupState backup;
    backup_swapchain_state(s, &backup);

    uint64_t t_idle0 = get_current_time_ms();
    VkResult idle_result = vkDeviceWaitIdle(s->context.device);
    uint64_t idle_dt = get_current_time_ms() - t_idle0;
    if (idle_dt > 200) {
        CARDINAL_LOG_WARN("[WATCHDOG] Swapchain recreate: device wait idle duration %llu ms",
                          (unsigned long long)idle_dt);
    }
    if (idle_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to wait for device idle: %d", idle_result);
        if (idle_result == VK_ERROR_DEVICE_LOST) {
            CARDINAL_LOG_ERROR("[SWAPCHAIN] Device lost during recreation wait");
            s->recovery.device_lost = true;
        }
        // Restore old state for cleanup
        restore_swapchain_state(s, &backup);
        return false;
    }

    // Destroy old pipeline and swapchain resources
    vk_destroy_pipeline(s);

    // Destroy mesh shader pipeline during swapchain recreation to prevent descriptor set validation
    // errors
    if (s->pipelines.use_mesh_shader_pipeline) {
        vk_mesh_shader_destroy_pipeline(s, &s->pipelines.mesh_shader_pipeline);
        // Note: mesh shader pipeline will be recreated later if needed
    }

    destroy_backup_resources(s, &backup);

    // Recreate swapchain
    if (!vk_create_swapchain(s))
        return handle_recreation_failure(s, &backup);

    // Recreate per-image initialization tracking for new swapchain image count
    if (!vk_recreate_images_in_flight(s))
        return handle_recreation_failure(s, &backup);

    // Recreate pipeline with new dimensions
    if (!vk_create_pipeline(s))
        return handle_recreation_failure(s, &backup);

    s->swapchain.depth_layout_initialized = false;

    // Recreate simple pipelines (UV and wireframe)
    if (!vk_create_simple_pipelines(s))
        return handle_recreation_failure(s, &backup);

    // Recreate mesh shader pipeline if it was previously enabled
    if (s->pipelines.use_mesh_shader_pipeline && s->context.supports_mesh_shader) {
        if (!recreate_mesh_shader_pipeline_logic(s))
            return handle_recreation_failure(s, &backup);
    }

    // Reset failure counter on successful recreation
    s->swapchain.consecutive_recreation_failures = 0;

    CARDINAL_LOG_INFO("[SWAPCHAIN] Successfully recreated swapchain: %ux%u -> %ux%u",
                      backup.extent.width, backup.extent.height, s->swapchain.extent.width,
                      s->swapchain.extent.height);

    // Notify application of successful recreation
    if (s->recovery.recovery_complete_callback) {
        s->recovery.recovery_complete_callback(s->recovery.callback_user_data, true);
    }

    return true;
}
