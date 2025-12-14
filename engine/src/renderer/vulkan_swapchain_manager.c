#include "vulkan_swapchain_manager.h"
#include "cardinal/core/log.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

// Platform-specific includes for timing
#ifdef _WIN32
    #include <windows.h>
#else
    #include <sys/time.h>
    #include <time.h>
#endif

/**
 * @brief Gets current time in milliseconds.
 */
static uint64_t get_current_time_ms(void) {
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
#endif
}

/**
 * @brief Helper function to create image views for swapchain images.
 */
static bool create_image_views(VulkanSwapchainManager* manager) {
    manager->imageViews = malloc(manager->imageCount * sizeof(VkImageView));
    if (!manager->imageViews) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to allocate memory for image views");
        return false;
    }

    // Initialize all image views to VK_NULL_HANDLE
    for (uint32_t i = 0; i < manager->imageCount; i++) {
        manager->imageViews[i] = VK_NULL_HANDLE;
    }

    // Create image views
    for (uint32_t i = 0; i < manager->imageCount; i++) {
        VkImageViewCreateInfo createInfo = {0};
        createInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        createInfo.image = manager->images[i];
        createInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
        createInfo.format = manager->format;
        createInfo.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        createInfo.subresourceRange.baseMipLevel = 0;
        createInfo.subresourceRange.levelCount = 1;
        createInfo.subresourceRange.baseArrayLayer = 0;
        createInfo.subresourceRange.layerCount = 1;

        VkResult result =
            vkCreateImageView(manager->device, &createInfo, NULL, &manager->imageViews[i]);
        if (result != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to create image view %u: %d", i, result);

            // Clean up previously created image views
            for (uint32_t j = 0; j < i; j++) {
                if (manager->imageViews[j] != VK_NULL_HANDLE) {
                    vkDestroyImageView(manager->device, manager->imageViews[j], NULL);
                }
            }
            free(manager->imageViews);
            manager->imageViews = NULL;
            return false;
        }
    }

    CARDINAL_LOG_DEBUG("[SWAPCHAIN] Created %u image views", manager->imageCount);
    return true;
}

/**
 * @brief Helper function to destroy image views.
 */
static void destroy_image_views(VulkanSwapchainManager* manager) {
    if (manager->imageViews) {
        for (uint32_t i = 0; i < manager->imageCount; i++) {
            if (manager->imageViews[i] != VK_NULL_HANDLE) {
                vkDestroyImageView(manager->device, manager->imageViews[i], NULL);
            }
        }
        free(manager->imageViews);
        manager->imageViews = NULL;
    }
}

/**
 * @brief Helper function to create the actual swapchain.
 */
static bool create_swapchain_internal(VulkanSwapchainManager* manager,
                                      const VulkanSwapchainCreateInfo* createInfo) {
    // Query surface support
    VulkanSurfaceSupport support = {0};
    if (!vk_swapchain_query_surface_support(manager->physicalDevice, manager->surface, &support)) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to query surface support");
        return false;
    }

    // Choose surface format
    VkSurfaceFormatKHR surfaceFormat = vk_swapchain_choose_surface_format(
        support.formats, support.formatCount, createInfo->preferredFormat,
        createInfo->preferredColorSpace);

    // Choose present mode
    VkPresentModeKHR presentMode = vk_swapchain_choose_present_mode(
        support.presentModes, support.presentModeCount, createInfo->preferredPresentMode);

    // Choose extent
    VkExtent2D extent = vk_swapchain_choose_extent(&support.capabilities, createInfo->windowExtent);

    // Validate extent
    if (extent.width == 0 || extent.height == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid swapchain extent: %ux%u", extent.width,
                           extent.height);
        vk_swapchain_free_surface_support(&support);
        return false;
    }

    // Choose image count
    uint32_t imageCount = createInfo->preferredImageCount;
    if (imageCount == 0) {
        imageCount = support.capabilities.minImageCount + 1;
        if (support.capabilities.maxImageCount > 0 &&
            imageCount > support.capabilities.maxImageCount) {
            imageCount = support.capabilities.maxImageCount;
        }
    }

    // Clamp image count to supported range
    if (imageCount < support.capabilities.minImageCount) {
        imageCount = support.capabilities.minImageCount;
    }
    if (support.capabilities.maxImageCount > 0 && imageCount > support.capabilities.maxImageCount) {
        imageCount = support.capabilities.maxImageCount;
    }

    CARDINAL_LOG_INFO("[SWAPCHAIN] Creating swapchain: %ux%u, %u images, format %d", extent.width,
                      extent.height, imageCount, surfaceFormat.format);

    // Create swapchain
    VkSwapchainCreateInfoKHR swapchainCreateInfo = {0};
    swapchainCreateInfo.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    swapchainCreateInfo.surface = manager->surface;
    swapchainCreateInfo.minImageCount = imageCount;
    swapchainCreateInfo.imageFormat = surfaceFormat.format;
    swapchainCreateInfo.imageColorSpace = surfaceFormat.colorSpace;
    swapchainCreateInfo.imageExtent = extent;
    swapchainCreateInfo.imageArrayLayers = 1;
    swapchainCreateInfo.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    swapchainCreateInfo.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    swapchainCreateInfo.queueFamilyIndexCount = 0;
    swapchainCreateInfo.pQueueFamilyIndices = NULL;
    swapchainCreateInfo.preTransform = support.capabilities.currentTransform;
    swapchainCreateInfo.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    swapchainCreateInfo.presentMode = presentMode;
    swapchainCreateInfo.clipped = VK_TRUE;
    swapchainCreateInfo.oldSwapchain = createInfo->oldSwapchain;

    VkResult result =
        vkCreateSwapchainKHR(manager->device, &swapchainCreateInfo, NULL, &manager->swapchain);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to create swapchain: %d", result);
        vk_swapchain_free_surface_support(&support);
        return false;
    }

    // Store swapchain properties
    manager->format = surfaceFormat.format;
    manager->colorSpace = surfaceFormat.colorSpace;
    manager->extent = extent;
    manager->presentMode = presentMode;

    // Get swapchain images
    result =
        vkGetSwapchainImagesKHR(manager->device, manager->swapchain, &manager->imageCount, NULL);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get swapchain image count: %d", result);
        vkDestroySwapchainKHR(manager->device, manager->swapchain, NULL);
        manager->swapchain = VK_NULL_HANDLE;
        vk_swapchain_free_surface_support(&support);
        return false;
    }

    if (manager->imageCount == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Swapchain has no images");
        vkDestroySwapchainKHR(manager->device, manager->swapchain, NULL);
        manager->swapchain = VK_NULL_HANDLE;
        vk_swapchain_free_surface_support(&support);
        return false;
    }

    // Allocate images array
    manager->images = malloc(manager->imageCount * sizeof(VkImage));
    if (!manager->images) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to allocate memory for swapchain images");
        vkDestroySwapchainKHR(manager->device, manager->swapchain, NULL);
        manager->swapchain = VK_NULL_HANDLE;
        vk_swapchain_free_surface_support(&support);
        return false;
    }

    // Get swapchain images
    result = vkGetSwapchainImagesKHR(manager->device, manager->swapchain, &manager->imageCount,
                                     manager->images);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to retrieve swapchain images: %d", result);
        free(manager->images);
        manager->images = NULL;
        vkDestroySwapchainKHR(manager->device, manager->swapchain, NULL);
        manager->swapchain = VK_NULL_HANDLE;
        vk_swapchain_free_surface_support(&support);
        return false;
    }

    // Create image views
    if (!create_image_views(manager)) {
        free(manager->images);
        manager->images = NULL;
        vkDestroySwapchainKHR(manager->device, manager->swapchain, NULL);
        manager->swapchain = VK_NULL_HANDLE;
        vk_swapchain_free_surface_support(&support);
        return false;
    }

    // Update recreation tracking
    manager->recreationPending = false;
    manager->lastRecreationTime = get_current_time_ms();
    manager->recreationCount++;

    vk_swapchain_free_surface_support(&support);

    CARDINAL_LOG_INFO("[SWAPCHAIN] Successfully created swapchain with %u images (%ux%u)",
                      manager->imageCount, manager->extent.width, manager->extent.height);
    return true;
}

bool vk_swapchain_manager_create(VulkanSwapchainManager* manager,
                                 const VulkanSwapchainCreateInfo* createInfo) {
    if (!manager || !createInfo) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid parameters for swapchain manager creation");
        return false;
    }

    if (!createInfo->device || !createInfo->physicalDevice || !createInfo->surface) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid Vulkan objects in create info");
        return false;
    }

    memset(manager, 0, sizeof(VulkanSwapchainManager));

    manager->device = createInfo->device;
    manager->physicalDevice = createInfo->physicalDevice;
    manager->surface = createInfo->surface;

    // Create the swapchain
    if (!create_swapchain_internal(manager, createInfo)) {
        return false;
    }

    manager->initialized = true;

    CARDINAL_LOG_INFO("[SWAPCHAIN] Swapchain manager created successfully");
    return true;
}

void vk_swapchain_manager_destroy(VulkanSwapchainManager* manager) {
    if (!manager || !manager->initialized) {
        return;
    }

    // Destroy image views
    destroy_image_views(manager);

    // Free images array
    if (manager->images) {
        free(manager->images);
        manager->images = NULL;
    }

    // Destroy swapchain
    if (manager->swapchain != VK_NULL_HANDLE) {
        vkDestroySwapchainKHR(manager->device, manager->swapchain, NULL);
        manager->swapchain = VK_NULL_HANDLE;
    }

    memset(manager, 0, sizeof(VulkanSwapchainManager));

    CARDINAL_LOG_DEBUG("[SWAPCHAIN] Swapchain manager destroyed");
}

bool vk_swapchain_manager_recreate(VulkanSwapchainManager* manager, VkExtent2D newExtent) {
    if (!manager || !manager->initialized) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Invalid manager for recreation");
        return false;
    }

    if (!manager->device) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] No valid device for swapchain recreation");
        return false;
    }

    CARDINAL_LOG_INFO("[SWAPCHAIN] Starting swapchain recreation");

    // Wait for device to be idle
    VkResult idleResult = vkDeviceWaitIdle(manager->device);
    if (idleResult == VK_ERROR_DEVICE_LOST) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Device lost during recreation wait");
        return false;
    }
    if (idleResult != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to wait for device idle: %d", idleResult);
        return false;
    }

    // Store old swapchain for recreation
    VkSwapchainKHR oldSwapchain = manager->swapchain;
    VkImage* oldImages = manager->images;
    VkImageView* oldImageViews = manager->imageViews;
    uint32_t oldImageCount = manager->imageCount;
    VkExtent2D oldExtent = manager->extent;
    VkFormat oldFormat = manager->format;

    // Clear current state
    manager->swapchain = VK_NULL_HANDLE;
    manager->images = NULL;
    manager->imageViews = NULL;
    manager->imageCount = 0;

    // Create new swapchain
    VulkanSwapchainCreateInfo createInfo = {0};
    createInfo.device = manager->device;
    createInfo.physicalDevice = manager->physicalDevice;
    createInfo.surface = manager->surface;
    createInfo.preferredImageCount = 0; // Use automatic
    createInfo.preferredFormat = oldFormat;
    createInfo.preferredColorSpace = manager->colorSpace;
    createInfo.preferredPresentMode = manager->presentMode;
    createInfo.windowExtent = newExtent;
    createInfo.oldSwapchain = oldSwapchain;

    if (!create_swapchain_internal(manager, &createInfo)) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to recreate swapchain");

        // Restore old state
        manager->swapchain = oldSwapchain;
        manager->images = oldImages;
        manager->imageViews = oldImageViews;
        manager->imageCount = oldImageCount;
        manager->extent = oldExtent;
        manager->format = oldFormat;
        return false;
    }

    // Clean up old resources
    if (oldImageViews) {
        for (uint32_t i = 0; i < oldImageCount; i++) {
            if (oldImageViews[i] != VK_NULL_HANDLE) {
                vkDestroyImageView(manager->device, oldImageViews[i], NULL);
            }
        }
        free(oldImageViews);
    }

    if (oldImages) {
        free(oldImages);
    }

    if (oldSwapchain != VK_NULL_HANDLE) {
        vkDestroySwapchainKHR(manager->device, oldSwapchain, NULL);
    }

    CARDINAL_LOG_INFO("[SWAPCHAIN] Successfully recreated swapchain: %ux%u -> %ux%u",
                      oldExtent.width, oldExtent.height, manager->extent.width,
                      manager->extent.height);
    return true;
}

VkResult vk_swapchain_manager_acquire_image(VulkanSwapchainManager* manager, uint64_t timeout,
                                            VkSemaphore semaphore, VkFence fence,
                                            uint32_t* imageIndex) {
    if (!manager || !manager->initialized || !imageIndex) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    if (manager->swapchain == VK_NULL_HANDLE) {
        return VK_ERROR_SURFACE_LOST_KHR;
    }

    return vkAcquireNextImageKHR(manager->device, manager->swapchain, timeout, semaphore, fence,
                                 imageIndex);
}

VkResult vk_swapchain_manager_present(VulkanSwapchainManager* manager, VkQueue presentQueue,
                                      uint32_t imageIndex, uint32_t waitSemaphoreCount,
                                      const VkSemaphore* waitSemaphores) {
    if (!manager || !manager->initialized || !presentQueue) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    if (manager->swapchain == VK_NULL_HANDLE) {
        return VK_ERROR_SURFACE_LOST_KHR;
    }

    VkPresentInfoKHR presentInfo = {0};
    presentInfo.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    presentInfo.waitSemaphoreCount = waitSemaphoreCount;
    presentInfo.pWaitSemaphores = waitSemaphores;
    presentInfo.swapchainCount = 1;
    presentInfo.pSwapchains = &manager->swapchain;
    presentInfo.pImageIndices = &imageIndex;
    presentInfo.pResults = NULL;

    return vkQueuePresentKHR(presentQueue, &presentInfo);
}

bool vk_swapchain_query_surface_support(VkPhysicalDevice physicalDevice, VkSurfaceKHR surface,
                                        VulkanSurfaceSupport* support) {
    if (!physicalDevice || !surface || !support) {
        return false;
    }

    memset(support, 0, sizeof(VulkanSurfaceSupport));

    // Get surface capabilities
    VkResult result =
        vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &support->capabilities);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get surface capabilities: %d", result);
        return false;
    }

    // Get surface formats
    result =
        vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &support->formatCount, NULL);
    if (result != VK_SUCCESS || support->formatCount == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get surface formats or no formats available: %d",
                           result);
        return false;
    }

    support->formats = malloc(support->formatCount * sizeof(VkSurfaceFormatKHR));
    if (!support->formats) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to allocate memory for surface formats");
        return false;
    }

    result = vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &support->formatCount,
                                                  support->formats);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to retrieve surface formats: %d", result);
        free(support->formats);
        support->formats = NULL;
        return false;
    }

    // Get present modes
    result = vkGetPhysicalDeviceSurfacePresentModesKHR(physicalDevice, surface,
                                                       &support->presentModeCount, NULL);
    if (result != VK_SUCCESS || support->presentModeCount == 0) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to get present modes or no modes available: %d",
                           result);
        free(support->formats);
        support->formats = NULL;
        return false;
    }

    support->presentModes = malloc(support->presentModeCount * sizeof(VkPresentModeKHR));
    if (!support->presentModes) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to allocate memory for present modes");
        free(support->formats);
        support->formats = NULL;
        return false;
    }

    result = vkGetPhysicalDeviceSurfacePresentModesKHR(
        physicalDevice, surface, &support->presentModeCount, support->presentModes);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SWAPCHAIN] Failed to retrieve present modes: %d", result);
        free(support->presentModes);
        support->presentModes = NULL;
        free(support->formats);
        support->formats = NULL;
        return false;
    }

    return true;
}

void vk_swapchain_free_surface_support(VulkanSurfaceSupport* support) {
    if (!support) {
        return;
    }

    if (support->formats) {
        free(support->formats);
        support->formats = NULL;
    }

    if (support->presentModes) {
        free(support->presentModes);
        support->presentModes = NULL;
    }

    support->formatCount = 0;
    support->presentModeCount = 0;
}

VkSurfaceFormatKHR vk_swapchain_choose_surface_format(const VkSurfaceFormatKHR* availableFormats,
                                                      uint32_t formatCount,
                                                      VkFormat preferredFormat,
                                                      VkColorSpaceKHR preferredColorSpace) {
    if (!availableFormats) {
        VkSurfaceFormatKHR defaultFormat = {VK_FORMAT_B8G8R8A8_SRGB,
                                            VK_COLOR_SPACE_SRGB_NONLINEAR_KHR};
        return defaultFormat;
    }
    if (formatCount == 0) {
        return availableFormats[0];
    }

    // If preferred format is specified, look for it
    if (preferredFormat != VK_FORMAT_UNDEFINED) {
        for (uint32_t i = 0; i < formatCount; i++) {
            if (availableFormats[i].format == preferredFormat &&
                availableFormats[i].colorSpace == preferredColorSpace) {
                return availableFormats[i];
            }
        }
    }

    // Look for preferred formats
    VkFormat preferredFormats[] = {VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM,
                                   VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_B8G8R8A8_SRGB};

    for (uint32_t i = 0; i < sizeof(preferredFormats) / sizeof(preferredFormats[0]); i++) {
        for (uint32_t j = 0; j < formatCount; j++) {
            if (availableFormats[j].format == preferredFormats[i] &&
                availableFormats[j].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                return availableFormats[j];
            }
        }
    }

    // Return the first available format as fallback
    return availableFormats[0];
}

VkPresentModeKHR vk_swapchain_choose_present_mode(const VkPresentModeKHR* availableModes,
                                                  uint32_t modeCount,
                                                  VkPresentModeKHR preferredMode) {
    if (!availableModes || modeCount == 0) {
        return VK_PRESENT_MODE_FIFO_KHR; // Always available
    }

    // If preferred mode is specified, look for it
    if (preferredMode != VK_PRESENT_MODE_MAX_ENUM_KHR) {
        for (uint32_t i = 0; i < modeCount; i++) {
            if (availableModes[i] == preferredMode) {
                return preferredMode;
            }
        }
    }

    // Look for preferred modes in order
    VkPresentModeKHR preferredModes[] = {VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_IMMEDIATE_KHR,
                                         VK_PRESENT_MODE_FIFO_RELAXED_KHR,
                                         VK_PRESENT_MODE_FIFO_KHR};

    for (uint32_t i = 0; i < sizeof(preferredModes) / sizeof(preferredModes[0]); i++) {
        for (uint32_t j = 0; j < modeCount; j++) {
            if (availableModes[j] == preferredModes[i]) {
                return preferredModes[i];
            }
        }
    }

    // FIFO is guaranteed to be available
    return VK_PRESENT_MODE_FIFO_KHR;
}

VkExtent2D vk_swapchain_choose_extent(const VkSurfaceCapabilitiesKHR* capabilities,
                                      VkExtent2D windowExtent) {
    if (!capabilities) {
        return windowExtent;
    }

    if (capabilities->currentExtent.width != UINT32_MAX) {
        return capabilities->currentExtent;
    }

    VkExtent2D actualExtent = windowExtent;

    // Clamp to supported range
    if (actualExtent.width < capabilities->minImageExtent.width) {
        actualExtent.width = capabilities->minImageExtent.width;
    }
    if (actualExtent.width > capabilities->maxImageExtent.width) {
        actualExtent.width = capabilities->maxImageExtent.width;
    }

    if (actualExtent.height < capabilities->minImageExtent.height) {
        actualExtent.height = capabilities->minImageExtent.height;
    }
    if (actualExtent.height > capabilities->maxImageExtent.height) {
        actualExtent.height = capabilities->maxImageExtent.height;
    }

    return actualExtent;
}

void vk_swapchain_manager_mark_for_recreation(VulkanSwapchainManager* manager) {
    if (manager && manager->initialized) {
        manager->recreationPending = true;
    }
}

bool vk_swapchain_manager_is_recreation_pending(const VulkanSwapchainManager* manager) {
    return manager && manager->initialized && manager->recreationPending;
}

VkSwapchainKHR vk_swapchain_manager_get_swapchain(const VulkanSwapchainManager* manager) {
    return manager && manager->initialized ? manager->swapchain : VK_NULL_HANDLE;
}

VkFormat vk_swapchain_manager_get_format(const VulkanSwapchainManager* manager) {
    return manager && manager->initialized ? manager->format : VK_FORMAT_UNDEFINED;
}

VkExtent2D vk_swapchain_manager_get_extent(const VulkanSwapchainManager* manager) {
    VkExtent2D extent = {0, 0};
    if (manager && manager->initialized) {
        extent = manager->extent;
    }
    return extent;
}

uint32_t vk_swapchain_manager_get_image_count(const VulkanSwapchainManager* manager) {
    return manager && manager->initialized ? manager->imageCount : 0;
}

const VkImage* vk_swapchain_manager_get_images(const VulkanSwapchainManager* manager) {
    return manager && manager->initialized ? manager->images : NULL;
}

const VkImageView* vk_swapchain_manager_get_image_views(const VulkanSwapchainManager* manager) {
    return manager && manager->initialized ? manager->imageViews : NULL;
}

void vk_swapchain_manager_get_recreation_stats(const VulkanSwapchainManager* manager,
                                               uint32_t* recreationCount,
                                               uint64_t* lastRecreationTime) {
    if (!manager || !manager->initialized) {
        if (recreationCount)
            *recreationCount = 0;
        if (lastRecreationTime)
            *lastRecreationTime = 0;
        return;
    }

    if (recreationCount) {
        *recreationCount = manager->recreationCount;
    }
    if (lastRecreationTime) {
        *lastRecreationTime = manager->lastRecreationTime;
    }
}
