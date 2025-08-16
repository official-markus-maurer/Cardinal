/**
 * @file mesh_loader.h
 * @brief Mesh loading utilities for Cardinal Engine
 *
 * This module provides mesh loading functionality with thread-safe caching
 * and reference counting for efficient resource management in multi-threaded
 * environments.
 *
 * Features:
 * - Thread-safe mesh loading with reference counting
 * - Mesh caching to avoid duplicate loading
 * - Asynchronous mesh loading support
 * - Memory-efficient resource management
 * - Cross-platform mutex support
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_ASSETS_MESH_LOADER_H
#define CARDINAL_ASSETS_MESH_LOADER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#include "cardinal/assets/scene.h"
#include "cardinal/core/async_loader.h"
#include "cardinal/core/ref_counting.h"

/**
 * @brief Load mesh with reference counting
 *
 * Loads a mesh and registers it in the reference counting system for
 * shared resource management. If the mesh is already loaded, returns
 * a reference to the existing mesh.
 *
 * @param mesh_data Pointer to source mesh data to load
 * @param out_mesh Pointer to mesh structure to populate
 * @return Reference-counted resource handle, or NULL on failure
 *
 * @note The caller should call cardinal_ref_release() when done with the mesh
 * @note The mesh data is deep-copied to ensure thread safety
 */
CardinalRefCountedResource* mesh_load_with_ref_counting(const CardinalMesh* mesh_data,
                                                        CardinalMesh* out_mesh);

/**
 * @brief Release a reference-counted mesh
 *
 * Decrements the reference count for a mesh. When the reference count
 * reaches zero, the mesh data is automatically freed.
 *
 * @param ref_resource Reference-counted resource to release
 */
void mesh_release_ref_counted(CardinalRefCountedResource* ref_resource);

/**
 * @brief Free mesh data
 *
 * Frees the memory allocated for mesh vertex and index data.
 * This function is used internally by the reference counting system.
 *
 * @param mesh Pointer to mesh data to free
 */
void mesh_data_free(CardinalMesh* mesh);

/**
 * @brief Load mesh asynchronously with reference counting
 *
 * Loads a mesh in a background thread to prevent UI blocking.
 * The callback function will be called when the loading is complete.
 *
 * @param mesh_data Pointer to source mesh data to load
 * @param priority Loading priority (higher priority tasks are processed first)
 * @param callback Function to call when loading completes (can be NULL)
 * @param user_data User data passed to the callback function
 * @return Async task handle, or NULL on failure
 *
 * @note The callback is called on the main thread when processing completed
 *       tasks with cardinal_async_process_completed_tasks()
 * @note Use cardinal_async_get_mesh_result() to retrieve the loaded mesh
 * @note Call cardinal_async_free_task() when done with the task handle
 */
CardinalAsyncTask* mesh_load_async(const CardinalMesh* mesh_data,
                                   CardinalAsyncPriority priority,
                                   CardinalAsyncCallback callback,
                                   void* user_data);

/**
 * @brief Initialize the thread-safe mesh cache with specified maximum entries
 *
 * This is automatically called by mesh_load_with_ref_counting if not already initialized
 *
 * @param max_entries Maximum number of entries in the cache
 * @return true if initialization succeeded, false otherwise
 */
bool mesh_cache_initialize(uint32_t max_entries);

/**
 * @brief Shutdown the mesh cache and free all cached resources
 */
void mesh_cache_shutdown_system(void);

/**
 * @brief Mesh cache statistics for monitoring
 */
typedef struct MeshCacheStats {
    uint32_t entry_count;   /**< Current number of cached entries */
    uint32_t max_entries;   /**< Maximum number of cache entries */
    uint32_t cache_hits;    /**< Number of cache hits */
    uint32_t cache_misses;  /**< Number of cache misses */
} MeshCacheStats;

/**
 * @brief Get current cache statistics
 *
 * @return Current mesh cache statistics
 */
MeshCacheStats mesh_cache_get_stats(void);

/**
 * @brief Clear all entries from the mesh cache
 */
void mesh_cache_clear(void);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_MESH_LOADER_H
