/**
 * @file vulkan_descriptor_buffer_utils.h
 * @brief Vulkan descriptor buffer management utilities for Cardinal Engine
 *
 * This module provides utility functions for creating and managing Vulkan
 * descriptor buffers using the VK_EXT_descriptor_buffer extension. This
 * replaces traditional descriptor sets with buffer-backed descriptors,
 * providing better performance and eliminating descriptor set invalidation
 * issues.
 *
 * Key features:
 * - Descriptor buffer allocation and management
 * - Direct descriptor memory management
 * - Reduced API overhead compared to descriptor sets
 * - Support for uniform buffers and combined image samplers
 * - Resource binding through buffer offsets
 * - Memory-efficient descriptor storage
 *
 * The utilities abstract the descriptor buffer complexity and provide
 * a streamlined interface for binding resources to shaders using the
 * modern descriptor buffer approach.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_DESCRIPTOR_BUFFER_UTILS_H
#define VULKAN_DESCRIPTOR_BUFFER_UTILS_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

// Forward declarations
typedef struct VulkanAllocator VulkanAllocator;
typedef struct VulkanState VulkanState;

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Descriptor buffer allocation info
 */
typedef struct {
  VkBuffer buffer;          /**< Vulkan buffer handle */
  VkDeviceMemory memory;    /**< Device memory handle */
  void *mapped_data;        /**< Mapped memory pointer */
  VkDeviceSize size;        /**< Buffer size in bytes */
  VkDeviceSize alignment;   /**< Required alignment */
  VkBufferUsageFlags usage; /**< Buffer usage flags */
} DescriptorBufferAllocation;

/**
 * @brief Descriptor buffer manager for a specific layout
 */
typedef struct {
  VkDevice device;              /**< Vulkan logical device */
  VulkanAllocator *allocator;   /**< Memory allocator */
  VkDescriptorSetLayout layout; /**< Descriptor set layout */

  // Buffer allocation
  DescriptorBufferAllocation buffer_alloc; /**< Descriptor buffer allocation */

  // Layout properties
  VkDeviceSize layout_size;      /**< Size of descriptor set layout */
  VkDeviceSize buffer_alignment; /**< Required buffer alignment */

  // Binding offsets within the buffer
  VkDeviceSize *binding_offsets; /**< Offset for each binding */
  uint32_t binding_count;        /**< Number of bindings */

  // Update tracking
  bool needs_update; /**< Whether buffer needs updating */
} DescriptorBufferManager;

/**
 * @brief Parameters for creating a descriptor buffer manager
 */
typedef struct {
  VkDevice device;              /**< Vulkan logical device */
  VulkanAllocator *allocator;   /**< Memory allocator */
  VkDescriptorSetLayout layout; /**< Descriptor set layout */
  uint32_t max_sets;            /**< Maximum number of descriptor sets */
} DescriptorBufferCreateInfo;

/**
 * @brief Creates a descriptor buffer manager
 * @param create_info Creation parameters
 * @param manager Output descriptor buffer manager
 * @return true on success, false on failure
 */
bool vk_descriptor_buffer_create_manager(
    const DescriptorBufferCreateInfo *create_info,
    DescriptorBufferManager *manager, VulkanState *vulkan_state);

/**
 * @brief Destroys a descriptor buffer manager
 * @param manager Descriptor buffer manager to destroy
 */
void vk_descriptor_buffer_destroy_manager(DescriptorBufferManager *manager);

/**
 * @brief Gets the buffer device address for binding
 * @param manager Descriptor buffer manager
 * @param set_index Index of the descriptor set
 * @return Buffer device address
 */
VkDeviceAddress
vk_descriptor_buffer_get_address(const DescriptorBufferManager *manager,
                                 uint32_t set_index, VulkanState *vulkan_state);

/**
 * @brief Updates a uniform buffer descriptor in the buffer
 * @param manager Descriptor buffer manager
 * @param set_index Index of the descriptor set
 * @param binding Binding index
 * @param buffer Uniform buffer
 * @param offset Buffer offset
 * @param range Buffer range
 * @return true on success, false on failure
 */
bool vk_descriptor_buffer_update_uniform_buffer(
    DescriptorBufferManager *manager, uint32_t set_index, uint32_t binding,
    VkBuffer buffer, VkDeviceSize offset, VkDeviceSize range,
    VulkanState *vulkan_state);

// Temporarily removed problematic function declaration
// TODO: Fix Vulkan type recognition issue
/*
bool vk_descriptor_buffer_update_image_sampler(DescriptorBufferManager* manager,
                                                uint32_t set_index,
                                                uint32_t binding,
                                                uint32_t array_element,
                                                VkImageView image_view,
                                                VkSampler vk_sampler,
                                                VkImageLayout image_layout);
*/

/**
 * @brief Binds descriptor buffers to a command buffer
 * @param cmd_buffer Command buffer
 * @param pipeline_bind_point Pipeline bind point
 * @param layout Pipeline layout
 * @param first_set First descriptor set index
 * @param set_count Number of descriptor sets
 * @param buffers Array of descriptor buffers
 * @param offsets Array of buffer offsets
 */
void vk_descriptor_buffer_bind(VkCommandBuffer cmd_buffer,
                               VkPipelineBindPoint pipeline_bind_point,
                               VkPipelineLayout layout, uint32_t first_set,
                               uint32_t set_count, const VkBuffer *buffers,
                               const VkDeviceSize *offsets,
                               VulkanState *vulkan_state);

/**
 * @brief Sets descriptor buffer offsets for binding
 * @param cmd_buffer Command buffer
 * @param pipeline_bind_point Pipeline bind point
 * @param layout Pipeline layout
 * @param first_set First descriptor set index
 * @param set_count Number of descriptor sets
 * @param buffer_indices Array of buffer indices
 * @param offsets Array of buffer offsets
 */
void vk_descriptor_buffer_set_offsets(VkCommandBuffer cmd_buffer,
                                      VkPipelineBindPoint pipeline_bind_point,
                                      VkPipelineLayout layout,
                                      uint32_t first_set, uint32_t set_count,
                                      const uint32_t *buffer_indices,
                                      const VkDeviceSize *offsets,
                                      VulkanState *vulkan_state);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_DESCRIPTOR_BUFFER_UTILS_H
