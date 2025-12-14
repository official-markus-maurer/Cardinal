#include "cardinal/core/log.h"
#include "vulkan_state.h"
#include <cardinal/renderer/vulkan_pipeline.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

/**
 * @brief Creates depth resources for the Vulkan state.
 *
 * @param s Pointer to the VulkanState structure.
 * @return true if successful, false otherwise.
 *
 * @todo Support configurable depth formats and multisampling.
 * @todo Integrate with Vulkan dynamic rendering extensions.
 */
static bool create_depth_resources(VulkanState* s) {
    // Find a suitable depth format
    VkFormat candidates[] = {VK_FORMAT_D32_SFLOAT, VK_FORMAT_D32_SFLOAT_S8_UINT,
                             VK_FORMAT_D24_UNORM_S8_UINT};
    s->swapchain.depth_format = VK_FORMAT_UNDEFINED;

    for (int i = 0; i < 3; i++) {
        VkFormatProperties props;
        vkGetPhysicalDeviceFormatProperties(s->context.physical_device, candidates[i], &props);
        if (props.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) {
            s->swapchain.depth_format = candidates[i];
            break;
        }
    }

    if (s->swapchain.depth_format == VK_FORMAT_UNDEFINED) {
        CARDINAL_LOG_ERROR("pipeline: failed to find suitable depth format");
        return false;
    }

    // Create depth image
    VkImageCreateInfo imageInfo = {0};
    imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = s->swapchain.extent.width;
    imageInfo.extent.height = s->swapchain.extent.height;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = s->swapchain.depth_format;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    // Use VulkanAllocator to allocate and bind image + memory
    if (!vk_allocator_allocate_image(&s->allocator, &imageInfo, &s->swapchain.depth_image,
                                     &s->swapchain.depth_image_memory,
                                     VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
        CARDINAL_LOG_ERROR("pipeline: allocator failed to create depth image");
        return false;
    }

    // Create depth image view
    VkImageViewCreateInfo viewInfo = {0};
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = s->swapchain.depth_image;
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = s->swapchain.depth_format;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;

    if (vkCreateImageView(s->context.device, &viewInfo, NULL, &s->swapchain.depth_image_view) !=
        VK_SUCCESS) {
        CARDINAL_LOG_ERROR("pipeline: failed to create depth image view");
        // Free image + memory via allocator on failure
        vk_allocator_free_image(&s->allocator, s->swapchain.depth_image,
                                s->swapchain.depth_image_memory);
        s->swapchain.depth_image = VK_NULL_HANDLE;
        s->swapchain.depth_image_memory = VK_NULL_HANDLE;
        return false;
    }

    // Initialize layout tracking
    s->swapchain.depth_layout_initialized = false;

    CARDINAL_LOG_INFO("pipeline: depth resources created");
    return true;
}

/**
 * @brief Destroys depth resources associated with the Vulkan state.
 *
 * @param s Pointer to the VulkanState structure.
 */
static void destroy_depth_resources(VulkanState* s) {
    if (!s || !s->context.device)
        return;

    // Validate and destroy depth image view
    if (s->swapchain.depth_image_view != VK_NULL_HANDLE) {
        vkDestroyImageView(s->context.device, s->swapchain.depth_image_view, NULL);
        s->swapchain.depth_image_view = VK_NULL_HANDLE;
    }

    // Validate and free image + memory using allocator
    if (s->swapchain.depth_image != VK_NULL_HANDLE ||
        s->swapchain.depth_image_memory != VK_NULL_HANDLE) {
        // Ensure allocator is valid before freeing
        if (s->allocator.device != VK_NULL_HANDLE) {
            vk_allocator_free_image(&s->allocator, s->swapchain.depth_image,
                                    s->swapchain.depth_image_memory);
        }
        s->swapchain.depth_image = VK_NULL_HANDLE;
        s->swapchain.depth_image_memory = VK_NULL_HANDLE;
    }

    // Reset layout tracking when depth resources are destroyed
    s->swapchain.depth_layout_initialized = false;
}

/**
 * @brief Creates the render pass and graphics pipeline for the Vulkan state.
 *
 * @param s Pointer to the VulkanState structure.
 * @return true if successful, false otherwise.
 *
 * @todo Support multiple render passes for advanced rendering techniques.
 * @todo Implement pipeline caching for faster recreation.
 */
bool vk_create_pipeline(VulkanState* s) {
    CARDINAL_LOG_INFO("pipeline: create depth resources");
    if (!create_depth_resources(s)) {
        return false;
    }

    CARDINAL_LOG_INFO("pipeline: depth resources created - no simple triangle pipeline needed");
    return true;
}

/**
 * @brief Destroys the render pass and graphics pipeline.
 *
 * @param s Pointer to the VulkanState structure.
 *
 * @todo Ensure thread-safe destruction of resources.
 * @todo Add logging for destruction events.
 */
void vk_destroy_pipeline(VulkanState* s) {
    if (!s || !s->context.device)
        return;

    // Wait for device to be idle before destroying resources for thread safety
    VkResult result = vkDeviceWaitIdle(s->context.device);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("pipeline: vkDeviceWaitIdle failed during destruction: %d", result);
        // Continue with destruction anyway to prevent resource leaks
    }

    destroy_depth_resources(s);

    CARDINAL_LOG_INFO("pipeline: pipeline resources destroyed");
}
