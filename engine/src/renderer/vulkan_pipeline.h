#ifndef VULKAN_PIPELINE_H
#define VULKAN_PIPELINE_H

#include <stdbool.h>
#include "vulkan_state.h"

/**
 * @brief Creates the render pass and graphics pipeline for the Vulkan state.
 * @param s Pointer to the VulkanState structure.
 * @return true if successful, false otherwise.
 */
bool vk_create_renderpass_pipeline(VulkanState* s);

/**
 * @brief Destroys the render pass and graphics pipeline.
 * @param s Pointer to the VulkanState structure.
 */
void vk_destroy_renderpass_pipeline(VulkanState* s);

#endif // VULKAN_PIPELINE_H
