/**
 * @file vulkan_texture_utils.h
 * @brief Vulkan texture management utilities for Cardinal Engine
 *
 * This module provides utility functions for creating and managing Vulkan
 * textures from various data sources. It handles texture creation, format
 * conversion, mipmap generation, and sampler configuration optimized for
 * PBR rendering workflows.
 *
 * Key features:
 * - Texture creation from CardinalTexture data
 * - Automatic format detection and conversion
 * - Placeholder texture generation for missing assets
 * - PBR-optimized texture sampling configuration
 * - Memory-efficient texture loading with staging buffers
 * - Support for various texture formats (RGBA, sRGB, etc.)
 *
 * The utilities handle the complex process of uploading texture data to
 * GPU memory and creating the necessary Vulkan objects for rendering.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_TEXTURE_UTILS_H
#define VULKAN_TEXTURE_UTILS_H

#include <cardinal/assets/scene.h>
#include <cardinal/renderer/vulkan_sync_manager.h>
#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

// Forward declarations
typedef struct VulkanAllocator VulkanAllocator;

/**
 * @brief Creates a Vulkan texture from CardinalTexture data.
 * @param allocator VulkanAllocator instance.
 * @param device Logical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param sync_manager VulkanSyncManager for proper synchronization (can be NULL
 * for fallback).
 * @param texture Input texture data.
 * @param textureImage Output image handle.
 * @param textureImageMemory Output memory handle.
 * @param textureImageView Output image view handle.
 * @param outTimelineValue Optional pointer to receive the timeline semaphore
 * value for this upload.
 * @return true on success, false on failure.
 */
bool vk_texture_create_from_data(
    VulkanAllocator *allocator, VkDevice device, VkCommandPool commandPool,
    VkQueue graphicsQueue, VulkanSyncManager *sync_manager,
    const CardinalTexture *texture, VkImage *textureImage,
    VkDeviceMemory *textureImageMemory, VkImageView *textureImageView,
    uint64_t *outTimelineValue);

/**
 * @brief Creates a 1x1 white placeholder texture.
 * @param allocator VulkanAllocator instance.
 * @param device Logical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param textureImage Output image handle.
 * @param textureImageMemory Output memory handle.
 * @param textureImageView Output image view handle.
 * @param format Optional format (NULL for default VK_FORMAT_R8G8B8A8_SRGB).
 * @return true on success, false on failure.
 */
bool vk_texture_create_placeholder(VulkanAllocator *allocator, VkDevice device,
                                   VkCommandPool commandPool,
                                   VkQueue graphicsQueue, VkImage *textureImage,
                                   VkDeviceMemory *textureImageMemory,
                                   VkImageView *textureImageView,
                                   const VkFormat *format);

/**
 * @brief Creates a texture sampler with standard PBR settings.
 * @param device Logical device.
 * @param physicalDevice Physical device.
 * @param sampler Output sampler handle.
 * @return true on success, false on failure.
 */
bool vk_texture_create_sampler(VkDevice device, VkPhysicalDevice physicalDevice,
                               VkSampler *sampler);

#endif // VULKAN_TEXTURE_UTILS_H
