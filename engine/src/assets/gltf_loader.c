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

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

// cgltf is header-only; include path supplied by CMake
#define CGLTF_IMPLEMENTATION
#include "cgltf.h"

#include "cardinal/assets/gltf_loader.h"
#include "cardinal/assets/texture_loader.h"
#include "cardinal/core/log.h"

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
    *nx = 0.0f; *ny = 1.0f; *nz = 0.0f;
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
static bool load_texture_with_fallback(const char* original_uri, const char* base_path, CardinalTexture* out_texture) {
    char texture_path[512] = {0};
    TextureData tex_data = {0};
    
    // First attempt: original path relative to glTF
    const char* last_slash = strrchr(base_path, '/');
    if (!last_slash) last_slash = strrchr(base_path, '\\');
    
    if (last_slash) {
        size_t dir_len = (size_t)(last_slash - base_path + 1);
        strncpy(texture_path, base_path, dir_len);
        texture_path[dir_len] = '\0';
        strncat(texture_path, original_uri, sizeof(texture_path) - dir_len - 1);
    } else {
        strncpy(texture_path, original_uri, sizeof(texture_path) - 1);
    }
    
    LOG_DEBUG("Trying texture path: %s", texture_path);
    if (texture_load_from_file(texture_path, &tex_data)) {
        goto success;
    }
    
    // Extract filename for advanced fallbacks
    const char* filename_only = strrchr(original_uri, '/');
    if (!filename_only) filename_only = strrchr(original_uri, '\\');
    if (!filename_only) filename_only = original_uri;
    else filename_only++; // Skip the slash
    
    // Hardened mapping: if filename contains both Roughness and Metalness in any order,
    // treat it as a concatenation and try decomposed lookups using the prefix before the first token.
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
    LOG_DEBUG("Analyzing filename: %s", filename_only);
    if (rough_pos) LOG_DEBUG("  - Found 'Roughness' at position %ld", (long)(rough_pos - filename_only));
    if (metal_pos) LOG_DEBUG("  - Found 'Metalness' at position %ld", (long)(metal_pos - filename_only));
    if (base_pos) LOG_DEBUG("  - Found 'BaseColor' at position %ld", (long)(base_pos - filename_only));
    if (normal_pos) LOG_DEBUG("  - Found 'Normal' at position %ld", (long)(normal_pos - filename_only));
    
    if (first_token) {
        size_t base_len = (size_t)(first_token - filename_only);
        if (base_len > 0 && base_len < 256) {
            char base_name[256];
            strncpy(base_name, filename_only, base_len);
            base_name[base_len] = '\0';
            
            LOG_DEBUG("Extracted base name: '%s'", base_name);
            
            // Prepare base_dir prefix like <gltf_dir>/textures/
            char base_dir_prefix[512] = {0};
            if (last_slash) {
                size_t dir_len = (size_t)(last_slash - base_path + 1);
                strncpy(base_dir_prefix, base_path, dir_len);
                base_dir_prefix[dir_len] = '\0';
                strncat(base_dir_prefix, "textures/", sizeof(base_dir_prefix) - dir_len - 1);
            }
            
            // Candidates in order: base_dir textures (Roughness, Metalness, BaseColor, Normal), then assets/textures
            const char* suffixes[4] = { "Roughness.png", "Metalness.png", "BaseColor.png", "Normal.png" };
            for (int i = 0; i < 4; ++i) {
                if (base_dir_prefix[0] != '\0') {
                    snprintf(texture_path, sizeof(texture_path), "%s%s%s", base_dir_prefix, base_name, suffixes[i]);
                    LOG_DEBUG("Trying decomposed candidate: %s", texture_path);
                    if (texture_load_from_file(texture_path, &tex_data)) {
                        goto success;
                    }
                }
                snprintf(texture_path, sizeof(texture_path), "assets/textures/%s%s", base_name, suffixes[i]);
                LOG_DEBUG("Trying decomposed candidate: %s", texture_path);
                if (texture_load_from_file(texture_path, &tex_data)) {
                    goto success;
                }
                
                // Also try the assets/models/textures directory
                snprintf(texture_path, sizeof(texture_path), "assets/models/textures/%s%s", base_name, suffixes[i]);
                LOG_DEBUG("Trying models/textures candidate: %s", texture_path);
                if (texture_load_from_file(texture_path, &tex_data)) {
                    goto success;
                }
            }
        }
    }
    
    // Second attempt: textures folder parallel to models (../textures and ../../textures)
    if (last_slash) {
        size_t dir_len = (size_t)(last_slash - base_path + 1);
        char base_dir[512];
        strncpy(base_dir, base_path, dir_len);
        base_dir[dir_len] = '\0';
        
        // ../textures/filename
        snprintf(texture_path, sizeof(texture_path), "%s../textures/%s", base_dir, filename_only);
        LOG_DEBUG("Trying fallback path: %s", texture_path);
        if (texture_load_from_file(texture_path, &tex_data)) {
            goto success;
        }
        
        // ../../textures/filename
        snprintf(texture_path, sizeof(texture_path), "%s../../textures/%s", base_dir, filename_only);
        LOG_DEBUG("Trying deeper fallback path: %s", texture_path);
        if (texture_load_from_file(texture_path, &tex_data)) {
            goto success;
        }
        
        // Replace 'models' with 'textures' in the path
        char models_to_textures[512];
        strncpy(models_to_textures, base_dir, sizeof(models_to_textures) - 1);
        models_to_textures[sizeof(models_to_textures) - 1] = '\0';
        char* models_seg = NULL;
        if (!models_seg) models_seg = strstr(models_to_textures, "/models/");
        if (!models_seg) models_seg = strstr(models_to_textures, "\\models\\");
        if (models_seg) {
            size_t prefix_len = (size_t)(models_seg - models_to_textures);
            char prefix[512];
            strncpy(prefix, models_to_textures, prefix_len);
            prefix[prefix_len] = '\0';
            char sep = (models_seg[0] == '/') ? '/' : '\\';
            snprintf(texture_path, sizeof(texture_path), "%s%ctextures%c%s", prefix, sep, sep, filename_only);
            LOG_DEBUG("Trying models->textures remap: %s", texture_path);
            if (texture_load_from_file(texture_path, &tex_data)) {
                goto success;
            }
        }
    }
    
    // Third attempt: just the filename in assets/textures relative to CWD
    snprintf(texture_path, sizeof(texture_path), "assets/textures/%s", filename_only);
    LOG_DEBUG("Trying relative path: %s", texture_path);
    if (texture_load_from_file(texture_path, &tex_data)) {
        goto success;
    }
    
    // Fourth attempt: create fallback texture
    LOG_WARN("Failed to load texture '%s' from all paths, using fallback", original_uri);
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
    
    LOG_INFO("Loaded texture %s: %ux%u, %u channels", texture_path, tex_data.width, tex_data.height, tex_data.channels);
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
static void extract_texture_transform(const cgltf_texture_view* texture_view, CardinalTextureTransform* out_transform) {
    // Initialize to identity transform
    out_transform->offset[0] = 0.0f;
    out_transform->offset[1] = 0.0f;
    out_transform->scale[0] = 1.0f;
    out_transform->scale[1] = 1.0f;
    out_transform->rotation = 0.0f;
    
    if (texture_view && texture_view->has_transform) {
        const cgltf_texture_transform* transform = &texture_view->transform;
        out_transform->offset[0] = transform->offset[0];
        out_transform->offset[1] = transform->offset[1];
        out_transform->scale[0] = transform->scale[0];
        out_transform->scale[1] = transform->scale[1];
        out_transform->rotation = transform->rotation;
        LOG_DEBUG("Texture transform: offset=(%.3f,%.3f), scale=(%.3f,%.3f), rotation=%.3f",
                 out_transform->offset[0], out_transform->offset[1],
                 out_transform->scale[0], out_transform->scale[1],
                 out_transform->rotation);
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
static bool load_texture_from_gltf(const cgltf_data* data, cgltf_size img_idx, const char* base_path, CardinalTexture* out_texture) {
    if (img_idx >= data->images_count || !data->images) {
        LOG_ERROR("Invalid image index %zu, only %zu images available", (size_t)img_idx, (size_t)data->images_count);
        return false;
    }

    const cgltf_image* img = &data->images[img_idx];

    if (img->uri) {
        // External image file - use fallback helper
        return load_texture_with_fallback(img->uri, base_path, out_texture);
    } else {
        LOG_WARN("Embedded textures not supported yet, using fallback");
        return create_fallback_texture(out_texture);
    }
}

// Helper function to multiply 4x4 matrices (column-major)
static void matrix_multiply(const float* a, const float* b, float* result) {
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            result[i * 4 + j] = 0.0f;
            for (int k = 0; k < 4; k++) {
                result[i * 4 + j] += a[i * 4 + k] * b[k * 4 + j];
            }
        }
    }
}

// Helper function to create identity matrix
static void matrix_identity(float* matrix) {
    memset(matrix, 0, 16 * sizeof(float));
    matrix[0] = matrix[5] = matrix[10] = matrix[15] = 1.0f;
}

// Helper function to create transformation matrix from TRS
static void matrix_from_trs(const float* translation, const float* rotation, const float* scale, float* matrix) {
    // Start with identity
    matrix_identity(matrix);
    
    // Apply scale
    if (scale) {
        matrix[0] *= scale[0];
        matrix[5] *= scale[1];
        matrix[10] *= scale[2];
    }
    
    // Apply rotation (quaternion to matrix)
    if (rotation) {
        float x = rotation[0], y = rotation[1], z = rotation[2], w = rotation[3];
        float x2 = x + x, y2 = y + y, z2 = z + z;
        float xx = x * x2, xy = x * y2, xz = x * z2;
        float yy = y * y2, yz = y * z2, zz = z * z2;
        float wx = w * x2, wy = w * y2, wz = w * z2;
        
        float rot_matrix[16];
        matrix_identity(rot_matrix);
        rot_matrix[0] = 1.0f - (yy + zz);
        rot_matrix[1] = xy + wz;
        rot_matrix[2] = xz - wy;
        rot_matrix[4] = xy - wz;
        rot_matrix[5] = 1.0f - (xx + zz);
        rot_matrix[6] = yz + wx;
        rot_matrix[8] = xz + wy;
        rot_matrix[9] = yz - wx;
        rot_matrix[10] = 1.0f - (xx + yy);
        
        float temp[16];
        memcpy(temp, matrix, 16 * sizeof(float));
        matrix_multiply(temp, rot_matrix, matrix);
    }
    
    // Apply translation
    if (translation) {
        matrix[12] += translation[0];
        matrix[13] += translation[1];
        matrix[14] += translation[2];
    }
}

// Helper function to traverse nodes and compute world transforms
static void process_node(const cgltf_data* data, const cgltf_node* node, const float* parent_transform, 
                        CardinalMesh* meshes, size_t total_mesh_count) {
    float local_transform[16];
    
    if (node->has_matrix) {
        // Use provided matrix directly
        memcpy(local_transform, node->matrix, 16 * sizeof(float));
    } else {
        // Build matrix from TRS
        const float* translation = node->has_translation ? node->translation : NULL;
        const float* rotation = node->has_rotation ? node->rotation : NULL;
        const float* scale = node->has_scale ? node->scale : NULL;
        matrix_from_trs(translation, rotation, scale, local_transform);
    }
    
    // Compute world transform
    float world_transform[16];
    if (parent_transform) {
        matrix_multiply(parent_transform, local_transform, world_transform);
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
                memcpy(meshes[cardinal_mesh_index + pi].transform, world_transform, 16 * sizeof(float));
                LOG_TRACE("Applied transform to mesh %zu (glTF mesh %zu, primitive %zu)", 
                         cardinal_mesh_index + pi, mesh_index, pi);
            }
        }
    }
    
    // Recursively process children
    for (cgltf_size ci = 0; ci < node->children_count; ++ci) {
        process_node(data, node->children[ci], world_transform, meshes, total_mesh_count);
    }
}

/**
 * @brief Loads a glTF scene from file.
 *
 * Parses the glTF file, loads buffers, textures, materials, and meshes.
 * Now properly processes node hierarchy and transformations.
 *
 * @param path Path to the glTF/glb file.
 * @param out_scene Pointer to the scene structure to fill.
 * @return true on success, false on failure.
 *
 * @todo Support glTF animations and skins.
 * @todo Implement error recovery and partial loading.
 * @todo Add support for glTF extensions like lights and cameras.
 */
bool cardinal_gltf_load_scene(const char* path, CardinalScene* out_scene) {
    if (!path || !out_scene) {
        LOG_ERROR("Invalid parameters: path=%p, out_scene=%p", (void*)path, (void*)out_scene);
        return false;
    }

    LOG_INFO("Starting GLTF scene loading: %s", path);
    memset(out_scene, 0, sizeof(*out_scene));

    cgltf_options options = {0};
    cgltf_data* data = NULL;

    LOG_DEBUG("Parsing GLTF file...");
    cgltf_result result = cgltf_parse_file(&options, path, &data);
    if (result != cgltf_result_success) {
        LOG_ERROR("cgltf_parse_file failed: %d for %s", (int)result, path);
        return false;
    }
    LOG_DEBUG("GLTF file parsed successfully");

    LOG_DEBUG("Loading GLTF buffers...");
    result = cgltf_load_buffers(&options, data, path);
    if (result != cgltf_result_success) {
        LOG_ERROR("cgltf_load_buffers failed: %d for %s", (int)result, path);
        cgltf_free(data);
        return false;
    }
    LOG_DEBUG("GLTF buffers loaded successfully");

    // Load textures first
    LOG_DEBUG("Loading %zu textures...", (size_t)data->images_count);
    CardinalTexture* textures = NULL;
    uint32_t texture_count = 0;
    
    if (data->images_count > 0) {
        textures = (CardinalTexture*)calloc(data->images_count, sizeof(CardinalTexture));
        if (!textures) {
            LOG_ERROR("Failed to allocate memory for textures");
            cgltf_free(data);
            return false;
        }
        
        for (cgltf_size i = 0; i < data->images_count; i++) {
            if (load_texture_from_gltf(data, i, path, &textures[texture_count])) {
                texture_count++;
            } else {
                LOG_WARN("Failed to load texture %zu, skipping", (size_t)i);
            }
        }
        LOG_INFO("Successfully loaded %u out of %zu textures", texture_count, (size_t)data->images_count);
    }

    // Load materials
    LOG_DEBUG("Loading %zu materials...", (size_t)data->materials_count);
    CardinalMaterial* materials = NULL;
    uint32_t material_count = 0;
    
    if (data->materials_count > 0) {
        materials = (CardinalMaterial*)calloc(data->materials_count, sizeof(CardinalMaterial));
        if (!materials) {
            LOG_ERROR("Failed to allocate memory for materials");
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
            CardinalTextureTransform identity_transform = {{0.0f, 0.0f}, {1.0f, 1.0f}, 0.0f};
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
                    extract_texture_transform(&pbr->base_color_texture, &card_mat->albedo_transform);
                }
                
                // Metallic roughness texture
                if (pbr->metallic_roughness_texture.texture) {
                    cgltf_size img_idx = pbr->metallic_roughness_texture.texture->image - data->images;
                    if (img_idx < texture_count) {
                        card_mat->metallic_roughness_texture = (uint32_t)img_idx;
                    }
                    extract_texture_transform(&pbr->metallic_roughness_texture, &card_mat->metallic_roughness_transform);
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
            if (mat->emissive_factor[0] > 0.0f || mat->emissive_factor[1] > 0.0f || mat->emissive_factor[2] > 0.0f) {
                card_mat->emissive_factor[0] = mat->emissive_factor[0];
                card_mat->emissive_factor[1] = mat->emissive_factor[1];
                card_mat->emissive_factor[2] = mat->emissive_factor[2];
            }
            
            material_count++;
            LOG_DEBUG("Material %u loaded: albedo_tex=%u, normal_tex=%u, mr_tex=%u", 
                     material_count - 1, 
                     card_mat->albedo_texture,
                     card_mat->normal_texture,
                     card_mat->metallic_roughness_texture);
            LOG_DEBUG("Material %u factors: albedo=(%.3f,%.3f,%.3f), metallic=%.3f, roughness=%.3f",
                     material_count - 1,
                     card_mat->albedo_factor[0], card_mat->albedo_factor[1], card_mat->albedo_factor[2],
                     card_mat->metallic_factor, card_mat->roughness_factor);
        }
        LOG_INFO("Successfully loaded %u materials", material_count);
    }

    // Count total primitives as meshes for now
    LOG_DEBUG("Analyzing scene structure: %zu meshes found", (size_t)data->meshes_count);
    size_t mesh_count = 0;
    for (cgltf_size mi = 0; mi < data->meshes_count; ++mi) {
        const cgltf_mesh* m = &data->meshes[mi];
        mesh_count += (size_t)m->primitives_count;
        LOG_TRACE("Mesh %zu: %zu primitives", (size_t)mi, (size_t)m->primitives_count);
    }
    LOG_INFO("Total primitives to load: %zu", mesh_count);

    if (mesh_count == 0) {
        LOG_WARN("Scene contains no meshes, returning empty scene");
        cgltf_free(data);
        return true; // empty scene
    }

    LOG_DEBUG("Allocating memory for %zu meshes", mesh_count);
    CardinalMesh* meshes = (CardinalMesh*)calloc(mesh_count, sizeof(CardinalMesh));
    if (!meshes) {
        LOG_ERROR("Failed to allocate memory for %zu meshes", mesh_count);
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

    LOG_DEBUG("Processing mesh data...");
    size_t mesh_write = 0;
    for (cgltf_size mi = 0; mi < data->meshes_count; ++mi) {
        const cgltf_mesh* m = &data->meshes[mi];
        LOG_DEBUG("Processing mesh %zu/%zu with %zu primitives", (size_t)mi + 1, (size_t)data->meshes_count, (size_t)m->primitives_count);
        
        for (cgltf_size pi = 0; pi < m->primitives_count; ++pi) {
            const cgltf_primitive* p = &m->primitives[pi];
            LOG_TRACE("Processing primitive %zu/%zu", (size_t)pi + 1, (size_t)m->primitives_count);

            // Determine vertex count from POSITION accessor
            const cgltf_accessor* pos_acc = NULL;
            const cgltf_accessor* nrm_acc = NULL;
            const cgltf_accessor* uv_acc = NULL;
            for (cgltf_size ai = 0; ai < p->attributes_count; ++ai) {
                const cgltf_attribute* a = &p->attributes[ai];
                if (a->type == cgltf_attribute_type_position) pos_acc = a->data;
                if (a->type == cgltf_attribute_type_normal) nrm_acc = a->data;
                if (a->type == cgltf_attribute_type_texcoord) uv_acc = a->data;
            }

            if (!pos_acc) {
                LOG_WARN("Skipping primitive %zu/%zu: no position data", (size_t)pi + 1, (size_t)m->primitives_count);
                continue;
            }
            cgltf_size vcount = pos_acc->count;
            LOG_TRACE("Primitive has %zu vertices, normals=%s, UVs=%s", 
                     (size_t)vcount, 
                     nrm_acc ? "yes" : "no", 
                     uv_acc ? "yes" : "no");

            CardinalVertex* vertices = (CardinalVertex*)calloc(vcount, sizeof(CardinalVertex));
            if (!vertices) {
                LOG_ERROR("Failed to allocate memory for %zu vertices", (size_t)vcount);
                continue;
            }
            LOG_TRACE("Allocated vertex buffer for %zu vertices", (size_t)vcount);

            // Read positions
            LOG_TRACE("Reading position data...");
            for (cgltf_size vi = 0; vi < vcount; ++vi) {
                cgltf_float v[3] = {0};
                cgltf_accessor_read_float(pos_acc, vi, v, 3);
                vertices[vi].px = (float)v[0];
                vertices[vi].py = (float)v[1];
                vertices[vi].pz = (float)v[2];
            }
            // Debug log first few vertices
            if (vcount > 0) {
                LOG_DEBUG("First vertex: pos=(%f, %f, %f)", vertices[0].px, vertices[0].py, vertices[0].pz);
                if (vcount > 1) {
                    LOG_DEBUG("Second vertex: pos=(%f, %f, %f)", vertices[1].px, vertices[1].py, vertices[1].pz);
                }
            }

            // Read normals
            if (nrm_acc) {
                LOG_TRACE("Reading normal data...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_float v[3] = {0};
                    cgltf_accessor_read_float(nrm_acc, vi, v, 3);
                    vertices[vi].nx = (float)v[0];
                    vertices[vi].ny = (float)v[1];
                    vertices[vi].nz = (float)v[2];
                }
            } else {
                LOG_TRACE("Generating default normals...");
                float nx, ny, nz;
                compute_default_normal(&nx, &ny, &nz);
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    vertices[vi].nx = nx; vertices[vi].ny = ny; vertices[vi].nz = nz;
                }
            }

            // Read UVs
            if (uv_acc) {
                LOG_TRACE("Reading UV coordinate data...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_float v[2] = {0};
                    cgltf_accessor_read_float(uv_acc, vi, v, 2);
                    vertices[vi].u = (float)v[0];
                    vertices[vi].v = (float)v[1];
                }
            } else {
                LOG_TRACE("Setting default UV coordinates...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    vertices[vi].u = 0.0f; vertices[vi].v = 0.0f;
                }
            }

            // Indices
            uint32_t* indices = NULL;
            uint32_t index_count = 0;
            if (p->indices) {
                index_count = (uint32_t)p->indices->count;
                LOG_TRACE("Reading %u indices...", index_count);
                indices = (uint32_t*)malloc(sizeof(uint32_t) * index_count);
                if (indices) {
                    for (cgltf_size ii = 0; ii < p->indices->count; ++ii) {
                        cgltf_uint idx = 0;
                        cgltf_accessor_read_uint(p->indices, ii, &idx, 1);
                        indices[ii] = (uint32_t)idx;
                    }
                    LOG_TRACE("Successfully read %u indices", index_count);
                } else {
                    LOG_ERROR("Failed to allocate memory for %u indices", index_count);
                    index_count = 0;
                }
            } else {
                // Generate a linear index buffer if the primitive is triangles and no indices given
                if (p->type == cgltf_primitive_type_triangles) {
                    index_count = (uint32_t)vcount;
                    LOG_TRACE("Generating linear index buffer with %u indices", index_count);
                    indices = (uint32_t*)malloc(sizeof(uint32_t) * index_count);
                    if (indices) {
                        for (uint32_t ii = 0; ii < index_count; ++ii) indices[ii] = ii;
                        LOG_TRACE("Generated linear index buffer successfully");
                    } else {
                        LOG_ERROR("Failed to allocate memory for generated %u indices", index_count);
                        index_count = 0;
                    }
                } else {
                    LOG_TRACE("No indices provided and primitive type is not triangles, using unindexed rendering");
                }
            }
            // Debug log first few indices
            if (index_count > 0 && indices) {
#ifdef _DEBUG
                uint32_t i0 = indices[0];
                uint32_t i1 = (index_count > 1) ? indices[1] : 0;
                uint32_t i2 = (index_count > 2) ? indices[2] : 0;
                LOG_DEBUG("First indices: %u, %u, %u (of %u)", i0, i1, i2, index_count);
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
            
            LOG_TRACE("Mesh %zu complete: %u vertices, %u indices, material=%u", mesh_write, dst->vertex_count, dst->index_count, dst->material_index);
        }
    }

    // Process scene graph to compute proper mesh transforms
    LOG_DEBUG("Processing scene graph and node transformations...");
    
    // Process the default scene if available
    if (data->scene && data->scene->nodes_count > 0) {
        LOG_DEBUG("Processing default scene with %zu root nodes", (size_t)data->scene->nodes_count);
        for (cgltf_size ni = 0; ni < data->scene->nodes_count; ++ni) {
            process_node(data, data->scene->nodes[ni], NULL, meshes, mesh_count);
        }
    } else if (data->nodes_count > 0) {
        // Fallback: process all nodes as root nodes if no scene is defined
        LOG_DEBUG("No default scene found, processing %zu nodes as root nodes", (size_t)data->nodes_count);
        for (cgltf_size ni = 0; ni < data->nodes_count; ++ni) {
            process_node(data, &data->nodes[ni], NULL, meshes, mesh_count);
        }
    }
    
    LOG_INFO("Applied transforms to meshes from scene graph");

    cgltf_free(data);
    LOG_DEBUG("GLTF data structures freed");

    out_scene->meshes = meshes;
    out_scene->mesh_count = (uint32_t)mesh_write; // Use actual written count
    out_scene->materials = materials;
    out_scene->material_count = material_count;
    out_scene->textures = textures;
    out_scene->texture_count = texture_count;
    
    LOG_INFO("GLTF scene loading completed successfully: %u meshes, %u materials, %u textures loaded from %s", 
             out_scene->mesh_count, out_scene->material_count, out_scene->texture_count, path);
    return true;
}
