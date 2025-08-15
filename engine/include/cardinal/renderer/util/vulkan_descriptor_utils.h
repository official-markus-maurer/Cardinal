/**
 * @file vulkan_descriptor_utils.h
 * @brief Vulkan descriptor set management utilities for Cardinal Engine
 *
 * This module provides utility functions for creating and managing Vulkan
 * descriptor sets, layouts, and pools. It handles the complex process of
 * setting up descriptor bindings for PBR rendering pipelines with support
 * for variable descriptor counts and dynamic texture arrays.
 *
 * Key features:
 * - PBR-optimized descriptor set layout creation
 * - Variable descriptor count support for texture arrays
 * - Descriptor pool management with configurable limits
 * - Descriptor set allocation and updating
 * - Uniform buffer and texture binding management
 * - Resource cleanup and destruction
 *
 * The utilities abstract the descriptor management complexity and provide
 * a streamlined interface for binding resources to shaders in PBR pipelines.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_DESCRIPTOR_UTILS_H
#define VULKAN_DESCRIPTOR_UTILS_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

/**
 * @brief Creates a descriptor set layout for PBR rendering.
 * @param device Logical device.
 * @param descriptorSetLayout Output descriptor set layout handle.
 * @return true on success, false on failure.
 */
bool vk_descriptor_create_pbr_layout(
    VkDevice device, VkDescriptorSetLayout *descriptorSetLayout);

/**
 * @brief Creates a descriptor pool with support for variable descriptor counts.
 * @param device Logical device.
 * @param maxSets Maximum number of descriptor sets.
 * @param maxTextures Maximum number of texture descriptors.
 * @param descriptorPool Output descriptor pool handle.
 * @return true on success, false on failure.
 */
bool vk_descriptor_create_pool(VkDevice device, uint32_t maxSets,
                               uint32_t maxTextures,
                               VkDescriptorPool *descriptorPool);

/**
 * @brief Allocates descriptor sets from a pool.
 * @param device Logical device.
 * @param descriptorPool Descriptor pool.
 * @param descriptorSetLayout Descriptor set layout.
 * @param setCount Number of sets to allocate.
 * @param variableDescriptorCount Variable descriptor count for last binding.
 * @param descriptorSets Output descriptor sets array.
 * @return true on success, false on failure.
 */
bool vk_descriptor_allocate_sets(VkDevice device,
                                 VkDescriptorPool descriptorPool,
                                 VkDescriptorSetLayout descriptorSetLayout,
                                 uint32_t setCount,
                                 uint32_t variableDescriptorCount,
                                 VkDescriptorSet *descriptorSets);

/**
 * @brief Updates descriptor sets with buffer and image information.
 * @param device Logical device.
 * @param descriptorSet Descriptor set to update.
 * @param uniformBuffer Uniform buffer.
 * @param uniformBufferSize Uniform buffer size.
 * @param lightingBuffer Lighting buffer.
 * @param lightingBufferSize Lighting buffer size.
 * @param imageViews Array of image views.
 * @param sampler Texture sampler.
 * @param imageCount Number of images.
 */
void vk_descriptor_update_sets(VkDevice device, VkDescriptorSet descriptorSet,
                               VkBuffer uniformBuffer,
                               VkDeviceSize uniformBufferSize,
                               VkBuffer lightingBuffer,
                               VkDeviceSize lightingBufferSize,
                               VkImageView *imageViews, VkSampler sampler,
                               uint32_t imageCount);

/**
 * @brief Destroys a descriptor pool.
 * @param device Logical device.
 * @param descriptorPool Descriptor pool to destroy.
 */
void vk_descriptor_destroy_pool(VkDevice device,
                                VkDescriptorPool descriptorPool);

/**
 * @brief Destroys a descriptor set layout.
 * @param device Logical device.
 * @param descriptorSetLayout Descriptor set layout to destroy.
 */
void vk_descriptor_destroy_layout(VkDevice device,
                                  VkDescriptorSetLayout descriptorSetLayout);

#endif // VULKAN_DESCRIPTOR_UTILS_H
