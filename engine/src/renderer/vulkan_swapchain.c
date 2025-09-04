#include "vulkan_state.h"
#include <GLFW/glfw3.h>
#include "cardinal/core/log.h"
#include <cardinal/renderer/vulkan_commands.h>
#include <cardinal/renderer/vulkan_pipeline.h>
#include <cardinal/renderer/vulkan_swapchain.h>
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
    if (!s->frame_pacing_enabled) {
        return false;
    }
    
    uint64_t current_time = get_current_time_ms();
    uint64_t time_since_last = current_time - s->last_swapchain_recreation_time;
    
    // Throttle if less than 100ms since last recreation and we've had multiple failures
    if (time_since_last < 100 && s->consecutive_recreation_failures > 0) {
        return true;
    }
    
    // More aggressive throttling if we've had many consecutive failures
    if (s->consecutive_recreation_failures >= 3 && time_since_last < 500) {
        // Only log this warning once every 1000ms to reduce spam
        static uint64_t last_throttle_log = 0;
        if (current_time - last_throttle_log > 1000) {
            CARDINAL_LOG_WARN("[SWAPCHAIN] Aggressive throttling: %u consecutive failures", 
                             s->consecutive_recreation_failures);
            last_throttle_log = current_time;
        }
        return true;
    }
    
    // Extreme throttling for persistent failures
    if (s->consecutive_recreation_failures >= 6) {
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
    for (uint32_t i = 0; i < count; i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM &&
            formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            return formats[i];
    }
    return formats[0];
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
 * @brief Creates the Vulkan swapchain.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 *
 * @todo Improve extent selection to handle window resizes dynamically.
 * @todo Add support for additional image usage flags for compute operations.
 */
bool vk_create_swapchain(VulkanState* s) {
    if (!s || !s->device || !s->physical_device || !s->surface) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid VulkanState or missing required components");
        return false;
    }

    // Validate device state before proceeding
    VkResult device_status = vkDeviceWaitIdle(s->device);
    if (device_status == VK_ERROR_DEVICE_LOST) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Device lost during swapchain creation");
        s->device_lost = true;
        return false;
    } else if (device_status != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Device not ready for swapchain creation: %d", device_status);
        return false;
    }

    VkSurfaceCapabilitiesKHR caps;
    VkResult caps_result = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(s->physical_device, s->surface, &caps);
    if (caps_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get surface capabilities: %d", caps_result);
        return false;
    }

    // Validate surface capabilities
    if (caps.minImageCount == 0 || caps.maxImageExtent.width == 0 || caps.maxImageExtent.height == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid surface capabilities detected");
        return false;
    }

    uint32_t fmt_count = 0;
    VkResult fmt_result = vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical_device, s->surface, &fmt_count, NULL);
    if (fmt_result != VK_SUCCESS || fmt_count == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get surface formats or no formats available: %d", fmt_result);
        return false;
    }
    
    VkSurfaceFormatKHR* fmts = (VkSurfaceFormatKHR*)malloc(sizeof(VkSurfaceFormatKHR) * fmt_count);
    if (!fmts) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to allocate memory for surface formats");
        return false;
    }
    
    fmt_result = vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical_device, s->surface, &fmt_count, fmts);
    if (fmt_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to retrieve surface formats: %d", fmt_result);
        free(fmts);
        return false;
    }
    VkSurfaceFormatKHR surface_fmt = choose_surface_format(fmts, fmt_count);

    uint32_t pm_count = 0;
    VkResult pm_result = vkGetPhysicalDeviceSurfacePresentModesKHR(s->physical_device, s->surface, &pm_count, NULL);
    if (pm_result != VK_SUCCESS || pm_count == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get present modes or no modes available: %d", pm_result);
        free(fmts);
        return false;
    }
    
    VkPresentModeKHR* pms = (VkPresentModeKHR*)malloc(sizeof(VkPresentModeKHR) * pm_count);
    if (!pms) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to allocate memory for present modes");
        free(fmts);
        return false;
    }
    
    pm_result = vkGetPhysicalDeviceSurfacePresentModesKHR(s->physical_device, s->surface, &pm_count, pms);
    if (pm_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to retrieve present modes: %d", pm_result);
        free(fmts);
        free(pms);
        return false;
    }
    VkPresentModeKHR present_mode = choose_present_mode(pms, pm_count);

    // Determine swapchain extent with validation
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        // Get window size from GLFW if available
        if (s->window) {
            int width, height;
            glfwGetFramebufferSize((GLFWwindow*)s->window, &width, &height);
            extent.width = (uint32_t)width;
            extent.height = (uint32_t)height;
        } else {
            extent.width = 800;
            extent.height = 600;
        }
        
        // Clamp to surface capabilities
        extent.width = (extent.width < caps.minImageExtent.width) ? caps.minImageExtent.width : extent.width;
        extent.width = (extent.width > caps.maxImageExtent.width) ? caps.maxImageExtent.width : extent.width;
        extent.height = (extent.height < caps.minImageExtent.height) ? caps.minImageExtent.height : extent.height;
        extent.height = (extent.height > caps.maxImageExtent.height) ? caps.maxImageExtent.height : extent.height;
    }
    
    // Validate extent
    if (extent.width == 0 || extent.height == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid swapchain extent: %ux%u", extent.width, extent.height);
        free(fmts);
        free(pms);
        return false;
    }

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount)
        image_count = caps.maxImageCount;
        
    CARDINAL_LOG_INFO("[SWAPCHAIN] Creating swapchain: %ux%u, %u images, format %d", 
                      extent.width, extent.height, image_count, surface_fmt.format);

    VkSwapchainCreateInfoKHR sci = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    sci.surface = s->surface;
    sci.minImageCount = image_count;
    sci.imageFormat = surface_fmt.format;
    sci.imageColorSpace = surface_fmt.colorSpace;
    sci.imageExtent = extent;
    sci.imageArrayLayers = 1;
    sci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    // Handle queue sharing when graphics and present families differ
    if (s->graphics_queue_family != s->present_queue_family) {
        uint32_t queue_families[] = {s->graphics_queue_family, s->present_queue_family};
        sci.imageSharingMode = VK_SHARING_MODE_CONCURRENT;
        sci.queueFamilyIndexCount = 2;
        sci.pQueueFamilyIndices = queue_families;
    } else {
        sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    }
    sci.preTransform = caps.currentTransform;
    sci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    sci.presentMode = present_mode;
    sci.clipped = VK_TRUE;

    VkResult create_result = vkCreateSwapchainKHR(s->device, &sci, NULL, &s->swapchain);
    if (create_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to create swapchain: %d", create_result);
        free(fmts);
        free(pms);
        if (create_result == VK_ERROR_DEVICE_LOST) {
            s->device_lost = true;
        }
        return false;
    }

    s->swapchain_extent = extent;
    s->swapchain_format = surface_fmt.format;

    // Get swapchain images with error handling
    VkResult images_result = vkGetSwapchainImagesKHR(s->device, s->swapchain, &s->swapchain_image_count, NULL);
    if (images_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get swapchain image count: %d", images_result);
        vkDestroySwapchainKHR(s->device, s->swapchain, NULL);
        s->swapchain = VK_NULL_HANDLE;
        free(fmts);
        free(pms);
        return false;
    }
    
    if (s->swapchain_image_count == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Swapchain has no images");
        vkDestroySwapchainKHR(s->device, s->swapchain, NULL);
        s->swapchain = VK_NULL_HANDLE;
        free(fmts);
        free(pms);
        return false;
    }
    
    s->swapchain_images = (VkImage*)malloc(sizeof(VkImage) * s->swapchain_image_count);
    if (!s->swapchain_images) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to allocate memory for swapchain images");
        vkDestroySwapchainKHR(s->device, s->swapchain, NULL);
        s->swapchain = VK_NULL_HANDLE;
        free(fmts);
        free(pms);
        return false;
    }
    
    images_result = vkGetSwapchainImagesKHR(s->device, s->swapchain, &s->swapchain_image_count, s->swapchain_images);
    if (images_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to retrieve swapchain images: %d", images_result);
        free(s->swapchain_images);
        s->swapchain_images = NULL;
        vkDestroySwapchainKHR(s->device, s->swapchain, NULL);
        s->swapchain = VK_NULL_HANDLE;
        free(fmts);
        free(pms);
        return false;
    }

    // Create image views with error handling
    s->swapchain_image_views = (VkImageView*)malloc(sizeof(VkImageView) * s->swapchain_image_count);
    if (!s->swapchain_image_views) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to allocate memory for image views");
        free(s->swapchain_images);
        s->swapchain_images = NULL;
        vkDestroySwapchainKHR(s->device, s->swapchain, NULL);
        s->swapchain = VK_NULL_HANDLE;
        free(fmts);
        free(pms);
        return false;
    }
    
    // Initialize all image views to VK_NULL_HANDLE for safe cleanup
    for (uint32_t i = 0; i < s->swapchain_image_count; i++) {
        s->swapchain_image_views[i] = VK_NULL_HANDLE;
    }
    
    for (uint32_t i = 0; i < s->swapchain_image_count; i++) {
        VkImageViewCreateInfo iv = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        iv.image = s->swapchain_images[i];
        iv.viewType = VK_IMAGE_VIEW_TYPE_2D;
        iv.format = s->swapchain_format;
        iv.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        iv.subresourceRange.levelCount = 1;
        iv.subresourceRange.layerCount = 1;
        
        VkResult view_result = vkCreateImageView(s->device, &iv, NULL, &s->swapchain_image_views[i]);
        if (view_result != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to create image view %u: %d", i, view_result);
            
            // Clean up previously created image views
            for (uint32_t j = 0; j < i; j++) {
                if (s->swapchain_image_views[j] != VK_NULL_HANDLE) {
                    vkDestroyImageView(s->device, s->swapchain_image_views[j], NULL);
                }
            }
            free(s->swapchain_image_views);
            s->swapchain_image_views = NULL;
            free(s->swapchain_images);
            s->swapchain_images = NULL;
            vkDestroySwapchainKHR(s->device, s->swapchain, NULL);
            s->swapchain = VK_NULL_HANDLE;
            free(fmts);
            free(pms);
            
            if (view_result == VK_ERROR_DEVICE_LOST) {
                s->device_lost = true;
            }
            return false;
        }
    }

    free(fmts);
    free(pms);
    
    // Initialize swapchain optimization state on successful creation
    s->swapchain_recreation_pending = false;
    s->last_swapchain_recreation_time = get_current_time_ms();
    s->swapchain_recreation_count++;
    s->consecutive_recreation_failures = 0;
    s->frame_pacing_enabled = true; // Enable frame pacing by default
    
    CARDINAL_LOG_INFO("[SWAPCHAIN] Successfully created swapchain with %u images (%ux%u)", 
                      s->swapchain_image_count, s->swapchain_extent.width, s->swapchain_extent.height);
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
    if (s->swapchain_image_views) {
        for (uint32_t i = 0; i < s->swapchain_image_count; i++) {
            if (s->swapchain_image_views[i] != VK_NULL_HANDLE) {
                vkDestroyImageView(s->device, s->swapchain_image_views[i], NULL);
            }
        }
        free(s->swapchain_image_views);
        s->swapchain_image_views = NULL;
    }
    // No framebuffers to destroy when using dynamic rendering
    if (s->swapchain_images) {
        free(s->swapchain_images);
        s->swapchain_images = NULL;
    }
    if (s->swapchain != VK_NULL_HANDLE) {
        vkDestroySwapchainKHR(s->device, s->swapchain, NULL);
        s->swapchain = VK_NULL_HANDLE;
    }
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
    
    if (!s->device) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] No valid device for swapchain recreation");
        return false;
    }

    // Check if we should throttle recreation attempts
    if (should_throttle_recreation(s)) {
        return false;
    }

    CARDINAL_LOG_INFO("[SWAPCHAIN] Starting swapchain recreation");
    
    // Update recreation tracking
    s->last_swapchain_recreation_time = get_current_time_ms();
    
    // Store original state for potential rollback
    VkSwapchainKHR old_swapchain = s->swapchain;
    VkImage* old_images = s->swapchain_images;
    VkImageView* old_image_views = s->swapchain_image_views;
    uint32_t old_image_count = s->swapchain_image_count;
    VkExtent2D old_extent = s->swapchain_extent;
    VkFormat old_format = s->swapchain_format;
    bool* old_layout_initialized = s->swapchain_image_layout_initialized;
    
    // Clear current state to prevent double-free in case of failure
    s->swapchain = VK_NULL_HANDLE;
    s->swapchain_images = NULL;
    s->swapchain_image_views = NULL;
    s->swapchain_image_count = 0;
    s->swapchain_image_layout_initialized = NULL;

    // Wait for device to be idle before recreating
    VkResult idle_result = vkDeviceWaitIdle(s->device);
    if (idle_result == VK_ERROR_DEVICE_LOST) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Device lost during recreation wait");
        s->device_lost = true;
        // Restore old state for cleanup
        s->swapchain = old_swapchain;
        s->swapchain_images = old_images;
        s->swapchain_image_views = old_image_views;
        s->swapchain_image_count = old_image_count;
        s->swapchain_extent = old_extent;
        s->swapchain_format = old_format;
        s->swapchain_image_layout_initialized = old_layout_initialized;
        return false;
    } else if (idle_result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to wait for device idle: %d", idle_result);
        // Restore old state for cleanup
        s->swapchain = old_swapchain;
        s->swapchain_images = old_images;
        s->swapchain_image_views = old_image_views;
        s->swapchain_image_count = old_image_count;
        s->swapchain_extent = old_extent;
        s->swapchain_format = old_format;
        s->swapchain_image_layout_initialized = old_layout_initialized;
        return false;
    }

    // Destroy old pipeline and swapchain resources
    vk_destroy_pipeline(s);
    
    // Clean up old swapchain resources manually since we cleared the state
    if (old_image_views) {
        for (uint32_t i = 0; i < old_image_count; i++) {
            if (old_image_views[i] != VK_NULL_HANDLE) {
                vkDestroyImageView(s->device, old_image_views[i], NULL);
            }
        }
        free(old_image_views);
    }
    if (old_images) {
        free(old_images);
    }
    if (old_swapchain != VK_NULL_HANDLE) {
        vkDestroySwapchainKHR(s->device, old_swapchain, NULL);
    }
    if (old_layout_initialized) {
        free(old_layout_initialized);
    }

    // Recreate swapchain
    if (!vk_create_swapchain(s)) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to recreate swapchain");
        
        // Track consecutive failures
        s->consecutive_recreation_failures++;
        
        // Attempt minimal fallback: restore basic state
        s->swapchain_extent = old_extent;
        s->swapchain_format = old_format;
        
        // Notify application of recreation failure
        if (s->device_loss_callback) {
            s->device_loss_callback(s->recovery_callback_user_data);
        }
        
        return false;
    }

    // Recreate per-image initialization tracking for new swapchain image count
    if (!vk_recreate_images_in_flight(s)) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to recreate images in flight tracking");
        
        // Track consecutive failures
        s->consecutive_recreation_failures++;
        
        // Clean up the newly created swapchain
        vk_destroy_swapchain(s);
        
        // Restore basic state
        s->swapchain_extent = old_extent;
        s->swapchain_format = old_format;
        
        return false;
    }

    // Recreate pipeline with new dimensions
    if (!vk_create_pipeline(s)) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to recreate pipeline");
        
        // Track consecutive failures
        s->consecutive_recreation_failures++;
        
        // Clean up the newly created swapchain and tracking
        if (s->swapchain_image_layout_initialized) {
            free(s->swapchain_image_layout_initialized);
            s->swapchain_image_layout_initialized = NULL;
        }
        vk_destroy_swapchain(s);
        
        // Restore basic state
        s->swapchain_extent = old_extent;
        s->swapchain_format = old_format;
        
        return false;
    }

    // Reset failure counter on successful recreation
    s->consecutive_recreation_failures = 0;
    
    CARDINAL_LOG_INFO("[SWAPCHAIN] Successfully recreated swapchain: %ux%u -> %ux%u", 
                      old_extent.width, old_extent.height, 
                      s->swapchain_extent.width, s->swapchain_extent.height);
    
    // Notify application of successful recreation
    if (s->recovery_complete_callback) {
        s->recovery_complete_callback(s->recovery_callback_user_data, true);
    }
    
    return true;
}
