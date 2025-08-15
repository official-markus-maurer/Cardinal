/**
 * @file vulkan_instance.h
 * @brief Vulkan instance and device management for Cardinal Engine
 *
 * This module handles the core Vulkan initialization and setup, including:
 * - Vulkan instance creation with validation layers
 * - Physical device selection and scoring
 * - Logical device creation with queue families
 * - Surface creation for window integration
 * - Debug messenger setup for validation
 *
 * The module provides a high-level interface for setting up the Vulkan
 * rendering context that other renderer components depend on.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_INSTANCE_H
#define VULKAN_INSTANCE_H

#include <stdbool.h>

// Forward declaration to avoid circular includes
typedef struct VulkanState VulkanState;

struct CardinalWindow;

/**
 * @brief Creates the Vulkan instance.
 * @param s Pointer to the VulkanState structure.
 * @return true on success, false on failure.
 * @todo Dynamically enable/disable validation layers based on build config.
 * @todo Add support for VK_KHR_portability extension for macOS compatibility.
 */
bool vk_create_instance(VulkanState *s);

/**
 * @brief Selects a suitable physical device.
 * @param s Pointer to the VulkanState structure.
 * @return true if device selected, false otherwise.
 * @todo Refactor to support multi-GPU selection with scoring.
 */
bool vk_pick_physical_device(VulkanState *s);

/**
 * @brief Creates the logical Vulkan device.
 * @param s Pointer to the VulkanState structure.
 * @return true on success, false on failure.
 * @todo Improve queue family selection for dedicated transfer queues.
 * @todo Enable device extensions like VK_KHR_dynamic_rendering for modern
 * rendering.
 */
bool vk_create_device(VulkanState *s);

/**
 * @brief Creates the Vulkan surface from the window.
 * @param s Pointer to the VulkanState structure.
 * @param window Pointer to the CardinalWindow structure.
 * @return true on success, false on failure.
 */
bool vk_create_surface(VulkanState *s, struct CardinalWindow *window);

/**
 * @brief Destroys Vulkan device objects.
 * @param s Pointer to the VulkanState structure.
 */
void vk_destroy_device_objects(VulkanState *s);

/**
 * @brief Recreate DebugUtils messenger to reflect current log level.
 * Call this after changing log level for immediate effect.
 * Safe to call if validation is disabled (no-op).
 */
void vk_recreate_debug_messenger(VulkanState *s);

#endif // VULKAN_INSTANCE_H
