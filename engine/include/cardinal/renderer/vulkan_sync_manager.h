/**
 * @file vulkan_sync_manager.h
 * @brief Vulkan synchronization primitive management for Cardinal Engine
 *
 * This module provides centralized management of Vulkan synchronization
 * primitives including semaphores, fences, and barriers. It handles
 * frame-in-flight tracking, timeline semaphores, and proper CPU-GPU
 * synchronization.
 *
 * Key responsibilities:
 * - Semaphore creation and management (binary and timeline)
 * - Fence creation and management for CPU-GPU sync
 * - Frame-in-flight tracking and synchronization
 * - Pipeline barrier management
 * - Command buffer synchronization
 * - Swapchain synchronization primitives
 *
 * The sync manager ensures proper ordering of GPU operations and prevents
 * race conditions between frames in flight.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_SYNC_MANAGER_H
#define VULKAN_SYNC_MANAGER_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
#ifdef __cplusplus
#if __cplusplus >= 202302L
#include <stdatomic.h>
#else
#include <atomic>
typedef std::atomic<uint64_t> atomic_uint_fast64_t;
typedef std::atomic<uint32_t> atomic_uint_fast32_t;
#endif
#elif defined(__zig__) || defined(__zig_translate_c__) || defined(CARDINAL_ZIG_BUILD)
// Zig-friendly atomic definitions
#ifndef CARDINAL_ZIG_ATOMICS_DEFINED
#define CARDINAL_ZIG_ATOMICS_DEFINED
#define atomic_uint_fast64_t uint64_t
#define atomic_uint_fast32_t uint32_t
#endif
#else
#include <stdatomic.h>
#endif

// Forward declarations
typedef struct VulkanState VulkanState;

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct {
  uint64_t base_value;
  uint64_t increment_step;
  uint64_t max_safe_value;
  uint64_t overflow_threshold;
  bool auto_reset_enabled;
} VulkanTimelineValueStrategy;

/**
 * @brief Synchronization manager structure
 */
typedef struct VulkanSyncManager {
  VkDevice device;
  VkQueue graphics_queue;
  uint32_t max_frames_in_flight;

  // Per-frame synchronization objects
  VkSemaphore
      *image_acquired_semaphores; /**< Semaphores for image acquisition */
  VkSemaphore
      *render_finished_semaphores; /**< Semaphores for render completion */
  VkFence *in_flight_fences;       /**< Fences for CPU-GPU sync */

  // Timeline semaphore for advanced synchronization
  VkSemaphore timeline_semaphore;
  atomic_uint_fast64_t current_frame_value;
  atomic_uint_fast64_t image_available_value;
  atomic_uint_fast64_t render_complete_value;
  atomic_uint_fast64_t global_timeline_counter;

  // Performance statistics
  atomic_uint_fast64_t timeline_wait_count;
  atomic_uint_fast64_t timeline_signal_count;

  // Timeline value optimization strategy
  VulkanTimelineValueStrategy value_strategy;

  // Frame tracking
  uint32_t current_frame;

  // Initialization state
  bool initialized;
} VulkanSyncManager;

/**
 * @brief Frame synchronization info for submit operations
 */
typedef struct {
  VkSemaphore wait_semaphore;
  VkSemaphore signal_semaphore;
  VkFence fence;
  uint64_t timeline_value;
  VkPipelineStageFlags wait_stage;
} VulkanFrameSyncInfo;

// Core sync manager functions

/**
 * @brief Initialize the synchronization manager
 * @param sync_manager Sync manager to initialize
 * @param device Vulkan device
 * @param max_frames_in_flight Maximum frames in flight
 * @return true on success, false on failure
 */
bool vulkan_sync_manager_init(VulkanSyncManager *sync_manager, VkDevice device,
                              VkQueue graphics_queue,
                              uint32_t max_frames_in_flight);

/**
 * @brief Destroy the synchronization manager
 * @param sync_manager Sync manager to destroy
 */
void vulkan_sync_manager_destroy(VulkanSyncManager *sync_manager);

/**
 * @brief Wait for the current frame's fence
 * @param sync_manager Sync manager
 * @param timeout_ns Timeout in nanoseconds (UINT64_MAX for infinite)
 * @return VK_SUCCESS on success, error code on failure
 */
VkResult vulkan_sync_manager_wait_for_frame(VulkanSyncManager *sync_manager,
                                            uint64_t timeout_ns);

/**
 * @brief Reset the current frame's fence
 * @param sync_manager Sync manager
 * @return VK_SUCCESS on success, error code on failure
 */
VkResult vulkan_sync_manager_reset_frame_fence(VulkanSyncManager *sync_manager);

/**
 * @brief Advance to the next frame
 * @param sync_manager Sync manager
 */
void vulkan_sync_manager_advance_frame(VulkanSyncManager *sync_manager);

// Semaphore management

/**
 * @brief Get synchronization info for the current frame
 * @param sync_manager Sync manager
 * @param sync_info Output synchronization info
 */
void vulkan_sync_manager_get_frame_sync_info(VulkanSyncManager *sync_manager,
                                             VulkanFrameSyncInfo *sync_info);

/**
 * @brief Create additional semaphore
 * @param sync_manager Sync manager
 * @param semaphore Output semaphore
 * @return true on success, false on failure
 */
bool vulkan_sync_manager_create_semaphore(VulkanSyncManager *sync_manager,
                                          VkSemaphore *semaphore);

/**
 * @brief Create additional fence
 * @param sync_manager Sync manager
 * @param signaled Whether fence should start signaled
 * @param fence Output fence
 * @return true on success, false on failure
 */
bool vulkan_sync_manager_create_fence(VulkanSyncManager *sync_manager,
                                      bool signaled, VkFence *fence);

/**
 * @brief Destroy semaphore
 * @param sync_manager Sync manager
 * @param semaphore Semaphore to destroy
 */
void vulkan_sync_manager_destroy_semaphore(VulkanSyncManager *sync_manager,
                                           VkSemaphore semaphore);

/**
 * @brief Destroy fence
 * @param sync_manager Sync manager
 * @param fence Fence to destroy
 */
void vulkan_sync_manager_destroy_fence(VulkanSyncManager *sync_manager,
                                       VkFence fence);

// Timeline semaphore functions

/**
 * @brief Wait for timeline semaphore value
 * @param sync_manager Sync manager
 * @param value Value to wait for
 * @param timeout_ns Timeout in nanoseconds
 * @return VK_SUCCESS on success, error code on failure
 */
VkResult vulkan_sync_manager_wait_timeline(VulkanSyncManager *sync_manager,
                                           uint64_t value, uint64_t timeout_ns);

/**
 * @brief Signal timeline semaphore
 * @param sync_manager Sync manager
 * @param value Value to signal
 * @return VK_SUCCESS on success, error code on failure
 */
VkResult vulkan_sync_manager_signal_timeline(VulkanSyncManager *sync_manager,
                                             uint64_t value);

/**
 * @brief Get current timeline semaphore value
 * @param sync_manager Sync manager
 * @param value Output current value
 * @return VK_SUCCESS on success, error code on failure
 */
VkResult vulkan_sync_manager_get_timeline_value(VulkanSyncManager *sync_manager,
                                                uint64_t *value);

/**
 * @brief Get next unique timeline semaphore value
 * @param sync_manager Sync manager
 * @return Next unique timeline value (0 on error)
 */
uint64_t
vulkan_sync_manager_get_next_timeline_value(VulkanSyncManager *sync_manager);

/**
 * @brief Wait for multiple timeline semaphore values (batch operation)
 * @param sync_manager Sync manager
 * @param values Array of values to wait for
 * @param count Number of values
 * @param timeout_ns Timeout in nanoseconds
 * @return VK_SUCCESS on success, error code on failure
 */
VkResult
vulkan_sync_manager_wait_timeline_batch(VulkanSyncManager *sync_manager,
                                        const uint64_t *values, uint32_t count,
                                        uint64_t timeout_ns);

/**
 * @brief Signal multiple timeline semaphore values (batch operation)
 * @param sync_manager Sync manager
 * @param values Array of values to signal
 * @param count Number of values
 * @return VK_SUCCESS on success, error code on failure
 */
VkResult vulkan_sync_manager_signal_timeline_batch(
    VulkanSyncManager *sync_manager, const uint64_t *values, uint32_t count);

/**
 * @brief Check if timeline semaphore has reached a specific value
 * @param sync_manager Sync manager
 * @param value Value to check
 * @param reached Output boolean indicating if value is reached
 * @return VK_SUCCESS on success, error code on failure
 */
VkResult
vulkan_sync_manager_is_timeline_value_reached(VulkanSyncManager *sync_manager,
                                              uint64_t value, bool *reached);

/**
 * @brief Get timeline semaphore performance statistics
 * @param sync_manager Sync manager
 * @param wait_count Output total number of waits performed
 * @param signal_count Output total number of signals performed
 * @param current_value Output current timeline value
 * @return VK_SUCCESS on success, error code on failure
 */
VkResult vulkan_sync_manager_get_timeline_stats(VulkanSyncManager *sync_manager,
                                                uint64_t *wait_count,
                                                uint64_t *signal_count,
                                                uint64_t *current_value);

// Error handling and recovery
typedef enum {
  VULKAN_TIMELINE_ERROR_NONE = 0,
  VULKAN_TIMELINE_ERROR_TIMEOUT,
  VULKAN_TIMELINE_ERROR_DEVICE_LOST,
  VULKAN_TIMELINE_ERROR_OUT_OF_MEMORY,
  VULKAN_TIMELINE_ERROR_INVALID_VALUE,
  VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID,
  VULKAN_TIMELINE_ERROR_UNKNOWN
} VulkanTimelineError;

typedef struct {
  VulkanTimelineError error_type;
  VkResult vulkan_result;
  uint64_t timeline_value;
  uint64_t timeout_ns;
  char error_message[256];
} VulkanTimelineErrorInfo;

// Enhanced error handling functions
VulkanTimelineError
vulkan_sync_manager_wait_timeline_safe(VulkanSyncManager *sync_manager,
                                       uint64_t value, uint64_t timeout_ns,
                                       VulkanTimelineErrorInfo *error_info);

VulkanTimelineError
vulkan_sync_manager_signal_timeline_safe(VulkanSyncManager *sync_manager,
                                         uint64_t value,
                                         VulkanTimelineErrorInfo *error_info);

bool vulkan_sync_manager_recover_timeline_semaphore(
    VulkanSyncManager *sync_manager, VulkanTimelineErrorInfo *error_info);

bool vulkan_sync_manager_validate_timeline_state(
    VulkanSyncManager *sync_manager);

const char *vulkan_timeline_error_to_string(VulkanTimelineError error);

// Timeline value optimization strategy functions

// Optimized timeline value management
bool vulkan_sync_manager_init_value_strategy(VulkanSyncManager *sync_manager,
                                             uint64_t increment_step,
                                             bool auto_reset_enabled);

uint64_t
vulkan_sync_manager_get_optimized_next_value(VulkanSyncManager *sync_manager,
                                             uint64_t min_increment);

bool vulkan_sync_manager_check_overflow_risk(VulkanSyncManager *sync_manager,
                                             uint64_t *remaining_values);

bool vulkan_sync_manager_reset_timeline_values(VulkanSyncManager *sync_manager);

void vulkan_sync_manager_optimize_value_allocation(
    VulkanSyncManager *sync_manager);

// Utility functions

/**
 * @brief Check if current frame fence is signaled
 * @param sync_manager Sync manager
 * @return true if signaled, false otherwise
 */
bool vulkan_sync_manager_is_frame_ready(VulkanSyncManager *sync_manager);

/**
 * @brief Get current frame index
 * @param sync_manager Sync manager
 * @return Current frame index
 */
uint32_t vulkan_sync_manager_get_current_frame(VulkanSyncManager *sync_manager);

/**
 * @brief Get maximum frames in flight
 * @param sync_manager Sync manager
 * @return Maximum frames in flight
 */
uint32_t vulkan_sync_manager_get_max_frames(VulkanSyncManager *sync_manager);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_SYNC_MANAGER_H
