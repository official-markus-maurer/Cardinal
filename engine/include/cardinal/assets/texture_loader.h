#ifndef CARDINAL_ASSETS_TEXTURE_LOADER_H
#define CARDINAL_ASSETS_TEXTURE_LOADER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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

// Free texture data loaded by texture_load_from_file()
void texture_data_free(TextureData *texture);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_TEXTURE_LOADER_H
