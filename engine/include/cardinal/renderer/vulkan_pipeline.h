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
bool vk_create_pipeline(VulkanState* s);

/**
 * @brief Destroys the graphics pipeline.
 * @param s Pointer to the VulkanState structure.
 */
void vk_destroy_pipeline(VulkanState* s);

#endif // VULKAN_PIPELINE_H
