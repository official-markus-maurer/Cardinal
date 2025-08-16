#include "cardinal/assets/texture_loader.h"
#include "cardinal/core/log.h"
#include "cardinal/core/ref_counting.h"
#include <stdlib.h>
#include <string.h>

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

    // Try to acquire existing texture from registry
    CardinalRefCountedResource* ref_resource = cardinal_ref_acquire(filepath);
    if (ref_resource) {
        // Copy texture data from existing resource
        TextureData* existing_texture = (TextureData*)ref_resource->resource;
        *out_texture = *existing_texture;
        CARDINAL_LOG_DEBUG("[TEXTURE] Reusing cached texture: %s (ref_count=%u)", filepath,
                           cardinal_ref_get_count(ref_resource));
        return ref_resource;
    }

    // Load texture from file
    if (!texture_load_from_file(filepath, out_texture)) {
        return NULL;
    }

    // Create a copy of texture data for the registry
    TextureData* texture_copy = (TextureData*)malloc(sizeof(TextureData));
    if (!texture_copy) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for texture copy");
        texture_data_free(out_texture);
        return NULL;
    }
    *texture_copy = *out_texture;

    // Register the texture in the reference counting system
    ref_resource =
        cardinal_ref_create(filepath, texture_copy, sizeof(TextureData), texture_data_destructor);
    if (!ref_resource) {
        CARDINAL_LOG_ERROR("Failed to register texture in reference counting system: %s", filepath);
        free(texture_copy);
        texture_data_free(out_texture);
        return NULL;
    }

    CARDINAL_LOG_INFO("[TEXTURE] Registered new texture for sharing: %s", filepath);
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
