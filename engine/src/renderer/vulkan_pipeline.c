#include <stdlib.h>
#include <vulkan/vulkan.h>
#include <string.h>
#include <stdio.h>
#include "vulkan_state.h"
#include <cardinal/renderer/vulkan_pipeline.h>
#include "cardinal/core/log.h"

/**
 * @brief Reads a SPIR-V shader file into memory.
 *
 * @param path Path to the SPIR-V file.
 * @param out_data Pointer to store the loaded data.
 * @param out_size Pointer to store the data size.
 * @return true if successful, false otherwise.
 *
 * @todo Implement shader caching to avoid repeated file reads.
 * @todo Add support for compressed shader files.
 */
static bool read_spv_file(const char* path, uint8_t** out_data, size_t* out_size) {
    FILE* f = fopen(path, "rb");
    if (!f) { LOG_ERROR("pipeline: failed to open SPV file"); return false; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    if (sz <= 0) { fclose(f); LOG_ERROR("pipeline: SPV file size invalid"); return false; }
    fseek(f, 0, SEEK_SET);
    uint8_t* data = (uint8_t*)malloc((size_t)sz);
    if (!data) { fclose(f); LOG_ERROR("pipeline: SPV malloc failed"); return false; }
    size_t rd = fread(data, 1, (size_t)sz, f);
    fclose(f);
    if (rd != (size_t)sz) { free(data); LOG_ERROR("pipeline: SPV read failed"); return false; }
    *out_data = data;
    *out_size = (size_t)sz;
    return true;
}

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
    VkFormat candidates[] = {VK_FORMAT_D32_SFLOAT, VK_FORMAT_D32_SFLOAT_S8_UINT, VK_FORMAT_D24_UNORM_S8_UINT};
    s->depth_format = VK_FORMAT_UNDEFINED;
    
    for (int i = 0; i < 3; i++) {
        VkFormatProperties props;
        vkGetPhysicalDeviceFormatProperties(s->physical_device, candidates[i], &props);
        if (props.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) {
            s->depth_format = candidates[i];
            break;
        }
    }
    
    if (s->depth_format == VK_FORMAT_UNDEFINED) {
        LOG_ERROR("pipeline: failed to find suitable depth format");
        return false;
    }
    
    // Create depth image
    VkImageCreateInfo imageInfo = {0};
    imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = s->swapchain_extent.width;
    imageInfo.extent.height = s->swapchain_extent.height;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = s->depth_format;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    
    // Use VulkanAllocator to allocate and bind image + memory
    if (!vk_allocator_allocate_image(&s->allocator, &imageInfo, &s->depth_image, &s->depth_image_memory, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
        LOG_ERROR("pipeline: allocator failed to create depth image");
        return false;
    }
    
    // Create depth image view
    VkImageViewCreateInfo viewInfo = {0};
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = s->depth_image;
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = s->depth_format;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;
    
    if (vkCreateImageView(s->device, &viewInfo, NULL, &s->depth_image_view) != VK_SUCCESS) {
        LOG_ERROR("pipeline: failed to create depth image view");
        // Free image + memory via allocator on failure
        vk_allocator_free_image(&s->allocator, s->depth_image, s->depth_image_memory);
        s->depth_image = VK_NULL_HANDLE;
        s->depth_image_memory = VK_NULL_HANDLE;
        return false;
    }
    
    // Initialize layout tracking
    s->depth_layout_initialized = false;
    
    LOG_INFO("pipeline: depth resources created");
    return true;
}

/**
 * @brief Destroys depth resources associated with the Vulkan state.
 *
 * @param s Pointer to the VulkanState structure.
 *
 * @todo Add checks for valid resource handles before destruction.
 */
static void destroy_depth_resources(VulkanState* s) {
    if (s->depth_image_view) {
        vkDestroyImageView(s->device, s->depth_image_view, NULL);
        s->depth_image_view = VK_NULL_HANDLE;
    }
    // Free image + memory using allocator
    if (s->depth_image || s->depth_image_memory) {
        vk_allocator_free_image(&s->allocator, s->depth_image, s->depth_image_memory);
        s->depth_image = VK_NULL_HANDLE;
        s->depth_image_memory = VK_NULL_HANDLE;
    }
    // Reset layout tracking when depth resources are destroyed
    s->depth_layout_initialized = false;
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
    LOG_INFO("pipeline: create depth resources");
    if (!create_depth_resources(s)) {
        return false;
    }
    
    LOG_INFO("pipeline: depth resources created - no simple triangle pipeline needed");
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
    if (!s) return;
    destroy_depth_resources(s);
}
