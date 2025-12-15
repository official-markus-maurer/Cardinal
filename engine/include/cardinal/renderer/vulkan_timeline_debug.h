/**
 * @file vulkan_timeline_debug.h
 * @brief Timeline semaphore debugging and profiling utilities
 *
 * This file provides comprehensive debugging and profiling tools for timeline
 * semaphores, including performance monitoring, state tracking, and diagnostic
 * information collection.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_TIMELINE_DEBUG_H
#define VULKAN_TIMELINE_DEBUG_H

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

// Debug configuration
#define VULKAN_TIMELINE_DEBUG_MAX_EVENTS 1000
#define VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH 64

// Debug event types
typedef enum {
  VULKAN_TIMELINE_EVENT_WAIT_START,
  VULKAN_TIMELINE_EVENT_WAIT_END,
  VULKAN_TIMELINE_EVENT_SIGNAL_START,
  VULKAN_TIMELINE_EVENT_SIGNAL_END,
  VULKAN_TIMELINE_EVENT_VALUE_QUERY,
  VULKAN_TIMELINE_EVENT_ERROR,
  VULKAN_TIMELINE_EVENT_RECOVERY,
  VULKAN_TIMELINE_EVENT_POOL_ALLOC,
  VULKAN_TIMELINE_EVENT_POOL_DEALLOC
} VulkanTimelineEventType;

// Debug event structure
typedef struct {
  VulkanTimelineEventType type;
  uint64_t timestamp_ns;
  uint64_t timeline_value;
  uint64_t duration_ns; // For end events
  VkResult result;
  uint32_t thread_id;
  char name[VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH];
  char details[128];
} VulkanTimelineDebugEvent;

// Performance metrics
typedef struct {
  atomic_uint_fast64_t total_waits;
  atomic_uint_fast64_t total_signals;
  atomic_uint_fast64_t total_wait_time_ns;
  atomic_uint_fast64_t total_signal_time_ns;
  atomic_uint_fast64_t max_wait_time_ns;
  atomic_uint_fast64_t max_signal_time_ns;
  atomic_uint_fast64_t timeout_count;
  atomic_uint_fast64_t error_count;
  atomic_uint_fast64_t recovery_count;
} VulkanTimelinePerformanceMetrics;

// Timeline state snapshot
typedef struct {
  uint64_t current_value;
  uint64_t pending_signals;
  uint64_t pending_waits;
  uint64_t last_signaled_value;
  uint64_t next_expected_value;
  bool is_valid;
  VkResult last_error;
} VulkanTimelineStateSnapshot;

// Debug context
typedef struct {
  bool enabled;
  bool collect_events;
  bool collect_performance;
  bool verbose_logging;

  // Event ring buffer
  VulkanTimelineDebugEvent events[VULKAN_TIMELINE_DEBUG_MAX_EVENTS];
  atomic_uint_fast32_t event_write_index;
  atomic_uint_fast32_t event_count;

  // Performance metrics
  VulkanTimelinePerformanceMetrics metrics;

  // State tracking
  VulkanTimelineStateSnapshot last_snapshot;
  uint64_t snapshot_interval_ns;
  uint64_t last_snapshot_time;

  // Thread safety
  void *mutex; // Platform-specific mutex
} VulkanTimelineDebugContext;

// Debug context management
bool vulkan_timeline_debug_init(VulkanTimelineDebugContext *debug_ctx);
void vulkan_timeline_debug_destroy(VulkanTimelineDebugContext *debug_ctx);
void vulkan_timeline_debug_reset(VulkanTimelineDebugContext *debug_ctx);

// Configuration
void vulkan_timeline_debug_set_enabled(VulkanTimelineDebugContext *debug_ctx,
                                       bool enabled);
void vulkan_timeline_debug_set_event_collection(
    VulkanTimelineDebugContext *debug_ctx, bool enabled);
void vulkan_timeline_debug_set_performance_collection(
    VulkanTimelineDebugContext *debug_ctx, bool enabled);
void vulkan_timeline_debug_set_verbose_logging(
    VulkanTimelineDebugContext *debug_ctx, bool enabled);
void vulkan_timeline_debug_set_snapshot_interval(
    VulkanTimelineDebugContext *debug_ctx, uint64_t interval_ns);

// Event logging
void vulkan_timeline_debug_log_event(VulkanTimelineDebugContext *debug_ctx,
                                     VulkanTimelineEventType type,
                                     uint64_t timeline_value, VkResult result,
                                     const char *name, const char *details);

void vulkan_timeline_debug_log_wait_start(VulkanTimelineDebugContext *debug_ctx,
                                          uint64_t value, uint64_t timeout_ns,
                                          const char *name);

void vulkan_timeline_debug_log_wait_end(VulkanTimelineDebugContext *debug_ctx,
                                        uint64_t value, VkResult result,
                                        uint64_t duration_ns, const char *name);

void vulkan_timeline_debug_log_signal_start(
    VulkanTimelineDebugContext *debug_ctx, uint64_t value, const char *name);

void vulkan_timeline_debug_log_signal_end(VulkanTimelineDebugContext *debug_ctx,
                                          uint64_t value, VkResult result,
                                          uint64_t duration_ns,
                                          const char *name);

// Performance tracking
void vulkan_timeline_debug_update_wait_metrics(
    VulkanTimelineDebugContext *debug_ctx, uint64_t duration_ns,
    bool timed_out);

void vulkan_timeline_debug_update_signal_metrics(
    VulkanTimelineDebugContext *debug_ctx, uint64_t duration_ns);

void vulkan_timeline_debug_increment_error_count(
    VulkanTimelineDebugContext *debug_ctx);
void vulkan_timeline_debug_increment_recovery_count(
    VulkanTimelineDebugContext *debug_ctx);

// State snapshots
void vulkan_timeline_debug_take_snapshot(VulkanTimelineDebugContext *debug_ctx,
                                         VkDevice device,
                                         VkSemaphore timeline_semaphore);

bool vulkan_timeline_debug_should_take_snapshot(
    VulkanTimelineDebugContext *debug_ctx);

// Query functions
bool vulkan_timeline_debug_get_performance_metrics(
    VulkanTimelineDebugContext *debug_ctx,
    VulkanTimelinePerformanceMetrics *metrics);

bool vulkan_timeline_debug_get_last_snapshot(
    VulkanTimelineDebugContext *debug_ctx,
    VulkanTimelineStateSnapshot *snapshot);

uint32_t
vulkan_timeline_debug_get_event_count(VulkanTimelineDebugContext *debug_ctx);

bool vulkan_timeline_debug_get_events(VulkanTimelineDebugContext *debug_ctx,
                                      VulkanTimelineDebugEvent *events,
                                      uint32_t max_events,
                                      uint32_t *actual_count);

// Analysis and reporting
void vulkan_timeline_debug_print_performance_report(
    VulkanTimelineDebugContext *debug_ctx);
void vulkan_timeline_debug_print_event_summary(
    VulkanTimelineDebugContext *debug_ctx);
void vulkan_timeline_debug_print_state_report(
    VulkanTimelineDebugContext *debug_ctx);

// Export functions
bool vulkan_timeline_debug_export_events_csv(
    VulkanTimelineDebugContext *debug_ctx, const char *filename);

bool vulkan_timeline_debug_export_performance_json(
    VulkanTimelineDebugContext *debug_ctx, const char *filename);

// Utility functions
const char *
vulkan_timeline_debug_event_type_to_string(VulkanTimelineEventType type);
uint64_t vulkan_timeline_debug_get_timestamp_ns(void);
uint32_t vulkan_timeline_debug_get_thread_id(void);

// Macros for convenient debugging (only active in debug builds)
#ifdef VULKAN_TIMELINE_DEBUG_ENABLED
#define VULKAN_TIMELINE_DEBUG_LOG_WAIT_START(ctx, value, timeout, name)        \
  vulkan_timeline_debug_log_wait_start(ctx, value, timeout, name)

#define VULKAN_TIMELINE_DEBUG_LOG_WAIT_END(ctx, value, result, duration, name) \
  vulkan_timeline_debug_log_wait_end(ctx, value, result, duration, name)

#define VULKAN_TIMELINE_DEBUG_LOG_SIGNAL_START(ctx, value, name)               \
  vulkan_timeline_debug_log_signal_start(ctx, value, name)

#define VULKAN_TIMELINE_DEBUG_LOG_SIGNAL_END(ctx, value, result, duration,     \
                                             name)                             \
  vulkan_timeline_debug_log_signal_end(ctx, value, result, duration, name)

#define VULKAN_TIMELINE_DEBUG_TAKE_SNAPSHOT_IF_NEEDED(ctx, device, semaphore)  \
  do {                                                                         \
    if (vulkan_timeline_debug_should_take_snapshot(ctx)) {                     \
      vulkan_timeline_debug_take_snapshot(ctx, device, semaphore);             \
    }                                                                          \
  } while (0)
#else
#define VULKAN_TIMELINE_DEBUG_LOG_WAIT_START(ctx, value, timeout, name)        \
  ((void)0)
#define VULKAN_TIMELINE_DEBUG_LOG_WAIT_END(ctx, value, result, duration, name) \
  ((void)0)
#define VULKAN_TIMELINE_DEBUG_LOG_SIGNAL_START(ctx, value, name) ((void)0)
#define VULKAN_TIMELINE_DEBUG_LOG_SIGNAL_END(ctx, value, result, duration,     \
                                             name)                             \
  ((void)0)
#define VULKAN_TIMELINE_DEBUG_TAKE_SNAPSHOT_IF_NEEDED(ctx, device, semaphore)  \
  ((void)0)
#endif

#ifdef __cplusplus
}
#endif

#endif // VULKAN_TIMELINE_DEBUG_H
