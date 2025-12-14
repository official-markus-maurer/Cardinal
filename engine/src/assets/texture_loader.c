#include "cardinal/assets/texture_loader.h"
#include "cardinal/core/async_loader.h"
#include "cardinal/core/log.h"
#include "cardinal/core/memory.h"
#include "cardinal/core/ref_counting.h"
#include "cardinal/core/resource_state.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
    #include <windows.h>
#else
    #include <pthread.h>
    #include <sys/syscall.h>
    #include <unistd.h>
#endif

// Thread-safe texture cache for multi-threaded loading with LRU eviction
typedef struct TextureCacheEntry {
    char* filepath;
    CardinalRefCountedResource* resource;
    uint64_t last_access_time;
    uint64_t memory_usage;
    struct TextureCacheEntry* next;
    struct TextureCacheEntry* prev;
} TextureCacheEntry;

typedef struct {
    TextureCacheEntry* head; // Most recently used
    TextureCacheEntry* tail; // Least recently used
    uint32_t entry_count;
    uint32_t max_entries;
    uint64_t total_memory_usage;
    uint64_t max_memory_usage;
    uint32_t cache_hits;
    uint32_t cache_misses;
    uint32_t evictions;
#ifdef _WIN32
    CRITICAL_SECTION mutex;
#else
    pthread_mutex_t mutex;
#endif
    bool initialized;
} TextureCache;

static TextureCache g_texture_cache = {0};

// Initialize the texture cache
static bool texture_cache_init(uint32_t max_entries) {
    if (g_texture_cache.initialized) {
        return true;
    }

    g_texture_cache.head = NULL;
    g_texture_cache.tail = NULL;
    g_texture_cache.entry_count = 0;
    g_texture_cache.max_entries = max_entries;
    g_texture_cache.total_memory_usage = 0;
    // Set memory limit to 512MB for texture cache
    g_texture_cache.max_memory_usage = 512 * 1024 * 1024;
    g_texture_cache.cache_hits = 0;
    g_texture_cache.cache_misses = 0;
    g_texture_cache.evictions = 0;

#ifdef _WIN32
    InitializeCriticalSection(&g_texture_cache.mutex);
#else
    if (pthread_mutex_init(&g_texture_cache.mutex, NULL) != 0) {
        CARDINAL_LOG_ERROR("Failed to initialize texture cache mutex");
        return false;
    }
#endif

    g_texture_cache.initialized = true;
    CARDINAL_LOG_INFO(
        "[TEXTURE] LRU texture cache initialized (max_entries=%u, max_memory=%llu MB)", max_entries,
        (unsigned long long)(g_texture_cache.max_memory_usage / (1024 * 1024)));
    return true;
}

// Helper function to get current time in milliseconds
static uint64_t get_current_time_ms(void) {
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
#endif
}

// Helper function to move entry to head (most recently used)
static void move_to_head(TextureCacheEntry* entry) {
    if (!entry || entry == g_texture_cache.head) {
        return;
    }

    // Remove from current position
    if (entry->prev) {
        entry->prev->next = entry->next;
    }
    if (entry->next) {
        entry->next->prev = entry->prev;
    }
    if (entry == g_texture_cache.tail) {
        g_texture_cache.tail = entry->prev;
    }

    // Move to head
    entry->prev = NULL;
    entry->next = g_texture_cache.head;
    if (g_texture_cache.head) {
        g_texture_cache.head->prev = entry;
    }
    g_texture_cache.head = entry;

    // If this was the only entry, it's also the tail
    if (!g_texture_cache.tail) {
        g_texture_cache.tail = entry;
    }
}

// Helper function to remove entry from LRU list
static void remove_from_list(TextureCacheEntry* entry) {
    if (!entry)
        return;

    if (entry->prev) {
        entry->prev->next = entry->next;
    } else {
        g_texture_cache.head = entry->next;
    }

    if (entry->next) {
        entry->next->prev = entry->prev;
    } else {
        g_texture_cache.tail = entry->prev;
    }

    entry->prev = entry->next = NULL;
}

// Helper function to calculate texture memory usage
static uint64_t calculate_texture_memory_usage(const TextureData* texture) {
    if (!texture)
        return 0;
    return (uint64_t)texture->width * texture->height * texture->channels;
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
    TextureCacheEntry* entry = g_texture_cache.head;
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);

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

    g_texture_cache.head = NULL;
    g_texture_cache.tail = NULL;
    g_texture_cache.entry_count = 0;
    g_texture_cache.total_memory_usage = 0;

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

    TextureCacheEntry* entry = g_texture_cache.head;
    while (entry) {
        if (entry->filepath && strcmp(entry->filepath, filepath) == 0) {
            // Update access time and move to head (LRU)
            entry->last_access_time = get_current_time_ms();
            move_to_head(entry);

            // Directly increment reference count of the cached resource
            CardinalRefCountedResource* resource = entry->resource;
#ifdef _WIN32
            InterlockedIncrement((LONG*)&resource->ref_count);
#else
            __atomic_add_fetch(&resource->ref_count, 1, __ATOMIC_SEQ_CST);
#endif
            g_texture_cache.cache_hits++;
            CARDINAL_LOG_DEBUG("[TEXTURE] Cache hit for %s (memory usage: %llu bytes)", filepath,
                               (unsigned long long)entry->memory_usage);
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

// Thread-safe cache insertion with LRU eviction
static bool texture_cache_put(const char* filepath, CardinalRefCountedResource* resource) {
    if (!g_texture_cache.initialized || !filepath || !resource) {
        return false;
    }

    // Calculate memory usage for this texture
    TextureData* texture_data = (TextureData*)resource;
    uint64_t texture_memory = calculate_texture_memory_usage(texture_data);

#ifdef _WIN32
    EnterCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_lock(&g_texture_cache.mutex);
#endif

    // Evict entries if we exceed memory or entry limits
    while (
        (g_texture_cache.total_memory_usage + texture_memory > g_texture_cache.max_memory_usage ||
         g_texture_cache.entry_count >= g_texture_cache.max_entries) &&
        g_texture_cache.tail) {
        TextureCacheEntry* to_remove = g_texture_cache.tail;
        remove_from_list(to_remove);

        CardinalAllocator* allocator =
            cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
        g_texture_cache.total_memory_usage -= to_remove->memory_usage;
        g_texture_cache.entry_count--;
        g_texture_cache.evictions++;

        CARDINAL_LOG_DEBUG("[TEXTURE] Evicted %s (freed %llu bytes, total: %llu/%llu bytes)",
                           to_remove->filepath ? to_remove->filepath : "unknown",
                           (unsigned long long)to_remove->memory_usage,
                           (unsigned long long)g_texture_cache.total_memory_usage,
                           (unsigned long long)g_texture_cache.max_memory_usage);

        if (to_remove->filepath) {
            cardinal_free(allocator, to_remove->filepath);
        }
        if (to_remove->resource) {
            cardinal_ref_release(to_remove->resource);
        }
        cardinal_free(allocator, to_remove);
    }

    // Create new entry
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    CARDINAL_LOG_DEBUG("[TEXTURE] Allocating cache entry for %s (size: %zu bytes)", filepath,
                       sizeof(TextureCacheEntry));
    TextureCacheEntry* new_entry = cardinal_alloc(allocator, sizeof(TextureCacheEntry));
    if (!new_entry) {
        CARDINAL_LOG_ERROR("[TEXTURE] Failed to allocate cache entry for %s (size: %zu bytes)",
                           filepath, sizeof(TextureCacheEntry));
        CARDINAL_LOG_ERROR("[TEXTURE] Current cache state: %u/%u entries, %llu/%llu bytes",
                           g_texture_cache.entry_count, g_texture_cache.max_entries,
                           (unsigned long long)g_texture_cache.total_memory_usage,
                           (unsigned long long)g_texture_cache.max_memory_usage);
#ifdef _WIN32
        LeaveCriticalSection(&g_texture_cache.mutex);
#else
        pthread_mutex_unlock(&g_texture_cache.mutex);
#endif
        return false;
    }

    // Initialize entry
    memset(new_entry, 0, sizeof(TextureCacheEntry));

    // Copy filepath
    size_t filepath_len = strlen(filepath) + 1;
    CARDINAL_LOG_DEBUG("[TEXTURE] Allocating filepath string for %s (size: %zu bytes)", filepath,
                       filepath_len);
    new_entry->filepath = cardinal_alloc(allocator, filepath_len);
    if (!new_entry->filepath) {
        CARDINAL_LOG_ERROR("[TEXTURE] Failed to allocate filepath string for %s (size: %zu bytes)",
                           filepath, filepath_len);
        CARDINAL_LOG_ERROR(
            "[TEXTURE] Cache entry allocation succeeded but filepath allocation failed");
        cardinal_free(allocator, new_entry);
#ifdef _WIN32
        LeaveCriticalSection(&g_texture_cache.mutex);
#else
        pthread_mutex_unlock(&g_texture_cache.mutex);
#endif
        return false;
    }
    strcpy(new_entry->filepath, filepath);

    // Set up entry data
    new_entry->resource = resource;
    // Increment reference count as the cache now holds a reference
#ifdef _WIN32
    InterlockedIncrement((LONG*)&resource->ref_count);
#else
    __atomic_add_fetch(&resource->ref_count, 1, __ATOMIC_SEQ_CST);
#endif
    new_entry->memory_usage = texture_memory;
    new_entry->last_access_time = get_current_time_ms();
    new_entry->prev = NULL;
    new_entry->next = NULL;

    // Add to head of list (most recently used)
    if (g_texture_cache.head) {
        g_texture_cache.head->prev = new_entry;
        new_entry->next = g_texture_cache.head;
    } else {
        g_texture_cache.tail = new_entry;
    }
    g_texture_cache.head = new_entry;

    g_texture_cache.entry_count++;
    g_texture_cache.total_memory_usage += texture_memory;

    CARDINAL_LOG_DEBUG("[TEXTURE] Cached %s (%llu bytes, total: %llu/%llu bytes, entries: %u/%u)",
                       filepath, (unsigned long long)texture_memory,
                       (unsigned long long)g_texture_cache.total_memory_usage,
                       (unsigned long long)g_texture_cache.max_memory_usage,
                       g_texture_cache.entry_count, g_texture_cache.max_entries);

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
    if (!resource) {
        CARDINAL_LOG_WARN("[CLEANUP] texture_data_destructor called with NULL resource");
        return;
    }

    TextureData* texture = (TextureData*)resource;
    CARDINAL_LOG_DEBUG("[CLEANUP] Destroying texture data at %p (size: %ux%u, %u channels)",
                       (void*)texture, texture->width, texture->height, texture->channels);

    if (texture->data) {
        CARDINAL_LOG_DEBUG("[CLEANUP] Freeing texture pixel data at %p", (void*)texture->data);
        stbi_image_free(texture->data);
        texture->data = NULL;
        CARDINAL_LOG_DEBUG("[CLEANUP] Texture pixel data freed and nullified");
    } else {
        CARDINAL_LOG_WARN("[CLEANUP] Texture data already NULL during destruction");
    }

    // Free the texture structure itself
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    cardinal_free(allocator, texture);
    CARDINAL_LOG_DEBUG("[CLEANUP] Texture structure freed");
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
        CARDINAL_LOG_ERROR("[TEXTURE] texture_load_from_file: invalid args file=%p out=%p",
                           (void*)filepath, (void*)out_texture);
        return false;
    }
    memset(out_texture, 0, sizeof(*out_texture));

    CARDINAL_LOG_INFO("[TEXTURE] Attempting to load texture: %s", filepath);

    // Check file accessibility first with crash-safe validation
    CARDINAL_LOG_DEBUG("[CRITICAL] Starting texture load for file: %s", filepath);
    FILE* test_file = fopen(filepath, "rb");
    if (!test_file) {
        CARDINAL_LOG_ERROR(
            "[CRITICAL] Cannot access file: %s (file may not exist or insufficient permissions)",
            filepath);
        return false;
    }

    // Get file size for memory planning with crash-safe validation
    if (fseek(test_file, 0, SEEK_END) != 0) {
        CARDINAL_LOG_ERROR("[CRITICAL] Failed to seek to end of texture file: %s", filepath);
        fclose(test_file);
        return false;
    }

    long file_size = ftell(test_file);
    if (file_size < 0) {
        CARDINAL_LOG_ERROR("[CRITICAL] Failed to get file size for texture: %s", filepath);
        fclose(test_file);
        return false;
    }

    fclose(test_file);
    CARDINAL_LOG_DEBUG("[CRITICAL] Loading texture file: %s (size: %ld bytes)", filepath,
                       file_size);

    // Flip vertically to match Vulkan's coordinate system
    stbi_set_flip_vertically_on_load(1);

    int w = 0, h = 0, c = 0;
    CARDINAL_LOG_DEBUG("[CRITICAL] Calling stbi_load for %s (forcing RGBA8)", filepath);
    if (!filepath || strlen(filepath) == 0) {
        CARDINAL_LOG_ERROR("[CRITICAL] Invalid filepath provided to stbi_load");
        return false;
    }

    unsigned char* data = stbi_load(filepath, &w, &h, &c, 4); // force RGBA8
    if (!data) {
        const char* reason = stbi_failure_reason();
        CARDINAL_LOG_ERROR("[CRITICAL] Failed to load image: %s", filepath);
        CARDINAL_LOG_ERROR("[CRITICAL] STB failure reason: %s", reason ? reason : "unknown");
        CARDINAL_LOG_ERROR("[CRITICAL] File size was: %ld bytes", file_size);
        CARDINAL_LOG_ERROR("[CRITICAL] Attempted dimensions: %dx%d, channels: %d", w, h, c);
        return false;
    }

    // Validate dimensions first with crash-safe checks
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) {
        CARDINAL_LOG_ERROR("[CRITICAL] Invalid dimensions from stbi_load: %dx%d for %s", w, h,
                           filepath);
        stbi_image_free(data);
        return false;
    }

    // Calculate expected memory usage with crash-safe validation
    size_t expected_size = (size_t)w * h * 4; // RGBA8
    if (expected_size == 0) {
        CARDINAL_LOG_ERROR("[CRITICAL] Calculated pixel data size is zero: %s", filepath);
        stbi_image_free(data);
        return false;
    }

    CARDINAL_LOG_DEBUG("[CRITICAL] Decoded image: %dx%d, original channels: %d, forced RGBA8", w, h,
                       c);
    CARDINAL_LOG_DEBUG("[CRITICAL] Expected memory usage: %zu bytes", expected_size);

    out_texture->data = data;
    out_texture->width = (uint32_t)w;
    out_texture->height = (uint32_t)h;
    out_texture->channels = 4;
    CARDINAL_LOG_INFO(
        "[TEXTURE] Successfully loaded texture %s (%ux%u, %u channels, original: %d, %zu bytes)",
        filepath, out_texture->width, out_texture->height, out_texture->channels, c, expected_size);
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
    CardinalAllocator* temp_allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
    CardinalRefCountedResource* temp_ref =
        cardinal_alloc(temp_allocator, sizeof(CardinalRefCountedResource));
    if (temp_ref) {
        memset(temp_ref, 0, sizeof(CardinalRefCountedResource));
        size_t filepath_len = strlen(filepath) + 1;
        temp_ref->identifier = cardinal_alloc(temp_allocator, filepath_len);
        if (temp_ref->identifier) {
            strcpy(temp_ref->identifier, filepath);
            temp_ref->ref_count = 1;
            temp_ref->resource = NULL;   // Will be set later
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
    CARDINAL_LOG_DEBUG("[TEXTURE] Current resource state for %s: %d", filepath,
                       cardinal_resource_state_get(filepath));
    if (!cardinal_resource_state_try_acquire_loading(filepath, thread_id)) {
        // Another thread is loading, wait for completion
        CARDINAL_LOG_DEBUG("[TEXTURE] Failed to acquire loading access for %s, current state: %d",
                           filepath, cardinal_resource_state_get(filepath));
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
                CARDINAL_LOG_DEBUG("[TEXTURE] Successfully retrieved texture after waiting: %s",
                                   filepath);
                return ref_resource;
            } else {
                CARDINAL_LOG_ERROR(
                    "[TEXTURE] Resource not found in cache or registry after wait: %s", filepath);
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
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);
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
    if (!texture) {
        CARDINAL_LOG_WARN("[CLEANUP] texture_data_free called with NULL texture");
        return;
    }

    CARDINAL_LOG_DEBUG("[CLEANUP] Freeing texture data at %p (size: %ux%u, %u channels)",
                       (void*)texture, texture->width, texture->height, texture->channels);

    if (texture->data) {
        CARDINAL_LOG_DEBUG("[CLEANUP] Freeing texture pixel data at %p", (void*)texture->data);
        stbi_image_free(texture->data);
        texture->data = NULL;
        CARDINAL_LOG_DEBUG("[CLEANUP] Texture pixel data freed and nullified");
    } else {
        CARDINAL_LOG_WARN("[CLEANUP] Texture data already NULL during free");
    }

    // Zero out the structure to detect use-after-free
    texture->width = 0;
    texture->height = 0;
    texture->channels = 0;
    CARDINAL_LOG_DEBUG("[CLEANUP] Texture structure zeroed for leak detection");
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
    TextureCacheEntry* entry = g_texture_cache.head;
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS);

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

    g_texture_cache.head = NULL;
    g_texture_cache.tail = NULL;
    g_texture_cache.entry_count = 0;
    g_texture_cache.total_memory_usage = 0;

#ifdef _WIN32
    LeaveCriticalSection(&g_texture_cache.mutex);
#else
    pthread_mutex_unlock(&g_texture_cache.mutex);
#endif

    CARDINAL_LOG_INFO("[TEXTURE] Cache cleared");
}
