#ifndef CARDINAL_CORE_MEMORY_H
#define CARDINAL_CORE_MEMORY_H

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Memory categories for tracking
typedef enum {
    CARDINAL_MEMORY_CATEGORY_UNKNOWN = 0,
    CARDINAL_MEMORY_CATEGORY_ENGINE,
    CARDINAL_MEMORY_CATEGORY_RENDERER,
    CARDINAL_MEMORY_CATEGORY_VULKAN_BUFFERS,
    CARDINAL_MEMORY_CATEGORY_VULKAN_DEVICE,
    CARDINAL_MEMORY_CATEGORY_TEXTURES,
    CARDINAL_MEMORY_CATEGORY_MESHES,
    CARDINAL_MEMORY_CATEGORY_ASSETS,
    CARDINAL_MEMORY_CATEGORY_SHADERS,
    CARDINAL_MEMORY_CATEGORY_WINDOW,
    CARDINAL_MEMORY_CATEGORY_LOGGING,
    CARDINAL_MEMORY_CATEGORY_TEMPORARY,
    CARDINAL_MEMORY_CATEGORY_MAX
} CardinalMemoryCategory;

// Memory statistics for a category
typedef struct {
    size_t total_allocated;     // Total bytes allocated
    size_t current_usage;       // Current bytes in use
    size_t peak_usage;          // Peak bytes ever allocated
    size_t allocation_count;    // Number of allocations
    size_t free_count;          // Number of frees
} CardinalMemoryStats;

// Global memory tracking statistics
typedef struct {
    CardinalMemoryStats categories[CARDINAL_MEMORY_CATEGORY_MAX];
    CardinalMemoryStats total;
} CardinalGlobalMemoryStats;

// Allocator types
typedef enum {
    CARDINAL_ALLOCATOR_DYNAMIC = 0,
    CARDINAL_ALLOCATOR_LINEAR  = 1,
    CARDINAL_ALLOCATOR_TRACKED = 2
} CardinalAllocatorType;

// Forward declaration
typedef struct CardinalAllocator CardinalAllocator;

// Allocator interface
struct CardinalAllocator {
    CardinalAllocatorType type;
    const char* name;
    CardinalMemoryCategory category;
    void* state; // internal state
    // Allocate 'size' bytes with optional alignment (0 => default).
    void* (*alloc)(CardinalAllocator* self, size_t size, size_t alignment);
    // Reallocate; if old_size is unknown, pass 0.
    void* (*realloc_fn)(CardinalAllocator* self, void* ptr, size_t old_size, size_t new_size, size_t alignment);
    // Free pointer (no-op for linear allocator)
    void (*free_fn)(CardinalAllocator* self, void* ptr);
    // Reset allocator (only meaningful for linear)
    void (*reset)(CardinalAllocator* self);
};

// Global initialization/shutdown
void cardinal_memory_init(size_t default_linear_capacity);
void cardinal_memory_shutdown(void);

// Global default allocators
CardinalAllocator* cardinal_get_dynamic_allocator(void);
CardinalAllocator* cardinal_get_linear_allocator(void);

// Category-specific views of the default dynamic allocator
CardinalAllocator* cardinal_get_allocator_for_category(CardinalMemoryCategory category);

// Linear allocator management
CardinalAllocator* cardinal_linear_allocator_create(size_t capacity);
void cardinal_linear_allocator_destroy(CardinalAllocator* allocator);

// Global stats accessors
void cardinal_memory_get_stats(CardinalGlobalMemoryStats* out_stats);
void cardinal_memory_reset_stats(void);

// Convenience helpers/macros
static inline void* cardinal_alloc(CardinalAllocator* a, size_t size) {
    return a->alloc(a, size, 0);
}
static inline void* cardinal_alloc_aligned(CardinalAllocator* a, size_t size, size_t alignment) {
    return a->alloc(a, size, alignment);
}
static inline void* cardinal_realloc(CardinalAllocator* a, void* ptr, size_t old_size, size_t new_size) {
    return a->realloc_fn(a, ptr, old_size, new_size, 0);
}
static inline void cardinal_free(CardinalAllocator* a, void* ptr) {
    a->free_fn(a, ptr);
}
static inline void cardinal_linear_reset(CardinalAllocator* a) {
    if (a && a->reset) a->reset(a);
}

// Helper macros to simplify tagged allocations
#define CARDINAL_ALLOCATE(category, size) cardinal_alloc(cardinal_get_allocator_for_category((category)), (size))
#define CARDINAL_ALLOCATE_ALIGNED(category, size, alignment) cardinal_alloc_aligned(cardinal_get_allocator_for_category((category)), (size), (alignment))
#define CARDINAL_REALLOCATE(category, ptr, old_size, new_size) cardinal_realloc(cardinal_get_allocator_for_category((category)), (ptr), (old_size), (new_size))
#define CARDINAL_FREE(category, ptr) cardinal_free(cardinal_get_allocator_for_category((category)), (ptr))

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_MEMORY_H
