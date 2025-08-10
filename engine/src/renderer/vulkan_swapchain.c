#include <stdlib.h>
#include <GLFW/glfw3.h>
#include <vulkan/vulkan.h>
#include "vulkan_state.h"
#include "vulkan_swapchain.h"

static VkSurfaceFormatKHR choose_surface_format(const VkSurfaceFormatKHR* formats, uint32_t count) {
    for (uint32_t i=0;i<count;i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM && formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            return formats[i];
    }
    return formats[0];
}

static VkPresentModeKHR choose_present_mode(const VkPresentModeKHR* modes, uint32_t count) {
    for (uint32_t i=0;i<count;i++) if (modes[i] == VK_PRESENT_MODE_MAILBOX_KHR) return VK_PRESENT_MODE_MAILBOX_KHR;
    return VK_PRESENT_MODE_FIFO_KHR;
}

bool vk_create_swapchain(VulkanState* s) {
    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(s->physical_device, s->surface, &caps);

    uint32_t fmt_count=0; vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical_device, s->surface, &fmt_count, NULL);
    VkSurfaceFormatKHR* fmts = (VkSurfaceFormatKHR*)malloc(sizeof(VkSurfaceFormatKHR)*fmt_count);
    vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical_device, s->surface, &fmt_count, fmts);
    VkSurfaceFormatKHR surface_fmt = choose_surface_format(fmts, fmt_count);

    uint32_t pm_count=0; vkGetPhysicalDeviceSurfacePresentModesKHR(s->physical_device, s->surface, &pm_count, NULL);
    VkPresentModeKHR* pms = (VkPresentModeKHR*)malloc(sizeof(VkPresentModeKHR)*pm_count);
    vkGetPhysicalDeviceSurfacePresentModesKHR(s->physical_device, s->surface, &pm_count, pms);
    VkPresentModeKHR present_mode = choose_present_mode(pms, pm_count);

    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        extent.width = 800; extent.height = 600;
    }

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount) image_count = caps.maxImageCount;

    VkSwapchainCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR };
    sci.surface = s->surface;
    sci.minImageCount = image_count;
    sci.imageFormat = surface_fmt.format;
    sci.imageColorSpace = surface_fmt.colorSpace;
    sci.imageExtent = extent;
    sci.imageArrayLayers = 1;
    sci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    sci.preTransform = caps.currentTransform;
    sci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    sci.presentMode = present_mode;
    sci.clipped = VK_TRUE;

    if (vkCreateSwapchainKHR(s->device, &sci, NULL, &s->swapchain) != VK_SUCCESS) return false;

    s->swapchain_extent = extent;
    s->swapchain_format = surface_fmt.format;

    vkGetSwapchainImagesKHR(s->device, s->swapchain, &s->swapchain_image_count, NULL);
    s->swapchain_images = (VkImage*)malloc(sizeof(VkImage)*s->swapchain_image_count);
    vkGetSwapchainImagesKHR(s->device, s->swapchain, &s->swapchain_image_count, s->swapchain_images);

    s->swapchain_image_views = (VkImageView*)malloc(sizeof(VkImageView)*s->swapchain_image_count);
    for (uint32_t i=0;i<s->swapchain_image_count;i++) {
        VkImageViewCreateInfo iv = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
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

void vk_destroy_swapchain(VulkanState* s) {
    if (!s) return;
    for (uint32_t i=0;i<s->swapchain_image_count;i++) {
        if (s->framebuffers) vkDestroyFramebuffer(s->device, s->framebuffers[i], NULL);
        vkDestroyImageView(s->device, s->swapchain_image_views[i], NULL);
    }
    free(s->framebuffers); s->framebuffers = NULL;
    free(s->swapchain_image_views); s->swapchain_image_views = NULL;
    free(s->swapchain_images); s->swapchain_images = NULL;
    if (s->swapchain) vkDestroySwapchainKHR(s->device, s->swapchain, NULL);
    s->swapchain = VK_NULL_HANDLE;
}