#include "vulkan_state.h"
#include <GLFW/glfw3.h>
#include <cardinal/renderer/vulkan_commands.h>
#include <cardinal/renderer/vulkan_pipeline.h>
#include <cardinal/renderer/vulkan_swapchain.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>

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
    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(s->physical_device, s->surface, &caps);

    uint32_t fmt_count = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical_device, s->surface, &fmt_count, NULL);
    VkSurfaceFormatKHR* fmts = (VkSurfaceFormatKHR*)malloc(sizeof(VkSurfaceFormatKHR) * fmt_count);
    vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical_device, s->surface, &fmt_count, fmts);
    VkSurfaceFormatKHR surface_fmt = choose_surface_format(fmts, fmt_count);

    uint32_t pm_count = 0;
    vkGetPhysicalDeviceSurfacePresentModesKHR(s->physical_device, s->surface, &pm_count, NULL);
    VkPresentModeKHR* pms = (VkPresentModeKHR*)malloc(sizeof(VkPresentModeKHR) * pm_count);
    vkGetPhysicalDeviceSurfacePresentModesKHR(s->physical_device, s->surface, &pm_count, pms);
    VkPresentModeKHR present_mode = choose_present_mode(pms, pm_count);

    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        extent.width = 800;
        extent.height = 600;
    }

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount)
        image_count = caps.maxImageCount;

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

    if (vkCreateSwapchainKHR(s->device, &sci, NULL, &s->swapchain) != VK_SUCCESS)
        return false;

    s->swapchain_extent = extent;
    s->swapchain_format = surface_fmt.format;

    vkGetSwapchainImagesKHR(s->device, s->swapchain, &s->swapchain_image_count, NULL);
    s->swapchain_images = (VkImage*)malloc(sizeof(VkImage) * s->swapchain_image_count);
    vkGetSwapchainImagesKHR(s->device, s->swapchain, &s->swapchain_image_count,
                            s->swapchain_images);

    s->swapchain_image_views = (VkImageView*)malloc(sizeof(VkImageView) * s->swapchain_image_count);
    for (uint32_t i = 0; i < s->swapchain_image_count; i++) {
        VkImageViewCreateInfo iv = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        iv.image = s->swapchain_images[i];
        iv.viewType = VK_IMAGE_VIEW_TYPE_2D;
        iv.format = s->swapchain_format;
        iv.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        iv.subresourceRange.levelCount = 1;
        iv.subresourceRange.layerCount = 1;
        vkCreateImageView(s->device, &iv, NULL, &s->swapchain_image_views[i]);
    }

    free(fmts);
    free(pms);
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
    if (!s)
        return false;

    // Wait for device to be idle before recreating
    vkDeviceWaitIdle(s->device);

    // Destroy old pipeline and swapchain resources
    vk_destroy_pipeline(s);
    vk_destroy_swapchain(s);

    // Recreate swapchain
    if (!vk_create_swapchain(s)) {
        return false;
    }

    // Recreate per-image initialization tracking for new swapchain image count
    if (!vk_recreate_images_in_flight(s)) {
        return false;
    }

    // Recreate pipeline with new dimensions
    if (!vk_create_pipeline(s)) {
        return false;
    }

    return true;
}
