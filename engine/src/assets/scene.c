#include <stdlib.h>
#include <string.h>
#include "cardinal/assets/scene.h"

void cardinal_scene_destroy(CardinalScene* scene) {
    if (!scene) return;
    if (scene->meshes) {
        for (uint32_t i = 0; i < scene->mesh_count; ++i) {
            free(scene->meshes[i].vertices);
            free(scene->meshes[i].indices);
        }
        free(scene->meshes);
    }
    memset(scene, 0, sizeof(*scene));
}