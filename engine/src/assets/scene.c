#include <stdlib.h>
#include <string.h>
#include "cardinal/assets/scene.h"

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
    if (!scene) return;
    
    // Free meshes
    if (scene->meshes) {
        for (uint32_t i = 0; i < scene->mesh_count; ++i) {
            free(scene->meshes[i].vertices);
            free(scene->meshes[i].indices);
        }
        free(scene->meshes);
    }
    
    // Free materials (no dynamic allocation within materials currently)
    if (scene->materials) {
        free(scene->materials);
    }
    
    // Free textures
    if (scene->textures) {
        for (uint32_t i = 0; i < scene->texture_count; ++i) {
            free(scene->textures[i].data);
            free(scene->textures[i].path);
        }
        free(scene->textures);
    }
    
    memset(scene, 0, sizeof(*scene));
}
