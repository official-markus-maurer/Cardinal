/**
 * @file vulkan_timeline_pool.h
 * @brief Timeline semaphore pooling system for Cardinal Engine
 *
 * This module provides a pooling system for timeline semaphores to reduce
 * creation/destruction overhead and improve performance. It manages a pool
 * of reusable timeline semaphores with automatic allocation and recycling.
 *
 * Key features:
 * - Automatic semaphore allocation from pool
 * - Efficient recycling of unused semaphores
 * - Thread-safe pool operations
 * - Configurable pool size limits
 * - Performance statistics tracking
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_TIMELINE_POOL_H
#define VULKAN_TIMELINE_POOL_H

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

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Timeline semaphore pool entry
 */
typedef struct {
  VkSemaphore semaphore;
  uint64_t last_signaled_value;
  bool in_use;
  uint64_t creation_time;
} VulkanTimelinePoolEntry;

/**
 * @brief Timeline semaphore pool structure
 */
typedef struct {
  VkDevice device;
  VulkanTimelinePoolEntry *entries;
  uint32_t pool_size;
  uint32_t max_pool_size;
  atomic_uint_fast32_t active_count;

  // Thread safety
  void *mutex; // Platform-specific mutex

  // Performance statistics
  atomic_uint_fast64_t allocations;
  atomic_uint_fast64_t deallocations;
  atomic_uint_fast64_t cache_hits;
  atomic_uint_fast64_t cache_misses;

  // Configuration
  uint64_t max_idle_time_ns;
  bool auto_cleanup_enabled;

  bool initialized;
} VulkanTimelinePool;

/**
 * @brief Pool allocation result
 */
typedef struct {
  VkSemaphore semaphore;
  uint32_t pool_index;
  bool from_cache;
} VulkanTimelinePoolAllocation;

// Core pool functions

/**
 * @brief Initialize timeline semaphore pool
 * @param pool Pool to initialize
 * @param device Vulkan device
 * @param initial_size Initial pool size
 * @param max_size Maximum pool size (0 for unlimited)
 * @return true on success, false on failure
 */
bool vulkan_timeline_pool_init(VulkanTimelinePool *pool, VkDevice device,
                               uint32_t initial_size, uint32_t max_size);

/**
 * @brief Destroy timeline semaphore pool
 * @param pool Pool to destroy
 */
void vulkan_timeline_pool_destroy(VulkanTimelinePool *pool);

/**
 * @brief Allocate timeline semaphore from pool
 * @param pool Timeline pool
 * @param allocation Output allocation info
 * @return true on success, false on failure
 */
bool vulkan_timeline_pool_allocate(VulkanTimelinePool *pool,
                                   VulkanTimelinePoolAllocation *allocation);

/**
 * @brief Return timeline semaphore to pool
 * @param pool Timeline pool
 * @param pool_index Index returned from allocation
 * @param last_value Last signaled value for recycling
 */
void vulkan_timeline_pool_deallocate(VulkanTimelinePool *pool,
                                     uint32_t pool_index, uint64_t last_value);

/**
 * @brief Cleanup idle semaphores in pool
 * @param pool Timeline pool
 * @param current_time_ns Current time in nanoseconds
 * @return Number of semaphores cleaned up
 */
uint32_t vulkan_timeline_pool_cleanup_idle(VulkanTimelinePool *pool,
                                           uint64_t current_time_ns);

/**
 * @brief Get pool statistics
 * @param pool Timeline pool
 * @param active_count Output active semaphore count
 * @param total_allocations Output total allocations
 * @param cache_hit_rate Output cache hit rate (0.0-1.0)
 * @return true on success, false on failure
 */
bool vulkan_timeline_pool_get_stats(VulkanTimelinePool *pool,
                                    uint32_t *active_count,
                                    uint64_t *total_allocations,
                                    float *cache_hit_rate);

/**
 * @brief Configure pool auto-cleanup
 * @param pool Timeline pool
 * @param enabled Enable/disable auto cleanup
 * @param max_idle_time_ns Maximum idle time before cleanup
 */
void vulkan_timeline_pool_configure_cleanup(VulkanTimelinePool *pool,
                                            bool enabled,
                                            uint64_t max_idle_time_ns);

/**
 * @brief Reset pool statistics
 * @param pool Timeline pool
 */
void vulkan_timeline_pool_reset_stats(VulkanTimelinePool *pool);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_TIMELINE_POOL_H
