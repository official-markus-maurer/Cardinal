/**
 * @file vulkan_material_utils.h
 * @brief Utility functions for material management in Vulkan
 *
 * This file provides helper functions for setting up material properties
 * and push constants for rendering pipelines.
 */

#ifndef CARDINAL_RENDERER_UTIL_VULKAN_MATERIAL_UTILS_H
#define CARDINAL_RENDERER_UTIL_VULKAN_MATERIAL_UTILS_H

#include <cardinal/assets/scene.h>
#include <cardinal/renderer/vulkan_pbr.h> // For PBRPushConstants
#include <stdbool.h>

// Forward declarations
typedef struct VulkanTextureManager VulkanTextureManager;

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Populates PBR push constants from a mesh and scene material
 *
 * @param pushConstants Pointer to the push constants structure to populate
 * @param mesh The mesh being rendered
 * @param scene The scene containing the mesh and materials
 * @param textureManager The texture manager (optional, can be NULL)
 */
void vk_material_setup_push_constants(
    PBRPushConstants *pushConstants, const CardinalMesh *mesh,
    const CardinalScene *scene, const VulkanTextureManager *textureManager);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_RENDERER_UTIL_VULKAN_MATERIAL_UTILS_H
