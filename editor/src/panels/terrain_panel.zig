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
const platform = engine.platform;
const texture_loader = engine.texture_loader;
const c = @import("../c.zig").c;
const editor_state = @import("../editor_state.zig");
const EditorState = editor_state.EditorState;
const mesh_generators = @import("../systems/mesh_generators.zig");
const terrain_volume = @import("../systems/terrain_volume.zig");
const selection_raycast = @import("../systems/selection_raycast.zig");
const volumetric_terrain = @import("../systems/volumetric_terrain.zig");
const undo = @import("../undo.zig");

const enable_volumetric_terrain = false;

const StrokeCapture = struct {
    entity_id: u64,
    model_id: u32,
    combined_mesh_index: u32,
    touched: std.AutoHashMapUnmanaged(u32, u32) = .{},
    indices: std.ArrayListUnmanaged(u32) = .{},
    before_y: std.ArrayListUnmanaged(f32) = .{},
    before_color: std.ArrayListUnmanaged([4]f32) = .{},
    before_splat: std.ArrayListUnmanaged(u32) = .{},
};

const StrokeState = struct {
    tool: i32,
    sculpt_surface: i32 = 0,
    flatten_target_y: f32 = 0.0,
    flatten_has_target: bool = false,
    capture_by_entity: std.AutoHashMapUnmanaged(u64, u32) = .{},
    captures: std.ArrayListUnmanaged(StrokeCapture) = .{},
};

var active_stroke: ?StrokeState = null;

const VolumetricStrokeCapture = struct {
    entity_id: u64,
    dims: u32,
    before_density: []f32,
    before_splat: []u8,
    before_data_id: u64,
};

const VolumetricStrokeState = struct {
    tool: i32,
    mode: i32,
    capture_by_entity: std.AutoHashMapUnmanaged(u64, u32) = .{},
    captures: std.ArrayListUnmanaged(VolumetricStrokeCapture) = .{},
};

var active_volumetric_stroke: ?VolumetricStrokeState = null;

fn sphere_intersects_aabb(center: math.Vec3, radius: f32, aabb_min: math.Vec3, aabb_max: math.Vec3) bool {
    const cx = std.math.clamp(center.x, aabb_min.x, aabb_max.x);
    const cy = std.math.clamp(center.y, aabb_min.y, aabb_max.y);
    const cz = std.math.clamp(center.z, aabb_min.z, aabb_max.z);
    const dx = center.x - cx;
    const dy = center.y - cy;
    const dz = center.z - cz;
    return (dx * dx + dy * dy + dz * dz) <= radius * radius;
}

fn brush_can_stamp(state: *EditorState, hit_world: math.Vec3) bool {
    const spacing = state.ui.terrain_brush_spacing;
    if (spacing <= 0.0001) return true;
    if (!state.ui.terrain_brush_stamp_valid) return true;
    const dx = hit_world.x - state.ui.terrain_brush_stamp_pos[0];
    const dy = hit_world.y - state.ui.terrain_brush_stamp_pos[1];
    const dz = hit_world.z - state.ui.terrain_brush_stamp_pos[2];
    const min_dist = @max(0.0, spacing) * @max(0.001, state.ui.terrain_brush_radius);
    return (dx * dx + dy * dy + dz * dz) >= min_dist * min_dist;
}

fn brush_record_stamp(state: *EditorState, hit_world: math.Vec3) void {
    state.ui.terrain_brush_stamp_valid = true;
    state.ui.terrain_brush_stamp_pos = .{ hit_world.x, hit_world.y, hit_world.z };
}

fn volumetric_stroke_begin(tool: i32, mode: i32) void {
    if (active_volumetric_stroke != null) return;
    active_volumetric_stroke = .{
        .tool = tool,
        .mode = mode,
        .capture_by_entity = .{},
        .captures = .{},
    };
}

fn volumetric_stroke_capture_before(state: *EditorState, entity_id: u64) void {
    if (active_volumetric_stroke == null) return;
    if (active_volumetric_stroke.?.capture_by_entity.contains(entity_id)) return;

    const ent = engine.ecs_entity.Entity{ .id = entity_id };
    if (!state.runtime.registry.entity_manager.is_alive(ent)) return;
    const vt = state.runtime.registry.get(components.VolumetricTerrain, ent) orelse return;
    const td = volumetric_terrain.ensure_volumetric_terrain_data_for_entity(state, ent) orelse return;
    if (td.dims < 2) return;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const density_copy = alloc.alloc(f32, td.density.len) catch return;
    errdefer alloc.free(density_copy);
    const splat_copy = alloc.alloc(u8, td.splat.len) catch {
        alloc.free(density_copy);
        return;
    };
    @memcpy(density_copy, td.density);
    @memcpy(splat_copy, td.splat);

    const idx: u32 = @intCast(active_volumetric_stroke.?.captures.items.len);
    active_volumetric_stroke.?.capture_by_entity.put(alloc, entity_id, idx) catch {
        alloc.free(splat_copy);
        alloc.free(density_copy);
        return;
    };
    active_volumetric_stroke.?.captures.append(alloc, .{
        .entity_id = entity_id,
        .dims = td.dims,
        .before_density = density_copy,
        .before_splat = splat_copy,
        .before_data_id = vt.data_id,
    }) catch {
        _ = active_volumetric_stroke.?.capture_by_entity.remove(entity_id);
        alloc.free(splat_copy);
        alloc.free(density_copy);
        return;
    };
}

fn volumetric_stroke_end_and_push_undo(state: *EditorState) void {
    if (active_volumetric_stroke == null) return;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    defer {
        for (active_volumetric_stroke.?.captures.items) |cap| {
            if (cap.before_density.len != 0) alloc.free(cap.before_density);
            if (cap.before_splat.len != 0) alloc.free(cap.before_splat);
        }
        active_volumetric_stroke.?.captures.deinit(alloc);
        active_volumetric_stroke.?.capture_by_entity.deinit(alloc);
        active_volumetric_stroke = null;
    }

    var cmds: std.ArrayListUnmanaged(*undo.VolumetricTerrainEditCommand) = .{};
    defer cmds.deinit(alloc);

    for (active_volumetric_stroke.?.captures.items) |*cap| {
        const ent = engine.ecs_entity.Entity{ .id = cap.entity_id };
        if (!state.runtime.registry.entity_manager.is_alive(ent)) continue;
        const vt = state.runtime.registry.get(components.VolumetricTerrain, ent) orelse continue;
        const td = volumetric_terrain.ensure_volumetric_terrain_data_for_entity(state, ent) orelse continue;
        if (td.dims != cap.dims) continue;

        const after_density = alloc.alloc(f32, td.density.len) catch continue;
        errdefer alloc.free(after_density);
        const after_splat = alloc.alloc(u8, td.splat.len) catch continue;

        @memcpy(after_density, td.density);
        @memcpy(after_splat, td.splat);

        const cmd = alloc.create(undo.VolumetricTerrainEditCommand) catch {
            alloc.free(after_splat);
            alloc.free(after_density);
            continue;
        };

        cmd.* = .{
            .entity_id = cap.entity_id,
            .dims = cap.dims,
            .before_density = cap.before_density,
            .after_density = after_density,
            .before_splat = cap.before_splat,
            .after_splat = after_splat,
            .before_data_id = cap.before_data_id,
            .after_data_id = vt.data_id,
        };

        cap.before_density = @constCast(&[_]f32{});
        cap.before_splat = @constCast(&[_]u8{});

        cmds.append(alloc, cmd) catch {
            alloc.free(cmd.before_density);
            alloc.free(cmd.after_density);
            alloc.free(cmd.before_splat);
            alloc.free(cmd.after_splat);
            alloc.destroy(cmd);
        };
    }

    if (cmds.items.len == 0) return;
    if (cmds.items.len == 1) {
        state.ui.undo.push(.{ .VolumetricTerrainEdit = cmds.items[0] });
        return;
    }

    const edits = alloc.alloc(*undo.VolumetricTerrainEditCommand, cmds.items.len) catch {
        for (cmds.items) |p| {
            alloc.free(p.before_density);
            alloc.free(p.after_density);
            alloc.free(p.before_splat);
            alloc.free(p.after_splat);
            alloc.destroy(p);
        }
        return;
    };
    @memcpy(edits, cmds.items);
    state.ui.undo.push(.{ .VolumetricTerrainEditGroup = .{ .edits = edits } });
}

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

fn build_flat_terrain_scene(grid_resolution: u32, world_size: f32, thickness: f32) ?scene.CardinalScene {
    return mesh_generators.build_flat_terrain_scene(grid_resolution, world_size, thickness);
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

fn get_terrain_volume_meshes(state: *EditorState, terr: *components.Terrain) ?struct {
    top_model: *scene.CardinalMesh,
    top_combined: *scene.CardinalMesh,
    bottom_model: ?*scene.CardinalMesh,
    bottom_combined: ?*scene.CardinalMesh,
} {
    const model = model_manager.cardinal_model_manager_get_model(&state.runtime.model_manager, terr.model_id) orelse return null;
    if (model.scene.meshes == null or model.scene.mesh_count == 0) return null;
    const range = get_model_combined_mesh_range(state, terr.model_id) orelse return null;
    if (terr.mesh_index < range.start) return null;
    const local_index: u32 = terr.mesh_index - range.start;
    if (local_index >= model.scene.mesh_count) return null;

    if (state.runtime.combined_scene.meshes == null or terr.mesh_index >= state.runtime.combined_scene.mesh_count) return null;

    const top_model = &model.scene.meshes.?[local_index];
    const top_combined = &state.runtime.combined_scene.meshes.?[terr.mesh_index];

    var bottom_model: ?*scene.CardinalMesh = null;
    var bottom_combined: ?*scene.CardinalMesh = null;
    if (terr.thickness > 0.01) {
        const bottom_local = local_index + 1;
        const bottom_combined_index = terr.mesh_index + 1;
        if (bottom_local < model.scene.mesh_count and bottom_combined_index < state.runtime.combined_scene.mesh_count) {
            bottom_model = &model.scene.meshes.?[bottom_local];
            bottom_combined = &state.runtime.combined_scene.meshes.?[bottom_combined_index];
        }
    }

    return .{
        .top_model = top_model,
        .top_combined = top_combined,
        .bottom_model = bottom_model,
        .bottom_combined = bottom_combined,
    };
}

fn clamp01(v: f32) f32 {
    return @min(1.0, @max(0.0, v));
}

fn float_to_u8(v: f32) u8 {
    return @intFromFloat(clamp01(v) * 255.0 + 0.5);
}

fn pack_splat(td: *editor_state.TerrainData, vi: u32) u32 {
    const base: usize = @as(usize, vi) * 4;
    if (base + 3 >= td.splat.len) return 0;
    return @as(u32, td.splat[base + 0]) |
        (@as(u32, td.splat[base + 1]) << 8) |
        (@as(u32, td.splat[base + 2]) << 16) |
        (@as(u32, td.splat[base + 3]) << 24);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn is_texture_asset_path(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.mem.eql(u8, ext, ".png") or
        std.mem.eql(u8, ext, ".jpg") or
        std.mem.eql(u8, ext, ".jpeg") or
        std.mem.eql(u8, ext, ".tga") or
        std.mem.eql(u8, ext, ".bmp") or
        std.mem.eql(u8, ext, ".dds") or
        std.mem.eql(u8, ext, ".hdr") or
        std.mem.eql(u8, ext, ".exr");
}

fn sample_height_bilinear_map(height_map: []const f32, verts_per_side: u32, terr: *components.Terrain, local_x: f32, local_z: f32) f32 {
    if (verts_per_side < 2) return 0.0;
    const grid: u32 = verts_per_side - 1;
    const half_x = terr.size.x * 0.5;
    const half_z = terr.size.y * 0.5;

    const fx = std.math.clamp((local_x + half_x) / terr.size.x, 0.0, 1.0);
    const fz = std.math.clamp((local_z + half_z) / terr.size.y, 0.0, 1.0);

    const x_f = fx * @as(f32, @floatFromInt(grid));
    const z_f = fz * @as(f32, @floatFromInt(grid));

    const x0_u32: u32 = @intFromFloat(@floor(x_f));
    const z0_u32: u32 = @intFromFloat(@floor(z_f));
    const x1_u32: u32 = @min(x0_u32 + 1, grid);
    const z1_u32: u32 = @min(z0_u32 + 1, grid);

    const tx = x_f - @as(f32, @floatFromInt(x0_u32));
    const tz = z_f - @as(f32, @floatFromInt(z0_u32));

    const idx00: usize = @as(usize, z0_u32) * @as(usize, verts_per_side) + @as(usize, x0_u32);
    const idx10: usize = @as(usize, z0_u32) * @as(usize, verts_per_side) + @as(usize, x1_u32);
    const idx01: usize = @as(usize, z1_u32) * @as(usize, verts_per_side) + @as(usize, x0_u32);
    const idx11: usize = @as(usize, z1_u32) * @as(usize, verts_per_side) + @as(usize, x1_u32);

    if (idx11 >= height_map.len) return 0.0;
    const h00 = height_map[idx00];
    const h10 = height_map[idx10];
    const h01 = height_map[idx01];
    const h11 = height_map[idx11];

    return lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), tz);
}

fn sample_height_bilinear(td: *editor_state.TerrainData, verts_per_side: u32, terr: *components.Terrain, local_x: f32, local_z: f32) f32 {
    return sample_height_bilinear_map(td.height, verts_per_side, terr, local_x, local_z);
}

fn brush_falloff(radius: f32, dx: f32, dz: f32) f32 {
    const d2 = dx * dx + dz * dz;
    if (d2 > radius * radius) return 0.0;
    const d = @sqrt(@max(0.0, d2));
    var w = 1.0 - (d / radius);
    w = w * w;
    return w;
}

fn pick_sculpt_surface_for_hit(state: *EditorState, entity: engine.ecs_entity.Entity, terr: *components.Terrain, tr: *components.Transform, hit: math.Vec3) i32 {
    if (terr.thickness <= 0.01) return 0;
    const td = state.runtime.terrain_data_by_entity.getPtr(entity.id) orelse ensure_terrain_data_for_entity(state, entity) orelse return 0;
    const meshes = get_terrain_volume_meshes(state, terr) orelse return 0;
    const grid_ctx = derive_grid_from_mesh(terr, meshes.top_model) orelse return 0;

    const local_x = hit.x - tr.position.x;
    const local_z = hit.z - tr.position.z;

    const top_h = sample_height_bilinear_map(td.height, grid_ctx.verts_per_side, terr, local_x, local_z);
    const bot_h = sample_height_bilinear_map(td.bottom_height, grid_ctx.verts_per_side, terr, local_x, local_z);
    const top_wy = tr.position.y + top_h;
    const bot_wy = tr.position.y + bot_h;

    const dt = @abs(hit.y - top_wy);
    const db = @abs(hit.y - bot_wy);
    return if (db < dt) 1 else 0;
}

fn predicted_height_at_point(
    terr: *components.Terrain,
    t: *components.Transform,
    td: *editor_state.TerrainData,
    verts_per_side: u32,
    world_center: math.Vec3,
    local_x: f32,
    local_z: f32,
    tool: i32,
    mode: i32,
    radius: f32,
    strength_in: f32,
) f32 {
    const base = sample_height_bilinear(td, verts_per_side, terr, local_x, local_z);

    const center_local_x = world_center.x - t.position.x;
    const center_local_z = world_center.z - t.position.z;
    const dx = local_x - center_local_x;
    const dz = local_z - center_local_z;
    const w = brush_falloff(radius, dx, dz);
    if (w <= 0.0) return base;

    if (tool != 0) return base;

    const raw_strength = strength_in;
    const strength = if (mode == 0 or mode == 1) @max(0.0, raw_strength) else @min(1.0, @max(0.0, raw_strength));

    if (mode == 0) return base + strength * w;
    if (mode == 1) return base - strength * w;
    if (mode == 2) {
        var target = base;
        if (active_stroke) |s| {
            if (s.flatten_has_target) target = s.flatten_target_y;
        } else {
            target = sample_height_bilinear(td, verts_per_side, terr, center_local_x, center_local_z);
        }
        return base + (target - base) * (strength * w);
    }
    if (mode == 3) {
        const grid: u32 = verts_per_side - 1;
        const step_x = terr.size.x / @as(f32, @floatFromInt(grid));
        const step_z = terr.size.y / @as(f32, @floatFromInt(grid));
        const h0 = base;
        const h1 = sample_height_bilinear(td, verts_per_side, terr, local_x - step_x, local_z);
        const h2 = sample_height_bilinear(td, verts_per_side, terr, local_x + step_x, local_z);
        const h3 = sample_height_bilinear(td, verts_per_side, terr, local_x, local_z - step_z);
        const h4 = sample_height_bilinear(td, verts_per_side, terr, local_x, local_z + step_z);
        const avg = (h0 + h1 + h2 + h3 + h4) / 5.0;
        return h0 + (avg - h0) * (strength * w);
    }

    return base;
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

fn get_terrain_walls_meshes(state: *EditorState, terr: *components.Terrain) ?struct { walls_model: *scene.CardinalMesh, walls_combined: *scene.CardinalMesh } {
    if (terr.thickness <= 0.01) return null;
    const model = model_manager.cardinal_model_manager_get_model(&state.runtime.model_manager, terr.model_id) orelse return null;
    if (model.scene.meshes == null or model.scene.mesh_count < 3) return null;
    const range = get_model_combined_mesh_range(state, terr.model_id) orelse return null;
    if (terr.mesh_index < range.start) return null;
    const local_index: u32 = terr.mesh_index - range.start;
    const walls_local = local_index + 2;
    if (walls_local >= model.scene.mesh_count) return null;
    const walls_combined_index = terr.mesh_index + 2;
    if (state.runtime.combined_scene.meshes == null or walls_combined_index >= state.runtime.combined_scene.mesh_count) return null;
    return .{
        .walls_model = &model.scene.meshes.?[walls_local],
        .walls_combined = &state.runtime.combined_scene.meshes.?[walls_combined_index],
    };
}

fn update_terrain_bounds_for_entity(state: *EditorState, terr: *components.Terrain) void {
    const meshes = get_terrain_volume_meshes(state, terr) orelse return;
    update_terrain_bounds(terr, meshes.top_model, meshes.top_combined);
    var min_y: f32 = meshes.top_model.bounding_box_min[1];
    var max_y: f32 = meshes.top_model.bounding_box_max[1];
    if (meshes.bottom_model) |bottom_model| {
        if (meshes.bottom_combined) |bottom_combined| {
            update_terrain_bounds(terr, bottom_model, bottom_combined);
            min_y = @min(min_y, bottom_model.bounding_box_min[1]);
            max_y = @max(max_y, bottom_model.bounding_box_max[1]);
        }
    }
    if (get_terrain_walls_meshes(state, terr)) |wm| {
        const half_x = terr.size.x * 0.5;
        const half_z = terr.size.y * 0.5;
        wm.walls_model.bounding_box_min = .{ -half_x, min_y, -half_z };
        wm.walls_model.bounding_box_max = .{ half_x, max_y, half_z };
        wm.walls_combined.bounding_box_min = wm.walls_model.bounding_box_min;
        wm.walls_combined.bounding_box_max = wm.walls_model.bounding_box_max;
    }
}

fn rewrite_indices_from_alpha(model_mesh: *scene.CardinalMesh, verts_per_side: u32) void {
    if (model_mesh.vertices == null or model_mesh.indices == null) return;
    if (verts_per_side < 2) return;
    const grid: u32 = verts_per_side - 1;
    const need: u32 = grid * grid * 6;
    if (model_mesh.index_count < need) return;

    const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));
    const indices = @as([*]u32, @ptrCast(model_mesh.indices.?));

    var quad: u32 = 0;
    var z: u32 = 0;
    while (z < grid) : (z += 1) {
        var x: u32 = 0;
        while (x < grid) : (x += 1) {
            const idx0: u32 = z * verts_per_side + x;
            const idx1: u32 = idx0 + 1;
            const idx2: u32 = idx0 + verts_per_side;
            const idx3: u32 = idx2 + 1;

            const a = (verts[idx0].color[3] + verts[idx1].color[3] + verts[idx2].color[3] + verts[idx3].color[3]) * 0.25;
            const base: usize = @as(usize, quad) * 6;
            if (a > 0.5) {
                indices[base + 0] = idx0;
                indices[base + 1] = idx2;
                indices[base + 2] = idx1;
                indices[base + 3] = idx1;
                indices[base + 4] = idx2;
                indices[base + 5] = idx3;
            } else {
                indices[base + 0] = 0;
                indices[base + 1] = 0;
                indices[base + 2] = 0;
                indices[base + 3] = 0;
                indices[base + 4] = 0;
                indices[base + 5] = 0;
            }
            quad += 1;
        }
    }
}

fn emit_wall_quad(wall_verts: [*]scene.CardinalVertex, wall_indices: [*]u32, wall_v: *u32, wall_i: *u32, v0: scene.CardinalVertex, v1: scene.CardinalVertex, nx: f32, nz: f32, flip: bool, thickness: f32) void {
    const top0 = v0;
    const top1 = v1;
    var bot0 = v0;
    var bot1 = v1;
    bot0.py = v0.py - thickness;
    bot1.py = v1.py - thickness;

    var t0 = top0;
    var t1 = top1;
    t0.nx = nx;
    t0.ny = 0.0;
    t0.nz = nz;
    t1.nx = nx;
    t1.ny = 0.0;
    t1.nz = nz;
    bot0.nx = nx;
    bot0.ny = 0.0;
    bot0.nz = nz;
    bot1.nx = nx;
    bot1.ny = 0.0;
    bot1.nz = nz;

    const base_v = wall_v.*;
    wall_verts[base_v + 0] = t0;
    wall_verts[base_v + 1] = t1;
    wall_verts[base_v + 2] = bot1;
    wall_verts[base_v + 3] = bot0;

    const base_i = wall_i.*;
    if (!flip) {
        wall_indices[base_i + 0] = base_v + 0;
        wall_indices[base_i + 1] = base_v + 1;
        wall_indices[base_i + 2] = base_v + 2;
        wall_indices[base_i + 3] = base_v + 0;
        wall_indices[base_i + 4] = base_v + 2;
        wall_indices[base_i + 5] = base_v + 3;
    } else {
        wall_indices[base_i + 0] = base_v + 0;
        wall_indices[base_i + 1] = base_v + 2;
        wall_indices[base_i + 2] = base_v + 1;
        wall_indices[base_i + 3] = base_v + 0;
        wall_indices[base_i + 4] = base_v + 3;
        wall_indices[base_i + 5] = base_v + 2;
    }

    wall_v.* += 4;
    wall_i.* += 6;
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
fn ensure_terrain_data(state: *EditorState, entity_id: u64, terr: *components.Terrain, top_mesh: *scene.CardinalMesh, bottom_mesh: ?*scene.CardinalMesh, verts_per_side: u32) ?*editor_state.TerrainData {
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const dims = verts_per_side;
    const want_height_len: usize = @as(usize, dims) * @as(usize, dims);
    const want_splat_len: usize = want_height_len * 4;

    if (state.runtime.terrain_data_by_entity.getPtr(entity_id)) |existing| {
        if (existing.dims == dims and existing.height.len == want_height_len and existing.bottom_height.len == want_height_len and existing.splat.len == want_splat_len) {
            return existing;
        }
        for (existing.layer_imgui_ids) |id| {
            if (id != 0) {
                c.imgui_bridge_vk_remove_texture(id);
            }
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
        alloc.free(existing.bottom_height);
        alloc.free(existing.splat);
        _ = state.runtime.terrain_data_by_entity.remove(entity_id);
    }

    if (top_mesh.vertices == null or top_mesh.vertex_count == 0) return null;
    const verts = @as([*]scene.CardinalVertex, @ptrCast(top_mesh.vertices.?));
    if (top_mesh.vertex_count != want_height_len) return null;

    const height = alloc.alloc(f32, want_height_len) catch return null;
    const bottom_height = alloc.alloc(f32, want_height_len) catch {
        alloc.free(height);
        return null;
    };
    const splat = alloc.alloc(u8, want_splat_len) catch {
        alloc.free(bottom_height);
        alloc.free(height);
        return null;
    };

    var bottom_verts_opt: ?[*]scene.CardinalVertex = null;
    if (bottom_mesh) |bm| {
        if (bm.vertices != null and bm.vertex_count == top_mesh.vertex_count) {
            bottom_verts_opt = @as([*]scene.CardinalVertex, @ptrCast(bm.vertices.?));
        }
    }

    var i: usize = 0;
    while (i < want_height_len) : (i += 1) {
        height[i] = verts[@as(u32, @intCast(i))].py;
        if (bottom_verts_opt) |bv| {
            bottom_height[i] = bv[@as(u32, @intCast(i))].py;
        } else {
            bottom_height[i] = height[i] - terr.thickness;
        }
        const c4 = verts[@as(u32, @intCast(i))].color;
        const base = i * 4;
        const r = clamp01(c4[0]);
        const g = clamp01(c4[1]);
        const b = clamp01(c4[2]);
        if (r > 0.999 and g > 0.999 and b > 0.999) {
            splat[base + 0] = 255;
            splat[base + 1] = 0;
            splat[base + 2] = 0;
            splat[base + 3] = 0;
            continue;
        }
        const sum = r + g + b;
        if (sum > 0.0001) {
            splat[base + 0] = float_to_u8(r / sum);
            splat[base + 1] = float_to_u8(g / sum);
            splat[base + 2] = float_to_u8(b / sum);
            splat[base + 3] = 0;
        } else {
            splat[base + 0] = 255;
            splat[base + 1] = 0;
            splat[base + 2] = 0;
            splat[base + 3] = 0;
        }
    }

    state.runtime.terrain_data_by_entity.put(alloc, entity_id, .{
        .dims = dims,
        .height = height,
        .bottom_height = bottom_height,
        .splat = splat,
    }) catch {
        alloc.free(splat);
        alloc.free(bottom_height);
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
    const tiling = @max(0.001, state.ui.terrain_texture_tiling);
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
    if (mat.emissive_strength < 0.0 and
        mat.emissive_texture.index == td.splat_handle and
        mat.albedo_texture.index == td.layer_handles[0] and
        mat.normal_texture.index == td.layer_handles[1] and
        mat.metallic_roughness_texture.index == td.layer_handles[2] and
        mat.ao_texture.index == td.layer_handles[3] and
        mat.albedo_transform.scale[0] == tile_tf.scale[0] and
        mat.albedo_transform.scale[1] == tile_tf.scale[1])
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
    mat.uv_indices = .{ 0, 0, 0, 0, 0 };
    mat.albedo_transform = tile_tf;
    mat.normal_transform = tile_tf;
    mat.metallic_roughness_transform = tile_tf;
    mat.ao_transform = tile_tf;
    mat.emissive_transform = identity_tf;

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
            cmb.uv_indices = .{ 0, 0, 0, 0, 0 };
            cmb.albedo_transform = tile_tf;
            cmb.normal_transform = tile_tf;
            cmb.metallic_roughness_transform = tile_tf;
            cmb.ao_transform = tile_tf;
            cmb.emissive_transform = identity_tf;
        }
    }

    state.runtime.pending_scene = state.runtime.combined_scene;
    state.runtime.scene_upload_pending = true;
    state.runtime.scene_loaded = (state.runtime.combined_scene.mesh_count > 0);
}

pub fn ensure_terrain_data_for_entity(state: *EditorState, entity: engine.ecs_entity.Entity) ?*editor_state.TerrainData {
    if (!state.runtime.registry.entity_manager.is_alive(entity)) return null;
    const terr = state.runtime.registry.get(components.Terrain, entity) orelse return null;
    const meshes = get_terrain_volume_meshes(state, terr) orelse return null;
    const grid_ctx = derive_grid_from_mesh(terr, meshes.top_model) orelse return null;
    const td = ensure_terrain_data(state, entity.id, terr, meshes.top_model, meshes.bottom_model, grid_ctx.verts_per_side) orelse return null;
    ensure_terrain_material_bound(state, terr, td);
    return td;
}

/// Rebinds `terr` to use the runtime textures referenced by `td`.
pub fn bind_terrain_material(state: *EditorState, terr: *components.Terrain, td: *editor_state.TerrainData) void {
    ensure_terrain_material_bound(state, terr, td);
}

/// Rewrites the terrain mesh index buffer using the alpha carving mask.
pub fn rewrite_indices_from_carve_alpha(model_mesh: *scene.CardinalMesh, verts_per_side: u32) void {
    rewrite_indices_from_alpha(model_mesh, verts_per_side);
}

/// Uploads a rectangular CPU height/splat region into the terrain GPU textures.
fn upload_terrain_dirty_rect(state: *EditorState, entity_id: u64, td: *editor_state.TerrainData, min_x: u32, min_y: u32, max_x: u32, max_y: u32) void {
    ensure_terrain_gpu_textures(state, td);
    if (td.height_handle == std.math.maxInt(u32) or td.splat_handle == std.math.maxInt(u32)) return;

    if (min_x > max_x or min_y > max_y) return;
    if (max_x >= td.dims or max_y >= td.dims) return;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    if (state.runtime.terrain_dirty_rects.getPtr(entity_id)) |r| {
        r.min_x = @min(r.min_x, min_x);
        r.min_y = @min(r.min_y, min_y);
        r.max_x = @max(r.max_x, max_x);
        r.max_y = @max(r.max_y, max_y);
    } else {
        state.runtime.terrain_dirty_rects.put(alloc, entity_id, .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y }) catch {};
    }
}

fn stroke_begin(tool: i32, sculpt_surface: i32) void {
    if (active_stroke != null) return;
    active_stroke = .{ .tool = tool, .sculpt_surface = sculpt_surface };
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    active_stroke.?.capture_by_entity.ensureTotalCapacity(alloc, 16) catch {};
    active_stroke.?.captures.ensureTotalCapacity(alloc, 16) catch {};
}

fn stroke_get_capture(entity_id: u64, terr: *components.Terrain, combined_mesh_index: u32) ?*StrokeCapture {
    if (active_stroke == null) return null;
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    const s = &active_stroke.?;
    if (s.capture_by_entity.get(entity_id)) |idx| {
        if (idx < s.captures.items.len) return &s.captures.items[idx];
    }

    const idx_u32: u32 = @intCast(s.captures.items.len);
    s.capture_by_entity.put(alloc, entity_id, idx_u32) catch return null;
    s.captures.append(alloc, .{
        .entity_id = entity_id,
        .model_id = terr.model_id,
        .combined_mesh_index = combined_mesh_index,
    }) catch {
        _ = s.capture_by_entity.remove(entity_id);
        return null;
    };

    const cap = &s.captures.items[idx_u32];
    cap.touched.ensureTotalCapacity(alloc, 256) catch {};
    cap.indices.ensureTotalCapacity(alloc, 256) catch {};
    cap.before_y.ensureTotalCapacity(alloc, 256) catch {};
    cap.before_color.ensureTotalCapacity(alloc, 256) catch {};
    cap.before_splat.ensureTotalCapacity(alloc, 256) catch {};
    return cap;
}

fn stroke_record_vertex(entity_id: u64, terr: *components.Terrain, combined_mesh_index: u32, index: u32, before_y: f32, before_color: [4]f32, before_splat: u32) void {
    const cap = stroke_get_capture(entity_id, terr, combined_mesh_index) orelse return;
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    if (cap.touched.get(index) != null) return;
    const pos: u32 = @intCast(cap.indices.items.len);
    cap.touched.put(alloc, index, pos) catch return;
    cap.indices.append(alloc, index) catch return;
    cap.before_y.append(alloc, before_y) catch return;
    cap.before_color.append(alloc, before_color) catch return;
    cap.before_splat.append(alloc, before_splat) catch return;
}

const StitchDir = enum { neg_x, pos_x, neg_z, pos_z };

fn stitch_pair_bottom_height(state: *EditorState, a_ent: engine.ecs_entity.Entity, b_ent: engine.ecs_entity.Entity, dir: StitchDir) void {
    if (!state.runtime.registry.entity_manager.is_alive(a_ent) or !state.runtime.registry.entity_manager.is_alive(b_ent)) return;

    const terr_a = state.runtime.registry.get(components.Terrain, a_ent) orelse return;
    const terr_b = state.runtime.registry.get(components.Terrain, b_ent) orelse return;
    const tr_a = state.runtime.registry.get(components.Transform, a_ent) orelse return;
    const tr_b = state.runtime.registry.get(components.Transform, b_ent) orelse return;
    const td_a = state.runtime.terrain_data_by_entity.getPtr(a_ent.id) orelse return;
    const td_b = state.runtime.terrain_data_by_entity.getPtr(b_ent.id) orelse return;

    if (td_a.dims < 2 or td_b.dims < 2) return;
    if (td_a.dims != td_b.dims) return;
    if (@abs(terr_a.size.x - terr_b.size.x) > 0.001) return;
    if (@abs(terr_a.size.y - terr_b.size.y) > 0.001) return;
    if (@abs(tr_a.position.y - tr_b.position.y) > 0.01) return;
    if (terr_a.thickness <= 0.01 or terr_b.thickness <= 0.01) return;

    const meshes_a = get_terrain_volume_meshes(state, terr_a) orelse return;
    const meshes_b = get_terrain_volume_meshes(state, terr_b) orelse return;
    const model_mesh_a = meshes_a.bottom_model orelse return;
    const model_mesh_b = meshes_b.bottom_model orelse return;
    if (model_mesh_a.vertices == null or model_mesh_a.vertex_count == 0) return;
    if (model_mesh_b.vertices == null or model_mesh_b.vertex_count == 0) return;
    const verts_a = @as([*]scene.CardinalVertex, @ptrCast(model_mesh_a.vertices.?));
    const verts_b = @as([*]scene.CardinalVertex, @ptrCast(model_mesh_b.vertices.?));

    const vps: u32 = td_a.dims;
    const grid: u32 = vps - 1;

    const combined_a: u32 = terr_a.mesh_index + 1;
    const combined_b: u32 = terr_b.mesh_index + 1;

    switch (dir) {
        .pos_x => {
            var z: u32 = 0;
            while (z <= grid) : (z += 1) {
                const vi_a: u32 = z * vps + grid;
                const vi_b: u32 = z * vps + 0;
                if (vi_a >= model_mesh_a.vertex_count or vi_b >= model_mesh_b.vertex_count) continue;
                stroke_record_vertex(a_ent.id, terr_a, combined_a, vi_a, verts_a[vi_a].py, verts_a[vi_a].color, pack_splat(td_a, vi_a));
                stroke_record_vertex(b_ent.id, terr_b, combined_b, vi_b, verts_b[vi_b].py, verts_b[vi_b].color, pack_splat(td_b, vi_b));

                const ia: usize = @intCast(vi_a);
                const ib: usize = @intCast(vi_b);
                const avg: f32 = (td_a.bottom_height[ia] + td_b.bottom_height[ib]) * 0.5;
                td_a.bottom_height[ia] = avg;
                td_b.bottom_height[ib] = avg;
                verts_a[vi_a].py = avg;
                verts_b[vi_b].py = avg;
            }
        },
        .neg_x => {
            var z: u32 = 0;
            while (z <= grid) : (z += 1) {
                const vi_a: u32 = z * vps + 0;
                const vi_b: u32 = z * vps + grid;
                if (vi_a >= model_mesh_a.vertex_count or vi_b >= model_mesh_b.vertex_count) continue;
                stroke_record_vertex(a_ent.id, terr_a, combined_a, vi_a, verts_a[vi_a].py, verts_a[vi_a].color, pack_splat(td_a, vi_a));
                stroke_record_vertex(b_ent.id, terr_b, combined_b, vi_b, verts_b[vi_b].py, verts_b[vi_b].color, pack_splat(td_b, vi_b));

                const ia: usize = @intCast(vi_a);
                const ib: usize = @intCast(vi_b);
                const avg: f32 = (td_a.bottom_height[ia] + td_b.bottom_height[ib]) * 0.5;
                td_a.bottom_height[ia] = avg;
                td_b.bottom_height[ib] = avg;
                verts_a[vi_a].py = avg;
                verts_b[vi_b].py = avg;
            }
        },
        .pos_z => {
            var x: u32 = 0;
            while (x <= grid) : (x += 1) {
                const vi_a: u32 = grid * vps + x;
                const vi_b: u32 = 0 * vps + x;
                if (vi_a >= model_mesh_a.vertex_count or vi_b >= model_mesh_b.vertex_count) continue;
                stroke_record_vertex(a_ent.id, terr_a, combined_a, vi_a, verts_a[vi_a].py, verts_a[vi_a].color, pack_splat(td_a, vi_a));
                stroke_record_vertex(b_ent.id, terr_b, combined_b, vi_b, verts_b[vi_b].py, verts_b[vi_b].color, pack_splat(td_b, vi_b));

                const ia: usize = @intCast(vi_a);
                const ib: usize = @intCast(vi_b);
                const avg: f32 = (td_a.bottom_height[ia] + td_b.bottom_height[ib]) * 0.5;
                td_a.bottom_height[ia] = avg;
                td_b.bottom_height[ib] = avg;
                verts_a[vi_a].py = avg;
                verts_b[vi_b].py = avg;
            }
        },
        .neg_z => {
            var x: u32 = 0;
            while (x <= grid) : (x += 1) {
                const vi_a: u32 = 0 * vps + x;
                const vi_b: u32 = grid * vps + x;
                if (vi_a >= model_mesh_a.vertex_count or vi_b >= model_mesh_b.vertex_count) continue;
                stroke_record_vertex(a_ent.id, terr_a, combined_a, vi_a, verts_a[vi_a].py, verts_a[vi_a].color, pack_splat(td_a, vi_a));
                stroke_record_vertex(b_ent.id, terr_b, combined_b, vi_b, verts_b[vi_b].py, verts_b[vi_b].color, pack_splat(td_b, vi_b));

                const ia: usize = @intCast(vi_a);
                const ib: usize = @intCast(vi_b);
                const avg: f32 = (td_a.bottom_height[ia] + td_b.bottom_height[ib]) * 0.5;
                td_a.bottom_height[ia] = avg;
                td_b.bottom_height[ib] = avg;
                verts_a[vi_a].py = avg;
                verts_b[vi_b].py = avg;
            }
        },
    }

    update_terrain_volume_meshes(state, a_ent.id);
    update_terrain_volume_meshes(state, b_ent.id);
}

fn stitch_pair(state: *EditorState, a_ent: engine.ecs_entity.Entity, b_ent: engine.ecs_entity.Entity, dir: StitchDir, tool: i32, sculpt_surface: i32) void {
    if (!state.runtime.registry.entity_manager.is_alive(a_ent) or !state.runtime.registry.entity_manager.is_alive(b_ent)) return;

    const terr_a = state.runtime.registry.get(components.Terrain, a_ent) orelse return;
    const terr_b = state.runtime.registry.get(components.Terrain, b_ent) orelse return;
    const tr_a = state.runtime.registry.get(components.Transform, a_ent) orelse return;
    const tr_b = state.runtime.registry.get(components.Transform, b_ent) orelse return;
    const td_a = state.runtime.terrain_data_by_entity.getPtr(a_ent.id) orelse return;
    const td_b = state.runtime.terrain_data_by_entity.getPtr(b_ent.id) orelse return;

    if (td_a.dims < 2 or td_b.dims < 2) return;
    if (td_a.dims != td_b.dims) return;
    if (@abs(terr_a.size.x - terr_b.size.x) > 0.001) return;
    if (@abs(terr_a.size.y - terr_b.size.y) > 0.001) return;
    if (@abs(tr_a.position.y - tr_b.position.y) > 0.01) return;

    if (tool == 0 and sculpt_surface == 2) {
        stitch_pair_bottom_height(state, a_ent, b_ent, dir);
    } else if (tool == 0 and sculpt_surface == 1) {
        stitch_pair_bottom_height(state, a_ent, b_ent, dir);
        return;
    }

    const meshes_a = get_terrain_meshes(state, terr_a) orelse return;
    const meshes_b = get_terrain_meshes(state, terr_b) orelse return;
    const model_mesh_a = meshes_a.model_mesh;
    const model_mesh_b = meshes_b.model_mesh;
    if (model_mesh_a.vertices == null or model_mesh_a.vertex_count == 0) return;
    if (model_mesh_b.vertices == null or model_mesh_b.vertex_count == 0) return;
    const verts_a = @as([*]scene.CardinalVertex, @ptrCast(model_mesh_a.vertices.?));
    const verts_b = @as([*]scene.CardinalVertex, @ptrCast(model_mesh_b.vertices.?));

    const vps: u32 = td_a.dims;
    const grid: u32 = vps - 1;

    const do_height = (tool == 0);
    const do_paint = (tool == 1);
    const do_carve = (tool == 2);

    switch (dir) {
        .pos_x => {
            var z: u32 = 0;
            while (z <= grid) : (z += 1) {
                const vi_a: u32 = z * vps + grid;
                const vi_b: u32 = z * vps + 0;
                if (vi_a >= model_mesh_a.vertex_count or vi_b >= model_mesh_b.vertex_count) continue;
                stroke_record_vertex(a_ent.id, terr_a, terr_a.mesh_index, vi_a, verts_a[vi_a].py, verts_a[vi_a].color, pack_splat(td_a, vi_a));
                stroke_record_vertex(b_ent.id, terr_b, terr_b.mesh_index, vi_b, verts_b[vi_b].py, verts_b[vi_b].color, pack_splat(td_b, vi_b));

                if (do_height) {
                    const avg: f32 = (td_a.height[vi_a] + td_b.height[vi_b]) * 0.5;
                    td_a.height[vi_a] = avg;
                    td_b.height[vi_b] = avg;
                    verts_a[vi_a].py = avg;
                    verts_b[vi_b].py = avg;
                } else if (do_paint) {
                    const base_a: usize = @as(usize, vi_a) * 4;
                    const base_b: usize = @as(usize, vi_b) * 4;
                    if (base_a + 3 < td_a.splat.len and base_b + 3 < td_b.splat.len) {
                        var chan: usize = 0;
                        while (chan < 4) : (chan += 1) {
                            const a_u: u16 = td_a.splat[base_a + chan];
                            const b_u: u16 = td_b.splat[base_b + chan];
                            const avg_u: u8 = @intCast((a_u + b_u + 1) / 2);
                            td_a.splat[base_a + chan] = avg_u;
                            td_b.splat[base_b + chan] = avg_u;
                        }
                        const a0 = @as(f32, @floatFromInt(td_a.splat[base_a + 0])) / 255.0;
                        const a1 = @as(f32, @floatFromInt(td_a.splat[base_a + 1])) / 255.0;
                        const a2 = @as(f32, @floatFromInt(td_a.splat[base_a + 2])) / 255.0;
                        const b0 = @as(f32, @floatFromInt(td_b.splat[base_b + 0])) / 255.0;
                        const b1 = @as(f32, @floatFromInt(td_b.splat[base_b + 1])) / 255.0;
                        const b2 = @as(f32, @floatFromInt(td_b.splat[base_b + 2])) / 255.0;
                        verts_a[vi_a].color = .{ a0, a1, a2, verts_a[vi_a].color[3] };
                        verts_b[vi_b].color = .{ b0, b1, b2, verts_b[vi_b].color[3] };
                    }
                } else if (do_carve) {
                    const avg_a: f32 = (clamp01(verts_a[vi_a].color[3]) + clamp01(verts_b[vi_b].color[3])) * 0.5;
                    verts_a[vi_a].color[3] = avg_a;
                    verts_b[vi_b].color[3] = avg_a;
                }
            }
            if (!do_carve) {
                upload_terrain_dirty_rect(state, a_ent.id, td_a, grid, 0, grid, grid);
                upload_terrain_dirty_rect(state, b_ent.id, td_b, 0, 0, 0, grid);
            } else {
                rewrite_indices_from_alpha(model_mesh_a, vps);
                rewrite_indices_from_alpha(model_mesh_b, vps);
            }
        },
        .neg_x => {
            var z: u32 = 0;
            while (z <= grid) : (z += 1) {
                const vi_a: u32 = z * vps + 0;
                const vi_b: u32 = z * vps + grid;
                if (vi_a >= model_mesh_a.vertex_count or vi_b >= model_mesh_b.vertex_count) continue;
                stroke_record_vertex(a_ent.id, terr_a, terr_a.mesh_index, vi_a, verts_a[vi_a].py, verts_a[vi_a].color, pack_splat(td_a, vi_a));
                stroke_record_vertex(b_ent.id, terr_b, terr_b.mesh_index, vi_b, verts_b[vi_b].py, verts_b[vi_b].color, pack_splat(td_b, vi_b));

                if (do_height) {
                    const avg: f32 = (td_a.height[vi_a] + td_b.height[vi_b]) * 0.5;
                    td_a.height[vi_a] = avg;
                    td_b.height[vi_b] = avg;
                    verts_a[vi_a].py = avg;
                    verts_b[vi_b].py = avg;
                } else if (do_paint) {
                    const base_a: usize = @as(usize, vi_a) * 4;
                    const base_b: usize = @as(usize, vi_b) * 4;
                    if (base_a + 3 < td_a.splat.len and base_b + 3 < td_b.splat.len) {
                        var chan: usize = 0;
                        while (chan < 4) : (chan += 1) {
                            const a_u: u16 = td_a.splat[base_a + chan];
                            const b_u: u16 = td_b.splat[base_b + chan];
                            const avg_u: u8 = @intCast((a_u + b_u + 1) / 2);
                            td_a.splat[base_a + chan] = avg_u;
                            td_b.splat[base_b + chan] = avg_u;
                        }
                        const a0 = @as(f32, @floatFromInt(td_a.splat[base_a + 0])) / 255.0;
                        const a1 = @as(f32, @floatFromInt(td_a.splat[base_a + 1])) / 255.0;
                        const a2 = @as(f32, @floatFromInt(td_a.splat[base_a + 2])) / 255.0;
                        const b0 = @as(f32, @floatFromInt(td_b.splat[base_b + 0])) / 255.0;
                        const b1 = @as(f32, @floatFromInt(td_b.splat[base_b + 1])) / 255.0;
                        const b2 = @as(f32, @floatFromInt(td_b.splat[base_b + 2])) / 255.0;
                        verts_a[vi_a].color = .{ a0, a1, a2, verts_a[vi_a].color[3] };
                        verts_b[vi_b].color = .{ b0, b1, b2, verts_b[vi_b].color[3] };
                    }
                } else if (do_carve) {
                    const avg_a: f32 = (clamp01(verts_a[vi_a].color[3]) + clamp01(verts_b[vi_b].color[3])) * 0.5;
                    verts_a[vi_a].color[3] = avg_a;
                    verts_b[vi_b].color[3] = avg_a;
                }
            }
            if (!do_carve) {
                upload_terrain_dirty_rect(state, a_ent.id, td_a, 0, 0, 0, grid);
                upload_terrain_dirty_rect(state, b_ent.id, td_b, grid, 0, grid, grid);
            } else {
                rewrite_indices_from_alpha(model_mesh_a, vps);
                rewrite_indices_from_alpha(model_mesh_b, vps);
            }
        },
        .pos_z => {
            var x: u32 = 0;
            while (x <= grid) : (x += 1) {
                const vi_a: u32 = grid * vps + x;
                const vi_b: u32 = 0 * vps + x;
                if (vi_a >= model_mesh_a.vertex_count or vi_b >= model_mesh_b.vertex_count) continue;
                stroke_record_vertex(a_ent.id, terr_a, terr_a.mesh_index, vi_a, verts_a[vi_a].py, verts_a[vi_a].color, pack_splat(td_a, vi_a));
                stroke_record_vertex(b_ent.id, terr_b, terr_b.mesh_index, vi_b, verts_b[vi_b].py, verts_b[vi_b].color, pack_splat(td_b, vi_b));

                if (do_height) {
                    const avg: f32 = (td_a.height[vi_a] + td_b.height[vi_b]) * 0.5;
                    td_a.height[vi_a] = avg;
                    td_b.height[vi_b] = avg;
                    verts_a[vi_a].py = avg;
                    verts_b[vi_b].py = avg;
                } else if (do_paint) {
                    const base_a: usize = @as(usize, vi_a) * 4;
                    const base_b: usize = @as(usize, vi_b) * 4;
                    if (base_a + 3 < td_a.splat.len and base_b + 3 < td_b.splat.len) {
                        var chan: usize = 0;
                        while (chan < 4) : (chan += 1) {
                            const a_u: u16 = td_a.splat[base_a + chan];
                            const b_u: u16 = td_b.splat[base_b + chan];
                            const avg_u: u8 = @intCast((a_u + b_u + 1) / 2);
                            td_a.splat[base_a + chan] = avg_u;
                            td_b.splat[base_b + chan] = avg_u;
                        }
                        const a0 = @as(f32, @floatFromInt(td_a.splat[base_a + 0])) / 255.0;
                        const a1 = @as(f32, @floatFromInt(td_a.splat[base_a + 1])) / 255.0;
                        const a2 = @as(f32, @floatFromInt(td_a.splat[base_a + 2])) / 255.0;
                        const b0 = @as(f32, @floatFromInt(td_b.splat[base_b + 0])) / 255.0;
                        const b1 = @as(f32, @floatFromInt(td_b.splat[base_b + 1])) / 255.0;
                        const b2 = @as(f32, @floatFromInt(td_b.splat[base_b + 2])) / 255.0;
                        verts_a[vi_a].color = .{ a0, a1, a2, verts_a[vi_a].color[3] };
                        verts_b[vi_b].color = .{ b0, b1, b2, verts_b[vi_b].color[3] };
                    }
                } else if (do_carve) {
                    const avg_a: f32 = (clamp01(verts_a[vi_a].color[3]) + clamp01(verts_b[vi_b].color[3])) * 0.5;
                    verts_a[vi_a].color[3] = avg_a;
                    verts_b[vi_b].color[3] = avg_a;
                }
            }
            if (!do_carve) {
                upload_terrain_dirty_rect(state, a_ent.id, td_a, 0, grid, grid, grid);
                upload_terrain_dirty_rect(state, b_ent.id, td_b, 0, 0, grid, 0);
            } else {
                rewrite_indices_from_alpha(model_mesh_a, vps);
                rewrite_indices_from_alpha(model_mesh_b, vps);
            }
        },
        .neg_z => {
            var x: u32 = 0;
            while (x <= grid) : (x += 1) {
                const vi_a: u32 = 0 * vps + x;
                const vi_b: u32 = grid * vps + x;
                if (vi_a >= model_mesh_a.vertex_count or vi_b >= model_mesh_b.vertex_count) continue;
                stroke_record_vertex(a_ent.id, terr_a, terr_a.mesh_index, vi_a, verts_a[vi_a].py, verts_a[vi_a].color, pack_splat(td_a, vi_a));
                stroke_record_vertex(b_ent.id, terr_b, terr_b.mesh_index, vi_b, verts_b[vi_b].py, verts_b[vi_b].color, pack_splat(td_b, vi_b));

                if (do_height) {
                    const avg: f32 = (td_a.height[vi_a] + td_b.height[vi_b]) * 0.5;
                    td_a.height[vi_a] = avg;
                    td_b.height[vi_b] = avg;
                    verts_a[vi_a].py = avg;
                    verts_b[vi_b].py = avg;
                } else if (do_paint) {
                    const base_a: usize = @as(usize, vi_a) * 4;
                    const base_b: usize = @as(usize, vi_b) * 4;
                    if (base_a + 3 < td_a.splat.len and base_b + 3 < td_b.splat.len) {
                        var chan: usize = 0;
                        while (chan < 4) : (chan += 1) {
                            const a_u: u16 = td_a.splat[base_a + chan];
                            const b_u: u16 = td_b.splat[base_b + chan];
                            const avg_u: u8 = @intCast((a_u + b_u + 1) / 2);
                            td_a.splat[base_a + chan] = avg_u;
                            td_b.splat[base_b + chan] = avg_u;
                        }
                        const a0 = @as(f32, @floatFromInt(td_a.splat[base_a + 0])) / 255.0;
                        const a1 = @as(f32, @floatFromInt(td_a.splat[base_a + 1])) / 255.0;
                        const a2 = @as(f32, @floatFromInt(td_a.splat[base_a + 2])) / 255.0;
                        const b0 = @as(f32, @floatFromInt(td_b.splat[base_b + 0])) / 255.0;
                        const b1 = @as(f32, @floatFromInt(td_b.splat[base_b + 1])) / 255.0;
                        const b2 = @as(f32, @floatFromInt(td_b.splat[base_b + 2])) / 255.0;
                        verts_a[vi_a].color = .{ a0, a1, a2, verts_a[vi_a].color[3] };
                        verts_b[vi_b].color = .{ b0, b1, b2, verts_b[vi_b].color[3] };
                    }
                } else if (do_carve) {
                    const avg_a: f32 = (clamp01(verts_a[vi_a].color[3]) + clamp01(verts_b[vi_b].color[3])) * 0.5;
                    verts_a[vi_a].color[3] = avg_a;
                    verts_b[vi_b].color[3] = avg_a;
                }
            }
            if (!do_carve) {
                upload_terrain_dirty_rect(state, a_ent.id, td_a, 0, 0, grid, 0);
                upload_terrain_dirty_rect(state, b_ent.id, td_b, 0, grid, grid, grid);
            } else {
                rewrite_indices_from_alpha(model_mesh_a, vps);
                rewrite_indices_from_alpha(model_mesh_b, vps);
            }
        },
    }

    if (!do_paint) {
        update_terrain_volume_meshes(state, a_ent.id);
        update_terrain_volume_meshes(state, b_ent.id);
    }
}

fn stitch_seams_for_active_stroke(state: *EditorState) void {
    if (active_stroke == null) return;
    const tool = active_stroke.?.tool;
    if (tool != 0 and tool != 1 and tool != 2) return;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var visited: std.AutoHashMapUnmanaged(u128, void) = .{};
    defer visited.deinit(alloc);

    var i: usize = 0;
    while (i < active_stroke.?.captures.items.len) : (i += 1) {
        const cap = &active_stroke.?.captures.items[i];
        if (cap.indices.items.len == 0) continue;

        const ent = engine.ecs_entity.Entity{ .id = cap.entity_id };
        if (!state.runtime.registry.entity_manager.is_alive(ent)) continue;
        const terr = state.runtime.registry.get(components.Terrain, ent) orelse continue;
        const tr = state.runtime.registry.get(components.Transform, ent) orelse continue;
        const td = state.runtime.terrain_data_by_entity.getPtr(cap.entity_id) orelse continue;
        if (td.dims < 2) continue;
        const vps: u32 = td.dims;
        const grid: u32 = vps - 1;

        var touch_neg_x = false;
        var touch_pos_x = false;
        var touch_neg_z = false;
        var touch_pos_z = false;

        var j: usize = 0;
        while (j < cap.indices.items.len) : (j += 1) {
            const vi: u32 = cap.indices.items[j];
            const x: u32 = vi % vps;
            const z: u32 = vi / vps;
            if (x == 0) touch_neg_x = true;
            if (x == grid) touch_pos_x = true;
            if (z == 0) touch_neg_z = true;
            if (z == grid) touch_pos_z = true;
            if (touch_neg_x and touch_pos_x and touch_neg_z and touch_pos_z) break;
        }

        const want_left = math.Vec3{ .x = tr.position.x - terr.size.x, .y = tr.position.y, .z = tr.position.z };
        const want_right = math.Vec3{ .x = tr.position.x + terr.size.x, .y = tr.position.y, .z = tr.position.z };
        const want_up = math.Vec3{ .x = tr.position.x, .y = tr.position.y, .z = tr.position.z - terr.size.y };
        const want_down = math.Vec3{ .x = tr.position.x, .y = tr.position.y, .z = tr.position.z + terr.size.y };

        if (touch_neg_x) {
            if (terrain_volume.find_adjacent_terrain(&state.runtime, ent, want_left)) |n| {
                const lo: u64 = @min(ent.id, n.id);
                const hi: u64 = @max(ent.id, n.id);
                const key: u128 = (@as(u128, lo) << 64) | @as(u128, hi);
                if (!visited.contains(key)) {
                    visited.put(alloc, key, {}) catch {};
                    stitch_pair(state, ent, n, .neg_x, tool, active_stroke.?.sculpt_surface);
                }
            }
        }
        if (touch_pos_x) {
            if (terrain_volume.find_adjacent_terrain(&state.runtime, ent, want_right)) |n| {
                const lo: u64 = @min(ent.id, n.id);
                const hi: u64 = @max(ent.id, n.id);
                const key: u128 = (@as(u128, lo) << 64) | @as(u128, hi);
                if (!visited.contains(key)) {
                    visited.put(alloc, key, {}) catch {};
                    stitch_pair(state, ent, n, .pos_x, tool, active_stroke.?.sculpt_surface);
                }
            }
        }
        if (touch_neg_z) {
            if (terrain_volume.find_adjacent_terrain(&state.runtime, ent, want_up)) |n| {
                const lo: u64 = @min(ent.id, n.id);
                const hi: u64 = @max(ent.id, n.id);
                const key: u128 = (@as(u128, lo) << 64) | @as(u128, hi);
                if (!visited.contains(key)) {
                    visited.put(alloc, key, {}) catch {};
                    stitch_pair(state, ent, n, .neg_z, tool, active_stroke.?.sculpt_surface);
                }
            }
        }
        if (touch_pos_z) {
            if (terrain_volume.find_adjacent_terrain(&state.runtime, ent, want_down)) |n| {
                const lo: u64 = @min(ent.id, n.id);
                const hi: u64 = @max(ent.id, n.id);
                const key: u128 = (@as(u128, lo) << 64) | @as(u128, hi);
                if (!visited.contains(key)) {
                    visited.put(alloc, key, {}) catch {};
                    stitch_pair(state, ent, n, .pos_z, tool, active_stroke.?.sculpt_surface);
                }
            }
        }
    }
}

fn stroke_end_and_push_undo(state: *EditorState) void {
    if (active_stroke == null) return;
    defer {
        const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
        for (active_stroke.?.captures.items) |*cap| {
            cap.touched.deinit(alloc);
            cap.indices.deinit(alloc);
            cap.before_y.deinit(alloc);
            cap.before_color.deinit(alloc);
            cap.before_splat.deinit(alloc);
        }
        active_stroke.?.captures.deinit(alloc);
        active_stroke.?.capture_by_entity.deinit(alloc);
        active_stroke = null;
    }

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var cmds: std.ArrayListUnmanaged(*undo.TerrainTexRectEditCommand) = .{};
    defer cmds.deinit(alloc);

    stitch_seams_for_active_stroke(state);

    for (active_stroke.?.captures.items) |*cap| {
        if (cap.indices.items.len == 0) continue;

        const ent = engine.ecs_entity.Entity{ .id = cap.entity_id };
        if (!state.runtime.registry.entity_manager.is_alive(ent)) continue;
        const terr = state.runtime.registry.get(components.Terrain, ent) orelse continue;

        if (terr.model_id != cap.model_id) continue;

        const use_bottom = (cap.combined_mesh_index == terr.mesh_index + 1);
        if (cap.combined_mesh_index != terr.mesh_index and !use_bottom) continue;

        const meshes = get_terrain_volume_meshes(state, terr) orelse continue;
        const model_mesh = if (use_bottom) meshes.bottom_model orelse continue else meshes.top_model;
        if (model_mesh.vertices == null or model_mesh.vertex_count == 0) continue;
        const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));

        const td = state.runtime.terrain_data_by_entity.getPtr(cap.entity_id) orelse continue;
        if (td.dims < 2) continue;
        const height_map: []f32 = if (use_bottom) td.bottom_height else td.height;

        var min_x: u32 = std.math.maxInt(u32);
        var min_y: u32 = std.math.maxInt(u32);
        var max_x: u32 = 0;
        var max_y: u32 = 0;

        var j0: usize = 0;
        while (j0 < cap.indices.items.len) : (j0 += 1) {
            const vi: u32 = cap.indices.items[j0];
            const x: u32 = vi % td.dims;
            const y: u32 = vi / td.dims;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
        if (min_x == std.math.maxInt(u32) or min_y == std.math.maxInt(u32)) continue;
        if (max_x >= td.dims or max_y >= td.dims) continue;

        const w: u32 = max_x - min_x + 1;
        const h: u32 = max_y - min_y + 1;
        const count_rect: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h));

        const before_y_mem = alloc.alloc(f32, count_rect) catch continue;
        const after_y_mem = alloc.alloc(f32, count_rect) catch {
            alloc.free(before_y_mem);
            continue;
        };
        const before_c_mem = alloc.alloc([4]f32, count_rect) catch {
            alloc.free(after_y_mem);
            alloc.free(before_y_mem);
            continue;
        };
        const after_c_mem = alloc.alloc([4]f32, count_rect) catch {
            alloc.free(before_c_mem);
            alloc.free(after_y_mem);
            alloc.free(before_y_mem);
            continue;
        };
        const before_splat_mem = alloc.alloc(u32, count_rect) catch {
            alloc.free(after_c_mem);
            alloc.free(before_c_mem);
            alloc.free(after_y_mem);
            alloc.free(before_y_mem);
            continue;
        };
        const after_splat_mem = alloc.alloc(u32, count_rect) catch {
            alloc.free(before_splat_mem);
            alloc.free(after_c_mem);
            alloc.free(before_c_mem);
            alloc.free(after_y_mem);
            alloc.free(before_y_mem);
            continue;
        };

        var idx: usize = 0;
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            const y: u32 = min_y + row;
            var col: u32 = 0;
            while (col < w) : (col += 1) {
                const x: u32 = min_x + col;
                const vi: u32 = y * td.dims + x;
                const vi_usize: usize = @intCast(vi);

                const after_y_val: f32 = if (vi < model_mesh.vertex_count) verts[vi].py else height_map[vi_usize];
                const after_c_val: [4]f32 = if (vi < model_mesh.vertex_count) verts[vi].color else .{ 0.0, 0.0, 0.0, 0.0 };
                const after_s_val: u32 = pack_splat(td, vi);

                after_y_mem[idx] = after_y_val;
                after_c_mem[idx] = after_c_val;
                after_splat_mem[idx] = after_s_val;

                if (cap.touched.get(vi)) |pos_u32| {
                    const pos: usize = @intCast(pos_u32);
                    if (pos < cap.before_y.items.len and pos < cap.before_color.items.len and pos < cap.before_splat.items.len) {
                        before_y_mem[idx] = cap.before_y.items[pos];
                        before_c_mem[idx] = cap.before_color.items[pos];
                        before_splat_mem[idx] = cap.before_splat.items[pos];
                    } else {
                        before_y_mem[idx] = after_y_val;
                        before_c_mem[idx] = after_c_val;
                        before_splat_mem[idx] = after_s_val;
                    }
                } else {
                    before_y_mem[idx] = after_y_val;
                    before_c_mem[idx] = after_c_val;
                    before_splat_mem[idx] = after_s_val;
                }

                idx += 1;
            }
        }

        const cmd_ptr = alloc.create(undo.TerrainTexRectEditCommand) catch {
            alloc.free(after_splat_mem);
            alloc.free(before_splat_mem);
            alloc.free(after_c_mem);
            alloc.free(before_c_mem);
            alloc.free(after_y_mem);
            alloc.free(before_y_mem);
            continue;
        };
        cmd_ptr.* = .{
            .model_id = terr.model_id,
            .combined_mesh_index = cap.combined_mesh_index,
            .min_x = min_x,
            .min_y = min_y,
            .max_x = max_x,
            .max_y = max_y,
            .before_y = before_y_mem,
            .after_y = after_y_mem,
            .before_color = before_c_mem,
            .after_color = after_c_mem,
            .before_splat = before_splat_mem,
            .after_splat = after_splat_mem,
        };

        update_terrain_bounds_for_entity(state, terr);
        update_terrain_volume_meshes(state, cap.entity_id);

        if (!use_bottom) {
            upload_terrain_dirty_rect(state, cap.entity_id, td, min_x, min_y, max_x, max_y);
        }

        cmds.append(alloc, cmd_ptr) catch {
            alloc.free(cmd_ptr.before_y);
            alloc.free(cmd_ptr.after_y);
            alloc.free(cmd_ptr.before_color);
            alloc.free(cmd_ptr.after_color);
            alloc.free(cmd_ptr.before_splat);
            alloc.free(cmd_ptr.after_splat);
            alloc.destroy(cmd_ptr);
        };
    }

    if (cmds.items.len == 0) return;
    if (cmds.items.len == 1) {
        state.ui.undo.push(.{ .TerrainTexRectEdit = cmds.items[0] });
        return;
    }

    const edits = alloc.alloc(*undo.TerrainTexRectEditCommand, cmds.items.len) catch {
        for (cmds.items) |p| {
            alloc.free(p.before_y);
            alloc.free(p.after_y);
            alloc.free(p.before_color);
            alloc.free(p.after_color);
            alloc.free(p.before_splat);
            alloc.free(p.after_splat);
            alloc.destroy(p);
        }
        return;
    };
    @memcpy(edits, cmds.items);
    state.ui.undo.push(.{ .TerrainTexRectEditGroup = .{ .edits = edits } });
}

fn create_terrain_at(state: *EditorState, grid_resolution: u32, world_size: f32, thickness: f32, parent: ?engine.ecs_entity.Entity, position: math.Vec3) ?engine.ecs_entity.Entity {
    var scn = build_flat_terrain_scene(grid_resolution, world_size, thickness) orelse return null;

    var name_buf: [64]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "Terrain", .{}) catch "Terrain";
    const model_id = model_manager.cardinal_model_manager_add_scene(&state.runtime.model_manager, &scn, null, name_z.ptr);
    if (model_id == 0) {
        scene.cardinal_scene_destroy(&scn);
        return null;
    }

    rebuild_scene_and_schedule_upload(state);
    state.runtime.picking_cache_dirty = true;

    const created = node_factory.create_node(state.runtime.registry, parent, .Terrain3D, "Terrain", .{}) catch return null;
    if (state.runtime.registry.get(components.Transform, created)) |tr| {
        tr.position = position;
    }

    const range = get_model_combined_mesh_range(state, model_id) orelse return null;
    if (range.count == 0) return null;
    if (state.runtime.combined_scene.meshes == null or range.start >= state.runtime.combined_scene.mesh_count) return null;

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
        .thickness = thickness,
        .model_id = model_id,
        .mesh_index = range.start,
        .data_id = std.crypto.random.int(u64),
    };
    state.runtime.registry.add(created, terr) catch {};

    if (state.runtime.registry.get(components.Terrain, created)) |_| {
        update_terrain_volume_meshes(state, created.id);
        state.runtime.pending_scene = state.runtime.combined_scene;
        state.runtime.scene_upload_pending = true;
    }

    if (thickness > 0.01 and range.count >= 3 and state.runtime.combined_scene.meshes != null) {
        const bottom_idx: u32 = range.start + 1;
        const walls_idx: u32 = range.start + 2;
        if (bottom_idx < state.runtime.combined_scene.mesh_count) {
            const m = &state.runtime.combined_scene.meshes.?[bottom_idx];
            const child = node_factory.create_node(state.runtime.registry, created, .MeshInstance3D, "Terrain Bottom", .{}) catch null;
            if (child) |e| {
                const cmr = components.MeshRenderer{
                    .mesh = .{ .index = bottom_idx, .generation = 0 },
                    .material = .{ .index = m.material_index, .generation = 0 },
                    .visible = true,
                    .cast_shadows = true,
                    .receive_shadows = true,
                };
                state.runtime.registry.add(e, cmr) catch {};
            }
        }
        if (walls_idx < state.runtime.combined_scene.mesh_count) {
            const m = &state.runtime.combined_scene.meshes.?[walls_idx];
            const child = node_factory.create_node(state.runtime.registry, created, .MeshInstance3D, "Terrain Walls", .{}) catch null;
            if (child) |e| {
                const cmr = components.MeshRenderer{
                    .mesh = .{ .index = walls_idx, .generation = 0 },
                    .material = .{ .index = m.material_index, .generation = 0 },
                    .visible = true,
                    .cast_shadows = true,
                    .receive_shadows = true,
                };
                state.runtime.registry.add(e, cmr) catch {};
            }
        }
    }

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const dims: u32 = (if (grid_resolution < 2) 2 else grid_resolution) + 1;
    const h_len: usize = @as(usize, dims) * @as(usize, dims);
    const s_len: usize = h_len * 4;
    const height_opt = alloc.alloc(f32, h_len) catch null;
    const bottom_height_opt = alloc.alloc(f32, h_len) catch null;
    const splat_opt = alloc.alloc(u8, s_len) catch null;
    if (height_opt != null and bottom_height_opt != null and splat_opt != null) {
        const height = height_opt.?;
        const bottom_height = bottom_height_opt.?;
        const splat = splat_opt.?;
        @memset(height, 0.0);
        @memset(bottom_height, -thickness);
        var i: usize = 0;
        while (i < s_len) : (i += 4) {
            splat[i + 0] = 255;
            splat[i + 1] = 0;
            splat[i + 2] = 0;
            splat[i + 3] = 0;
        }
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
            alloc.free(existing.bottom_height);
            alloc.free(existing.splat);
            _ = state.runtime.terrain_data_by_entity.remove(created.id);
        }
        state.runtime.terrain_data_by_entity.put(alloc, created.id, .{ .dims = dims, .height = height, .bottom_height = bottom_height, .splat = splat }) catch {
            alloc.free(splat);
            alloc.free(bottom_height);
            alloc.free(height);
        };
        if (state.runtime.terrain_data_by_entity.getPtr(created.id)) |td| {
            ensure_terrain_gpu_textures(state, td);
            if (state.runtime.registry.get(components.Terrain, created)) |terr_ptr| {
                ensure_terrain_material_bound(state, terr_ptr, td);
                const default_path_len = std.mem.indexOfScalar(u8, &state.ui.terrain_default_texture_path, 0) orelse state.ui.terrain_default_texture_path.len;
                if (default_path_len > 0) {
                    set_terrain_layer_texture_from_path(state, terr_ptr, td, 0, state.ui.terrain_default_texture_path[0..default_path_len]);
                }
            }
        }
    } else {
        if (height_opt) |h| alloc.free(h);
        if (bottom_height_opt) |h| alloc.free(h);
        if (splat_opt) |s| alloc.free(s);
    }

    state.runtime.mark_transform_override_tree(created);

    state.ui.selected_entity = created;
    state.ui.selected_entities.clearRetainingCapacity();
    state.ui.selected_entities.put(alloc, created.id, {}) catch {};
    state.ui.selected_model_id = 0;
    state.ui.scene_graph_focus_target_id = created.id;
    state.ui.scene_graph_focus_pending = true;
    return created;
}

fn create_terrain(state: *EditorState, grid_resolution: u32, world_size: f32) void {
    const parent = if (state.runtime.registry.entity_manager.is_alive(state.ui.selected_entity)) state.ui.selected_entity else null;
    const thickness: f32 = if (state.ui.terrain_create_volume) state.ui.terrain_create_thickness else 0.0;
    _ = create_terrain_at(state, grid_resolution, world_size, thickness, parent, .{ .x = 0.0, .y = 0.0, .z = 0.0 });
}

fn create_volumetric_terrain_at(
    state: *EditorState,
    resolution: u32,
    size: math.Vec3,
    parent: ?engine.ecs_entity.Entity,
    position: math.Vec3,
    chunk_x: i32,
    chunk_y: i32,
    chunk_z: i32,
) ?engine.ecs_entity.Entity {
    var scn = volumetric_terrain.build_scene(resolution, size) orelse return null;

    var name_buf: [64]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "Volumetric Terrain ({d},{d},{d})", .{ chunk_x, chunk_y, chunk_z }) catch "Volumetric Terrain";
    const model_id = model_manager.cardinal_model_manager_add_scene(&state.runtime.model_manager, &scn, null, name_z.ptr);
    if (model_id == 0) {
        scene.cardinal_scene_destroy(&scn);
        return null;
    }

    const created = node_factory.create_node(state.runtime.registry, parent, .MeshInstance3D, "Volumetric Terrain", .{}) catch return null;
    if (state.runtime.registry.get(components.Transform, created)) |tr| {
        tr.position = position;
    }

    const range = get_model_combined_mesh_range(state, model_id) orelse return null;
    if (range.count == 0) return null;

    const vt = components.VolumetricTerrain{
        .size = size,
        .resolution = if (resolution < 1) 1 else resolution,
        .chunk_x = chunk_x,
        .chunk_y = chunk_y,
        .chunk_z = chunk_z,
        .model_id = model_id,
        .mesh_index = range.start,
        .data_id = std.crypto.random.int(u64),
    };
    state.runtime.registry.add(created, vt) catch {};

    _ = volumetric_terrain.ensure_volumetric_terrain_data_for_entity(state, created);
    volumetric_terrain.remesh_volumetric_terrain_initial(state, created.id);

    rebuild_scene_and_schedule_upload(state);
    state.runtime.picking_cache_dirty = true;
    volumetric_terrain.ensure_brick_entities(state, created);

    state.runtime.mark_transform_override_tree(created);

    return created;
}

fn create_volumetric_terrain(state: *EditorState, resolution: u32, size: math.Vec3) void {
    const parent = if (state.runtime.registry.entity_manager.is_alive(state.ui.selected_entity)) state.ui.selected_entity else null;
    _ = create_volumetric_terrain_at(state, resolution, size, parent, .{ .x = 0.0, .y = 0.0, .z = 0.0 }, 0, 0, 0);
}

fn create_volumetric_terrain_grid(state: *EditorState, resolution: u32, chunk_size: math.Vec3, count_x: i32, count_z: i32) void {
    const parent = if (state.runtime.registry.entity_manager.is_alive(state.ui.selected_entity)) state.ui.selected_entity else null;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const root = node_factory.create_node(state.runtime.registry, parent, .Node3D, "Volumetric Terrain World", .{}) catch return;
    state.runtime.mark_transform_override_tree(root);

    const nx: i32 = clamp_i32(count_x, 1, 64);
    const nz: i32 = clamp_i32(count_z, 1, 64);
    const total_x = @as(f32, @floatFromInt(nx)) * chunk_size.x;
    const total_z = @as(f32, @floatFromInt(nz)) * chunk_size.z;
    const origin = math.Vec3{ .x = -total_x * 0.5 + chunk_size.x * 0.5, .y = 0.0, .z = -total_z * 0.5 + chunk_size.z * 0.5 };

    var z: i32 = 0;
    while (z < nz) : (z += 1) {
        var x: i32 = 0;
        while (x < nx) : (x += 1) {
            const pos = math.Vec3{
                .x = origin.x + @as(f32, @floatFromInt(x)) * chunk_size.x,
                .y = origin.y,
                .z = origin.z + @as(f32, @floatFromInt(z)) * chunk_size.z,
            };
            _ = create_volumetric_terrain_at(state, resolution, chunk_size, root, pos, x, 0, z);
        }
    }

    state.ui.selected_entity = root;
    state.ui.selected_entities.clearRetainingCapacity();
    state.ui.selected_entities.put(alloc, root.id, {}) catch {};
    state.ui.scene_graph_focus_target_id = root.id;
    state.ui.scene_graph_focus_pending = true;
}

/// Applies the sculpt brush to the terrain heightmap and combined mesh.
fn apply_sculpt_to_selected(state: *EditorState, entity_id: u64, terr: *components.Terrain, t: *components.Transform, world_hit: math.Vec3) bool {
    const meshes = get_terrain_volume_meshes(state, terr) orelse return false;
    var surface_i32: i32 = 0;
    if (active_stroke) |s| surface_i32 = s.sculpt_surface;
    if (terr.thickness <= 0.01) surface_i32 = 0;
    const ui_mode = state.ui.terrain_sculpt_mode;
    if (surface_i32 == 2 and ui_mode != 0 and ui_mode != 1) {
        surface_i32 = pick_sculpt_surface_for_hit(state, engine.ecs_entity.Entity{ .id = entity_id }, terr, t, world_hit);
    }
    const use_bottom = (surface_i32 == 1);
    const model_mesh = if (use_bottom) meshes.bottom_model orelse return false else meshes.top_model;
    if (model_mesh.vertices == null or model_mesh.vertex_count == 0) return false;
    const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));
    const grid_ctx = derive_grid_from_mesh(terr, meshes.top_model) orelse return false;
    const grid = grid_ctx.grid;
    const verts_per_side = grid_ctx.verts_per_side;
    const data = ensure_terrain_data(state, entity_id, terr, meshes.top_model, meshes.bottom_model, verts_per_side) orelse return false;
    var height_map: []f32 = if (use_bottom) data.bottom_height else data.height;
    const combined_mesh_index: u32 = if (use_bottom) terr.mesh_index + 1 else terr.mesh_index;

    const local_x = world_hit.x - t.position.x;
    const local_z = world_hit.z - t.position.z;

    const half_x = terr.size.x * 0.5;
    const half_z = terr.size.y * 0.5;
    const radius = @max(0.001, state.ui.terrain_brush_radius);
    if (local_x < -half_x - radius or local_x > half_x + radius) return false;
    if (local_z < -half_z - radius or local_z > half_z + radius) return false;
    const mode: i32 = if (use_bottom and (ui_mode == 0 or ui_mode == 1))
        (if (ui_mode == 0) 1 else 0)
    else
        ui_mode;
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

    if (surface_i32 == 2 and (ui_mode == 0 or ui_mode == 1)) {
        const top_mesh = meshes.top_model;
        const bottom_mesh = meshes.bottom_model orelse return false;
        if (top_mesh.vertices == null or bottom_mesh.vertices == null) return false;
        if (top_mesh.vertex_count == 0 or bottom_mesh.vertex_count == 0) return false;
        if (top_mesh.vertex_count != bottom_mesh.vertex_count) return false;
        const top_verts = @as([*]scene.CardinalVertex, @ptrCast(top_mesh.vertices.?));
        const bot_verts = @as([*]scene.CardinalVertex, @ptrCast(bottom_mesh.vertices.?));

        const top_combined = meshes.top_combined;
        const bot_combined = meshes.bottom_combined orelse return false;
        if (top_combined.vertices == null or bot_combined.vertices == null) return false;
        if (top_combined.vertex_count != top_mesh.vertex_count or bot_combined.vertex_count != bottom_mesh.vertex_count) return false;
        const top_comb_verts = @as([*]scene.CardinalVertex, @ptrCast(top_combined.vertices.?));
        const bot_comb_verts = @as([*]scene.CardinalVertex, @ptrCast(bot_combined.vertices.?));

        const dx_neg = @abs(local_x + half_x);
        const dx_pos = @abs(local_x - half_x);
        const dz_neg = @abs(local_z + half_z);
        const dz_pos = @abs(local_z - half_z);

        const want_neg_x = (dx_neg <= dx_pos and dx_neg <= dz_neg and dx_neg <= dz_pos);
        const want_pos_x = (!want_neg_x and dx_pos <= dz_neg and dx_pos <= dz_pos);
        const want_neg_z = (!want_neg_x and !want_pos_x and dz_neg <= dz_pos);
        const want_pos_z = (!want_neg_x and !want_pos_x and !want_neg_z);

        var rect_min_x: u32 = std.math.maxInt(u32);
        var rect_min_z: u32 = std.math.maxInt(u32);
        var rect_max_x: u32 = 0;
        var rect_max_z: u32 = 0;

        const delta_sign: f32 = if (ui_mode == 0) 1.0 else -1.0;

        if (want_neg_x or want_pos_x) {
            const x_fixed: u32 = if (want_neg_x) 0 else grid;
            var z: i32 = min_z;
            while (z <= max_z) : (z += 1) {
                const z_u32: u32 = @intCast(z);
                const vi: u32 = z_u32 * verts_per_side + x_fixed;
                if (vi >= top_mesh.vertex_count) continue;

                const px = (@as(f32, @floatFromInt(x_fixed)) / @as(f32, @floatFromInt(grid))) * terr.size.x - half_x;
                const pz = (@as(f32, @floatFromInt(z_u32)) / @as(f32, @floatFromInt(grid))) * terr.size.y - half_z;
                const dx = px - local_x;
                const dz = pz - local_z;
                const d2 = dx * dx + dz * dz;
                if (d2 > radius * radius) continue;
                const d = @sqrt(d2);
                var w = 1.0 - (d / radius);
                w = w * w;
                const a = strength * w;
                if (a <= 0.0) continue;

                const vi_usize: usize = @intCast(vi);
                const top_wy = t.position.y + data.height[vi_usize];
                const bot_wy = t.position.y + data.bottom_height[vi_usize];
                const dt = @abs(world_hit.y - top_wy);
                const db = @abs(world_hit.y - bot_wy);
                const denom = dt + db + 0.0001;
                const wt = 1.0 - (dt / denom);
                const wb = 1.0 - (db / denom);

                stroke_record_vertex(entity_id, terr, terr.mesh_index, vi, top_verts[vi].py, top_verts[vi].color, pack_splat(data, vi));
                stroke_record_vertex(entity_id, terr, terr.mesh_index + 1, vi, bot_verts[vi].py, bot_verts[vi].color, pack_splat(data, vi));

                data.height[vi_usize] += delta_sign * a * wt;
                data.bottom_height[vi_usize] += delta_sign * a * wb;
                if (data.height[vi_usize] < data.bottom_height[vi_usize] + 0.01) {
                    const mid = (data.height[vi_usize] + data.bottom_height[vi_usize]) * 0.5;
                    data.height[vi_usize] = mid + 0.005;
                    data.bottom_height[vi_usize] = mid - 0.005;
                }

                const top_y = data.height[vi_usize];
                const bot_y = data.bottom_height[vi_usize];
                top_verts[vi].py = top_y;
                bot_verts[vi].py = bot_y;
                top_comb_verts[vi].py = top_y;
                bot_comb_verts[vi].py = bot_y;

                rect_min_x = @min(rect_min_x, x_fixed);
                rect_min_z = @min(rect_min_z, z_u32);
                rect_max_x = @max(rect_max_x, x_fixed);
                rect_max_z = @max(rect_max_z, z_u32);
                changed = true;
            }
        } else if (want_neg_z or want_pos_z) {
            const z_fixed: u32 = if (want_neg_z) 0 else grid;
            var x: i32 = min_x;
            while (x <= max_x) : (x += 1) {
                const x_u32: u32 = @intCast(x);
                const vi: u32 = z_fixed * verts_per_side + x_u32;
                if (vi >= top_mesh.vertex_count) continue;

                const px = (@as(f32, @floatFromInt(x_u32)) / @as(f32, @floatFromInt(grid))) * terr.size.x - half_x;
                const pz = (@as(f32, @floatFromInt(z_fixed)) / @as(f32, @floatFromInt(grid))) * terr.size.y - half_z;
                const dx = px - local_x;
                const dz = pz - local_z;
                const d2 = dx * dx + dz * dz;
                if (d2 > radius * radius) continue;
                const d = @sqrt(d2);
                var w = 1.0 - (d / radius);
                w = w * w;
                const a = strength * w;
                if (a <= 0.0) continue;

                const vi_usize: usize = @intCast(vi);
                const top_wy = t.position.y + data.height[vi_usize];
                const bot_wy = t.position.y + data.bottom_height[vi_usize];
                const dt = @abs(world_hit.y - top_wy);
                const db = @abs(world_hit.y - bot_wy);
                const denom = dt + db + 0.0001;
                const wt = 1.0 - (dt / denom);
                const wb = 1.0 - (db / denom);

                stroke_record_vertex(entity_id, terr, terr.mesh_index, vi, top_verts[vi].py, top_verts[vi].color, pack_splat(data, vi));
                stroke_record_vertex(entity_id, terr, terr.mesh_index + 1, vi, bot_verts[vi].py, bot_verts[vi].color, pack_splat(data, vi));

                data.height[vi_usize] += delta_sign * a * wt;
                data.bottom_height[vi_usize] += delta_sign * a * wb;
                if (data.height[vi_usize] < data.bottom_height[vi_usize] + 0.01) {
                    const mid = (data.height[vi_usize] + data.bottom_height[vi_usize]) * 0.5;
                    data.height[vi_usize] = mid + 0.005;
                    data.bottom_height[vi_usize] = mid - 0.005;
                }

                const top_y = data.height[vi_usize];
                const bot_y = data.bottom_height[vi_usize];
                top_verts[vi].py = top_y;
                bot_verts[vi].py = bot_y;
                top_comb_verts[vi].py = top_y;
                bot_comb_verts[vi].py = bot_y;

                rect_min_x = @min(rect_min_x, x_u32);
                rect_min_z = @min(rect_min_z, z_fixed);
                rect_max_x = @max(rect_max_x, x_u32);
                rect_max_z = @max(rect_max_z, z_fixed);
                changed = true;
            }
        }

        if (!changed) return false;
        upload_terrain_dirty_rect(state, entity_id, data, rect_min_x, rect_min_z, rect_max_x, rect_max_z);
        update_terrain_volume_meshes(state, entity_id);
        state.runtime.pending_scene = state.runtime.combined_scene;
        state.runtime.scene_upload_pending = true;
        return true;
    }

    if (mode == 3) {
        const self_ent = engine.ecs_entity.Entity{ .id = entity_id };
        const want_left = math.Vec3{ .x = t.position.x - terr.size.x, .y = t.position.y, .z = t.position.z };
        const want_right = math.Vec3{ .x = t.position.x + terr.size.x, .y = t.position.y, .z = t.position.z };
        const want_up = math.Vec3{ .x = t.position.x, .y = t.position.y, .z = t.position.z - terr.size.y };
        const want_down = math.Vec3{ .x = t.position.x, .y = t.position.y, .z = t.position.z + terr.size.y };

        var left_td: ?*editor_state.TerrainData = null;
        var right_td: ?*editor_state.TerrainData = null;
        var up_td: ?*editor_state.TerrainData = null;
        var down_td: ?*editor_state.TerrainData = null;

        const wants = [_]struct { pos: math.Vec3, out: *?*editor_state.TerrainData }{
            .{ .pos = want_left, .out = &left_td },
            .{ .pos = want_right, .out = &right_td },
            .{ .pos = want_up, .out = &up_td },
            .{ .pos = want_down, .out = &down_td },
        };
        for (wants) |w| {
            if (terrain_volume.find_adjacent_terrain(&state.runtime, self_ent, w.pos)) |n_ent| {
                const n_terr = state.runtime.registry.get(components.Terrain, n_ent) orelse continue;
                const meshes_n = get_terrain_volume_meshes(state, n_terr) orelse continue;
                const grid_n = derive_grid_from_mesh(n_terr, meshes_n.top_model) orelse continue;
                if (grid_n.verts_per_side != verts_per_side) continue;
                w.out.* = ensure_terrain_data(state, n_ent.id, n_terr, meshes_n.top_model, meshes_n.bottom_model, grid_n.verts_per_side);
            }
        }

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
                const z_u32: u32 = @intCast(z);
                const left_h = if (x > 0)
                    height_map[@as(usize, left)]
                else if (left_td) |td|
                    (if (use_bottom) td.bottom_height[@as(usize, z_u32) * @as(usize, verts_per_side) + @as(usize, grid)] else td.height[@as(usize, z_u32) * @as(usize, verts_per_side) + @as(usize, grid)])
                else
                    height_map[@as(usize, vi)];
                const right_h = if (x < @as(i32, @intCast(grid)))
                    height_map[@as(usize, right)]
                else if (right_td) |td|
                    (if (use_bottom) td.bottom_height[@as(usize, z_u32) * @as(usize, verts_per_side)] else td.height[@as(usize, z_u32) * @as(usize, verts_per_side)])
                else
                    height_map[@as(usize, vi)];
                const up_h = if (z > 0)
                    height_map[@as(usize, down)]
                else if (up_td) |td|
                    (if (use_bottom) td.bottom_height[@as(usize, grid) * @as(usize, verts_per_side) + @as(usize, @intCast(x))] else td.height[@as(usize, grid) * @as(usize, verts_per_side) + @as(usize, @intCast(x))])
                else
                    height_map[@as(usize, vi)];
                const down_h = if (z < @as(i32, @intCast(grid)))
                    height_map[@as(usize, up)]
                else if (down_td) |td|
                    (if (use_bottom) td.bottom_height[@as(usize, @intCast(x))] else td.height[@as(usize, @intCast(x))])
                else
                    height_map[@as(usize, vi)];
                tmp[ti] = (height_map[@as(usize, vi)] + left_h + right_h + up_h + down_h) / 5.0;
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
                        stroke_record_vertex(entity_id, terr, combined_mesh_index, vi, verts[vi].py, verts[vi].color, pack_splat(data, vi));
                        const vi_usize: usize = @intCast(vi);
                        height_map[vi_usize] += (tmp[ti] - height_map[vi_usize]) * a;
                        if (use_bottom) {
                            height_map[vi_usize] = @min(height_map[vi_usize], data.height[vi_usize] - 0.01);
                        } else if (terr.thickness > 0.01) {
                            height_map[vi_usize] = @max(height_map[vi_usize], data.bottom_height[vi_usize] + 0.01);
                        }
                        verts[vi].py = height_map[vi_usize];
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
                active_stroke.?.flatten_target_y = height_map[@as(usize, vi)];
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

                stroke_record_vertex(entity_id, terr, combined_mesh_index, vi, verts[vi].py, verts[vi].color, pack_splat(data, vi));
                const vi_usize: usize = @intCast(vi);
                switch (mode) {
                    0 => height_map[vi_usize] += strength * w,
                    1 => height_map[vi_usize] -= strength * w,
                    2 => {
                        const current_y = height_map[vi_usize];
                        const target_y = if (active_stroke) |s| if (s.flatten_has_target) s.flatten_target_y else current_y else current_y;
                        height_map[vi_usize] += (target_y - height_map[vi_usize]) * (strength * w);
                    },
                    else => {},
                }
                if (use_bottom) {
                    height_map[vi_usize] = @min(height_map[vi_usize], data.height[vi_usize] - 0.01);
                } else if (terr.thickness > 0.01) {
                    height_map[vi_usize] = @max(height_map[vi_usize], data.bottom_height[vi_usize] + 0.01);
                }
                verts[vi].py = height_map[vi_usize];
                changed = true;
            }
        }
    }

    if (!changed) return false;

    if (!use_bottom) {
        upload_terrain_dirty_rect(state, entity_id, data, @intCast(min_x), @intCast(min_z), @intCast(max_x), @intCast(max_z));
    }
    update_terrain_volume_meshes(state, entity_id);
    state.runtime.pending_scene = state.runtime.combined_scene;
    state.runtime.scene_upload_pending = true;
    return true;
}

/// Applies the paint brush to the terrain splatmap and combined mesh vertex colors.
fn apply_paint_to_selected(state: *EditorState, entity_id: u64, terr: *components.Terrain, t: *components.Transform, world_hit: math.Vec3) bool {
    const meshes = get_terrain_volume_meshes(state, terr) orelse return false;
    const model_mesh = meshes.top_model;
    if (model_mesh.vertices == null or model_mesh.vertex_count == 0) return false;
    const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));
    const grid_ctx = derive_grid_from_mesh(terr, model_mesh) orelse return false;
    const grid = grid_ctx.grid;
    const verts_per_side = grid_ctx.verts_per_side;
    const data = ensure_terrain_data(state, entity_id, terr, meshes.top_model, meshes.bottom_model, verts_per_side) orelse return false;
    ensure_terrain_material_bound(state, terr, data);

    const local_x = world_hit.x - t.position.x;
    const local_z = world_hit.z - t.position.z;

    const half_x = terr.size.x * 0.5;
    const half_z = terr.size.y * 0.5;
    const radius = @max(0.001, state.ui.terrain_brush_radius);
    if (local_x < -half_x - radius or local_x > half_x + radius) return false;
    if (local_z < -half_z - radius or local_z > half_z + radius) return false;
    const strength = @min(1.0, @max(0.0, state.ui.terrain_brush_strength));

    const layer_i32 = clamp_i32(state.ui.terrain_paint_layer, 0, 3);
    const layer: u32 = @intCast(layer_i32);
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

            const base = @as(usize, vi) * 4;
            if (base + 3 >= data.splat.len) continue;

            stroke_record_vertex(entity_id, terr, terr.mesh_index, vi, verts[vi].py, verts[vi].color, pack_splat(data, vi));

            var ws = [4]f32{
                @as(f32, @floatFromInt(data.splat[base + 0])) / 255.0,
                @as(f32, @floatFromInt(data.splat[base + 1])) / 255.0,
                @as(f32, @floatFromInt(data.splat[base + 2])) / 255.0,
                @as(f32, @floatFromInt(data.splat[base + 3])) / 255.0,
            };
            const prev_t = ws[@intCast(layer)];
            const next_t = prev_t + (1.0 - prev_t) * a;

            var other_sum: f32 = 0.0;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                if (k == layer) continue;
                other_sum += ws[k];
            }

            if (other_sum > 0.000001) {
                const scale = (1.0 - next_t) / other_sum;
                k = 0;
                while (k < 4) : (k += 1) {
                    if (k == layer) continue;
                    ws[k] = ws[k] * scale;
                }
            } else {
                k = 0;
                while (k < 4) : (k += 1) {
                    if (k == layer) continue;
                    ws[k] = 0.0;
                }
            }
            ws[@intCast(layer)] = next_t;

            data.splat[base + 0] = float_to_u8(ws[0]);
            data.splat[base + 1] = float_to_u8(ws[1]);
            data.splat[base + 2] = float_to_u8(ws[2]);
            data.splat[base + 3] = float_to_u8(ws[3]);
            const carve_alpha = verts[vi].color[3];
            verts[vi].color = .{ ws[0], ws[1], ws[2], carve_alpha };
            changed = true;
        }
    }

    if (changed) {
        upload_terrain_dirty_rect(state, entity_id, data, @intCast(min_x), @intCast(min_z), @intCast(max_x), @intCast(max_z));
    }

    return changed;
}

fn apply_carve_to_selected(state: *EditorState, entity_id: u64, terr: *components.Terrain, t: *components.Transform, world_hit: math.Vec3) bool {
    const meshes = get_terrain_volume_meshes(state, terr) orelse return false;
    const model_mesh = meshes.top_model;
    if (model_mesh.vertices == null or model_mesh.vertex_count == 0 or model_mesh.indices == null or model_mesh.index_count == 0) return false;
    const verts = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?));
    const grid_ctx = derive_grid_from_mesh(terr, model_mesh) orelse return false;
    const grid = grid_ctx.grid;
    const verts_per_side = grid_ctx.verts_per_side;
    const data = ensure_terrain_data(state, entity_id, terr, meshes.top_model, meshes.bottom_model, verts_per_side) orelse return false;

    const local_x = world_hit.x - t.position.x;
    const local_z = world_hit.z - t.position.z;

    const half_x = terr.size.x * 0.5;
    const half_z = terr.size.y * 0.5;
    const radius = @max(0.001, state.ui.terrain_brush_radius);
    if (local_x < -half_x - radius or local_x > half_x + radius) return false;
    if (local_z < -half_z - radius or local_z > half_z + radius) return false;
    const strength = @min(1.0, @max(0.0, state.ui.terrain_brush_strength));

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

    const remove_mode = (state.ui.terrain_carve_mode == 0);
    var changed = false;

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

            stroke_record_vertex(entity_id, terr, terr.mesh_index, vi, verts[vi].py, verts[vi].color, pack_splat(data, vi));

            const prev = clamp01(verts[vi].color[3]);
            const next = if (remove_mode) prev * (1.0 - a) else prev + (1.0 - prev) * a;
            verts[vi].color[3] = next;
            changed = true;
        }
    }

    if (!changed) return false;

    rewrite_indices_from_alpha(model_mesh, verts_per_side);
    rewrite_indices_from_alpha(meshes.top_combined, verts_per_side);
    update_terrain_volume_meshes(state, entity_id);
    state.runtime.pending_scene = state.runtime.combined_scene;
    state.runtime.scene_upload_pending = true;
    return true;
}

fn update_terrain_volume_meshes(state: *EditorState, entity_id: u64) void {
    terrain_volume.update_terrain_volume_meshes(&state.runtime, entity_id);
}

/// Loads an image from disk and uploads it into a terrain layer runtime texture.
///
/// If the layer already has a runtime texture, it is replaced.
fn set_terrain_layer_texture_from_path(state: *EditorState, terr: *components.Terrain, td: *editor_state.TerrainData, layer_index: usize, path: []const u8) void {
    if (layer_index >= 4) return;
    if (path.len == 0) return;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const path_z = alloc.dupeZ(u8, path) catch return;
    defer alloc.free(path_z);

    var tex = std.mem.zeroes(texture_loader.TextureData);
    if (!texture_loader.texture_load_from_disk(@ptrCast(path_z.ptr), &tex)) {
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Terrain layer {d}: failed to load texture '{s}'", .{ layer_index, std.fs.path.basename(path) }) catch {};
        return;
    }
    defer texture_loader.texture_data_free(&tex);

    if (tex.data == null or tex.data_size == 0 or tex.width == 0 or tex.height == 0) {
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Terrain layer {d}: invalid texture data for '{s}'", .{ layer_index, std.fs.path.basename(path) }) catch {};
        return;
    }

    if (td.layer_handles[layer_index] != std.math.maxInt(u32)) {
        const gen = c.imgui_bridge_vk_generation();
        if (td.layer_imgui_ids[layer_index] != 0 and td.layer_imgui_generations[layer_index] == gen and gen != 0) {
            c.imgui_bridge_vk_remove_texture(td.layer_imgui_ids[layer_index]);
        }
        td.layer_imgui_ids[layer_index] = 0;
        td.layer_imgui_generations[layer_index] = 0;
        renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, td.layer_handles[layer_index]);
        td.layer_handles[layer_index] = std.math.maxInt(u32);
    }

    var handle: u32 = 0;
    const fmt: c.VkFormat = @intCast(tex.format);
    if (!renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, tex.width, tex.height, fmt, &handle)) {
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Terrain layer {d}: failed to allocate GPU texture for '{s}'", .{ layer_index, std.fs.path.basename(path) }) catch {};
        return;
    }

    const size_usize: usize = @intCast(tex.data_size);
    if (!renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, handle, @ptrCast(tex.data.?), size_usize)) {
        renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Terrain layer {d}: failed to upload texture '{s}'", .{ layer_index, std.fs.path.basename(path) }) catch {};
        return;
    }

    td.layer_handles[layer_index] = handle;
    ensure_terrain_material_bound(state, terr, td);
}

fn ensure_imgui_texture_id_for_layer(state: *EditorState, td: *editor_state.TerrainData, layer_index: usize) u64 {
    if (layer_index >= 4) return 0;
    const gen = c.imgui_bridge_vk_generation();
    if (td.layer_imgui_ids[layer_index] != 0 and td.layer_imgui_generations[layer_index] == gen and gen != 0) {
        return td.layer_imgui_ids[layer_index];
    }
    td.layer_imgui_ids[layer_index] = 0;
    td.layer_imgui_generations[layer_index] = 0;
    const handle = td.layer_handles[layer_index];
    if (handle == std.math.maxInt(u32)) return 0;
    if (gen == 0) return 0;

    var sampler_raw: ?*anyopaque = null;
    var view_raw: ?*anyopaque = null;
    if (!renderer.cardinal_renderer_runtime_texture_get_vk_handles(state.runtime.renderer, handle, @ptrCast(@alignCast(&sampler_raw)), @ptrCast(@alignCast(&view_raw)))) return 0;
    if (sampler_raw == null or view_raw == null) return 0;
    const id = c.imgui_bridge_vk_add_texture(@ptrCast(sampler_raw), @ptrCast(view_raw), c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    td.layer_imgui_ids[layer_index] = id;
    td.layer_imgui_generations[layer_index] = if (id != 0) gen else 0;
    return id;
}

fn try_apply_default_texture_to_selected_layer0(state: *EditorState) void {
    const default_path_len = std.mem.indexOfScalar(u8, &state.ui.terrain_default_texture_path, 0) orelse state.ui.terrain_default_texture_path.len;
    if (default_path_len == 0) return;
    const path = state.ui.terrain_default_texture_path[0..default_path_len];

    const selected = state.ui.selected_entity;
    const terr_ptr = if (state.runtime.registry.entity_manager.is_alive(selected)) state.runtime.registry.get(components.Terrain, selected) else null;
    if (terr_ptr == null) return;

    if (get_terrain_volume_meshes(state, terr_ptr.?)) |meshes| {
        if (derive_grid_from_mesh(terr_ptr.?, meshes.top_model)) |grid_ctx| {
            if (ensure_terrain_data(state, selected.id, terr_ptr.?, meshes.top_model, meshes.bottom_model, grid_ctx.verts_per_side)) |td| {
                set_terrain_layer_texture_from_path(state, terr_ptr.?, td, 0, path);
            }
        }
    }
}

/// Draws the Terrain panel UI.
pub fn draw_terrain_panel(state: *EditorState) void {
    if (!state.ui.show_terrain_panel) return;
    const open = c.imgui_bridge_begin("Terrain", &state.ui.show_terrain_panel, 0);
    defer c.imgui_bridge_end();
    if (!open) return;

    _ = c.imgui_bridge_drag_float("Create Size", &state.ui.terrain_create_size, 0.5, 1.0, 4096.0, "%.1f", 0);
    _ = c.imgui_bridge_drag_float("Create Resolution", &state.ui.terrain_create_resolution, 1.0, 2.0, 1024.0, "%.0f", 0);
    _ = c.imgui_bridge_checkbox("Create Volume", &state.ui.terrain_create_volume);
    if (state.ui.terrain_create_volume) {
        _ = c.imgui_bridge_drag_float("Create Thickness", &state.ui.terrain_create_thickness, 0.1, 0.01, 200.0, "%.2f", 0);
    }

    const default_path_len = std.mem.indexOfScalar(u8, &state.ui.terrain_default_texture_path, 0) orelse state.ui.terrain_default_texture_path.len;
    if (default_path_len > 0) {
        c.imgui_bridge_text_wrapped("Default Texture: %s", @as([*:0]const u8, @ptrCast(&state.ui.terrain_default_texture_path)));
    } else {
        c.imgui_bridge_text_wrapped("Default Texture: (none)");
    }
    var apply_default_to_layer0 = false;
    if (c.imgui_bridge_begin_drag_drop_target()) {
        if (c.imgui_bridge_accept_drag_drop_payload("ASSET_PATH", 0)) |payload| {
            if (c.imgui_bridge_payload_is_delivery(payload)) {
                const data_ptr = c.imgui_bridge_payload_get_data(payload);
                if (data_ptr != null) {
                    const path_c: [*:0]const u8 = @ptrCast(@alignCast(data_ptr));
                    const path = std.mem.span(path_c);
                    if (is_texture_asset_path(path)) {
                        const len = @min(path.len, state.ui.terrain_default_texture_path.len - 1);
                        @memcpy(state.ui.terrain_default_texture_path[0..len], path[0..len]);
                        state.ui.terrain_default_texture_path[len] = 0;
                        apply_default_to_layer0 = true;
                    }
                }
            }
        }
        c.imgui_bridge_end_drag_drop_target();
    }
    if (c.imgui_bridge_button("Set Default Texture...")) {
        const filter = "Textures\x00*.png;*.jpg;*.jpeg;*.tga;*.bmp;*.dds;*.hdr;*.exr\x00All Files\x00*.*\x00";
        if (platform.open_file_dialog(memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator(), filter, null)) |picked| {
            defer memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator().free(picked);
            const len = @min(picked.len, state.ui.terrain_default_texture_path.len - 1);
            @memcpy(state.ui.terrain_default_texture_path[0..len], picked[0..len]);
            state.ui.terrain_default_texture_path[len] = 0;
            apply_default_to_layer0 = true;
        }
    }
    c.imgui_bridge_same_line(0, -1);
    if (c.imgui_bridge_button("Clear Default")) {
        @memset(&state.ui.terrain_default_texture_path, 0);
    }
    if (apply_default_to_layer0) {
        try_apply_default_texture_to_selected_layer0(state);
    }

    if (c.imgui_bridge_button("Create Terrain")) {
        const res: u32 = @intFromFloat(std.math.clamp(state.ui.terrain_create_resolution, 2.0, 1024.0));
        const size: f32 = std.math.clamp(state.ui.terrain_create_size, 1.0, 4096.0);
        create_terrain(state, res, size);
    }
    if (enable_volumetric_terrain) {
        c.imgui_bridge_same_line(0, -1);
        if (c.imgui_bridge_button("Create Volumetric Terrain")) {
            const res: u32 = @intFromFloat(std.math.clamp(state.ui.terrain_create_resolution, 4.0, 64.0));
            const size_xz: f32 = std.math.clamp(state.ui.terrain_create_size, 1.0, 4096.0);
            const size_y: f32 = std.math.clamp(state.ui.terrain_create_thickness, 1.0, 4096.0);
            create_volumetric_terrain(state, res, .{ .x = size_xz, .y = size_y, .z = size_xz });
        }
        c.imgui_bridge_same_line(0, -1);
        if (c.imgui_bridge_button("Create Volumetric Grid")) {
            const res: u32 = @intFromFloat(std.math.clamp(state.ui.terrain_create_resolution, 4.0, 64.0));
            const size_xz: f32 = std.math.clamp(state.ui.terrain_create_size, 1.0, 4096.0);
            const size_y: f32 = std.math.clamp(state.ui.terrain_create_thickness, 1.0, 4096.0);
            create_volumetric_terrain_grid(state, res, .{ .x = size_xz, .y = size_y, .z = size_xz }, state.ui.volumetric_grid_x, state.ui.volumetric_grid_z);
        }

        var gx: c_int = state.ui.volumetric_grid_x;
        var gz: c_int = state.ui.volumetric_grid_z;
        _ = c.imgui_bridge_drag_int("Grid X", &gx, 0.2, 1, 64, "%d", 0);
        _ = c.imgui_bridge_drag_int("Grid Z", &gz, 0.2, 1, 64, "%d", 0);
        state.ui.volumetric_grid_x = @intCast(gx);
        state.ui.volumetric_grid_z = @intCast(gz);
    }

    c.imgui_bridge_separator();

    const selected = state.ui.selected_entity;
    const terr_ptr = if (state.runtime.registry.entity_manager.is_alive(selected)) state.runtime.registry.get(components.Terrain, selected) else null;
    const vt_ptr = if (state.runtime.registry.entity_manager.is_alive(selected)) state.runtime.registry.get(components.VolumetricTerrain, selected) else null;
    if (terr_ptr == null and vt_ptr == null) {
        c.imgui_bridge_text_wrapped("Select a Terrain entity to edit.");
        return;
    }

    if (vt_ptr != null and !enable_volumetric_terrain) {
        c.imgui_bridge_text_wrapped("Volumetric Terrain is disabled for now. Select a Terrain entity to edit.");
        return;
    }

    if (vt_ptr != null and enable_volumetric_terrain) {
        const vt = vt_ptr.?;
        c.imgui_bridge_text_wrapped("Volumetric Terrain (density field).");
        c.imgui_bridge_text("Resolution: %d", vt.resolution);
        c.imgui_bridge_text("Size: %.2f, %.2f, %.2f", vt.size.x, vt.size.y, vt.size.z);
        c.imgui_bridge_text("Chunk: %d,%d,%d", vt.chunk_x, vt.chunk_y, vt.chunk_z);

        _ = volumetric_terrain.ensure_volumetric_terrain_data_for_entity(state, selected);

        _ = c.imgui_bridge_checkbox("Enable Edit (hold Shift + LMB)", &state.ui.terrain_sculpt_enabled);
        const tool_items = [_][*:0]const u8{
            "Sculpt",
            "Paint",
        };
        var tool_ptr: i32 = @intCast(std.math.clamp(state.ui.terrain_tool, 0, 1));
        _ = c.imgui_bridge_combo("Tool", &tool_ptr, &tool_items[0], @intCast(tool_items.len), 10);
        state.ui.terrain_tool = @intCast(tool_ptr);

        if (state.ui.terrain_tool == 0) {
            const mode_items = [_][*:0]const u8{
                "Add",
                "Remove",
                "Flatten",
                "Smooth",
            };
            var mode_ptr: i32 = @intCast(std.math.clamp(state.ui.terrain_sculpt_mode, 0, @as(i32, @intCast(mode_items.len - 1))));
            _ = c.imgui_bridge_combo("Mode", &mode_ptr, &mode_items[0], @intCast(mode_items.len), 10);
            state.ui.terrain_sculpt_mode = @intCast(mode_ptr);
        } else {
            const layer_items = [_][*:0]const u8{
                "Layer 0",
                "Layer 1",
                "Layer 2",
                "Layer 3",
            };
            var layer_ptr: i32 = @intCast(std.math.clamp(state.ui.terrain_paint_layer, 0, 3));
            _ = c.imgui_bridge_combo("Layer", &layer_ptr, &layer_items[0], @intCast(layer_items.len), 10);
            state.ui.terrain_paint_layer = @intCast(layer_ptr);
        }

        _ = c.imgui_bridge_drag_float("Brush Radius", &state.ui.terrain_brush_radius, 0.05, 0.1, 200.0, "%.2f", 0);
        if (state.ui.terrain_tool == 0) {
            _ = c.imgui_bridge_drag_float("Brush Strength", &state.ui.terrain_brush_strength, 0.01, 0.0, 5.0, "%.3f", 0);
        } else {
            _ = c.imgui_bridge_drag_float("Paint Strength", &state.ui.terrain_brush_strength, 0.01, 0.0, 1.0, "%.3f", 0);
        }

        const falloff_items = [_][*:0]const u8{
            "Smooth",
            "Linear",
            "Gaussian",
        };
        var falloff_ptr: i32 = @intCast(std.math.clamp(state.ui.terrain_brush_falloff, 0, @as(i32, @intCast(falloff_items.len - 1))));
        _ = c.imgui_bridge_combo("Falloff", &falloff_ptr, &falloff_items[0], @intCast(falloff_items.len), 10);
        state.ui.terrain_brush_falloff = falloff_ptr;
        _ = c.imgui_bridge_drag_float("Brush Spacing", &state.ui.terrain_brush_spacing, 0.01, 0.0, 2.0, "%.2f", 0);

        const sculpt_down = state.ui.terrain_sculpt_enabled and c.imgui_bridge_is_shift_down() and c.imgui_bridge_is_mouse_down(0) and !state.runtime.mouse_captured;
        const paint_down = state.ui.terrain_sculpt_enabled and c.imgui_bridge_is_shift_down() and c.imgui_bridge_is_mouse_down(0) and !state.runtime.mouse_captured;
        const paint_erase = state.ui.terrain_sculpt_enabled and c.imgui_bridge_is_shift_down() and c.imgui_bridge_is_mouse_down(1) and !state.runtime.mouse_captured;

        var preview_hit = math.Vec3{ .x = 0.0, .y = 0.0, .z = 0.0 };
        var preview_enabled = false;
        if (state.ui.terrain_sculpt_enabled and c.imgui_bridge_is_shift_down() and !state.runtime.mouse_captured) {
            if (selection_raycast.get_ray_from_mouse(state)) |ray| {
                var best_t: f32 = std.math.floatMax(f32);
                var best_hit: ?math.Vec3 = null;

                const selected_hier = state.runtime.registry.get(components.Hierarchy, selected);
                const selected_parent = if (selected_hier) |h| h.parent else null;

                var bview = state.runtime.registry.view(components.VolumetricTerrainBrick);
                var bit = bview.iterator();
                while (bit.next()) |bentry| {
                    const brick = bentry.component;
                    const parent_ent = engine.ecs_entity.Entity{ .id = brick.parent_id };
                    if (!state.runtime.registry.entity_manager.is_alive(parent_ent)) continue;
                    const other = state.runtime.registry.get(components.VolumetricTerrain, parent_ent) orelse continue;
                    if (other.resolution != vt.resolution) continue;
                    if (@abs(other.size.x - vt.size.x) > 0.001) continue;
                    if (@abs(other.size.y - vt.size.y) > 0.001) continue;
                    if (@abs(other.size.z - vt.size.z) > 0.001) continue;

                    if (selected_parent) |p| {
                        const other_hier = state.runtime.registry.get(components.Hierarchy, parent_ent) orelse continue;
                        if (other_hier.parent == null or other_hier.parent.?.id != p.id) continue;
                    } else {
                        if (parent_ent.id != selected.id) continue;
                    }

                    const mr = state.runtime.registry.get(components.MeshRenderer, bentry.entity) orelse continue;
                    if (!mr.visible) continue;
                    if (mr.mesh.index >= state.runtime.combined_scene.mesh_count) continue;
                    if (selection_raycast.raycast_combined_mesh_point_allow_invisible(state, mr.mesh.index, ray)) |hit| {
                        const t_hit = hit.sub(ray.origin).dot(ray.direction);
                        if (t_hit > 0.0 and t_hit < best_t) {
                            best_t = t_hit;
                            best_hit = hit;
                        }
                    }
                }

                if (best_hit) |hit| {
                    preview_hit = hit;
                    preview_enabled = true;
                }
            }
        }

        state.ui.terrain_brush_outline_enabled = preview_enabled;
        if (preview_enabled) {
            state.ui.terrain_brush_outline_pos = .{ preview_hit.x, preview_hit.y, preview_hit.z };
            state.ui.terrain_brush_outline_radius = state.ui.terrain_brush_radius;
            state.ui.terrain_brush_outline_strength = state.ui.terrain_brush_strength;
            state.ui.terrain_brush_outline_tool = state.ui.terrain_tool;
            state.ui.terrain_brush_outline_mode = if (state.ui.terrain_tool == 0) state.ui.terrain_sculpt_mode else state.ui.terrain_paint_layer;
            state.ui.terrain_brush_outline_surface = 0;
        }

        renderer.cardinal_renderer_set_terrain_brush_preview(
            state.runtime.renderer,
            preview_enabled,
            preview_hit.x,
            preview_hit.y,
            preview_hit.z,
            state.ui.terrain_brush_radius,
            state.ui.terrain_brush_strength,
            @intCast(state.ui.terrain_tool),
            @intCast(if (state.ui.terrain_tool == 0) state.ui.terrain_sculpt_mode else state.ui.terrain_paint_layer),
        );

        if (state.ui.terrain_tool == 0 and sculpt_down) {
            if (preview_enabled) {
                if (!brush_can_stamp(state, preview_hit)) {
                    state.ui.terrain_brush_last_mouse_down = true;
                    return;
                }
                brush_record_stamp(state, preview_hit);
                volumetric_stroke_begin(state.ui.terrain_tool, state.ui.terrain_sculpt_mode);

                const selected_hier = state.runtime.registry.get(components.Hierarchy, selected);
                const selected_parent = if (selected_hier) |h| h.parent else null;
                var vview = state.runtime.registry.view(components.VolumetricTerrain);
                var vit = vview.iterator();
                while (vit.next()) |entry| {
                    const ent = entry.entity;
                    const other = entry.component;
                    if (other.resolution != vt.resolution) continue;
                    if (@abs(other.size.x - vt.size.x) > 0.001) continue;
                    if (@abs(other.size.y - vt.size.y) > 0.001) continue;
                    if (@abs(other.size.z - vt.size.z) > 0.001) continue;

                    if (selected_parent) |p| {
                        const other_hier = state.runtime.registry.get(components.Hierarchy, ent) orelse continue;
                        if (other_hier.parent == null or other_hier.parent.?.id != p.id) continue;
                    } else {
                        if (ent.id != selected.id) continue;
                    }

                    const tr = state.runtime.registry.get(components.Transform, ent) orelse continue;
                    const half = other.size.mul(0.5);
                    const aabb_min = tr.position.sub(half);
                    const aabb_max = tr.position.add(half);
                    if (!sphere_intersects_aabb(preview_hit, state.ui.terrain_brush_radius, aabb_min, aabb_max)) continue;
                    volumetric_stroke_capture_before(state, ent.id);
                }

                volumetric_terrain.apply_sculpt_group(state, selected.id, preview_hit, state.ui.terrain_brush_radius, state.ui.terrain_brush_strength, state.ui.terrain_sculpt_mode);
                state.ui.terrain_brush_last_mouse_down = true;
            }
        } else if (state.ui.terrain_tool == 1 and (paint_down or paint_erase)) {
            if (preview_enabled) {
                if (!brush_can_stamp(state, preview_hit)) {
                    state.ui.terrain_brush_last_mouse_down = true;
                    return;
                }
                brush_record_stamp(state, preview_hit);
                volumetric_stroke_begin(state.ui.terrain_tool, state.ui.terrain_paint_layer);

                const selected_hier = state.runtime.registry.get(components.Hierarchy, selected);
                const selected_parent = if (selected_hier) |h| h.parent else null;
                var vview = state.runtime.registry.view(components.VolumetricTerrain);
                var vit = vview.iterator();
                while (vit.next()) |entry| {
                    const ent = entry.entity;
                    const other = entry.component;
                    if (other.resolution != vt.resolution) continue;
                    if (@abs(other.size.x - vt.size.x) > 0.001) continue;
                    if (@abs(other.size.y - vt.size.y) > 0.001) continue;
                    if (@abs(other.size.z - vt.size.z) > 0.001) continue;

                    if (selected_parent) |p| {
                        const other_hier = state.runtime.registry.get(components.Hierarchy, ent) orelse continue;
                        if (other_hier.parent == null or other_hier.parent.?.id != p.id) continue;
                    } else {
                        if (ent.id != selected.id) continue;
                    }

                    const tr = state.runtime.registry.get(components.Transform, ent) orelse continue;
                    const half = other.size.mul(0.5);
                    const aabb_min = tr.position.sub(half);
                    const aabb_max = tr.position.add(half);
                    if (!sphere_intersects_aabb(preview_hit, state.ui.terrain_brush_radius, aabb_min, aabb_max)) continue;
                    volumetric_stroke_capture_before(state, ent.id);
                }

                volumetric_terrain.apply_paint_group(state, selected.id, preview_hit, state.ui.terrain_brush_radius, std.math.clamp(state.ui.terrain_brush_strength, 0.0, 1.0), @intCast(state.ui.terrain_paint_layer), paint_erase);
                state.ui.terrain_brush_last_mouse_down = true;
            }
        } else if (state.ui.terrain_brush_last_mouse_down) {
            volumetric_stroke_end_and_push_undo(state);
            state.ui.terrain_brush_stamp_valid = false;
            state.ui.terrain_brush_last_mouse_down = false;
        }
        return;
    }

    if (get_terrain_volume_meshes(state, terr_ptr.?)) |meshes| {
        if (derive_grid_from_mesh(terr_ptr.?, meshes.top_model)) |grid_ctx| {
            if (ensure_terrain_data(state, selected.id, terr_ptr.?, meshes.top_model, meshes.bottom_model, grid_ctx.verts_per_side)) |td| {
                ensure_terrain_material_bound(state, terr_ptr.?, td);
            }
        }
    }

    if (state.runtime.registry.get(components.Transform, selected)) |tr| {
        c.imgui_bridge_separator();
        c.imgui_bridge_text_wrapped("Extend terrain by adding adjacent chunks.");

        const hier = state.runtime.registry.get(components.Hierarchy, selected);
        const parent = if (hier) |h| if (h.parent) |p| p else null else null;

        const res: u32 = terr_ptr.?.resolution;
        const size_x: f32 = terr_ptr.?.size.x;
        const size_z: f32 = terr_ptr.?.size.y;

        var pos_px = tr.position;
        pos_px.x += size_x;
        if (c.imgui_bridge_button("+X Chunk")) {
            _ = create_terrain_at(state, res, size_x, terr_ptr.?.thickness, parent, pos_px);
        }
        c.imgui_bridge_same_line(0, -1);
        var pos_nx = tr.position;
        pos_nx.x -= size_x;
        if (c.imgui_bridge_button("-X Chunk")) {
            _ = create_terrain_at(state, res, size_x, terr_ptr.?.thickness, parent, pos_nx);
        }

        var pos_pz = tr.position;
        pos_pz.z += size_z;
        if (c.imgui_bridge_button("+Z Chunk")) {
            _ = create_terrain_at(state, res, size_x, terr_ptr.?.thickness, parent, pos_pz);
        }
        c.imgui_bridge_same_line(0, -1);
        var pos_nz = tr.position;
        pos_nz.z -= size_z;
        if (c.imgui_bridge_button("-Z Chunk")) {
            _ = create_terrain_at(state, res, size_x, terr_ptr.?.thickness, parent, pos_nz);
        }

        c.imgui_bridge_text("Thickness: %.2f", terr_ptr.?.thickness);
    }

    _ = c.imgui_bridge_checkbox("Enable Edit (hold Shift + LMB)", &state.ui.terrain_sculpt_enabled);

    const tool_items = [_][*:0]const u8{
        "Sculpt Height",
        "Paint Texture",
        "Carve",
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
    } else if (state.ui.terrain_tool == 1) {
        _ = c.imgui_bridge_drag_float("Brush Strength", &state.ui.terrain_brush_strength, 0.01, 0.0, 1.0, "%.3f", 0);
        if (c.imgui_bridge_drag_float("Texture Tiling", &state.ui.terrain_texture_tiling, 0.1, 0.1, 128.0, "%.2f", 0)) {
            if (state.runtime.terrain_data_by_entity.getPtr(selected.id)) |td| {
                ensure_terrain_material_bound(state, terr_ptr.?, td);
            }
        }
        c.imgui_bridge_separator();
        c.imgui_bridge_text_wrapped("Layer Textures:");

        const layer_names = [_][*:0]const u8{
            "Layer 0",
            "Layer 1",
            "Layer 2",
            "Layer 3",
        };

        if (state.runtime.terrain_data_by_entity.getPtr(selected.id)) |td| {
            const set_labels = [_][*:0]const u8{
                "Set...##Layer0",
                "Set...##Layer1",
                "Set...##Layer2",
                "Set...##Layer3",
            };
            var li: usize = 0;
            while (li < 4) : (li += 1) {
                c.imgui_bridge_text("%s", layer_names[li]);
                c.imgui_bridge_same_line(0, -1);
                const tex_id = ensure_imgui_texture_id_for_layer(state, td, li);
                if (tex_id != 0) {
                    c.imgui_bridge_image_u64(tex_id, 64.0, 64.0);
                    c.imgui_bridge_same_line(0, -1);
                }
                if (c.imgui_bridge_begin_drag_drop_target()) {
                    if (c.imgui_bridge_accept_drag_drop_payload("ASSET_PATH", 0)) |payload| {
                        if (c.imgui_bridge_payload_is_delivery(payload)) {
                            const data_ptr = c.imgui_bridge_payload_get_data(payload);
                            if (data_ptr != null) {
                                const path_c: [*:0]const u8 = @ptrCast(@alignCast(data_ptr));
                                const path = std.mem.span(path_c);
                                if (is_texture_asset_path(path)) {
                                    set_terrain_layer_texture_from_path(state, terr_ptr.?, td, li, path);
                                }
                            }
                        }
                    }
                    c.imgui_bridge_end_drag_drop_target();
                }
                if (c.imgui_bridge_button(set_labels[li])) {
                    const filter = "Textures\x00*.png;*.jpg;*.jpeg;*.tga;*.bmp;*.dds;*.hdr;*.exr\x00All Files\x00*.*\x00";
                    if (platform.open_file_dialog(memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator(), filter, null)) |picked| {
                        defer memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator().free(picked);
                        set_terrain_layer_texture_from_path(state, terr_ptr.?, td, li, picked);
                    }
                }
            }
        }
        const layer_items = [_][*:0]const u8{
            "Layer 0",
            "Layer 1",
            "Layer 2",
            "Layer 3",
        };
        var layer_ptr: i32 = state.ui.terrain_paint_layer;
        _ = c.imgui_bridge_combo("Paint Layer", &layer_ptr, &layer_items[0], @intCast(layer_items.len), 10);
        state.ui.terrain_paint_layer = layer_ptr;
    } else {
        _ = c.imgui_bridge_drag_float("Brush Strength", &state.ui.terrain_brush_strength, 0.01, 0.0, 1.0, "%.3f", 0);
        const mode_items = [_][*:0]const u8{
            "Remove",
            "Add",
        };
        var mode_ptr: i32 = state.ui.terrain_carve_mode;
        _ = c.imgui_bridge_combo("Carve Mode", &mode_ptr, &mode_items[0], @intCast(mode_items.len), 10);
        state.ui.terrain_carve_mode = mode_ptr;
    }

    {
        const falloff_items = [_][*:0]const u8{
            "Smooth",
            "Linear",
            "Gaussian",
        };
        var falloff_ptr: i32 = @intCast(std.math.clamp(state.ui.terrain_brush_falloff, 0, @as(i32, @intCast(falloff_items.len - 1))));
        _ = c.imgui_bridge_combo("Falloff", &falloff_ptr, &falloff_items[0], @intCast(falloff_items.len), 10);
        state.ui.terrain_brush_falloff = falloff_ptr;
        _ = c.imgui_bridge_drag_float("Brush Spacing", &state.ui.terrain_brush_spacing, 0.01, 0.0, 2.0, "%.2f", 0);
    }

    const mouse_down = state.ui.terrain_sculpt_enabled and c.imgui_bridge_is_shift_down() and c.imgui_bridge_is_mouse_down(0) and !state.runtime.mouse_captured;

    var terrain_group: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
    defer terrain_group.deinit(state.runtime.arena_allocator);
    terrain_volume.collect_connected_terrain(&state.runtime, selected, state.runtime.arena_allocator, &terrain_group);
    if (terrain_group.items.len == 0) {
        terrain_group.append(state.runtime.arena_allocator, selected) catch {};
    }

    var preview_hit = math.Vec3{ .x = 0.0, .y = 0.0, .z = 0.0 };
    var preview_enabled = false;
    var preview_surface: i32 = 0;
    if (state.ui.terrain_sculpt_enabled and c.imgui_bridge_is_shift_down() and !state.runtime.mouse_captured) {
        if (selection_raycast.get_ray_from_mouse(state)) |ray| {
            var best_t: f32 = std.math.floatMax(f32);
            var best_hit: ?math.Vec3 = null;
            var best_ent: ?engine.ecs_entity.Entity = null;
            var best_mesh: ?u32 = null;
            for (terrain_group.items) |e| {
                const terr = state.runtime.registry.get(components.Terrain, e) orelse continue;
                const hits = [_]u32{
                    terr.mesh_index,
                    if (terr.thickness > 0.01) terr.mesh_index + 1 else std.math.maxInt(u32),
                    if (terr.thickness > 0.01) terr.mesh_index + 2 else std.math.maxInt(u32),
                };
                for (hits) |mesh_index| {
                    if (mesh_index == std.math.maxInt(u32)) continue;
                    if (mesh_index >= state.runtime.combined_scene.mesh_count) continue;
                    if (selection_raycast.raycast_combined_mesh_point(state, mesh_index, ray)) |hit| {
                        const t_hit = hit.sub(ray.origin).dot(ray.direction);
                        if (t_hit > 0.0 and t_hit < best_t) {
                            best_t = t_hit;
                            best_hit = hit;
                            best_ent = e;
                            best_mesh = mesh_index;
                        }
                    }
                }
            }
            if (best_hit) |hit| {
                preview_hit = hit;
                preview_enabled = true;
                if (best_ent) |pe| {
                    if (state.ui.terrain_tool == 0 and best_mesh != null) {
                        if (state.runtime.registry.get(components.Terrain, pe)) |terr| {
                            if (state.runtime.registry.get(components.Transform, pe)) |tr| {
                                const local_x = hit.x - tr.position.x;
                                const local_z = hit.z - tr.position.z;
                                const half_x = terr.size.x * 0.5;
                                const half_z = terr.size.y * 0.5;
                                const dx_neg = @abs(local_x + half_x);
                                const dx_pos = @abs(local_x - half_x);
                                const dz_neg = @abs(local_z + half_z);
                                const dz_pos = @abs(local_z - half_z);
                                const min_edge = @min(@min(dx_neg, dx_pos), @min(dz_neg, dz_pos));
                                const edge_thresh: f32 = @max(0.05, state.ui.terrain_brush_radius * 0.25);

                                preview_surface = if (terr.thickness > 0.01 and min_edge <= edge_thresh)
                                    2
                                else if (best_mesh.? == terr.mesh_index + 1)
                                    1
                                else if (best_mesh.? == terr.mesh_index)
                                    0
                                else
                                    pick_sculpt_surface_for_hit(state, pe, terr, tr, hit);
                            }
                        }
                    }
                }
            }
        }
    }

    state.ui.terrain_brush_outline_enabled = preview_enabled;
    if (preview_enabled) {
        state.ui.terrain_brush_outline_pos = .{ preview_hit.x, preview_hit.y, preview_hit.z };
        state.ui.terrain_brush_outline_radius = state.ui.terrain_brush_radius;
        state.ui.terrain_brush_outline_strength = state.ui.terrain_brush_strength;
        state.ui.terrain_brush_outline_tool = state.ui.terrain_tool;
        state.ui.terrain_brush_outline_mode = if (state.ui.terrain_tool == 0) state.ui.terrain_sculpt_mode else if (state.ui.terrain_tool == 1) state.ui.terrain_paint_layer else state.ui.terrain_carve_mode;
        state.ui.terrain_brush_outline_surface = if (state.ui.terrain_tool == 0) preview_surface else 0;
    }

    const preview_mode: u32 = if (state.ui.terrain_tool == 0) @intCast(state.ui.terrain_sculpt_mode) else if (state.ui.terrain_tool == 1) @intCast(state.ui.terrain_paint_layer) else @intCast(state.ui.terrain_carve_mode);
    renderer.cardinal_renderer_set_terrain_brush_preview(
        state.runtime.renderer,
        preview_enabled,
        preview_hit.x,
        preview_hit.y,
        preview_hit.z,
        state.ui.terrain_brush_radius,
        state.ui.terrain_brush_strength,
        @intCast(state.ui.terrain_tool),
        preview_mode,
    );

    if (mouse_down) {
        if (selection_raycast.get_ray_from_mouse(state)) |ray| {
            var best_t: f32 = std.math.floatMax(f32);
            var best_hit: ?math.Vec3 = null;
            var best_ent: ?engine.ecs_entity.Entity = null;
            var best_mesh: ?u32 = null;
            for (terrain_group.items) |e| {
                const terr = state.runtime.registry.get(components.Terrain, e) orelse continue;
                const hits = [_]u32{
                    terr.mesh_index,
                    if (terr.thickness > 0.01) terr.mesh_index + 1 else std.math.maxInt(u32),
                    if (terr.thickness > 0.01) terr.mesh_index + 2 else std.math.maxInt(u32),
                };
                for (hits) |mesh_index| {
                    if (mesh_index == std.math.maxInt(u32)) continue;
                    if (mesh_index >= state.runtime.combined_scene.mesh_count) continue;
                    if (selection_raycast.raycast_combined_mesh_point(state, mesh_index, ray)) |hit| {
                        const t_hit = hit.sub(ray.origin).dot(ray.direction);
                        if (t_hit > 0.0 and t_hit < best_t) {
                            best_t = t_hit;
                            best_hit = hit;
                            best_ent = e;
                            best_mesh = mesh_index;
                        }
                    }
                }
            }

            if (best_hit) |hit| {
                if (best_ent) |e_hit| {
                    if (state.runtime.registry.get(components.Terrain, e_hit)) |terr| {
                        if (state.runtime.registry.get(components.Transform, e_hit)) |tr| {
                            if (!brush_can_stamp(state, hit)) {
                                state.ui.terrain_brush_last_mouse_down = true;
                                return;
                            }
                            brush_record_stamp(state, hit);
                            var sculpt_surface: i32 = 0;
                            if (state.ui.terrain_tool == 0 and best_mesh != null) {
                                const local_x = hit.x - tr.position.x;
                                const local_z = hit.z - tr.position.z;
                                const half_x = terr.size.x * 0.5;
                                const half_z = terr.size.y * 0.5;
                                const dx_neg = @abs(local_x + half_x);
                                const dx_pos = @abs(local_x - half_x);
                                const dz_neg = @abs(local_z + half_z);
                                const dz_pos = @abs(local_z - half_z);
                                const min_edge = @min(@min(dx_neg, dx_pos), @min(dz_neg, dz_pos));
                                const edge_thresh: f32 = @max(0.05, state.ui.terrain_brush_radius * 0.25);

                                if (terr.thickness > 0.01 and min_edge <= edge_thresh) {
                                    sculpt_surface = 2;
                                } else if (best_mesh.? == terr.mesh_index + 2) {
                                    sculpt_surface = 2;
                                } else if (best_mesh.? == terr.mesh_index + 1) {
                                    sculpt_surface = 1;
                                } else {
                                    sculpt_surface = 0;
                                }
                            }
                            stroke_begin(state.ui.terrain_tool, sculpt_surface);
                            if (state.ui.terrain_tool == 0) {
                                _ = apply_sculpt_to_selected(state, e_hit.id, terr, tr, hit);
                            } else if (state.ui.terrain_tool == 1) {
                                _ = apply_paint_to_selected(state, e_hit.id, terr, tr, hit);
                            } else {
                                _ = apply_carve_to_selected(state, e_hit.id, terr, tr, hit);
                            }
                        }
                    }
                }
                for (terrain_group.items) |e| {
                    if (best_ent) |be| {
                        if (e.id == be.id) continue;
                    }
                    const terr = state.runtime.registry.get(components.Terrain, e) orelse continue;
                    const t = state.runtime.registry.get(components.Transform, e) orelse continue;
                    if (state.ui.terrain_tool == 0) {
                        _ = apply_sculpt_to_selected(state, e.id, terr, t, hit);
                    } else if (state.ui.terrain_tool == 1) {
                        _ = apply_paint_to_selected(state, e.id, terr, t, hit);
                    } else {
                        _ = apply_carve_to_selected(state, e.id, terr, t, hit);
                    }
                }
                state.ui.terrain_brush_last_mouse_down = true;
                state.runtime.picking_cache_dirty = true;
            }
        }
    } else if (state.ui.terrain_brush_last_mouse_down) {
        stroke_end_and_push_undo(state);
        state.ui.terrain_brush_stamp_valid = false;
        state.runtime.pending_scene = state.runtime.combined_scene;
        state.runtime.scene_upload_pending = true;
        state.runtime.picking_cache_dirty = true;
        state.ui.terrain_brush_last_mouse_down = false;
    }
}

/// Uploads any accumulated dirty terrain rectangles to the renderer.
pub fn flush_terrain_pending_uploads(state: *EditorState) void {
    if (state.runtime.terrain_dirty_rects.count() == 0) return;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    var it = state.runtime.terrain_dirty_rects.iterator();
    while (it.next()) |entry| {
        const entity_id = entry.key_ptr.*;
        const rect = entry.value_ptr.*;

        const td = state.runtime.terrain_data_by_entity.getPtr(entity_id) orelse continue;
        ensure_terrain_gpu_textures(state, td);
        if (td.height_handle == std.math.maxInt(u32) or td.splat_handle == std.math.maxInt(u32)) continue;

        if (rect.min_x > rect.max_x or rect.min_y > rect.max_y) continue;
        if (rect.max_x >= td.dims or rect.max_y >= td.dims) continue;

        const w: u32 = rect.max_x - rect.min_x + 1;
        const h: u32 = rect.max_y - rect.min_y + 1;
        const w_usize: usize = @intCast(w);
        const h_usize: usize = @intCast(h);

        const tmp_height = alloc.alloc(f32, w_usize * h_usize) catch continue;
        defer alloc.free(tmp_height);
        const tmp_splat = alloc.alloc(u8, (w_usize * h_usize) * 4) catch continue;
        defer alloc.free(tmp_splat);

        var row: u32 = 0;
        while (row < h) : (row += 1) {
            const src_y: usize = @as(usize, rect.min_y + row);
            const src_base: usize = src_y * @as(usize, td.dims) + @as(usize, rect.min_x);
            const dst_base: usize = @as(usize, row) * w_usize;

            @memcpy(tmp_height[dst_base .. dst_base + w_usize], td.height[src_base .. src_base + w_usize]);

            const src_s_base: usize = src_base * 4;
            const dst_s_base: usize = dst_base * 4;
            @memcpy(tmp_splat[dst_s_base .. dst_s_base + w_usize * 4], td.splat[src_s_base .. src_s_base + w_usize * 4]);
        }

        _ = renderer.cardinal_renderer_runtime_texture_update_subregion(state.runtime.renderer, td.height_handle, rect.min_x, rect.min_y, w, h, @ptrCast(tmp_height.ptr), tmp_height.len * @sizeOf(f32));
        _ = renderer.cardinal_renderer_runtime_texture_update_subregion(state.runtime.renderer, td.splat_handle, rect.min_x, rect.min_y, w, h, @ptrCast(tmp_splat.ptr), tmp_splat.len);
    }

    state.runtime.terrain_dirty_rects.clearRetainingCapacity();
}
