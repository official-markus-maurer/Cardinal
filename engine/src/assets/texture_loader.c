#include "cardinal/assets/texture_loader.h"
#include "cardinal/core/async_loader.h"
#include "cardinal/core/log.h"
#include "cardinal/core/ref_counting.h"
#include "cardinal/core/resource_state.h"
#include "cardinal/core/memory.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#include <sys/syscall.h>
#endif

// Thread-safe texture cache for multi-threaded loading
typedef struct TextureCacheEntry {
    char* filepath;
    CardinalRefCountedResource* resource;
    struct TextureCacheEntry* next;
} TextureCacheEntry;

typedef struct {
    TextureCacheEntry* entries;
    uint32_t entry_count;
    uint32_t max_entries;
    uint32_t cache_hits;
    uint32_t cache_misses;
#ifdef _WIN32
    CRITICAL_SECTION mutex;
#else
    pthread_mutex_t mutex;
#endif
    bool initialized;
} TextureCache;

static TextureCache g_texture_cache = {0};

// Initialize the thread-safe texture cache
static bool texture_cache_init(uint32_t max_entries) {
    if (g_texture_cache.initialized) {
        return true;
    }

    g_texture_cache.entries = NULL;
    g_texture_cache.entry_count = 0;
    g_texture_cache.max_entries = max_entries;
    g_texture_cache.cache_hits = 0;
    g_texture_cache.cache_misses = 0;

#ifdef _WIN32
    InitializeCriticalSection(&g_texture_cache.mutex);
#else
    if (pthread_mutex_init(&g_texture_cache.mutex, NULL) != 0) {
        CARDINAL_LOG_ERROR("Failed to initialize texture cache mutex");
        return false;
    }
#endif

    g_texture_cache.initialized = true;
    CARDINAL_LOG_INFO("[TEXTURE] Thread-safe texture cache initialized (max_entries=%u)", max_entries);
    return true;
}

// Shutdown the texture cache
static void texture_cache_shutdown(void) {
    if (!g_texture_cache.initialized) {
        return;
    }

#ifdef _WIN32
    EnterCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_lock(&g_texture_cache.mutex);
#endif

    // Free all cache entries
    TextureCacheEntry* entry = g_texture_cache.entries;
    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    
    while (entry) {
        TextureCacheEntry* next = entry->next;
        if (entry->filepath) {
            cardinal_free(allocator, entry->filepath);
        }
        if (entry->resource) {
            cardinal_ref_release(entry->resource);
        }
        cardinal_free(allocator, entry);
        entry = next;
    }

    g_texture_cache.entries = NULL;
    g_texture_cache.entry_count = 0;

#ifdef _WIN32
    LeaveCriticalSection(&g_texture_cache.mutex);
    DeleteCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_unlock(&g_texture_cache.mutex);
    pthread_mutex_destroy(&g_texture_cache.mutex);
#endif

    g_texture_cache.initialized = false;
    CARDINAL_LOG_INFO("[TEXTURE] Thread-safe texture cache shutdown");
}

// Thread-safe cache lookup
static CardinalRefCountedResource* texture_cache_get(const char* filepath) {
    if (!g_texture_cache.initialized || !filepath) {
        return NULL;
    }

#ifdef _WIN32
    EnterCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_lock(&g_texture_cache.mutex);
#endif

    TextureCacheEntry* entry = g_texture_cache.entries;
    while (entry) {
        if (entry->filepath && strcmp(entry->filepath, filepath) == 0) {
            // Directly increment reference count of the cached resource
            CardinalRefCountedResource* resource = entry->resource;
#ifdef _WIN32
            InterlockedIncrement((LONG*)&resource->ref_count);
#else
            __atomic_add_fetch(&resource->ref_count, 1, __ATOMIC_SEQ_CST);
#endif
            g_texture_cache.cache_hits++;
#ifdef _WIN32
            LeaveCriticalSection(&g_texture_cache.mutex);
#else
            pthread_mutex_unlock(&g_texture_cache.mutex);
#endif
            return resource;
        }
        entry = entry->next;
    }

    g_texture_cache.cache_misses++;
#ifdef _WIN32
    LeaveCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_unlock(&g_texture_cache.mutex);
#endif

    return NULL;
}

// Thread-safe cache insertion
static bool texture_cache_put(const char* filepath, CardinalRefCountedResource* resource) {
    if (!g_texture_cache.initialized || !filepath || !resource) {
        return false;
    }

#ifdef _WIN32
    EnterCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_lock(&g_texture_cache.mutex);
#endif

    // Check if we've reached max capacity
    if (g_texture_cache.entry_count >= g_texture_cache.max_entries) {
        // Remove oldest entry (simple FIFO eviction)
        if (g_texture_cache.entries) {
            TextureCacheEntry* to_remove = g_texture_cache.entries;
            g_texture_cache.entries = to_remove->next;
            
            CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
            if (to_remove->filepath) {
                cardinal_free(allocator, to_remove->filepath);
            }
            if (to_remove->resource) {
                cardinal_ref_release(to_remove->resource);
            }
            cardinal_free(allocator, to_remove);
            g_texture_cache.entry_count--;
        }
    }

    // Create new entry
    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    TextureCacheEntry* new_entry = cardinal_alloc(allocator, sizeof(TextureCacheEntry));
    if (!new_entry) {
#ifdef _WIN32
        LeaveCriticalSection(&g_texture_cache.mutex);
#else
        pthread_mutex_unlock(&g_texture_cache.mutex);
#endif
        return false;
    }

    // Copy filepath
    size_t filepath_len = strlen(filepath) + 1;
    new_entry->filepath = cardinal_alloc(allocator, filepath_len);
    if (!new_entry->filepath) {
        cardinal_free(allocator, new_entry);
#ifdef _WIN32
        LeaveCriticalSection(&g_texture_cache.mutex);
#else
        pthread_mutex_unlock(&g_texture_cache.mutex);
#endif
        return false;
    }
    strcpy(new_entry->filepath, filepath);

    // Add reference to resource
    new_entry->resource = resource; // Resource is already reference counted
    new_entry->next = g_texture_cache.entries;
    g_texture_cache.entries = new_entry;
    g_texture_cache.entry_count++;

#ifdef _WIN32
    LeaveCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_unlock(&g_texture_cache.mutex);
#endif

    return true;
}

// Use official stb_image implementation
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_HDR
#define STBI_NO_PSD
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STBI_NO_GIF
#define STBI_NO_TGA
#define STBI_NO_LINEAR
#define STBI_MALLOC(sz) malloc(sz)
#define STBI_FREE(p) free(p)
#define STBI_REALLOC(p, nsz) realloc(p, nsz)
#include <stb_image.h>

/**
 * @brief Loads texture data from a file.
 * @param filepath Path to the image file.
 * @param out_texture Pointer to store loaded data.
 * @return true on success, false on failure.
 *
 * @todo Support more image formats beyond STB (e.g., DDS for compressed textures).
 * @todo Integrate Vulkan extension VK_KHR_sampler_ycbcr_conversion for advanced sampling.
 */
/**
 * @brief Destructor function for reference counted textures
 * @param resource Pointer to the TextureData to free
 */
static void texture_data_destructor(void* resource) {
    TextureData* texture = (TextureData*)resource;
    if (texture && texture->data) {
        stbi_image_free(texture->data);
        texture->data = NULL;
    }
    texture->width = texture->height = texture->channels = 0;
}

/**
 * @brief Loads texture data from a file with reference counting.
 *
 * @param filepath Path to the image file.
 * @param out_texture Pointer to store loaded data.
 * @return true on success, false on failure.
 *
 * @todo Support additional formats like DDS or KTX.
 * @todo Add options for mipmapping and compression.
 */
bool texture_load_from_file(const char* filepath, TextureData* out_texture) {
    if (!filepath || !out_texture) {
        LOG_ERROR("texture_load_from_file: invalid args file=%p out=%p", (void*)filepath,
                  (void*)out_texture);
        return false;
    }
    memset(out_texture, 0, sizeof(*out_texture));

    CARDINAL_LOG_INFO("[TEXTURE] Attempting to load texture: %s", filepath);

    // Flip vertically to match Vulkan's coordinate system
    stbi_set_flip_vertically_on_load(1);

    int w = 0, h = 0, c = 0;
    unsigned char* data = stbi_load(filepath, &w, &h, &c, 4); // force RGBA8
    if (!data) {
        const char* reason = stbi_failure_reason();
        CARDINAL_LOG_ERROR("[TEXTURE] Failed to load image: %s - STB reason: %s", filepath,
                           reason ? reason : "unknown");
        return false;
    }

    out_texture->data = data;
    out_texture->width = (uint32_t)w;
    out_texture->height = (uint32_t)h;
    out_texture->channels = 4;
    CARDINAL_LOG_INFO("[TEXTURE] Successfully loaded texture %s (%ux%u, %u channels original: %d)",
                      filepath, out_texture->width, out_texture->height, out_texture->channels, c);
    return true;
}

/**
 * @brief Load texture with reference counting support
 *
 * Attempts to load a texture from the reference counting registry first.
 * If not found, loads from file and registers it for sharing.
 *
 * @param filepath Path to the image file
 * @param out_texture Pointer to store loaded data
 * @return Pointer to reference counted resource, or NULL on failure
 */
CardinalRefCountedResource* texture_load_with_ref_counting(const char* filepath,
                                                           TextureData* out_texture) {
    if (!filepath || !out_texture) {
        CARDINAL_LOG_ERROR("texture_load_with_ref_counting: invalid args file=%p out=%p",
                           (void*)filepath, (void*)out_texture);
        return NULL;
    }

    // Initialize cache if not already done
    if (!g_texture_cache.initialized) {
        texture_cache_init(256); // Default cache size
    }

    // Check resource state first
    CardinalResourceState state = cardinal_resource_state_get(filepath);
    
    // If resource is already loaded, try to get it from cache/registry
    if (state == CARDINAL_RESOURCE_STATE_LOADED) {
        CardinalRefCountedResource* ref_resource = texture_cache_get(filepath);
        if (ref_resource) {
            TextureData* existing_texture = (TextureData*)ref_resource->resource;
            *out_texture = *existing_texture;
            CARDINAL_LOG_DEBUG("[TEXTURE] Reusing loaded texture: %s (ref_count=%u)", filepath,
                               cardinal_ref_get_count(ref_resource));
            return ref_resource;
        }
        
        // Fallback to registry
        ref_resource = cardinal_ref_acquire(filepath);
        if (ref_resource) {
            TextureData* existing_texture = (TextureData*)ref_resource->resource;
            *out_texture = *existing_texture;
            texture_cache_put(filepath, ref_resource);
            CARDINAL_LOG_DEBUG("[TEXTURE] Reusing registry texture: %s (ref_count=%u)", filepath,
                               cardinal_ref_get_count(ref_resource));
            return ref_resource;
        }
    }
    
    // If resource is currently loading, wait for it to complete
    if (state == CARDINAL_RESOURCE_STATE_LOADING) {
        CARDINAL_LOG_DEBUG("[TEXTURE] Waiting for texture to finish loading: %s", filepath);
        if (cardinal_resource_state_wait_for(filepath, CARDINAL_RESOURCE_STATE_LOADED, 5000)) {
            // Try to get the loaded resource
            CardinalRefCountedResource* ref_resource = texture_cache_get(filepath);
            if (!ref_resource) {
                ref_resource = cardinal_ref_acquire(filepath);
            }
            if (ref_resource) {
                TextureData* existing_texture = (TextureData*)ref_resource->resource;
                *out_texture = *existing_texture;
                CARDINAL_LOG_DEBUG("[TEXTURE] Got texture after waiting: %s", filepath);
                return ref_resource;
            }
        } else {
            CARDINAL_LOG_WARN("[TEXTURE] Timeout waiting for texture to load: %s", filepath);
        }
    }
    
    // Try to acquire loading access
    uint32_t thread_id = 0;
#ifdef _WIN32
    thread_id = GetCurrentThreadId();
#else
    thread_id = (uint32_t)syscall(SYS_gettid);
#endif
    // Create a temporary ref resource for state tracking registration
    CardinalAllocator* temp_allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    CardinalRefCountedResource* temp_ref = cardinal_alloc(temp_allocator, sizeof(CardinalRefCountedResource));
    if (temp_ref) {
        memset(temp_ref, 0, sizeof(CardinalRefCountedResource));
        size_t filepath_len = strlen(filepath) + 1;
        temp_ref->identifier = cardinal_alloc(temp_allocator, filepath_len);
        if (temp_ref->identifier) {
            strcpy(temp_ref->identifier, filepath);
            temp_ref->ref_count = 1;
            temp_ref->resource = NULL; // Will be set later
            temp_ref->destructor = NULL; // Will be set later
            
            CARDINAL_LOG_DEBUG("[TEXTURE] Attempting to register resource: %s", filepath);
            // Register with state tracking system
            CardinalResourceStateTracker* tracker = cardinal_resource_state_register(temp_ref);
            if (!tracker) {
                CARDINAL_LOG_WARN("Failed to register texture with state tracking: %s", filepath);
                cardinal_free(temp_allocator, temp_ref->identifier);
                cardinal_free(temp_allocator, temp_ref);
            } else {
                CARDINAL_LOG_DEBUG("[TEXTURE] Successfully registered resource: %s", filepath);
            }
        } else {
            CARDINAL_LOG_ERROR("[TEXTURE] Failed to allocate identifier for: %s", filepath);
            cardinal_free(temp_allocator, temp_ref);
        }
    } else {
        CARDINAL_LOG_ERROR("[TEXTURE] Failed to allocate temp_ref for: %s", filepath);
    }

    // Try to acquire loading access
    CARDINAL_LOG_DEBUG("[TEXTURE] Current resource state for %s: %d", filepath, cardinal_resource_state_get(filepath));
    if (!cardinal_resource_state_try_acquire_loading(filepath, thread_id)) {
        // Another thread is loading, wait for completion
        CARDINAL_LOG_DEBUG("[TEXTURE] Failed to acquire loading access for %s, current state: %d", filepath, cardinal_resource_state_get(filepath));
        CARDINAL_LOG_DEBUG("[TEXTURE] Another thread is loading, waiting: %s", filepath);
        if (cardinal_resource_state_wait_for(filepath, CARDINAL_RESOURCE_STATE_LOADED, 5000)) {
            CARDINAL_LOG_DEBUG("[TEXTURE] Wait succeeded, trying to get from cache: %s", filepath);
            CardinalRefCountedResource* ref_resource = texture_cache_get(filepath);
            if (!ref_resource) {
                CARDINAL_LOG_DEBUG("[TEXTURE] Not in cache, trying registry: %s", filepath);
                ref_resource = cardinal_ref_acquire(filepath);
            } else {
                CARDINAL_LOG_DEBUG("[TEXTURE] Found in cache: %s", filepath);
            }
            if (ref_resource) {
                TextureData* existing_texture = (TextureData*)ref_resource->resource;
                *out_texture = *existing_texture;
                CARDINAL_LOG_DEBUG("[TEXTURE] Successfully retrieved texture after waiting: %s", filepath);
                return ref_resource;
            } else {
                CARDINAL_LOG_ERROR("[TEXTURE] Resource not found in cache or registry after wait: %s", filepath);
            }
        } else {
            CARDINAL_LOG_ERROR("[TEXTURE] Wait for resource loading timed out: %s", filepath);
        }
        CARDINAL_LOG_ERROR("[TEXTURE] Failed to get texture after waiting: %s", filepath);
        return NULL;
    }
    
    CARDINAL_LOG_DEBUG("[TEXTURE] Starting texture load: %s", filepath);
    
    // Load texture from file
    CARDINAL_LOG_DEBUG("[TEXTURE] About to call texture_load_from_file for: %s", filepath);
    if (!texture_load_from_file(filepath, out_texture)) {
        CARDINAL_LOG_ERROR("[TEXTURE] texture_load_from_file failed for: %s", filepath);
        cardinal_resource_state_set(filepath, CARDINAL_RESOURCE_STATE_ERROR, thread_id);
        return NULL;
    }
    CARDINAL_LOG_DEBUG("[TEXTURE] texture_load_from_file succeeded for: %s", filepath);

    // Create a copy of texture data for the registry
    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    TextureData* texture_copy = cardinal_alloc(allocator, sizeof(TextureData));
    if (!texture_copy) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for texture copy");
        texture_data_free(out_texture);
        cardinal_resource_state_set(filepath, CARDINAL_RESOURCE_STATE_ERROR, thread_id);
        return NULL;
    }
    *texture_copy = *out_texture;

    // Register the texture in the reference counting system
    CardinalRefCountedResource* ref_resource =
        cardinal_ref_create(filepath, texture_copy, sizeof(TextureData), texture_data_destructor);
    if (!ref_resource) {
        CARDINAL_LOG_ERROR("Failed to register texture in reference counting system: %s", filepath);
        cardinal_free(allocator, texture_copy);
        texture_data_free(out_texture);
        cardinal_resource_state_set(filepath, CARDINAL_RESOURCE_STATE_ERROR, thread_id);
        return NULL;
    }
    
    // Add to cache for future access BEFORE marking as loaded
    // This ensures other threads can find the resource when they wake up
    texture_cache_put(filepath, ref_resource);
    
    // Register with state tracking system
    CardinalResourceStateTracker* tracker = cardinal_resource_state_register(ref_resource);
    if (!tracker) {
        CARDINAL_LOG_WARN("Failed to register texture with state tracking: %s", filepath);
    }
    
    // Mark as loaded LAST - this will notify waiting threads
    // By this point, the resource is fully available in cache and registry
    cardinal_resource_state_set(filepath, CARDINAL_RESOURCE_STATE_LOADED, thread_id);

    CARDINAL_LOG_INFO("[TEXTURE] Successfully loaded and registered texture: %s", filepath);
    return ref_resource;
}

/**
 * @brief Release a reference counted texture
 *
 * Decrements the reference count and frees the texture if no more references exist.
 *
 * @param ref_resource Reference counted texture resource
 */
void texture_release_ref_counted(CardinalRefCountedResource* ref_resource) {
    if (ref_resource) {
        cardinal_ref_release(ref_resource);
    }
}

/**
 * @brief Frees texture data (legacy function).
 * @param texture Pointer to the texture data to free.
 *
 * @note This function is kept for backward compatibility.
 *       New code should use texture_load_with_ref_counting() and texture_release_ref_counted().
 */
void texture_data_free(TextureData* texture) {
    if (!texture)
        return;
    if (texture->data) {
        stbi_image_free(texture->data);
        texture->data = NULL;
    }
    texture->width = texture->height = texture->channels = 0;
}

/**
 * @brief Load texture asynchronously with reference counting
 *
 * Loads a texture file in a background thread to prevent UI blocking.
 * The texture will be automatically registered in the reference counting
 * system for sharing between multiple users.
 *
 * @param filepath Path to the image file
 * @param priority Loading priority (higher priority tasks are processed first)
 * @param callback Function to call when loading completes (can be NULL)
 * @param user_data User data passed to the callback function
 * @return Async task handle, or NULL on failure
 *
 * @note The callback is called on the main thread when processing completed
 *       tasks with cardinal_async_process_completed_tasks()
 * @note Use cardinal_async_get_texture_result() to retrieve the loaded texture
 * @note Call cardinal_async_free_task() when done with the task handle
 *
 * @see cardinal_async_get_texture_result()
 * @see cardinal_async_free_task()
 * @see cardinal_async_process_completed_tasks()
 */
CardinalAsyncTask* texture_load_async(const char* filepath, CardinalAsyncPriority priority,
                                      CardinalAsyncCallback callback, void* user_data) {
    if (!filepath) {
        CARDINAL_LOG_ERROR("texture_load_async: invalid filepath");
        return NULL;
    }

    if (!cardinal_async_loader_is_initialized()) {
        CARDINAL_LOG_ERROR("Async loader not initialized");
        return NULL;
    }

    CARDINAL_LOG_INFO("[TEXTURE] Async texture loading requested: %s", filepath);

    return cardinal_async_load_texture(filepath, priority, callback, user_data);
}

// Public texture cache management functions
bool texture_cache_initialize(uint32_t max_entries) {
    return texture_cache_init(max_entries);
}

void texture_cache_shutdown_system(void) {
    texture_cache_shutdown();
}

TextureCacheStats texture_cache_get_stats(void) {
    TextureCacheStats stats = {0};
    
    if (!g_texture_cache.initialized) {
        return stats;
    }
    
#ifdef _WIN32
    EnterCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_lock(&g_texture_cache.mutex);
#endif
    
    stats.entry_count = g_texture_cache.entry_count;
     stats.max_entries = g_texture_cache.max_entries;
     stats.cache_hits = g_texture_cache.cache_hits;
     stats.cache_misses = g_texture_cache.cache_misses;
     
#ifdef _WIN32
     LeaveCriticalSection(&g_texture_cache.mutex);
#else
     pthread_mutex_unlock(&g_texture_cache.mutex);
#endif
    
    return stats;
}

void texture_cache_clear(void) {
    if (!g_texture_cache.initialized) {
        return;
    }
    
#ifdef _WIN32
    EnterCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_lock(&g_texture_cache.mutex);
#endif
    
    // Free all cache entries
    TextureCacheEntry* entry = g_texture_cache.entries;
    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    
    while (entry) {
        TextureCacheEntry* next = entry->next;
        if (entry->filepath) {
            cardinal_free(allocator, entry->filepath);
        }
        if (entry->resource) {
            cardinal_ref_release(entry->resource);
        }
        cardinal_free(allocator, entry);
        entry = next;
    }
    
    g_texture_cache.entries = NULL;
    g_texture_cache.entry_count = 0;
    
#ifdef _WIN32
    LeaveCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_unlock(&g_texture_cache.mutex);
#endif
    
    CARDINAL_LOG_INFO("[TEXTURE] Cache cleared");
}
