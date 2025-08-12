#include <stdlib.h>
#include <string.h>
#include "cardinal/assets/texture_loader.h"
#include "cardinal/core/log.h"

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
#define STBI_REALLOC(p,nsz) realloc(p,nsz)
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
 * @brief Loads texture data from a file.
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
        LOG_ERROR("texture_load_from_file: invalid args file=%p out=%p", (void*)filepath, (void*)out_texture);
        return false;
    }
    memset(out_texture, 0, sizeof(*out_texture));

    // Flip vertically to match Vulkan's coordinate system if desired
    stbi_set_flip_vertically_on_load(0);

    int w=0,h=0,c=0;
    unsigned char* data = stbi_load(filepath, &w, &h, &c, 4); // force RGBA8
    if (!data) {
        LOG_ERROR("Failed to load image: %s", filepath);
        return false;
    }

    out_texture->data = data;
    out_texture->width = (uint32_t)w;
    out_texture->height = (uint32_t)h;
    out_texture->channels = 4;
    LOG_INFO("Loaded texture %s (%ux%u, %u channels)", filepath, out_texture->width, out_texture->height, out_texture->channels);
    return true;
}

/**
 * @brief Frees texture data.
 * @param texture Pointer to the texture data to free.
 * 
 * @todo Refactor to handle reference counting for shared textures.
 * @todo Add asynchronous loading to improve performance in multi-threaded scenarios.
 */
/**
 * @brief Frees texture data.
 *
 * @param texture Pointer to the texture data to free.
 *
 * @todo Implement reference counting for shared textures.
 */
void texture_data_free(TextureData* texture) {
    if (!texture) return;
    if (texture->data) {
        stbi_image_free(texture->data);
        texture->data = NULL;
    }
    texture->width = texture->height = texture->channels = 0;
}
