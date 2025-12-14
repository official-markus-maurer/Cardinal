/**
 * @file vulkan_barrier_validation.h
 * @brief Memory barrier and synchronization validation for multi-threaded
 * Vulkan command recording
 *
 * This module provides validation utilities for ensuring proper memory barriers
 * and synchronization in multi-threaded command buffer recording scenarios. It
 * helps detect potential race conditions and synchronization issues during
 * development.
 *
 * Key features:
 * - Memory barrier validation for command buffer recording
 * - Thread-safe access tracking for resources
 * - Synchronization point validation
 * - Debug logging for barrier issues
 * - Integration with multi-threaded command recording
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_RENDERER_VULKAN_BARRIER_VALIDATION_H
#define CARDINAL_RENDERER_VULKAN_BARRIER_VALIDATION_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct VulkanState VulkanState;
typedef struct CardinalSecondaryCommandContext CardinalSecondaryCommandContext;

/**
 * @brief Resource access types for validation
 */
typedef enum CardinalResourceAccessType {
  CARDINAL_ACCESS_READ,
  CARDINAL_ACCESS_WRITE,
  CARDINAL_ACCESS_READ_WRITE
} CardinalResourceAccessType;

/**
 * @brief Resource types for barrier validation
 */
typedef enum CardinalResourceType {
  CARDINAL_RESOURCE_BUFFER,
  CARDINAL_RESOURCE_IMAGE,
  CARDINAL_RESOURCE_DESCRIPTOR_SET
} CardinalResourceType;

/**
 * @brief Resource access tracking entry
 */
typedef struct CardinalResourceAccess {
  uint64_t resource_id;                   // Unique resource identifier
  CardinalResourceType resource_type;     // Type of resource
  CardinalResourceAccessType access_type; // Type of access
  VkPipelineStageFlags2 stage_mask; // Pipeline stages accessing the resource
  VkAccessFlags2 access_mask;       // Access flags
  uint32_t thread_id;               // Thread performing the access
  uint64_t timestamp;               // Timestamp of access
  VkCommandBuffer command_buffer;   // Command buffer recording the access
} CardinalResourceAccess;

/**
 * @brief Barrier validation context
 */
typedef struct CardinalBarrierValidationContext {
  CardinalResourceAccess *resource_accesses; // Array of resource accesses
  uint32_t access_count;                     // Number of tracked accesses
  uint32_t max_accesses;                     // Maximum number of accesses
  bool validation_enabled;                   // Whether validation is enabled
  bool strict_mode;                          // Whether to use strict validation
} CardinalBarrierValidationContext;

/**
 * @brief Initialize the barrier validation system
 *
 * @param max_tracked_accesses Maximum number of resource accesses to track
 * @param strict_mode Whether to enable strict validation mode
 * @return true on success, false on failure
 */
bool cardinal_barrier_validation_init(uint32_t max_tracked_accesses,
                                      bool strict_mode);

/**
 * @brief Shutdown the barrier validation system
 */
void cardinal_barrier_validation_shutdown(void);

/**
 * @brief Enable or disable barrier validation
 *
 * @param enabled Whether validation should be enabled
 */
void cardinal_barrier_validation_set_enabled(bool enabled);

/**
 * @brief Track a resource access in a command buffer
 *
 * @param resource_id Unique identifier for the resource
 * @param resource_type Type of the resource
 * @param access_type Type of access being performed
 * @param stage_mask Pipeline stages accessing the resource
 * @param access_mask Access flags
 * @param thread_id Thread performing the access
 * @param command_buffer Command buffer recording the access
 * @return true on success, false on failure
 */
bool cardinal_barrier_validation_track_access(
    uint64_t resource_id, CardinalResourceType resource_type,
    CardinalResourceAccessType access_type, VkPipelineStageFlags2 stage_mask,
    VkAccessFlags2 access_mask, uint32_t thread_id,
    VkCommandBuffer command_buffer);

/**
 * @brief Validate a memory barrier before recording
 *
 * @param barrier Pointer to the memory barrier
 * @param command_buffer Command buffer where barrier will be recorded
 * @param thread_id Thread recording the barrier
 * @return true if barrier is valid, false if issues detected
 */
bool cardinal_barrier_validation_validate_memory_barrier(
    const VkMemoryBarrier2 *barrier, VkCommandBuffer command_buffer,
    uint32_t thread_id);

/**
 * @brief Validate a buffer memory barrier before recording
 *
 * @param barrier Pointer to the buffer memory barrier
 * @param command_buffer Command buffer where barrier will be recorded
 * @param thread_id Thread recording the barrier
 * @return true if barrier is valid, false if issues detected
 */
bool cardinal_barrier_validation_validate_buffer_barrier(
    const VkBufferMemoryBarrier2 *barrier, VkCommandBuffer command_buffer,
    uint32_t thread_id);

/**
 * @brief Validate an image memory barrier before recording
 *
 * @param barrier Pointer to the image memory barrier
 * @param command_buffer Command buffer where barrier will be recorded
 * @param thread_id Thread recording the barrier
 * @return true if barrier is valid, false if issues detected
 */
bool cardinal_barrier_validation_validate_image_barrier(
    const VkImageMemoryBarrier2 *barrier, VkCommandBuffer command_buffer,
    uint32_t thread_id);

/**
 * @brief Validate a pipeline barrier before recording
 *
 * @param dependency_info Pointer to the dependency info
 * @param command_buffer Command buffer where barrier will be recorded
 * @param thread_id Thread recording the barrier
 * @return true if barrier is valid, false if issues detected
 */
bool cardinal_barrier_validation_validate_pipeline_barrier(
    const VkDependencyInfo *dependency_info, VkCommandBuffer command_buffer,
    uint32_t thread_id);

/**
 * @brief Validate secondary command buffer recording
 *
 * @param context Secondary command buffer context
 * @return true if recording is safe, false if issues detected
 */
bool cardinal_barrier_validation_validate_secondary_recording(
    const CardinalSecondaryCommandContext *context);

/**
 * @brief Check for potential race conditions between threads
 *
 * @param thread_id1 First thread ID
 * @param thread_id2 Second thread ID
 * @return true if race condition detected, false otherwise
 */
bool cardinal_barrier_validation_check_race_condition(uint32_t thread_id1,
                                                      uint32_t thread_id2);

/**
 * @brief Get validation statistics
 *
 * @param out_total_accesses Total number of tracked accesses
 * @param out_validation_errors Number of validation errors detected
 * @param out_race_conditions Number of race conditions detected
 */
void cardinal_barrier_validation_get_stats(uint32_t *out_total_accesses,
                                           uint32_t *out_validation_errors,
                                           uint32_t *out_race_conditions);

/**
 * @brief Clear all tracked resource accesses
 */
void cardinal_barrier_validation_clear_accesses(void);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_RENDERER_VULKAN_BARRIER_VALIDATION_H
