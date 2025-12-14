#include "cardinal/assets/mesh_loader.h"
#include "cardinal/core/async_loader.h"
#include "cardinal/core/log.h"
#include "cardinal/core/memory.h"
#include "cardinal/core/ref_counting.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
    #include <windows.h>
#else
    #include <pthread.h>
#endif

// Thread-safe mesh cache for multi-threaded loading
typedef struct MeshCacheEntry {
    char* mesh_id; // Unique identifier for the mesh (hash of mesh data)
    CardinalRefCountedResource* resource;
    struct MeshCacheEntry* next;
} MeshCacheEntry;

typedef struct MeshCache {
    MeshCacheEntry* entries;
    uint32_t entry_count;
    uint32_t max_entries;
    uint32_t cache_hits;
    uint32_t cache_misses;
    bool initialized;

#ifdef _WIN32
    CRITICAL_SECTION mutex;
#else
    pthread_mutex_t mutex;
#endif
} MeshCache;

// Global mesh cache instance
static MeshCache g_mesh_cache = {0};

// Forward declarations
static void mesh_data_destructor(void* data);
static char* generate_mesh_id(const CardinalMesh* mesh);
static uint32_t hash_string(const char* str);

// Initialize the mesh cache
static bool mesh_cache_init(uint32_t max_entries) {
    if (g_mesh_cache.initialized) {
        return true;
    }

    g_mesh_cache.entries = NULL;
    g_mesh_cache.entry_count = 0;
    g_mesh_cache.max_entries = max_entries;
    g_mesh_cache.cache_hits = 0;
    g_mesh_cache.cache_misses = 0;

#ifdef _WIN32
    InitializeCriticalSection(&g_mesh_cache.mutex);
#else
    if (pthread_mutex_init(&g_mesh_cache.mutex, NULL) != 0) {
        CARDINAL_LOG_ERROR("Failed to initialize mesh cache mutex");
        return false;
    }
#endif

    g_mesh_cache.initialized = true;
    CARDINAL_LOG_INFO("[MESH] Cache initialized with max_entries=%u", max_entries);
    return true;
}

// Shutdown the mesh cache
static void mesh_cache_shutdown(void) {
    if (!g_mesh_cache.initialized) {
        return;
    }

#ifdef _WIN32
    EnterCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_lock(&g_mesh_cache.mutex);
#endif

    // Free all cache entries
    MeshCacheEntry* entry = g_mesh_cache.entries;
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);

    while (entry) {
        MeshCacheEntry* next = entry->next;
        if (entry->mesh_id) {
            cardinal_free(allocator, entry->mesh_id);
        }
        if (entry->resource) {
            cardinal_ref_release(entry->resource);
        }
        cardinal_free(allocator, entry);
        entry = next;
    }

    g_mesh_cache.entries = NULL;
    g_mesh_cache.entry_count = 0;

#ifdef _WIN32
    LeaveCriticalSection(&g_mesh_cache.mutex);
    DeleteCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_unlock(&g_mesh_cache.mutex);
    pthread_mutex_destroy(&g_mesh_cache.mutex);
#endif

    g_mesh_cache.initialized = false;
    CARDINAL_LOG_INFO("[MESH] Cache shutdown complete");
}

// Get mesh from cache
static CardinalRefCountedResource* mesh_cache_get(const char* mesh_id) {
    if (!g_mesh_cache.initialized || !mesh_id) {
        return NULL;
    }

#ifdef _WIN32
    EnterCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_lock(&g_mesh_cache.mutex);
#endif

    MeshCacheEntry* entry = g_mesh_cache.entries;
    while (entry) {
        if (entry->mesh_id && strcmp(entry->mesh_id, mesh_id) == 0) {
            // Found in cache, acquire reference
            CardinalRefCountedResource* resource = entry->resource;
            if (resource) {
                cardinal_ref_acquire(resource->identifier);
                g_mesh_cache.cache_hits++;

#ifdef _WIN32
                LeaveCriticalSection(&g_mesh_cache.mutex);
#else
                pthread_mutex_unlock(&g_mesh_cache.mutex);
#endif
                return resource;
            }
        }
        entry = entry->next;
    }

    g_mesh_cache.cache_misses++;

#ifdef _WIN32
    LeaveCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_unlock(&g_mesh_cache.mutex);
#endif

    return NULL;
}

// Add mesh to cache
static void mesh_cache_put(const char* mesh_id, CardinalRefCountedResource* resource) {
    if (!g_mesh_cache.initialized || !mesh_id || !resource) {
        return;
    }

#ifdef _WIN32
    EnterCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_lock(&g_mesh_cache.mutex);
#endif

    // Check if we're at capacity
    if (g_mesh_cache.entry_count >= g_mesh_cache.max_entries) {
        // Remove oldest entry (simple FIFO eviction)
        if (g_mesh_cache.entries) {
            MeshCacheEntry* to_remove = g_mesh_cache.entries;
            g_mesh_cache.entries = to_remove->next;

            CardinalAllocator* allocator =
                cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
            if (to_remove->mesh_id) {
                cardinal_free(allocator, to_remove->mesh_id);
            }
            if (to_remove->resource) {
                cardinal_ref_release(to_remove->resource);
            }
            cardinal_free(allocator, to_remove);
            g_mesh_cache.entry_count--;
        }
    }

    // Create new entry
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    MeshCacheEntry* new_entry = cardinal_alloc(allocator, sizeof(MeshCacheEntry));
    if (!new_entry) {
#ifdef _WIN32
        LeaveCriticalSection(&g_mesh_cache.mutex);
#else
        pthread_mutex_unlock(&g_mesh_cache.mutex);
#endif
        return;
    }

    // Copy mesh ID
    size_t id_len = strlen(mesh_id) + 1;
    new_entry->mesh_id = cardinal_alloc(allocator, id_len);
    if (!new_entry->mesh_id) {
        cardinal_free(allocator, new_entry);
#ifdef _WIN32
        LeaveCriticalSection(&g_mesh_cache.mutex);
#else
        pthread_mutex_unlock(&g_mesh_cache.mutex);
#endif
        return;
    }
    strcpy(new_entry->mesh_id, mesh_id);

    // Acquire reference to resource
    new_entry->resource = resource;
    cardinal_ref_acquire(resource->identifier);

    // Add to front of list
    new_entry->next = g_mesh_cache.entries;
    g_mesh_cache.entries = new_entry;
    g_mesh_cache.entry_count++;

#ifdef _WIN32
    LeaveCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_unlock(&g_mesh_cache.mutex);
#endif
}

// Generate a unique ID for a mesh based on its data
static char* generate_mesh_id(const CardinalMesh* mesh) {
    if (!mesh) {
        return NULL;
    }

    // Create a hash based on mesh properties
    uint32_t hash = 0;
    hash ^= mesh->vertex_count;
    hash ^= mesh->index_count << 16;
    hash ^= mesh->material_index;

    // Hash some vertex data if available
    if (mesh->vertices && mesh->vertex_count > 0) {
        for (uint32_t i = 0; i < mesh->vertex_count && i < 10; i++) {
            hash ^= hash_string((const char*)&mesh->vertices[i].px);
        }
    }

    // Hash some index data if available
    if (mesh->indices && mesh->index_count > 0) {
        for (uint32_t i = 0; i < mesh->index_count && i < 10; i++) {
            hash ^= mesh->indices[i];
        }
    }

    // Convert hash to string
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    char* id = cardinal_alloc(allocator, 32);
    if (id) {
        snprintf(id, 32, "mesh_%08x", hash);
    }

    return id;
}

// Simple string hash function
static uint32_t hash_string(const char* str) {
    uint32_t hash = 5381;
    int c;

    while ((c = *str++)) {
        hash = ((hash << 5) + hash) + c;
    }

    return hash;
}

// Mesh data destructor for reference counting
static void mesh_data_destructor(void* data) {
    CardinalMesh* mesh = (CardinalMesh*)data;
    if (mesh) {
        CardinalAllocator* allocator =
            cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
        if (mesh->vertices) {
            cardinal_free(allocator, mesh->vertices);
        }
        if (mesh->indices) {
            cardinal_free(allocator, mesh->indices);
        }
        cardinal_free(allocator, mesh);
    }
}

// Public API implementations

CardinalRefCountedResource* mesh_load_with_ref_counting(const CardinalMesh* mesh_data,
                                                        CardinalMesh* out_mesh) {
    if (!mesh_data || !out_mesh) {
        CARDINAL_LOG_ERROR("mesh_load_with_ref_counting: invalid args mesh_data=%p out=%p",
                           (void*)mesh_data, (void*)out_mesh);
        return NULL;
    }

    // Initialize cache if not already done
    if (!g_mesh_cache.initialized) {
        mesh_cache_init(128); // Default cache size
    }

    // Generate unique ID for this mesh
    char* mesh_id = generate_mesh_id(mesh_data);
    if (!mesh_id) {
        CARDINAL_LOG_ERROR("Failed to generate mesh ID");
        return NULL;
    }

    // Try to get mesh from thread-safe cache first
    CardinalRefCountedResource* ref_resource = mesh_cache_get(mesh_id);
    if (ref_resource) {
        // Copy mesh data from cached resource
        CardinalMesh* existing_mesh = (CardinalMesh*)ref_resource->resource;
        *out_mesh = *existing_mesh;

        CardinalAllocator* allocator =
            cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
        cardinal_free(allocator, mesh_id);

        CARDINAL_LOG_DEBUG("[MESH] Reusing cached mesh: %s (ref_count=%u)", mesh_id,
                           cardinal_ref_get_count(ref_resource));
        return ref_resource;
    }

    // Try to acquire existing mesh from global registry (fallback)
    ref_resource = cardinal_ref_acquire(mesh_id);
    if (ref_resource) {
        // Copy mesh data from existing resource
        CardinalMesh* existing_mesh = (CardinalMesh*)ref_resource->resource;
        *out_mesh = *existing_mesh;

        // Add to cache for faster future access
        mesh_cache_put(mesh_id, ref_resource);

        CardinalAllocator* allocator =
            cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
        cardinal_free(allocator, mesh_id);

        CARDINAL_LOG_DEBUG("[MESH] Reusing registry mesh: %s (ref_count=%u)", mesh_id,
                           cardinal_ref_get_count(ref_resource));
        return ref_resource;
    }

    // Create a deep copy of mesh data for the registry
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    CardinalMesh* mesh_copy = cardinal_alloc(allocator, sizeof(CardinalMesh));
    if (!mesh_copy) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for mesh copy");
        cardinal_free(allocator, mesh_id);
        return NULL;
    }

    // Copy mesh structure
    *mesh_copy = *mesh_data;

    // Deep copy vertex data
    if (mesh_data->vertices && mesh_data->vertex_count > 0) {
        size_t vertex_size = mesh_data->vertex_count * sizeof(CardinalVertex);
        mesh_copy->vertices = cardinal_alloc(allocator, vertex_size);
        if (!mesh_copy->vertices) {
            cardinal_free(allocator, mesh_copy);
            cardinal_free(allocator, mesh_id);
            CARDINAL_LOG_ERROR("Failed to allocate memory for vertex data copy");
            return NULL;
        }
        memcpy(mesh_copy->vertices, mesh_data->vertices, vertex_size);
    }

    // Deep copy index data
    if (mesh_data->indices && mesh_data->index_count > 0) {
        size_t index_size = mesh_data->index_count * sizeof(uint32_t);
        mesh_copy->indices = cardinal_alloc(allocator, index_size);
        if (!mesh_copy->indices) {
            if (mesh_copy->vertices) {
                cardinal_free(allocator, mesh_copy->vertices);
            }
            cardinal_free(allocator, mesh_copy);
            cardinal_free(allocator, mesh_id);
            CARDINAL_LOG_ERROR("Failed to allocate memory for index data copy");
            return NULL;
        }
        memcpy(mesh_copy->indices, mesh_data->indices, index_size);
    }

    // Register the mesh in the reference counting system
    ref_resource =
        cardinal_ref_create(mesh_id, mesh_copy, sizeof(CardinalMesh), mesh_data_destructor);
    if (!ref_resource) {
        CARDINAL_LOG_ERROR("Failed to register mesh in reference counting system: %s", mesh_id);
        if (mesh_copy->vertices) {
            cardinal_free(allocator, mesh_copy->vertices);
        }
        if (mesh_copy->indices) {
            cardinal_free(allocator, mesh_copy->indices);
        }
        cardinal_free(allocator, mesh_copy);
        cardinal_free(allocator, mesh_id);
        return NULL;
    }

    // Add to cache for future access
    mesh_cache_put(mesh_id, ref_resource);

    // Copy mesh data to output
    *out_mesh = *mesh_copy;

    cardinal_free(allocator, mesh_id);

    CARDINAL_LOG_INFO("[MESH] Registered new mesh for sharing: vertices=%u, indices=%u",
                      mesh_data->vertex_count, mesh_data->index_count);
    return ref_resource;
}

void mesh_release_ref_counted(CardinalRefCountedResource* ref_resource) {
    if (ref_resource) {
        cardinal_ref_release(ref_resource);
    }
}

void mesh_data_free(CardinalMesh* mesh) {
    if (mesh) {
        CardinalAllocator* allocator =
            cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
        if (mesh->vertices) {
            cardinal_free(allocator, mesh->vertices);
            mesh->vertices = NULL;
        }
        if (mesh->indices) {
            cardinal_free(allocator, mesh->indices);
            mesh->indices = NULL;
        }
        mesh->vertex_count = 0;
        mesh->index_count = 0;
    }
}

CardinalAsyncTask* mesh_load_async(const CardinalMesh* mesh_data, CardinalAsyncPriority priority,
                                   CardinalAsyncCallback callback, void* user_data) {
    if (!mesh_data) {
        CARDINAL_LOG_ERROR("mesh_load_async: mesh_data is NULL");
        return NULL;
    }

    CARDINAL_LOG_DEBUG("[MESH] Starting async load for mesh: vertices=%u, indices=%u",
                       mesh_data->vertex_count, mesh_data->index_count);

    // Use the async loader to load the mesh
    CardinalAsyncTask* task = cardinal_async_load_mesh(mesh_data, priority, callback, user_data);
    if (!task) {
        CARDINAL_LOG_ERROR("Failed to create async mesh loading task");
        return NULL;
    }

    CARDINAL_LOG_DEBUG("[MESH] Async task created for mesh loading");
    return task;
}

// Public mesh cache management functions
bool mesh_cache_initialize(uint32_t max_entries) {
    return mesh_cache_init(max_entries);
}

void mesh_cache_shutdown_system(void) {
    mesh_cache_shutdown();
}

MeshCacheStats mesh_cache_get_stats(void) {
    MeshCacheStats stats = {0};

    if (!g_mesh_cache.initialized) {
        return stats;
    }

#ifdef _WIN32
    EnterCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_lock(&g_mesh_cache.mutex);
#endif

    stats.entry_count = g_mesh_cache.entry_count;
    stats.max_entries = g_mesh_cache.max_entries;
    stats.cache_hits = g_mesh_cache.cache_hits;
    stats.cache_misses = g_mesh_cache.cache_misses;

#ifdef _WIN32
    LeaveCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_unlock(&g_mesh_cache.mutex);
#endif

    return stats;
}

void mesh_cache_clear(void) {
    if (!g_mesh_cache.initialized) {
        return;
    }

#ifdef _WIN32
    EnterCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_lock(&g_mesh_cache.mutex);
#endif

    // Free all cache entries
    MeshCacheEntry* entry = g_mesh_cache.entries;
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);

    while (entry) {
        MeshCacheEntry* next = entry->next;
        if (entry->mesh_id) {
            cardinal_free(allocator, entry->mesh_id);
        }
        if (entry->resource) {
            cardinal_ref_release(entry->resource);
        }
        cardinal_free(allocator, entry);
        entry = next;
    }

    g_mesh_cache.entries = NULL;
    g_mesh_cache.entry_count = 0;

#ifdef _WIN32
    LeaveCriticalSection(&g_mesh_cache.mutex);
#else
    pthread_mutex_unlock(&g_mesh_cache.mutex);
#endif

    CARDINAL_LOG_INFO("[MESH] Cache cleared");
}
