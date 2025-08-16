#include "cardinal/assets/material_ref_counting.h"
#include "cardinal/core/log.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Hash function for 64-bit values (FNV-1a variant)
static uint64_t hash_64(const void* data, size_t len) {
    const uint8_t* bytes = (const uint8_t*)data;
    uint64_t hash = 14695981039346656037ULL; // FNV offset basis

    for (size_t i = 0; i < len; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL; // FNV prime
    }

    return hash;
}

bool cardinal_material_ref_init(void) {
    // Material reference counting uses the same registry as other resources
    // No additional initialization needed
    return true;
}

void cardinal_material_ref_shutdown(void) {
    // Material cleanup is handled by the main reference counting system
    // No additional cleanup needed
}

CardinalMaterialHash cardinal_material_generate_hash(const CardinalMaterial* material) {
    CardinalMaterialHash hash = {0};

    if (!material) {
        return hash;
    }

    // Hash texture indices
    uint32_t texture_indices[] = {material->albedo_texture, material->normal_texture,
                                  material->metallic_roughness_texture, material->ao_texture,
                                  material->emissive_texture};
    hash.texture_hash = hash_64(texture_indices, sizeof(texture_indices));

    // Hash material factors
    struct {
        float albedo_factor[3];
        float metallic_factor;
        float roughness_factor;
        float emissive_factor[3];
        float normal_scale;
        float ao_strength;
    } factors = {
        {  material->albedo_factor[0],   material->albedo_factor[1],   material->albedo_factor[2]},
        material->metallic_factor,
        material->roughness_factor,
        {material->emissive_factor[0], material->emissive_factor[1], material->emissive_factor[2]},
        material->normal_scale,
        material->ao_strength
    };
    hash.factor_hash = hash_64(&factors, sizeof(factors));

    // Hash texture transforms
    struct {
        CardinalTextureTransform albedo_transform;
        CardinalTextureTransform normal_transform;
        CardinalTextureTransform metallic_roughness_transform;
        CardinalTextureTransform ao_transform;
        CardinalTextureTransform emissive_transform;
    } transforms = {material->albedo_transform, material->normal_transform,
                    material->metallic_roughness_transform, material->ao_transform,
                    material->emissive_transform};
    hash.transform_hash = hash_64(&transforms, sizeof(transforms));

    return hash;
}

char* cardinal_material_hash_to_string(const CardinalMaterialHash* hash, char* buffer) {
    if (!hash || !buffer) {
        return NULL;
    }

    snprintf(buffer, 64, "mat_%016llx_%016llx_%016llx", (unsigned long long)hash->texture_hash,
             (unsigned long long)hash->factor_hash, (unsigned long long)hash->transform_hash);

    return buffer;
}

CardinalRefCountedResource* cardinal_material_load_with_ref_counting(
    const CardinalMaterial* material, CardinalMaterial* out_material) {
    if (!material || !out_material) {
        CARDINAL_LOG_ERROR(
            "cardinal_material_load_with_ref_counting: invalid args material=%p out=%p",
            (void*)material, (void*)out_material);
        return NULL;
    }

    // Generate hash for the material
    CardinalMaterialHash hash = cardinal_material_generate_hash(material);
    char hash_string[64];
    cardinal_material_hash_to_string(&hash, hash_string);

    // Try to acquire existing material from registry
    CardinalRefCountedResource* ref_resource = cardinal_ref_acquire(hash_string);
    if (ref_resource) {
        // Copy material data from existing resource
        CardinalMaterial* existing_material = (CardinalMaterial*)ref_resource->resource;
        *out_material = *existing_material;
        CARDINAL_LOG_DEBUG("[MATERIAL] Reusing cached material: %s (ref_count=%u)", hash_string,
                           cardinal_ref_get_count(ref_resource));
        return ref_resource;
    }

    // Create a copy of material data for the registry
    CardinalMaterial* material_copy = (CardinalMaterial*)malloc(sizeof(CardinalMaterial));
    if (!material_copy) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for material copy");
        return NULL;
    }
    *material_copy = *material;

    // Copy output material
    *out_material = *material;

    // Register the material in the reference counting system
    ref_resource = cardinal_ref_create(hash_string, material_copy, sizeof(CardinalMaterial),
                                       cardinal_material_destructor);
    if (!ref_resource) {
        CARDINAL_LOG_ERROR("Failed to register material in reference counting system: %s",
                           hash_string);
        free(material_copy);
        return NULL;
    }

    CARDINAL_LOG_INFO("[MATERIAL] Registered new material for sharing: %s", hash_string);
    return ref_resource;
}

void cardinal_material_release_ref_counted(CardinalRefCountedResource* ref_resource) {
    if (ref_resource) {
        cardinal_ref_release(ref_resource);
    }
}

void cardinal_material_destructor(void* resource) {
    if (resource) {
        // CardinalMaterial doesn't contain any dynamically allocated members
        // so we just need to free the material structure itself
        free(resource);
    }
}
