#ifndef CARDINAL_ASSETS_SCENE_H
#define CARDINAL_ASSETS_SCENE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Simple vertex format for now
typedef struct CardinalVertex {
    float px, py, pz;
    float nx, ny, nz;
    float u, v;
} CardinalVertex;

typedef struct CardinalMesh {
    CardinalVertex* vertices;
    uint32_t vertex_count;
    uint32_t* indices;
    uint32_t index_count;
    // TODO: material reference, GPU buffers, etc.
} CardinalMesh;

typedef struct CardinalScene {
    CardinalMesh* meshes;
    uint32_t mesh_count;
} CardinalScene;

// Destroy a scene allocated by loaders
void cardinal_scene_destroy(CardinalScene* scene);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_SCENE_H
