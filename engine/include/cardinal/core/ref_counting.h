/**
 * @file ref_counting.h
 * @brief Reference counting system for shared resources in Cardinal Engine
 *
 * This module provides a thread-safe reference counting system for managing
 * shared resources like textures, materials, and other assets. It prevents
 * resource leaks and enables safe sharing of resources across multiple
 * consumers.
 *
 * Key features:
 * - Atomic reference counting for thread safety
 * - Generic resource management with custom destructors
 * - Hash table-based resource registry for efficient lookups
 * - Automatic cleanup when reference count reaches zero
 * - Debug tracking for resource lifecycle monitoring
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_CORE_REF_COUNTING_H
#define CARDINAL_CORE_REF_COUNTING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Reference counted resource handle
 *
 * Wraps any resource with reference counting capabilities.
 * The resource is automatically freed when the reference count reaches zero.
 */
typedef struct CardinalRefCountedResource {
  void *resource;                     /**< Pointer to the actual resource */
  volatile uint32_t ref_count;        /**< Atomic reference counter */
  void (*destructor)(void *resource); /**< Custom destructor function */
  char *identifier;                   /**< Unique identifier for the resource */
  size_t resource_size;               /**< Size of the resource in bytes */
  struct CardinalRefCountedResource *next; /**< Next resource in hash table chain */
} CardinalRefCountedResource;

/**
 * @brief Resource registry for managing shared resources
 *
 * Maintains a hash table of resources indexed by their identifiers.
 * Enables efficient lookup and sharing of resources across the engine.
 */
typedef struct CardinalResourceRegistry {
  CardinalRefCountedResource **buckets; /**< Hash table buckets */
  size_t bucket_count;                  /**< Number of hash table buckets */
  volatile uint32_t
      total_resources; /**< Total number of registered resources */
} CardinalResourceRegistry;

/**
 * @brief Initialize the global resource registry
 *
 * Sets up the hash table and internal structures for resource management.
 * Must be called before using any reference counting functions.
 *
 * @param bucket_count Number of hash table buckets (should be prime)
 * @return true on success, false on failure
 */
bool cardinal_ref_counting_init(size_t bucket_count);

/**
 * @brief Shutdown the global resource registry
 *
 * Cleans up all remaining resources and frees the registry.
 * Should be called during engine shutdown.
 */
void cardinal_ref_counting_shutdown(void);

/**
 * @brief Create a new reference counted resource
 *
 * Registers a new resource in the registry with an initial reference count
 * of 1. If a resource with the same identifier already exists, returns the
 * existing resource and increments its reference count.
 *
 * @param identifier Unique identifier for the resource
 * @param resource Pointer to the resource data
 * @param resource_size Size of the resource in bytes
 * @param destructor Function to call when the resource is freed
 * @return Pointer to the reference counted resource, or NULL on failure
 */
CardinalRefCountedResource *cardinal_ref_create(const char *identifier,
                                                void *resource,
                                                size_t resource_size,
                                                void (*destructor)(void *));

/**
 * @brief Acquire a reference to an existing resource
 *
 * Looks up a resource by identifier and increments its reference count.
 * Returns NULL if the resource is not found.
 *
 * @param identifier Unique identifier for the resource
 * @return Pointer to the reference counted resource, or NULL if not found
 */
CardinalRefCountedResource *cardinal_ref_acquire(const char *identifier);

/**
 * @brief Release a reference to a resource
 *
 * Decrements the reference count of the resource. If the count reaches zero,
 * the resource is automatically freed using its destructor and removed from
 * the registry.
 *
 * @param ref_resource Pointer to the reference counted resource
 */
void cardinal_ref_release(CardinalRefCountedResource *ref_resource);

/**
 * @brief Get the current reference count of a resource
 *
 * Returns the current reference count for debugging and monitoring purposes.
 *
 * @param ref_resource Pointer to the reference counted resource
 * @return Current reference count, or 0 if ref_resource is NULL
 */
uint32_t cardinal_ref_get_count(const CardinalRefCountedResource *ref_resource);

/**
 * @brief Get the total number of registered resources
 *
 * Returns the total number of resources currently in the registry.
 * Useful for memory usage monitoring and debugging.
 *
 * @return Total number of registered resources
 */
uint32_t cardinal_ref_get_total_resources(void);

/**
 * @brief Check if a resource exists in the registry
 *
 * Checks if a resource with the given identifier is registered.
 *
 * @param identifier Unique identifier for the resource
 * @return true if the resource exists, false otherwise
 */
bool cardinal_ref_exists(const char *identifier);

/**
 * @brief Print debug information about all registered resources
 *
 * Outputs information about all resources in the registry to the log.
 * Useful for debugging memory leaks and resource usage.
 */
void cardinal_ref_debug_print_resources(void);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_REF_COUNTING_H
