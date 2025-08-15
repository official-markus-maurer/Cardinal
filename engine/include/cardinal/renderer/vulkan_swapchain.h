/**
 * @file vulkan_swapchain.h
 * @brief Vulkan swapchain management for Cardinal Engine
 * 
 * This module handles the creation, management, and recreation of Vulkan
 * swapchains, which are responsible for presenting rendered images to the
 * screen. The swapchain manages a series of framebuffers that are used
 * for double/triple buffering.
 * 
 * Key responsibilities:
 * - Swapchain creation with optimal surface format and present mode
 * - Image view creation for swapchain images
 * - Swapchain recreation for window resize events
 * - Synchronization with presentation engine
 * - Resource cleanup and management
 * 
 * The module automatically selects the best available surface format
 * and present mode based on device capabilities and performance requirements.
 * 
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_SWAPCHAIN_H
#define VULKAN_SWAPCHAIN_H

#include <stdbool.h>

// Forward declaration to avoid circular includes
typedef struct VulkanState VulkanState;

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

