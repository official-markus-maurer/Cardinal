#ifndef CARDINAL_ASSETS_SCENE_H
#define CARDINAL_ASSETS_SCENE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Vertex format for PBR rendering
typedef struct CardinalVertex {
    float px, py, pz;    // Position
    float nx, ny, nz;    // Normal
    float u, v;          // Texture coordinates
} CardinalVertex;

// Texture transform structure
typedef struct CardinalTextureTransform {
    float offset[2];    // UV offset
    float scale[2];     // UV scale
    float rotation;     // UV rotation in radians
} CardinalTextureTransform;

// PBR Material structure
typedef struct CardinalMaterial {
    // Texture indices (into scene texture array)
    uint32_t albedo_texture;
    uint32_t normal_texture;
    uint32_t metallic_roughness_texture;
    uint32_t ao_texture;
    uint32_t emissive_texture;
    
    // Material factors
    float albedo_factor[3];      // RGB
    float metallic_factor;
    float roughness_factor;
    float emissive_factor[3];    // RGB
    float normal_scale;
    float ao_strength;
    
    // Texture transforms
    CardinalTextureTransform albedo_transform;
    CardinalTextureTransform normal_transform;
    CardinalTextureTransform metallic_roughness_transform;
    CardinalTextureTransform ao_transform;
    CardinalTextureTransform emissive_transform;
} CardinalMaterial;

// Texture data
typedef struct CardinalTexture {
    unsigned char* data;
    uint32_t width;
    uint32_t height;
    uint32_t channels;
    char* path;  // For debugging/identification
} CardinalTexture;

typedef struct CardinalMesh {
    CardinalVertex* vertices;
    uint32_t vertex_count;
    uint32_t* indices;
    uint32_t index_count;
    uint32_t material_index;  // Index into scene materials array
    float transform[16];      // 4x4 transformation matrix (column-major)
} CardinalMesh;

typedef struct CardinalScene {
    CardinalMesh* meshes;
    uint32_t mesh_count;
    
    CardinalMaterial* materials;
    uint32_t material_count;
    
    CardinalTexture* textures;
    uint32_t texture_count;
} CardinalScene;

// Destroy a scene allocated by loaders
void cardinal_scene_destroy(CardinalScene* scene);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_SCENE_H
