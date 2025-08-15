/**
 * @file scene.h
 * @brief Scene data structures and management for Cardinal Engine
 * 
 * This module defines the core data structures used to represent 3D scenes,
 * including meshes, materials, textures, and vertices. It provides a unified
 * representation for loaded 3D assets that can be efficiently rendered using
 * the Cardinal Engine's PBR (Physically Based Rendering) pipeline.
 * 
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_ASSETS_SCENE_H
#define CARDINAL_ASSETS_SCENE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Vertex format for PBR rendering
 * 
 * Defines the vertex layout used throughout the Cardinal Engine's rendering pipeline.
 * Each vertex contains position, normal, and texture coordinate data required for
 * physically-based rendering.
 */
typedef struct CardinalVertex {
    float px, py, pz;    /**< 3D position coordinates (x, y, z) */
    float nx, ny, nz;    /**< Surface normal vector (x, y, z) */
    float u, v;          /**< Texture coordinates (u, v) */
} CardinalVertex;

/**
 * @brief Texture transformation parameters
 * 
 * Defines UV coordinate transformations that can be applied to textures.
 * Supports the KHR_texture_transform glTF extension for advanced texture mapping.
 */
typedef struct CardinalTextureTransform {
    float offset[2];    /**< UV coordinate offset (u, v) */
    float scale[2];     /**< UV coordinate scale factors (u, v) */
    float rotation;     /**< UV rotation angle in radians */
} CardinalTextureTransform;

/**
 * @brief PBR (Physically Based Rendering) material definition
 * 
 * Contains all parameters needed to define a physically-based material,
 * including texture references, material factors, and texture transformations.
 * Follows the glTF 2.0 PBR material specification.
 */
typedef struct CardinalMaterial {
    /** @name Texture Indices
     * Indices into the scene's texture array. Use UINT32_MAX for unused textures.
     * @{
     */
    uint32_t albedo_texture;            /**< Base color/albedo texture index */
    uint32_t normal_texture;            /**< Normal map texture index */
    uint32_t metallic_roughness_texture; /**< Metallic-roughness texture index */
    uint32_t ao_texture;                /**< Ambient occlusion texture index */
    uint32_t emissive_texture;          /**< Emissive texture index */
    /** @} */
    
    /** @name Material Factors
     * Scalar and vector factors that modify texture values or provide defaults.
     * @{
     */
    float albedo_factor[3];      /**< Base color factor (RGB) */
    float metallic_factor;       /**< Metallic factor [0.0, 1.0] */
    float roughness_factor;      /**< Roughness factor [0.0, 1.0] */
    float emissive_factor[3];    /**< Emissive factor (RGB) */
    float normal_scale;          /**< Normal map intensity scale */
    float ao_strength;           /**< Ambient occlusion strength [0.0, 1.0] */
    /** @} */
    
    /** @name Texture Transforms
     * UV coordinate transformations for each texture type.
     * @{
     */
    CardinalTextureTransform albedo_transform;            /**< Albedo texture transform */
    CardinalTextureTransform normal_transform;            /**< Normal texture transform */
    CardinalTextureTransform metallic_roughness_transform; /**< Metallic-roughness texture transform */
    CardinalTextureTransform ao_transform;                /**< AO texture transform */
    CardinalTextureTransform emissive_transform;          /**< Emissive texture transform */
    /** @} */
} CardinalMaterial;

/**
 * @brief Texture data container
 * 
 * Holds raw texture data and metadata. The texture data is stored in
 * a format suitable for GPU upload (typically RGBA8 or similar).
 */
typedef struct CardinalTexture {
    unsigned char* data;  /**< Raw texture pixel data */
    uint32_t width;       /**< Texture width in pixels */
    uint32_t height;      /**< Texture height in pixels */
    uint32_t channels;    /**< Number of color channels (1-4) */
    char* path;           /**< Original file path (for debugging/identification) */
} CardinalTexture;

/**
 * @brief 3D mesh data structure
 * 
 * Contains vertex and index data for a single mesh, along with its material
 * assignment and transformation matrix. Each mesh represents a drawable object
 * in the scene.
 */
typedef struct CardinalMesh {
    CardinalVertex* vertices;  /**< Array of vertex data */
    uint32_t vertex_count;     /**< Number of vertices in the mesh */
    uint32_t* indices;         /**< Array of vertex indices for triangulation */
    uint32_t index_count;      /**< Number of indices in the mesh */
    uint32_t material_index;   /**< Index into scene materials array */
    float transform[16];       /**< 4x4 transformation matrix (column-major) */
} CardinalMesh;

/**
 * @brief Complete 3D scene representation
 * 
 * Contains all data needed to represent a complete 3D scene, including
 * meshes, materials, and textures. This structure is typically populated
 * by asset loaders and consumed by the rendering system.
 */
typedef struct CardinalScene {
    CardinalMesh* meshes;        /**< Array of mesh objects in the scene */
    uint32_t mesh_count;         /**< Number of meshes in the scene */
    
    CardinalMaterial* materials; /**< Array of materials used by meshes */
    uint32_t material_count;     /**< Number of materials in the scene */
    
    CardinalTexture* textures;   /**< Array of textures used by materials */
    uint32_t texture_count;      /**< Number of textures in the scene */
} CardinalScene;

/**
 * @brief Destroy and free a scene
 * 
 * Properly deallocates all memory associated with a scene, including
 * meshes, materials, textures, and their associated data. The scene
 * pointer becomes invalid after this call.
 * 
 * @param scene Pointer to the scene to destroy
 * 
 * @note This function handles NULL pointers gracefully
 */
void cardinal_scene_destroy(CardinalScene* scene);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_SCENE_H
