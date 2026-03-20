//! PBR pipeline shared shader-facing types.
//!
//! Structs and enums mirrored by shaders and render code for the PBR path.
const std = @import("std");
const c = @import("vulkan_c.zig").c;
const math = @import("../core/math.zig");

/// 2D texture transform used by PBR materials.
pub const PBRTextureTransform = extern struct {
    offset: math.Vec2,
    scale: math.Vec2,
    rotation: f32,
};

/// Per-frame uniform buffer used by the classic PBR vertex/fragment pipeline.
pub const PBRUniformBufferObject = extern struct {
    view: [16]f32,
    proj: [16]f32,
    viewPos: [3]f32,
    debugFlags: f32,
    ambientColor: [4]f32,
    terrainBrushPosRadius: [4]f32,
    terrainBrushParams: [4]f32,
};

/// Light type encoded by shader-friendly values.
pub const PBRLightType = enum(c_int) {
    DIRECTIONAL = 0,
    POINT = 1,
    SPOT = 2,
};

/// Push constants used by the shadow pass.
pub const ShadowPushConstants = extern struct {
    model: [16]f32,
    texture_index: u32,
    alpha_cutoff: f32,
    _pad0: [60]u8,
    packed_info: u32,
    _pad1: [16]u8,
    cascade_index: u32,
};

comptime {
    if (@sizeOf(ShadowPushConstants) != 156) @compileError("ShadowPushConstants size mismatch");
}

pub const PBRLight = extern struct {
    lightDirection: [4]f32,
    lightColor: [4]f32,
    params: [4]f32,
    lightPosition: [4]f32,
};

/// Maximum number of lights packed into `PBRLightingBuffer`.
pub const MAX_LIGHTS = 128;

/// Fixed-capacity light array used by the PBR pipeline.
pub const PBRLightingBuffer = extern struct {
    count: u32,
    _padding: [3]u32,
    lights: [MAX_LIGHTS]PBRLight,
};

/// GPU-side material parameters for PBR shading.
pub const PBRMaterialProperties = extern struct {
    albedoFactor: [4]f32,
    metallicFactor: f32,
    roughnessFactor: f32,
    emissiveFactor: [4]f32,

    normalScale: f32,
    aoStrength: f32,
    albedoTextureIndex: u32,
    normalTextureIndex: u32,
    metallicRoughnessTextureIndex: u32,
    aoTextureIndex: u32,
    emissiveTextureIndex: u32,
    supportsDescriptorIndexing: u32,
};

pub const PBRPushConstants = extern struct {
    modelMatrix: math.Mat4,
    albedoFactor: [4]f32,
    emissiveFactor: [3]f32,
    roughnessFactor: f32,
    metallicNormalAO: [4]f32,
    albedoTextureIndex: u32,
    normalTextureIndex: u32,
    metallicRoughnessTextureIndex: u32,
    aoTextureIndex: u32,
    emissiveTextureIndex: u32,
    packedInfo: u32,
    _padding: [2]u32,
    textureTransforms: [5][4]f32,
    textureRotations: [5]f32,
    emissiveStrength: f32,
    _padding_end: [2]u32,
};

pub const MeshShaderPushConstants = extern struct {
    albedoFactor: [4]f32,
    emissiveFactor: [3]f32,
    roughnessFactor: f32,
    metallicNormalAO: [4]f32,
    albedoTextureIndex: u32,
    normalTextureIndex: u32,
    metallicRoughnessTextureIndex: u32,
    aoTextureIndex: u32,
    emissiveTextureIndex: u32,
    packedInfo: u32,
    _padding: [2]u32,
    textureTransforms: [5][4]f32,
    textureRotations: [5]f32,
    emissiveStrength: f32,
    _padding_end: [2]u32,
};

pub const MeshShaderUniformBuffer = extern struct {
    model: [16]f32,
    view: [16]f32,
    proj: [16]f32,
    mvp: [16]f32,
    materialIndex: u32,
    _padding: [3]u32,
    viewPos: [4]f32,
    ambientColor: [4]f32,
    terrainBrushPosRadius: [4]f32,
    terrainBrushParams: [4]f32,
};
