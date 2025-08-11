#ifndef CARDINAL_ASSETS_GLTF_LOADER_H
#define CARDINAL_ASSETS_GLTF_LOADER_H

#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#include "cardinal/assets/scene.h"

// Load a GLTF/GLB scene file into a CardinalScene. Returns true on success.
bool cardinal_gltf_load_scene(const char* filepath, CardinalScene* out_scene);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_GLTF_LOADER_H