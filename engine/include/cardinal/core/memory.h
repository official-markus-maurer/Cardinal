/**
 * @file memory.h
 * @brief Cardinal Engine Memory Management System
 *
 * This module provides a comprehensive memory management system with tracking,
 * categorization, and multiple allocator types for optimal memory usage.
 */

#ifndef CARDINAL_CORE_MEMORY_H
#define CARDINAL_CORE_MEMORY_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Memory categories for tracking and profiling
 *
 * These categories help organize memory usage by subsystem,
 * enabling detailed memory profiling and debugging.
 */
typedef enum {
  CARDINAL_MEMORY_CATEGORY_UNKNOWN = 0,    /**< Uncategorized memory */
  CARDINAL_MEMORY_CATEGORY_ENGINE,         /**< Core engine systems */
  CARDINAL_MEMORY_CATEGORY_RENDERER,       /**< Rendering subsystem */
  CARDINAL_MEMORY_CATEGORY_VULKAN_BUFFERS, /**< Vulkan buffer objects */
  CARDINAL_MEMORY_CATEGORY_VULKAN_DEVICE,  /**< Vulkan device memory */
  CARDINAL_MEMORY_CATEGORY_TEXTURES,       /**< Texture data */
  CARDINAL_MEMORY_CATEGORY_MESHES,         /**< Mesh geometry data */
  CARDINAL_MEMORY_CATEGORY_ASSETS,         /**< Asset loading */
  CARDINAL_MEMORY_CATEGORY_SHADERS,        /**< Shader compilation */
  CARDINAL_MEMORY_CATEGORY_WINDOW,         /**< Window management */
  CARDINAL_MEMORY_CATEGORY_LOGGING,        /**< Logging system */
  CARDINAL_MEMORY_CATEGORY_TEMPORARY,      /**< Temporary allocations */
  CARDINAL_MEMORY_CATEGORY_MAX             /**< Maximum category count */
} CardinalMemoryCategory;

/**
 * @brief Memory statistics for a specific category
 *
 * Tracks allocation patterns and usage for memory profiling.
 */
typedef struct {
  size_t total_allocated;  /**< Total bytes allocated over lifetime */
  size_t current_usage;    /**< Current bytes in use */
  size_t peak_usage;       /**< Peak bytes ever allocated */
  size_t allocation_count; /**< Number of allocations performed */
  size_t free_count;       /**< Number of frees performed */
} CardinalMemoryStats;

/**
 * @brief Global memory tracking statistics
 *
 * Aggregates memory statistics across all categories and provides
 * a total overview of memory usage.
 */
typedef struct {
  CardinalMemoryStats
      categories[CARDINAL_MEMORY_CATEGORY_MAX]; /**< Per-category stats */
  CardinalMemoryStats total;                    /**< Aggregate statistics */
} CardinalGlobalMemoryStats;

/**
 * @brief Available allocator types
 *
 * Different allocator strategies for various use cases.
 */
typedef enum {
  CARDINAL_ALLOCATOR_DYNAMIC = 0, /**< Standard malloc/free allocator */
  CARDINAL_ALLOCATOR_LINEAR = 1,  /**< Linear/stack allocator */
  CARDINAL_ALLOCATOR_TRACKED = 2  /**< Tracked allocator with statistics */
} CardinalAllocatorType;

/**
 * @brief Forward declaration of allocator structure
 */
typedef struct CardinalAllocator CardinalAllocator;

/**
 * @brief Generic allocator interface
 *
 * Provides a unified interface for different allocation strategies.
 * All allocators implement this common interface for consistency.
 */
struct CardinalAllocator {
  CardinalAllocatorType type;      /**< Type of allocator */
  const char *name;                /**< Human-readable name */
  CardinalMemoryCategory category; /**< Memory category for tracking */
  void *state;                     /**< Internal allocator state */

  /**
   * @brief Allocate memory
   * @param self Pointer to allocator instance
   * @param size Number of bytes to allocate
   * @param alignment Memory alignment (0 for default)
   * @return Pointer to allocated memory or NULL on failure
   */
  void *(*alloc)(CardinalAllocator *self, size_t size, size_t alignment);

  /**
   * @brief Reallocate memory
   * @param self Pointer to allocator instance
   * @param ptr Existing memory pointer
   * @param old_size Previous size (0 if unknown)
   * @param new_size New size in bytes
   * @param alignment Memory alignment (0 for default)
   * @return Pointer to reallocated memory or NULL on failure
   */
  void *(*realloc_fn)(CardinalAllocator *self, void *ptr, size_t old_size,
                      size_t new_size, size_t alignment);

  /**
   * @brief Free memory
   * @param self Pointer to allocator instance
   * @param ptr Memory pointer to free (no-op for linear allocator)
   */
  void (*free_fn)(CardinalAllocator *self, void *ptr);

  /**
   * @brief Reset allocator state
   * @param self Pointer to allocator instance
   * @note Only meaningful for linear allocators
   */
  void (*reset)(CardinalAllocator *self);
};

/**
 * @brief Initialize the memory management system
 * @param default_linear_capacity Initial capacity for the default linear
 * allocator
 */
void cardinal_memory_init(size_t default_linear_capacity);

/**
 * @brief Shutdown the memory management system
 *
 * Cleans up all allocators and reports any memory leaks.
 */
void cardinal_memory_shutdown(void);

/**
 * @brief Get the global dynamic allocator
 * @return Pointer to the default dynamic allocator
 */
CardinalAllocator *cardinal_get_dynamic_allocator(void);

/**
 * @brief Get the global linear allocator
 * @return Pointer to the default linear allocator
 */
CardinalAllocator *cardinal_get_linear_allocator(void);

/**
 * @brief Get a category-specific allocator
 * @param category Memory category for tracking
 * @return Pointer to allocator configured for the specified category
 */
CardinalAllocator *
cardinal_get_allocator_for_category(CardinalMemoryCategory category);

/**
 * @brief Create a new linear allocator
 * @param capacity Maximum capacity in bytes
 * @return Pointer to new linear allocator or NULL on failure
 */
CardinalAllocator *cardinal_linear_allocator_create(size_t capacity);

/**
 * @brief Destroy a linear allocator
 * @param allocator Pointer to allocator to destroy
 */
void cardinal_linear_allocator_destroy(CardinalAllocator *allocator);

/**
 * @brief Get current memory statistics
 * @param out_stats Pointer to structure to fill with statistics
 */
void cardinal_memory_get_stats(CardinalGlobalMemoryStats *out_stats);

/**
 * @brief Reset all memory statistics
 */
void cardinal_memory_reset_stats(void);

/**
 * @brief Convenience helper functions for common allocator operations
 * @{
 */

/**
 * @brief Allocate memory with default alignment
 * @param a Pointer to allocator
 * @param size Number of bytes to allocate
 * @return Pointer to allocated memory or NULL on failure
 */
static inline void *cardinal_alloc(CardinalAllocator *a, size_t size) {
  return a->alloc(a, size, 0);
}

/**
 * @brief Allocate aligned memory
 * @param a Pointer to allocator
 * @param size Number of bytes to allocate
 * @param alignment Memory alignment requirement
 * @return Pointer to allocated memory or NULL on failure
 */
static inline void *cardinal_alloc_aligned(CardinalAllocator *a, size_t size,
                                           size_t alignment) {
  return a->alloc(a, size, alignment);
}

/**
 * @brief Reallocate memory with default alignment
 * @param a Pointer to allocator
 * @param ptr Existing memory pointer
 * @param old_size Previous size in bytes
 * @param new_size New size in bytes
 * @return Pointer to reallocated memory or NULL on failure
 */
static inline void *cardinal_realloc(CardinalAllocator *a, void *ptr,
                                     size_t old_size, size_t new_size) {
  return a->realloc_fn(a, ptr, old_size, new_size, 0);
}

/**
 * @brief Free allocated memory
 * @param a Pointer to allocator
 * @param ptr Memory pointer to free
 */
static inline void cardinal_free(CardinalAllocator *a, void *ptr) {
  a->free_fn(a, ptr);
}

/**
 * @brief Reset linear allocator to initial state
 * @param a Pointer to linear allocator
 */
static inline void cardinal_linear_reset(CardinalAllocator *a) {
  if (a && a->reset)
    a->reset(a);
}

/** @} */

// Helper macros to simplify tagged allocations
#define CARDINAL_ALLOCATE(category, size)                                      \
  cardinal_alloc(cardinal_get_allocator_for_category((category)), (size))
#define CARDINAL_ALLOCATE_ALIGNED(category, size, alignment)                   \
  cardinal_alloc_aligned(cardinal_get_allocator_for_category((category)),      \
                         (size), (alignment))
#define CARDINAL_REALLOCATE(category, ptr, old_size, new_size)                 \
  cardinal_realloc(cardinal_get_allocator_for_category((category)), (ptr),     \
                   (old_size), (new_size))
#define CARDINAL_FREE(category, ptr)                                           \
  cardinal_free(cardinal_get_allocator_for_category((category)), (ptr))

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_MEMORY_H
