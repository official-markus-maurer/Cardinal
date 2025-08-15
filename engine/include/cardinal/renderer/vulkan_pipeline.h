/**
 * @file vulkan_pipeline.h
 * @brief Vulkan graphics pipeline management for Cardinal Engine
 *
 * This module handles the creation and management of Vulkan graphics pipelines,
 * including render passes and pipeline state objects. The pipeline defines how
 * vertices are processed and fragments are rendered.
 *
 * Key responsibilities:
 * - Render pass creation with color and depth attachments
 * - Graphics pipeline creation with shader stages
 * - Pipeline layout and descriptor set layout management
 * - Vertex input and rasterization state configuration
 * - Pipeline cleanup and resource management
 *
 * The pipeline is configured for PBR (Physically Based Rendering) with
 * support for multiple textures and material properties.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_PIPELINE_H
#define VULKAN_PIPELINE_H

#include <stdbool.h>

// Forward declaration to avoid circular includes
typedef struct VulkanState VulkanState;

/**
 * @brief Creates the render pass and graphics pipeline for the Vulkan state.
 * @param s Pointer to the VulkanState structure.
 * @return true if successful, false otherwise.
 */
bool vk_create_pipeline(VulkanState *s);

/**
 * @brief Destroys the graphics pipeline.
 * @param s Pointer to the VulkanState structure.
 */
void vk_destroy_pipeline(VulkanState *s);

#endif // VULKAN_PIPELINE_H
