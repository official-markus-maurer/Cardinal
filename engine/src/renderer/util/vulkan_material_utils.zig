const std = @import("std");
const types = @import("../vulkan_types.zig");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("vulkan/vulkan.h");
});

fn set_default_material_properties(pushConstants: *types.PBRPushConstants, hasTextures: bool) void {
    pushConstants.albedoFactor[0] = 1.0;
    pushConstants.albedoFactor[1] = 1.0;
    pushConstants.albedoFactor[2] = 1.0;
    pushConstants.metallicFactor = 0.0;
    pushConstants.emissiveFactor[0] = 0.0;
    pushConstants.emissiveFactor[1] = 0.0;
    pushConstants.emissiveFactor[2] = 0.0;
    pushConstants.roughnessFactor = 0.5;
    pushConstants.normalScale = 1.0;
    pushConstants.aoStrength = 1.0;
    pushConstants.flags = 0; // OPAQUE (0) | No Skeleton (0) | No Indexing (0)
    pushConstants.alphaCutoff = 0.5;

    pushConstants.albedoTextureIndex = c.UINT32_MAX;
    pushConstants.normalTextureIndex = c.UINT32_MAX;
    pushConstants.metallicRoughnessTextureIndex = c.UINT32_MAX;
    pushConstants.aoTextureIndex = c.UINT32_MAX;
    pushConstants.emissiveTextureIndex = c.UINT32_MAX;

    if (hasTextures) {
        pushConstants.flags |= 8; // Set supportsDescriptorIndexing bit (bit 3)
    }

    // Default texture transforms (identity)
    pushConstants.albedoTransform.scale.x = 1.0;
    pushConstants.albedoTransform.scale.y = 1.0;
    pushConstants.normalTransform.scale.x = 1.0;
    pushConstants.normalTransform.scale.y = 1.0;
    pushConstants.metallicRoughnessTransform.scale.x = 1.0;
    pushConstants.metallicRoughnessTransform.scale.y = 1.0;
    pushConstants.aoTransform.scale.x = 1.0;
    pushConstants.aoTransform.scale.y = 1.0;
    pushConstants.emissiveTransform.scale.x = 1.0;
    pushConstants.emissiveTransform.scale.y = 1.0;

    // Set default offsets and rotations to zero
    pushConstants.albedoTransform.offset.x = 0.0;
    pushConstants.albedoTransform.offset.y = 0.0;
    pushConstants.normalTransform.offset.x = 0.0;
    pushConstants.normalTransform.offset.y = 0.0;
    pushConstants.metallicRoughnessTransform.offset.x = 0.0;
    pushConstants.metallicRoughnessTransform.offset.y = 0.0;
    pushConstants.aoTransform.offset.x = 0.0;
    pushConstants.aoTransform.offset.y = 0.0;
    pushConstants.emissiveTransform.offset.x = 0.0;
    pushConstants.emissiveTransform.offset.y = 0.0;

    pushConstants.albedoTransform.rotation = 0.0;
    pushConstants.normalTransform.rotation = 0.0;
    pushConstants.metallicRoughnessTransform.rotation = 0.0;
    pushConstants.aoTransform.rotation = 0.0;
    pushConstants.emissiveTransform.rotation = 0.0;
}

fn resolve_texture_index(textureIndex: u32, hasTextures: bool, textureCount: u32, hasPlaceholder: bool) u32 {
    if (textureIndex == c.UINT32_MAX) {
        return c.UINT32_MAX;
    }

    // Map GLTF index to Manager index
    // If we have a placeholder at index 0, real textures start at index 1
    const mappedIndex = if (hasPlaceholder) (textureIndex + 1) else textureIndex;

    if (hasTextures and mappedIndex < textureCount) {
        return mappedIndex;
    }

    return c.UINT32_MAX;
}

fn set_texture_indices(pushConstants: *types.PBRPushConstants, material: *const types.CardinalMaterial, hasTextures: bool, textureCount: u32, hasPlaceholder: bool) void {
    pushConstants.albedoTextureIndex = resolve_texture_index(material.albedo_texture, hasTextures, textureCount, hasPlaceholder);
    pushConstants.normalTextureIndex = resolve_texture_index(material.normal_texture, hasTextures, textureCount, hasPlaceholder);
    pushConstants.metallicRoughnessTextureIndex = resolve_texture_index(material.metallic_roughness_texture, hasTextures, textureCount, hasPlaceholder);
    pushConstants.aoTextureIndex = resolve_texture_index(material.ao_texture, hasTextures, textureCount, hasPlaceholder);
    pushConstants.emissiveTextureIndex = resolve_texture_index(material.emissive_texture, hasTextures, textureCount, hasPlaceholder);
}

fn set_texture_transforms(pushConstants: *types.PBRPushConstants, material: *const types.CardinalMaterial) void {
    // Albedo
    pushConstants.albedoTransform.offset.x = material.albedo_transform.offset[0];
    pushConstants.albedoTransform.offset.y = material.albedo_transform.offset[1];
    pushConstants.albedoTransform.scale.x = material.albedo_transform.scale[0];
    pushConstants.albedoTransform.scale.y = material.albedo_transform.scale[1];
    pushConstants.albedoTransform.rotation = material.albedo_transform.rotation;

    // Normal
    pushConstants.normalTransform.offset.x = material.normal_transform.offset[0];
    pushConstants.normalTransform.offset.y = material.normal_transform.offset[1];
    pushConstants.normalTransform.scale.x = material.normal_transform.scale[0];
    pushConstants.normalTransform.scale.y = material.normal_transform.scale[1];
    pushConstants.normalTransform.rotation = material.normal_transform.rotation;

    // Metallic Roughness
    pushConstants.metallicRoughnessTransform.offset.x = material.metallic_roughness_transform.offset[0];
    pushConstants.metallicRoughnessTransform.offset.y = material.metallic_roughness_transform.offset[1];
    pushConstants.metallicRoughnessTransform.scale.x = material.metallic_roughness_transform.scale[0];
    pushConstants.metallicRoughnessTransform.scale.y = material.metallic_roughness_transform.scale[1];
    pushConstants.metallicRoughnessTransform.rotation = material.metallic_roughness_transform.rotation;

    // AO
    pushConstants.aoTransform.offset.x = material.ao_transform.offset[0];
    pushConstants.aoTransform.offset.y = material.ao_transform.offset[1];
    pushConstants.aoTransform.scale.x = material.ao_transform.scale[0];
    pushConstants.aoTransform.scale.y = material.ao_transform.scale[1];
    pushConstants.aoTransform.rotation = material.ao_transform.rotation;

    // Emissive
    pushConstants.emissiveTransform.offset.x = material.emissive_transform.offset[0];
    pushConstants.emissiveTransform.offset.y = material.emissive_transform.offset[1];
    pushConstants.emissiveTransform.scale.x = material.emissive_transform.scale[0];
    pushConstants.emissiveTransform.scale.y = material.emissive_transform.scale[1];
    pushConstants.emissiveTransform.rotation = material.emissive_transform.rotation;
}

fn set_material_properties(pushConstants: *types.PBRPushConstants, material: *const types.CardinalMaterial) void {
    @memcpy(pushConstants.albedoFactor[0..3], material.albedo_factor[0..3]);
    pushConstants.metallicFactor = material.metallic_factor;
    @memcpy(pushConstants.emissiveFactor[0..3], material.emissive_factor[0..3]);
    pushConstants.roughnessFactor = material.roughness_factor;
    pushConstants.normalScale = material.normal_scale;
    pushConstants.aoStrength = material.ao_strength;

    // Pack flags
    pushConstants.flags = 0;
    pushConstants.flags |= (@as(u32, @intCast(@intFromEnum(material.alpha_mode))) & 3); // Bits 0-1: Alpha Mode
    // Skeleton bit (bit 2) will be set in vk_pbr_render
    // Descriptor indexing bit (bit 3) is set below

    pushConstants.alphaCutoff = material.alpha_cutoff;
}

pub export fn vk_material_setup_push_constants(pushConstants: ?*types.PBRPushConstants, mesh: ?*const types.CardinalMesh, scene: ?*const types.CardinalScene, textureManager: ?*const types.VulkanTextureManager) callconv(.c) void {
    if (pushConstants == null or mesh == null or scene == null) {
        return;
    }

    const pc = pushConstants.?;
    const m = mesh.?;
    const s = scene.?;

    // Copy model matrix
    @memcpy(@as([*]u8, @ptrCast(&pc.modelMatrix))[0..64], @as([*]const u8, @ptrCast(&m.transform))[0..64]);

    // Determine if textures are available
    const hasTextures = (textureManager != null and textureManager.?.textureCount > 0);
    const textureCount = if (hasTextures) textureManager.?.textureCount else 0;
    const hasPlaceholder = (textureManager != null and textureManager.?.hasPlaceholder);

    // Set material properties for this mesh
    if (m.material_index < s.material_count) {
        const material = &s.materials.?[m.material_index];

        set_material_properties(pc, material);
        set_texture_indices(pc, material, hasTextures, textureCount, hasPlaceholder);
        set_texture_transforms(pc, material);

        // Set descriptor indexing flag
        if (hasTextures) {
            pc.flags |= 8; // Bit 3
        }
    } else {
        set_default_material_properties(pc, hasTextures);
    }
}
