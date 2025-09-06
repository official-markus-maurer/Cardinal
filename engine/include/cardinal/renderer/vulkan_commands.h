/**
 * @file vulkan_commands.h
 * @brief Vulkan command buffer and synchronization management for Cardinal
 * Engine
 *
 * This module handles the creation and management of Vulkan command buffers,
 * command pools, and synchronization primitives (semaphores and fences).
 * Command buffers are used to record and submit GPU commands for rendering.
 *
 * Key responsibilities:
 * - Command pool creation for different queue families
 * - Command buffer allocation and management
 * - Multi-threaded command buffer allocation and secondary command buffers
 * - Synchronization object creation (semaphores, fences)
 * - Command recording for rendering operations
 * - Frame-in-flight tracking for proper synchronization
 *
 * The module ensures proper synchronization between CPU and GPU operations
 * and manages multiple frames in flight for optimal performance. It now
 * includes multi-threading support for better parallelism.
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
bool vk_create_commands_sync(VulkanState *s);

/**
 * @brief Recreates per-image initialization tracking after swapchain changes.
 * @param s Pointer to the VulkanState structure.
 * @return true on success, false on failure.
 */
bool vk_recreate_images_in_flight(VulkanState *s);

/**
 * @brief Destroys command pools, buffers, and synchronization objects.
 * @param s Pointer to the VulkanState structure.
 */
void vk_destroy_commands_sync(VulkanState *s);

/**
 * @brief Records drawing commands into a command buffer.
 * @param s Pointer to the VulkanState structure.
 * @param image_index Swapchain image index.
 */
void vk_record_cmd(VulkanState *s, uint32_t image_index);

/**
 * @brief Prepares mesh shader rendering by updating descriptor sets.
 * @param s Pointer to the VulkanState structure.
 */
void vk_prepare_mesh_shader_rendering(VulkanState *s);

/**
 * @brief Get the multi-threaded command manager for the current Vulkan state.
 * @return Pointer to the command manager, or NULL if not initialized.
 */
struct CardinalMTCommandManager* vk_get_mt_command_manager(void);

/**
 * @brief Submit a command recording task to the multi-threading subsystem
 * @param record_func Function to record commands
 * @param user_data User data to pass to the record function
 * @param callback Optional callback when task completes
 * @return true on success, false on failure
 */
bool vk_submit_mt_command_task(void (*record_func)(void* data),
                               void* user_data,
                               void (*callback)(void* data, bool success));

// === Secondary Command Buffer Functions ===
// Note: Secondary command buffer functions are implemented internally in vulkan_commands.c

#endif // VULKAN_COMMANDS_H
