/**
 * @file vulkan_buffer_utils.h
 * @brief Vulkan buffer management utilities for Cardinal Engine
 *
 * This module provides utility functions for creating, managing, and copying
 * Vulkan buffers. It handles memory allocation, type selection, and efficient
 * buffer operations commonly needed in graphics applications.
 *
 * Key features:
 * - Memory type selection based on requirements
 * - Buffer creation with automatic memory allocation
 * - Efficient buffer-to-buffer copying operations
 * - Integration with VulkanAllocator for memory management
 * - Support for various buffer usage patterns
 *
 * The utilities abstract common buffer operations and provide a simplified
 * interface for buffer management throughout the rendering pipeline.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_BUFFER_UTILS_H
#define VULKAN_BUFFER_UTILS_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

// Forward declarations
typedef struct VulkanAllocator VulkanAllocator;

/**
 * @brief Finds a suitable memory type index.
 * @param physicalDevice Physical device.
 * @param typeFilter Memory type filter.
 * @param properties Required memory properties.
 * @return Memory type index or UINT32_MAX on failure.
 */
uint32_t vk_buffer_find_memory_type(VkPhysicalDevice physicalDevice,
                                    uint32_t typeFilter,
                                    VkMemoryPropertyFlags properties);

/**
 * @brief Creates a Vulkan buffer and allocates memory using VulkanAllocator.
 * @param allocator VulkanAllocator instance.
 * @param size Buffer size.
 * @param usage Buffer usage flags.
 * @param properties Memory properties.
 * @param buffer Output buffer handle.
 * @param bufferMemory Output memory handle.
 * @return true on success, false on failure.
 */
bool vk_buffer_create(VulkanAllocator *allocator, VkDeviceSize size,
                      VkBufferUsageFlags usage,
                      VkMemoryPropertyFlags properties, VkBuffer *buffer,
                      VkDeviceMemory *bufferMemory);

/**
 * @brief Copies data from one buffer to another.
 * @param device Logical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param srcBuffer Source buffer.
 * @param dstBuffer Destination buffer.
 * @param size Size to copy.
 */
void vk_buffer_copy(VkDevice device, VkCommandPool commandPool,
                    VkQueue graphicsQueue, VkBuffer srcBuffer,
                    VkBuffer dstBuffer, VkDeviceSize size);

/**
 * @brief Creates a buffer with optimal GPU memory using staging buffer
 * transfer.
 * @param allocator VulkanAllocator instance.
 * @param device Logical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param data Source data to upload.
 * @param size Buffer size.
 * @param usage Buffer usage flags (will add TRANSFER_DST_BIT automatically).
 * @param buffer Output buffer handle.
 * @param bufferMemory Output memory handle.
 * @return true on success, false on failure.
 */
bool vk_buffer_create_with_staging(VulkanAllocator *allocator, VkDevice device,
                                   VkCommandPool commandPool,
                                   VkQueue graphicsQueue, const void *data,
                                   VkDeviceSize size, VkBufferUsageFlags usage,
                                   VkBuffer *buffer,
                                   VkDeviceMemory *bufferMemory);

#endif // VULKAN_BUFFER_UTILS_H
