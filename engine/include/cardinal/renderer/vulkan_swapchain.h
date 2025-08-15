#ifndef VULKAN_SWAPCHAIN_H
#define VULKAN_SWAPCHAIN_H

#include <stdbool.h>
#include "../../src/renderer/vulkan_state.h"

/**
 * @brief Creates the Vulkan swapchain.
 * @param s Pointer to the VulkanState structure.
 * @return true on success, false on failure.
 * @todo Improve extent selection to handle window resizes dynamically.
 * @todo Add support for additional image usage flags for compute operations.
 */
bool vk_create_swapchain(VulkanState* s);

/**
 * @brief Destroys the swapchain and associated resources.
 * @param s Pointer to the VulkanState structure.
 * @todo Ensure all dependent resources are properly cleaned up before destruction.
 */
void vk_destroy_swapchain(VulkanState* s);

/**
 * @brief Recreates the swapchain for window resize or other changes.
 * @param s Pointer to the VulkanState structure.
 * @return true on success, false on failure.
 * @todo Optimize recreation to minimize frame drops during resize.
 * @todo Integrate with window event system for automatic recreation.
 */
bool vk_recreate_swapchain(VulkanState* s);

#endif // VULKAN_SWAPCHAIN_H

