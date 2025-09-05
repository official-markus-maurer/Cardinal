#include "cardinal/assets/scene.h"
#include "cardinal/assets/material_ref_counting.h"
#include "cardinal/core/ref_counting.h"
#include "cardinal/core/transform.h"
#include <stdlib.h>
#include <string.h>

// Helper function to mark node and all children as having dirty world transforms
static void mark_world_transform_dirty(CardinalSceneNode* node) {
    if (!node) return;
    
    node->world_transform_dirty = true;
    for (uint32_t i = 0; i < node->child_count; ++i) {
        mark_world_transform_dirty(node->children[i]);
    }
}

CardinalSceneNode *cardinal_scene_node_create(const char *name) {
    CardinalSceneNode *node = (CardinalSceneNode*)malloc(sizeof(CardinalSceneNode));
    if (!node) return NULL;
    
    // Initialize name
    if (name) {
        size_t name_len = strlen(name) + 1;
        node->name = (char*)malloc(name_len);
        if (!node->name) {
            free(node);
            return NULL;
        }
        strcpy(node->name, name);
    } else {
        node->name = NULL;
    }
    
    // Initialize transforms
    cardinal_matrix_identity(node->local_transform);
    cardinal_matrix_identity(node->world_transform);
    node->world_transform_dirty = false;
    
    // Initialize mesh data
    node->mesh_indices = NULL;
    node->mesh_count = 0;
    
    // Initialize hierarchy
    node->parent = NULL;
    node->children = NULL;
    node->child_count = 0;
    node->child_capacity = 0;
    
    return node;
}

void cardinal_scene_node_destroy(CardinalSceneNode *node) {
    if (!node) return;
    
    // Recursively destroy all children
    for (uint32_t i = 0; i < node->child_count; ++i) {
        cardinal_scene_node_destroy(node->children[i]);
    }
    
    // Free allocated memory
    free(node->name);
    free(node->mesh_indices);
    free(node->children);
    free(node);
}

bool cardinal_scene_node_add_child(CardinalSceneNode *parent, CardinalSceneNode *child) {
    if (!parent || !child) return false;
    
    // Remove child from its current parent if it has one
    if (child->parent) {
        cardinal_scene_node_remove_from_parent(child);
    }
    
    // Expand children array if needed
    if (parent->child_count >= parent->child_capacity) {
        uint32_t new_capacity = parent->child_capacity == 0 ? 4 : parent->child_capacity * 2;
        CardinalSceneNode **new_children = (CardinalSceneNode**)realloc(
            parent->children, new_capacity * sizeof(CardinalSceneNode*));
        if (!new_children) return false;
        
        parent->children = new_children;
        parent->child_capacity = new_capacity;
    }
    
    // Add child to parent
    parent->children[parent->child_count++] = child;
    child->parent = parent;
    
    // Mark child's world transform as dirty
    mark_world_transform_dirty(child);
    
    return true;
}

bool cardinal_scene_node_remove_from_parent(CardinalSceneNode *child) {
    if (!child || !child->parent) return false;
    
    CardinalSceneNode *parent = child->parent;
    
    // Find child in parent's children array
    for (uint32_t i = 0; i < parent->child_count; ++i) {
        if (parent->children[i] == child) {
            // Move last child to this position
            parent->children[i] = parent->children[parent->child_count - 1];
            parent->child_count--;
            child->parent = NULL;
            
            // Mark child's world transform as dirty
            mark_world_transform_dirty(child);
            
            return true;
        }
    }
    
    return false;
}

CardinalSceneNode *cardinal_scene_node_find_by_name(CardinalSceneNode *root, const char *name) {
    if (!root || !name) return NULL;
    
    // Check if this node matches
    if (root->name && strcmp(root->name, name) == 0) {
        return root;
    }
    
    // Recursively search children
    for (uint32_t i = 0; i < root->child_count; ++i) {
        CardinalSceneNode *found = cardinal_scene_node_find_by_name(root->children[i], name);
        if (found) return found;
    }
    
    return NULL;
}

void cardinal_scene_node_update_transforms(CardinalSceneNode *node, const float *parent_world_transform) {
    if (!node) return;
    
    // Update world transform if dirty or if parent transform changed
    if (node->world_transform_dirty || parent_world_transform) {
        if (parent_world_transform) {
            cardinal_matrix_multiply(parent_world_transform, node->local_transform, node->world_transform);
        } else {
            memcpy(node->world_transform, node->local_transform, 16 * sizeof(float));
        }
        node->world_transform_dirty = false;
    }
    
    // Recursively update children
    for (uint32_t i = 0; i < node->child_count; ++i) {
        cardinal_scene_node_update_transforms(node->children[i], node->world_transform);
    }
}

void cardinal_scene_node_set_local_transform(CardinalSceneNode *node, const float *transform) {
    if (!node || !transform) return;
    
    memcpy(node->local_transform, transform, 16 * sizeof(float));
    mark_world_transform_dirty(node);
}

const float *cardinal_scene_node_get_world_transform(CardinalSceneNode *node) {
    if (!node) return NULL;
    
    // Update transform if dirty
    if (node->world_transform_dirty) {
        const float *parent_transform = node->parent ? 
            cardinal_scene_node_get_world_transform(node->parent) : NULL;
        cardinal_scene_node_update_transforms(node, parent_transform);
    }
    
    return node->world_transform;
}

/**
 * @brief Destroys a CardinalScene and frees all associated resources.
 *
 * @param scene Pointer to the CardinalScene to destroy.
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

    // Destroy scene node hierarchy
    if (scene->root_nodes) {
        for (uint32_t i = 0; i < scene->root_node_count; ++i) {
            cardinal_scene_node_destroy(scene->root_nodes[i]);
        }
        free(scene->root_nodes);
    }

    memset(scene, 0, sizeof(*scene));
}
