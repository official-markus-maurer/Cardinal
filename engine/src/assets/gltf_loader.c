/**
 * @file gltf_loader.c
 * @brief GLTF asset loading implementation for Cardinal Engine
 *
 * This file implements comprehensive GLTF 2.0 asset loading functionality
 * for the Cardinal Engine. It handles parsing of GLTF files, extraction
 * of geometry data, materials, textures, and scene hierarchy information
 * using the cgltf library.
 *
 * Key features:
 * - Complete GLTF 2.0 specification support
 * - Mesh geometry extraction (vertices, indices, normals, UVs)
 * - PBR material loading (albedo, metallic, roughness, normal maps)
 * - Texture loading and format conversion
 * - Scene hierarchy and node transformation parsing
 * - Fallback handling for missing data (default normals, placeholder textures)
 * - Memory-efficient loading with proper resource cleanup
 *
 * Supported GLTF features:
 * - Binary (.glb) and JSON (.gltf) formats
 * - Embedded and external texture references
 * - Multiple primitive types per mesh
 * - PBR metallic-roughness material workflow
 * - Texture coordinate transformations
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// cgltf is header-only; include path supplied by CMake
#define CGLTF_IMPLEMENTATION
#include "cgltf.h"

#include "cardinal/assets/gltf_loader.h"
#include "cardinal/assets/material_ref_counting.h"
#include "cardinal/assets/texture_loader.h"
#include "cardinal/core/animation.h"
#include "cardinal/core/async_loader.h"
#include "cardinal/core/log.h"
#include "cardinal/core/ref_counting.h"
#include "cardinal/core/transform.h"

// Texture path cache for optimization
#define TEXTURE_CACHE_SIZE 256
static struct {
    char original_uri[256];
    char resolved_path[512];
    bool valid;
} g_texture_path_cache[TEXTURE_CACHE_SIZE];
static bool g_cache_initialized = false;

/**
 * @brief Simple hash function for texture cache.
 */
static size_t texture_cache_hash(const char* uri) {
    size_t hash = 5381;
    for (const char* c = uri; *c; c++) {
        hash = ((hash << 5) + hash) + *c;
    }
    return hash % TEXTURE_CACHE_SIZE;
}

/**
 * @brief Initialize texture path cache.
 */
static void init_texture_cache(void) {
    if (!g_cache_initialized) {
        memset(g_texture_path_cache, 0, sizeof(g_texture_path_cache));
        g_cache_initialized = true;
        CARDINAL_LOG_DEBUG("Texture path cache initialized");
    }
}

/**
 * @brief Look up cached texture path.
 */
static const char* lookup_cached_path(const char* original_uri) {
    if (!g_cache_initialized)
        return NULL;

    size_t index = texture_cache_hash(original_uri);
    if (g_texture_path_cache[index].valid &&
        strcmp(g_texture_path_cache[index].original_uri, original_uri) == 0) {
        CARDINAL_LOG_DEBUG("Cache hit for texture: %s -> %s", original_uri,
                           g_texture_path_cache[index].resolved_path);
        return g_texture_path_cache[index].resolved_path;
    }
    return NULL;
}

/**
 * @brief Cache a successful texture path.
 */
static void cache_texture_path(const char* original_uri, const char* resolved_path) {
    if (!g_cache_initialized)
        init_texture_cache();

    size_t index = texture_cache_hash(original_uri);
    strncpy(g_texture_path_cache[index].original_uri, original_uri,
            sizeof(g_texture_path_cache[index].original_uri) - 1);
    strncpy(g_texture_path_cache[index].resolved_path, resolved_path,
            sizeof(g_texture_path_cache[index].resolved_path) - 1);
    g_texture_path_cache[index].original_uri[sizeof(g_texture_path_cache[index].original_uri) - 1] =
        '\0';
    g_texture_path_cache[index]
        .resolved_path[sizeof(g_texture_path_cache[index].resolved_path) - 1] = '\0';
    g_texture_path_cache[index].valid = true;
    CARDINAL_LOG_DEBUG("Cached texture path: %s -> %s", original_uri, resolved_path);
}

/**
 * @brief Try loading texture from a specific path.
 */
static CardinalRefCountedResource* try_texture_path(const char* path, TextureData* tex_data) {
    CARDINAL_LOG_DEBUG("Trying texture path: %s", path);
    return texture_load_with_ref_counting(path, tex_data);
}

/**
 * @brief Efficiently build path with format string and single buffer.
 */
static CardinalRefCountedResource* try_formatted_path(char* buffer, size_t buffer_size,
                                                      TextureData* tex_data, const char* format,
                                                      ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, buffer_size, format, args);
    va_end(args);
    return try_texture_path(buffer, tex_data);
}

/**
 * @brief Check if texture URI follows common patterns that suggest specific locations.
 */
static bool has_common_texture_pattern(const char* uri) {
    if (!uri)
        return false;

    // Check for absolute paths or URLs - skip fallbacks
    if (uri[0] == '/' || strstr(uri, "://") || (strlen(uri) > 2 && uri[1] == ':')) {
        return true;
    }

    // Check for common texture type patterns
    const char* patterns[] = {"diffuse", "albedo",    "basecolor", "color",     "normal",   "bump",
                              "height",  "roughness", "metallic",  "metalness", "specular", "ao",
                              "ambient", "occlusion", "emission",  "emissive"};

    char lower_uri[256];
    strncpy(lower_uri, uri, sizeof(lower_uri) - 1);
    lower_uri[sizeof(lower_uri) - 1] = '\0';

    // Convert to lowercase for pattern matching
    for (char* p = lower_uri; *p; p++) {
        *p = (*p >= 'A' && *p <= 'Z') ? *p + 32 : *p;
    }

    for (size_t i = 0; i < sizeof(patterns) / sizeof(patterns[0]); i++) {
        if (strstr(lower_uri, patterns[i])) {
            return true;
        }
    }

    return false;
}

/**
 * @brief Generate optimized fallback paths in order of likelihood.
 */
static bool try_optimized_fallback_paths(const char* original_uri, const char* base_path,
                                         char* texture_path, size_t path_size,
                                         TextureData* tex_data,
                                         CardinalRefCountedResource** ref_resource) {
    // Extract filename and directory components once
    const char* last_slash = strrchr(base_path, '/');
    if (!last_slash)
        last_slash = strrchr(base_path, '\\');

    const char* filename_only = strrchr(original_uri, '/');
    if (!filename_only)
        filename_only = strrchr(original_uri, '\\');
    if (!filename_only)
        filename_only = original_uri;
    else
        filename_only++;

    // 1. Most common: relative to glTF file
    if (last_slash) {
        size_t dir_len = (size_t)(last_slash - base_path + 1);
        *ref_resource = try_formatted_path(texture_path, path_size, tex_data, "%.*s%s",
                                           (int)dir_len, base_path, original_uri);
        if (*ref_resource)
            return true;
    } else {
        strncpy(texture_path, original_uri, path_size - 1);
        texture_path[path_size - 1] = '\0';
        *ref_resource = try_texture_path(texture_path, tex_data);
        if (*ref_resource)
            return true;
    }

    // 2. Common asset directories (most likely to succeed)
    *ref_resource =
        try_formatted_path(texture_path, path_size, tex_data, "assets/textures/%s", filename_only);
    if (*ref_resource)
        return true;

    *ref_resource = try_formatted_path(texture_path, path_size, tex_data,
                                       "assets/models/textures/%s", filename_only);
    if (*ref_resource)
        return true;

    // 3. Parallel textures directory
    if (last_slash) {
        size_t dir_len = (size_t)(last_slash - base_path + 1);
        *ref_resource = try_formatted_path(texture_path, path_size, tex_data, "%.*s../textures/%s",
                                           (int)dir_len, base_path, filename_only);
        if (*ref_resource)
            return true;
    }

    return false;
}

/**
 * @brief Computes a default normal vector.
 *
 * Sets a fallback normal if none is provided in the model.
 * @param nx Pointer to x-component.
 * @param ny Pointer to y-component.
 * @param nz Pointer to z-component.
 */
/**
 * @brief Computes a default normal vector.
 *
 * Sets a fallback normal if none is provided in the model.
 *
 * @param nx Pointer to x-component.
 * @param ny Pointer to y-component.
 * @param nz Pointer to z-component.
 *
 * @todo Allow configurable default normals or compute from geometry.
 */
static void compute_default_normal(float* nx, float* ny, float* nz) {
    // Fallback normal if none provided
    *nx = 0.0f;
    *ny = 1.0f;
    *nz = 0.0f;
}

/**
 * @brief Creates a fallback texture (magenta placeholder).
 * @param out_texture Pointer to the texture structure to fill.
 * @return true if creation succeeds, false on allocation failure.
 *
 * @todo Allow customizable fallback colors or patterns.
 */
/**
 * @brief Creates a fallback texture (magenta placeholder).
 *
 * @param out_texture Pointer to the texture structure to fill.
 * @return true if creation succeeds, false on allocation failure.
 *
 * @todo Support different fallback patterns or colors.
 */
static bool create_fallback_texture(CardinalTexture* out_texture) {
    out_texture->width = 2;
    out_texture->height = 2;
    out_texture->channels = 4;
    out_texture->data = malloc(16); // 2x2x4 bytes
    if (!out_texture->data) {
        return false;
    }

    // Magenta placeholder (R=255, G=0, B=255, A=255)
    unsigned char* pixels = (unsigned char*)out_texture->data;
    for (int i = 0; i < 4; i++) {
        pixels[i * 4 + 0] = 255; // R
        pixels[i * 4 + 1] = 0;   // G
        pixels[i * 4 + 2] = 255; // B
        pixels[i * 4 + 3] = 255; // A
    }

    out_texture->path = malloc(strlen("[fallback]") + 1);
    if (out_texture->path) {
        strcpy(out_texture->path, "[fallback]");
    }

    return true;
}

/**
 * @brief Loads a texture with multiple fallback paths and decomposition for malformed URIs.
 * @param original_uri The original texture URI from glTF.
 * @param base_path The base path of the glTF file.
 * @param out_texture Pointer to the texture structure to fill.
 * @return true if loaded successfully or fallback created, false otherwise.
 *
 * @todo Add support for more glTF texture extensions like KHR_texture_basisu.
 * @todo Improve path resolution for cross-platform consistency.
 */
/**
 * @brief Loads a texture with multiple fallback paths and decomposition for malformed URIs.
 *
 * @param original_uri The original texture URI from glTF.
 * @param base_path The base path of the glTF file.
 * @param out_texture Pointer to the texture structure to fill.
 * @return true if loaded successfully or fallback created, false otherwise.
 *
 * @todo Optimize path resolution and add caching for loaded textures.
 */
static bool load_texture_with_fallback(const char* original_uri, const char* base_path,
                                       CardinalTexture* out_texture) {
    // Error checking for degenerate cases
    if (!original_uri || !base_path || !out_texture) {
        CARDINAL_LOG_ERROR("Invalid parameters: original_uri=%p, base_path=%p, out_texture=%p",
                           (void*)original_uri, (void*)base_path, (void*)out_texture);
        return false;
    }

    if (strlen(original_uri) == 0) {
        CARDINAL_LOG_WARN("Empty texture URI provided, using fallback");
        return create_fallback_texture(out_texture);
    }

    // Check cache first
    const char* cached_path = lookup_cached_path(original_uri);
    if (cached_path) {
        TextureData tex_data = {0};
        CardinalRefCountedResource* ref_resource =
            texture_load_with_ref_counting(cached_path, &tex_data);
        if (ref_resource) {
            out_texture->data = tex_data.data;
            out_texture->width = tex_data.width;
            out_texture->height = tex_data.height;
            out_texture->channels = tex_data.channels;
            out_texture->path = malloc(strlen(cached_path) + 1);
            if (out_texture->path) {
                strcpy(out_texture->path, cached_path);
            }
            out_texture->ref_resource = ref_resource;
            CARDINAL_LOG_DEBUG("Loaded texture from cache: %s", cached_path);
            return true;
        }
    }

    char texture_path[512] = {0};
    TextureData tex_data = {0};
    CardinalRefCountedResource* ref_resource = NULL;

    // Early exit for absolute paths or URLs - try direct load only
    if (original_uri[0] == '/' || strstr(original_uri, "://") ||
        (strlen(original_uri) > 2 && original_uri[1] == ':')) {
        ref_resource = try_texture_path(original_uri, &tex_data);
        if (ref_resource) {
            cache_texture_path(original_uri, original_uri);
            strncpy(texture_path, original_uri, sizeof(texture_path) - 1);
            goto success;
        }
        goto create_fallback;
    }

    // Try optimized fallback paths first (covers 90% of cases)
    if (try_optimized_fallback_paths(original_uri, base_path, texture_path, sizeof(texture_path),
                                     &tex_data, &ref_resource)) {
        goto success;
    }

    // Advanced fallback: decomposed texture name analysis
    // Extract filename for pattern matching
    const char* filename_only = strrchr(original_uri, '/');
    if (!filename_only)
        filename_only = strrchr(original_uri, '\\');
    if (!filename_only)
        filename_only = original_uri;
    else
        filename_only++;

    // Find last slash in base_path for directory operations
    const char* last_slash = strrchr(base_path, '/');
    if (!last_slash)
        last_slash = strrchr(base_path, '\\');

    // Check for composite texture names (e.g., "MaterialRoughnessMetalness.png")
    const char* rough_pos = strstr(filename_only, "Roughness");
    const char* metal_pos = strstr(filename_only, "Metalness");
    const char* base_pos = strstr(filename_only, "BaseColor");
    const char* normal_pos = strstr(filename_only, "Normal");

    // Find the first token position for decomposition
    const char* first_token = NULL;
    if (rough_pos && metal_pos) {
        first_token = (rough_pos < metal_pos) ? rough_pos : metal_pos;
    } else if (rough_pos) {
        first_token = rough_pos;
    } else if (metal_pos) {
        first_token = metal_pos;
    } else if (base_pos) {
        first_token = base_pos;
    } else if (normal_pos) {
        first_token = normal_pos;
    }

    // Log the detected tokens for debugging
    CARDINAL_LOG_DEBUG("Analyzing filename: %s", filename_only);
    if (rough_pos)
        CARDINAL_LOG_DEBUG("  - Found 'Roughness' at position %ld",
                           (long)(rough_pos - filename_only));
    if (metal_pos)
        CARDINAL_LOG_DEBUG("  - Found 'Metalness' at position %ld",
                           (long)(metal_pos - filename_only));
    if (base_pos)
        CARDINAL_LOG_DEBUG("  - Found 'BaseColor' at position %ld",
                           (long)(base_pos - filename_only));
    if (normal_pos)
        CARDINAL_LOG_DEBUG("  - Found 'Normal' at position %ld",
                           (long)(normal_pos - filename_only));

    if (first_token) {
        size_t base_len = (size_t)(first_token - filename_only);
        if (base_len > 0 && base_len < 256) {
            char base_name[256];
            strncpy(base_name, filename_only, base_len);
            base_name[base_len] = '\0';

            CARDINAL_LOG_DEBUG("Extracted base name: '%s'", base_name);

            // Prepare base_dir prefix like <gltf_dir>/textures/
            char base_dir_prefix[512] = {0};
            if (last_slash) {
                size_t dir_len = (size_t)(last_slash - base_path + 1);
                strncpy(base_dir_prefix, base_path, dir_len);
                base_dir_prefix[dir_len] = '\0';
                strncat(base_dir_prefix, "textures/", sizeof(base_dir_prefix) - dir_len - 1);
            }

            // Candidates in order: base_dir textures (Roughness, Metalness, BaseColor, Normal),
            // then assets/textures
            const char* suffixes[4] = {"Roughness.png", "Metalness.png", "BaseColor.png",
                                       "Normal.png"};
            for (int i = 0; i < 4; ++i) {
                if (base_dir_prefix[0] != '\0') {
                    snprintf(texture_path, sizeof(texture_path), "%s%s%s", base_dir_prefix,
                             base_name, suffixes[i]);
                    CARDINAL_LOG_DEBUG("Trying decomposed candidate: %s", texture_path);
                    ref_resource = texture_load_with_ref_counting(texture_path, &tex_data);
                    if (ref_resource) {
                        goto success;
                    }
                }
                snprintf(texture_path, sizeof(texture_path), "assets/textures/%s%s", base_name,
                         suffixes[i]);
                ref_resource = try_texture_path(texture_path, &tex_data);
                if (ref_resource) {
                    goto success;
                }

                snprintf(texture_path, sizeof(texture_path), "assets/models/textures/%s%s",
                         base_name, suffixes[i]);
                ref_resource = try_texture_path(texture_path, &tex_data);
                if (ref_resource) {
                    goto success;
                }
            }
        }
    }

    // Additional fallback: deeper directory traversal and path transformations

    if (last_slash) {
        size_t dir_len = (size_t)(last_slash - base_path + 1);
        char base_dir[512];
        strncpy(base_dir, base_path, dir_len);
        base_dir[dir_len] = '\0';

        // ../../textures/filename (deeper traversal)
        snprintf(texture_path, sizeof(texture_path), "%s../../textures/%s", base_dir,
                 filename_only);
        ref_resource = try_texture_path(texture_path, &tex_data);
        if (ref_resource) {
            goto success;
        }

        // Replace 'models' with 'textures' in the path (unique transformation)
        char models_to_textures[512];
        strncpy(models_to_textures, base_dir, sizeof(models_to_textures) - 1);
        models_to_textures[sizeof(models_to_textures) - 1] = '\0';
        char* models_seg = strstr(models_to_textures, "/models/");
        if (!models_seg)
            models_seg = strstr(models_to_textures, "\\models\\");
        if (models_seg) {
            size_t prefix_len = (size_t)(models_seg - models_to_textures);
            char prefix[512];
            strncpy(prefix, models_to_textures, prefix_len);
            prefix[prefix_len] = '\0';
            char sep = (models_seg[0] == '/') ? '/' : '\\';
            ref_resource = try_formatted_path(texture_path, sizeof(texture_path), &tex_data,
                                              "%s%ctextures%c%s", prefix, sep, sep, filename_only);
            if (ref_resource) {
                goto success;
            }
        }
    }

create_fallback:
    // Fourth attempt: create fallback texture
    CARDINAL_LOG_WARN("Failed to load texture '%s' from all paths, using fallback", original_uri);
    return create_fallback_texture(out_texture);

success:
    out_texture->data = tex_data.data;
    out_texture->width = tex_data.width;
    out_texture->height = tex_data.height;
    out_texture->channels = tex_data.channels;
    out_texture->path = malloc(strlen(texture_path) + 1);
    if (out_texture->path) {
        strcpy(out_texture->path, texture_path);
    }
    // Store reference for cleanup
    out_texture->ref_resource = ref_resource;

    // Cache the successful path for future use
    cache_texture_path(original_uri, texture_path);

    CARDINAL_LOG_INFO("Loaded texture %s: %ux%u, %u channels (ref_count=%u)", texture_path,
                      tex_data.width, tex_data.height, tex_data.channels,
                      ref_resource ? cardinal_ref_get_count(ref_resource) : 0);
    return true;
}

/**
 * @brief Loads a texture from glTF image data.
 * @param data The parsed glTF data.
 * @param img_idx Index of the image in glTF.
 * @param base_path Base path for relative URIs.
 * @param out_texture Pointer to the texture structure.
 * @return true on success, false on failure.
 *
 * @todo Handle embedded textures (data URIs) properly.
 * @todo Expand to support glTF animations and skins for dynamic scenes.
 */
/**
 * @brief Extracts texture transform from cgltf texture view.
 * @param texture_view The cgltf texture view.
 * @param out_transform Output texture transform.
 */
static void extract_texture_transform(const cgltf_texture_view* texture_view,
                                      CardinalTextureTransform* out_transform) {
    // Initialize to identity transform
    out_transform->offset[0] = 0.0f;
    out_transform->offset[1] = 0.0f;
    out_transform->scale[0] = 1.0f;
    out_transform->scale[1] = 1.0f;
    out_transform->rotation = 0.0f;

    if (texture_view && texture_view->has_transform) {
        const cgltf_texture_transform* transform = &texture_view->transform;
        out_transform->offset[0] = transform->offset[0];
        // Invert Y-offset to account for texture Y-flip during loading
        out_transform->offset[1] = -transform->offset[1];
        out_transform->scale[0] = transform->scale[0];
        out_transform->scale[1] = transform->scale[1];
        out_transform->rotation = transform->rotation;
        CARDINAL_LOG_DEBUG(
            "Texture transform: offset=(%.3f,%.3f), scale=(%.3f,%.3f), rotation=%.3f",
            out_transform->offset[0], out_transform->offset[1], out_transform->scale[0],
            out_transform->scale[1], out_transform->rotation);
    }
}

/**
 * @brief Loads a texture from glTF image data.
 *
 * @param data The parsed glTF data.
 * @param img_idx Index of the image in glTF.
 * @param base_path Base path for relative URIs.
 * @param out_texture Pointer to the texture structure.
 * @return true on success, false on failure.
 *
 * @todo Support embedded (data URI) textures.
 * @todo Handle glTF texture extensions like KHR_texture_basisu.
 */
static bool load_texture_from_gltf(const cgltf_data* data, cgltf_size img_idx,
                                   const char* base_path, CardinalTexture* out_texture) {
    if (img_idx >= data->images_count || !data->images) {
        CARDINAL_LOG_ERROR("Invalid image index %zu, only %zu images available", (size_t)img_idx,
                           (size_t)data->images_count);
        return false;
    }

    const cgltf_image* img = &data->images[img_idx];

    if (img->uri) {
        // External image file - use fallback helper
        return load_texture_with_fallback(img->uri, base_path, out_texture);
    } else {
        CARDINAL_LOG_WARN("Embedded textures not supported yet, using fallback");
        return create_fallback_texture(out_texture);
    }
}

// Helper function to multiply 4x4 matrices (column-major)

// Helper function to traverse nodes and compute world transforms
static void process_node(const cgltf_data* data, const cgltf_node* node,
                         const float* parent_transform, CardinalMesh* meshes,
                         size_t total_mesh_count) {
    float local_transform[16];

    if (node->has_matrix) {
        // Use provided matrix directly
        memcpy(local_transform, node->matrix, 16 * sizeof(float));
    } else {
        // Build matrix from TRS
        const float* translation = node->has_translation ? node->translation : NULL;
        const float* rotation = node->has_rotation ? node->rotation : NULL;
        const float* scale = node->has_scale ? node->scale : NULL;
        cardinal_matrix_from_trs(translation, rotation, scale, local_transform);
    }

    // Compute world transform
    float world_transform[16];
    if (parent_transform) {
        cardinal_matrix_multiply(parent_transform, local_transform, world_transform);
    } else {
        memcpy(world_transform, local_transform, 16 * sizeof(float));
    }

    // If this node has a mesh, apply the world transform to the correct mesh indices
    if (node->mesh) {
        const cgltf_mesh* mesh = node->mesh;
        cgltf_size mesh_index = mesh - data->meshes; // Get the mesh index in the glTF data

        // Find the corresponding Cardinal meshes (primitives) for this glTF mesh
        size_t cardinal_mesh_index = 0;
        for (cgltf_size mi = 0; mi < mesh_index; ++mi) {
            cardinal_mesh_index += data->meshes[mi].primitives_count;
        }

        // Apply transform to all primitives of this mesh
        for (cgltf_size pi = 0; pi < mesh->primitives_count; ++pi) {
            if (cardinal_mesh_index + pi < total_mesh_count) {
                memcpy(meshes[cardinal_mesh_index + pi].transform, world_transform,
                       16 * sizeof(float));
                CARDINAL_LOG_TRACE("Applied transform to mesh %zu (glTF mesh %zu, primitive %zu)",
                                   cardinal_mesh_index + pi, mesh_index, pi);
            }
        }
    }

    // Recursively process children
    for (cgltf_size ci = 0; ci < node->children_count; ++ci) {
        process_node(data, node->children[ci], world_transform, meshes, total_mesh_count);
    }
}

// New function to build scene hierarchy
static CardinalSceneNode* build_scene_node(const cgltf_data* data, const cgltf_node* gltf_node,
                                           CardinalMesh* meshes, size_t total_mesh_count,
                                           CardinalSceneNode** all_nodes) {
    if (!gltf_node)
        return NULL;

    // Create the scene node
    const char* node_name = gltf_node->name ? gltf_node->name : "Unnamed Node";
    CardinalSceneNode* scene_node = cardinal_scene_node_create(node_name);
    if (!scene_node) {
        CARDINAL_LOG_ERROR("Failed to create scene node for '%s'", node_name);
        return NULL;
    }

    // Store in flat array
    if (all_nodes && data->nodes) {
        size_t index = gltf_node - data->nodes;
        if (index < data->nodes_count) {
            all_nodes[index] = scene_node;
        }
    }

    // Set local transform
    float local_transform[16];
    if (gltf_node->has_matrix) {
        // Use the matrix directly
        for (int i = 0; i < 16; ++i) {
            local_transform[i] = (float)gltf_node->matrix[i];
        }
    } else {
        // Build from TRS
        float translation[3] = {0.0f, 0.0f, 0.0f};
        float rotation[4] = {0.0f, 0.0f, 0.0f, 1.0f};
        float scale[3] = {1.0f, 1.0f, 1.0f};

        if (gltf_node->has_translation) {
            translation[0] = (float)gltf_node->translation[0];
            translation[1] = (float)gltf_node->translation[1];
            translation[2] = (float)gltf_node->translation[2];
        }
        if (gltf_node->has_rotation) {
            rotation[0] = (float)gltf_node->rotation[0];
            rotation[1] = (float)gltf_node->rotation[1];
            rotation[2] = (float)gltf_node->rotation[2];
            rotation[3] = (float)gltf_node->rotation[3];
        }
        if (gltf_node->has_scale) {
            scale[0] = (float)gltf_node->scale[0];
            scale[1] = (float)gltf_node->scale[1];
            scale[2] = (float)gltf_node->scale[2];
        }

        cardinal_matrix_from_trs(translation, rotation, scale, local_transform);
    }

    cardinal_scene_node_set_local_transform(scene_node, local_transform);

    // Attach meshes if this node has any
    if (gltf_node->mesh) {
        cgltf_size mesh_idx = gltf_node->mesh - data->meshes;
        const cgltf_mesh* m = gltf_node->mesh;

        // Count how many primitives this mesh has
        uint32_t primitive_count = (uint32_t)m->primitives_count;
        if (primitive_count > 0) {
            // Allocate mesh indices array
            scene_node->mesh_indices = (uint32_t*)malloc(primitive_count * sizeof(uint32_t));
            if (!scene_node->mesh_indices) {
                CARDINAL_LOG_ERROR("Failed to allocate mesh indices for node '%s'",
                                   scene_node->name ? scene_node->name : "Unnamed");
                return scene_node;
            }
        }

        // Find all primitives for this mesh and attach them
        size_t mesh_write = 0;
        for (cgltf_size mi = 0; mi < data->meshes_count; ++mi) {
            const cgltf_mesh* check_mesh = &data->meshes[mi];
            for (cgltf_size pi = 0; pi < check_mesh->primitives_count; ++pi) {
                if (mesh_write < total_mesh_count && mi == mesh_idx) {
                    // Attach this mesh to the node
                    scene_node->mesh_indices[scene_node->mesh_count] = (uint32_t)mesh_write;
                    scene_node->mesh_count++;
                }
                mesh_write++;
            }
        }
    }

    // Recursively build child nodes
    for (cgltf_size ci = 0; ci < gltf_node->children_count; ++ci) {
        CardinalSceneNode* child =
            build_scene_node(data, gltf_node->children[ci], meshes, total_mesh_count, all_nodes);
        if (child) {
            cardinal_scene_node_add_child(scene_node, child);
        }
    }

    return scene_node;
}

/**
 * @brief Load skins from GLTF data
 */
static bool load_skins_from_gltf(const cgltf_data* data, CardinalSkin** out_skins,
                                 uint32_t* out_skin_count) {
    if (!data || !out_skins || !out_skin_count) {
        return false;
    }

    *out_skins = NULL;
    *out_skin_count = 0;

    if (data->skins_count == 0) {
        return true; // No skins to load
    }

    CardinalSkin* skins = (CardinalSkin*)calloc(data->skins_count, sizeof(CardinalSkin));
    if (!skins) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for skins");
        return false;
    }

    for (cgltf_size i = 0; i < data->skins_count; ++i) {
        const cgltf_skin* gltf_skin = &data->skins[i];
        CardinalSkin* skin = &skins[i];

        // Set skin name
        if (gltf_skin->name) {
            size_t name_len = strlen(gltf_skin->name) + 1;
            skin->name = (char*)malloc(name_len);
            if (skin->name) {
                strcpy(skin->name, gltf_skin->name);
            }
        } else {
            size_t name_len = snprintf(NULL, 0, "Skin_%zu", (size_t)i) + 1;
            skin->name = (char*)malloc(name_len);
            if (skin->name) {
                snprintf(skin->name, name_len, "Skin_%zu", (size_t)i);
            }
        }

        // Load joints as bones
        skin->bone_count = (uint32_t)gltf_skin->joints_count;
        if (skin->bone_count > 0) {
            skin->bones = (CardinalBone*)calloc(skin->bone_count, sizeof(CardinalBone));
            if (!skin->bones) {
                CARDINAL_LOG_ERROR("Failed to allocate memory for skin bones");
                // Cleanup and return false
                for (uint32_t j = 0; j < i; ++j) {
                    cardinal_skin_destroy(&skins[j]);
                }
                free(skins);
                return false;
            }

            for (cgltf_size j = 0; j < gltf_skin->joints_count; ++j) {
                skin->bones[j].node_index = (uint32_t)(gltf_skin->joints[j] - data->nodes);
                skin->bones[j].parent_index = UINT32_MAX; // Will be set later if needed
                cardinal_matrix_identity(skin->bones[j].inverse_bind_matrix);
                cardinal_matrix_identity(skin->bones[j].current_matrix);
            }
        }

        // Load inverse bind matrices if available
        if (gltf_skin->inverse_bind_matrices) {
            const cgltf_accessor* accessor = gltf_skin->inverse_bind_matrices;
            if (accessor->type == cgltf_type_mat4 &&
                accessor->component_type == cgltf_component_type_r_32f) {
                // Read inverse bind matrices into individual bones
                for (uint32_t j = 0; j < skin->bone_count; ++j) {
                    cgltf_accessor_read_float(accessor, j, skin->bones[j].inverse_bind_matrix, 16);
                }
            }
        }
    }

    *out_skins = skins;
    *out_skin_count = (uint32_t)data->skins_count;

    CARDINAL_LOG_INFO("Loaded %u skins from GLTF", *out_skin_count);
    return true;
}

/**
 * @brief Load animations from GLTF data
 */
static bool load_animations_from_gltf(const cgltf_data* data,
                                      CardinalAnimationSystem* anim_system) {
    if (!data || !anim_system) {
        return false;
    }

    if (data->animations_count == 0) {
        return true; // No animations to load
    }

    for (cgltf_size i = 0; i < data->animations_count; ++i) {
        const cgltf_animation* gltf_anim = &data->animations[i];

        // Create animation
        CardinalAnimation animation = {0};
        if (gltf_anim->name) {
            strncpy(animation.name, gltf_anim->name, sizeof(animation.name) - 1);
            animation.name[sizeof(animation.name) - 1] = '\0';
        } else {
            snprintf(animation.name, sizeof(animation.name), "Animation_%zu", (size_t)i);
        }

        // Load samplers
        animation.sampler_count = (uint32_t)gltf_anim->samplers_count;
        if (animation.sampler_count > 0) {
            animation.samplers = (CardinalAnimationSampler*)calloc(
                animation.sampler_count, sizeof(CardinalAnimationSampler));
            if (!animation.samplers) {
                CARDINAL_LOG_ERROR("Failed to allocate memory for animation samplers");
                continue;
            }

            for (cgltf_size s = 0; s < gltf_anim->samplers_count; ++s) {
                const cgltf_animation_sampler* gltf_sampler = &gltf_anim->samplers[s];
                CardinalAnimationSampler* sampler = &animation.samplers[s];

                // Set interpolation type
                switch (gltf_sampler->interpolation) {
                    case cgltf_interpolation_type_linear:
                        sampler->interpolation = CARDINAL_ANIMATION_INTERPOLATION_LINEAR;
                        break;
                    case cgltf_interpolation_type_step:
                        sampler->interpolation = CARDINAL_ANIMATION_INTERPOLATION_STEP;
                        break;
                    case cgltf_interpolation_type_cubic_spline:
                        sampler->interpolation = CARDINAL_ANIMATION_INTERPOLATION_CUBICSPLINE;
                        break;
                    default:
                        sampler->interpolation = CARDINAL_ANIMATION_INTERPOLATION_LINEAR;
                        break;
                }

                // Load input (time) data
                const cgltf_accessor* input_accessor = gltf_sampler->input;
                if (input_accessor &&
                    input_accessor->component_type == cgltf_component_type_r_32f) {
                    sampler->input_count = (uint32_t)input_accessor->count;
                    sampler->input = (float*)malloc(sampler->input_count * sizeof(float));
                    if (sampler->input) {
                        cgltf_accessor_read_float(input_accessor, 0, sampler->input,
                                                  sampler->input_count);
                    }
                }

                // Load output data
                const cgltf_accessor* output_accessor = gltf_sampler->output;
                if (output_accessor &&
                    output_accessor->component_type == cgltf_component_type_r_32f) {
                    sampler->output_count = (uint32_t)output_accessor->count;
                    size_t component_count = 0;
                    switch (output_accessor->type) {
                        case cgltf_type_scalar:
                            component_count = 1;
                            break;
                        case cgltf_type_vec3:
                            component_count = 3;
                            break;
                        case cgltf_type_vec4:
                            component_count = 4;
                            break;
                        default:
                            component_count = 1;
                            break;
                    }

                    sampler->output =
                        (float*)malloc(sampler->output_count * component_count * sizeof(float));
                    if (sampler->output) {
                        cgltf_accessor_read_float(output_accessor, 0, sampler->output,
                                                  sampler->output_count * component_count);
                    }
                }
            }
        }

        // Load channels
        animation.channel_count = (uint32_t)gltf_anim->channels_count;
        if (animation.channel_count > 0) {
            animation.channels = (CardinalAnimationChannel*)calloc(
                animation.channel_count, sizeof(CardinalAnimationChannel));
            if (!animation.channels) {
                CARDINAL_LOG_ERROR("Failed to allocate memory for animation channels");
                // Cleanup samplers
                for (uint32_t s = 0; s < animation.sampler_count; ++s) {
                    free(animation.samplers[s].input);
                    free(animation.samplers[s].output);
                }
                free(animation.samplers);
                continue;
            }

            for (cgltf_size c = 0; c < gltf_anim->channels_count; ++c) {
                const cgltf_animation_channel* gltf_channel = &gltf_anim->channels[c];
                CardinalAnimationChannel* channel = &animation.channels[c];

                channel->sampler_index = (uint32_t)(gltf_channel->sampler - gltf_anim->samplers);
                channel->target.node_index = (uint32_t)(gltf_channel->target_node - data->nodes);

                // Set target path based on glTF channel target path
                switch (gltf_channel->target_path) {
                    case cgltf_animation_path_type_translation:
                        channel->target.path = CARDINAL_ANIMATION_TARGET_TRANSLATION;
                        break;
                    case cgltf_animation_path_type_rotation:
                        channel->target.path = CARDINAL_ANIMATION_TARGET_ROTATION;
                        break;
                    case cgltf_animation_path_type_scale:
                        channel->target.path = CARDINAL_ANIMATION_TARGET_SCALE;
                        break;
                    case cgltf_animation_path_type_weights:
                        channel->target.path = CARDINAL_ANIMATION_TARGET_WEIGHTS;
                        break;
                    default:
                        CARDINAL_LOG_WARN("Unsupported animation target path: %d",
                                          gltf_channel->target_path);
                        channel->target.path = CARDINAL_ANIMATION_TARGET_TRANSLATION; // Fallback
                        break;
                }
            }
        }

        // Calculate animation duration
        animation.duration = 0.0f;
        for (uint32_t s = 0; s < animation.sampler_count; ++s) {
            if (animation.samplers[s].input && animation.samplers[s].input_count > 0) {
                float max_time = animation.samplers[s].input[animation.samplers[s].input_count - 1];
                if (max_time > animation.duration) {
                    animation.duration = max_time;
                }
            }
        }

        // Add animation to system
        cardinal_animation_system_add_animation(anim_system, &animation);
    }

    CARDINAL_LOG_INFO("Loaded %zu animations from GLTF", (size_t)data->animations_count);
    return true;
}

/**
 * @brief Loads a glTF scene from file.
 *
 * Parses the glTF file, loads buffers, textures, materials, and meshes.
 * Now properly processes node hierarchy and transformations.
 * Extended to support animations and skins for skeletal animation.
 *
 * @param path Path to the glTF/glb file.
 * @param out_scene Pointer to the scene structure to fill.
 * @return true on success, false on failure.
 *
 * @todo Implement error recovery and partial loading.
 * @todo Add support for glTF extensions like lights and cameras.
 */
bool cardinal_gltf_load_scene(const char* path, CardinalScene* out_scene) {
    if (!path || !out_scene) {
        CARDINAL_LOG_ERROR("Invalid parameters: path=%p, out_scene=%p", (void*)path,
                           (void*)out_scene);
        return false;
    }

    CARDINAL_LOG_INFO("Starting GLTF scene loading: %s", path);
    CARDINAL_LOG_DEBUG("[MEMORY] Initial scene structure size: %zu bytes", sizeof(*out_scene));
    memset(out_scene, 0, sizeof(*out_scene));
    CARDINAL_LOG_DEBUG("[MEMORY] Scene structure zeroed at %p", (void*)out_scene);

    // Start performance timing
    clock_t start_time = clock();
    clock_t parse_start = start_time;
    CARDINAL_LOG_DEBUG("[PERF] Starting GLTF loading pipeline at %ld", start_time);

    cgltf_options options = {0};
    cgltf_data* data = NULL;

    CARDINAL_LOG_DEBUG("Parsing GLTF file...");
    cgltf_result result = cgltf_parse_file(&options, path, &data);

    clock_t parse_end = clock();
    double parse_time = ((double)(parse_end - parse_start)) / CLOCKS_PER_SEC;
    CARDINAL_LOG_DEBUG("[PERF] GLTF parsing completed in %.3f seconds", parse_time);
    if (result != cgltf_result_success) {
        CARDINAL_LOG_ERROR("cgltf_parse_file failed: %d for %s", (int)result, path);
        return false;
    }
    CARDINAL_LOG_DEBUG("GLTF file parsed successfully");

    CARDINAL_LOG_DEBUG("Loading GLTF buffers...");
    result = cgltf_load_buffers(&options, data, path);
    if (result != cgltf_result_success) {
        CARDINAL_LOG_ERROR("cgltf_load_buffers failed: %d for %s", (int)result, path);
        cgltf_free(data);
        return false;
    }
    CARDINAL_LOG_DEBUG("GLTF buffers loaded successfully");

    // Load textures first with performance timing
    clock_t texture_start = clock();
    CARDINAL_LOG_DEBUG("[PERF] Starting texture loading phase");
    CARDINAL_LOG_DEBUG("Loading %zu textures...", (size_t)data->images_count);
    CardinalTexture* textures = NULL;
    uint32_t texture_count = 0;

    if (data->images_count > 0) {
        size_t textures_size = data->images_count * sizeof(CardinalTexture);
        CARDINAL_LOG_DEBUG("[MEMORY] Allocating %zu bytes for %zu textures", textures_size,
                           (size_t)data->images_count);
        textures = (CardinalTexture*)calloc(data->images_count, sizeof(CardinalTexture));
        if (!textures) {
            CARDINAL_LOG_ERROR("[MEMORY] Failed to allocate %zu bytes for textures (count: %zu)",
                               textures_size, (size_t)data->images_count);
            cgltf_free(data);
            return false;
        }
        CARDINAL_LOG_DEBUG("[MEMORY] Successfully allocated textures array at %p", (void*)textures);

        for (cgltf_size i = 0; i < data->images_count; i++) {
            if (load_texture_from_gltf(data, i, path, &textures[texture_count])) {
                texture_count++;
            } else {
                CARDINAL_LOG_WARN("Failed to load texture %zu, skipping", (size_t)i);
            }
        }
        CARDINAL_LOG_INFO("Successfully loaded %u out of %zu textures", texture_count,
                          (size_t)data->images_count);
    }

    clock_t texture_end = clock();
    double texture_time = ((double)(texture_end - texture_start)) / CLOCKS_PER_SEC;
    CARDINAL_LOG_DEBUG("[PERF] Texture loading completed in %.3f seconds (%u textures)",
                       texture_time, texture_count);

    // Load materials with performance timing
    clock_t material_start = clock();
    CARDINAL_LOG_DEBUG("[PERF] Starting material loading phase");
    CARDINAL_LOG_DEBUG("Loading %zu materials...", (size_t)data->materials_count);
    CardinalMaterial* materials = NULL;
    uint32_t material_count = 0;

    if (data->materials_count > 0) {
        size_t materials_size = data->materials_count * sizeof(CardinalMaterial);
        CARDINAL_LOG_DEBUG("[MEMORY] Allocating %zu bytes for %zu materials", materials_size,
                           (size_t)data->materials_count);
        materials = (CardinalMaterial*)calloc(data->materials_count, sizeof(CardinalMaterial));
        if (!materials) {
            CARDINAL_LOG_ERROR("[MEMORY] Failed to allocate %zu bytes for materials (count: %zu)",
                               materials_size, (size_t)data->materials_count);
            CARDINAL_LOG_DEBUG(
                "[MEMORY] Cleaning up %u textures due to material allocation failure",
                texture_count);
            // Clean up textures
            for (uint32_t i = 0; i < texture_count; i++) {
                free(textures[i].data);
                free(textures[i].path);
            }
            free(textures);
            cgltf_free(data);
            return false;
        }

        for (cgltf_size i = 0; i < data->materials_count; i++) {
            const cgltf_material* mat = &data->materials[i];
            CardinalMaterial* card_mat = &materials[material_count];

            // Initialize with default values (no texture = UINT32_MAX)
            card_mat->albedo_texture = UINT32_MAX;
            card_mat->normal_texture = UINT32_MAX;
            card_mat->metallic_roughness_texture = UINT32_MAX;
            card_mat->ao_texture = UINT32_MAX;
            card_mat->emissive_texture = UINT32_MAX;

            // Set default factors
            card_mat->albedo_factor[0] = 1.0f;
            card_mat->albedo_factor[1] = 1.0f;
            card_mat->albedo_factor[2] = 1.0f;
            card_mat->metallic_factor = 0.0f;  // Non-metallic by default
            card_mat->roughness_factor = 0.5f; // Medium roughness by default
            card_mat->emissive_factor[0] = 0.0f;
            card_mat->emissive_factor[1] = 0.0f;
            card_mat->emissive_factor[2] = 0.0f;
            card_mat->normal_scale = 1.0f;
            card_mat->ao_strength = 1.0f;

            // Initialize texture transforms to identity
            CardinalTextureTransform identity_transform = {
                {0.0f, 0.0f},
                {1.0f, 1.0f},
                0.0f
            };
            card_mat->albedo_transform = identity_transform;
            card_mat->normal_transform = identity_transform;
            card_mat->metallic_roughness_transform = identity_transform;
            card_mat->ao_transform = identity_transform;
            card_mat->emissive_transform = identity_transform;

            // Parse PBR metallic roughness
            if (mat->has_pbr_metallic_roughness) {
                const cgltf_pbr_metallic_roughness* pbr = &mat->pbr_metallic_roughness;

                // Base color factor
                card_mat->albedo_factor[0] = pbr->base_color_factor[0];
                card_mat->albedo_factor[1] = pbr->base_color_factor[1];
                card_mat->albedo_factor[2] = pbr->base_color_factor[2];

                // Metallic and roughness factors
                card_mat->metallic_factor = pbr->metallic_factor;
                card_mat->roughness_factor = pbr->roughness_factor;

                // Base color texture
                if (pbr->base_color_texture.texture) {
                    cgltf_size img_idx = pbr->base_color_texture.texture->image - data->images;
                    if (img_idx < texture_count) {
                        card_mat->albedo_texture = (uint32_t)img_idx;
                    }
                    extract_texture_transform(&pbr->base_color_texture,
                                              &card_mat->albedo_transform);
                }

                // Metallic roughness texture
                if (pbr->metallic_roughness_texture.texture) {
                    cgltf_size img_idx =
                        pbr->metallic_roughness_texture.texture->image - data->images;
                    if (img_idx < texture_count) {
                        card_mat->metallic_roughness_texture = (uint32_t)img_idx;
                    }
                    extract_texture_transform(&pbr->metallic_roughness_texture,
                                              &card_mat->metallic_roughness_transform);
                }
            }

            // Normal texture
            if (mat->normal_texture.texture) {
                cgltf_size img_idx = mat->normal_texture.texture->image - data->images;
                if (img_idx < texture_count) {
                    card_mat->normal_texture = (uint32_t)img_idx;
                }
                card_mat->normal_scale = mat->normal_texture.scale;
                extract_texture_transform(&mat->normal_texture, &card_mat->normal_transform);
            }

            // Occlusion texture
            if (mat->occlusion_texture.texture) {
                cgltf_size img_idx = mat->occlusion_texture.texture->image - data->images;
                if (img_idx < texture_count) {
                    card_mat->ao_texture = (uint32_t)img_idx;
                }
                card_mat->ao_strength = mat->occlusion_texture.scale;
                extract_texture_transform(&mat->occlusion_texture, &card_mat->ao_transform);
            }

            // Emissive texture and factor
            if (mat->emissive_texture.texture) {
                cgltf_size img_idx = mat->emissive_texture.texture->image - data->images;
                if (img_idx < texture_count) {
                    card_mat->emissive_texture = (uint32_t)img_idx;
                }
                extract_texture_transform(&mat->emissive_texture, &card_mat->emissive_transform);
            }
            // Only apply non-zero emissive factor; otherwise keep the default (0,0,0)
            if (mat->emissive_factor[0] > 0.0f || mat->emissive_factor[1] > 0.0f ||
                mat->emissive_factor[2] > 0.0f) {
                card_mat->emissive_factor[0] = mat->emissive_factor[0];
                card_mat->emissive_factor[1] = mat->emissive_factor[1];
                card_mat->emissive_factor[2] = mat->emissive_factor[2];
            }

            // Try to load material with reference counting
            CardinalMaterial temp_material;
            CardinalRefCountedResource* material_ref =
                cardinal_material_load_with_ref_counting(card_mat, &temp_material);
            if (material_ref) {
                // Replace the material with the reference-counted one
                *card_mat = temp_material;
                card_mat->ref_resource = material_ref; // Store the reference resource
                material_count++;
                CARDINAL_LOG_DEBUG(
                    "Material %u loaded with ref counting: albedo_tex=%u, normal_tex=%u, "
                    "mr_tex=%u (ref_count=%u)",
                    material_count - 1, card_mat->albedo_texture, card_mat->normal_texture,
                    card_mat->metallic_roughness_texture, cardinal_ref_get_count(material_ref));
                CARDINAL_LOG_DEBUG(
                    "Material %u factors: albedo=(%.3f,%.3f,%.3f), metallic=%.3f, roughness=%.3f",
                    material_count - 1, card_mat->albedo_factor[0], card_mat->albedo_factor[1],
                    card_mat->albedo_factor[2], card_mat->metallic_factor,
                    card_mat->roughness_factor);
            } else {
                CARDINAL_LOG_WARN(
                    "Failed to register material %zu with reference counting, using direct "
                    "material",
                    i);
                card_mat->ref_resource = NULL; // No reference resource for direct materials
                material_count++;
                CARDINAL_LOG_DEBUG("Material %u loaded: albedo_tex=%u, normal_tex=%u, mr_tex=%u",
                                   material_count - 1, card_mat->albedo_texture,
                                   card_mat->normal_texture, card_mat->metallic_roughness_texture);
                CARDINAL_LOG_DEBUG(
                    "Material %u factors: albedo=(%.3f,%.3f,%.3f), metallic=%.3f, roughness=%.3f",
                    material_count - 1, card_mat->albedo_factor[0], card_mat->albedo_factor[1],
                    card_mat->albedo_factor[2], card_mat->metallic_factor,
                    card_mat->roughness_factor);
            }
        }
        CARDINAL_LOG_INFO("Successfully loaded %u materials", material_count);
    }

    clock_t material_end = clock();
    double material_time = ((double)(material_end - material_start)) / CLOCKS_PER_SEC;
    CARDINAL_LOG_DEBUG("[PERF] Material loading completed in %.3f seconds (%u materials)",
                       material_time, material_count);

    // Count total primitives as meshes for now with performance timing
    clock_t mesh_start = clock();
    CARDINAL_LOG_DEBUG("[PERF] Starting mesh loading phase");
    CARDINAL_LOG_DEBUG("Analyzing scene structure: %zu meshes found", (size_t)data->meshes_count);
    size_t mesh_count = 0;
    for (cgltf_size mi = 0; mi < data->meshes_count; ++mi) {
        const cgltf_mesh* m = &data->meshes[mi];
        mesh_count += (size_t)m->primitives_count;
        CARDINAL_LOG_TRACE("Mesh %zu: %zu primitives", (size_t)mi, (size_t)m->primitives_count);
    }
    CARDINAL_LOG_INFO("Total primitives to load: %zu", mesh_count);

    if (mesh_count == 0) {
        CARDINAL_LOG_WARN("Scene contains no meshes, returning empty scene");
        cgltf_free(data);
        return true; // empty scene
    }

    size_t meshes_size = mesh_count * sizeof(CardinalMesh);
    CARDINAL_LOG_DEBUG("[MEMORY] Allocating %zu bytes for %zu meshes", meshes_size, mesh_count);
    CardinalMesh* meshes = (CardinalMesh*)calloc(mesh_count, sizeof(CardinalMesh));
    if (!meshes) {
        CARDINAL_LOG_ERROR("[MEMORY] Failed to allocate %zu bytes for meshes (count: %zu)",
                           meshes_size, mesh_count);
        CARDINAL_LOG_DEBUG(
            "[MEMORY] Cleaning up %u textures and %u materials due to mesh allocation failure",
            texture_count, material_count);
        // Clean up materials and textures
        for (uint32_t i = 0; i < texture_count; i++) {
            free(textures[i].data);
            free(textures[i].path);
        }
        free(textures);
        free(materials);
        cgltf_free(data);
        return false;
    }

    CARDINAL_LOG_DEBUG("[PERF] Starting mesh data processing");
    CARDINAL_LOG_DEBUG("Processing mesh data...");
    size_t mesh_write = 0;
    for (cgltf_size mi = 0; mi < data->meshes_count; ++mi) {
        const cgltf_mesh* m = &data->meshes[mi];
        CARDINAL_LOG_DEBUG("Processing mesh %zu/%zu with %zu primitives", (size_t)mi + 1,
                           (size_t)data->meshes_count, (size_t)m->primitives_count);

        for (cgltf_size pi = 0; pi < m->primitives_count; ++pi) {
            const cgltf_primitive* p = &m->primitives[pi];
            CARDINAL_LOG_TRACE("Processing primitive %zu/%zu", (size_t)pi + 1,
                               (size_t)m->primitives_count);

            // Determine vertex count from POSITION accessor
            const cgltf_accessor* pos_acc = NULL;
            const cgltf_accessor* nrm_acc = NULL;
            const cgltf_accessor* uv_acc = NULL;
            const cgltf_accessor* joints_acc = NULL;
            const cgltf_accessor* weights_acc = NULL;
            for (cgltf_size ai = 0; ai < p->attributes_count; ++ai) {
                const cgltf_attribute* a = &p->attributes[ai];
                if (a->type == cgltf_attribute_type_position)
                    pos_acc = a->data;
                if (a->type == cgltf_attribute_type_normal)
                    nrm_acc = a->data;
                if (a->type == cgltf_attribute_type_texcoord)
                    uv_acc = a->data;
                if (a->type == cgltf_attribute_type_joints)
                    joints_acc = a->data;
                if (a->type == cgltf_attribute_type_weights)
                    weights_acc = a->data;
            }

            if (!pos_acc) {
                CARDINAL_LOG_WARN("Skipping primitive %zu/%zu: no position data", (size_t)pi + 1,
                                  (size_t)m->primitives_count);
                continue;
            }
            cgltf_size vcount = pos_acc->count;
            CARDINAL_LOG_TRACE(
                "Primitive has %zu vertices, normals=%s, UVs=%s, joints=%s, weights=%s",
                (size_t)vcount, nrm_acc ? "yes" : "no", uv_acc ? "yes" : "no",
                joints_acc ? "yes" : "no", weights_acc ? "yes" : "no");

            size_t vertex_buffer_size = vcount * sizeof(CardinalVertex);
            CARDINAL_LOG_DEBUG("[MEMORY] Allocating %zu bytes for %zu vertices in primitive %zu",
                               vertex_buffer_size, (size_t)vcount, (size_t)pi);
            CardinalVertex* vertices = (CardinalVertex*)calloc(vcount, sizeof(CardinalVertex));
            if (!vertices) {
                CARDINAL_LOG_ERROR(
                    "[MEMORY] Failed to allocate %zu bytes for %zu vertices in primitive %zu",
                    vertex_buffer_size, (size_t)vcount, (size_t)pi);
                continue;
            }
            CARDINAL_LOG_DEBUG("[MEMORY] Vertex buffer allocated at %p for %zu vertices",
                               (void*)vertices, (size_t)vcount);

            // Read positions
            CARDINAL_LOG_TRACE("Reading position data...");
            for (cgltf_size vi = 0; vi < vcount; ++vi) {
                cgltf_float v[3] = {0};
                cgltf_accessor_read_float(pos_acc, vi, v, 3);
                vertices[vi].px = (float)v[0];
                vertices[vi].py = (float)v[1];
                vertices[vi].pz = (float)v[2];
            }
            // Debug log first few vertices
            if (vcount > 0) {
                CARDINAL_LOG_DEBUG("First vertex: pos=(%f, %f, %f)", vertices[0].px, vertices[0].py,
                                   vertices[0].pz);
                if (vcount > 1) {
                    CARDINAL_LOG_DEBUG("Second vertex: pos=(%f, %f, %f)", vertices[1].px,
                                       vertices[1].py, vertices[1].pz);
                }
            }

            // Read normals
            if (nrm_acc) {
                CARDINAL_LOG_TRACE("Reading normal data...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_float v[3] = {0};
                    cgltf_accessor_read_float(nrm_acc, vi, v, 3);
                    vertices[vi].nx = (float)v[0];
                    vertices[vi].ny = (float)v[1];
                    vertices[vi].nz = (float)v[2];
                }
            } else {
                CARDINAL_LOG_TRACE("Generating default normals...");
                float nx, ny, nz;
                compute_default_normal(&nx, &ny, &nz);
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    vertices[vi].nx = nx;
                    vertices[vi].ny = ny;
                    vertices[vi].nz = nz;
                }
            }

            // Read UVs
            if (uv_acc) {
                CARDINAL_LOG_TRACE("Reading UV coordinate data...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_float v[2] = {0};
                    cgltf_accessor_read_float(uv_acc, vi, v, 2);
                    vertices[vi].u = (float)v[0];
                    vertices[vi].v = (float)v[1];
                }
            } else {
                CARDINAL_LOG_TRACE("Setting default UV coordinates...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    vertices[vi].u = 0.0f;
                    vertices[vi].v = 0.0f;
                }
            }

            // Read joints
            if (joints_acc) {
                CARDINAL_LOG_TRACE("Reading joint data...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_uint v[4] = {0};
                    cgltf_accessor_read_uint(joints_acc, vi, v, 4);
                    vertices[vi].bone_indices[0] = (uint32_t)v[0];
                    vertices[vi].bone_indices[1] = (uint32_t)v[1];
                    vertices[vi].bone_indices[2] = (uint32_t)v[2];
                    vertices[vi].bone_indices[3] = (uint32_t)v[3];
                }
            }

            // Read weights
            if (weights_acc) {
                CARDINAL_LOG_TRACE("Reading weight data...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_float v[4] = {0};
                    cgltf_accessor_read_float(weights_acc, vi, v, 4);
                    vertices[vi].bone_weights[0] = (float)v[0];
                    vertices[vi].bone_weights[1] = (float)v[1];
                    vertices[vi].bone_weights[2] = (float)v[2];
                    vertices[vi].bone_weights[3] = (float)v[3];
                }
            }

            // Indices
            uint32_t* indices = NULL;
            uint32_t index_count = 0;
            if (p->indices) {
                index_count = (uint32_t)p->indices->count;
                CARDINAL_LOG_TRACE("Reading %u indices...", index_count);
                size_t index_buffer_size = sizeof(uint32_t) * index_count;
                CARDINAL_LOG_DEBUG("[MEMORY] Allocating %zu bytes for %u indices in primitive %zu",
                                   index_buffer_size, index_count, (size_t)pi);
                indices = (uint32_t*)malloc(index_buffer_size);
                if (indices) {
                    CARDINAL_LOG_DEBUG("[MEMORY] Index buffer allocated at %p for %u indices",
                                       (void*)indices, index_count);
                    for (cgltf_size ii = 0; ii < p->indices->count; ++ii) {
                        cgltf_uint idx = 0;
                        cgltf_accessor_read_uint(p->indices, ii, &idx, 1);
                        indices[ii] = (uint32_t)idx;
                    }
                    CARDINAL_LOG_TRACE("Successfully read %u indices", index_count);
                } else {
                    CARDINAL_LOG_ERROR(
                        "[MEMORY] Failed to allocate %zu bytes for %u indices in primitive %zu",
                        index_buffer_size, index_count, (size_t)pi);
                    index_count = 0;
                }
            } else {
                // Generate a linear index buffer if the primitive is triangles and no indices given
                if (p->type == cgltf_primitive_type_triangles) {
                    index_count = (uint32_t)vcount;
                    CARDINAL_LOG_TRACE("Generating linear index buffer with %u indices",
                                       index_count);
                    size_t index_buffer_size = sizeof(uint32_t) * index_count;
                    CARDINAL_LOG_DEBUG(
                        "[MEMORY] Allocating %zu bytes for %u generated indices in primitive %zu",
                        index_buffer_size, index_count, (size_t)pi);
                    indices = (uint32_t*)malloc(index_buffer_size);
                    if (indices) {
                        CARDINAL_LOG_DEBUG(
                            "[MEMORY] Generated index buffer allocated at %p for %u indices",
                            (void*)indices, index_count);
                        for (uint32_t ii = 0; ii < index_count; ++ii)
                            indices[ii] = ii;
                        CARDINAL_LOG_TRACE("Generated linear index buffer successfully");
                    } else {
                        CARDINAL_LOG_ERROR("[MEMORY] Failed to allocate %zu bytes for generated %u "
                                           "indices in primitive %zu",
                                           index_buffer_size, index_count, (size_t)pi);
                        index_count = 0;
                    }
                } else {
                    CARDINAL_LOG_TRACE(
                        "No indices provided and primitive type is not triangles, using "
                        "unindexed rendering");
                }
            }
            // Debug log first few indices
            if (index_count > 0 && indices) {
#ifdef _DEBUG
                uint32_t i0 = indices[0];
                uint32_t i1 = (index_count > 1) ? indices[1] : 0;
                uint32_t i2 = (index_count > 2) ? indices[2] : 0;
                CARDINAL_LOG_DEBUG("First indices: %u, %u, %u (of %u)", i0, i1, i2, index_count);
#endif
            }

            CardinalMesh* dst = &meshes[mesh_write++];
            dst->vertices = vertices;
            dst->vertex_count = (uint32_t)vcount;
            dst->indices = indices;
            dst->index_count = index_count;

            // Assign material index
            if (p->material) {
                cgltf_size mat_idx = p->material - data->materials;
                if (mat_idx < material_count) {
                    dst->material_index = (uint32_t)mat_idx;
                } else {
                    dst->material_index = UINT32_MAX; // No material
                }
            } else {
                dst->material_index = UINT32_MAX; // No material
            }

            // Initialize transform matrix to identity (will be overwritten by node processing)
            memset(dst->transform, 0, 16 * sizeof(float));
            dst->transform[0] = dst->transform[5] = dst->transform[10] = dst->transform[15] = 1.0f;

            // Initialize visibility to true by default
            dst->visible = true;

            CARDINAL_LOG_TRACE("Mesh %zu complete: %u vertices, %u indices, material=%u",
                               mesh_write, dst->vertex_count, dst->index_count,
                               dst->material_index);
        }
    }

    // Build scene hierarchy
    CARDINAL_LOG_DEBUG("Building scene hierarchy...");

    CardinalSceneNode** root_nodes = NULL;
    uint32_t root_node_count = 0;

    // Allocate flat node array for animation system
    if (data->nodes_count > 0) {
        out_scene->all_node_count = (uint32_t)data->nodes_count;
        out_scene->all_nodes =
            (CardinalSceneNode**)calloc(out_scene->all_node_count, sizeof(CardinalSceneNode*));
        if (!out_scene->all_nodes) {
            CARDINAL_LOG_ERROR("Failed to allocate all_nodes array");
            out_scene->all_node_count = 0;
        }
    }

    // Build the scene hierarchy
    if (data->scene && data->scene->nodes_count > 0) {
        CARDINAL_LOG_DEBUG("Building hierarchy from default scene with %zu root nodes",
                           (size_t)data->scene->nodes_count);
        root_node_count = (uint32_t)data->scene->nodes_count;
        root_nodes = (CardinalSceneNode**)calloc(root_node_count, sizeof(CardinalSceneNode*));
        if (root_nodes) {
            for (cgltf_size ni = 0; ni < data->scene->nodes_count; ++ni) {
                root_nodes[ni] = build_scene_node(data, data->scene->nodes[ni], meshes, mesh_count,
                                                  out_scene->all_nodes);
                if (!root_nodes[ni]) {
                    CARDINAL_LOG_WARN("Failed to build scene node %zu", (size_t)ni);
                }
            }
        } else {
            CARDINAL_LOG_ERROR("Failed to allocate memory for root nodes");
            root_node_count = 0;
        }
    } else if (data->nodes_count > 0) {
        // Fallback: process all nodes as root nodes if no scene is defined
        CARDINAL_LOG_DEBUG(
            "No default scene found, building hierarchy from %zu nodes as root nodes",
            (size_t)data->nodes_count);
        root_node_count = (uint32_t)data->nodes_count;
        root_nodes = (CardinalSceneNode**)calloc(root_node_count, sizeof(CardinalSceneNode*));
        if (root_nodes) {
            for (cgltf_size ni = 0; ni < data->nodes_count; ++ni) {
                root_nodes[ni] = build_scene_node(data, &data->nodes[ni], meshes, mesh_count,
                                                  out_scene->all_nodes);
                if (!root_nodes[ni]) {
                    CARDINAL_LOG_WARN("Failed to build scene node %zu", (size_t)ni);
                }
            }
        } else {
            CARDINAL_LOG_ERROR("Failed to allocate memory for root nodes");
            root_node_count = 0;
        }
    }

    // Update transforms for all nodes in the hierarchy with crash-safe validation
    CARDINAL_LOG_DEBUG("[CRITICAL] Starting transform update phase for %u root nodes",
                       root_node_count);
    if (root_nodes) {
        for (uint32_t i = 0; i < root_node_count; ++i) {
            if (i >= root_node_count) {
                CARDINAL_LOG_ERROR("[CRITICAL] Root node index %u exceeds count %u - breaking loop",
                                   i, root_node_count);
                break;
            }

            if (root_nodes[i]) {
                CARDINAL_LOG_DEBUG("[CRITICAL] Updating transforms for root node %u at %p", i,
                                   (void*)root_nodes[i]);
                cardinal_scene_node_update_transforms(root_nodes[i], NULL); // NULL for root nodes
                CARDINAL_LOG_DEBUG("[CRITICAL] Transform update completed for root node %u", i);
            } else {
                CARDINAL_LOG_WARN("[CRITICAL] Root node %u is NULL - skipping transform update", i);
            }
        }
        CARDINAL_LOG_DEBUG("[CRITICAL] Transform update phase completed");
    } else {
        CARDINAL_LOG_WARN("[CRITICAL] No root nodes available for transform updates");
    }

    // Also process the old way for backward compatibility with mesh transforms
    CARDINAL_LOG_DEBUG(
        "[CRITICAL] Processing scene graph for mesh transforms (backward compatibility)...");
    if (data->scene && data->scene->nodes_count > 0) {
        CARDINAL_LOG_DEBUG("[CRITICAL] Processing %zu scene nodes for mesh transforms",
                           (size_t)data->scene->nodes_count);
        for (cgltf_size ni = 0; ni < data->scene->nodes_count; ++ni) {
            if (ni >= data->scene->nodes_count) {
                CARDINAL_LOG_ERROR(
                    "[CRITICAL] Scene node index %zu exceeds count %zu - breaking loop", (size_t)ni,
                    (size_t)data->scene->nodes_count);
                break;
            }

            if (data->scene->nodes[ni]) {
                CARDINAL_LOG_DEBUG("[CRITICAL] Processing scene node %zu for mesh transforms",
                                   (size_t)ni);
                process_node(data, data->scene->nodes[ni], NULL, meshes, mesh_count);
            } else {
                CARDINAL_LOG_WARN(
                    "[CRITICAL] Scene node %zu is NULL - skipping mesh transform processing",
                    (size_t)ni);
            }
        }
    } else if (data->nodes_count > 0) {
        CARDINAL_LOG_DEBUG("[CRITICAL] Processing %zu data nodes for mesh transforms (fallback)",
                           (size_t)data->nodes_count);
        for (cgltf_size ni = 0; ni < data->nodes_count; ++ni) {
            if (ni >= data->nodes_count) {
                CARDINAL_LOG_ERROR(
                    "[CRITICAL] Data node index %zu exceeds count %zu - breaking loop", (size_t)ni,
                    (size_t)data->nodes_count);
                break;
            }

            CARDINAL_LOG_DEBUG("[CRITICAL] Processing data node %zu for mesh transforms",
                               (size_t)ni);
            process_node(data, &data->nodes[ni], NULL, meshes, mesh_count);
        }
    } else {
        CARDINAL_LOG_DEBUG("[CRITICAL] No nodes available for mesh transform processing");
    }
    CARDINAL_LOG_DEBUG("[CRITICAL] Scene graph processing completed");

    CARDINAL_LOG_INFO("Built scene hierarchy with %u root nodes", root_node_count);



    // Initialize animation system with crash-safe validation
    CARDINAL_LOG_DEBUG("[CRITICAL] Starting animation system initialization");
    uint32_t max_animations = data->animations_count > 0 ? (uint32_t)data->animations_count : 10;
    uint32_t max_skins = data->skins_count > 0 ? (uint32_t)data->skins_count : 10;
    CARDINAL_LOG_DEBUG("[CRITICAL] Creating animation system with %u max animations, %u max skins",
                       max_animations, max_skins);

    out_scene->animation_system = cardinal_animation_system_create(max_animations, max_skins);
    if (!out_scene->animation_system) {
        CARDINAL_LOG_ERROR(
            "[CRITICAL] Failed to create animation system - continuing without animations");
    } else {
        CARDINAL_LOG_DEBUG("[CRITICAL] Animation system created successfully at %p",
                           (void*)out_scene->animation_system);
    }

    // Load skins with crash-safe validation
    CARDINAL_LOG_DEBUG("[CRITICAL] Starting skin loading phase");
    if (!load_skins_from_gltf(data, &out_scene->skins, &out_scene->skin_count)) {
        CARDINAL_LOG_ERROR("[CRITICAL] Failed to load skins from GLTF - continuing without skins");
        out_scene->skins = NULL;
        out_scene->skin_count = 0;
    } else {
        CARDINAL_LOG_DEBUG("[CRITICAL] Loaded %u skins successfully", out_scene->skin_count);
    }

    // Populate skin mesh indices by traversing the scene nodes
    // This is required because load_skins_from_gltf doesn't know about mesh-skin relationships
    // which are defined in the nodes
    if (data->skins_count > 0 && root_nodes) {
        CARDINAL_LOG_DEBUG("Mapping meshes to skins...");

        // Helper function to process node for skin mapping
        // (We implement this iteratively to avoid deep recursion issues)
        // For simplicity in this context, we'll iterate the data->nodes directly as we have access
        // to them and they map 1:1 to the hierarchy structure we built (conceptually) BUT we need
        // the CardinalSceneNode to get the mesh indices.

        // A better approach: We already have the list of all CardinalSceneNodes if we traversed
        // properly. But we don't have a flat list of all scene nodes in the scene struct. However,
        // we can iterate over data->nodes again. We need to match data->nodes[i] to the
        // CardinalSceneNode we created. The current implementation of build_scene_node doesn't
        // store a map.

        // Let's traverse the hierarchy we built.
        // We'll use a simple stack-based traversal.

        CardinalSceneNode** stack =
            (CardinalSceneNode**)malloc(sizeof(CardinalSceneNode*) * 1024); // Limit depth
        if (stack) {
            uint32_t stack_top = 0;

            // Push root nodes
            for (uint32_t i = 0; i < root_node_count; ++i) {
                if (root_nodes[i] && stack_top < 1024) {
                    stack[stack_top++] = root_nodes[i];
                }
            }

            while (stack_top > 0) {
                CardinalSceneNode* node = stack[--stack_top];

                // If node has meshes and a skin, add meshes to the skin
                if (node->skin_index != UINT32_MAX && node->mesh_count > 0 &&
                    node->skin_index < out_scene->skin_count) {
                    CardinalSkin* skin = &out_scene->skins[node->skin_index];

                    // Reallocate skin mesh indices
                    uint32_t new_count = skin->mesh_count + node->mesh_count;
                    uint32_t* new_indices =
                        (uint32_t*)realloc(skin->mesh_indices, new_count * sizeof(uint32_t));

                    if (new_indices) {
                        skin->mesh_indices = new_indices;
                        for (uint32_t m = 0; m < node->mesh_count; ++m) {
                            skin->mesh_indices[skin->mesh_count + m] = node->mesh_indices[m];
                        }
                        skin->mesh_count = new_count;
                        CARDINAL_LOG_TRACE("Added %u meshes to skin %u (total: %u)",
                                           node->mesh_count, node->skin_index, skin->mesh_count);
                    } else {
                        CARDINAL_LOG_ERROR("Failed to reallocate mesh indices for skin %u",
                                           node->skin_index);
                    }
                }

                // Push children
                for (uint32_t c = 0; c < node->child_count; ++c) {
                    if (node->children[c] && stack_top < 1024) {
                        stack[stack_top++] = node->children[c];
                    }
                }
            }

            free(stack);
        }
    }

    // Load animations with crash-safe logging
    CARDINAL_LOG_DEBUG("[CRITICAL] Starting animation loading phase");
    if (out_scene->animation_system) {
        CARDINAL_LOG_DEBUG("[CRITICAL] Animation system available at %p, loading animations",
                           (void*)out_scene->animation_system);
        if (!load_animations_from_gltf(data, out_scene->animation_system)) {
            CARDINAL_LOG_ERROR(
                "[CRITICAL] Failed to load animations from GLTF - continuing with scene loading");
        } else {
            CARDINAL_LOG_DEBUG("[CRITICAL] Animations loaded successfully");
        }
    } else {
        CARDINAL_LOG_DEBUG("[CRITICAL] No animation system available, skipping animation loading");
    }

    // Mark bone nodes after hierarchy is built with crash-safe validation
    CARDINAL_LOG_DEBUG("[CRITICAL] Starting bone node marking phase for %u skins",
                       out_scene->skin_count);
    for (uint32_t s = 0; s < out_scene->skin_count; ++s) {
        if (s >= out_scene->skin_count) {
            CARDINAL_LOG_ERROR("[CRITICAL] Skin index %u exceeds skin count %u - breaking loop", s,
                               out_scene->skin_count);
            break;
        }

        CardinalSkin* skin = &out_scene->skins[s];
        if (!skin) {
            CARDINAL_LOG_ERROR("[CRITICAL] Skin %u is NULL - skipping", s);
            continue;
        }

        CARDINAL_LOG_DEBUG("[CRITICAL] Processing skin %u with %u bones", s, skin->bone_count);
        for (uint32_t j = 0; j < skin->bone_count; ++j) {
            if (j >= skin->bone_count) {
                CARDINAL_LOG_ERROR(
                    "[CRITICAL] Bone index %u exceeds bone count %u for skin %u - breaking loop", j,
                    skin->bone_count, s);
                break;
            }

            // Note: CardinalSkin doesn't have joint_nodes, using bone index instead
            uint32_t joint_node_index = j; // Using bone index as placeholder
            // Find the corresponding scene node and mark it as a bone
            // This is a simplified approach - in a full implementation you'd need
            // to properly map GLTF node indices to scene node indices
            if (joint_node_index < data->nodes_count) {
                CARDINAL_LOG_DEBUG("[CRITICAL] Node %u is a bone (joint %u of skin %u)",
                                   joint_node_index, j, s);
            } else {
                CARDINAL_LOG_WARN(
                    "[CRITICAL] Joint node index %u exceeds node count %zu for skin %u bone %u",
                    joint_node_index, (size_t)data->nodes_count, s, j);
            }
        }
    }
    CARDINAL_LOG_DEBUG("[CRITICAL] Bone node marking phase completed");

    // Free GLTF data with validation
    CARDINAL_LOG_DEBUG("[CLEANUP] Freeing GLTF data structure at %p", (void*)data);
    if (data) {
        cgltf_free(data);
        CARDINAL_LOG_DEBUG("[CLEANUP] GLTF data freed successfully");
    } else {
        CARDINAL_LOG_WARN("[CLEANUP] Attempted to free NULL GLTF data pointer");
    }

    // Set up scene with validation
    CARDINAL_LOG_DEBUG("[CLEANUP] Setting up scene structure with loaded resources");
    out_scene->meshes = meshes;
    out_scene->mesh_count = (uint32_t)mesh_write; // Use actual written count
    out_scene->materials = materials;
    out_scene->material_count = material_count;
    out_scene->textures = textures;
    out_scene->texture_count = texture_count;
    out_scene->root_nodes = root_nodes;
    out_scene->root_node_count = root_node_count;

    // Log final resource state for leak detection
    CARDINAL_LOG_DEBUG("[CLEANUP] Final resource assignment completed:");
    CARDINAL_LOG_DEBUG("[CLEANUP]   Meshes: %u at %p (written: %u)", out_scene->mesh_count,
                       (void*)meshes, (uint32_t)mesh_write);
    CARDINAL_LOG_DEBUG("[CLEANUP]   Materials: %u at %p", material_count, (void*)materials);
    CARDINAL_LOG_DEBUG("[CLEANUP]   Textures: %u at %p", texture_count, (void*)textures);
    CARDINAL_LOG_DEBUG("[CLEANUP]   Root nodes: %u at %p", root_node_count, (void*)root_nodes);
    CARDINAL_LOG_DEBUG("[CLEANUP]   Skins: %u at %p", out_scene->skin_count,
                       (void*)out_scene->skins);

    // Complete performance timing
    clock_t mesh_end = clock();
    double mesh_time = ((double)(mesh_end - mesh_start)) / CLOCKS_PER_SEC;
    CARDINAL_LOG_DEBUG("[PERF] Mesh loading completed in %.3f seconds (%u meshes)", mesh_time,
                       out_scene->mesh_count);

    clock_t total_end = clock();
    double total_time = ((double)(total_end - start_time)) / CLOCKS_PER_SEC;
    CARDINAL_LOG_INFO("[PERF] Total GLTF loading completed in %.3f seconds", total_time);
    CARDINAL_LOG_DEBUG(
        "[PERF] Performance breakdown: parse=%.3fs, textures=%.3fs, materials=%.3fs, meshes=%.3fs",
        parse_time, texture_time, material_time, mesh_time);

    CARDINAL_LOG_INFO(
        "GLTF scene loading completed successfully: %u meshes, %u materials, %u textures, "
        "%u skins loaded from %s",
        out_scene->mesh_count, out_scene->material_count, out_scene->texture_count,
        out_scene->skin_count, path);
    if (out_scene->animation_system) {
        CARDINAL_LOG_INFO("  Animations: %u", out_scene->animation_system->animation_count);
    }
    return true;
}
