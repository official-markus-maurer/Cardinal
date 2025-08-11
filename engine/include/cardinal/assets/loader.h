#ifndef CARDINAL_ASSETS_LOADER_H
#define CARDINAL_ASSETS_LOADER_H

#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#include "cardinal/assets/scene.h"

// Generic scene load by file extension. Supports .gltf/.glb for now.
bool cardinal_scene_load(const char* filepath, CardinalScene* out_scene);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_LOADER_H
