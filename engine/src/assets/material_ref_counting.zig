const std = @import("std");
const memory = @import("../core/memory.zig");
const ref_counting = @import("../core/ref_counting.zig");
const log = @import("../core/log.zig");
const scene = @import("scene.zig");

// --- Struct Definitions matching scene.h ---

pub const CardinalTextureTransform = scene.CardinalTextureTransform;
pub const CardinalSamplerWrap = scene.CardinalSamplerWrap;
pub const CardinalSamplerFilter = scene.CardinalSamplerFilter;
pub const CardinalSampler = scene.CardinalSampler;
pub const CardinalAlphaMode = scene.CardinalAlphaMode;
pub const CardinalMaterial = scene.CardinalMaterial;

pub const CardinalMaterialHash = extern struct {
    texture_hash: u64,
    factor_hash: u64,
    transform_hash: u64,
};

// --- Helper Functions ---

fn hash_64(data: []const u8) u64 {
    var hash: u64 = 14695981039346656037; // FNV offset basis
    const prime: u64 = 1099511628211; // FNV prime

    for (data) |byte| {
        hash ^= byte;
        hash *%= prime; // Wrapping multiplication
    }

    return hash;
}

// --- Public API ---

pub export fn cardinal_material_ref_init() callconv(.c) bool {
    // Material reference counting uses the same registry as other resources
    // No additional initialization needed
    return true;
}

pub export fn cardinal_material_ref_shutdown() callconv(.c) void {
    // Material cleanup is handled by the main reference counting system
    // No additional cleanup needed
}

pub export fn cardinal_material_generate_hash(material: ?*const CardinalMaterial) callconv(.c) CardinalMaterialHash {
    var hash = CardinalMaterialHash{
        .texture_hash = 0,
        .factor_hash = 0,
        .transform_hash = 0,
    };

    if (material == null) {
        return hash;
    }

    const mat = material.?;

    // Hash texture indices
    const texture_indices = [_]u32{
        mat.albedo_texture.index,
        mat.normal_texture.index,
        mat.metallic_roughness_texture.index,
        mat.ao_texture.index,
        mat.emissive_texture.index,
    };
    hash.texture_hash = hash_64(std.mem.asBytes(&texture_indices));

    // Hash material factors
    const Factors = extern struct {
        albedo_factor: [3]f32,
        metallic_factor: f32,
        roughness_factor: f32,
        emissive_factor: [3]f32,
        normal_scale: f32,
        ao_strength: f32,
    };
    const factors = Factors{
        .albedo_factor = mat.albedo_factor,
        .metallic_factor = mat.metallic_factor,
        .roughness_factor = mat.roughness_factor,
        .emissive_factor = mat.emissive_factor,
        .normal_scale = mat.normal_scale,
        .ao_strength = mat.ao_strength,
    };
    hash.factor_hash = hash_64(std.mem.asBytes(&factors));

    // Hash texture transforms
    const Transforms = extern struct {
        albedo_transform: CardinalTextureTransform,
        normal_transform: CardinalTextureTransform,
        metallic_roughness_transform: CardinalTextureTransform,
        ao_transform: CardinalTextureTransform,
        emissive_transform: CardinalTextureTransform,
    };
    const transforms = Transforms{
        .albedo_transform = mat.albedo_transform,
        .normal_transform = mat.normal_transform,
        .metallic_roughness_transform = mat.metallic_roughness_transform,
        .ao_transform = mat.ao_transform,
        .emissive_transform = mat.emissive_transform,
    };
    hash.transform_hash = hash_64(std.mem.asBytes(&transforms));

    return hash;
}

pub export fn cardinal_material_hash_to_string(hash: ?*const CardinalMaterialHash, buffer: ?[*:0]u8) callconv(.c) ?[*:0]u8 {
    if (hash == null or buffer == null) {
        return null;
    }

    const h = hash.?;
    // We assume the buffer is at least 64 bytes as per C API
    const buf_slice = buffer.?[0..64];
    _ = std.fmt.bufPrintZ(buf_slice, "mat_{x:0>16}_{x:0>16}_{x:0>16}", .{
        h.texture_hash,
        h.factor_hash,
        h.transform_hash,
    }) catch return null;

    return buffer;
}

pub export fn cardinal_material_destructor(resource: ?*anyopaque) callconv(.c) void {
    if (resource) |res| {
        // CardinalMaterial doesn't contain any dynamically allocated members
        // so we just need to free the material structure itself.
        // We need to use the engine allocator.
        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
        memory.cardinal_free(allocator, res);
    }
}

pub export fn cardinal_material_load_with_ref_counting(material: ?*const CardinalMaterial, out_material: ?*CardinalMaterial) callconv(.c) ?*ref_counting.CardinalRefCountedResource {
    if (material == null or out_material == null) {
        std.log.err("cardinal_material_load_with_ref_counting: invalid args", .{});
        return null;
    }

    // Generate hash
    const hash = cardinal_material_generate_hash(material);
    var hash_string: [64:0]u8 = undefined;
    _ = std.fmt.bufPrintZ(&hash_string, "mat_{x:0>16}_{x:0>16}_{x:0>16}", .{
        hash.texture_hash,
        hash.factor_hash,
        hash.transform_hash,
    }) catch {
        return null;
    };
    const hash_cstr: [*:0]const u8 = @ptrCast(&hash_string);
    const hash_slice = std.mem.span(hash_cstr);

    // Try to acquire existing material
    if (ref_counting.cardinal_ref_acquire(hash_cstr)) |ref_resource| {
        // Copy material data from existing resource
        const existing_material = @as(*CardinalMaterial, @ptrCast(@alignCast(ref_resource.resource)));
        out_material.?.* = existing_material.*;
        std.log.debug("[MATERIAL] Reusing cached material: {s} (ref_count={d})", .{ hash_slice, ref_counting.cardinal_ref_get_count(ref_resource) });
        return ref_resource;
    }

    // Create a copy of material data for the registry
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const material_copy_ptr = memory.cardinal_alloc(allocator, @sizeOf(CardinalMaterial));
    if (material_copy_ptr == null) {
        std.log.err("Failed to allocate memory for material copy", .{});
        return null;
    }
    const material_copy = @as(*CardinalMaterial, @ptrCast(@alignCast(material_copy_ptr)));
    material_copy.* = material.?.*;

    // Copy output material
    out_material.?.* = material.?.*;

    // Register the material
    const ref_resource = ref_counting.cardinal_ref_create(hash_cstr, material_copy, @sizeOf(CardinalMaterial), cardinal_material_destructor);
    if (ref_resource == null) {
        std.log.err("Failed to register material in reference counting system: {s}", .{hash_slice});
        memory.cardinal_free(allocator, material_copy);
        return null;
    }

    std.log.info("[MATERIAL] Registered new material for sharing: {s}", .{hash_slice});
    return ref_resource;
}

pub export fn cardinal_material_release_ref_counted(ref_resource: ?*ref_counting.CardinalRefCountedResource) callconv(.c) void {
    if (ref_resource) |res| {
        ref_counting.cardinal_ref_release(res);
    }
}
