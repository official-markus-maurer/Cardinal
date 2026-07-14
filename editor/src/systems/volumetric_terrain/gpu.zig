const C = @import("common.zig");

const std = C.std;
const engine = C.engine;
const EditorState = C.EditorState;
const VolumetricTerrainData = C.VolumetricTerrainData;
const VolumetricSplatDirtyRect = C.VolumetricSplatDirtyRect;
const memory = C.memory;
const renderer = C.renderer;
const components = C.components;
const model_manager = C.model_manager;
const scene = C.scene;
const vk = C.vk;

fn mark_volumetric_splat_dirty_rect(state: *EditorState, entity_id: u64, min_x: u32, min_z: u32, max_x: u32, max_z: u32) void {
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const rect = VolumetricSplatDirtyRect{ .min_x = min_x, .min_z = min_z, .max_x = max_x, .max_z = max_z };
    if (state.runtime.volumetric_splat_dirty_rects.getPtr(entity_id)) |r| {
        r.min_x = @min(r.min_x, rect.min_x);
        r.min_z = @min(r.min_z, rect.min_z);
        r.max_x = @max(r.max_x, rect.max_x);
        r.max_z = @max(r.max_z, rect.max_z);
    } else {
        state.runtime.volumetric_splat_dirty_rects.put(alloc, entity_id, rect) catch {};
    }
}

fn ensure_volumetric_layer_textures(state: *EditorState, td: *VolumetricTerrainData) void {
    const colors = [_][4]u8{
        .{ 80, 140, 80, 255 },
        .{ 120, 95, 60, 255 },
        .{ 130, 130, 130, 255 },
        .{ 200, 200, 160, 255 },
    };

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (td.layer_handles[i] != std.math.maxInt(u32)) continue;
        var handle: u32 = 0;
        if (renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, 1, 1, vk.VK_FORMAT_R8G8B8A8_SRGB, &handle)) {
            td.layer_handles[i] = handle;
            _ = renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, handle, @ptrCast(&colors[i]), 4);
        }
    }
}

fn project_splat_xz(td: *const VolumetricTerrainData, x: u32, z: u32) [4]u8 {
    if (td.dims == 0) return .{ 255, 0, 0, 0 };
    const dims = td.dims;
    const max_y: u32 = dims - 1;
    var best_y: u32 = 0;
    var best_abs: f32 = std.math.floatMax(f32);

    var y: u32 = 0;
    while (y <= max_y) : (y += 1) {
        const d = td.density[C.density_index(dims, x, y, z)];
        const a = @abs(d);
        if (a < best_abs) {
            best_abs = a;
            best_y = y;
            if (best_abs < C.iso_epsilon * 4.0) break;
        }
    }

    const idx = C.density_index(dims, x, best_y, z) * 4;
    return .{ td.splat[idx + 0], td.splat[idx + 1], td.splat[idx + 2], td.splat[idx + 3] };
}

fn ensure_volumetric_splat_texture(state: *EditorState, td: *VolumetricTerrainData) void {
    if (td.splat_handle != std.math.maxInt(u32)) return;
    if (td.dims < 2) return;

    var handle: u32 = 0;
    if (!renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, td.dims, td.dims, vk.VK_FORMAT_R8G8B8A8_UNORM, &handle)) return;
    td.splat_handle = handle;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const out = alloc.alloc(u8, @as(usize, td.dims) * @as(usize, td.dims) * 4) catch return;
    defer alloc.free(out);

    var z: u32 = 0;
    while (z < td.dims) : (z += 1) {
        var x: u32 = 0;
        while (x < td.dims) : (x += 1) {
            const p = project_splat_xz(td, x, z);
            const o = (@as(usize, z) * @as(usize, td.dims) + @as(usize, x)) * 4;
            out[o + 0] = p[0];
            out[o + 1] = p[1];
            out[o + 2] = p[2];
            out[o + 3] = p[3];
        }
    }

    _ = renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, td.splat_handle, @ptrCast(out.ptr), out.len);
}

pub fn ensure_volumetric_material_bound(state: *EditorState, vt: *components.VolumetricTerrain, td: *VolumetricTerrainData) void {
    ensure_volumetric_layer_textures(state, td);
    if (td.layer_handles[0] == std.math.maxInt(u32)) return;

    const model = model_manager.cardinal_model_manager_get_model(&state.runtime.model_manager, vt.model_id) orelse return;
    if (model.scene.materials == null or model.scene.material_count == 0) return;
    var mat = &model.scene.materials.?[0];

    const tiling = @max(0.001, state.ui.terrain_texture_tiling);
    if (mat.emissive_strength < 0.0 and
        mat.emissive_strength < -1.5 and
        mat.albedo_texture.index == td.layer_handles[0] and
        mat.normal_texture.index == td.layer_handles[1] and
        mat.metallic_roughness_texture.index == td.layer_handles[2] and
        mat.ao_texture.index == td.layer_handles[3] and
        mat.albedo_transform.scale[0] == tiling and mat.albedo_transform.scale[1] == tiling)
    {
        return;
    }
    const identity_tf = scene.CardinalTextureTransform{
        .offset = .{ 0.0, 0.0 },
        .scale = .{ 1.0, 1.0 },
        .rotation = 0.0,
    };
    const tile_tf = scene.CardinalTextureTransform{
        .offset = .{ 0.0, 0.0 },
        .scale = .{ tiling, tiling },
        .rotation = 0.0,
    };

    const TH = @TypeOf(mat.albedo_texture);
    mat.albedo_texture = TH{ .index = td.layer_handles[0], .generation = 0 };
    mat.normal_texture = TH{ .index = td.layer_handles[1], .generation = 0 };
    mat.metallic_roughness_texture = TH{ .index = td.layer_handles[2], .generation = 0 };
    mat.ao_texture = TH{ .index = td.layer_handles[3], .generation = 0 };
    mat.emissive_texture = TH{ .index = std.math.maxInt(u32), .generation = 0 };

    mat.albedo_factor = .{ 1.0, 1.0, 1.0, 1.0 };
    mat.metallic_factor = 0.0;
    mat.roughness_factor = 1.0;
    mat.emissive_factor = .{ 0.0, 0.0, 0.0 };
    mat.emissive_strength = -2.0;
    mat.uv_indices = .{ 0, 0, 0, 0, 0 };
    mat.albedo_transform = tile_tf;
    mat.normal_transform = tile_tf;
    mat.metallic_roughness_transform = tile_tf;
    mat.ao_transform = tile_tf;
    mat.emissive_transform = identity_tf;

    if (state.runtime.combined_scene.materials != null and state.runtime.combined_scene.material_count != 0) {
        if (vt.mesh_index < state.runtime.combined_scene.mesh_count and state.runtime.combined_scene.meshes != null) {
            const mi = state.runtime.combined_scene.meshes.?[vt.mesh_index].material_index;
            if (mi < state.runtime.combined_scene.material_count) {
                var cmb = &state.runtime.combined_scene.materials.?[mi];
                const THC = @TypeOf(cmb.albedo_texture);
                cmb.albedo_texture = THC{ .index = td.layer_handles[0], .generation = 0 };
                cmb.normal_texture = THC{ .index = td.layer_handles[1], .generation = 0 };
                cmb.metallic_roughness_texture = THC{ .index = td.layer_handles[2], .generation = 0 };
                cmb.ao_texture = THC{ .index = td.layer_handles[3], .generation = 0 };
                cmb.emissive_texture = THC{ .index = std.math.maxInt(u32), .generation = 0 };

                cmb.albedo_factor = mat.albedo_factor;
                cmb.metallic_factor = mat.metallic_factor;
                cmb.roughness_factor = mat.roughness_factor;
                cmb.emissive_factor = mat.emissive_factor;
                cmb.emissive_strength = mat.emissive_strength;
                cmb.alpha_cutoff = mat.alpha_cutoff;
                cmb.alpha_mode = mat.alpha_mode;
                cmb.normal_scale = mat.normal_scale;
                cmb.ao_strength = mat.ao_strength;
                cmb.uv_indices = mat.uv_indices;
                cmb.albedo_transform = tile_tf;
                cmb.normal_transform = tile_tf;
                cmb.metallic_roughness_transform = tile_tf;
                cmb.ao_transform = tile_tf;
                cmb.emissive_transform = identity_tf;
            }
        }
    }

    state.runtime.pending_scene = state.runtime.combined_scene;
    state.runtime.scene_upload_pending = true;
    state.runtime.scene_loaded = (state.runtime.combined_scene.mesh_count > 0);
}

pub fn flush_volumetric_pending_uploads(state: *EditorState) void {
    if (state.runtime.volumetric_splat_dirty_rects.count() == 0) return;

    var it = state.runtime.volumetric_splat_dirty_rects.iterator();
    while (it.next()) |entry| {
        const entity_id = entry.key_ptr.*;
        const rect = entry.value_ptr.*;
        const ent = engine.ecs_entity.Entity{ .id = entity_id };
        if (!state.runtime.registry.entity_manager.is_alive(ent)) continue;
        const vt = state.runtime.registry.get(components.VolumetricTerrain, ent) orelse continue;
        const td = state.runtime.volumetric_terrain_data_by_entity.getPtr(entity_id) orelse continue;
        if (td.dims < 2) continue;

        ensure_volumetric_splat_texture(state, td);
        ensure_volumetric_material_bound(state, vt, td);
        if (td.splat_handle == std.math.maxInt(u32)) continue;

        const min_x = @min(rect.min_x, td.dims - 1);
        const min_z = @min(rect.min_z, td.dims - 1);
        const max_x = @min(rect.max_x, td.dims - 1);
        const max_z = @min(rect.max_z, td.dims - 1);
        if (min_x > max_x or min_z > max_z) continue;

        const w: u32 = max_x - min_x + 1;
        const h: u32 = max_z - min_z + 1;
        const w_usize: usize = @intCast(w);

        const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
        const tmp = alloc.alloc(u8, @as(usize, h) * w_usize * 4) catch continue;
        defer alloc.free(tmp);

        var row: u32 = 0;
        while (row < h) : (row += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const p = project_splat_xz(td, min_x + x, min_z + row);
                const o = (@as(usize, row) * w_usize + @as(usize, x)) * 4;
                tmp[o + 0] = p[0];
                tmp[o + 1] = p[1];
                tmp[o + 2] = p[2];
                tmp[o + 3] = p[3];
            }
        }

        _ = renderer.cardinal_renderer_runtime_texture_update_subregion(state.runtime.renderer, td.splat_handle, min_x, min_z, w, h, @ptrCast(tmp.ptr), tmp.len);
    }

    state.runtime.volumetric_splat_dirty_rects.clearRetainingCapacity();
}
