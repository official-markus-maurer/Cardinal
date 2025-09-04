/**
 * @file resource_state.h
 * @brief Resource state tracking system for Cardinal Engine
 *
 * This module extends the reference counting system with state tracking
 * to prevent concurrent access to resources during loading and processing.
 * It provides thread-safe state management for assets like textures,
 * materials, and other resources.
 *
 * Key features:
 * - Thread-safe resource state tracking
 * - Loading state management with blocking/non-blocking access
 * - Integration with existing reference counting system
 * - Deadlock prevention through timeout mechanisms
 * - Resource dependency tracking
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_CORE_RESOURCE_STATE_H
#define CARDINAL_CORE_RESOURCE_STATE_H

#include "cardinal/core/ref_counting.h"
#include "cardinal/renderer/vulkan_mt.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Resource loading states
 */
typedef enum {
    CARDINAL_RESOURCE_STATE_UNLOADED = 0,  /**< Resource not loaded */
    CARDINAL_RESOURCE_STATE_LOADING,       /**< Resource currently loading */
    CARDINAL_RESOURCE_STATE_LOADED,        /**< Resource fully loaded and ready */
    CARDINAL_RESOURCE_STATE_ERROR,         /**< Resource failed to load */
    CARDINAL_RESOURCE_STATE_UNLOADING      /**< Resource being unloaded */
} CardinalResourceState;

/**
 * @brief Resource state tracker
 *
 * Extends reference counted resources with state tracking and synchronization.
 */
typedef struct CardinalResourceStateTracker {
    CardinalRefCountedResource* ref_resource;  /**< Associated reference counted resource */
    volatile CardinalResourceState state;      /**< Current resource state */
    cardinal_mutex_t state_mutex;                 /**< Mutex for state changes */
    cardinal_cond_t state_changed;   /**< Condition variable for state notifications */
    uint32_t loading_thread_id;               /**< ID of thread currently loading the resource */
    uint64_t state_change_timestamp;          /**< Timestamp of last state change */
    char* identifier;                         /**< Resource identifier (copy) */
    struct CardinalResourceStateTracker* next; /**< Next in hash table chain */
} CardinalResourceStateTracker;

/**
 * @brief Resource state registry
 *
 * Global registry for tracking resource states across the engine.
 */
typedef struct {
    CardinalResourceStateTracker** buckets;   /**< Hash table buckets */
    size_t bucket_count;                      /**< Number of hash table buckets */
    cardinal_mutex_t registry_mutex;             /**< Mutex for registry operations */
    volatile uint32_t total_tracked_resources; /**< Total number of tracked resources */
    bool initialized;                         /**< Whether the registry is initialized */
} CardinalResourceStateRegistry;

/**
 * @brief Initialize the resource state tracking system
 *
 * Sets up the global registry and synchronization primitives.
 * Must be called before using any resource state tracking functions.
 *
 * @param bucket_count Number of hash table buckets (should be prime)
 * @return true on success, false on failure
 */
bool cardinal_resource_state_init(size_t bucket_count);

/**
 * @brief Shutdown the resource state tracking system
 *
 * Cleans up all tracked resources and frees the registry.
 * Should be called during engine shutdown.
 */
void cardinal_resource_state_shutdown(void);

/**
 * @brief Register a resource for state tracking
 *
 * Creates a state tracker for the given resource. If already tracked,
 * returns the existing tracker.
 *
 * @param ref_resource Reference counted resource to track
 * @return Pointer to the state tracker, or NULL on failure
 */
CardinalResourceStateTracker* cardinal_resource_state_register(CardinalRefCountedResource* ref_resource);

/**
 * @brief Unregister a resource from state tracking
 *
 * Removes the state tracker for the given resource identifier.
 *
 * @param identifier Resource identifier
 */
void cardinal_resource_state_unregister(const char* identifier);

/**
 * @brief Get the current state of a resource
 *
 * Returns the current loading state of the specified resource.
 *
 * @param identifier Resource identifier
 * @return Current resource state, or CARDINAL_RESOURCE_STATE_UNLOADED if not found
 */
CardinalResourceState cardinal_resource_state_get(const char* identifier);

/**
 * @brief Set the state of a resource
 *
 * Updates the resource state and notifies waiting threads.
 * Only the loading thread can change the state from LOADING to LOADED/ERROR.
 *
 * @param identifier Resource identifier
 * @param new_state New resource state
 * @param loading_thread_id ID of the thread performing the operation
 * @return true on success, false on failure
 */
bool cardinal_resource_state_set(const char* identifier, CardinalResourceState new_state, uint32_t loading_thread_id);

/**
 * @brief Wait for a resource to reach a specific state
 *
 * Blocks the calling thread until the resource reaches the specified state
 * or the timeout expires.
 *
 * @param identifier Resource identifier
 * @param target_state State to wait for
 * @param timeout_ms Timeout in milliseconds (0 = no timeout)
 * @return true if target state reached, false on timeout or error
 */
bool cardinal_resource_state_wait_for(const char* identifier, CardinalResourceState target_state, uint32_t timeout_ms);

/**
 * @brief Try to acquire exclusive loading access to a resource
 *
 * Attempts to change the resource state from UNLOADED to LOADING.
 * Only one thread can have loading access at a time.
 *
 * @param identifier Resource identifier
 * @param loading_thread_id ID of the thread requesting loading access
 * @return true if loading access acquired, false if already loading or loaded
 */
bool cardinal_resource_state_try_acquire_loading(const char* identifier, uint32_t loading_thread_id);

/**
 * @brief Check if a resource is safe to access
 *
 * Returns true if the resource is in LOADED state and safe for concurrent access.
 *
 * @param identifier Resource identifier
 * @return true if safe to access, false otherwise
 */
bool cardinal_resource_state_is_safe_to_access(const char* identifier);

/**
 * @brief Get resource state statistics
 *
 * Returns statistics about the resource state tracking system.
 *
 * @param out_total_tracked Output for total tracked resources
 * @param out_loading_count Output for resources currently loading
 * @param out_loaded_count Output for resources fully loaded
 * @param out_error_count Output for resources in error state
 */
void cardinal_resource_state_get_stats(uint32_t* out_total_tracked, uint32_t* out_loading_count, 
                                      uint32_t* out_loaded_count, uint32_t* out_error_count);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_RESOURCE_STATE_H