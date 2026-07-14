//! Terrain volume mesh maintenance.
//!
//! Keeps a heightfield terrain visually volumetric by generating/updating:
//! - A bottom surface offset by `Terrain.thickness`
//! - Side walls around boundaries (including carve edges), skipping borders that
//!   touch adjacent terrain chunks.
const std = @import("std");
const engine = @import("cardinal_engine");

const editor_state = @import("../editor_state.zig");
const EditorRuntimeState = editor_state.EditorRuntimeState;

const math = engine.math;
const components = engine.ecs_components;
const model_manager = engine.model_manager;
const scene = engine.scene;

fn emit_wall_quad(wall_verts: [*]scene.CardinalVertex, wall_indices: [*]u32, wall_v: *u32, wall_i: *u32, top0: scene.CardinalVertex, top1: scene.CardinalVertex, bot0_in: scene.CardinalVertex, bot1_in: scene.CardinalVertex, nx: f32, nz: f32, flip: bool) void {
    var t0 = top0;
    var t1 = top1;
    var bot0 = bot0_in;
    var bot1 = bot1_in;
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

const NeighborMask = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
};

/// Computes which chunk borders are shared with adjacent terrain chunks.
///
/// This is used to suppress duplicate walls on shared borders.
pub fn compute_neighbor_mask(runtime: *EditorRuntimeState, self_ent: engine.ecs_entity.Entity) NeighborMask {
    const self_tr = runtime.registry.get(components.Transform, self_ent) orelse return .{};
    const self_terr = runtime.registry.get(components.Terrain, self_ent) orelse return .{};

    const want_left = math.Vec3{ .x = self_tr.position.x - self_terr.size.x, .y = self_tr.position.y, .z = self_tr.position.z };
    const want_right = math.Vec3{ .x = self_tr.position.x + self_terr.size.x, .y = self_tr.position.y, .z = self_tr.position.z };
    const want_up = math.Vec3{ .x = self_tr.position.x, .y = self_tr.position.y, .z = self_tr.position.z - self_terr.size.y };
    const want_down = math.Vec3{ .x = self_tr.position.x, .y = self_tr.position.y, .z = self_tr.position.z + self_terr.size.y };

    var mask: NeighborMask = .{};

    var view = runtime.registry.view(components.Terrain);
    var it = view.iterator();
    while (it.next()) |entry| {
        if (entry.entity.id == self_ent.id) continue;
        const other_terr = entry.component;
        if (@abs(other_terr.size.x - self_terr.size.x) > 0.001) continue;
        if (@abs(other_terr.size.y - self_terr.size.y) > 0.001) continue;
        const tr = runtime.registry.get(components.Transform, entry.entity) orelse continue;

        if (!mask.left and @abs(tr.position.x - want_left.x) <= 0.01 and @abs(tr.position.y - want_left.y) <= 0.01 and @abs(tr.position.z - want_left.z) <= 0.01) mask.left = true;
        if (!mask.right and @abs(tr.position.x - want_right.x) <= 0.01 and @abs(tr.position.y - want_right.y) <= 0.01 and @abs(tr.position.z - want_right.z) <= 0.01) mask.right = true;
        if (!mask.up and @abs(tr.position.x - want_up.x) <= 0.01 and @abs(tr.position.y - want_up.y) <= 0.01 and @abs(tr.position.z - want_up.z) <= 0.01) mask.up = true;
        if (!mask.down and @abs(tr.position.x - want_down.x) <= 0.01 and @abs(tr.position.y - want_down.y) <= 0.01 and @abs(tr.position.z - want_down.z) <= 0.01) mask.down = true;

        if (mask.left and mask.right and mask.up and mask.down) break;
    }

    return mask;
}

pub fn find_adjacent_terrain(runtime: *EditorRuntimeState, self_ent: engine.ecs_entity.Entity, want_pos: math.Vec3) ?engine.ecs_entity.Entity {
    const self_terr = runtime.registry.get(components.Terrain, self_ent) orelse return null;

    var view = runtime.registry.view(components.Terrain);
    var it = view.iterator();
    while (it.next()) |entry| {
        if (entry.entity.id == self_ent.id) continue;
        const other_terr = entry.component;
        if (@abs(other_terr.size.x - self_terr.size.x) > 0.001) continue;
        if (@abs(other_terr.size.y - self_terr.size.y) > 0.001) continue;
        const tr = runtime.registry.get(components.Transform, entry.entity) orelse continue;
        if (@abs(tr.position.x - want_pos.x) <= 0.01 and @abs(tr.position.y - want_pos.y) <= 0.01 and @abs(tr.position.z - want_pos.z) <= 0.01) {
            return entry.entity;
        }
    }

    return null;
}

pub fn collect_connected_terrain(runtime: *EditorRuntimeState, start: engine.ecs_entity.Entity, alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(engine.ecs_entity.Entity)) void {
    out.clearRetainingCapacity();

    if (!runtime.registry.entity_manager.is_alive(start)) return;
    const start_tr = runtime.registry.get(components.Transform, start) orelse return;
    const start_terr = runtime.registry.get(components.Terrain, start) orelse return;

    var visited: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer visited.deinit(alloc);

    var stack: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
    defer stack.deinit(alloc);

    visited.put(alloc, start.id, {}) catch return;
    stack.append(alloc, start) catch return;

    while (stack.items.len != 0) {
        const idx = stack.items.len - 1;
        const e = stack.items[idx];
        stack.items.len = idx;

        if (!runtime.registry.entity_manager.is_alive(e)) continue;
        const terr = runtime.registry.get(components.Terrain, e) orelse continue;
        const tr = runtime.registry.get(components.Transform, e) orelse continue;

        if (@abs(terr.size.x - start_terr.size.x) > 0.001) continue;
        if (@abs(terr.size.y - start_terr.size.y) > 0.001) continue;
        if (@abs(tr.position.y - start_tr.position.y) > 0.01) continue;

        out.append(alloc, e) catch {};

        const want_left = math.Vec3{ .x = tr.position.x - terr.size.x, .y = tr.position.y, .z = tr.position.z };
        const want_right = math.Vec3{ .x = tr.position.x + terr.size.x, .y = tr.position.y, .z = tr.position.z };
        const want_up = math.Vec3{ .x = tr.position.x, .y = tr.position.y, .z = tr.position.z - terr.size.y };
        const want_down = math.Vec3{ .x = tr.position.x, .y = tr.position.y, .z = tr.position.z + terr.size.y };

        const wants = [_]math.Vec3{ want_left, want_right, want_up, want_down };
        inline for (wants) |wp| {
            if (find_adjacent_terrain(runtime, e, wp)) |n| {
                if (!visited.contains(n.id)) {
                    visited.put(alloc, n.id, {}) catch {};
                    stack.append(alloc, n) catch {};
                }
            }
        }
    }
}

/// Rebuilds the bottom and walls meshes for a terrain entity.
///
/// This operates on the combined scene meshes (top/bottom/walls) and mirrors the
/// dynamic wall mesh counts back into the source model scene so uploads include
/// the updated counts.
pub fn update_terrain_volume_meshes(runtime: *EditorRuntimeState, entity_id: u64) void {
    const ent = engine.ecs_entity.Entity{ .id = entity_id };
    if (!runtime.registry.entity_manager.is_alive(ent)) return;

    const terr = runtime.registry.get(components.Terrain, ent) orelse return;
    if (terr.thickness <= 0.01) return;
    if (runtime.combined_scene.meshes == null) return;
    if (terr.mesh_index + 2 >= runtime.combined_scene.mesh_count) return;

    const top = &runtime.combined_scene.meshes.?[terr.mesh_index];
    const bottom = &runtime.combined_scene.meshes.?[terr.mesh_index + 1];
    const walls = &runtime.combined_scene.meshes.?[terr.mesh_index + 2];

    if (top.vertices == null or top.indices == null) return;
    if (bottom.vertices == null or bottom.indices == null) return;
    if (walls.vertices == null or walls.indices == null) return;
    if (top.vertex_count == 0 or top.index_count == 0) return;

    const vc = top.vertex_count;
    const side_f: f64 = std.math.sqrt(@as(f64, @floatFromInt(vc)));
    const vps: u32 = @intFromFloat(side_f + 0.5);
    if (vps < 2 or vps * vps != vc) return;
    const grid: u32 = vps - 1;

    const top_verts = @as([*]scene.CardinalVertex, @ptrCast(top.vertices.?));
    const bottom_verts = @as([*]scene.CardinalVertex, @ptrCast(bottom.vertices.?));
    const thickness: f32 = @max(0.01, terr.thickness);
    const bottom_ok = (bottom.vertex_count == top.vertex_count and bottom.vertices != null);
    var i: u32 = 0;
    while (i < vc) : (i += 1) {
        const py = bottom_verts[i].py;
        bottom_verts[i] = top_verts[i];
        bottom_verts[i].py = if (bottom_ok) py else top_verts[i].py - thickness;
        bottom_verts[i].nx = 0.0;
        bottom_verts[i].ny = -1.0;
        bottom_verts[i].nz = 0.0;
    }

    const bottom_indices = @as([*]u32, @ptrCast(bottom.indices.?));
    var quad: u32 = 0;
    var z: u32 = 0;
    while (z < grid) : (z += 1) {
        var x: u32 = 0;
        while (x < grid) : (x += 1) {
            const idx0: u32 = z * vps + x;
            const idx1: u32 = idx0 + 1;
            const idx2: u32 = idx0 + vps;
            const idx3: u32 = idx2 + 1;
            const a = (top_verts[idx0].color[3] + top_verts[idx1].color[3] + top_verts[idx2].color[3] + top_verts[idx3].color[3]) * 0.25;
            const base: usize = @as(usize, quad) * 6;
            if (a > 0.5) {
                bottom_indices[base + 0] = idx0;
                bottom_indices[base + 1] = idx1;
                bottom_indices[base + 2] = idx2;
                bottom_indices[base + 3] = idx1;
                bottom_indices[base + 4] = idx3;
                bottom_indices[base + 5] = idx2;
            } else {
                bottom_indices[base + 0] = 0;
                bottom_indices[base + 1] = 0;
                bottom_indices[base + 2] = 0;
                bottom_indices[base + 3] = 0;
                bottom_indices[base + 4] = 0;
                bottom_indices[base + 5] = 0;
            }
            quad += 1;
        }
    }

    const wall_verts = @as([*]scene.CardinalVertex, @ptrCast(walls.vertices.?));
    const wall_indices = @as([*]u32, @ptrCast(walls.indices.?));
    var wall_v: u32 = 0;
    var wall_i: u32 = 0;

    const neighbors = compute_neighbor_mask(runtime, ent);
    const has_left = neighbors.left;
    const has_right = neighbors.right;
    const has_up = neighbors.up;
    const has_down = neighbors.down;

    z = 0;
    while (z < grid) : (z += 1) {
        var x: u32 = 0;
        while (x < grid) : (x += 1) {
            const idx0: u32 = z * vps + x;
            const idx1: u32 = idx0 + 1;
            const idx2: u32 = idx0 + vps;
            const idx3: u32 = idx2 + 1;
            const a = (top_verts[idx0].color[3] + top_verts[idx1].color[3] + top_verts[idx2].color[3] + top_verts[idx3].color[3]) * 0.25;
            if (a <= 0.5) continue;

            const solid_left = (x > 0) and ((top_verts[idx0 - 1].color[3] + top_verts[idx2 - 1].color[3]) * 0.5 > 0.5);
            const solid_right = (x + 1 < vps - 1) and ((top_verts[idx1 + 1].color[3] + top_verts[idx3 + 1].color[3]) * 0.5 > 0.5);
            const solid_up = (z > 0) and ((top_verts[idx0 - vps].color[3] + top_verts[idx1 - vps].color[3]) * 0.5 > 0.5);
            const solid_down = (z + 1 < vps - 1) and ((top_verts[idx2 + vps].color[3] + top_verts[idx3 + vps].color[3]) * 0.5 > 0.5);

            const allow_left = !solid_left and !(x == 0 and has_left);
            const allow_right = !solid_right and !(x == grid - 1 and has_right);
            const allow_up = !solid_up and !(z == 0 and has_up);
            const allow_down = !solid_down and !(z == grid - 1 and has_down);

            const bot0 = if (bottom_ok) bottom_verts[idx0] else blk: {
                var v = top_verts[idx0];
                v.py -= thickness;
                break :blk v;
            };
            const bot1 = if (bottom_ok) bottom_verts[idx1] else blk: {
                var v = top_verts[idx1];
                v.py -= thickness;
                break :blk v;
            };
            const bot2 = if (bottom_ok) bottom_verts[idx2] else blk: {
                var v = top_verts[idx2];
                v.py -= thickness;
                break :blk v;
            };
            const bot3 = if (bottom_ok) bottom_verts[idx3] else blk: {
                var v = top_verts[idx3];
                v.py -= thickness;
                break :blk v;
            };

            if (allow_left) emit_wall_quad(wall_verts, wall_indices, &wall_v, &wall_i, top_verts[idx0], top_verts[idx2], bot0, bot2, -1.0, 0.0, true);
            if (allow_right) emit_wall_quad(wall_verts, wall_indices, &wall_v, &wall_i, top_verts[idx1], top_verts[idx3], bot1, bot3, 1.0, 0.0, false);
            if (allow_up) emit_wall_quad(wall_verts, wall_indices, &wall_v, &wall_i, top_verts[idx0], top_verts[idx1], bot0, bot1, 0.0, -1.0, false);
            if (allow_down) emit_wall_quad(wall_verts, wall_indices, &wall_v, &wall_i, top_verts[idx2], top_verts[idx3], bot2, bot3, 0.0, 1.0, true);
        }
    }

    walls.vertex_count = wall_v;
    walls.index_count = wall_i;

    const model = model_manager.cardinal_model_manager_get_model(&runtime.model_manager, terr.model_id) orelse return;
    if (model.scene.meshes != null and model.scene.mesh_count >= 3) {
        const top_m = &model.scene.meshes.?[0];
        const bottom_m = &model.scene.meshes.?[1];
        const walls_m = &model.scene.meshes.?[2];
        if (top_m.vertices != null and bottom_m.vertices != null and walls_m.vertices != null and bottom_m.vertex_count == top_m.vertex_count) {
            const tv = @as([*]scene.CardinalVertex, @ptrCast(top_m.vertices.?));
            const bv = @as([*]scene.CardinalVertex, @ptrCast(bottom_m.vertices.?));
            var vi: u32 = 0;
            while (vi < top_m.vertex_count) : (vi += 1) {
                const py = bv[vi].py;
                bv[vi] = tv[vi];
                bv[vi].py = py;
                bv[vi].nx = 0.0;
                bv[vi].ny = -1.0;
                bv[vi].nz = 0.0;
            }
        }
        walls_m.vertex_count = wall_v;
        walls_m.index_count = wall_i;
    }
}
