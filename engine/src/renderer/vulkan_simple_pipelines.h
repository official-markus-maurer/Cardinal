/**
 * @file vulkan_simple_pipelines.h
 * @brief Simple pipeline management for UV and wireframe rendering modes
 * 
 * This module provides functions for creating and managing simplified rendering
 * pipelines used for UV visualization and wireframe rendering modes.
 * 
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_SIMPLE_PIPELINES_H
#define VULKAN_SIMPLE_PIPELINES_H

#include <stdbool.h>
#include <vulkan/vulkan.h>

// Forward declaration to avoid circular includes
typedef struct VulkanState VulkanState;

/**
 * @brief Creates UV and wireframe pipelines
 * @param s Vulkan state
 * @return true on success, false on failure
 */
bool vk_create_simple_pipelines(VulkanState* s);

/**
 * @brief Destroys UV and wireframe pipelines
 * @param s Vulkan state
 */
void vk_destroy_simple_pipelines(VulkanState* s);

/**
 * @brief Updates the simple uniform buffer with current matrices
 * @param s Vulkan state
 * @param model Model matrix
 * @param view View matrix
 * @param proj Projection matrix
 */
void vk_update_simple_uniforms(VulkanState* s, const float* model, const float* view, const float* proj);

/**
 * @brief Renders scene using a simple pipeline (UV or wireframe)
 * @param s Vulkan state
 * @param commandBuffer Command buffer to record into
 * @param pipeline Pipeline to use
 * @param pipelineLayout Pipeline layout to use
 */
void vk_render_simple(VulkanState* s, VkCommandBuffer commandBuffer, VkPipeline pipeline, VkPipelineLayout pipelineLayout);

#endif // VULKAN_SIMPLE_PIPELINES_H
