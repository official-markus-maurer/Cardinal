#ifndef CARDINAL_ASSETS_TEXTURE_LOADER_H
#define CARDINAL_ASSETS_TEXTURE_LOADER_H

#include <stdbool.h>
#include <stdint.h>
#include "cardinal/core/async_loader.h"

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct CardinalRefCountedResource CardinalRefCountedResource;

// Texture data structure for loading images
typedef struct TextureData {
  unsigned char *data;
  uint32_t width;
  uint32_t height;
  uint32_t channels;
} TextureData;

// Load an image file and return texture data
// Returns true on success, false on failure
// Caller is responsible for freeing the data using texture_data_free()
bool texture_load_from_file(const char *filepath, TextureData *out_texture);

// Load texture with reference counting support
// Returns a reference counted resource that should be released with
// texture_release_ref_counted()
CardinalRefCountedResource *
texture_load_with_ref_counting(const char *filepath, TextureData *out_texture);

// Release a reference counted texture
void texture_release_ref_counted(CardinalRefCountedResource *ref_resource);

// Free texture data loaded by texture_load_from_file() (legacy function)
void texture_data_free(TextureData *texture);

// Load texture asynchronously with reference counting
// Returns an async task handle that can be used to check status and retrieve
// results
CardinalAsyncTask *texture_load_async(const char *filepath,
                                      CardinalAsyncPriority priority,
                                      CardinalAsyncCallback callback,
                                      void *user_data);

// Initialize the thread-safe texture cache with specified maximum entries
// This is automatically called by texture_load_with_ref_counting if not already initialized
bool texture_cache_initialize(uint32_t max_entries);

// Shutdown the texture cache and free all cached resources
void texture_cache_shutdown_system(void);

// Get cache statistics for monitoring
typedef struct TextureCacheStats {
    uint32_t entry_count;
    uint32_t max_entries;
    uint32_t cache_hits;
    uint32_t cache_misses;
} TextureCacheStats;

// Get current cache statistics
TextureCacheStats texture_cache_get_stats(void);

// Clear all entries from the texture cache
void texture_cache_clear(void);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_TEXTURE_LOADER_H
