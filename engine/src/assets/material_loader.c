#include "cardinal/assets/material_loader.h"
#include "cardinal/assets/material_ref_counting.h"
#include "cardinal/core/async_loader.h"
#include "cardinal/core/log.h"
#include "cardinal/core/ref_counting.h"
#include "cardinal/core/memory.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

// Thread-safe material cache for multi-threaded loading
typedef struct MaterialCacheEntry {
    char* material_id;  // Unique identifier for the material (hash string)
    CardinalRefCountedResource* resource;
    struct MaterialCacheEntry* next;
} MaterialCacheEntry;

typedef struct MaterialCache {
    MaterialCacheEntry* entries;
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
} MaterialCache;

// Global material cache instance
static MaterialCache g_material_cache = {0};

// Forward declarations
static void material_data_destructor(void* data);
static char* generate_material_id(const CardinalMaterial* material);

// Initialize the material cache
static bool material_cache_init(uint32_t max_entries) {
    if (g_material_cache.initialized) {
        return true;
    }
    
    g_material_cache.entries = NULL;
    g_material_cache.entry_count = 0;
    g_material_cache.max_entries = max_entries;
    g_material_cache.cache_hits = 0;
    g_material_cache.cache_misses = 0;
    
#ifdef _WIN32
    InitializeCriticalSection(&g_material_cache.mutex);
#else
    if (pthread_mutex_init(&g_material_cache.mutex, NULL) != 0) {
        CARDINAL_LOG_ERROR("Failed to initialize material cache mutex");
        return false;
    }
#endif
    
    g_material_cache.initialized = true;
    CARDINAL_LOG_INFO("[MATERIAL] Cache initialized with max_entries=%u", max_entries);
    return true;
}

// Shutdown the material cache
static void material_cache_shutdown(void) {
    if (!g_material_cache.initialized) {
        return;
    }
    
#ifdef _WIN32
    EnterCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_lock(&g_material_cache.mutex);
#endif
    
    // Free all cache entries
    MaterialCacheEntry* entry = g_material_cache.entries;
    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    
    while (entry) {
        MaterialCacheEntry* next = entry->next;
        if (entry->material_id) {
            cardinal_free(allocator, entry->material_id);
        }
        if (entry->resource) {
            cardinal_ref_release(entry->resource);
        }
        cardinal_free(allocator, entry);
        entry = next;
    }
    
    g_material_cache.entries = NULL;
    g_material_cache.entry_count = 0;
    
#ifdef _WIN32
    LeaveCriticalSection(&g_material_cache.mutex);
    DeleteCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_unlock(&g_material_cache.mutex);
    pthread_mutex_destroy(&g_material_cache.mutex);
#endif
    
    g_material_cache.initialized = false;
    CARDINAL_LOG_INFO("[MATERIAL] Cache shutdown complete");
}

// Get material from cache
static CardinalRefCountedResource* material_cache_get(const char* material_id) {
    if (!g_material_cache.initialized || !material_id) {
        return NULL;
    }
    
#ifdef _WIN32
    EnterCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_lock(&g_material_cache.mutex);
#endif
    
    MaterialCacheEntry* entry = g_material_cache.entries;
    while (entry) {
        if (entry->material_id && strcmp(entry->material_id, material_id) == 0) {
            // Found in cache, acquire reference
            CardinalRefCountedResource* resource = entry->resource;
            if (resource) {
                cardinal_ref_acquire(resource->identifier);
                g_material_cache.cache_hits++;
                
#ifdef _WIN32
                LeaveCriticalSection(&g_material_cache.mutex);
#else
                pthread_mutex_unlock(&g_material_cache.mutex);
#endif
                return resource;
            }
        }
        entry = entry->next;
    }
    
    g_material_cache.cache_misses++;
    
#ifdef _WIN32
    LeaveCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_unlock(&g_material_cache.mutex);
#endif
    
    return NULL;
}

// Add material to cache
static void material_cache_put(const char* material_id, CardinalRefCountedResource* resource) {
    if (!g_material_cache.initialized || !material_id || !resource) {
        return;
    }
    
#ifdef _WIN32
    EnterCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_lock(&g_material_cache.mutex);
#endif
    
    // Check if we're at capacity
    if (g_material_cache.entry_count >= g_material_cache.max_entries) {
        // Remove oldest entry (simple FIFO eviction)
        if (g_material_cache.entries) {
            MaterialCacheEntry* to_remove = g_material_cache.entries;
            g_material_cache.entries = to_remove->next;
            
            CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
            if (to_remove->material_id) {
                cardinal_free(allocator, to_remove->material_id);
            }
            if (to_remove->resource) {
                cardinal_ref_release(to_remove->resource);
            }
            cardinal_free(allocator, to_remove);
            g_material_cache.entry_count--;
        }
    }
    
    // Create new entry
    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    MaterialCacheEntry* new_entry = cardinal_alloc(allocator, sizeof(MaterialCacheEntry));
    if (!new_entry) {
#ifdef _WIN32
        LeaveCriticalSection(&g_material_cache.mutex);
#else
        pthread_mutex_unlock(&g_material_cache.mutex);
#endif
        return;
    }
    
    // Copy material ID
    size_t id_len = strlen(material_id) + 1;
    new_entry->material_id = cardinal_alloc(allocator, id_len);
    if (!new_entry->material_id) {
        cardinal_free(allocator, new_entry);
#ifdef _WIN32
        LeaveCriticalSection(&g_material_cache.mutex);
#else
        pthread_mutex_unlock(&g_material_cache.mutex);
#endif
        return;
    }
    strcpy(new_entry->material_id, material_id);
    
    // Acquire reference to resource
    new_entry->resource = resource;
    cardinal_ref_acquire(resource->identifier);
    
    // Add to front of list
    new_entry->next = g_material_cache.entries;
    g_material_cache.entries = new_entry;
    g_material_cache.entry_count++;
    
#ifdef _WIN32
    LeaveCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_unlock(&g_material_cache.mutex);
#endif
}

// Generate a unique ID for a material using the existing hash system
static char* generate_material_id(const CardinalMaterial* material) {
    if (!material) {
        return NULL;
    }
    
    // Use the existing material hash system
    CardinalMaterialHash hash = cardinal_material_generate_hash(material);
    
    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    char* id = cardinal_alloc(allocator, 64);
    if (id) {
        cardinal_material_hash_to_string(&hash, id);
    }
    
    return id;
}

// Material data destructor for reference counting
static void material_data_destructor(void* data) {
    CardinalMaterial* material = (CardinalMaterial*)data;
    if (material) {
        CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
        cardinal_free(allocator, material);
    }
}

// Public API implementations

CardinalRefCountedResource* material_load_with_ref_counting(const CardinalMaterial* material_data,
                                                            CardinalMaterial* out_material) {
    if (!material_data || !out_material) {
        CARDINAL_LOG_ERROR("material_load_with_ref_counting: invalid args material_data=%p out=%p",
                           (void*)material_data, (void*)out_material);
        return NULL;
    }
    
    // Initialize cache if not already done
    if (!g_material_cache.initialized) {
        material_cache_init(256); // Default cache size
    }
    
    // Generate unique ID for this material
    char* material_id = generate_material_id(material_data);
    if (!material_id) {
        CARDINAL_LOG_ERROR("Failed to generate material ID");
        return NULL;
    }
    
    // Try to get material from thread-safe cache first
    CardinalRefCountedResource* ref_resource = material_cache_get(material_id);
    if (ref_resource) {
        // Copy material data from cached resource
        CardinalMaterial* existing_material = (CardinalMaterial*)ref_resource->resource;
        *out_material = *existing_material;
        
        CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
        cardinal_free(allocator, material_id);
        
        CARDINAL_LOG_DEBUG("[MATERIAL] Reusing cached material: %s (ref_count=%u)", material_id,
                           cardinal_ref_get_count(ref_resource));
        return ref_resource;
    }
    
    // Try to use the existing material reference counting system (fallback)
    ref_resource = cardinal_material_load_with_ref_counting(material_data, out_material);
    if (ref_resource) {
        // Add to cache for faster future access
        material_cache_put(material_id, ref_resource);
        
        CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
        cardinal_free(allocator, material_id);
        
        CARDINAL_LOG_DEBUG("[MATERIAL] Loaded material via registry: %s (ref_count=%u)", material_id,
                           cardinal_ref_get_count(ref_resource));
        return ref_resource;
    }
    
    // If we reach here, the existing system failed, so we create a new material
    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    CardinalMaterial* material_copy = cardinal_alloc(allocator, sizeof(CardinalMaterial));
    if (!material_copy) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for material copy");
        cardinal_free(allocator, material_id);
        return NULL;
    }
    
    // Copy material data
    *material_copy = *material_data;
    *out_material = *material_data;
    
    // Register the material in the reference counting system
    ref_resource = cardinal_ref_create(material_id, material_copy, sizeof(CardinalMaterial), material_data_destructor);
    if (!ref_resource) {
        CARDINAL_LOG_ERROR("Failed to register material in reference counting system: %s", material_id);
        cardinal_free(allocator, material_copy);
        cardinal_free(allocator, material_id);
        return NULL;
    }
    
    // Add to cache for future access
    material_cache_put(material_id, ref_resource);
    
    cardinal_free(allocator, material_id);
    
    CARDINAL_LOG_INFO("[MATERIAL] Registered new material for sharing");
    return ref_resource;
}

void material_release_ref_counted(CardinalRefCountedResource* ref_resource) {
    if (ref_resource) {
        cardinal_ref_release(ref_resource);
    }
}

void material_data_free(CardinalMaterial* material) {
    if (material) {
        // CardinalMaterial doesn't contain dynamically allocated members
        // in the current implementation, so we just need to clear the structure
        memset(material, 0, sizeof(CardinalMaterial));
    }
}

CardinalAsyncTask* material_load_async(const CardinalMaterial* material_data,
                                       CardinalAsyncPriority priority,
                                       CardinalAsyncCallback callback,
                                       void* user_data) {
    if (!material_data) {
        CARDINAL_LOG_ERROR("material_load_async: material_data is NULL");
        return NULL;
    }
    
    CARDINAL_LOG_DEBUG("[MATERIAL] Starting async load for material");
    
    // Use the async loader to load the material
    CardinalAsyncTask* task = cardinal_async_load_material(material_data, priority, callback, user_data);
    if (!task) {
        CARDINAL_LOG_ERROR("Failed to create async material loading task");
        return NULL;
    }
    
    CARDINAL_LOG_DEBUG("[MATERIAL] Async task created for material loading");
    return task;
}

// Public material cache management functions
bool material_cache_initialize(uint32_t max_entries) {
    return material_cache_init(max_entries);
}

void material_cache_shutdown_system(void) {
    material_cache_shutdown();
}

MaterialCacheStats material_cache_get_stats(void) {
    MaterialCacheStats stats = {0};
    
    if (!g_material_cache.initialized) {
        return stats;
    }
    
#ifdef _WIN32
    EnterCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_lock(&g_material_cache.mutex);
#endif
    
    stats.entry_count = g_material_cache.entry_count;
    stats.max_entries = g_material_cache.max_entries;
    stats.cache_hits = g_material_cache.cache_hits;
    stats.cache_misses = g_material_cache.cache_misses;
    
#ifdef _WIN32
    LeaveCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_unlock(&g_material_cache.mutex);
#endif
    
    return stats;
}

void material_cache_clear(void) {
    if (!g_material_cache.initialized) {
        return;
    }
    
#ifdef _WIN32
    EnterCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_lock(&g_material_cache.mutex);
#endif
    
    // Free all cache entries
    MaterialCacheEntry* entry = g_material_cache.entries;
    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    
    while (entry) {
        MaterialCacheEntry* next = entry->next;
        if (entry->material_id) {
            cardinal_free(allocator, entry->material_id);
        }
        if (entry->resource) {
            cardinal_ref_release(entry->resource);
        }
        cardinal_free(allocator, entry);
        entry = next;
    }
    
    g_material_cache.entries = NULL;
    g_material_cache.entry_count = 0;
    
#ifdef _WIN32
    LeaveCriticalSection(&g_material_cache.mutex);
#else
    pthread_mutex_unlock(&g_material_cache.mutex);
#endif
    
    CARDINAL_LOG_INFO("[MATERIAL] Cache cleared");
}
