#ifndef CARDINAL_ASSETS_MATERIAL_REF_COUNTING_H
#define CARDINAL_ASSETS_MATERIAL_REF_COUNTING_H

#include "cardinal/assets/scene.h"
#include "cardinal/core/ref_counting.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Material hash structure for reference counting
 *
 * Used to generate unique identifiers for materials based on their properties.
 * This allows materials with identical properties to be shared across meshes.
 */
typedef struct CardinalMaterialHash {
  uint64_t texture_hash;   /**< Hash of texture indices */
  uint64_t factor_hash;    /**< Hash of material factors */
  uint64_t transform_hash; /**< Hash of texture transforms */
} CardinalMaterialHash;

/**
 * @brief Initialize the material reference counting system
 *
 * Must be called before using any material reference counting functions.
 *
 * @return true on success, false on failure
 */
bool cardinal_material_ref_init(void);

/**
 * @brief Shutdown the material reference counting system
 *
 * Cleans up all material references and frees associated memory.
 */
void cardinal_material_ref_shutdown(void);

/**
 * @brief Generate a hash for a material
 *
 * Creates a unique hash based on the material's properties that can be used
 * as an identifier for reference counting.
 *
 * @param material Pointer to the material to hash
 * @return Material hash structure
 */
CardinalMaterialHash
cardinal_material_generate_hash(const CardinalMaterial *material);

/**
 * @brief Convert material hash to string identifier
 *
 * Converts a material hash to a string that can be used as a key in the
 * reference counting system.
 *
 * @param hash Material hash to convert
 * @param buffer Buffer to store the string (must be at least 64 characters)
 * @return Pointer to the buffer containing the string identifier
 */
char *cardinal_material_hash_to_string(const CardinalMaterialHash *hash,
                                       char *buffer);

/**
 * @brief Load or acquire a reference counted material
 *
 * Attempts to find an existing material with the same properties in the
 * reference counting registry. If found, increments its reference count.
 * If not found, creates a new reference counted material.
 *
 * @param material Pointer to the material data
 * @param out_material Pointer to store the material data
 * @return Pointer to reference counted resource, or NULL on failure
 */
CardinalRefCountedResource *
cardinal_material_load_with_ref_counting(const CardinalMaterial *material,
                                         CardinalMaterial *out_material);

/**
 * @brief Release a reference counted material
 *
 * Decrements the reference count and frees the material if no more references
 * exist.
 *
 * @param ref_resource Reference counted material resource
 */
void cardinal_material_release_ref_counted(
    CardinalRefCountedResource *ref_resource);

/**
 * @brief Destructor function for reference counted materials
 *
 * Called automatically when a material's reference count reaches zero.
 * Frees the material data.
 *
 * @param resource Pointer to the material resource to free
 */
void cardinal_material_destructor(void *resource);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_MATERIAL_REF_COUNTING_H
