const C = @import("common.zig");
const Data = @import("data.zig");
const Dirty = @import("dirty.zig");
const Tasks = @import("tasks.zig");
const Streaming = @import("streaming.zig");

const std = C.std;
const engine = C.engine;
const EditorState = C.EditorState;
const VolumetricTerrainData = C.VolumetricTerrainData;
const memory = C.memory;
const components = C.components;
const math = C.math;

fn brush_falloff_weight(d2: f32, r: f32, kind: i32) f32 {
    const r2 = r * r;
    if (r2 <= 0.0000001) return 0.0;
    const t = std.math.clamp(1.0 - d2 / r2, 0.0, 1.0);
    if (kind == 1) {
        return t;
    }
    if (kind == 2) {
        const sigma = @max(0.0001, r * 0.5);
        const denom = 2.0 * sigma * sigma;
        return @exp(-d2 / denom);
    }
    return t * t;
}

fn apply_sculpt_chunk_no_remesh(state: *EditorState, entity_id: u64, hit_world: math.Vec3, radius: f32, strength: f32, mode: i32) bool {
    const ent = engine.ecs_entity.Entity{ .id = entity_id };
    if (!state.runtime.registry.entity_manager.is_alive(ent)) return false;
    const vt = state.runtime.registry.get(components.VolumetricTerrain, ent) orelse return false;
    const tr = state.runtime.registry.get(components.Transform, ent) orelse return false;
    const td = Data.ensure_volumetric_terrain_data_for_entity(state, ent) orelse return false;
    if (td.dims < 2) return false;

    const r = @max(0.001, radius);
    const s = strength;

    const size = vt.size;
    const half = size.mul(0.5);
    const res: u32 = td.dims - 1;
    const step = math.Vec3{
        .x = size.x / @as(f32, @floatFromInt(res)),
        .y = size.y / @as(f32, @floatFromInt(res)),
        .z = size.z / @as(f32, @floatFromInt(res)),
    };

    const local = hit_world.sub(tr.position);
    const center = math.Vec3{
        .x = std.math.clamp((local.x + half.x) / size.x, 0.0, 1.0),
        .y = std.math.clamp((local.y + half.y) / size.y, 0.0, 1.0),
        .z = std.math.clamp((local.z + half.z) / size.z, 0.0, 1.0),
    };

    const cx = center.x * @as(f32, @floatFromInt(res));
    const cy = center.y * @as(f32, @floatFromInt(res));
    const cz = center.z * @as(f32, @floatFromInt(res));

    const rx = r / size.x * @as(f32, @floatFromInt(res));
    const ry = r / size.y * @as(f32, @floatFromInt(res));
    const rz = r / size.z * @as(f32, @floatFromInt(res));

    const min_x: i32 = @intCast(@max(0, @as(i32, @intFromFloat(@floor(cx - rx)))));
    const max_x: i32 = @intCast(@min(@as(i32, @intCast(res)), @as(i32, @intFromFloat(@ceil(cx + rx)))));
    const min_y: i32 = @intCast(@max(0, @as(i32, @intFromFloat(@floor(cy - ry)))));
    const max_y: i32 = @intCast(@min(@as(i32, @intCast(res)), @as(i32, @intFromFloat(@ceil(cy + ry)))));
    const min_z: i32 = @intCast(@max(0, @as(i32, @intFromFloat(@floor(cz - rz)))));
    const max_z: i32 = @intCast(@min(@as(i32, @intCast(res)), @as(i32, @intFromFloat(@ceil(cz + rz)))));

    const falloff_kind: i32 = state.ui.terrain_brush_falloff;
    var touched = false;

    var smooth_orig: []f32 = @constCast(&[_]f32{});
    const sx0: i32 = min_x;
    const sy0: i32 = min_y;
    const sz0: i32 = min_z;
    const sx1: i32 = max_x;
    const sy1: i32 = max_y;
    const sz1: i32 = max_z;
    const sdx: u32 = @intCast(sx1 - sx0 + 1);
    const sdy: u32 = @intCast(sy1 - sy0 + 1);
    const sdz: u32 = @intCast(sz1 - sz0 + 1);
    if (mode == 3) {
        const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
        const count: usize = @as(usize, sdx) * @as(usize, sdy) * @as(usize, sdz);
        smooth_orig = alloc.alloc(f32, count) catch @constCast(&[_]f32{});
        if (smooth_orig.len == count) {
            var zz: i32 = sz0;
            while (zz <= sz1) : (zz += 1) {
                var yy: i32 = sy0;
                while (yy <= sy1) : (yy += 1) {
                    var xx: i32 = sx0;
                    while (xx <= sx1) : (xx += 1) {
                        const gx: u32 = @intCast(xx);
                        const gy: u32 = @intCast(yy);
                        const gz: u32 = @intCast(zz);
                        const li: usize =
                            (@as(usize, @intCast(zz - sz0)) * @as(usize, sdy) + @as(usize, @intCast(yy - sy0))) * @as(usize, sdx) +
                            @as(usize, @intCast(xx - sx0));
                        smooth_orig[li] = C.sample_density(td, gx, gy, gz);
                    }
                }
            }
        }
    }
    defer {
        if (smooth_orig.len != 0) {
            const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
            alloc.free(smooth_orig);
        }
    }

    var z: i32 = min_z;
    while (z <= max_z) : (z += 1) {
        var y: i32 = min_y;
        while (y <= max_y) : (y += 1) {
            var x: i32 = min_x;
            while (x <= max_x) : (x += 1) {
                const gx: u32 = @intCast(x);
                const gy: u32 = @intCast(y);
                const gz: u32 = @intCast(z);

                const p = math.Vec3{
                    .x = -half.x + step.x * @as(f32, @floatFromInt(gx)),
                    .y = -half.y + step.y * @as(f32, @floatFromInt(gy)),
                    .z = -half.z + step.z * @as(f32, @floatFromInt(gz)),
                };
                const world_p = tr.position.add(p);
                const d = world_p.sub(hit_world);
                const d2 = d.x * d.x + d.y * d.y + d.z * d.z;
                if (d2 > r * r) continue;
                const w = brush_falloff_weight(d2, r, falloff_kind);

                const idx = C.density_index(td.dims, gx, gy, gz);
                const cur = td.density[idx];
                if (mode == 0 or mode == 1) {
                    const delta_sign: f32 = if (mode == 0) -1.0 else 1.0;
                    td.density[idx] = cur + delta_sign * s * w;
                } else if (mode == 2) {
                    const a = std.math.clamp(s, 0.0, 1.0) * w;
                    const desired = p.y - local.y;
                    td.density[idx] = cur + (desired - cur) * a;
                } else if (mode == 3) {
                    const a = std.math.clamp(s, 0.0, 1.0) * w;
                    const xi: i32 = x;
                    const yi: i32 = y;
                    const zi: i32 = z;
                    const max_i: i32 = @intCast(td.dims - 1);
                    const xm: u32 = @intCast(std.math.clamp(xi - 1, 0, max_i));
                    const xp: u32 = @intCast(std.math.clamp(xi + 1, 0, max_i));
                    const ym: u32 = @intCast(std.math.clamp(yi - 1, 0, max_i));
                    const yp: u32 = @intCast(std.math.clamp(yi + 1, 0, max_i));
                    const zm: u32 = @intCast(std.math.clamp(zi - 1, 0, max_i));
                    const zp: u32 = @intCast(std.math.clamp(zi + 1, 0, max_i));

                    const sample_stable = struct {
                        fn f(td_in: *VolumetricTerrainData, orig: []const f32, sx0i: i32, sy0i: i32, sz0i: i32, sdxi: u32, sdyi: u32, sdzi: u32, xq: u32, yq: u32, zq: u32) f32 {
                            const xi2: i32 = @intCast(xq);
                            const yi2: i32 = @intCast(yq);
                            const zi2: i32 = @intCast(zq);
                            if (orig.len != 0 and xi2 >= sx0i and yi2 >= sy0i and zi2 >= sz0i) {
                                const lx: i32 = xi2 - sx0i;
                                const ly: i32 = yi2 - sy0i;
                                const lz: i32 = zi2 - sz0i;
                                if (lx >= 0 and ly >= 0 and lz >= 0) {
                                    const ux: u32 = @intCast(lx);
                                    const uy: u32 = @intCast(ly);
                                    const uz: u32 = @intCast(lz);
                                    if (ux < sdxi and uy < sdyi and uz < sdzi) {
                                        const li: usize = (@as(usize, uz) * @as(usize, sdyi) + @as(usize, uy)) * @as(usize, sdxi) + @as(usize, ux);
                                        return orig[li];
                                    }
                                }
                            }
                            return C.sample_density(td_in, xq, yq, zq);
                        }
                    }.f;

                    const cur0 = if (smooth_orig.len != 0)
                        sample_stable(td, smooth_orig, sx0, sy0, sz0, sdx, sdy, sdz, gx, gy, gz)
                    else
                        cur;
                    const avg =
                        (sample_stable(td, smooth_orig, sx0, sy0, sz0, sdx, sdy, sdz, xp, gy, gz) +
                        sample_stable(td, smooth_orig, sx0, sy0, sz0, sdx, sdy, sdz, xm, gy, gz) +
                        sample_stable(td, smooth_orig, sx0, sy0, sz0, sdx, sdy, sdz, gx, yp, gz) +
                        sample_stable(td, smooth_orig, sx0, sy0, sz0, sdx, sdy, sdz, gx, ym, gz) +
                        sample_stable(td, smooth_orig, sx0, sy0, sz0, sdx, sdy, sdz, gx, gy, zp) +
                        sample_stable(td, smooth_orig, sx0, sy0, sz0, sdx, sdy, sdz, gx, gy, zm)) * (1.0 / 6.0);
                    td.density[idx] = cur0 + (avg - cur0) * a;
                } else {
                    const delta_sign: f32 = if (mode == 0) -1.0 else 1.0;
                    td.density[idx] = cur + delta_sign * s * w;
                }
                touched = true;
            }
        }
    }

    if (touched and res >= 1) {
        const cell_min_x: i32 = @max(0, min_x - 1);
        const cell_min_y: i32 = @max(0, min_y - 1);
        const cell_min_z: i32 = @max(0, min_z - 1);
        const cell_max_i: i32 = @intCast(res - 1);
        const cell_max_x: i32 = @min(cell_max_i, max_x);
        const cell_max_y: i32 = @min(cell_max_i, max_y);
        const cell_max_z: i32 = @min(cell_max_i, max_z);
        if (cell_min_x <= cell_max_x and cell_min_y <= cell_max_y and cell_min_z <= cell_max_z) {
            Dirty.mark_dirty_bricks_masked(state, entity_id, .{
                .min_x = @intCast(cell_min_x),
                .min_y = @intCast(cell_min_y),
                .min_z = @intCast(cell_min_z),
                .max_x = @intCast(cell_max_x),
                .max_y = @intCast(cell_max_y),
                .max_z = @intCast(cell_max_z),
            }, C.all_lods_mask, res);
        }
    }

    return touched;
}

pub fn apply_sculpt_group(state: *EditorState, seed_entity_id: u64, hit_world: math.Vec3, radius: f32, strength: f32, mode: i32) void {
    const seed_ent = engine.ecs_entity.Entity{ .id = seed_entity_id };
    if (!state.runtime.registry.entity_manager.is_alive(seed_ent)) return;
    const seed_vt = state.runtime.registry.get(components.VolumetricTerrain, seed_ent) orelse return;
    const seed_hier = state.runtime.registry.get(components.Hierarchy, seed_ent);
    const seed_parent = if (seed_hier) |h| h.parent else null;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var touched = std.ArrayListUnmanaged(u64){};
    defer touched.deinit(alloc);

    const r = @max(0.001, radius);
    var view = state.runtime.registry.view(components.VolumetricTerrain);
    var it = view.iterator();
    while (it.next()) |entry| {
        const ent = entry.entity;
        const vt = entry.component;
        if (vt.resolution != seed_vt.resolution) continue;
        if (@abs(vt.size.x - seed_vt.size.x) > 0.001) continue;
        if (@abs(vt.size.y - seed_vt.size.y) > 0.001) continue;
        if (@abs(vt.size.z - seed_vt.size.z) > 0.001) continue;

        if (seed_parent) |p| {
            const h = state.runtime.registry.get(components.Hierarchy, ent) orelse continue;
            if (h.parent == null or h.parent.?.id != p.id) continue;
        } else {
            if (ent.id != seed_ent.id) continue;
        }

        const tr = state.runtime.registry.get(components.Transform, ent) orelse continue;

        const half = vt.size.mul(0.5);
        const aabb_min = tr.position.sub(half);
        const aabb_max = tr.position.add(half);
        if (!Streaming.sphere_intersects_aabb(hit_world, r, aabb_min, aabb_max)) continue;

        if (apply_sculpt_chunk_no_remesh(state, ent.id, hit_world, r, strength, mode)) {
            touched.append(alloc, ent.id) catch {};
        }
    }

    for (touched.items) |id| {
        const ent = engine.ecs_entity.Entity{ .id = id };
        if (state.runtime.registry.get(components.VolumetricTerrain, ent)) |vt| {
            vt.data_id = std.crypto.random.int(u64);
        }
    }
    Tasks.schedule_brick_remeshes(state, Data.ensure_volumetric_terrain_data_for_entity);
}

fn apply_paint_chunk_no_remesh(state: *EditorState, entity_id: u64, hit_world: math.Vec3, radius: f32, strength: f32, layer: u32, erase: bool) bool {
    const ent = engine.ecs_entity.Entity{ .id = entity_id };
    if (!state.runtime.registry.entity_manager.is_alive(ent)) return false;
    const vt = state.runtime.registry.get(components.VolumetricTerrain, ent) orelse return false;
    const tr = state.runtime.registry.get(components.Transform, ent) orelse return false;
    const td = Data.ensure_volumetric_terrain_data_for_entity(state, ent) orelse return false;
    if (td.dims < 2) return false;

    const r = @max(0.001, radius);
    const s = std.math.clamp(strength, 0.0, 1.0);
    const l: u32 = @min(layer, 3);

    const size = vt.size;
    const half = size.mul(0.5);
    const res: u32 = td.dims - 1;
    const step = math.Vec3{
        .x = size.x / @as(f32, @floatFromInt(res)),
        .y = size.y / @as(f32, @floatFromInt(res)),
        .z = size.z / @as(f32, @floatFromInt(res)),
    };
    const near_surface = @max(step.x, @max(step.y, step.z)) * 2.0;

    const local = hit_world.sub(tr.position);
    const center = math.Vec3{
        .x = std.math.clamp((local.x + half.x) / size.x, 0.0, 1.0),
        .y = std.math.clamp((local.y + half.y) / size.y, 0.0, 1.0),
        .z = std.math.clamp((local.z + half.z) / size.z, 0.0, 1.0),
    };

    const cx = center.x * @as(f32, @floatFromInt(res));
    const cy = center.y * @as(f32, @floatFromInt(res));
    const cz = center.z * @as(f32, @floatFromInt(res));

    const rx = r / size.x * @as(f32, @floatFromInt(res));
    const ry = r / size.y * @as(f32, @floatFromInt(res));
    const rz = r / size.z * @as(f32, @floatFromInt(res));

    const min_x: i32 = @intCast(@max(0, @as(i32, @intFromFloat(@floor(cx - rx)))));
    const max_x: i32 = @intCast(@min(@as(i32, @intCast(res)), @as(i32, @intFromFloat(@ceil(cx + rx)))));
    const min_y: i32 = @intCast(@max(0, @as(i32, @intFromFloat(@floor(cy - ry)))));
    const max_y: i32 = @intCast(@min(@as(i32, @intCast(res)), @as(i32, @intFromFloat(@ceil(cy + ry)))));
    const min_z: i32 = @intCast(@max(0, @as(i32, @intFromFloat(@floor(cz - rz)))));
    const max_z: i32 = @intCast(@min(@as(i32, @intCast(res)), @as(i32, @intFromFloat(@ceil(cz + rz)))));

    const falloff_kind: i32 = state.ui.terrain_brush_falloff;
    var touched = false;
    var z: i32 = min_z;
    while (z <= max_z) : (z += 1) {
        var y: i32 = min_y;
        while (y <= max_y) : (y += 1) {
            var x: i32 = min_x;
            while (x <= max_x) : (x += 1) {
                const gx: u32 = @intCast(x);
                const gy: u32 = @intCast(y);
                const gz: u32 = @intCast(z);
                const idx = C.density_index(td.dims, gx, gy, gz);
                if (@abs(td.density[idx]) > near_surface) continue;

                const p = math.Vec3{
                    .x = -half.x + step.x * @as(f32, @floatFromInt(gx)),
                    .y = -half.y + step.y * @as(f32, @floatFromInt(gy)),
                    .z = -half.z + step.z * @as(f32, @floatFromInt(gz)),
                };
                const world_p = tr.position.add(p);
                const d = world_p.sub(hit_world);
                const d2 = d.x * d.x + d.y * d.y + d.z * d.z;
                if (d2 > r * r) continue;
                const w = brush_falloff_weight(d2, r, falloff_kind);
                const a = s * w;

                const o = idx * 4;
                const w0: f32 = @as(f32, @floatFromInt(td.splat[o + 0])) / 255.0;
                const w1: f32 = @as(f32, @floatFromInt(td.splat[o + 1])) / 255.0;
                const w2: f32 = @as(f32, @floatFromInt(td.splat[o + 2])) / 255.0;
                const w3: f32 = @as(f32, @floatFromInt(td.splat[o + 3])) / 255.0;

                var weights = [4]f32{ w0, w1, w2, w3 };
                if (erase) {
                    weights[l] = std.math.clamp(weights[l] - a, 0.0, 1.0);
                } else {
                    weights[l] = std.math.clamp(weights[l] + a, 0.0, 1.0);
                }

                const sumw = weights[0] + weights[1] + weights[2] + weights[3];
                if (sumw > 0.000001) {
                    const inv_sum = 1.0 / sumw;
                    weights[0] *= inv_sum;
                    weights[1] *= inv_sum;
                    weights[2] *= inv_sum;
                    weights[3] *= inv_sum;
                } else {
                    weights = .{ 1.0, 0.0, 0.0, 0.0 };
                }

                td.splat[o + 0] = @intFromFloat(std.math.clamp(weights[0] * 255.0, 0.0, 255.0));
                td.splat[o + 1] = @intFromFloat(std.math.clamp(weights[1] * 255.0, 0.0, 255.0));
                td.splat[o + 2] = @intFromFloat(std.math.clamp(weights[2] * 255.0, 0.0, 255.0));
                td.splat[o + 3] = @intFromFloat(std.math.clamp(weights[3] * 255.0, 0.0, 255.0));
                touched = true;
            }
        }
    }

    if (touched and res >= 1) {
        const cell_min_x: i32 = @max(0, min_x - 1);
        const cell_min_y: i32 = @max(0, min_y - 1);
        const cell_min_z: i32 = @max(0, min_z - 1);
        const cell_max_i: i32 = @intCast(res - 1);
        const cell_max_x: i32 = @min(cell_max_i, max_x);
        const cell_max_y: i32 = @min(cell_max_i, max_y);
        const cell_max_z: i32 = @min(cell_max_i, max_z);
        if (cell_min_x <= cell_max_x and cell_min_y <= cell_max_y and cell_min_z <= cell_max_z) {
            Dirty.mark_dirty_bricks_masked(state, entity_id, .{
                .min_x = @intCast(cell_min_x),
                .min_y = @intCast(cell_min_y),
                .min_z = @intCast(cell_min_z),
                .max_x = @intCast(cell_max_x),
                .max_y = @intCast(cell_max_y),
                .max_z = @intCast(cell_max_z),
            }, C.all_lods_mask, res);
        }
    }

    return touched;
}

pub fn apply_paint(state: *EditorState, entity_id: u64, hit_world: math.Vec3, radius: f32, strength: f32, layer: u32, erase: bool) void {
    if (apply_paint_chunk_no_remesh(state, entity_id, hit_world, radius, strength, layer, erase)) {
        const ent = engine.ecs_entity.Entity{ .id = entity_id };
        if (state.runtime.registry.get(components.VolumetricTerrain, ent)) |vt| {
            vt.data_id = std.crypto.random.int(u64);
        }
        Tasks.schedule_brick_remeshes(state, Data.ensure_volumetric_terrain_data_for_entity);
    }
}

pub fn apply_paint_group(state: *EditorState, seed_entity_id: u64, hit_world: math.Vec3, radius: f32, strength: f32, layer: u32, erase: bool) void {
    const seed_ent = engine.ecs_entity.Entity{ .id = seed_entity_id };
    if (!state.runtime.registry.entity_manager.is_alive(seed_ent)) return;
    const seed_vt = state.runtime.registry.get(components.VolumetricTerrain, seed_ent) orelse return;
    const seed_hier = state.runtime.registry.get(components.Hierarchy, seed_ent);
    const seed_parent = if (seed_hier) |h| h.parent else null;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var touched = std.ArrayListUnmanaged(u64){};
    defer touched.deinit(alloc);

    const r = @max(0.001, radius);
    var view = state.runtime.registry.view(components.VolumetricTerrain);
    var it = view.iterator();
    while (it.next()) |entry| {
        const ent = entry.entity;
        const vt = entry.component;
        if (vt.resolution != seed_vt.resolution) continue;
        if (@abs(vt.size.x - seed_vt.size.x) > 0.001) continue;
        if (@abs(vt.size.y - seed_vt.size.y) > 0.001) continue;
        if (@abs(vt.size.z - seed_vt.size.z) > 0.001) continue;

        if (seed_parent) |p| {
            const h = state.runtime.registry.get(components.Hierarchy, ent) orelse continue;
            if (h.parent == null or h.parent.?.id != p.id) continue;
        } else {
            if (ent.id != seed_ent.id) continue;
        }

        const tr = state.runtime.registry.get(components.Transform, ent) orelse continue;

        const half = vt.size.mul(0.5);
        const aabb_min = tr.position.sub(half);
        const aabb_max = tr.position.add(half);
        if (!Streaming.sphere_intersects_aabb(hit_world, r, aabb_min, aabb_max)) continue;

        if (apply_paint_chunk_no_remesh(state, ent.id, hit_world, r, strength, layer, erase)) {
            touched.append(alloc, ent.id) catch {};
        }
    }

    for (touched.items) |id| {
        const ent = engine.ecs_entity.Entity{ .id = id };
        if (state.runtime.registry.get(components.VolumetricTerrain, ent)) |vt| {
            vt.data_id = std.crypto.random.int(u64);
        }
    }
    Tasks.schedule_brick_remeshes(state, Data.ensure_volumetric_terrain_data_for_entity);
}
