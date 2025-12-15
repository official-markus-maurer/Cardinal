/**
 * @file vulkan_material_utils.c
 * @brief Implementation of material utility functions
 */

#include <cardinal/renderer/util/vulkan_material_utils.h>
#include <cardinal/renderer/vulkan_texture_manager.h>
#include <string.h>

static void set_default_material_properties(PBRPushConstants* pushConstants, bool hasTextures) {
    pushConstants->albedoFactor[0] = pushConstants->albedoFactor[1] =
        pushConstants->albedoFactor[2] = 1.0f;
    pushConstants->metallicFactor = 0.0f;
    pushConstants->emissiveFactor[0] = pushConstants->emissiveFactor[1] =
        pushConstants->emissiveFactor[2] = 0.0f;
    pushConstants->roughnessFactor = 0.5f;
    pushConstants->normalScale = 1.0f;
    pushConstants->aoStrength = 1.0f;

    pushConstants->albedoTextureIndex = UINT32_MAX;
    pushConstants->normalTextureIndex = UINT32_MAX;
    pushConstants->metallicRoughnessTextureIndex = UINT32_MAX;
    pushConstants->aoTextureIndex = UINT32_MAX;
    pushConstants->emissiveTextureIndex = UINT32_MAX;

    pushConstants->supportsDescriptorIndexing = hasTextures ? 1u : 0u;

    // Default texture transforms (identity)
    pushConstants->albedoTransform.scale[0] = pushConstants->albedoTransform.scale[1] = 1.0f;
    pushConstants->normalTransform.scale[0] = pushConstants->normalTransform.scale[1] = 1.0f;
    pushConstants->metallicRoughnessTransform.scale[0] =
        pushConstants->metallicRoughnessTransform.scale[1] = 1.0f;
    pushConstants->aoTransform.scale[0] = pushConstants->aoTransform.scale[1] = 1.0f;
    pushConstants->emissiveTransform.scale[0] = pushConstants->emissiveTransform.scale[1] = 1.0f;

    // Set default offsets and rotations to zero
    pushConstants->albedoTransform.offset[0] = pushConstants->albedoTransform.offset[1] = 0.0f;
    pushConstants->normalTransform.offset[0] = pushConstants->normalTransform.offset[1] = 0.0f;
    pushConstants->metallicRoughnessTransform.offset[0] =
        pushConstants->metallicRoughnessTransform.offset[1] = 0.0f;
    pushConstants->aoTransform.offset[0] = pushConstants->aoTransform.offset[1] = 0.0f;
    pushConstants->emissiveTransform.offset[0] = pushConstants->emissiveTransform.offset[1] = 0.0f;

    pushConstants->albedoTransform.rotation = 0.0f;
    pushConstants->normalTransform.rotation = 0.0f;
    pushConstants->metallicRoughnessTransform.rotation = 0.0f;
    pushConstants->aoTransform.rotation = 0.0f;
    pushConstants->emissiveTransform.rotation = 0.0f;
}

static uint32_t resolve_texture_index(uint32_t textureIndex, bool hasTextures,
                                      uint32_t textureCount, bool hasPlaceholder) {
    if (textureIndex == UINT32_MAX) {
        return UINT32_MAX;
    }

    // Map GLTF index to Manager index
    // If we have a placeholder at index 0, real textures start at index 1
    uint32_t mappedIndex = hasPlaceholder ? (textureIndex + 1) : textureIndex;

    if (hasTextures && mappedIndex < textureCount) {
        return mappedIndex;
    }

    // Fallback to placeholder if available and requested texture is missing/invalid
    // FIX: Do NOT fallback to placeholder (index 0) if the texture is missing.
    // Returning 0 (white texture) breaks normal maps (creates diagonal normals) and
    // messes up other material properties. Returning UINT32_MAX tells the shader
    // to use the material factors instead.
    /*
    if (hasPlaceholder) {
        return 0;
    }
    */

    return UINT32_MAX;
}

static void set_texture_indices(PBRPushConstants* pushConstants, const CardinalMaterial* material,
                                bool hasTextures, uint32_t textureCount, bool hasPlaceholder) {
    pushConstants->albedoTextureIndex =
        resolve_texture_index(material->albedo_texture, hasTextures, textureCount, hasPlaceholder);
    pushConstants->normalTextureIndex =
        resolve_texture_index(material->normal_texture, hasTextures, textureCount, hasPlaceholder);
    pushConstants->metallicRoughnessTextureIndex = resolve_texture_index(
        material->metallic_roughness_texture, hasTextures, textureCount, hasPlaceholder);
    pushConstants->aoTextureIndex =
        resolve_texture_index(material->ao_texture, hasTextures, textureCount, hasPlaceholder);
    pushConstants->emissiveTextureIndex = resolve_texture_index(
        material->emissive_texture, hasTextures, textureCount, hasPlaceholder);
}

static void set_texture_transforms(PBRPushConstants* pushConstants,
                                   const CardinalMaterial* material) {
    // Albedo
    memcpy(pushConstants->albedoTransform.offset, material->albedo_transform.offset,
           sizeof(float) * 2);
    memcpy(pushConstants->albedoTransform.scale, material->albedo_transform.scale,
           sizeof(float) * 2);
    pushConstants->albedoTransform.rotation = material->albedo_transform.rotation;

    // Normal
    memcpy(pushConstants->normalTransform.offset, material->normal_transform.offset,
           sizeof(float) * 2);
    memcpy(pushConstants->normalTransform.scale, material->normal_transform.scale,
           sizeof(float) * 2);
    pushConstants->normalTransform.rotation = material->normal_transform.rotation;

    // Metallic Roughness
    memcpy(pushConstants->metallicRoughnessTransform.offset,
           material->metallic_roughness_transform.offset, sizeof(float) * 2);
    memcpy(pushConstants->metallicRoughnessTransform.scale,
           material->metallic_roughness_transform.scale, sizeof(float) * 2);
    pushConstants->metallicRoughnessTransform.rotation =
        material->metallic_roughness_transform.rotation;

    // AO
    memcpy(pushConstants->aoTransform.offset, material->ao_transform.offset, sizeof(float) * 2);
    memcpy(pushConstants->aoTransform.scale, material->ao_transform.scale, sizeof(float) * 2);
    pushConstants->aoTransform.rotation = material->ao_transform.rotation;

    // Emissive
    memcpy(pushConstants->emissiveTransform.offset, material->emissive_transform.offset,
           sizeof(float) * 2);
    memcpy(pushConstants->emissiveTransform.scale, material->emissive_transform.scale,
           sizeof(float) * 2);
    pushConstants->emissiveTransform.rotation = material->emissive_transform.rotation;
}

static void set_material_properties(PBRPushConstants* pushConstants,
                                    const CardinalMaterial* material) {
    memcpy(pushConstants->albedoFactor, material->albedo_factor, sizeof(float) * 3);
    pushConstants->metallicFactor = material->metallic_factor;
    memcpy(pushConstants->emissiveFactor, material->emissive_factor, sizeof(float) * 3);
    pushConstants->roughnessFactor = material->roughness_factor;
    pushConstants->normalScale = material->normal_scale;
    pushConstants->aoStrength = material->ao_strength;
}

void vk_material_setup_push_constants(PBRPushConstants* pushConstants, const CardinalMesh* mesh,
                                      const CardinalScene* scene,
                                      const VulkanTextureManager* textureManager) {
    if (!pushConstants || !mesh || !scene) {
        return;
    }

    // Copy model matrix
    memcpy(pushConstants->modelMatrix, mesh->transform, 16 * sizeof(float));

    // Determine if textures are available
    bool hasTextures = (textureManager && textureManager->textureCount > 0);
    uint32_t textureCount = hasTextures ? textureManager->textureCount : 0;
    bool hasPlaceholder = (textureManager && textureManager->hasPlaceholder);

    // Set material properties for this mesh
    if (mesh->material_index < scene->material_count) {
        const CardinalMaterial* material = &scene->materials[mesh->material_index];

        set_material_properties(pushConstants, material);
        set_texture_indices(pushConstants, material, hasTextures, textureCount, hasPlaceholder);
        set_texture_transforms(pushConstants, material);

        // CRITICAL: Set descriptor indexing flag for shader
        pushConstants->supportsDescriptorIndexing = hasTextures ? 1u : 0u;
    } else {
        set_default_material_properties(pushConstants, hasTextures);
    }
}
