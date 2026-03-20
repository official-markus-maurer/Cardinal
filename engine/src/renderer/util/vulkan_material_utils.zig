//! PBR material helpers.
//!
//! Prepares per-draw push constants from scene materials and resolves bindless texture indices.
const std = @import("std");
const types = @import("../vulkan_types.zig");
const handles = @import("../../core/handles.zig");
const log = @import("../../core/log.zig");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("vulkan/vulkan.h");
});

const mat_utils_log = log.ScopedLogger("MAT_UTILS");

/// Bits per UV slot packed into `PBRPushConstants.packedInfo`.
const PACKEDINFO_UV_BITS_PER_SLOT: u32 = 3;
/// Mask for a single UV slot value.
const PACKEDINFO_UV_SLOT_MASK: u32 = 0x7;
/// Mask for the UV field stored in the low 16 bits.
const PACKEDINFO_UV_FIELD_MASK: u32 = 0xFFFF;
/// Bit shift for the flags field stored in the high 16 bits.
const PACKEDINFO_FLAGS_SHIFT: u32 = 16;
/// Mask for `alpha_mode` bits stored in the flags field.
const PACKEDINFO_ALPHA_MODE_MASK: u32 = 0x3;
/// Flag bit indicating textures are present.
const PACKEDINFO_FLAG_HAS_TEXTURES: u32 = 1 << 3;

fn set_default_material_properties(pushConstants: *types.PBRPushConstants, hasTextures: bool) void {
    pushConstants.albedoFactor[0] = 1.0;
    pushConstants.albedoFactor[1] = 1.0;
    pushConstants.albedoFactor[2] = 1.0;
    pushConstants.albedoFactor[3] = 1.0;
    pushConstants.metallicNormalAO[0] = 0.0;
    pushConstants.metallicNormalAO[1] = 1.0;
    pushConstants.metallicNormalAO[2] = 1.0;
    pushConstants.metallicNormalAO[3] = 0.5;
    pushConstants.emissiveFactor[0] = 0.0;
    pushConstants.emissiveFactor[1] = 0.0;
    pushConstants.emissiveFactor[2] = 0.0;
    pushConstants.emissiveStrength = 1.0;
    pushConstants.roughnessFactor = 0.5;

    pushConstants.packedInfo = 0;

    pushConstants.albedoTextureIndex = c.UINT32_MAX;
    pushConstants.normalTextureIndex = c.UINT32_MAX;
    pushConstants.metallicRoughnessTextureIndex = c.UINT32_MAX;
    pushConstants.aoTextureIndex = c.UINT32_MAX;
    pushConstants.emissiveTextureIndex = c.UINT32_MAX;

    _ = hasTextures;

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        pushConstants.textureTransforms[i][0] = 0.0;
        pushConstants.textureTransforms[i][1] = 0.0;
        pushConstants.textureTransforms[i][2] = 1.0;
        pushConstants.textureTransforms[i][3] = 1.0;
        pushConstants.textureRotations[i] = 0.0;
    }
}

/// Resolves a scene texture handle into a bindless pool index when available.
pub fn resolve_texture_index(textureHandle: handles.TextureHandle, manager: ?*const types.VulkanTextureManager) u32 {
    if (manager == null or !textureHandle.is_valid()) {
        return c.UINT32_MAX;
    }

    const textureIndex = textureHandle.index;

    const mappedIndex = if (manager.?.hasPlaceholder) (textureIndex + 1) else textureIndex;

    if (mappedIndex < manager.?.textureCount) {
        const tex = &manager.?.textures.?[mappedIndex];

        if (tex.bindless_index != c.UINT32_MAX) {
            const pool = &manager.?.bindless_pool;
            if (pool.textures != null and tex.bindless_index < pool.max_textures) {
                const bt = &pool.textures.?[tex.bindless_index];
                if (bt.is_allocated and bt.image_view != null and bt.sampler != null) {
                    return tex.bindless_index;
                }
            }
        }
    }

    if (manager.?.hasPlaceholder and manager.?.textures != null and manager.?.textureCount > 0 and manager.?.textures.?[0].bindless_index != c.UINT32_MAX) {
        const placeholder = manager.?.textures.?[0].bindless_index;
        const pool = &manager.?.bindless_pool;
        if (pool.textures != null and placeholder < pool.max_textures) {
            const bt = &pool.textures.?[placeholder];
            if (bt.is_allocated and bt.image_view != null and bt.sampler != null) {
                return placeholder;
            }
        }
    }

    return c.UINT32_MAX;
}

fn set_texture_indices(pushConstants: *types.PBRPushConstants, material: *const types.CardinalMaterial, manager: ?*const types.VulkanTextureManager) void {
    pushConstants.albedoTextureIndex = resolve_texture_index(material.albedo_texture, manager);
    pushConstants.normalTextureIndex = resolve_texture_index(material.normal_texture, manager);
    pushConstants.metallicRoughnessTextureIndex = resolve_texture_index(material.metallic_roughness_texture, manager);
    pushConstants.aoTextureIndex = resolve_texture_index(material.ao_texture, manager);
    pushConstants.emissiveTextureIndex = resolve_texture_index(material.emissive_texture, manager);
}

fn set_texture_transforms(pushConstants: *types.PBRPushConstants, material: *const types.CardinalMaterial) void {
    pushConstants.textureTransforms[0][0] = material.albedo_transform.offset[0];
    pushConstants.textureTransforms[0][1] = material.albedo_transform.offset[1];
    pushConstants.textureTransforms[0][2] = material.albedo_transform.scale[0];
    pushConstants.textureTransforms[0][3] = material.albedo_transform.scale[1];
    pushConstants.textureRotations[0] = material.albedo_transform.rotation;

    pushConstants.textureTransforms[1][0] = material.normal_transform.offset[0];
    pushConstants.textureTransforms[1][1] = material.normal_transform.offset[1];
    pushConstants.textureTransforms[1][2] = material.normal_transform.scale[0];
    pushConstants.textureTransforms[1][3] = material.normal_transform.scale[1];
    pushConstants.textureRotations[1] = material.normal_transform.rotation;

    pushConstants.textureTransforms[2][0] = material.metallic_roughness_transform.offset[0];
    pushConstants.textureTransforms[2][1] = material.metallic_roughness_transform.offset[1];
    pushConstants.textureTransforms[2][2] = material.metallic_roughness_transform.scale[0];
    pushConstants.textureTransforms[2][3] = material.metallic_roughness_transform.scale[1];
    pushConstants.textureRotations[2] = material.metallic_roughness_transform.rotation;

    pushConstants.textureTransforms[3][0] = material.ao_transform.offset[0];
    pushConstants.textureTransforms[3][1] = material.ao_transform.offset[1];
    pushConstants.textureTransforms[3][2] = material.ao_transform.scale[0];
    pushConstants.textureTransforms[3][3] = material.ao_transform.scale[1];
    pushConstants.textureRotations[3] = material.ao_transform.rotation;

    pushConstants.textureTransforms[4][0] = material.emissive_transform.offset[0];
    pushConstants.textureTransforms[4][1] = material.emissive_transform.offset[1];
    pushConstants.textureTransforms[4][2] = material.emissive_transform.scale[0];
    pushConstants.textureTransforms[4][3] = material.emissive_transform.scale[1];
    pushConstants.textureRotations[4] = material.emissive_transform.rotation;
}

fn set_material_properties(pushConstants: *types.PBRPushConstants, material: *const types.CardinalMaterial) void {
    @memcpy(pushConstants.albedoFactor[0..4], material.albedo_factor[0..4]);
    @memcpy(pushConstants.emissiveFactor[0..3], material.emissive_factor[0..3]);
    pushConstants.emissiveStrength = material.emissive_strength;
    pushConstants.roughnessFactor = material.roughness_factor;
    pushConstants.metallicNormalAO[0] = material.metallic_factor;
    pushConstants.metallicNormalAO[1] = material.normal_scale;
    pushConstants.metallicNormalAO[2] = material.ao_strength;
    pushConstants.metallicNormalAO[3] = material.alpha_cutoff;

    var flags: u32 = 0;
    flags |= (@as(u32, @bitCast(@intFromEnum(material.alpha_mode))) & PACKEDINFO_ALPHA_MODE_MASK);

    var packedUVs: u32 = 0;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const slot = @as(u32, material.uv_indices[i]) & PACKEDINFO_UV_SLOT_MASK;
        const shift: u5 = @intCast(PACKEDINFO_UV_BITS_PER_SLOT * i);
        packedUVs |= slot << shift;
    }

    pushConstants.packedInfo = (flags << PACKEDINFO_FLAGS_SHIFT) | (packedUVs & PACKEDINFO_UV_FIELD_MASK);
}

pub export fn vk_material_setup_push_constants(pushConstants: ?*types.PBRPushConstants, mesh: ?*const types.CardinalMesh, scene: ?*const types.CardinalScene, textureManager: ?*const types.VulkanTextureManager) callconv(.c) void {
    if (pushConstants == null or mesh == null or scene == null) {
        return;
    }

    const pc = pushConstants.?;
    const m = mesh.?;
    const s = scene.?;

    @memcpy(@as([*]u8, @ptrCast(&pc.modelMatrix))[0..64], @as([*]const u8, @ptrCast(&m.transform))[0..64]);

    const hasTextures = (textureManager != null and textureManager.?.textureCount > 0);

    if (m.material_index < s.material_count) {
        const material = &s.materials.?[m.material_index];

        set_material_properties(pc, material);
        set_texture_indices(pc, material, textureManager);
        set_texture_transforms(pc, material);

        if (hasTextures) {
            pc.packedInfo |= (PACKEDINFO_FLAG_HAS_TEXTURES << PACKEDINFO_FLAGS_SHIFT);
        }
    } else {
        set_default_material_properties(pc, hasTextures);
    }
}
