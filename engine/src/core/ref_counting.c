/**
 * @file ref_counting.c
 * @brief Reference counting system implementation for Cardinal Engine
 *
 * This file implements the reference counting system for managing shared
 * resources. It provides thread-safe reference counting with automatic
 * cleanup and a hash table-based registry for efficient resource lookup.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include "cardinal/core/ref_counting.h"
#include "cardinal/core/log.h"
#include "cardinal/core/memory.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
    #include <windows.h>
    #define ATOMIC_INCREMENT(ptr) InterlockedIncrement((LONG volatile*)(ptr))
    #define ATOMIC_DECREMENT(ptr) InterlockedDecrement((LONG volatile*)(ptr))
    #define ATOMIC_LOAD(ptr) InterlockedAdd((LONG volatile*)(ptr), 0)
#else
    #include <stdatomic.h>
    #define ATOMIC_INCREMENT(ptr) atomic_fetch_add((atomic_uint*)(ptr), 1) + 1
    #define ATOMIC_DECREMENT(ptr) atomic_fetch_sub((atomic_uint*)(ptr), 1) - 1
    #define ATOMIC_LOAD(ptr) atomic_load((atomic_uint*)(ptr))
#endif

// Global resource registry
static CardinalResourceRegistry g_registry = {0};
static bool g_registry_initialized = false;

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
 * @brief Find a resource in the registry by identifier
 * @param identifier Resource identifier
 * @return Pointer to the resource, or NULL if not found
 */
static CardinalRefCountedResource* find_resource(const char* identifier) {
    if (!g_registry_initialized || !identifier) {
        return NULL;
    }

    uint32_t hash = hash_string(identifier);
    size_t bucket_index = hash % g_registry.bucket_count;

    CardinalRefCountedResource* current = g_registry.buckets[bucket_index];
    while (current) {
        if (strcmp(current->identifier, identifier) == 0) {
            return current;
        }
        current = current->next; // Use proper next field
    }

    return NULL;
}

/**
 * @brief Remove a resource from the registry
 * @param identifier Resource identifier
 */
static void remove_resource(const char* identifier) {
    if (!g_registry_initialized || !identifier) {
        return;
    }

    uint32_t hash = hash_string(identifier);
    size_t bucket_index = hash % g_registry.bucket_count;

    CardinalRefCountedResource** current = &g_registry.buckets[bucket_index];
    while (*current) {
        if (strcmp((*current)->identifier, identifier) == 0) {
            CardinalRefCountedResource* to_remove = *current;
            *current = to_remove->next; // Use proper next field

            // Free the resource using its destructor
            if (to_remove->destructor && to_remove->resource) {
                to_remove->destructor(to_remove->resource);
            }

            // Free the identifier and the ref counted wrapper
            free(to_remove->identifier);
            free(to_remove);

            ATOMIC_DECREMENT(&g_registry.total_resources);
            return;
        }
        current = &(*current)->next; // Use proper next field
    }
}

bool cardinal_ref_counting_init(size_t bucket_count) {
    if (g_registry_initialized) {
        CARDINAL_LOG_WARN("Reference counting system already initialized");
        return true;
    }

    if (bucket_count == 0) {
        bucket_count = 1009; // Default prime number
    }

    g_registry.buckets =
        (CardinalRefCountedResource**)calloc(bucket_count, sizeof(CardinalRefCountedResource*));
    if (!g_registry.buckets) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for resource registry buckets");
        return false;
    }

    g_registry.bucket_count = bucket_count;
    g_registry.total_resources = 0;
    g_registry_initialized = true;

    CARDINAL_LOG_INFO("Reference counting system initialized with %zu buckets", bucket_count);
    return true;
}

void cardinal_ref_counting_shutdown(void) {
    if (!g_registry_initialized) {
        return;
    }

    CARDINAL_LOG_INFO("Shutting down reference counting system...");

    // Clean up all remaining resources
    for (size_t i = 0; i < g_registry.bucket_count; i++) {
        CardinalRefCountedResource* current = g_registry.buckets[i];
        while (current) {
            CardinalRefCountedResource* next = current->next; // Use proper next field

            CARDINAL_LOG_WARN("Resource '%s' still has %u references during shutdown",
                              current->identifier, ATOMIC_LOAD(&current->ref_count));

            // Force cleanup
            if (current->destructor && current->resource) {
                current->destructor(current->resource);
            }
            free(current->identifier);
            free(current);

            current = next;
        }
    }

    free(g_registry.buckets);
    memset(&g_registry, 0, sizeof(g_registry));
    g_registry_initialized = false;

    CARDINAL_LOG_INFO("Reference counting system shutdown complete");
}

CardinalRefCountedResource* cardinal_ref_create(const char* identifier, void* resource,
                                                size_t resource_size, void (*destructor)(void*)) {
    if (!g_registry_initialized) {
        CARDINAL_LOG_ERROR("Reference counting system not initialized");
        return NULL;
    }

    if (!identifier || !resource) {
        CARDINAL_LOG_ERROR("Invalid parameters for ref_create: identifier=%p, resource=%p",
                           (void*)identifier, resource);
        return NULL;
    }

    // Check if resource already exists
    CardinalRefCountedResource* existing = find_resource(identifier);
    if (existing) {
        ATOMIC_INCREMENT(&existing->ref_count);
        CARDINAL_LOG_DEBUG("Acquired existing resource '%s', ref_count=%u", identifier,
                           ATOMIC_LOAD(&existing->ref_count));
        return existing;
    }

    // Create new resource
    CardinalRefCountedResource* ref_resource =
        (CardinalRefCountedResource*)malloc(sizeof(CardinalRefCountedResource));
    if (!ref_resource) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for reference counted resource");
        return NULL;
    }

    ref_resource->resource = resource;
    ref_resource->ref_count = 1;
    ref_resource->destructor = destructor;
    ref_resource->resource_size = resource_size;
    ref_resource->next = NULL; // Initialize next pointer

    // Copy identifier
    size_t id_len = strlen(identifier) + 1;
    ref_resource->identifier = (char*)malloc(id_len);
    if (!ref_resource->identifier) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for resource identifier");
        free(ref_resource);
        return NULL;
    }
    strcpy(ref_resource->identifier, identifier);

    // Add to registry
    uint32_t hash = hash_string(identifier);
    size_t bucket_index = hash % g_registry.bucket_count;

    // Insert at the beginning of the chain using proper next field
    ref_resource->next = g_registry.buckets[bucket_index];
    g_registry.buckets[bucket_index] = ref_resource;

    ATOMIC_INCREMENT(&g_registry.total_resources);

    CARDINAL_LOG_DEBUG("Created new resource '%s', ref_count=1, total_resources=%u", identifier,
                       ATOMIC_LOAD(&g_registry.total_resources));

    return ref_resource;
}

CardinalRefCountedResource* cardinal_ref_acquire(const char* identifier) {
    if (!g_registry_initialized || !identifier) {
        return NULL;
    }

    CardinalRefCountedResource* resource = find_resource(identifier);
    if (resource) {
        ATOMIC_INCREMENT(&resource->ref_count);
        CARDINAL_LOG_DEBUG("Acquired resource '%s', ref_count=%u", identifier,
                           ATOMIC_LOAD(&resource->ref_count));
    }

    return resource;
}

void cardinal_ref_release(CardinalRefCountedResource* ref_resource) {
    if (!ref_resource) {
        return;
    }

    uint32_t new_count = ATOMIC_DECREMENT(&ref_resource->ref_count);
    CARDINAL_LOG_DEBUG("Released resource '%s', ref_count=%u", ref_resource->identifier, new_count);

    if (new_count == 0) {
        CARDINAL_LOG_DEBUG("Resource '%s' ref_count reached 0, cleaning up",
                           ref_resource->identifier);
        remove_resource(ref_resource->identifier);
    }
}

uint32_t cardinal_ref_get_count(const CardinalRefCountedResource* ref_resource) {
    if (!ref_resource) {
        return 0;
    }
    return ATOMIC_LOAD(&ref_resource->ref_count);
}

uint32_t cardinal_ref_get_total_resources(void) {
    if (!g_registry_initialized) {
        return 0;
    }
    return ATOMIC_LOAD(&g_registry.total_resources);
}

bool cardinal_ref_exists(const char* identifier) {
    return find_resource(identifier) != NULL;
}

void cardinal_ref_debug_print_resources(void) {
    if (!g_registry_initialized) {
        CARDINAL_LOG_INFO("Reference counting system not initialized");
        return;
    }

    CARDINAL_LOG_INFO("=== Reference Counted Resources Debug Info ===");
    CARDINAL_LOG_INFO("Total resources: %u", ATOMIC_LOAD(&g_registry.total_resources));
    CARDINAL_LOG_INFO("Bucket count: %zu", g_registry.bucket_count);

    for (size_t i = 0; i < g_registry.bucket_count; i++) {
        CardinalRefCountedResource* current = g_registry.buckets[i];
        if (current) {
            CARDINAL_LOG_INFO("Bucket %zu:", i);
            while (current) {
                CARDINAL_LOG_INFO("  - '%s': ref_count=%u, size=%zu bytes", current->identifier,
                                  ATOMIC_LOAD(&current->ref_count), current->resource_size);
                current = current->next; // Use proper next field
            }
        }
    }
    CARDINAL_LOG_INFO("=== End Debug Info ===");
}
