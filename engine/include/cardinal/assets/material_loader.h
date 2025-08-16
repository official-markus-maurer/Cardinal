/**
 * @file material_loader.h
 * @brief Thread-safe material loading with caching and reference counting
 *
 * This module provides enhanced material loading functionality with thread-safe
 * caching and reference counting for efficient material sharing in multi-threaded
 * environments. It builds upon the existing material_ref_counting system to add
 * performance optimizations through caching.
 *
 * Key features:
 * - Thread-safe material cache for fast lookups
 * - Reference counting for automatic memory management
 * - Asynchronous material loading support
 * - Cache statistics and management
 * - Integration with existing material system
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_ASSETS_MATERIAL_LOADER_H
#define CARDINAL_ASSETS_MATERIAL_LOADER_H

#include "cardinal/assets/scene.h"
#include "cardinal/core/ref_counting.h"
#include "cardinal/core/async_loader.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Material cache statistics
 *
 * Provides information about cache performance and usage.
 */
typedef struct MaterialCacheStats {
    uint32_t entry_count;   /**< Current number of cached materials */
    uint32_t max_entries;   /**< Maximum cache capacity */
    uint32_t cache_hits;    /**< Number of successful cache lookups */
    uint32_t cache_misses;  /**< Number of cache misses */
} MaterialCacheStats;

/**
 * @brief Load or acquire a reference counted material with caching
 *
 * This function provides thread-safe material loading with caching support.
 * It first checks the thread-safe cache, then falls back to the global
 * reference counting registry, and finally creates a new material if needed.
 *
 * @param material_data Pointer to the source material data
 * @param out_material Pointer to store the loaded material data
 * @return Pointer to reference counted resource, or NULL on failure
 */
CardinalRefCountedResource* material_load_with_ref_counting(const CardinalMaterial* material_data,
                                                            CardinalMaterial* out_material);

/**
 * @brief Release a reference counted material
 *
 * Decrements the reference count and frees the material if no more references exist.
 *
 * @param ref_resource Reference counted material resource to release
 */
void material_release_ref_counted(CardinalRefCountedResource* ref_resource);

/**
 * @brief Free material data
 *
 * Frees the memory associated with material data. This function should be used
 * for materials that are not reference counted.
 *
 * @param material Pointer to the material to free
 */
void material_data_free(CardinalMaterial* material);

/**
 * @brief Load material asynchronously
 *
 * Submits a material loading task to the async loader system. The material
 * will be loaded with reference counting and caching in a background thread.
 *
 * @param material_data Pointer to the source material data
 * @param priority Priority level for the async task
 * @param callback Callback function to call when loading completes
 * @param user_data User data to pass to the callback
 * @return Pointer to async task, or NULL on failure
 */
CardinalAsyncTask* material_load_async(const CardinalMaterial* material_data,
                                       CardinalAsyncPriority priority,
                                       CardinalAsyncCallback callback,
                                       void* user_data);

/**
 * @brief Initialize the material cache system
 *
 * Initializes the thread-safe material cache with the specified maximum
 * number of entries. This function should be called during engine initialization.
 *
 * @param max_entries Maximum number of materials to cache
 * @return true on success, false on failure
 */
bool material_cache_initialize(uint32_t max_entries);

/**
 * @brief Shutdown the material cache system
 *
 * Cleans up the material cache and releases all cached materials.
 * This function should be called during engine shutdown.
 */
void material_cache_shutdown_system(void);

/**
 * @brief Get material cache statistics
 *
 * Returns current statistics about the material cache performance and usage.
 *
 * @return Material cache statistics structure
 */
MaterialCacheStats material_cache_get_stats(void);

/**
 * @brief Clear the material cache
 *
 * Removes all entries from the material cache, releasing their references.
 * The cache remains initialized and ready for new entries.
 */
void material_cache_clear(void);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_MATERIAL_LOADER_H
