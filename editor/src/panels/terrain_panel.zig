//! Terrain creation and editing panel.
//!
//! Provides sculpt/paint tools backed by CPU-side height/splat maps and streams updates into GPU
//! textures. Terrain edits modify the live combined scene mesh and push a single undo command per
//! stroke.
const std = @import("std");
const engine = @import("cardinal_engine");
const components = engine.ecs_components;
const node_factory = engine.ecs_node_factory;
const model_manager = engine.model_manager;
const scene = engine.scene;
const math = engine.math;
const memory = engine.memory;
const renderer = engine.vulkan_renderer;
const c = @import("../c.zig").c;
const editor_state = @import("../editor_state.zig");
const EditorState = editor_state.EditorState;
const selection_raycast = @import("../systems/selection_raycast.zig");
const undo = @import("../undo.zig");

/// Per-stroke capture state used to build a single undo command.
const StrokeCapture = struct {
    model_id: u32,
    combined_mesh_index: u32,
    tool: i32,
    flatten_target_y: f32 = 0.0,
    flatten_has_target: bool = false,
    touched: std.AutoHashMapUnmanaged(u32, u32) = .{},
    indices: std.ArrayListUnmanaged(u32) = .{},
    before_y: std.ArrayListUnmanaged(f32) = .{},
    before_color: std.ArrayListUnmanaged([4]f32) = .{},
};

/// Currently active terrain stroke, or null when idle.
var active_stroke: ?StrokeCapture = null;

/// Resolves the mesh index range for a model inside the combined scene.
fn get_model_combined_mesh_range(state: *EditorState, model_id: u32) ?struct { start: u32, count: u32 } {
    if (state.runtime.model_manager.models == null) return null;
    const models = state.runtime.model_manager.models.?;

    var offset: u32 = 0;
    var i: u32 = 0;
    while (i < state.runtime.model_manager.model_count) : (i += 1) {
        const m = &models[i];
        if (!m.visible or m.is_loading) continue;
        if (m.id == model_id) return .{ .start = offset, .count = m.scene.mesh_count };
        offset += m.scene.mesh_count;
    }
    return null;
}

/// Builds a one-mesh terrain scene used when creating new terrain assets.
///
/// TODO: Share primitive-scene construction with other editor mesh generators.
fn build_flat_terrain_scene(grid_resolution: u32, world_size: f32) ?scene.CardinalScene {
    const assets_alloc = memory.cardinal_get_allocator_for_category(.ASSETS);

    var out = std.mem.zeroes(scene.CardinalScene);

    const grid = if (grid_resolution < 2) 2 else grid_resolution;
    const verts_per_side: u32 = grid + 1;
    const vertex_count: u32 = verts_per_side * verts_per_side;
    const index_count: u32 = grid * grid * 6;

    const meshes_ptr = memory.cardinal_calloc(assets_alloc, 1, @sizeOf(scene.CardinalMesh)) orelse return null;
    const materials_ptr = memory.cardinal_calloc(assets_alloc, 1, @sizeOf(scene.CardinalMaterial)) orelse {
        memory.cardinal_free(assets_alloc, meshes_ptr);
        return null;
    };
    const vertices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, vertex_count) * @sizeOf(scene.CardinalVertex)) orelse {
        memory.cardinal_free(assets_alloc, materials_ptr);
        memory.cardinal_free(assets_alloc, meshes_ptr);
        return null;
    };
    const indices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, index_count) * @sizeOf(u32)) orelse {
        memory.cardinal_free(assets_alloc, vertices_ptr);
        memory.cardinal_free(assets_alloc, materials_ptr);
        memory.cardinal_free(assets_alloc, meshes_ptr);
        return null;
    };

    const meshes = @as([*]scene.CardinalMesh, @ptrCast(@alignCast(meshes_ptr)));
    const materials = @as([*]scene.CardinalMaterial, @ptrCast(@alignCast(materials_ptr)));
    const vertices = @as([*]scene.CardinalVertex, @ptrCast(@alignCast(vertices_ptr)));
    const indices = @as([*]u32, @ptrCast(@alignCast(indices_ptr)));

    const half: f32 = world_size * 0.5;

    const min_y: f32 = 0.0;
    const max_y: f32 = 0.0;

    var v: u32 = 0;
    while (v < vertex_count) : (v += 1) {
        vertices[v] = std.mem.zeroes(scene.CardinalVertex);
        vertices[v].nx = 0.0;
        vertices[v].ny = 1.0;
        vertices[v].nz = 0.0;
        vertices[v].u1 = 0.0;
        vertices[v].v1 = 0.0;
        vertices[v].color = .{ 1.0, 1.0, 1.0, 1.0 };
    }

    var z: u32 = 0;
    while (z < verts_per_side) : (z += 1) {
        var x: u32 = 0;
        while (x < verts_per_side) : (x += 1) {
            const idx: u32 = z * verts_per_side + x;
            const fx: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(grid));
            const fz: f32 = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(grid));

            const px = fx * world_size - half;
            const pz = fz * world_size - half;

            vertices[idx].px = px;
            vertices[idx].py = 0.0;
            vertices[idx].pz = pz;
            vertices[idx].u = fx;
            vertices[idx].v = fz;
            vertices[idx].u1 = fx;
            vertices[idx].v1 = fz;
        }
    }

    var ii: u32 = 0;
    z = 0;
    while (z < grid) : (z += 1) {
        var x: u32 = 0;
        while (x < grid) : (x += 1) {
            const idx0: u32 = z * verts_per_side + x;
            const idx1: u32 = idx0 + 1;
            const idx2: u32 = idx0 + verts_per_side;
            const idx3: u32 = idx2 + 1;

            indices[ii + 0] = idx0;
            indices[ii + 1] = idx2;
            indices[ii + 2] = idx1;
            indices[ii + 3] = idx1;
            indices[ii + 4] = idx2;
            indices[ii + 5] = idx3;
            ii += 6;
        }
    }

    materials[0] = std.mem.zeroes(scene.CardinalMaterial);
    const TextureHandle = @TypeOf(materials[0].albedo_texture);
    const invalid_tex: TextureHandle = .{ .index = std.math.maxInt(u32), .generation = 0 };
    materials[0].albedo_texture = invalid_tex;
    materials[0].normal_texture = invalid_tex;
    materials[0].metallic_roughness_texture = invalid_tex;
    materials[0].ao_texture = invalid_tex;
    materials[0].emissive_texture = invalid_tex;
    materials[0].albedo_factor = .{ 0.35, 0.6, 0.35, 1.0 };
    materials[0].metallic_factor = 0.0;
    materials[0].roughness_factor = 0.95;
    materials[0].emissive_factor = .{ 0.0, 0.0, 0.0 };
    materials[0].emissive_strength = 0.0;
    materials[0].normal_scale = 1.0;
    materials[0].ao_strength = 1.0;
    materials[0].alpha_mode = scene.CardinalAlphaMode.OPAQUE;
    materials[0].alpha_cutoff = 0.5;
    materials[0].double_sided = true;
    materials[0].uv_indices = .{ 0, 0, 0, 0, 0 };
    materials[0].albedo_transform = std.mem.zeroes(scene.CardinalTextureTransform);
    materials[0].normal_transform = std.mem.zeroes(scene.CardinalTextureTransform);
    materials[0].metallic_roughness_transform = std.mem.zeroes(scene.CardinalTextureTransform);
    materials[0].ao_transform = std.mem.zeroes(scene.CardinalTextureTransform);
    materials[0].emissive_transform = std.mem.zeroes(scene.CardinalTextureTransform);

    meshes[0] = std.mem.zeroes(scene.CardinalMesh);
    meshes[0].vertices = @ptrCast(vertices);
    meshes[0].vertex_count = vertex_count;
    meshes[0].indices = @ptrCast(indices);
    meshes[0].index_count = index_count;
    meshes[0].material_index = 0;
    meshes[0].visible = true;
    meshes[0].bounding_box_min = .{ -half, min_y, -half };
    meshes[0].bounding_box_max = .{ half, max_y, half };

    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    @memcpy(&meshes[0].transform, &identity);

    out.meshes = @ptrCast(meshes);
    out.mesh_count = 1;
    out.materials = @ptrCast(materials);
    out.material_count = 1;
    out.textures = null;
    out.texture_count = 0;
    out.lights = null;
    out.light_count = 0;
    out.root_nodes = null;
    out.root_node_count = 0;
    out.all_nodes = null;
    out.all_node_count = 0;
    out.animation_system = null;
    out.skins = null;
    out.skin_count = 0;

    return out;
}

/// Refreshes `state.runtime.combined_scene` from the model manager and schedules a GPU upload.
fn rebuild_scene_and_schedule_upload(state: *EditorState) void {
    const combined = model_manager.cardinal_model_manager_get_combined_scene(&state.runtime.model_manager) orelse return;
    state.runtime.combined_scene = combined.*;
    state.runtime.pending_scene = state.runtime.combined_scene;
    state.runtime.scene_upload_pending = true;
    state.runtime.scene_loaded = (state.runtime.combined_scene.mesh_count > 0);
}

/// Returns the per-model mesh pointer and its combined-scene counterpart for a terrain entity.
fn get_terrain_meshes(state: *EditorState, terr: *components.Terrain) ?struct { model_mesh: *scene.CardinalMesh, combined_mesh: *scene.CardinalMesh } {
    const model = model_manager.cardinal_model_manager_get_model(&state.runtime.model_manager, terr.model_id) orelse return null;
    if (model.scene.meshes == null or model.scene.mesh_count == 0) return null;
    const range = get_model_combined_mesh_range(state, terr.model_id) orelse return null;
    if (terr.mesh_index < range.start) return null;
    const local_index: u32 = terr.mesh_index - range.start;
    if (local_index >= model.scene.mesh_count) return null;
    const model_mesh = &model.scene.meshes.?[local_index];

    if (state.runtime.combined_scene.meshes == null or terr.mesh_index >= state.runtime.combined_scene.mesh_count) return null;
    const combined_mesh = &state.runtime.combined_scene.meshes.?[terr.mesh_index];
    return .{ .model_mesh = model_mesh, .combined_mesh = combined_mesh };
}

fn clamp01(v: f32) f32 {
    return @min(1.0, @max(0.0, v));
}

fn float_to_u8(v: f32) u8 {
    return @intFromFloat(clamp01(v) * 255.0 + 0.5);
}

fn recompute_y_bounds(verts: [*]scene.CardinalVertex, vertex_count: u32) struct { min_y: f32, max_y: f32 } {
    var min_y: f32 = std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var i: u32 = 0;
    while (i < vertex_count) : (i += 1) {
        min_y = @min(min_y, verts[i].py);
        max_y = @max(max_y, verts[i].py);
    }
    if (vertex_count == 0) return .{ .min_y = 0.0, .max_y = 0.0 };
    return .{ .min_y = min_y, .max_y = max_y };
}

fn update_terrain_bounds(terr: *components.Terrain, model_mesh: *scene.CardinalMesh, combined_mesh: *scene.CardinalMesh) void {
    if (model_mesh.vertices == null or model_mesh.vertex_count == 0) return;
    const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));
    const b = recompute_y_bounds(verts, model_mesh.vertex_count);
    const half_x = terr.size.x * 0.5;
    const half_z = terr.size.y * 0.5;
    model_mesh.bounding_box_min = .{ -half_x, b.min_y, -half_z };
    model_mesh.bounding_box_max = .{ half_x, b.max_y, half_z };
    combined_mesh.bounding_box_min = model_mesh.bounding_box_min;
    combined_mesh.bounding_box_max = model_mesh.bounding_box_max;
}

fn derive_grid_from_mesh(terr: *components.Terrain, mesh: *scene.CardinalMesh) ?struct { grid: u32, verts_per_side: u32 } {
    _ = terr;
    if (mesh.vertex_count < 4) return null;
    const vf: f64 = @floatFromInt(mesh.vertex_count);
    const root: f64 = std.math.sqrt(vf);
    const vps: u32 = @intFromFloat(@floor(root + 0.5));
    if (vps < 2) return null;
    if (@as(u64, vps) * @as(u64, vps) != @as(u64, mesh.vertex_count)) return null;
    return .{ .grid = vps - 1, .verts_per_side = vps };
}

fn clamp_i32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

/// Ensures CPU-side height/splat data exists for `entity_id`, migrating from mesh vertices if needed.
fn ensure_terrain_data(state: *EditorState, entity_id: u64, model_mesh: *scene.CardinalMesh, verts_per_side: u32) ?*editor_state.TerrainData {
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const dims = verts_per_side;
    const want_height_len: usize = @as(usize, dims) * @as(usize, dims);
    const want_splat_len: usize = want_height_len * 4;

    if (state.runtime.terrain_data_by_entity.getPtr(entity_id)) |existing| {
        if (existing.dims == dims and existing.height.len == want_height_len and existing.splat.len == want_splat_len) {
            return existing;
        }
        if (existing.height_handle != std.math.maxInt(u32)) {
            renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, existing.height_handle);
        }
        if (existing.splat_handle != std.math.maxInt(u32)) {
            renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, existing.splat_handle);
        }
        for (existing.layer_handles) |h| {
            if (h != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, h);
            }
        }
        alloc.free(existing.height);
        alloc.free(existing.splat);
        _ = state.runtime.terrain_data_by_entity.remove(entity_id);
    }

    if (model_mesh.vertices == null or model_mesh.vertex_count == 0) return null;
    const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));
    if (model_mesh.vertex_count != want_height_len) return null;

    const height = alloc.alloc(f32, want_height_len) catch return null;
    const splat = alloc.alloc(u8, want_splat_len) catch {
        alloc.free(height);
        return null;
    };

    var i: usize = 0;
    while (i < want_height_len) : (i += 1) {
        height[i] = verts[@as(u32, @intCast(i))].py;
        const c4 = verts[@as(u32, @intCast(i))].color;
        const base = i * 4;
        splat[base + 0] = float_to_u8(c4[0]);
        splat[base + 1] = float_to_u8(c4[1]);
        splat[base + 2] = float_to_u8(c4[2]);
        splat[base + 3] = 255;
    }

    state.runtime.terrain_data_by_entity.put(alloc, entity_id, .{
        .dims = dims,
        .height = height,
        .splat = splat,
    }) catch {
        alloc.free(splat);
        alloc.free(height);
        return null;
    };

    return state.runtime.terrain_data_by_entity.getPtr(entity_id);
}

fn ensure_terrain_gpu_textures(state: *EditorState, td: *editor_state.TerrainData) void {
    if (td.height_handle == std.math.maxInt(u32)) {
        var handle: u32 = 0;
        if (renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, td.dims, td.dims, c.VK_FORMAT_R32_SFLOAT, &handle)) {
            td.height_handle = handle;
            _ = renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, handle, @ptrCast(td.height.ptr), td.height.len * @sizeOf(f32));
        }
    }

    if (td.splat_handle == std.math.maxInt(u32)) {
        var handle: u32 = 0;
        if (renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, td.dims, td.dims, c.VK_FORMAT_R8G8B8A8_UNORM, &handle)) {
            td.splat_handle = handle;
            _ = renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, handle, @ptrCast(td.splat.ptr), td.splat.len);
        }
    }
}

fn ensure_terrain_layer_textures(state: *EditorState, td: *editor_state.TerrainData) void {
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
        if (renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, 1, 1, c.VK_FORMAT_R8G8B8A8_SRGB, &handle)) {
            td.layer_handles[i] = handle;
            _ = renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, handle, @ptrCast(&colors[i]), 4);
        }
    }
}

fn ensure_terrain_material_bound(state: *EditorState, terr: *components.Terrain, td: *editor_state.TerrainData) void {
    ensure_terrain_gpu_textures(state, td);
    ensure_terrain_layer_textures(state, td);
    if (td.splat_handle == std.math.maxInt(u32)) return;
    if (td.layer_handles[0] == std.math.maxInt(u32)) return;

    const model = model_manager.cardinal_model_manager_get_model(&state.runtime.model_manager, terr.model_id) orelse return;
    if (model.scene.materials == null or model.scene.material_count == 0) return;
    var mat = &model.scene.materials.?[0];

    const TextureHandle = @TypeOf(mat.albedo_texture);
    if (mat.emissive_strength < 0.0 and
        mat.emissive_texture.index == td.splat_handle and
        mat.albedo_texture.index == td.layer_handles[0] and
        mat.normal_texture.index == td.layer_handles[1] and
        mat.metallic_roughness_texture.index == td.layer_handles[2] and
        mat.ao_texture.index == td.layer_handles[3])
    {
        return;
    }
    mat.albedo_texture = TextureHandle{ .index = td.layer_handles[0], .generation = 0 };
    mat.normal_texture = TextureHandle{ .index = td.layer_handles[1], .generation = 0 };
    mat.metallic_roughness_texture = TextureHandle{ .index = td.layer_handles[2], .generation = 0 };
    mat.ao_texture = TextureHandle{ .index = td.layer_handles[3], .generation = 0 };
    mat.emissive_texture = TextureHandle{ .index = td.splat_handle, .generation = 0 };

    mat.albedo_factor = .{ 1.0, 1.0, 1.0, 1.0 };
    mat.metallic_factor = 0.0;
    mat.roughness_factor = 1.0;
    mat.emissive_factor = .{ 0.0, 0.0, 0.0 };
    mat.emissive_strength = -1.0;

    if (get_terrain_meshes(state, terr)) |meshes| {
        const combined_mesh = meshes.combined_mesh;
        if (state.runtime.combined_scene.materials != null and combined_mesh.material_index < state.runtime.combined_scene.material_count) {
            var cmb = &state.runtime.combined_scene.materials.?[combined_mesh.material_index];
            const TH = @TypeOf(cmb.albedo_texture);
            cmb.albedo_texture = TH{ .index = td.layer_handles[0], .generation = 0 };
            cmb.normal_texture = TH{ .index = td.layer_handles[1], .generation = 0 };
            cmb.metallic_roughness_texture = TH{ .index = td.layer_handles[2], .generation = 0 };
            cmb.ao_texture = TH{ .index = td.layer_handles[3], .generation = 0 };
            cmb.emissive_texture = TH{ .index = td.splat_handle, .generation = 0 };

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
        }
    }

    state.runtime.pending_scene = state.runtime.combined_scene;
    state.runtime.scene_upload_pending = true;
    state.runtime.scene_loaded = (state.runtime.combined_scene.mesh_count > 0);
}

/// Uploads a rectangular CPU height/splat region into the terrain GPU textures.
fn upload_terrain_dirty_rect(state: *EditorState, td: *editor_state.TerrainData, min_x: u32, min_y: u32, max_x: u32, max_y: u32) void {
    ensure_terrain_gpu_textures(state, td);
    if (td.height_handle == std.math.maxInt(u32) or td.splat_handle == std.math.maxInt(u32)) return;

    if (min_x > max_x or min_y > max_y) return;
    if (max_x >= td.dims or max_y >= td.dims) return;

    const w: u32 = max_x - min_x + 1;
    const h: u32 = max_y - min_y + 1;
    const w_usize: usize = @intCast(w);
    const h_usize: usize = @intCast(h);

    const tmp_height = state.runtime.arena_allocator.alloc(f32, w_usize * h_usize) catch return;
    const tmp_splat = state.runtime.arena_allocator.alloc(u8, (w_usize * h_usize) * 4) catch return;

    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const src_y: usize = @as(usize, min_y + row);
        const src_base: usize = src_y * @as(usize, td.dims) + @as(usize, min_x);
        const dst_base: usize = @as(usize, row) * w_usize;

        @memcpy(tmp_height[dst_base .. dst_base + w_usize], td.height[src_base .. src_base + w_usize]);

        const src_s_base: usize = src_base * 4;
        const dst_s_base: usize = dst_base * 4;
        @memcpy(tmp_splat[dst_s_base .. dst_s_base + w_usize * 4], td.splat[src_s_base .. src_s_base + w_usize * 4]);
    }

    _ = renderer.cardinal_renderer_runtime_texture_update_subregion(state.runtime.renderer, td.height_handle, min_x, min_y, w, h, @ptrCast(tmp_height.ptr), tmp_height.len * @sizeOf(f32));
    _ = renderer.cardinal_renderer_runtime_texture_update_subregion(state.runtime.renderer, td.splat_handle, min_x, min_y, w, h, @ptrCast(tmp_splat.ptr), tmp_splat.len);
}

/// Begins a new stroke capture if one is not already active.
fn stroke_begin(state: *EditorState, terr: *components.Terrain, tool: i32) void {
    if (active_stroke != null) return;
    active_stroke = .{
        .model_id = terr.model_id,
        .combined_mesh_index = terr.mesh_index,
        .tool = tool,
    };
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    active_stroke.?.touched.ensureTotalCapacity(alloc, 256) catch {};
    active_stroke.?.indices.ensureTotalCapacity(alloc, 256) catch {};
    active_stroke.?.before_y.ensureTotalCapacity(alloc, 256) catch {};
    active_stroke.?.before_color.ensureTotalCapacity(alloc, 256) catch {};
    _ = state;
}

/// Adds a vertex to the active stroke capture if it was not seen before.
fn stroke_record_vertex(index: u32, before_y: f32, before_color: [4]f32) void {
    if (active_stroke == null) return;
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    if (active_stroke.?.touched.get(index) != null) return;
    const pos: u32 = @intCast(active_stroke.?.indices.items.len);
    active_stroke.?.touched.put(alloc, index, pos) catch return;
    active_stroke.?.indices.append(alloc, index) catch return;
    active_stroke.?.before_y.append(alloc, before_y) catch return;
    active_stroke.?.before_color.append(alloc, before_color) catch return;
}

/// Ends the active stroke and pushes a single undo command for the edited vertices.
fn stroke_end_and_push_undo(state: *EditorState, entity_id: u64, terr: *components.Terrain) void {
    if (active_stroke == null) return;
    defer {
        const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
        active_stroke.?.touched.deinit(alloc);
        active_stroke.?.indices.deinit(alloc);
        active_stroke.?.before_y.deinit(alloc);
        active_stroke.?.before_color.deinit(alloc);
        active_stroke = null;
    }

    if (active_stroke.?.indices.items.len == 0) return;
    if (active_stroke.?.model_id != terr.model_id or active_stroke.?.combined_mesh_index != terr.mesh_index) return;

    const meshes = get_terrain_meshes(state, terr) orelse return;
    const model_mesh = meshes.model_mesh;
    const combined_mesh = meshes.combined_mesh;
    if (model_mesh.vertices == null or model_mesh.vertex_count == 0) return;
    const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    const count: usize = active_stroke.?.indices.items.len;
    const indices_mem = alloc.alloc(u32, count) catch return;
    const before_y_mem = alloc.alloc(f32, count) catch {
        alloc.free(indices_mem);
        return;
    };
    const after_y_mem = alloc.alloc(f32, count) catch {
        alloc.free(before_y_mem);
        alloc.free(indices_mem);
        return;
    };
    const before_c_mem = alloc.alloc([4]f32, count) catch {
        alloc.free(after_y_mem);
        alloc.free(before_y_mem);
        alloc.free(indices_mem);
        return;
    };
    const after_c_mem = alloc.alloc([4]f32, count) catch {
        alloc.free(before_c_mem);
        alloc.free(after_y_mem);
        alloc.free(before_y_mem);
        alloc.free(indices_mem);
        return;
    };

    @memcpy(indices_mem, active_stroke.?.indices.items);
    @memcpy(before_y_mem, active_stroke.?.before_y.items);
    @memcpy(before_c_mem, active_stroke.?.before_color.items);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const vi = indices_mem[i];
        if (vi >= model_mesh.vertex_count) {
            after_y_mem[i] = before_y_mem[i];
            after_c_mem[i] = before_c_mem[i];
            continue;
        }
        after_y_mem[i] = verts[vi].py;
        after_c_mem[i] = verts[vi].color;
    }

    const cmd_ptr = alloc.create(undo.TerrainMeshEditCommand) catch {
        alloc.free(after_c_mem);
        alloc.free(before_c_mem);
        alloc.free(after_y_mem);
        alloc.free(before_y_mem);
        alloc.free(indices_mem);
        return;
    };
    cmd_ptr.* = .{
        .model_id = terr.model_id,
        .combined_mesh_index = terr.mesh_index,
        .vertex_indices = indices_mem,
        .before_y = before_y_mem,
        .after_y = after_y_mem,
        .before_color = before_c_mem,
        .after_color = after_c_mem,
    };

    update_terrain_bounds(terr, model_mesh, combined_mesh);

    state.ui.undo.push(.{ .TerrainMeshEdit = cmd_ptr });

    if (state.runtime.terrain_data_by_entity.getPtr(entity_id)) |td| {
        var min_x: u32 = std.math.maxInt(u32);
        var min_y: u32 = std.math.maxInt(u32);
        var max_x: u32 = 0;
        var max_y: u32 = 0;

        var j: usize = 0;
        while (j < active_stroke.?.indices.items.len) : (j += 1) {
            const vi: u32 = active_stroke.?.indices.items[j];
            const x: u32 = vi % td.dims;
            const y: u32 = vi / td.dims;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }

        if (min_x != std.math.maxInt(u32) and min_y != std.math.maxInt(u32)) {
            upload_terrain_dirty_rect(state, td, min_x, min_y, max_x, max_y);
        }
    }
}

fn create_terrain(state: *EditorState, grid_resolution: u32, world_size: f32) void {
    var scn = build_flat_terrain_scene(grid_resolution, world_size) orelse return;

    var name_buf: [64]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "Terrain", .{}) catch "Terrain";
    const model_id = model_manager.cardinal_model_manager_add_scene(&state.runtime.model_manager, &scn, null, name_z.ptr);
    if (model_id == 0) {
        scene.cardinal_scene_destroy(&scn);
        return;
    }

    rebuild_scene_and_schedule_upload(state);
    state.runtime.picking_cache_dirty = true;

    const parent = if (state.runtime.registry.entity_manager.is_alive(state.ui.selected_entity)) state.ui.selected_entity else null;
    const created = node_factory.create_node(state.runtime.registry, parent, .Terrain3D, "Terrain", .{}) catch return;

    const range = get_model_combined_mesh_range(state, model_id) orelse return;
    if (range.count == 0) return;
    if (state.runtime.combined_scene.meshes == null or range.start >= state.runtime.combined_scene.mesh_count) return;

    const mesh = &state.runtime.combined_scene.meshes.?[range.start];
    const mr = components.MeshRenderer{
        .mesh = .{ .index = range.start, .generation = 0 },
        .material = .{ .index = mesh.material_index, .generation = 0 },
        .visible = true,
        .cast_shadows = true,
        .receive_shadows = true,
    };
    state.runtime.registry.add(created, mr) catch {};

    const terr = components.Terrain{
        .size = .{ .x = world_size, .y = world_size },
        .resolution = if (grid_resolution < 2) 2 else grid_resolution,
        .model_id = model_id,
        .mesh_index = range.start,
    };
    state.runtime.registry.add(created, terr) catch {};

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const dims: u32 = (if (grid_resolution < 2) 2 else grid_resolution) + 1;
    const h_len: usize = @as(usize, dims) * @as(usize, dims);
    const s_len: usize = h_len * 4;
    const height_opt = alloc.alloc(f32, h_len) catch null;
    const splat_opt = alloc.alloc(u8, s_len) catch null;
    if (height_opt != null and splat_opt != null) {
        const height = height_opt.?;
        const splat = splat_opt.?;
        @memset(height, 0.0);
        @memset(splat, 255);
        if (state.runtime.terrain_data_by_entity.getPtr(created.id)) |existing| {
            if (existing.height_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, existing.height_handle);
            }
            if (existing.splat_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, existing.splat_handle);
            }
            for (existing.layer_handles) |h| {
                if (h != std.math.maxInt(u32)) {
                    renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, h);
                }
            }
            alloc.free(existing.height);
            alloc.free(existing.splat);
            _ = state.runtime.terrain_data_by_entity.remove(created.id);
        }
        state.runtime.terrain_data_by_entity.put(alloc, created.id, .{ .dims = dims, .height = height, .splat = splat }) catch {
            alloc.free(splat);
            alloc.free(height);
        };
        if (state.runtime.terrain_data_by_entity.getPtr(created.id)) |td| {
            ensure_terrain_gpu_textures(state, td);
            if (state.runtime.registry.get(components.Terrain, created)) |terr_ptr| {
                ensure_terrain_material_bound(state, terr_ptr, td);
            }
        }
    } else {
        if (height_opt) |h| alloc.free(h);
        if (splat_opt) |s| alloc.free(s);
    }

    state.runtime.mark_transform_override_tree(created);

    state.ui.selected_entity = created;
    state.ui.selected_model_id = 0;
    state.ui.scene_graph_focus_target_id = created.id;
    state.ui.scene_graph_focus_pending = true;
}

/// Applies the sculpt brush to the terrain heightmap and combined mesh.
fn apply_sculpt_to_selected(state: *EditorState, entity_id: u64, terr: *components.Terrain, t: *components.Transform, world_hit: math.Vec3) bool {
    const meshes = get_terrain_meshes(state, terr) orelse return false;
    const model_mesh = meshes.model_mesh;
    if (model_mesh.vertices == null or model_mesh.vertex_count == 0) return false;
    const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));
    const grid_ctx = derive_grid_from_mesh(terr, model_mesh) orelse return false;
    const grid = grid_ctx.grid;
    const verts_per_side = grid_ctx.verts_per_side;
    const data = ensure_terrain_data(state, entity_id, model_mesh, verts_per_side) orelse return false;

    const local_x = world_hit.x - t.position.x;
    const local_z = world_hit.z - t.position.z;

    const half_x = terr.size.x * 0.5;
    const half_z = terr.size.y * 0.5;
    if (local_x < -half_x or local_x > half_x) return false;
    if (local_z < -half_z or local_z > half_z) return false;

    const radius = @max(0.001, state.ui.terrain_brush_radius);
    const mode = state.ui.terrain_sculpt_mode;
    const raw_strength = state.ui.terrain_brush_strength;
    const strength = if (mode == 0 or mode == 1) @max(0.0, raw_strength) else @min(1.0, @max(0.0, raw_strength));

    var changed = false;

    const fx = (local_x + half_x) / terr.size.x;
    const fz = (local_z + half_z) / terr.size.y;
    const cx_f = fx * @as(f32, @floatFromInt(grid));
    const cz_f = fz * @as(f32, @floatFromInt(grid));

    const radius_x = radius / terr.size.x * @as(f32, @floatFromInt(grid));
    const radius_z = radius / terr.size.y * @as(f32, @floatFromInt(grid));

    const cx_i: i32 = @intFromFloat(@floor(cx_f + 0.5));
    const cz_i: i32 = @intFromFloat(@floor(cz_f + 0.5));

    const min_x = clamp_i32(@intFromFloat(@floor(cx_f - radius_x)), 0, @as(i32, @intCast(grid)));
    const max_x = clamp_i32(@intFromFloat(@ceil(cx_f + radius_x)), 0, @as(i32, @intCast(grid)));
    const min_z = clamp_i32(@intFromFloat(@floor(cz_f - radius_z)), 0, @as(i32, @intCast(grid)));
    const max_z = clamp_i32(@intFromFloat(@ceil(cz_f + radius_z)), 0, @as(i32, @intCast(grid)));

    if (mode == 3) {
        const alloc = state.runtime.arena_allocator;
        const x_count: usize = @intCast(max_x - min_x + 1);
        const z_count: usize = @intCast(max_z - min_z + 1);
        const tmp_len: usize = x_count * z_count;
        const tmp = alloc.alloc(f32, tmp_len) catch return false;
        const tmp_idx = alloc.alloc(u32, tmp_len) catch return false;

        var ti: usize = 0;
        var z: i32 = min_z;
        while (z <= max_z) : (z += 1) {
            var x: i32 = min_x;
            while (x <= max_x) : (x += 1) {
                const vi: u32 = @intCast(@as(u32, @intCast(z)) * verts_per_side + @as(u32, @intCast(x)));
                tmp_idx[ti] = vi;
                if (vi >= model_mesh.vertex_count) {
                    tmp[ti] = 0.0;
                    ti += 1;
                    continue;
                }
                const left = if (x > 0) vi - 1 else vi;
                const right = if (x < @as(i32, @intCast(grid))) vi + 1 else vi;
                const down = if (z > 0) vi - verts_per_side else vi;
                const up = if (z < @as(i32, @intCast(grid))) vi + verts_per_side else vi;
                tmp[ti] = (data.height[vi] + data.height[left] + data.height[right] + data.height[down] + data.height[up]) / 5.0;
                ti += 1;
            }
        }

        ti = 0;
        z = min_z;
        while (z <= max_z) : (z += 1) {
            var x: i32 = min_x;
            while (x <= max_x) : (x += 1) {
                const vi = tmp_idx[ti];
                if (vi >= model_mesh.vertex_count) {
                    ti += 1;
                    continue;
                }
                const px = (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(grid))) * terr.size.x - half_x;
                const pz = (@as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(grid))) * terr.size.y - half_z;
                const dx = px - local_x;
                const dz = pz - local_z;
                const d2 = dx * dx + dz * dz;
                if (d2 <= radius * radius) {
                    const d = @sqrt(d2);
                    var w = 1.0 - (d / radius);
                    w = w * w;
                    const a = strength * w;
                    if (a > 0.0) {
                        stroke_record_vertex(vi, verts[vi].py, verts[vi].color);
                        data.height[vi] += (tmp[ti] - data.height[vi]) * a;
                        verts[vi].py = data.height[vi];
                        changed = true;
                    }
                }
                ti += 1;
            }
        }
    } else {
        if (mode == 2 and active_stroke != null and !active_stroke.?.flatten_has_target) {
            const vx: i32 = clamp_i32(cx_i, 0, @as(i32, @intCast(grid)));
            const vz: i32 = clamp_i32(cz_i, 0, @as(i32, @intCast(grid)));
            const vi: u32 = @intCast(@as(u32, @intCast(vz)) * verts_per_side + @as(u32, @intCast(vx)));
            if (vi < model_mesh.vertex_count) {
                active_stroke.?.flatten_target_y = data.height[vi];
                active_stroke.?.flatten_has_target = true;
            }
        }

        var z: i32 = min_z;
        while (z <= max_z) : (z += 1) {
            var x: i32 = min_x;
            while (x <= max_x) : (x += 1) {
                const vi: u32 = @intCast(@as(u32, @intCast(z)) * verts_per_side + @as(u32, @intCast(x)));
                if (vi >= model_mesh.vertex_count) continue;
                const px = (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(grid))) * terr.size.x - half_x;
                const pz = (@as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(grid))) * terr.size.y - half_z;
                const dx = px - local_x;
                const dz = pz - local_z;
                const d2 = dx * dx + dz * dz;
                if (d2 > radius * radius) continue;

                const d = @sqrt(d2);
                var w = 1.0 - (d / radius);
                w = w * w;

                stroke_record_vertex(vi, verts[vi].py, verts[vi].color);
                switch (mode) {
                    0 => data.height[vi] += strength * w,
                    1 => data.height[vi] -= strength * w,
                    2 => {
                        const target_y = if (active_stroke) |s| if (s.flatten_has_target) s.flatten_target_y else data.height[vi] else data.height[vi];
                        data.height[vi] += (target_y - data.height[vi]) * (strength * w);
                    },
                    else => {},
                }
                verts[vi].py = data.height[vi];
                changed = true;
            }
        }
    }

    if (!changed) return false;
    return true;
}

/// Applies the paint brush to the terrain splatmap and combined mesh vertex colors.
fn apply_paint_to_selected(state: *EditorState, entity_id: u64, terr: *components.Terrain, t: *components.Transform, world_hit: math.Vec3) bool {
    const meshes = get_terrain_meshes(state, terr) orelse return false;
    const model_mesh = meshes.model_mesh;
    if (model_mesh.vertices == null or model_mesh.vertex_count == 0) return false;
    const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));
    const grid_ctx = derive_grid_from_mesh(terr, model_mesh) orelse return false;
    const grid = grid_ctx.grid;
    const verts_per_side = grid_ctx.verts_per_side;
    const data = ensure_terrain_data(state, entity_id, model_mesh, verts_per_side) orelse return false;

    const local_x = world_hit.x - t.position.x;
    const local_z = world_hit.z - t.position.z;

    const half_x = terr.size.x * 0.5;
    const half_z = terr.size.y * 0.5;
    if (local_x < -half_x or local_x > half_x) return false;
    if (local_z < -half_z or local_z > half_z) return false;

    const radius = @max(0.001, state.ui.terrain_brush_radius);
    const strength = @min(1.0, @max(0.0, state.ui.terrain_brush_strength));

    const target = state.ui.terrain_paint_color;
    const tr: f32 = clamp01(target[0]);
    const tg: f32 = clamp01(target[1]);
    const tb: f32 = clamp01(target[2]);
    var changed = false;

    const fx = (local_x + half_x) / terr.size.x;
    const fz = (local_z + half_z) / terr.size.y;
    const cx_f = fx * @as(f32, @floatFromInt(grid));
    const cz_f = fz * @as(f32, @floatFromInt(grid));

    const radius_x = radius / terr.size.x * @as(f32, @floatFromInt(grid));
    const radius_z = radius / terr.size.y * @as(f32, @floatFromInt(grid));

    const min_x = clamp_i32(@intFromFloat(@floor(cx_f - radius_x)), 0, @as(i32, @intCast(grid)));
    const max_x = clamp_i32(@intFromFloat(@ceil(cx_f + radius_x)), 0, @as(i32, @intCast(grid)));
    const min_z = clamp_i32(@intFromFloat(@floor(cz_f - radius_z)), 0, @as(i32, @intCast(grid)));
    const max_z = clamp_i32(@intFromFloat(@ceil(cz_f + radius_z)), 0, @as(i32, @intCast(grid)));

    var z: i32 = min_z;
    while (z <= max_z) : (z += 1) {
        var x: i32 = min_x;
        while (x <= max_x) : (x += 1) {
            const vi: u32 = @intCast(@as(u32, @intCast(z)) * verts_per_side + @as(u32, @intCast(x)));
            if (vi >= model_mesh.vertex_count) continue;
            const dx = verts[vi].px - local_x;
            const dz = verts[vi].pz - local_z;
            const d2 = dx * dx + dz * dz;
            if (d2 > radius * radius) continue;

            const d = @sqrt(d2);
            var w = 1.0 - (d / radius);
            w = w * w;
            const a = strength * w;
            if (a <= 0.0) continue;

            stroke_record_vertex(vi, verts[vi].py, verts[vi].color);
            verts[vi].color[0] = verts[vi].color[0] + (tr - verts[vi].color[0]) * a;
            verts[vi].color[1] = verts[vi].color[1] + (tg - verts[vi].color[1]) * a;
            verts[vi].color[2] = verts[vi].color[2] + (tb - verts[vi].color[2]) * a;
            verts[vi].color[3] = 1.0;

            const base = @as(usize, vi) * 4;
            data.splat[base + 0] = float_to_u8(verts[vi].color[0]);
            data.splat[base + 1] = float_to_u8(verts[vi].color[1]);
            data.splat[base + 2] = float_to_u8(verts[vi].color[2]);
            data.splat[base + 3] = 255;
            changed = true;
        }
    }

    if (changed) {
        upload_terrain_dirty_rect(state, data, @intCast(min_x), @intCast(min_z), @intCast(max_x), @intCast(max_z));
    }

    return changed;
}

pub fn draw_terrain_panel(state: *EditorState) void {
    if (!state.ui.show_terrain_panel) return;
    const open = c.imgui_bridge_begin("Terrain", &state.ui.show_terrain_panel, 0);
    defer c.imgui_bridge_end();
    if (!open) return;

    if (c.imgui_bridge_button("Create Terrain")) {
        create_terrain(state, 128, 64.0);
    }

    c.imgui_bridge_separator();

    const selected = state.ui.selected_entity;
    const terr_ptr = if (state.runtime.registry.entity_manager.is_alive(selected)) state.runtime.registry.get(components.Terrain, selected) else null;
    if (terr_ptr == null) {
        c.imgui_bridge_text_wrapped("Select a Terrain entity to edit.");
        return;
    }

    if (get_terrain_meshes(state, terr_ptr.?)) |meshes| {
        if (derive_grid_from_mesh(terr_ptr.?, meshes.model_mesh)) |grid_ctx| {
            if (ensure_terrain_data(state, selected.id, meshes.model_mesh, grid_ctx.verts_per_side)) |td| {
                ensure_terrain_material_bound(state, terr_ptr.?, td);
            }
        }
    }

    _ = c.imgui_bridge_checkbox("Enable Edit (hold Shift + LMB)", &state.ui.terrain_sculpt_enabled);

    const tool_items = [_][*:0]const u8{
        "Sculpt Height",
        "Paint Color",
    };
    var tool_ptr: i32 = state.ui.terrain_tool;
    _ = c.imgui_bridge_combo("Tool", &tool_ptr, &tool_items[0], @intCast(tool_items.len), 10);
    state.ui.terrain_tool = tool_ptr;

    _ = c.imgui_bridge_drag_float("Brush Radius", &state.ui.terrain_brush_radius, 0.05, 0.1, 200.0, "%.2f", 0);
    if (state.ui.terrain_tool == 0) {
        const mode_items = [_][*:0]const u8{
            "Raise",
            "Lower",
            "Flatten",
            "Smooth",
        };
        var mode_ptr: i32 = state.ui.terrain_sculpt_mode;
        _ = c.imgui_bridge_combo("Mode", &mode_ptr, &mode_items[0], @intCast(mode_items.len), 10);
        state.ui.terrain_sculpt_mode = mode_ptr;

        if (state.ui.terrain_sculpt_mode == 0 or state.ui.terrain_sculpt_mode == 1) {
            _ = c.imgui_bridge_drag_float("Brush Strength", &state.ui.terrain_brush_strength, 0.01, 0.0, 10.0, "%.3f", 0);
        } else {
            _ = c.imgui_bridge_drag_float("Brush Strength", &state.ui.terrain_brush_strength, 0.01, 0.0, 1.0, "%.3f", 0);
        }
    } else {
        _ = c.imgui_bridge_drag_float("Brush Strength", &state.ui.terrain_brush_strength, 0.01, 0.0, 1.0, "%.3f", 0);
        _ = c.imgui_bridge_color_edit3("Paint Color", &state.ui.terrain_paint_color, 0);
    }

    const mouse_down = state.ui.terrain_sculpt_enabled and c.imgui_bridge_is_shift_down() and c.imgui_bridge_is_mouse_down(0) and !state.runtime.mouse_captured;

    if (mouse_down) {
        stroke_begin(state, terr_ptr.?, state.ui.terrain_tool);
        if (state.runtime.registry.get(components.Transform, selected)) |t| {
            if (selection_raycast.get_ray_from_mouse(state)) |ray| {
                if (@abs(ray.direction.y) > 0.00001) {
                    const plane_y = t.position.y;
                    const hit_t = (plane_y - ray.origin.y) / ray.direction.y;
                    if (hit_t > 0.0) {
                        const hit = ray.origin.add(ray.direction.mul(hit_t));
                        if (state.ui.terrain_tool == 0) {
                            _ = apply_sculpt_to_selected(state, selected.id, terr_ptr.?, t, hit);
                        } else {
                            _ = apply_paint_to_selected(state, selected.id, terr_ptr.?, t, hit);
                        }
                        state.ui.terrain_brush_last_mouse_down = true;
                        state.runtime.picking_cache_dirty = true;
                    }
                }
            }
        }
    } else if (state.ui.terrain_brush_last_mouse_down) {
        stroke_end_and_push_undo(state, selected.id, terr_ptr.?);
        state.runtime.pending_scene = state.runtime.combined_scene;
        state.runtime.scene_upload_pending = true;
        state.runtime.picking_cache_dirty = true;
        state.ui.terrain_brush_last_mouse_down = false;
    }
}
