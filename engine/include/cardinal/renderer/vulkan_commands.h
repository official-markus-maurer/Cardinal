/**
 * @file vulkan_commands.h
 * @brief Vulkan command buffer and synchronization management for Cardinal Engine
 * 
 * This module handles the creation and management of Vulkan command buffers,
 * command pools, and synchronization primitives (semaphores and fences).
 * Command buffers are used to record and submit GPU commands for rendering.
 * 
 * Key responsibilities:
 * - Command pool creation for different queue families
 * - Command buffer allocation and management
 * - Synchronization object creation (semaphores, fences)
 * - Command recording for rendering operations
 * - Frame-in-flight tracking for proper synchronization
 * 
 * The module ensures proper synchronization between CPU and GPU operations
 * and manages multiple frames in flight for optimal performance.
 * 
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_COMMANDS_H
#define VULKAN_COMMANDS_H

#include <stdbool.h>

// Forward declaration to avoid circular includes
typedef struct VulkanState VulkanState;

/**
 * @brief Creates command pools, buffers, and synchronization objects.
 * @param s Pointer to the VulkanState structure.
 * @return true on success, false on failure.
 */
bool vk_create_commands_sync(VulkanState* s);

/**
 * @brief Recreates per-image initialization tracking after swapchain changes.
 * @param s Pointer to the VulkanState structure.
 * @return true on success, false on failure.
 */
bool vk_recreate_images_in_flight(VulkanState* s);

/**
 * @brief Destroys command pools, buffers, and synchronization objects.
 * @param s Pointer to the VulkanState structure.
 */
void vk_destroy_commands_sync(VulkanState* s);

/**
 * @brief Records drawing commands into a command buffer.
 * @param s Pointer to the VulkanState structure.
 * @param image_index Swapchain image index.
 */
void vk_record_cmd(VulkanState* s, uint32_t image_index);

#endif // VULKAN_COMMANDS_H
