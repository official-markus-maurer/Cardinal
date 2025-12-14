/**
 * @file vulkan_timeline_debug.c
 * @brief Timeline semaphore debugging and profiling utilities implementation
 *
 * This file implements comprehensive debugging and profiling tools for timeline
 * semaphores, providing performance monitoring, state tracking, and diagnostic
 * information collection.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include <cardinal/core/log.h>
#include <cardinal/renderer/vulkan_timeline_debug.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
    #include <processthreadsapi.h>
    #include <windows.h>
    #define DEBUG_MUTEX CRITICAL_SECTION
    #define debug_mutex_init(m) InitializeCriticalSection((CRITICAL_SECTION*)(m))
    #define debug_mutex_destroy(m) DeleteCriticalSection((CRITICAL_SECTION*)(m))
    #define debug_mutex_lock(m) EnterCriticalSection((CRITICAL_SECTION*)(m))
    #define debug_mutex_unlock(m) LeaveCriticalSection((CRITICAL_SECTION*)(m))
#else
    #include <pthread.h>
    #include <sys/syscall.h>
    #include <unistd.h>
    #define DEBUG_MUTEX pthread_mutex_t
    #define debug_mutex_init(m) pthread_mutex_init((pthread_mutex_t*)(m), NULL)
    #define debug_mutex_destroy(m) pthread_mutex_destroy((pthread_mutex_t*)(m))
    #define debug_mutex_lock(m) pthread_mutex_lock((pthread_mutex_t*)(m))
    #define debug_mutex_unlock(m) pthread_mutex_unlock((pthread_mutex_t*)(m))
#endif

// Utility function implementations
uint64_t vulkan_timeline_debug_get_timestamp_ns(void) {
#ifdef _WIN32
    LARGE_INTEGER frequency, counter;
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&counter);
    return (uint64_t)((counter.QuadPart * 1000000000ULL) / frequency.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)(ts.tv_sec * 1000000000ULL + ts.tv_nsec);
#endif
}

uint32_t vulkan_timeline_debug_get_thread_id(void) {
#ifdef _WIN32
    return GetCurrentThreadId();
#else
    return (uint32_t)syscall(SYS_gettid);
#endif
}

const char* vulkan_timeline_debug_event_type_to_string(VulkanTimelineEventType type) {
    switch (type) {
        case VULKAN_TIMELINE_EVENT_WAIT_START:
            return "WAIT_START";
        case VULKAN_TIMELINE_EVENT_WAIT_END:
            return "WAIT_END";
        case VULKAN_TIMELINE_EVENT_SIGNAL_START:
            return "SIGNAL_START";
        case VULKAN_TIMELINE_EVENT_SIGNAL_END:
            return "SIGNAL_END";
        case VULKAN_TIMELINE_EVENT_VALUE_QUERY:
            return "VALUE_QUERY";
        case VULKAN_TIMELINE_EVENT_ERROR:
            return "ERROR";
        case VULKAN_TIMELINE_EVENT_RECOVERY:
            return "RECOVERY";
        case VULKAN_TIMELINE_EVENT_POOL_ALLOC:
            return "POOL_ALLOC";
        case VULKAN_TIMELINE_EVENT_POOL_DEALLOC:
            return "POOL_DEALLOC";
        default:
            return "UNKNOWN";
    }
}

// Debug context management
bool vulkan_timeline_debug_init(VulkanTimelineDebugContext* debug_ctx) {
    if (!debug_ctx) {
        return false;
    }

    memset(debug_ctx, 0, sizeof(VulkanTimelineDebugContext));

    // Initialize mutex
    debug_ctx->mutex = malloc(sizeof(DEBUG_MUTEX));
    if (!debug_ctx->mutex) {
        CARDINAL_LOG_ERROR("[TIMELINE_DEBUG] Failed to allocate mutex");
        return false;
    }
    debug_mutex_init(debug_ctx->mutex);

    // Initialize atomic variables
    atomic_store(&debug_ctx->event_write_index, 0);
    atomic_store(&debug_ctx->event_count, 0);

    // Initialize performance metrics
    atomic_store(&debug_ctx->metrics.total_waits, 0);
    atomic_store(&debug_ctx->metrics.total_signals, 0);
    atomic_store(&debug_ctx->metrics.total_wait_time_ns, 0);
    atomic_store(&debug_ctx->metrics.total_signal_time_ns, 0);
    atomic_store(&debug_ctx->metrics.max_wait_time_ns, 0);
    atomic_store(&debug_ctx->metrics.max_signal_time_ns, 0);
    atomic_store(&debug_ctx->metrics.timeout_count, 0);
    atomic_store(&debug_ctx->metrics.error_count, 0);
    atomic_store(&debug_ctx->metrics.recovery_count, 0);

    // Default configuration
    debug_ctx->enabled = true;
    debug_ctx->collect_events = true;
    debug_ctx->collect_performance = true;
    debug_ctx->verbose_logging = false;
    debug_ctx->snapshot_interval_ns = 1000000000ULL; // 1 second
    debug_ctx->last_snapshot_time = vulkan_timeline_debug_get_timestamp_ns();

    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Debug context initialized");
    return true;
}

void vulkan_timeline_debug_destroy(VulkanTimelineDebugContext* debug_ctx) {
    if (!debug_ctx || !debug_ctx->mutex) {
        return;
    }

    debug_mutex_destroy(debug_ctx->mutex);
    free(debug_ctx->mutex);

    memset(debug_ctx, 0, sizeof(VulkanTimelineDebugContext));

    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Debug context destroyed");
}

void vulkan_timeline_debug_reset(VulkanTimelineDebugContext* debug_ctx) {
    if (!debug_ctx || !debug_ctx->enabled) {
        return;
    }

    debug_mutex_lock(debug_ctx->mutex);

    // Reset event buffer
    atomic_store(&debug_ctx->event_write_index, 0);
    atomic_store(&debug_ctx->event_count, 0);
    memset(debug_ctx->events, 0, sizeof(debug_ctx->events));

    // Reset performance metrics
    atomic_store(&debug_ctx->metrics.total_waits, 0);
    atomic_store(&debug_ctx->metrics.total_signals, 0);
    atomic_store(&debug_ctx->metrics.total_wait_time_ns, 0);
    atomic_store(&debug_ctx->metrics.total_signal_time_ns, 0);
    atomic_store(&debug_ctx->metrics.max_wait_time_ns, 0);
    atomic_store(&debug_ctx->metrics.max_signal_time_ns, 0);
    atomic_store(&debug_ctx->metrics.timeout_count, 0);
    atomic_store(&debug_ctx->metrics.error_count, 0);
    atomic_store(&debug_ctx->metrics.recovery_count, 0);

    debug_ctx->last_snapshot_time = vulkan_timeline_debug_get_timestamp_ns();

    debug_mutex_unlock(debug_ctx->mutex);

    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Debug context reset");
}

// Configuration functions
void vulkan_timeline_debug_set_enabled(VulkanTimelineDebugContext* debug_ctx, bool enabled) {
    if (debug_ctx) {
        debug_ctx->enabled = enabled;
        CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Debug %s", enabled ? "enabled" : "disabled");
    }
}

void vulkan_timeline_debug_set_event_collection(VulkanTimelineDebugContext* debug_ctx,
                                                bool enabled) {
    if (debug_ctx) {
        debug_ctx->collect_events = enabled;
    }
}

void vulkan_timeline_debug_set_performance_collection(VulkanTimelineDebugContext* debug_ctx,
                                                      bool enabled) {
    if (debug_ctx) {
        debug_ctx->collect_performance = enabled;
    }
}

void vulkan_timeline_debug_set_verbose_logging(VulkanTimelineDebugContext* debug_ctx,
                                               bool enabled) {
    if (debug_ctx) {
        debug_ctx->verbose_logging = enabled;
    }
}

void vulkan_timeline_debug_set_snapshot_interval(VulkanTimelineDebugContext* debug_ctx,
                                                 uint64_t interval_ns) {
    if (debug_ctx) {
        debug_ctx->snapshot_interval_ns = interval_ns;
    }
}

// Event logging functions
void vulkan_timeline_debug_log_event(VulkanTimelineDebugContext* debug_ctx,
                                     VulkanTimelineEventType type, uint64_t timeline_value,
                                     VkResult result, const char* name, const char* details) {
    if (!debug_ctx || !debug_ctx->enabled || !debug_ctx->collect_events) {
        return;
    }

    uint32_t index =
        atomic_fetch_add(&debug_ctx->event_write_index, 1) % VULKAN_TIMELINE_DEBUG_MAX_EVENTS;

    VulkanTimelineDebugEvent* event = &debug_ctx->events[index];
    event->type = type;
    event->timestamp_ns = vulkan_timeline_debug_get_timestamp_ns();
    event->timeline_value = timeline_value;
    event->duration_ns = 0;
    event->result = result;
    event->thread_id = vulkan_timeline_debug_get_thread_id();

    if (name) {
        strncpy(event->name, name, VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH - 1);
        event->name[VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH - 1] = '\0';
    } else {
        event->name[0] = '\0';
    }

    if (details) {
        strncpy(event->details, details, sizeof(event->details) - 1);
        event->details[sizeof(event->details) - 1] = '\0';
    } else {
        event->details[0] = '\0';
    }

    atomic_fetch_add(&debug_ctx->event_count, 1);

    if (debug_ctx->verbose_logging) {
        CARDINAL_LOG_DEBUG("[TIMELINE_DEBUG] %s: value=%llu, result=%d, thread=%u, name=%s",
                           vulkan_timeline_debug_event_type_to_string(type), timeline_value, result,
                           event->thread_id, name ? name : "<unnamed>");
    }
}

void vulkan_timeline_debug_log_wait_start(VulkanTimelineDebugContext* debug_ctx, uint64_t value,
                                          uint64_t timeout_ns, const char* name) {
    char details[128];
    snprintf(details, sizeof(details), "timeout=%llu ns", timeout_ns);
    vulkan_timeline_debug_log_event(debug_ctx, VULKAN_TIMELINE_EVENT_WAIT_START, value, VK_SUCCESS,
                                    name, details);
}

void vulkan_timeline_debug_log_wait_end(VulkanTimelineDebugContext* debug_ctx, uint64_t value,
                                        VkResult result, uint64_t duration_ns, const char* name) {
    char details[128];
    snprintf(details, sizeof(details), "duration=%llu ns", duration_ns);

    // Find the corresponding start event and update its duration
    uint32_t current_index = atomic_load(&debug_ctx->event_write_index);
    for (uint32_t i = 0;
         i < VULKAN_TIMELINE_DEBUG_MAX_EVENTS && i < atomic_load(&debug_ctx->event_count); i++) {
        uint32_t check_index = (current_index - 1 - i) % VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        VulkanTimelineDebugEvent* event = &debug_ctx->events[check_index];

        if (event->type == VULKAN_TIMELINE_EVENT_WAIT_START && event->timeline_value == value &&
            event->thread_id == vulkan_timeline_debug_get_thread_id() && event->duration_ns == 0) {
            event->duration_ns = duration_ns;
            break;
        }
    }

    vulkan_timeline_debug_log_event(debug_ctx, VULKAN_TIMELINE_EVENT_WAIT_END, value, result, name,
                                    details);

    if (debug_ctx->collect_performance) {
        vulkan_timeline_debug_update_wait_metrics(debug_ctx, duration_ns, result == VK_TIMEOUT);
    }
}

void vulkan_timeline_debug_log_signal_start(VulkanTimelineDebugContext* debug_ctx, uint64_t value,
                                            const char* name) {
    vulkan_timeline_debug_log_event(debug_ctx, VULKAN_TIMELINE_EVENT_SIGNAL_START, value,
                                    VK_SUCCESS, name, NULL);
}

void vulkan_timeline_debug_log_signal_end(VulkanTimelineDebugContext* debug_ctx, uint64_t value,
                                          VkResult result, uint64_t duration_ns, const char* name) {
    char details[128];
    snprintf(details, sizeof(details), "duration=%llu ns", duration_ns);

    // Find the corresponding start event and update its duration
    uint32_t current_index = atomic_load(&debug_ctx->event_write_index);
    for (uint32_t i = 0;
         i < VULKAN_TIMELINE_DEBUG_MAX_EVENTS && i < atomic_load(&debug_ctx->event_count); i++) {
        uint32_t check_index = (current_index - 1 - i) % VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        VulkanTimelineDebugEvent* event = &debug_ctx->events[check_index];

        if (event->type == VULKAN_TIMELINE_EVENT_SIGNAL_START && event->timeline_value == value &&
            event->thread_id == vulkan_timeline_debug_get_thread_id() && event->duration_ns == 0) {
            event->duration_ns = duration_ns;
            break;
        }
    }

    vulkan_timeline_debug_log_event(debug_ctx, VULKAN_TIMELINE_EVENT_SIGNAL_END, value, result,
                                    name, details);

    if (debug_ctx->collect_performance) {
        vulkan_timeline_debug_update_signal_metrics(debug_ctx, duration_ns);
    }
}

// Performance tracking functions
void vulkan_timeline_debug_update_wait_metrics(VulkanTimelineDebugContext* debug_ctx,
                                               uint64_t duration_ns, bool timed_out) {
    if (!debug_ctx || !debug_ctx->enabled || !debug_ctx->collect_performance) {
        return;
    }

    atomic_fetch_add(&debug_ctx->metrics.total_waits, 1);
    atomic_fetch_add(&debug_ctx->metrics.total_wait_time_ns, duration_ns);

    if (timed_out) {
        atomic_fetch_add(&debug_ctx->metrics.timeout_count, 1);
    }

    // Update max wait time
    uint64_t current_max = atomic_load(&debug_ctx->metrics.max_wait_time_ns);
    while (duration_ns > current_max) {
        if (atomic_compare_exchange_weak(&debug_ctx->metrics.max_wait_time_ns, &current_max,
                                         duration_ns)) {
            break;
        }
    }
}

void vulkan_timeline_debug_update_signal_metrics(VulkanTimelineDebugContext* debug_ctx,
                                                 uint64_t duration_ns) {
    if (!debug_ctx || !debug_ctx->enabled || !debug_ctx->collect_performance) {
        return;
    }

    atomic_fetch_add(&debug_ctx->metrics.total_signals, 1);
    atomic_fetch_add(&debug_ctx->metrics.total_signal_time_ns, duration_ns);

    // Update max signal time
    uint64_t current_max = atomic_load(&debug_ctx->metrics.max_signal_time_ns);
    while (duration_ns > current_max) {
        if (atomic_compare_exchange_weak(&debug_ctx->metrics.max_signal_time_ns, &current_max,
                                         duration_ns)) {
            break;
        }
    }
}

void vulkan_timeline_debug_increment_error_count(VulkanTimelineDebugContext* debug_ctx) {
    if (debug_ctx && debug_ctx->enabled && debug_ctx->collect_performance) {
        atomic_fetch_add(&debug_ctx->metrics.error_count, 1);
    }
}

void vulkan_timeline_debug_increment_recovery_count(VulkanTimelineDebugContext* debug_ctx) {
    if (debug_ctx && debug_ctx->enabled && debug_ctx->collect_performance) {
        atomic_fetch_add(&debug_ctx->metrics.recovery_count, 1);
    }
}

// State snapshot functions
void vulkan_timeline_debug_take_snapshot(VulkanTimelineDebugContext* debug_ctx, VkDevice device,
                                         VkSemaphore timeline_semaphore) {
    if (!debug_ctx || !debug_ctx->enabled || !device || !timeline_semaphore) {
        return;
    }

    debug_mutex_lock(debug_ctx->mutex);

    VulkanTimelineStateSnapshot* snapshot = &debug_ctx->last_snapshot;

    // Get current timeline value
    VkResult result =
        vkGetSemaphoreCounterValue(device, timeline_semaphore, &snapshot->current_value);
    snapshot->is_valid = (result == VK_SUCCESS);
    snapshot->last_error = result;

    if (snapshot->is_valid) {
        // Update other snapshot fields (these would need additional context)
        snapshot->pending_signals = 0; // Would need tracking
        snapshot->pending_waits = 0;   // Would need tracking
        snapshot->last_signaled_value = snapshot->current_value;
        snapshot->next_expected_value = snapshot->current_value + 1;
    }

    debug_ctx->last_snapshot_time = vulkan_timeline_debug_get_timestamp_ns();

    debug_mutex_unlock(debug_ctx->mutex);

    if (debug_ctx->verbose_logging) {
        CARDINAL_LOG_DEBUG("[TIMELINE_DEBUG] Snapshot taken: value=%llu, valid=%s",
                           snapshot->current_value, snapshot->is_valid ? "true" : "false");
    }
}

bool vulkan_timeline_debug_should_take_snapshot(VulkanTimelineDebugContext* debug_ctx) {
    if (!debug_ctx || !debug_ctx->enabled) {
        return false;
    }

    uint64_t current_time = vulkan_timeline_debug_get_timestamp_ns();
    return (current_time - debug_ctx->last_snapshot_time) >= debug_ctx->snapshot_interval_ns;
}

// Query functions
bool vulkan_timeline_debug_get_performance_metrics(VulkanTimelineDebugContext* debug_ctx,
                                                   VulkanTimelinePerformanceMetrics* metrics) {
    if (!debug_ctx || !metrics) {
        return false;
    }

    metrics->total_waits = atomic_load(&debug_ctx->metrics.total_waits);
    metrics->total_signals = atomic_load(&debug_ctx->metrics.total_signals);
    metrics->total_wait_time_ns = atomic_load(&debug_ctx->metrics.total_wait_time_ns);
    metrics->total_signal_time_ns = atomic_load(&debug_ctx->metrics.total_signal_time_ns);
    metrics->max_wait_time_ns = atomic_load(&debug_ctx->metrics.max_wait_time_ns);
    metrics->max_signal_time_ns = atomic_load(&debug_ctx->metrics.max_signal_time_ns);
    metrics->timeout_count = atomic_load(&debug_ctx->metrics.timeout_count);
    metrics->error_count = atomic_load(&debug_ctx->metrics.error_count);
    metrics->recovery_count = atomic_load(&debug_ctx->metrics.recovery_count);

    return true;
}

bool vulkan_timeline_debug_get_last_snapshot(VulkanTimelineDebugContext* debug_ctx,
                                             VulkanTimelineStateSnapshot* snapshot) {
    if (!debug_ctx || !snapshot) {
        return false;
    }

    debug_mutex_lock(debug_ctx->mutex);
    *snapshot = debug_ctx->last_snapshot;
    debug_mutex_unlock(debug_ctx->mutex);

    return true;
}

uint32_t vulkan_timeline_debug_get_event_count(VulkanTimelineDebugContext* debug_ctx) {
    if (!debug_ctx) {
        return 0;
    }

    uint32_t count = atomic_load(&debug_ctx->event_count);
    return count > VULKAN_TIMELINE_DEBUG_MAX_EVENTS ? VULKAN_TIMELINE_DEBUG_MAX_EVENTS : count;
}

bool vulkan_timeline_debug_get_events(VulkanTimelineDebugContext* debug_ctx,
                                      VulkanTimelineDebugEvent* events, uint32_t max_events,
                                      uint32_t* actual_count) {
    if (!debug_ctx || !events || !actual_count) {
        return false;
    }

    debug_mutex_lock(debug_ctx->mutex);

    uint32_t available_events = vulkan_timeline_debug_get_event_count(debug_ctx);
    uint32_t copy_count = available_events < max_events ? available_events : max_events;

    uint32_t start_index = atomic_load(&debug_ctx->event_write_index);
    if (available_events < VULKAN_TIMELINE_DEBUG_MAX_EVENTS) {
        start_index = 0;
    } else {
        start_index = (start_index - available_events) % VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
    }

    for (uint32_t i = 0; i < copy_count; i++) {
        uint32_t index = (start_index + i) % VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        events[i] = debug_ctx->events[index];
    }

    *actual_count = copy_count;

    debug_mutex_unlock(debug_ctx->mutex);

    return true;
}

// Analysis and reporting functions
void vulkan_timeline_debug_print_performance_report(VulkanTimelineDebugContext* debug_ctx) {
    if (!debug_ctx) {
        return;
    }

    VulkanTimelinePerformanceMetrics metrics;
    if (!vulkan_timeline_debug_get_performance_metrics(debug_ctx, &metrics)) {
        return;
    }

    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] === Performance Report ===");
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Total waits: %llu", metrics.total_waits);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Total signals: %llu", metrics.total_signals);

    if (metrics.total_waits > 0) {
        uint64_t avg_wait = metrics.total_wait_time_ns / metrics.total_waits;
        CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Average wait time: %llu ns (%.3f ms)", avg_wait,
                          avg_wait / 1000000.0);
        CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Max wait time: %llu ns (%.3f ms)",
                          metrics.max_wait_time_ns, metrics.max_wait_time_ns / 1000000.0);
    }

    if (metrics.total_signals > 0) {
        uint64_t avg_signal = metrics.total_signal_time_ns / metrics.total_signals;
        CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Average signal time: %llu ns (%.3f ms)", avg_signal,
                          avg_signal / 1000000.0);
        CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Max signal time: %llu ns (%.3f ms)",
                          metrics.max_signal_time_ns, metrics.max_signal_time_ns / 1000000.0);
    }

    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Timeouts: %llu", metrics.timeout_count);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Errors: %llu", metrics.error_count);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Recoveries: %llu", metrics.recovery_count);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] =========================");
}

void vulkan_timeline_debug_print_event_summary(VulkanTimelineDebugContext* debug_ctx) {
    if (!debug_ctx) {
        return;
    }

    uint32_t event_count = vulkan_timeline_debug_get_event_count(debug_ctx);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] === Event Summary ===");
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Total events recorded: %u", event_count);

    // Count events by type
    uint32_t type_counts[9] = {0}; // Assuming 9 event types

    VulkanTimelineDebugEvent* events = malloc(event_count * sizeof(VulkanTimelineDebugEvent));
    if (events) {
        uint32_t actual_count;
        if (vulkan_timeline_debug_get_events(debug_ctx, events, event_count, &actual_count)) {
            for (uint32_t i = 0; i < actual_count; i++) {
                if (events[i].type < 9) {
                    type_counts[events[i].type]++;
                }
            }
        }
        free(events);
    }

    for (int i = 0; i < 9; i++) {
        if (type_counts[i] > 0) {
            CARDINAL_LOG_INFO(
                "[TIMELINE_DEBUG] %s: %u",
                vulkan_timeline_debug_event_type_to_string((VulkanTimelineEventType)i),
                type_counts[i]);
        }
    }

    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] ===================");
}

void vulkan_timeline_debug_print_state_report(VulkanTimelineDebugContext* debug_ctx) {
    if (!debug_ctx) {
        return;
    }

    VulkanTimelineStateSnapshot snapshot;
    if (!vulkan_timeline_debug_get_last_snapshot(debug_ctx, &snapshot)) {
        return;
    }

    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] === State Report ===");
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Current value: %llu", snapshot.current_value);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Last signaled: %llu", snapshot.last_signaled_value);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Next expected: %llu", snapshot.next_expected_value);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Pending signals: %llu", snapshot.pending_signals);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Pending waits: %llu", snapshot.pending_waits);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Valid: %s", snapshot.is_valid ? "true" : "false");
    if (!snapshot.is_valid) {
        CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Last error: %d", snapshot.last_error);
    }
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] =================");
}

// Export functions (simplified implementations)
bool vulkan_timeline_debug_export_events_csv(VulkanTimelineDebugContext* debug_ctx,
                                             const char* filename) {
    if (!debug_ctx || !filename) {
        return false;
    }

    FILE* file = fopen(filename, "w");
    if (!file) {
        CARDINAL_LOG_ERROR("[TIMELINE_DEBUG] Failed to open file for CSV export: %s", filename);
        return false;
    }

    // Write CSV header
    fprintf(file, "timestamp_ns,type,timeline_value,duration_ns,result,thread_id,name,details\n");

    uint32_t event_count = vulkan_timeline_debug_get_event_count(debug_ctx);
    VulkanTimelineDebugEvent* events = malloc(event_count * sizeof(VulkanTimelineDebugEvent));

    if (events) {
        uint32_t actual_count;
        if (vulkan_timeline_debug_get_events(debug_ctx, events, event_count, &actual_count)) {
            for (uint32_t i = 0; i < actual_count; i++) {
                fprintf(file, "%llu,%s,%llu,%llu,%d,%u,\"%s\",\"%s\"\n", events[i].timestamp_ns,
                        vulkan_timeline_debug_event_type_to_string(events[i].type),
                        events[i].timeline_value, events[i].duration_ns, events[i].result,
                        events[i].thread_id, events[i].name, events[i].details);
            }
        }
        free(events);
    }

    fclose(file);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Events exported to CSV: %s", filename);
    return true;
}

bool vulkan_timeline_debug_export_performance_json(VulkanTimelineDebugContext* debug_ctx,
                                                   const char* filename) {
    if (!debug_ctx || !filename) {
        return false;
    }

    VulkanTimelinePerformanceMetrics metrics;
    if (!vulkan_timeline_debug_get_performance_metrics(debug_ctx, &metrics)) {
        return false;
    }

    FILE* file = fopen(filename, "w");
    if (!file) {
        CARDINAL_LOG_ERROR("[TIMELINE_DEBUG] Failed to open file for JSON export: %s", filename);
        return false;
    }

    fprintf(file, "{\n");
    fprintf(file, "  \"total_waits\": %llu,\n", metrics.total_waits);
    fprintf(file, "  \"total_signals\": %llu,\n", metrics.total_signals);
    fprintf(file, "  \"total_wait_time_ns\": %llu,\n", metrics.total_wait_time_ns);
    fprintf(file, "  \"total_signal_time_ns\": %llu,\n", metrics.total_signal_time_ns);
    fprintf(file, "  \"max_wait_time_ns\": %llu,\n", metrics.max_wait_time_ns);
    fprintf(file, "  \"max_signal_time_ns\": %llu,\n", metrics.max_signal_time_ns);
    fprintf(file, "  \"timeout_count\": %llu,\n", metrics.timeout_count);
    fprintf(file, "  \"error_count\": %llu,\n", metrics.error_count);
    fprintf(file, "  \"recovery_count\": %llu\n", metrics.recovery_count);
    fprintf(file, "}\n");

    fclose(file);
    CARDINAL_LOG_INFO("[TIMELINE_DEBUG] Performance metrics exported to JSON: %s", filename);
    return true;
}
