#pragma once

#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct VulkanState VulkanState;
typedef struct VulkanAllocator VulkanAllocator;

// Maximum number of bindless textures supported
#define CARDINAL_MAX_BINDLESS_TEXTURES 4096

// Bindless texture descriptor set binding indices
#define CARDINAL_BINDLESS_TEXTURE_BINDING 0
#define CARDINAL_BINDLESS_SAMPLER_BINDING 1

/**
 * @brief Structure representing a bindless texture entry
 */
typedef struct BindlessTexture {
    VkImage image;                    /**< Vulkan image handle */
    VkImageView image_view;          /**< Image view for shader access */
    VkDeviceMemory memory;           /**< Device memory for the image */
    VkSampler sampler;               /**< Sampler for texture filtering */
    uint32_t descriptor_index;       /**< Index in the bindless descriptor array */
    bool is_allocated;               /**< Whether this slot is currently allocated */
    VkFormat format;                 /**< Image format */
    VkExtent3D extent;               /**< Image dimensions */
    uint32_t mip_levels;             /**< Number of mip levels */
} BindlessTexture;

/**
 * @brief Bindless texture pool for managing large arrays of textures
 */
typedef struct BindlessTexturePool {
    VkDevice device;                           /**< Vulkan logical device */
    VkPhysicalDevice physical_device;          /**< Vulkan physical device */
    VulkanAllocator* allocator;                /**< Memory allocator */
    
    // Descriptor set layout and pool
    VkDescriptorSetLayout descriptor_layout;   /**< Descriptor set layout for bindless textures */
    VkDescriptorPool descriptor_pool;          /**< Descriptor pool for bindless sets */
    VkDescriptorSet descriptor_set;            /**< The bindless descriptor set */
    
    // Texture storage
    BindlessTexture* textures;                 /**< Array of bindless textures */
    uint32_t max_textures;                     /**< Maximum number of textures */
    uint32_t allocated_count;                  /**< Number of currently allocated textures */
    
    // Free list for efficient allocation
    uint32_t* free_indices;                    /**< Stack of free texture indices */
    uint32_t free_count;                       /**< Number of free indices available */
    
    // Default sampler for textures without specific samplers
    VkSampler default_sampler;                 /**< Default sampler */
    
    // Update tracking
    bool needs_descriptor_update;              /**< Whether descriptor set needs updating */
    uint32_t* pending_updates;                 /**< Array of indices that need updating */
    uint32_t pending_update_count;             /**< Number of pending updates */
} BindlessTexturePool;

/**
 * @brief Parameters for creating a bindless texture
 */
typedef struct BindlessTextureCreateInfo {
    VkExtent3D extent;                         /**< Texture dimensions */
    VkFormat format;                           /**< Texture format */
    uint32_t mip_levels;                       /**< Number of mip levels */
    VkImageUsageFlags usage;                   /**< Image usage flags */
    VkSampleCountFlagBits samples;             /**< Sample count for MSAA */
    VkSampler custom_sampler;                  /**< Custom sampler (VK_NULL_HANDLE for default) */
    const void* initial_data;                  /**< Initial texture data (optional) */
    VkDeviceSize data_size;                    /**< Size of initial data */
} BindlessTextureCreateInfo;

// Function declarations

/**
 * @brief Initialize the bindless texture pool
 * @param pool Pointer to the bindless texture pool
 * @param vulkan_state Vulkan state containing device and allocator
 * @param max_textures Maximum number of bindless textures to support
 * @return true on success, false on failure
 */
bool vk_bindless_texture_pool_init(BindlessTexturePool* pool, 
                                   VulkanState* vulkan_state,
                                   uint32_t max_textures);

/**
 * @brief Destroy the bindless texture pool and free all resources
 * @param pool Pointer to the bindless texture pool
 */
void vk_bindless_texture_pool_destroy(BindlessTexturePool* pool);

/**
 * @brief Allocate a new bindless texture
 * @param pool Pointer to the bindless texture pool
 * @param create_info Texture creation parameters
 * @param out_index Pointer to store the allocated texture index
 * @return true on success, false on failure
 */
bool vk_bindless_texture_allocate(BindlessTexturePool* pool,
                                  const BindlessTextureCreateInfo* create_info,
                                  uint32_t* out_index);

/**
 * @brief Free a bindless texture and return its index to the free list
 * @param pool Pointer to the bindless texture pool
 * @param texture_index Index of the texture to free
 */
void vk_bindless_texture_free(BindlessTexturePool* pool, uint32_t texture_index);

/**
 * @brief Update texture data for an existing bindless texture
 * @param pool Pointer to the bindless texture pool
 * @param texture_index Index of the texture to update
 * @param data New texture data
 * @param data_size Size of the new data
 * @param command_buffer Command buffer for the update operation
 * @return true on success, false on failure
 */
bool vk_bindless_texture_update_data(BindlessTexturePool* pool,
                                     uint32_t texture_index,
                                     const void* data,
                                     VkDeviceSize data_size,
                                     VkCommandBuffer command_buffer);

/**
 * @brief Get the descriptor set for bindless textures
 * @param pool Pointer to the bindless texture pool
 * @return The bindless descriptor set
 */
VkDescriptorSet vk_bindless_texture_get_descriptor_set(const BindlessTexturePool* pool);

/**
 * @brief Get the descriptor set layout for bindless textures
 * @param pool Pointer to the bindless texture pool
 * @return The bindless descriptor set layout
 */
VkDescriptorSetLayout vk_bindless_texture_get_layout(const BindlessTexturePool* pool);

/**
 * @brief Flush pending descriptor updates to the GPU
 * @param pool Pointer to the bindless texture pool
 * @return true on success, false on failure
 */
bool vk_bindless_texture_flush_updates(BindlessTexturePool* pool);

/**
 * @brief Get texture information by index
 * @param pool Pointer to the bindless texture pool
 * @param texture_index Index of the texture
 * @return Pointer to the bindless texture, or NULL if invalid index
 */
const BindlessTexture* vk_bindless_texture_get(const BindlessTexturePool* pool, uint32_t texture_index);

/**
 * @brief Check if descriptor indexing is supported
 * @param vulkan_state Vulkan state to check
 * @return true if descriptor indexing is supported and enabled
 */
bool vk_descriptor_indexing_supported(const VulkanState* vulkan_state);

/**
 * @brief Create a descriptor set layout with variable descriptor count support
 * @param device Vulkan logical device
 * @param binding_count Number of descriptor bindings
 * @param bindings Array of descriptor set layout bindings
 * @param variable_binding_index Index of the binding with variable descriptor count
 * @param max_variable_count Maximum number of descriptors for the variable binding
 * @param out_layout Pointer to store the created layout
 * @return true on success, false on failure
 */
bool vk_create_variable_descriptor_layout(VkDevice device,
                                          uint32_t binding_count,
                                          const VkDescriptorSetLayoutBinding* bindings,
                                          uint32_t variable_binding_index,
                                          uint32_t max_variable_count,
                                          VkDescriptorSetLayout* out_layout);

/**
 * @brief Allocate a descriptor set with variable descriptor count
 * @param device Vulkan logical device
 * @param descriptor_pool Descriptor pool to allocate from
 * @param layout Descriptor set layout
 * @param variable_count Number of descriptors for the variable binding
 * @param out_set Pointer to store the allocated descriptor set
 * @return true on success, false on failure
 */
bool vk_allocate_variable_descriptor_set(VkDevice device,
                                         VkDescriptorPool descriptor_pool,
                                         VkDescriptorSetLayout layout,
                                         uint32_t variable_count,
                                         VkDescriptorSet* out_set);

#ifdef __cplusplus
}
#endif