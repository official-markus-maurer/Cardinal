#include "cardinal/assets/scene.h"
#include "cardinal/assets/material_ref_counting.h"
#include "cardinal/core/ref_counting.h"
#include <stdlib.h>
#include <string.h>

/**
 * @brief Destroys a CardinalScene and frees all associated resources.
 *
 * @param scene Pointer to the CardinalScene to destroy.
 *
 * @todo Add scene creation and cloning functions.
 * @todo Support scene hierarchy and node transformations.
 * @todo Integrate with entity-component system for dynamic scenes.
 */
void cardinal_scene_destroy(CardinalScene* scene) {
    if (!scene)
        return;

    // Free meshes
    if (scene->meshes) {
        for (uint32_t i = 0; i < scene->mesh_count; ++i) {
            free(scene->meshes[i].vertices);
            free(scene->meshes[i].indices);
        }
        free(scene->meshes);
    }

    // Release reference-counted materials
    if (scene->materials) {
        for (uint32_t i = 0; i < scene->material_count; ++i) {
            if (scene->materials[i].ref_resource) {
                cardinal_material_release_ref_counted(scene->materials[i].ref_resource);
            }
        }
        free(scene->materials);
    }

    // Release reference-counted textures
    if (scene->textures) {
        for (uint32_t i = 0; i < scene->texture_count; ++i) {
            if (scene->textures[i].ref_resource) {
                cardinal_ref_release(scene->textures[i].ref_resource);
            } else {
                // Fallback for non-reference-counted textures
                free(scene->textures[i].data);
                free(scene->textures[i].path);
            }
        }
        free(scene->textures);
    }

    memset(scene, 0, sizeof(*scene));
}
