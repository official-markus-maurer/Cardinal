#include "cardinal/core/memory.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#ifdef _MSC_VER
#include <malloc.h>
#endif

// -----------------------------
// Internal state structures
// -----------------------------

typedef struct DynamicState {
    int placeholder; // not used; system malloc/free
} DynamicState;

typedef struct LinearState {
    uint8_t* buffer;
    size_t capacity;
    size_t offset;
} LinearState;

typedef struct TrackedState {
    CardinalAllocator* backing; // underlying allocator
    CardinalMemoryCategory category; // category we attribute to
} TrackedState;

// -----------------------------
// Global stats
// -----------------------------
static CardinalGlobalMemoryStats g_stats;
static void stats_on_alloc(CardinalMemoryCategory cat, size_t size) {
    if (cat >= CARDINAL_MEMORY_CATEGORY_MAX) cat = CARDINAL_MEMORY_CATEGORY_UNKNOWN;
    g_stats.categories[cat].total_allocated += size;
    g_stats.categories[cat].current_usage += size;
    if (g_stats.categories[cat].current_usage > g_stats.categories[cat].peak_usage)
        g_stats.categories[cat].peak_usage = g_stats.categories[cat].current_usage;
    g_stats.categories[cat].allocation_count++;

    g_stats.total.total_allocated += size;
    g_stats.total.current_usage += size;
    if (g_stats.total.current_usage > g_stats.total.peak_usage)
        g_stats.total.peak_usage = g_stats.total.current_usage;
    g_stats.total.allocation_count++;
}
static void stats_on_free(CardinalMemoryCategory cat, size_t size) {
    if (cat >= CARDINAL_MEMORY_CATEGORY_MAX) cat = CARDINAL_MEMORY_CATEGORY_UNKNOWN;
    if (g_stats.categories[cat].current_usage >= size)
        g_stats.categories[cat].current_usage -= size;
    else
        g_stats.categories[cat].current_usage = 0;
    g_stats.categories[cat].free_count++;

    if (g_stats.total.current_usage >= size)
        g_stats.total.current_usage -= size;
    else
        g_stats.total.current_usage = 0;
    g_stats.total.free_count++;
}

void cardinal_memory_get_stats(CardinalGlobalMemoryStats* out_stats) {
    if (out_stats) *out_stats = g_stats;
}
void cardinal_memory_reset_stats(void) {
    memset(&g_stats, 0, sizeof(g_stats));
}

// -----------------------------
// Backing dynamic allocator
// -----------------------------
static void* dyn_alloc(CardinalAllocator* self, size_t size, size_t alignment) {
    (void)self;
    if (alignment && alignment > alignof(max_align_t)) {
    #ifdef _MSC_VER
        return _aligned_malloc(size, alignment);
    #else
        void* p = NULL;
        if (posix_memalign(&p, alignment, size) != 0) return NULL;
        return p;
    #endif
    }
    return malloc(size);
}

static void* dyn_realloc(CardinalAllocator* self, void* ptr, size_t old_size, size_t new_size, size_t alignment) {
    (void)self; (void)old_size; (void)alignment;
    return realloc(ptr, new_size);
}

static void dyn_free(CardinalAllocator* self, void* ptr) {
    (void)self;
#ifdef _MSC_VER
    _aligned_free(ptr);
#else
    free(ptr);
#endif
}

// -----------------------------
// Linear allocator
// -----------------------------
static void* lin_alloc(CardinalAllocator* self, size_t size, size_t alignment) {
    LinearState* st = (LinearState*)self->state;
    size_t current = st->offset;
    size_t align = alignment ? alignment : sizeof(void*);
    size_t mis = (uintptr_t)(st->buffer + current) % align;
    size_t pad = mis ? (align - mis) : 0;
    if (current + pad + size > st->capacity) return NULL;
    size_t at = current + pad;
    st->offset = at + size;
    return st->buffer + at;
}

static void* lin_realloc(CardinalAllocator* self, void* ptr, size_t old_size, size_t new_size, size_t alignment) {
    (void)self; (void)alignment;
    if (!ptr) return lin_alloc(self, new_size, alignment);
    void* n = lin_alloc(self, new_size, alignment);
    if (!n) return NULL;
    size_t copy = old_size < new_size ? old_size : new_size;
    memcpy(n, ptr, copy);
    return n;
}

static void lin_free(CardinalAllocator* self, void* ptr) {
    (void)self; (void)ptr; /* no-op for linear allocator */
}

static void lin_reset(CardinalAllocator* self) {
    LinearState* st = (LinearState*)self->state;
    st->offset = 0;
}

// -----------------------------
// Tracked wrapper allocator - attributes to category
// -----------------------------
static void* tracked_alloc(CardinalAllocator* self, size_t size, size_t alignment) {
    TrackedState* ts = (TrackedState*)self->state;
    void* p = ts->backing->alloc(ts->backing, size, alignment);
    if (p && size) stats_on_alloc(ts->category, size);
    return p;
}
static void* tracked_realloc(CardinalAllocator* self, void* ptr, size_t old_size, size_t new_size, size_t alignment) {
    TrackedState* ts = (TrackedState*)self->state;
    void* p = ts->backing->realloc_fn(ts->backing, ptr, old_size, new_size, alignment);
    if (p) {
        if (new_size > old_size) stats_on_alloc(ts->category, new_size - old_size);
        else if (old_size > new_size) stats_on_free(ts->category, old_size - new_size);
    }
    return p;
}
static void tracked_free(CardinalAllocator* self, void* ptr) {
    TrackedState* ts = (TrackedState*)self->state;
    // We can't know size on generic free; user should provide sizes via realloc when possible.
    // As a heuristic, we won't decrement stats here; to support accurate frees, prefer using realloc with known sizes or provide sized-free API later.
    ts->backing->free_fn(ts->backing, ptr);
}
static void tracked_reset(CardinalAllocator* self) {
    TrackedState* ts = (TrackedState*)self->state;
    if (ts->backing->reset) ts->backing->reset(ts->backing);
}

// -----------------------------
// Globals
// -----------------------------
static CardinalAllocator g_dynamic;
static DynamicState g_dynamic_state;
static CardinalAllocator g_linear;
static LinearState g_linear_state;

// A tracked view per category backed by dynamic allocator
static CardinalAllocator g_tracked[CARDINAL_MEMORY_CATEGORY_MAX];
static TrackedState g_tracked_state[CARDINAL_MEMORY_CATEGORY_MAX];

void cardinal_memory_init(size_t default_linear_capacity) {
    // Reset stats
    memset(&g_stats, 0, sizeof(g_stats));

    // Dynamic allocator setup
    g_dynamic.type = CARDINAL_ALLOCATOR_DYNAMIC;
    g_dynamic.name = "dynamic";
    g_dynamic.category = CARDINAL_MEMORY_CATEGORY_ENGINE;
    g_dynamic.state = &g_dynamic_state;
    g_dynamic.alloc = dyn_alloc;
    g_dynamic.realloc_fn = dyn_realloc;
    g_dynamic.free_fn = dyn_free;
    g_dynamic.reset = NULL;

    // Linear allocator setup
    if (default_linear_capacity == 0) default_linear_capacity = 4 * 1024 * 1024; // 4MB default
    g_linear_state.buffer = (uint8_t*)malloc(default_linear_capacity);
    g_linear_state.capacity = g_linear_state.buffer ? default_linear_capacity : 0;
    g_linear_state.offset = 0;

    g_linear.type = CARDINAL_ALLOCATOR_LINEAR;
    g_linear.name = "linear";
    g_linear.category = CARDINAL_MEMORY_CATEGORY_TEMPORARY;
    g_linear.state = &g_linear_state;
    g_linear.alloc = lin_alloc;
    g_linear.realloc_fn = lin_realloc;
    g_linear.free_fn = lin_free;
    g_linear.reset = lin_reset;

    // Initialize tracked views for each category
    for (int c = 0; c < (int)CARDINAL_MEMORY_CATEGORY_MAX; ++c) {
        g_tracked_state[c].backing = &g_dynamic;
        g_tracked_state[c].category = (CardinalMemoryCategory)c;
        g_tracked[c].type = CARDINAL_ALLOCATOR_TRACKED;
        g_tracked[c].name = "tracked_dynamic";
        g_tracked[c].category = (CardinalMemoryCategory)c;
        g_tracked[c].state = &g_tracked_state[c];
        g_tracked[c].alloc = tracked_alloc;
        g_tracked[c].realloc_fn = tracked_realloc;
        g_tracked[c].free_fn = tracked_free;
        g_tracked[c].reset = tracked_reset;
    }
}

void cardinal_memory_shutdown(void) {
    if (g_linear_state.buffer) {
        free(g_linear_state.buffer);
        g_linear_state.buffer = NULL;
        g_linear_state.capacity = 0;
        g_linear_state.offset = 0;
    }
}

CardinalAllocator* cardinal_get_dynamic_allocator(void) { return &g_dynamic; }
CardinalAllocator* cardinal_get_linear_allocator(void) { return &g_linear; }
CardinalAllocator* cardinal_get_allocator_for_category(CardinalMemoryCategory category) {
    if ((int)category < 0 || category >= CARDINAL_MEMORY_CATEGORY_MAX) return &g_tracked[CARDINAL_MEMORY_CATEGORY_UNKNOWN];
    return &g_tracked[category];
}

CardinalAllocator* cardinal_linear_allocator_create(size_t capacity) {
    if (capacity == 0) return NULL;
    LinearState* st = (LinearState*)malloc(sizeof(LinearState));
    if (!st) return NULL;
    st->buffer = (uint8_t*)malloc(capacity);
    if (!st->buffer) { free(st); return NULL; }
    st->capacity = capacity;
    st->offset = 0;

    CardinalAllocator* a = (CardinalAllocator*)malloc(sizeof(CardinalAllocator));
    if (!a) { free(st->buffer); free(st); return NULL; }
    a->type = CARDINAL_ALLOCATOR_LINEAR;
    a->name = "linear_dyn";
    a->category = CARDINAL_MEMORY_CATEGORY_TEMPORARY;
    a->state = st;
    a->alloc = lin_alloc;
    a->realloc_fn = lin_realloc;
    a->free_fn = lin_free;
    a->reset = lin_reset;
    return a;
}

void cardinal_linear_allocator_destroy(CardinalAllocator* allocator) {
    if (!allocator) return;
    if (allocator->type != CARDINAL_ALLOCATOR_LINEAR) return;
    LinearState* st = (LinearState*)allocator->state;
    if (st) {
        free(st->buffer);
        free(st);
    }
    free(allocator);
}