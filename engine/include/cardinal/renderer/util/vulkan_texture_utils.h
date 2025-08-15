#ifndef VULKAN_TEXTURE_UTILS_H
#define VULKAN_TEXTURE_UTILS_H

#include <vulkan/vulkan.h>
#include <cardinal/assets/scene.h>
#include <stdint.h>
#include <stdbool.h>

// Forward declarations
typedef struct VulkanAllocator VulkanAllocator;

/**
 * @brief Creates a Vulkan texture from CardinalTexture data.
 * @param allocator VulkanAllocator instance.
 * @param device Logical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param texture Input texture data.
 * @param textureImage Output image handle.
 * @param textureImageMemory Output memory handle.
 * @param textureImageView Output image view handle.
 * @return true on success, false on failure.
 */
bool vk_texture_create_from_data(VulkanAllocator* allocator, VkDevice device,
                                 VkCommandPool commandPool, VkQueue graphicsQueue,
                                 const CardinalTexture* texture, 
                                 VkImage* textureImage, VkDeviceMemory* textureImageMemory,
                                 VkImageView* textureImageView);

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
bool vk_texture_create_placeholder(VulkanAllocator* allocator, VkDevice device,
                                   VkCommandPool commandPool, VkQueue graphicsQueue,
                                   VkImage* textureImage, VkDeviceMemory* textureImageMemory,
                                   VkImageView* textureImageView, const VkFormat* format);

/**
 * @brief Creates a texture sampler with standard PBR settings.
 * @param device Logical device.
 * @param physicalDevice Physical device.
 * @param sampler Output sampler handle.
 * @return true on success, false on failure.
 */
bool vk_texture_create_sampler(VkDevice device, VkPhysicalDevice physicalDevice, VkSampler* sampler);

#endif // VULKAN_TEXTURE_UTILS_H
