/**
 * @file model_manager.h
 * @brief Multi-model scene management for Cardinal Engine
 *
 * This module provides functionality to load, manage, and manipulate multiple
 * 3D models within a single scene. It extends the existing scene system to
 * support loading multiple separate model files, each with their own
 * transforms, visibility settings, and properties.
 *
 * Features:
 * - Load multiple models from different files
 * - Individual model transforms and visibility
 * - Efficient GPU resource management
 * - Model hierarchy and grouping
 * - Runtime model addition/removal
 *
 * @author Cardinal Engine
 * @version 1.0
 */

#ifndef CARDINAL_ASSETS_MODEL_MANAGER_H
#define CARDINAL_ASSETS_MODEL_MANAGER_H

#include "cardinal/assets/scene.h"
#include "cardinal/core/async_loader.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Represents a single loaded model instance
 *
 * Contains the loaded scene data along with instance-specific properties
 * like transform, visibility, and metadata.
 */
typedef struct CardinalModelInstance {
  char *name;          /**< User-friendly name for the model */
  char *file_path;     /**< Original file path */
  CardinalScene scene; /**< Loaded scene data */
  float transform[16]; /**< Instance transform matrix (column-major) */
  bool visible;        /**< Whether this model should be rendered */
  bool selected;       /**< Whether this model is currently selected */
  uint32_t id;         /**< Unique identifier for this instance */

  // Bounding box for culling and selection
  float bbox_min[3]; /**< Minimum bounds */
  float bbox_max[3]; /**< Maximum bounds */

  // Loading state
  bool is_loading;              /**< Whether this model is currently loading */
  CardinalAsyncTask *load_task; /**< Async loading task (if loading) */
} CardinalModelInstance;

/**
 * @brief Multi-model scene manager
 *
 * Manages a collection of loaded models, providing functionality to
 * add, remove, transform, and render multiple models efficiently.
 */
typedef struct CardinalModelManager {
  CardinalModelInstance *models; /**< Array of loaded model instances */
  uint32_t model_count;          /**< Number of loaded models */
  uint32_t model_capacity;       /**< Allocated capacity for models array */
  uint32_t next_id;              /**< Next unique ID to assign */

  // Combined scene data for rendering
  CardinalScene
      combined_scene; /**< Merged scene data for efficient rendering */
  bool scene_dirty;   /**< Whether combined scene needs rebuilding */

  // Selection and interaction
  uint32_t selected_model_id; /**< ID of currently selected model (0 = none) */
} CardinalModelManager;

// =============================================================================
// Model Manager Lifecycle
// =============================================================================

/**
 * @brief Initialize a new model manager
 *
 * Creates and initializes a new model manager with empty state.
 *
 * @param manager Pointer to model manager to initialize
 * @return true on success, false on failure
 */
bool cardinal_model_manager_init(CardinalModelManager *manager);

/**
 * @brief Destroy a model manager and free all resources
 *
 * Destroys all loaded models and frees associated memory.
 *
 * @param manager Pointer to model manager to destroy
 */
void cardinal_model_manager_destroy(CardinalModelManager *manager);

// =============================================================================
// Model Loading and Management
// =============================================================================

/**
 * @brief Load a model from file synchronously
 *
 * Loads a model file and adds it to the manager. The model is assigned
 * a unique ID and default transform.
 *
 * @param manager Pointer to model manager
 * @param file_path Path to the model file to load
 * @param name User-friendly name for the model (can be NULL for auto-naming)
 * @return Model ID on success, 0 on failure
 */
uint32_t cardinal_model_manager_load_model(CardinalModelManager *manager,
                                           const char *file_path,
                                           const char *name);

/**
 * @brief Load a model from file asynchronously
 *
 * Starts loading a model file in the background. The model will be added
 * to the manager when loading completes.
 *
 * @param manager Pointer to model manager
 * @param file_path Path to the model file to load
 * @param name User-friendly name for the model (can be NULL for auto-naming)
 * @param priority Loading priority
 * @return Model ID on success (model will be in loading state), 0 on failure
 */
uint32_t cardinal_model_manager_load_model_async(CardinalModelManager *manager,
                                                 const char *file_path,
                                                 const char *name,
                                                 int priority);

/**
 * @brief Add an already-loaded scene to the model manager
 *
 * Takes ownership of the provided scene data and adds it to the manager.
 * This is useful when you already have a loaded scene from async loading
 * and want to avoid reloading from file.
 *
 * @param manager Pointer to model manager
 * @param scene Pointer to already-loaded scene (will be moved, not copied)
 * @param file_path Original file path for reference
 * @param name User-friendly name for the model (can be NULL for auto-naming)
 * @return Model ID on success, 0 on failure
 */
uint32_t cardinal_model_manager_add_scene(CardinalModelManager *manager,
                                          CardinalScene *scene,
                                          const char *file_path,
                                          const char *name);

/**
 * @brief Remove a model from the manager
 *
 * Removes the specified model and frees its resources.
 *
 * @param manager Pointer to model manager
 * @param model_id ID of the model to remove
 * @return true on success, false if model not found
 */
bool cardinal_model_manager_remove_model(CardinalModelManager *manager,
                                         uint32_t model_id);

/**
 * @brief Get a model instance by ID
 *
 * @param manager Pointer to model manager
 * @param model_id ID of the model to retrieve
 * @return Pointer to model instance, or NULL if not found
 */
CardinalModelInstance *
cardinal_model_manager_get_model(CardinalModelManager *manager,
                                 uint32_t model_id);

/**
 * @brief Get a model instance by index
 *
 * @param manager Pointer to model manager
 * @param index Index of the model to retrieve (0-based)
 * @return Pointer to model instance, or NULL if index out of bounds
 */
CardinalModelInstance *
cardinal_model_manager_get_model_by_index(CardinalModelManager *manager,
                                          uint32_t index);

// =============================================================================
// Model Transforms and Properties
// =============================================================================

/**
 * @brief Set the transform matrix for a model
 *
 * @param manager Pointer to model manager
 * @param model_id ID of the model to transform
 * @param transform 4x4 transformation matrix (column-major)
 * @return true on success, false if model not found
 */
bool cardinal_model_manager_set_transform(CardinalModelManager *manager,
                                          uint32_t model_id,
                                          const float *transform);

/**
 * @brief Get the transform matrix for a model
 *
 * @param manager Pointer to model manager
 * @param model_id ID of the model
 * @return Pointer to transform matrix, or NULL if model not found
 */
const float *cardinal_model_manager_get_transform(CardinalModelManager *manager,
                                                  uint32_t model_id);

/**
 * @brief Set the visibility of a model
 *
 * @param manager Pointer to model manager
 * @param model_id ID of the model
 * @param visible Whether the model should be visible
 * @return true on success, false if model not found
 */
bool cardinal_model_manager_set_visible(CardinalModelManager *manager,
                                        uint32_t model_id, bool visible);

/**
 * @brief Set the selection state of a model
 *
 * @param manager Pointer to model manager
 * @param model_id ID of the model to select (0 to deselect all)
 */
void cardinal_model_manager_set_selected(CardinalModelManager *manager,
                                         uint32_t model_id);

// =============================================================================
// Scene Management
// =============================================================================

/**
 * @brief Get the combined scene for rendering
 *
 * Returns a merged scene containing all visible models, suitable for
 * uploading to the renderer. The scene is rebuilt if dirty.
 *
 * @param manager Pointer to model manager
 * @return Pointer to combined scene, or NULL on error
 */
const CardinalScene *
cardinal_model_manager_get_combined_scene(CardinalModelManager *manager);

/**
 * @brief Mark the combined scene as dirty
 *
 * Forces the combined scene to be rebuilt on next access.
 *
 * @param manager Pointer to model manager
 */
void cardinal_model_manager_mark_dirty(CardinalModelManager *manager);

/**
 * @brief Update the model manager
 *
 * Processes async loading tasks and updates internal state.
 * Should be called each frame.
 *
 * @param manager Pointer to model manager
 */
void cardinal_model_manager_update(CardinalModelManager *manager);

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * @brief Get the number of loaded models
 *
 * @param manager Pointer to model manager
 * @return Number of loaded models (excluding those currently loading)
 */
uint32_t
cardinal_model_manager_get_model_count(const CardinalModelManager *manager);

/**
 * @brief Get the total number of meshes across all models
 *
 * @param manager Pointer to model manager
 * @return Total mesh count
 */
uint32_t cardinal_model_manager_get_total_mesh_count(
    const CardinalModelManager *manager);

/**
 * @brief Clear all models from the manager
 *
 * Removes and destroys all loaded models.
 *
 * @param manager Pointer to model manager
 */
void cardinal_model_manager_clear(CardinalModelManager *manager);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_MODEL_MANAGER_H
