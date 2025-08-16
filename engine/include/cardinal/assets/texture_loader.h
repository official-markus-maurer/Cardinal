#ifndef CARDINAL_ASSETS_TEXTURE_LOADER_H
#define CARDINAL_ASSETS_TEXTURE_LOADER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declaration for reference counting
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

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_TEXTURE_LOADER_H
