/**
 * @file resource_state.c
 * @brief Resource state tracking system implementation for Cardinal Engine
 *
 * This file implements the resource state tracking system that extends
 * the reference counting system with thread-safe state management.
 * It prevents race conditions during resource loading and provides
 * synchronization primitives for safe concurrent access.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include "cardinal/core/resource_state.h"
#include "cardinal/core/log.h"
#include "cardinal/core/memory.h"
#include "../renderer/vulkan_mt.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
    #include <windows.h>
    #define GET_THREAD_ID() GetCurrentThreadId()
#else
    #include <pthread.h>
    #include <unistd.h>
    #include <sys/syscall.h>
    #define GET_THREAD_ID() (uint32_t)syscall(SYS_gettid)
#endif

// Global resource state registry
static CardinalResourceStateRegistry g_state_registry = {0};

/**
 * @brief Simple hash function for string identifiers
 * @param str String to hash
 * @return Hash value
 */
static uint32_t hash_string(const char* str) {
    uint32_t hash = 5381;
    int c;
    while ((c = *str++)) {
        hash = ((hash << 5) + hash) + c; // hash * 33 + c
    }
    return hash;
}

/**
 * @brief Get current timestamp in milliseconds
 * @return Current timestamp
 */
static uint64_t get_timestamp_ms(void) {
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
#endif
}

/**
 * @brief Find a resource state tracker by identifier (must hold registry mutex)
 * @param identifier Resource identifier
 * @return Pointer to the state tracker, or NULL if not found
 */
static CardinalResourceStateTracker* find_state_tracker_unsafe(const char* identifier) {
    if (!g_state_registry.initialized || !identifier) {
        return NULL;
    }

    uint32_t hash = hash_string(identifier);
    size_t bucket_index = hash % g_state_registry.bucket_count;

    CardinalResourceStateTracker* current = g_state_registry.buckets[bucket_index];
    while (current) {
        if (strcmp(current->identifier, identifier) == 0) {
            return current;
        }
        current = current->next;
    }

    return NULL;
}

bool cardinal_resource_state_init(size_t bucket_count) {
    if (g_state_registry.initialized) {
        CARDINAL_LOG_WARN("Resource state tracking system already initialized");
        return true;
    }

    if (bucket_count == 0) {
        bucket_count = 1009; // Default prime number
    }

    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    
    g_state_registry.buckets = (CardinalResourceStateTracker**)CARDINAL_ALLOCATE(
        CARDINAL_MEMORY_CATEGORY_ENGINE, bucket_count * sizeof(CardinalResourceStateTracker*));
    if (g_state_registry.buckets) {
        memset(g_state_registry.buckets, 0, bucket_count * sizeof(CardinalResourceStateTracker*));
    }
    if (!g_state_registry.buckets) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for resource state registry buckets");
        return false;
    }

    if (!cardinal_mt_mutex_init(&g_state_registry.registry_mutex)) {
        CARDINAL_LOG_ERROR("Failed to initialize resource state registry mutex");
        cardinal_free(allocator, g_state_registry.buckets);
        return false;
    }

    g_state_registry.bucket_count = bucket_count;
    g_state_registry.total_tracked_resources = 0;
    g_state_registry.initialized = true;

    CARDINAL_LOG_INFO("Resource state tracking system initialized with %zu buckets", bucket_count);
    return true;
}

void cardinal_resource_state_shutdown(void) {
    if (!g_state_registry.initialized) {
        return;
    }

    CARDINAL_LOG_INFO("Shutting down resource state tracking system...");

    cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);

    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    
    // Clean up all state trackers
    for (size_t i = 0; i < g_state_registry.bucket_count; i++) {
        CardinalResourceStateTracker* current = g_state_registry.buckets[i];
        while (current) {
            CardinalResourceStateTracker* next = current->next;

            CARDINAL_LOG_DEBUG("Cleaning up state tracker for resource '%s'", current->identifier);

            // Destroy synchronization primitives
            cardinal_mt_mutex_destroy(&current->state_mutex);
            cardinal_mt_cond_destroy(&current->state_changed);
            
            // Free identifier and tracker
            cardinal_free(allocator, current->identifier);
            cardinal_free(allocator, current);
            
            current = next;
        }
    }

    cardinal_free(allocator, g_state_registry.buckets);
    g_state_registry.buckets = NULL;
    g_state_registry.bucket_count = 0;
    g_state_registry.total_tracked_resources = 0;

    cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
    cardinal_mt_mutex_destroy(&g_state_registry.registry_mutex);
    
    g_state_registry.initialized = false;
    
    CARDINAL_LOG_INFO("Resource state tracking system shutdown complete");
}

CardinalResourceStateTracker* cardinal_resource_state_register(CardinalRefCountedResource* ref_resource) {
    if (!g_state_registry.initialized) {
        CARDINAL_LOG_ERROR("Resource state registry not initialized");
        return NULL;
    }
    if (!ref_resource) {
        CARDINAL_LOG_ERROR("ref_resource is NULL");
        return NULL;
    }
    if (!ref_resource->identifier) {
        CARDINAL_LOG_ERROR("ref_resource->identifier is NULL");
        return NULL;
    }

    cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);

    // Check if already tracked
    CardinalResourceStateTracker* existing = find_state_tracker_unsafe(ref_resource->identifier);
    if (existing) {
        cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return existing;
    }

    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    
    // Create new state tracker
    CardinalResourceStateTracker* tracker = (CardinalResourceStateTracker*)CARDINAL_ALLOCATE(
        CARDINAL_MEMORY_CATEGORY_ENGINE, sizeof(CardinalResourceStateTracker));
    if (tracker) {
        memset(tracker, 0, sizeof(CardinalResourceStateTracker));
    }
    if (!tracker) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for resource state tracker");
        cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return NULL;
    }

    // Initialize tracker
    tracker->ref_resource = ref_resource;
    tracker->state = CARDINAL_RESOURCE_STATE_UNLOADED;
    tracker->loading_thread_id = 0;
    tracker->state_change_timestamp = get_timestamp_ms();
    
    // Copy identifier
    size_t id_len = strlen(ref_resource->identifier) + 1;
    tracker->identifier = (char*)CARDINAL_ALLOCATE(CARDINAL_MEMORY_CATEGORY_ENGINE, id_len);
    if (!tracker->identifier) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for resource identifier copy");
        cardinal_free(allocator, tracker);
        cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return NULL;
    }
    strcpy(tracker->identifier, ref_resource->identifier);

    // Initialize synchronization primitives
    if (!cardinal_mt_mutex_init(&tracker->state_mutex)) {
        CARDINAL_LOG_ERROR("Failed to initialize state tracker mutex");
        cardinal_free(allocator, tracker->identifier);
        cardinal_free(allocator, tracker);
        cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return NULL;
    }

    if (!cardinal_mt_cond_init(&tracker->state_changed)) {
        CARDINAL_LOG_ERROR("Failed to initialize state tracker condition variable");
        cardinal_mt_mutex_destroy(&tracker->state_mutex);
        cardinal_free(allocator, tracker->identifier);
        cardinal_free(allocator, tracker);
        cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return NULL;
    }

    // Add to hash table
    uint32_t hash = hash_string(ref_resource->identifier);
    size_t bucket_index = hash % g_state_registry.bucket_count;
    tracker->next = g_state_registry.buckets[bucket_index];
    g_state_registry.buckets[bucket_index] = tracker;
    g_state_registry.total_tracked_resources++;

    cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    CARDINAL_LOG_DEBUG("Registered resource state tracker for '%s'", ref_resource->identifier);
    return tracker;
}

void cardinal_resource_state_unregister(const char* identifier) {
    if (!g_state_registry.initialized || !identifier) {
        return;
    }

    cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);

    uint32_t hash = hash_string(identifier);
    size_t bucket_index = hash % g_state_registry.bucket_count;

    CardinalResourceStateTracker** current = &g_state_registry.buckets[bucket_index];
    while (*current) {
        if (strcmp((*current)->identifier, identifier) == 0) {
            CardinalResourceStateTracker* to_remove = *current;
            *current = to_remove->next;

            CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
            
            // Destroy synchronization primitives
            cardinal_mt_mutex_destroy(&to_remove->state_mutex);
            cardinal_mt_cond_destroy(&to_remove->state_changed);
            
            // Free memory
            cardinal_free(allocator, to_remove->identifier);
            cardinal_free(allocator, to_remove);
            
            g_state_registry.total_tracked_resources--;
            
            CARDINAL_LOG_DEBUG("Unregistered resource state tracker for '%s'", identifier);
            break;
        }
        current = &(*current)->next;
    }

    cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
}

CardinalResourceState cardinal_resource_state_get(const char* identifier) {
    if (!g_state_registry.initialized || !identifier) {
        return CARDINAL_RESOURCE_STATE_UNLOADED;
    }

    cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);
    CardinalResourceStateTracker* tracker = find_state_tracker_unsafe(identifier);
    cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (!tracker) {
        return CARDINAL_RESOURCE_STATE_UNLOADED;
    }

    cardinal_mt_mutex_lock(&tracker->state_mutex);
    CardinalResourceState state = tracker->state;
    cardinal_mt_mutex_unlock(&tracker->state_mutex);

    return state;
}

bool cardinal_resource_state_set(const char* identifier, CardinalResourceState new_state, uint32_t loading_thread_id) {
    if (!g_state_registry.initialized || !identifier) {
        return false;
    }

    cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);
    CardinalResourceStateTracker* tracker = find_state_tracker_unsafe(identifier);
    cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (!tracker) {
        CARDINAL_LOG_ERROR("Cannot set state for untracked resource '%s'", identifier);
        return false;
    }

    cardinal_mt_mutex_lock(&tracker->state_mutex);

    // Validate state transitions
    CardinalResourceState old_state = tracker->state;
    bool valid_transition = false;

    switch (old_state) {
        case CARDINAL_RESOURCE_STATE_UNLOADED:
            valid_transition = (new_state == CARDINAL_RESOURCE_STATE_LOADING);
            break;
        case CARDINAL_RESOURCE_STATE_LOADING:
            // Only the loading thread can change from LOADING state
            if (tracker->loading_thread_id == loading_thread_id) {
                valid_transition = (new_state == CARDINAL_RESOURCE_STATE_LOADED || 
                                  new_state == CARDINAL_RESOURCE_STATE_ERROR);
            }
            break;
        case CARDINAL_RESOURCE_STATE_LOADED:
            valid_transition = (new_state == CARDINAL_RESOURCE_STATE_UNLOADING);
            break;
        case CARDINAL_RESOURCE_STATE_ERROR:
            valid_transition = (new_state == CARDINAL_RESOURCE_STATE_LOADING || 
                              new_state == CARDINAL_RESOURCE_STATE_UNLOADED);
            break;
        case CARDINAL_RESOURCE_STATE_UNLOADING:
            valid_transition = (new_state == CARDINAL_RESOURCE_STATE_UNLOADED);
            break;
    }

    if (!valid_transition) {
        CARDINAL_LOG_ERROR("Invalid state transition for resource '%s': %d -> %d", 
                          identifier, old_state, new_state);
        cardinal_mt_mutex_unlock(&tracker->state_mutex);
        return false;
    }

    // Update state
    tracker->state = new_state;
    tracker->state_change_timestamp = get_timestamp_ms();
    
    if (new_state == CARDINAL_RESOURCE_STATE_LOADING) {
        tracker->loading_thread_id = loading_thread_id;
    } else if (new_state == CARDINAL_RESOURCE_STATE_LOADED || 
               new_state == CARDINAL_RESOURCE_STATE_ERROR ||
               new_state == CARDINAL_RESOURCE_STATE_UNLOADED) {
        tracker->loading_thread_id = 0;
    }

    // Notify waiting threads
    cardinal_mt_cond_broadcast(&tracker->state_changed);
    
    cardinal_mt_mutex_unlock(&tracker->state_mutex);

    CARDINAL_LOG_DEBUG("Resource '%s' state changed: %d -> %d (thread %u)", 
                      identifier, old_state, new_state, loading_thread_id);
    return true;
}

bool cardinal_resource_state_wait_for(const char* identifier, CardinalResourceState target_state, uint32_t timeout_ms) {
    if (!g_state_registry.initialized || !identifier) {
        return false;
    }

    cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);
    CardinalResourceStateTracker* tracker = find_state_tracker_unsafe(identifier);
    cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (!tracker) {
        return false;
    }

    cardinal_mt_mutex_lock(&tracker->state_mutex);

    uint64_t start_time = get_timestamp_ms();
    
    while (tracker->state != target_state) {
        if (timeout_ms > 0) {
            uint64_t elapsed = get_timestamp_ms() - start_time;
            if (elapsed >= timeout_ms) {
                cardinal_mt_mutex_unlock(&tracker->state_mutex);
                CARDINAL_LOG_WARN("Timeout waiting for resource '%s' to reach state %d", 
                                 identifier, target_state);
                return false;
            }
            
            uint32_t remaining_ms = timeout_ms - (uint32_t)elapsed;
            if (!cardinal_mt_cond_wait_timeout(&tracker->state_changed, &tracker->state_mutex, remaining_ms)) {
                cardinal_mt_mutex_unlock(&tracker->state_mutex);
                return false;
            }
        } else {
            cardinal_mt_cond_wait(&tracker->state_changed, &tracker->state_mutex);
        }
    }

    cardinal_mt_mutex_unlock(&tracker->state_mutex);
    return true;
}

bool cardinal_resource_state_try_acquire_loading(const char* identifier, uint32_t loading_thread_id) {
    if (!g_state_registry.initialized || !identifier) {
        return false;
    }

    cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);
    CardinalResourceStateTracker* tracker = find_state_tracker_unsafe(identifier);
    cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (!tracker) {
        return false;
    }

    cardinal_mt_mutex_lock(&tracker->state_mutex);
    
    bool acquired = false;
    if (tracker->state == CARDINAL_RESOURCE_STATE_UNLOADED || 
        tracker->state == CARDINAL_RESOURCE_STATE_ERROR) {
        tracker->state = CARDINAL_RESOURCE_STATE_LOADING;
        tracker->loading_thread_id = loading_thread_id;
        tracker->state_change_timestamp = get_timestamp_ms();
        cardinal_mt_cond_broadcast(&tracker->state_changed);
        acquired = true;
    }
    
    cardinal_mt_mutex_unlock(&tracker->state_mutex);
    
    if (acquired) {
        CARDINAL_LOG_DEBUG("Thread %u acquired loading access for resource '%s'", 
                          loading_thread_id, identifier);
    }
    
    return acquired;
}

bool cardinal_resource_state_is_safe_to_access(const char* identifier) {
    return cardinal_resource_state_get(identifier) == CARDINAL_RESOURCE_STATE_LOADED;
}

void cardinal_resource_state_get_stats(uint32_t* out_total_tracked, uint32_t* out_loading_count, 
                                      uint32_t* out_loaded_count, uint32_t* out_error_count) {
    if (!g_state_registry.initialized) {
        if (out_total_tracked) *out_total_tracked = 0;
        if (out_loading_count) *out_loading_count = 0;
        if (out_loaded_count) *out_loaded_count = 0;
        if (out_error_count) *out_error_count = 0;
        return;
    }

    uint32_t total = 0, loading = 0, loaded = 0, error = 0;

    cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);
    
    for (size_t i = 0; i < g_state_registry.bucket_count; i++) {
        CardinalResourceStateTracker* current = g_state_registry.buckets[i];
        while (current) {
            total++;
            
            cardinal_mt_mutex_lock(&current->state_mutex);
            switch (current->state) {
                case CARDINAL_RESOURCE_STATE_LOADING:
                    loading++;
                    break;
                case CARDINAL_RESOURCE_STATE_LOADED:
                    loaded++;
                    break;
                case CARDINAL_RESOURCE_STATE_ERROR:
                    error++;
                    break;
                default:
                    break;
            }
            cardinal_mt_mutex_unlock(&current->state_mutex);
            
            current = current->next;
        }
    }
    
    cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (out_total_tracked) *out_total_tracked = total;
    if (out_loading_count) *out_loading_count = loading;
    if (out_loaded_count) *out_loaded_count = loaded;
    if (out_error_count) *out_error_count = error;
}