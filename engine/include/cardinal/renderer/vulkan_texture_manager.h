/**
 * @file vulkan_texture_manager.h
 * @brief Centralized texture management for Cardinal Engine
 *
 * This module provides a centralized texture management system that handles
 * texture loading, creation, caching, and resource management. It abstracts
 * the complexity of Vulkan texture operations and provides a clean interface
 * for texture operations across the renderer.
 *
 * Key features:
 * - Centralized texture loading and caching
 * - Automatic placeholder texture generation
 * - Efficient memory management
 * - Descriptor set integration
 * - Support for various texture formats
 * - Texture array management for descriptor indexing
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_TEXTURE_MANAGER_H
#define VULKAN_TEXTURE_MANAGER_H

#include <cardinal/assets/scene.h>
#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

// Forward declarations
typedef struct VulkanAllocator VulkanAllocator;
struct VulkanSyncManager;

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Represents a managed texture with all Vulkan resources
 */
typedef struct VulkanManagedTexture {
  VkImage image;
  VkDeviceMemory memory;
  VkImageView view;
  VkSampler sampler; // Specific sampler for this texture (if different from default)
  uint32_t width;
  uint32_t height;
  uint32_t channels;
  bool isPlaceholder;
  char *path; // Optional path for debugging
} VulkanManagedTexture;

/**
 * @brief Texture manager for centralized texture operations
 */
typedef struct VulkanTextureManager {
  VkDevice device;
  VulkanAllocator *allocator;
  VkCommandPool commandPool;
  VkQueue graphicsQueue;
  struct VulkanSyncManager *syncManager;

  // Texture storage
  VulkanManagedTexture *textures;
  uint32_t textureCount;
  uint32_t textureCapacity;

  // Shared sampler
  VkSampler defaultSampler;

  // Placeholder texture (always at index 0)
  bool hasPlaceholder;
} VulkanTextureManager;

/**
 * @brief Configuration for texture manager initialization
 */
typedef struct VulkanTextureManagerConfig {
  VkDevice device;
  VulkanAllocator *allocator;
  VkCommandPool commandPool;
  VkQueue graphicsQueue;
  struct VulkanSyncManager *syncManager;
  uint32_t initialCapacity;
} VulkanTextureManagerConfig;

/**
 * @brief Initialize the texture manager
 * @param manager Texture manager to initialize
 * @param config Configuration parameters
 * @return true on success, false on failure
 */
bool vk_texture_manager_init(VulkanTextureManager *manager,
                             const VulkanTextureManagerConfig *config);

/**
 * @brief Destroy the texture manager and all managed textures
 * @param manager Texture manager to destroy
 */
void vk_texture_manager_destroy(VulkanTextureManager *manager);

/**
 * @brief Load textures from a scene
 * @param manager Texture manager
 * @param scene Scene containing texture data
 * @return true on success, false on failure
 */
bool vk_texture_manager_load_scene_textures(VulkanTextureManager *manager,
                                            const CardinalScene *scene);

/**
 * @brief Load a single texture from data
 * @param manager Texture manager
 * @param texture Texture data to load
 * @param outIndex Output texture index
 * @param outTimelineValue Optional pointer to receive the timeline semaphore
 * value for this upload
 * @return true on success, false on failure
 */
bool vk_texture_manager_load_texture(VulkanTextureManager *manager,
                                     const CardinalTexture *texture,
                                     uint32_t *outIndex,
                                     uint64_t *outTimelineValue);

/**
 * @brief Create a placeholder texture
 * @param manager Texture manager
 * @param outIndex Output texture index
 * @return true on success, false on failure
 */
bool vk_texture_manager_create_placeholder(VulkanTextureManager *manager,
                                           uint32_t *outIndex);

/**
 * @brief Get texture by index
 * @param manager Texture manager
 * @param index Texture index
 * @return Pointer to managed texture, or NULL if invalid index
 */
const VulkanManagedTexture *
vk_texture_manager_get_texture(const VulkanTextureManager *manager,
                               uint32_t index);

/**
 * @brief Get the default sampler
 * @param manager Texture manager
 * @return Default sampler handle
 */
VkSampler
vk_texture_manager_get_default_sampler(const VulkanTextureManager *manager);

/**
 * @brief Get texture count
 * @param manager Texture manager
 * @return Number of loaded textures
 */
uint32_t
vk_texture_manager_get_texture_count(const VulkanTextureManager *manager);

/**
 * @brief Get all texture image views for descriptor set binding
 * @param manager Texture manager
 * @param outViews Output array of image views (must be pre-allocated)
 * @param maxViews Maximum number of views to copy
 * @return Number of views copied
 */
uint32_t vk_texture_manager_get_image_views(const VulkanTextureManager *manager,
                                            VkImageView *outViews,
                                            uint32_t maxViews);

/**
 * @brief Clear all textures (except placeholder)
 * @param manager Texture manager
 */
void vk_texture_manager_clear_textures(VulkanTextureManager *manager);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_TEXTURE_MANAGER_H
