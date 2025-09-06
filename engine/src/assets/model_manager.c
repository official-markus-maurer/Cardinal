/**
 * @file model_manager.c
 * @brief Implementation of multi-model scene management
 */

#include "cardinal/assets/model_manager.h"
#include "cardinal/assets/loader.h"
#include "cardinal/core/log.h"
#include "cardinal/core/transform.h"
#include "cardinal/core/async_loader.h"
#include "cardinal/core/ref_counting.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Initial capacity for models array
#define INITIAL_MODEL_CAPACITY 8

// =============================================================================
// Private Helper Functions
// =============================================================================

/**
 * @brief Generate a default name for a model based on its file path
 */
static char *generate_model_name(const char *file_path) {
    if (!file_path) return NULL;
    
    // Find the last slash or backslash
    const char *filename = file_path;
    for (const char *p = file_path; *p; p++) {
        if (*p == '/' || *p == '\\') {
            filename = p + 1;
        }
    }
    
    // Find the last dot to remove extension
    const char *ext = strrchr(filename, '.');
    size_t name_len = ext ? (size_t)(ext - filename) : strlen(filename);
    
    char *name = (char*)malloc(name_len + 1);
    if (name) {
        strncpy(name, filename, name_len);
        name[name_len] = '\0';
    }
    
    return name;
}

/**
 * @brief Calculate bounding box for a scene
 */
static void calculate_scene_bounds(const CardinalScene *scene, float *bbox_min, float *bbox_max) {
    if (!scene || scene->mesh_count == 0) {
        bbox_min[0] = bbox_min[1] = bbox_min[2] = 0.0f;
        bbox_max[0] = bbox_max[1] = bbox_max[2] = 0.0f;
        return;
    }
    
    // Initialize with first vertex of first mesh
    bool first_vertex = true;
    
    for (uint32_t m = 0; m < scene->mesh_count; m++) {
        const CardinalMesh *mesh = &scene->meshes[m];
        
        for (uint32_t v = 0; v < mesh->vertex_count; v++) {
            const CardinalVertex *vertex = &mesh->vertices[v];
            
            if (first_vertex) {
                bbox_min[0] = bbox_max[0] = vertex->px;
                bbox_min[1] = bbox_max[1] = vertex->py;
                bbox_min[2] = bbox_max[2] = vertex->pz;
                first_vertex = false;
            } else {
                if (vertex->px < bbox_min[0]) bbox_min[0] = vertex->px;
                if (vertex->py < bbox_min[1]) bbox_min[1] = vertex->py;
                if (vertex->pz < bbox_min[2]) bbox_min[2] = vertex->pz;
                if (vertex->px > bbox_max[0]) bbox_max[0] = vertex->px;
                if (vertex->py > bbox_max[1]) bbox_max[1] = vertex->py;
                if (vertex->pz > bbox_max[2]) bbox_max[2] = vertex->pz;
            }
        }
    }
}

/**
 * @brief Expand the models array capacity
 */
static bool expand_models_array(CardinalModelManager *manager) {
    uint32_t new_capacity = manager->model_capacity == 0 ? INITIAL_MODEL_CAPACITY : manager->model_capacity * 2;
    
    CardinalModelInstance *new_models = (CardinalModelInstance*)realloc(
        manager->models, new_capacity * sizeof(CardinalModelInstance));
    
    if (!new_models) {
        CARDINAL_LOG_ERROR("Failed to expand models array to capacity %u", new_capacity);
        return false;
    }
    
    manager->models = new_models;
    manager->model_capacity = new_capacity;
    return true;
}

/**
 * @brief Find model index by ID
 */
static int find_model_index(const CardinalModelManager *manager, uint32_t model_id) {
    for (uint32_t i = 0; i < manager->model_count; i++) {
        if (manager->models[i].id == model_id) {
            return (int)i;
        }
    }
    return -1;
}

/**
 * @brief Rebuild the combined scene from all visible models
 */
static void rebuild_combined_scene(CardinalModelManager *manager) {
    // Clear existing combined scene
    cardinal_scene_destroy(&manager->combined_scene);
    memset(&manager->combined_scene, 0, sizeof(CardinalScene));
    
    // Count total meshes, materials, and textures from visible models
    uint32_t total_meshes = 0, total_materials = 0, total_textures = 0;
    
    for (uint32_t i = 0; i < manager->model_count; i++) {
        const CardinalModelInstance *model = &manager->models[i];
        if (model->visible && !model->is_loading) {
            total_meshes += model->scene.mesh_count;
            total_materials += model->scene.material_count;
            total_textures += model->scene.texture_count;
        }
    }
    
    if (total_meshes == 0) {
        manager->scene_dirty = false;
        return;
    }
    
    // Allocate arrays
    manager->combined_scene.meshes = (CardinalMesh*)calloc(total_meshes, sizeof(CardinalMesh));
    manager->combined_scene.materials = (CardinalMaterial*)calloc(total_materials, sizeof(CardinalMaterial));
    manager->combined_scene.textures = (CardinalTexture*)calloc(total_textures, sizeof(CardinalTexture));
    
    if (!manager->combined_scene.meshes || !manager->combined_scene.materials || !manager->combined_scene.textures) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for combined scene");
        cardinal_scene_destroy(&manager->combined_scene);
        return;
    }
    
    // Copy data from visible models
    uint32_t mesh_offset = 0, material_offset = 0, texture_offset = 0;
    
    for (uint32_t i = 0; i < manager->model_count; i++) {
        const CardinalModelInstance *model = &manager->models[i];
        if (!model->visible || model->is_loading) continue;
        
        const CardinalScene *scene = &model->scene;
        
        // Copy meshes with transformed vertices
        for (uint32_t m = 0; m < scene->mesh_count; m++) {
            const CardinalMesh *src_mesh = &scene->meshes[m];
            CardinalMesh *dst_mesh = &manager->combined_scene.meshes[mesh_offset + m];
            
            // Validate source mesh data before copying
            if (!src_mesh->vertices || src_mesh->vertex_count == 0 || 
                !src_mesh->indices || src_mesh->index_count == 0 ||
                src_mesh->index_count > 1000000000) { // Sanity check for corrupted data
                CARDINAL_LOG_ERROR("Skipping corrupted mesh %u in model %u: vertices=%p, vertex_count=%u, indices=%p, index_count=%u",
                                   m, i, (void*)src_mesh->vertices, src_mesh->vertex_count, (void*)src_mesh->indices, src_mesh->index_count);
                // Initialize empty mesh to prevent further corruption
                memset(dst_mesh, 0, sizeof(CardinalMesh));
                dst_mesh->visible = false;
                continue;
            }
            
            // Copy mesh data (safe now that we've validated)
            *dst_mesh = *src_mesh;
            dst_mesh->material_index += material_offset; // Adjust material index
            
            // Copy and transform vertices
            dst_mesh->vertices = (CardinalVertex*)malloc(src_mesh->vertex_count * sizeof(CardinalVertex));
            if (dst_mesh->vertices) {
                for (uint32_t v = 0; v < src_mesh->vertex_count; v++) {
                    dst_mesh->vertices[v] = src_mesh->vertices[v];
                    
                    // Transform position
                    float position[3] = {src_mesh->vertices[v].px, src_mesh->vertices[v].py, src_mesh->vertices[v].pz};
                    float transformed[3];
                    cardinal_transform_point(model->transform, position, transformed);
                    
                    dst_mesh->vertices[v].px = transformed[0];
                    dst_mesh->vertices[v].py = transformed[1];
                    dst_mesh->vertices[v].pz = transformed[2];
                    
                    // Transform normal using proper normal transformation
                    float normal[3] = {src_mesh->vertices[v].nx, src_mesh->vertices[v].ny, src_mesh->vertices[v].nz};
                    float transformed_normal[3];
                    cardinal_transform_normal(model->transform, normal, transformed_normal);
                    
                    dst_mesh->vertices[v].nx = transformed_normal[0];
                    dst_mesh->vertices[v].ny = transformed_normal[1];
                    dst_mesh->vertices[v].nz = transformed_normal[2];
                }
            }
            
            // Copy indices with additional validation
            if (src_mesh->indices && src_mesh->index_count > 0 && src_mesh->index_count < 1000000000) {
                dst_mesh->indices = (uint32_t*)malloc(src_mesh->index_count * sizeof(uint32_t));
                if (dst_mesh->indices) {
                    memcpy(dst_mesh->indices, src_mesh->indices, src_mesh->index_count * sizeof(uint32_t));
                } else {
                    CARDINAL_LOG_ERROR("Failed to allocate memory for indices in mesh %u", m);
                    dst_mesh->index_count = 0;
                }
            } else {
                CARDINAL_LOG_ERROR("Invalid indices data for mesh %u: indices=%p, count=%u", m, (void*)src_mesh->indices, src_mesh->index_count);
                dst_mesh->indices = NULL;
                dst_mesh->index_count = 0;
            }
        }
        
        // Deep copy materials
        if (scene->materials) {
            for (uint32_t mat = 0; mat < scene->material_count; mat++) {
                const CardinalMaterial *src_material = &scene->materials[mat];
                CardinalMaterial *dst_material = &manager->combined_scene.materials[material_offset + mat];
                
                // Copy material structure
                *dst_material = *src_material;
                
                // Adjust texture indices to point to correct textures in combined scene
                if (dst_material->albedo_texture != UINT32_MAX) {
                    dst_material->albedo_texture += texture_offset;
                }
                if (dst_material->normal_texture != UINT32_MAX) {
                    dst_material->normal_texture += texture_offset;
                }
                if (dst_material->metallic_roughness_texture != UINT32_MAX) {
                    dst_material->metallic_roughness_texture += texture_offset;
                }
                if (dst_material->ao_texture != UINT32_MAX) {
                    dst_material->ao_texture += texture_offset;
                }
                if (dst_material->emissive_texture != UINT32_MAX) {
                    dst_material->emissive_texture += texture_offset;
                }
                
                // Acquire reference to shared material resource if it exists
                if (src_material->ref_resource && src_material->ref_resource->identifier) {
                    dst_material->ref_resource = cardinal_ref_acquire(src_material->ref_resource->identifier);
                }
            }
        }
        
        // Deep copy textures
        if (scene->textures) {
            for (uint32_t tex = 0; tex < scene->texture_count; tex++) {
                const CardinalTexture *src_texture = &scene->textures[tex];
                CardinalTexture *dst_texture = &manager->combined_scene.textures[texture_offset + tex];
                
                // Copy texture structure
                *dst_texture = *src_texture;
                
                // Deep copy texture data
                if (src_texture->data && src_texture->width > 0 && src_texture->height > 0) {
                    size_t data_size = src_texture->width * src_texture->height * src_texture->channels;
                    dst_texture->data = (unsigned char*)malloc(data_size);
                    if (dst_texture->data) {
                        memcpy(dst_texture->data, src_texture->data, data_size);
                    }
                }
                
                // Deep copy path string
                if (src_texture->path) {
                    size_t path_len = strlen(src_texture->path) + 1;
                    dst_texture->path = (char*)malloc(path_len);
                    if (dst_texture->path) {
                        strcpy(dst_texture->path, src_texture->path);
                    }
                }
                
                // Acquire reference to shared texture resource if it exists
                if (src_texture->ref_resource && src_texture->ref_resource->identifier) {
                    dst_texture->ref_resource = cardinal_ref_acquire(src_texture->ref_resource->identifier);
                }
            }
        }
        
        mesh_offset += scene->mesh_count;
        material_offset += scene->material_count;
        texture_offset += scene->texture_count;
    }
    
    manager->combined_scene.mesh_count = total_meshes;
    manager->combined_scene.material_count = total_materials;
    manager->combined_scene.texture_count = total_textures;
    
    manager->scene_dirty = false;
    
    CARDINAL_LOG_DEBUG("Rebuilt combined scene: %u meshes, %u materials, %u textures",
                       total_meshes, total_materials, total_textures);
}

// =============================================================================
// Public API Implementation
// =============================================================================

bool cardinal_model_manager_init(CardinalModelManager *manager) {
    if (!manager) return false;
    
    memset(manager, 0, sizeof(CardinalModelManager));
    manager->next_id = 1; // Start IDs from 1 (0 means no selection)
    manager->scene_dirty = true;
    
    CARDINAL_LOG_DEBUG("Model manager initialized");
    return true;
}

void cardinal_model_manager_destroy(CardinalModelManager *manager) {
    if (!manager) return;
    
    // Destroy all models
    for (uint32_t i = 0; i < manager->model_count; i++) {
        CardinalModelInstance *model = &manager->models[i];
        
        free(model->name);
        free(model->file_path);
        cardinal_scene_destroy(&model->scene);
        
        if (model->load_task) {
            cardinal_async_free_task(model->load_task);
        }
    }
    
    free(manager->models);
    cardinal_scene_destroy(&manager->combined_scene);
    
    memset(manager, 0, sizeof(CardinalModelManager));
    CARDINAL_LOG_DEBUG("Model manager destroyed");
}

uint32_t cardinal_model_manager_load_model(CardinalModelManager *manager,
                                           const char *file_path,
                                           const char *name) {
    if (!manager || !file_path) return 0;
    
    // Expand array if needed
    if (manager->model_count >= manager->model_capacity) {
        if (!expand_models_array(manager)) {
            return 0;
        }
    }
    
    // Get the new model slot
    CardinalModelInstance *model = &manager->models[manager->model_count];
    memset(model, 0, sizeof(CardinalModelInstance));
    
    // Set basic properties
    model->id = manager->next_id++;
    model->file_path = (char*)malloc(strlen(file_path) + 1);
    if (model->file_path) {
        strcpy(model->file_path, file_path);
    }
    
    model->name = name ? (char*)malloc(strlen(name) + 1) : generate_model_name(file_path);
    if (model->name && name) {
        strcpy(model->name, name);
    }
    
    // Initialize transform to identity
    cardinal_matrix_identity(model->transform);
    model->visible = true;
    model->selected = false;
    model->is_loading = false;
    
    // Load the scene
    if (!cardinal_scene_load(file_path, &model->scene)) {
        CARDINAL_LOG_ERROR("Failed to load model from %s", file_path);
        free(model->name);
        free(model->file_path);
        return 0;
    }
    
    // Calculate bounding box
    calculate_scene_bounds(&model->scene, model->bbox_min, model->bbox_max);
    
    manager->model_count++;
    manager->scene_dirty = true;
    
    CARDINAL_LOG_INFO("Loaded model '%s' from %s (ID: %u, %u meshes)",
                      model->name ? model->name : "Unnamed", file_path, model->id, model->scene.mesh_count);
    
    return model->id;
}

uint32_t cardinal_model_manager_load_model_async(CardinalModelManager *manager,
                                                  const char *file_path,
                                                  const char *name,
                                                  int priority) {
    if (!manager || !file_path) return 0;
    
    // Expand array if needed
    if (manager->model_count >= manager->model_capacity) {
        if (!expand_models_array(manager)) {
            return 0;
        }
    }
    
    // Get the new model slot
    CardinalModelInstance *model = &manager->models[manager->model_count];
    memset(model, 0, sizeof(CardinalModelInstance));
    
    // Set basic properties
    model->id = manager->next_id++;
    model->file_path = (char*)malloc(strlen(file_path) + 1);
    if (model->file_path) {
        strcpy(model->file_path, file_path);
    }
    
    model->name = name ? (char*)malloc(strlen(name) + 1) : generate_model_name(file_path);
    if (model->name && name) {
        strcpy(model->name, name);
    }
    
    // Initialize transform to identity
    cardinal_matrix_identity(model->transform);
    model->visible = true;
    model->selected = false;
    model->is_loading = true;
    
    // Start async loading
    model->load_task = cardinal_async_load_scene(file_path, priority, NULL, NULL);
    if (!model->load_task) {
        CARDINAL_LOG_ERROR("Failed to start async loading for %s", file_path);
        free(model->name);
        free(model->file_path);
        return 0;
    }
    
    manager->model_count++;
    
    CARDINAL_LOG_INFO("Started async loading of model '%s' from %s (ID: %u)",
                      model->name ? model->name : "Unnamed", file_path, model->id);
    
    return model->id;
}

uint32_t cardinal_model_manager_add_scene(CardinalModelManager *manager,
                                           CardinalScene *scene,
                                           const char *file_path,
                                           const char *name) {
    if (!manager || !scene) return 0;
    
    // Expand array if needed
    if (manager->model_count >= manager->model_capacity) {
        if (!expand_models_array(manager)) {
            return 0;
        }
    }
    
    // Get the new model slot
    CardinalModelInstance *model = &manager->models[manager->model_count];
    memset(model, 0, sizeof(CardinalModelInstance));
    
    // Set basic properties
    model->id = manager->next_id++;
    
    if (file_path) {
        model->file_path = (char*)malloc(strlen(file_path) + 1);
        if (model->file_path) {
            strcpy(model->file_path, file_path);
        }
    }
    
    model->name = name ? (char*)malloc(strlen(name) + 1) : (file_path ? generate_model_name(file_path) : NULL);
    if (model->name && name) {
        strcpy(model->name, name);
    }
    
    // Initialize transform to identity
    cardinal_matrix_identity(model->transform);
    model->visible = true;
    model->selected = false;
    model->is_loading = false;
    model->load_task = NULL;
    
    // Move the scene data (take ownership)
    model->scene = *scene;
    memset(scene, 0, sizeof(CardinalScene)); // Clear the source to prevent double-free
    
    // Calculate bounding box
    calculate_scene_bounds(&model->scene, model->bbox_min, model->bbox_max);
    
    manager->model_count++;
    manager->scene_dirty = true;
    
    CARDINAL_LOG_INFO("Added scene '%s' to model manager (ID: %u, %u meshes)",
                      model->name ? model->name : "Unnamed", model->id, model->scene.mesh_count);
    
    return model->id;
}

bool cardinal_model_manager_remove_model(CardinalModelManager *manager, uint32_t model_id) {
    if (!manager) return false;
    
    int index = find_model_index(manager, model_id);
    if (index < 0) return false;
    
    CardinalModelInstance *model = &manager->models[index];
    
    CARDINAL_LOG_INFO("Removing model '%s' (ID: %u)", model->name ? model->name : "Unnamed", model_id);
    
    // Clean up model resources
    free(model->name);
    free(model->file_path);
    cardinal_scene_destroy(&model->scene);
    
    if (model->load_task) {
        cardinal_async_free_task(model->load_task);
    }
    
    // Move remaining models down
    for (uint32_t i = index; i < manager->model_count - 1; i++) {
        manager->models[i] = manager->models[i + 1];
    }
    
    manager->model_count--;
    manager->scene_dirty = true;
    
    // Clear selection if this model was selected
    if (manager->selected_model_id == model_id) {
        manager->selected_model_id = 0;
    }
    
    return true;
}

CardinalModelInstance *cardinal_model_manager_get_model(CardinalModelManager *manager, uint32_t model_id) {
    if (!manager) return NULL;
    
    int index = find_model_index(manager, model_id);
    return index >= 0 ? &manager->models[index] : NULL;
}

CardinalModelInstance *cardinal_model_manager_get_model_by_index(CardinalModelManager *manager, uint32_t index) {
    if (!manager || index >= manager->model_count) return NULL;
    
    return &manager->models[index];
}

bool cardinal_model_manager_set_transform(CardinalModelManager *manager,
                                          uint32_t model_id,
                                          const float *transform) {
    if (!manager || !transform) return false;
    
    CardinalModelInstance *model = cardinal_model_manager_get_model(manager, model_id);
    if (!model) return false;
    
    memcpy(model->transform, transform, 16 * sizeof(float));
    manager->scene_dirty = true;
    
    return true;
}

const float *cardinal_model_manager_get_transform(CardinalModelManager *manager, uint32_t model_id) {
    CardinalModelInstance *model = cardinal_model_manager_get_model(manager, model_id);
    return model ? model->transform : NULL;
}

bool cardinal_model_manager_set_visible(CardinalModelManager *manager,
                                        uint32_t model_id,
                                        bool visible) {
    if (!manager) return false;
    
    CardinalModelInstance *model = cardinal_model_manager_get_model(manager, model_id);
    if (!model) return false;
    
    if (model->visible != visible) {
        model->visible = visible;
        manager->scene_dirty = true;
    }
    
    return true;
}

void cardinal_model_manager_set_selected(CardinalModelManager *manager, uint32_t model_id) {
    if (!manager) return;
    
    // Clear previous selection
    if (manager->selected_model_id != 0) {
        CardinalModelInstance *prev_selected = cardinal_model_manager_get_model(manager, manager->selected_model_id);
        if (prev_selected) {
            prev_selected->selected = false;
        }
    }
    
    // Set new selection
    manager->selected_model_id = model_id;
    if (model_id != 0) {
        CardinalModelInstance *model = cardinal_model_manager_get_model(manager, model_id);
        if (model) {
            model->selected = true;
        }
    }
}

const CardinalScene *cardinal_model_manager_get_combined_scene(CardinalModelManager *manager) {
    if (!manager) return NULL;
    
    if (manager->scene_dirty) {
        rebuild_combined_scene(manager);
    }
    
    return &manager->combined_scene;
}

void cardinal_model_manager_mark_dirty(CardinalModelManager *manager) {
    if (manager) {
        manager->scene_dirty = true;
    }
}

void cardinal_model_manager_update(CardinalModelManager *manager) {
    if (!manager) return;
    
    // Process async loading tasks
    for (uint32_t i = 0; i < manager->model_count; i++) {
        CardinalModelInstance *model = &manager->models[i];
        
        if (model->is_loading && model->load_task) {
            CardinalAsyncStatus status = cardinal_async_get_task_status(model->load_task);
            
            if (status == CARDINAL_ASYNC_STATUS_COMPLETED) {
                // Loading completed successfully
                if (cardinal_async_get_scene_result(model->load_task, &model->scene)) {
                    calculate_scene_bounds(&model->scene, model->bbox_min, model->bbox_max);
                    model->is_loading = false;
                    manager->scene_dirty = true;
                    
                    CARDINAL_LOG_INFO("Async loading completed for model '%s' (ID: %u, %u meshes)",
                                      model->name ? model->name : "Unnamed", model->id, model->scene.mesh_count);
                } else {
                    CARDINAL_LOG_ERROR("Failed to get scene result for model '%s'", model->name ? model->name : "Unnamed");
                }
                
                cardinal_async_free_task(model->load_task);
                model->load_task = NULL;
            } else if (status == CARDINAL_ASYNC_STATUS_FAILED) {
                // Loading failed
                const char *error_msg = cardinal_async_get_error_message(model->load_task);
                CARDINAL_LOG_ERROR("Async loading failed for model '%s': %s",
                                   model->name ? model->name : "Unnamed", error_msg ? error_msg : "Unknown error");
                
                cardinal_async_free_task(model->load_task);
                model->load_task = NULL;
                model->is_loading = false;
            }
        }
    }
}

uint32_t cardinal_model_manager_get_model_count(const CardinalModelManager *manager) {
    if (!manager) return 0;
    
    uint32_t count = 0;
    for (uint32_t i = 0; i < manager->model_count; i++) {
        if (!manager->models[i].is_loading) {
            count++;
        }
    }
    return count;
}

uint32_t cardinal_model_manager_get_total_mesh_count(const CardinalModelManager *manager) {
    if (!manager) return 0;
    
    uint32_t total = 0;
    for (uint32_t i = 0; i < manager->model_count; i++) {
        if (!manager->models[i].is_loading) {
            total += manager->models[i].scene.mesh_count;
        }
    }
    return total;
}

void cardinal_model_manager_clear(CardinalModelManager *manager) {
    if (!manager) return;
    
    CARDINAL_LOG_INFO("Clearing all models from manager");
    
    // Destroy all models
    for (uint32_t i = 0; i < manager->model_count; i++) {
        CardinalModelInstance *model = &manager->models[i];
        
        free(model->name);
        free(model->file_path);
        cardinal_scene_destroy(&model->scene);
        
        if (model->load_task) {
            cardinal_async_free_task(model->load_task);
        }
    }
    
    manager->model_count = 0;
    manager->selected_model_id = 0;
    manager->scene_dirty = true;
    
    // Clear combined scene
    cardinal_scene_destroy(&manager->combined_scene);
    memset(&manager->combined_scene, 0, sizeof(CardinalScene));
}