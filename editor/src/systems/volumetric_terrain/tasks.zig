const C = @import("common.zig");
const Dirty = @import("dirty.zig");
const Data = @import("data.zig");
const Bricks = @import("bricks.zig");
const Meshing = @import("meshing.zig");

const std = C.std;
const engine = C.engine;
const EditorState = C.EditorState;
const VolumetricTerrainData = C.VolumetricTerrainData;
const VolumetricDirtyBox = C.VolumetricDirtyBox;
const VolumetricBrickKey = C.VolumetricBrickKey;
const VolumetricBrickLodKey = C.editor_state.VolumetricBrickLodKey;
const VolumetricDensitySnapshotKey = C.VolumetricDensitySnapshotKey;
const memory = C.memory;
const async_loader = C.async_loader;
const components = C.components;
const model_manager = C.model_manager;
const scene = C.scene;
const MeshCapacity = C.MeshCapacity;

const BrickRemeshOutput = Meshing.BrickRemeshOutput;

const BrickTileOutput = struct {
    tile: u8,
    output: BrickRemeshOutput = .{},
};

const BrickRemeshJobData = struct {
    key: VolumetricBrickKey,
    generation: u32,
    dirty_box: VolumetricDirtyBox,
    model_id: u32,
    base_mesh_index: u32,
    size: C.math.Vec3,
    base_res: u32,
    base_dims: u32,
    axis: u32,
    lod: u32,
    full_rebuild: bool,
    data_id: u64,
    density: []const f32,
    splat: []const u8,
    snapshot_key: VolumetricDensitySnapshotKey,
    tile_outputs: []BrickTileOutput = @constCast(&[_]BrickTileOutput{}),
};

fn ensure_mesh_capacity(state: *EditorState, mesh_index: u32, model_mesh: *scene.CardinalMesh, combined_mesh: ?*scene.CardinalMesh, need_v: u32, need_i: u32) bool {
    const assets_alloc = memory.cardinal_get_allocator_for_category(.ASSETS);
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    var cap = state.runtime.volumetric_mesh_caps.get(mesh_index) orelse MeshCapacity{
        .vertex_cap = model_mesh.vertex_count,
        .index_cap = model_mesh.index_count,
    };

    const old_v_cap = cap.vertex_cap;
    const old_i_cap = cap.index_cap;

    if (cap.vertex_cap < need_v) cap.vertex_cap = @max(need_v, @max(cap.vertex_cap * 2, 1024));
    if (cap.index_cap < need_i) cap.index_cap = @max(need_i, @max(cap.index_cap * 2, 2048));

    if (cap.vertex_cap < need_v or cap.index_cap < need_i) return false;

    if (model_mesh.vertices == null) {
        const bytes = @as(usize, cap.vertex_cap) * @sizeOf(scene.CardinalVertex);
        const p = memory.cardinal_alloc(assets_alloc, bytes) orelse return false;
        model_mesh.vertices = @ptrCast(@alignCast(p));
        if (combined_mesh) |cmb| cmb.vertices = model_mesh.vertices;
    } else if (cap.vertex_cap != old_v_cap) {
        const bytes = @as(usize, cap.vertex_cap) * @sizeOf(scene.CardinalVertex);
        const p = memory.cardinal_realloc(assets_alloc, model_mesh.vertices.?, bytes) orelse return false;
        model_mesh.vertices = @ptrCast(@alignCast(p));
        if (combined_mesh) |cmb| cmb.vertices = model_mesh.vertices;
    }
    if (model_mesh.indices == null) {
        const bytes = @as(usize, cap.index_cap) * @sizeOf(u32);
        const p = memory.cardinal_alloc(assets_alloc, bytes) orelse return false;
        model_mesh.indices = @ptrCast(@alignCast(p));
        if (combined_mesh) |cmb| cmb.indices = model_mesh.indices;
    } else if (cap.index_cap != old_i_cap) {
        const bytes = @as(usize, cap.index_cap) * @sizeOf(u32);
        const p = memory.cardinal_realloc(assets_alloc, model_mesh.indices.?, bytes) orelse return false;
        model_mesh.indices = @ptrCast(@alignCast(p));
        if (combined_mesh) |cmb| cmb.indices = model_mesh.indices;
    }

    state.runtime.volumetric_mesh_caps.put(alloc, mesh_index, cap) catch {};

    if (combined_mesh) |cmb| {
        cmb.vertex_count = model_mesh.vertex_count;
        cmb.index_count = model_mesh.index_count;
    }

    return true;
}

fn acquire_density_snapshot(state: *EditorState, ent: engine.ecs_entity.Entity, vt: *const components.VolumetricTerrain, td: *const VolumetricTerrainData) ?struct { key: VolumetricDensitySnapshotKey, density: []const f32, splat: []const u8 } {
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const key = VolumetricDensitySnapshotKey{ .entity_id = ent.id, .data_id = vt.data_id };

    if (state.runtime.volumetric_density_snapshots.getPtr(key)) |snap| {
        snap.ref_count += 1;
        return .{ .key = key, .density = snap.density, .splat = snap.splat };
    }

    const density_copy = alloc.alloc(f32, td.density.len) catch return null;
    const splat_copy = alloc.alloc(u8, td.splat.len) catch {
        alloc.free(density_copy);
        return null;
    };
    @memcpy(density_copy, td.density);
    @memcpy(splat_copy, td.splat);
    state.runtime.volumetric_density_snapshots.put(alloc, key, .{ .density = density_copy, .splat = splat_copy, .ref_count = 1 }) catch {
        alloc.free(splat_copy);
        alloc.free(density_copy);
        return null;
    };
    return .{ .key = key, .density = density_copy, .splat = splat_copy };
}

fn release_density_snapshot(state: *EditorState, key: VolumetricDensitySnapshotKey) void {
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const snap_ptr = state.runtime.volumetric_density_snapshots.getPtr(key) orelse return;
    if (snap_ptr.ref_count > 0) snap_ptr.ref_count -= 1;
    if (snap_ptr.ref_count != 0) return;

    const ent = engine.ecs_entity.Entity{ .id = key.entity_id };
    if (state.runtime.registry.entity_manager.is_alive(ent)) {
        if (state.runtime.registry.get(components.VolumetricTerrain, ent)) |vt| {
            if (vt.data_id == key.data_id) return;
        }
    }

    alloc.free(snap_ptr.density);
    alloc.free(snap_ptr.splat);
    _ = state.runtime.volumetric_density_snapshots.remove(key);
}

fn brick_task_func(task_opt: ?*async_loader.CardinalAsyncTask, user_data: ?*anyopaque) callconv(.c) bool {
    _ = task_opt;
    if (user_data == null) return false;
    const job: *BrickRemeshJobData = @ptrCast(@alignCast(user_data.?));

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const res_lod: u32 = C.lod_resolution(job.base_res, job.lod);
    if (res_lod < 1) return true;
    const coords = C.brick_id_to_coords(job.axis, job.key.brick_id);
    const rx_opt = C.brick_cell_range_for_axis(res_lod, job.lod, job.axis, coords.bx);
    const ry_opt = C.brick_cell_range_for_axis(res_lod, job.lod, job.axis, coords.by);
    const rz_opt = C.brick_cell_range_for_axis(res_lod, job.lod, job.axis, coords.bz);
    if (rx_opt == null or ry_opt == null or rz_opt == null) return true;
    const rx = rx_opt.?;
    const ry = ry_opt.?;
    const rz = rz_opt.?;

    const base_step: u32 = @as(u32, 1) << @intCast(@min(job.lod, 30));
    const dirty = if (job.full_rebuild)
        VolumetricDirtyBox{ .min_x = 0, .min_y = 0, .min_z = 0, .max_x = job.base_res - 1, .max_y = job.base_res - 1, .max_z = job.base_res - 1 }
    else
        job.dirty_box;
    const dmin = [3]u32{
        dirty.min_x / base_step,
        dirty.min_y / base_step,
        dirty.min_z / base_step,
    };
    const dmax = [3]u32{
        (dirty.max_x + base_step - 1) / base_step,
        (dirty.max_y + base_step - 1) / base_step,
        (dirty.max_z + base_step - 1) / base_step,
    };

    const split_range = struct {
        fn f(r: C.CellRange, part: u32) ?C.CellRange {
            const cells = r.max - r.min + 1;
            if (cells <= 1) {
                return if (part == 0) C.CellRange{ .min = r.min, .max = r.max } else null;
            }
            const half = cells / 2;
            if (half == 0) return if (part == 0) C.CellRange{ .min = r.min, .max = r.max } else null;
            if (part == 0) {
                return C.CellRange{ .min = r.min, .max = r.min + half - 1 };
            }
            return C.CellRange{ .min = r.min + half, .max = r.max };
        }
    }.f;

    var list: std.ArrayListUnmanaged(BrickTileOutput) = .{};
    errdefer {
        for (list.items) |*t| {
            if (t.output.indices.len != 0) alloc.free(t.output.indices);
            if (t.output.vertices.len != 0) alloc.free(t.output.vertices);
        }
        list.deinit(alloc);
    }

    var tz: u32 = 0;
    while (tz < 2) : (tz += 1) {
        var ty: u32 = 0;
        while (ty < 2) : (ty += 1) {
            var tx: u32 = 0;
            while (tx < 2) : (tx += 1) {
                const rxx = split_range(rx, tx) orelse continue;
                const ryy = split_range(ry, ty) orelse continue;
                const rzz = split_range(rz, tz) orelse continue;

                if (!job.full_rebuild) {
                    if (rxx.max < dmin[0] or rxx.min > dmax[0]) continue;
                    if (ryy.max < dmin[1] or ryy.min > dmax[1]) continue;
                    if (rzz.max < dmin[2] or rzz.min > dmax[2]) continue;
                }

                var out: BrickRemeshOutput = .{};
                if (!Meshing.mesh_brick_lod_range(
                    alloc,
                    job.density,
                    job.splat,
                    job.base_dims,
                    job.base_res,
                    job.size,
                    job.lod,
                    rxx,
                    ryy,
                    rzz,
                    dirty,
                    rxx.min == rx.min,
                    rxx.max == rx.max,
                    rzz.min == rz.min,
                    rzz.max == rz.max,
                    &out,
                )) return false;

                if (!out.has_update) {
                    if (out.vertices.len != 0) alloc.free(out.vertices);
                    if (out.indices.len != 0) alloc.free(out.indices);
                    continue;
                }

                const tile_id: u8 = @intCast((tz * 4) + (ty * 2) + tx);
                list.append(alloc, .{ .tile = tile_id, .output = out }) catch return false;
            }
        }
    }

    job.tile_outputs = list.toOwnedSlice(alloc) catch return false;
    return true;
}

fn brick_task_callback(task_opt: ?*async_loader.CardinalAsyncTask, user_data: ?*anyopaque) callconv(.c) void {
    if (task_opt == null or user_data == null) return;
    const task = task_opt.?;
    const state: *EditorState = @ptrCast(@alignCast(user_data.?));

    if (task.custom_data == null) {
        async_loader.cardinal_async_free_task(task);
        return;
    }

    const job: *BrickRemeshJobData = @ptrCast(@alignCast(task.custom_data.?));
    _ = state.runtime.volumetric_brick_remesh_tasks.remove(job.key);

    const ok = task.status == .COMPLETED;
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    const ent = engine.ecs_entity.Entity{ .id = job.key.entity_id };
    const cur_gen = state.runtime.volumetric_brick_generation.get(job.key) orelse job.generation;
    const free_tile_outputs = struct {
        fn f(a: std.mem.Allocator, tiles: []BrickTileOutput) void {
            for (tiles) |t| {
                if (t.output.indices.len != 0) a.free(t.output.indices);
                if (t.output.vertices.len != 0) a.free(t.output.vertices);
            }
            if (tiles.len != 0) a.free(tiles);
        }
    }.f;

    if (cur_gen != job.generation) {
        free_tile_outputs(alloc, job.tile_outputs);
        job.tile_outputs = @constCast(&[_]BrickTileOutput{});
    } else if (ok and state.ui.project_loaded and state.runtime.registry.entity_manager.is_alive(ent)) {
        if (state.runtime.registry.get(components.VolumetricTerrain, ent)) |vt| {
            const bcount = C.brick_count(job.base_res);
            const mesh_index = vt.mesh_index + job.lod * bcount + job.key.brick_id;
            const model = model_manager.cardinal_model_manager_get_model(&state.runtime.model_manager, job.model_id) orelse null;
            if (model != null and model.?.scene.meshes != null and model.?.scene.mesh_count != 0) {
                const range = Bricks.get_model_combined_mesh_range(state, job.model_id) orelse null;
                if (range != null) {
                    const local_index = mesh_index - range.?.start;
                    if (local_index < model.?.scene.mesh_count) {
                        const model_mesh = &model.?.scene.meshes.?[local_index];
                        const combined_mesh = if (state.runtime.combined_scene.meshes != null and mesh_index < state.runtime.combined_scene.mesh_count)
                            &state.runtime.combined_scene.meshes.?[mesh_index]
                        else
                            null;

                        const key_lod = VolumetricBrickLodKey{ .entity_id = job.key.entity_id, .brick_id = job.key.brick_id, .lod = @intCast(job.lod) };
                        if (state.runtime.volumetric_brick_tile_cache.getPtr(key_lod)) |cache| {
                            if (job.full_rebuild) {
                                var i: usize = 0;
                                while (i < cache.tiles.len) : (i += 1) {
                                    if (cache.tiles[i].vertices.len != 0) alloc.free(cache.tiles[i].vertices);
                                    if (cache.tiles[i].indices.len != 0) alloc.free(cache.tiles[i].indices);
                                    cache.tiles[i].vertices = @constCast(&[_]scene.CardinalVertex{});
                                    cache.tiles[i].indices = @constCast(&[_]u32{});
                                    cache.tiles[i].vertex_count = 0;
                                    cache.tiles[i].index_count = 0;
                                }
                            }
                            cache.data_id = job.data_id;
                        } else {
                            _ = state.runtime.volumetric_brick_tile_cache.put(alloc, key_lod, .{ .data_id = job.data_id }) catch {};
                        }

                        const cache = state.runtime.volumetric_brick_tile_cache.getPtr(key_lod) orelse {
                            free_tile_outputs(alloc, job.tile_outputs);
                            release_density_snapshot(state, job.snapshot_key);
                            alloc.destroy(job);
                            async_loader.cardinal_async_free_task(task);
                            return;
                        };

                        for (job.tile_outputs) |t| {
                            if (!t.output.has_update) {
                                if (t.output.vertices.len != 0) alloc.free(t.output.vertices);
                                if (t.output.indices.len != 0) alloc.free(t.output.indices);
                                continue;
                            }
                            const i: usize = @intCast(t.tile);
                            if (i >= cache.tiles.len) {
                                if (t.output.indices.len != 0) alloc.free(t.output.indices);
                                if (t.output.vertices.len != 0) alloc.free(t.output.vertices);
                                continue;
                            }

                            if (cache.tiles[i].vertices.len != 0) alloc.free(cache.tiles[i].vertices);
                            if (cache.tiles[i].indices.len != 0) alloc.free(cache.tiles[i].indices);

                            cache.tiles[i].vertices = t.output.vertices;
                            cache.tiles[i].indices = t.output.indices;
                            cache.tiles[i].vertex_count = t.output.vertex_count;
                            cache.tiles[i].index_count = t.output.index_count;
                        }
                        if (job.tile_outputs.len != 0) alloc.free(job.tile_outputs);
                        job.tile_outputs = @constCast(&[_]BrickTileOutput{});

                        var total_v: u32 = 0;
                        var total_i: u32 = 0;
                        for (cache.tiles) |tm| {
                            total_v += tm.vertex_count;
                            total_i += tm.index_count;
                        }

                        if (total_v > 0 and total_i > 0) {
                            if (ensure_mesh_capacity(state, mesh_index, model_mesh, combined_mesh, total_v, total_i)) {
                                if (model_mesh.vertices != null and model_mesh.indices != null) {
                                    const dst_v = @as([*]scene.CardinalVertex, @ptrCast(model_mesh.vertices.?))[0..@as(usize, @intCast(total_v))];
                                    const dst_i = @as([*]u32, @ptrCast(model_mesh.indices.?))[0..@as(usize, @intCast(total_i))];

                                    var v_off: u32 = 0;
                                    var i_off: u32 = 0;
                                    for (cache.tiles) |tm| {
                                        if (tm.vertex_count == 0 or tm.index_count == 0) continue;
                                        const vv: usize = @intCast(tm.vertex_count);
                                        const ii: usize = @intCast(tm.index_count);
                                        const v_start: usize = @intCast(v_off);
                                        const i_start: usize = @intCast(i_off);
                                        @memcpy(dst_v[v_start .. v_start + vv], tm.vertices[0..vv]);
                                        var k: usize = 0;
                                        while (k < ii) : (k += 1) {
                                            dst_i[i_start + k] = tm.indices[k] + v_off;
                                        }
                                        v_off += tm.vertex_count;
                                        i_off += tm.index_count;
                                    }

                                    model_mesh.vertex_count = total_v;
                                    model_mesh.index_count = total_i;
                                    if (combined_mesh) |cmb| {
                                        cmb.vertex_count = total_v;
                                        cmb.index_count = total_i;
                                    }
                                    state.runtime.pending_scene = state.runtime.combined_scene;
                                    state.runtime.scene_upload_pending = true;
                                    state.runtime.picking_cache_dirty = true;
                                }
                            }
                        } else {
                            model_mesh.vertex_count = 0;
                            model_mesh.index_count = 0;
                            if (combined_mesh) |cmb| {
                                cmb.vertex_count = 0;
                                cmb.index_count = 0;
                            }
                            const assets_alloc = memory.cardinal_get_allocator_for_category(.ASSETS);
                            if (model_mesh.vertices) |p| {
                                memory.cardinal_free(assets_alloc, @ptrCast(p));
                                model_mesh.vertices = null;
                                if (combined_mesh) |cmb| cmb.vertices = null;
                            }
                            if (model_mesh.indices) |p| {
                                memory.cardinal_free(assets_alloc, @ptrCast(p));
                                model_mesh.indices = null;
                                if (combined_mesh) |cmb| cmb.indices = null;
                            }
                            _ = state.runtime.volumetric_mesh_caps.remove(mesh_index);
                        }
                    }
                }
            }
        }
    } else if (!ok) {
        const dirty_ptr = state.runtime.volumetric_dirty_brick_boxes.getPtr(job.key) orelse null;
        if (dirty_ptr != null) {
            const mask_ptr = state.runtime.volumetric_dirty_brick_lod_masks.getPtr(job.key) orelse null;
            if (mask_ptr != null) mask_ptr.?.* |= C.lod_bit(job.lod);
        }
    }

    if (job.tile_outputs.len != 0) {
        free_tile_outputs(alloc, job.tile_outputs);
    }

    release_density_snapshot(state, job.snapshot_key);
    alloc.destroy(job);
    async_loader.cardinal_async_free_task(task);
}

pub fn schedule_brick_remeshes(state: *EditorState, ensure_vt_data: *const fn (*EditorState, engine.ecs_entity.Entity) ?*VolumetricTerrainData) void {
    if (!state.ui.project_loaded) return;
    if (!async_loader.cardinal_async_loader_is_initialized()) return;

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const now_ms_i64: i64 = std.time.milliTimestamp();
    const now_ms: u64 = if (now_ms_i64 <= 0) 0 else @intCast(now_ms_i64);
    if (state.runtime.volumetric_brick_remesh_tasks.count() >= C.max_brick_tasks_in_flight) return;

    const Candidate = struct { key: VolumetricBrickKey, score: f32 };
    var candidates: std.ArrayListUnmanaged(Candidate) = .{};
    defer candidates.deinit(state.runtime.arena_allocator);

    var per_entity_scheduled: std.AutoHashMapUnmanaged(u64, u32) = .{};
    defer per_entity_scheduled.deinit(state.runtime.arena_allocator);

    {
        var it = state.runtime.volumetric_dirty_brick_lod_masks.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const mask = entry.value_ptr.*;
            if (mask == 0) continue;
            if (state.runtime.volumetric_brick_remesh_tasks.get(key) != null) continue;

            const ent = engine.ecs_entity.Entity{ .id = key.entity_id };
            if (!state.runtime.registry.entity_manager.is_alive(ent)) continue;
            const tr = state.runtime.registry.get(components.Transform, ent) orelse continue;

            const visible = state.runtime.volumetric_visible_by_entity.get(ent.id) orelse true;
            if (!visible) continue;

            const desired_lod_u8 = state.runtime.volumetric_lod_by_entity.get(ent.id) orelse 0;
            const desired_lod: u32 = desired_lod_u8;
            const lod_mask = mask & C.lod_bit(desired_lod);
            if (lod_mask == 0) continue;

            const dist = tr.position.sub(state.runtime.camera.position).length();
            var score: f32 = 1000.0 / (dist + 1.0);
            score += @as(f32, @floatFromInt(C.lod_level_count - 1 - desired_lod)) * 5.0;
            if (state.runtime.registry.entity_manager.is_alive(state.ui.selected_entity) and state.ui.selected_entity.id == ent.id) {
                score += 100000.0;
            }
            candidates.append(state.runtime.arena_allocator, .{ .key = key, .score = score }) catch {};
        }
    }

    if (candidates.items.len == 0) return;

    std.sort.pdq(Candidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.score > b.score;
        }
    }.lessThan);

    var scheduled: u32 = 0;
    var idx: usize = 0;
    while (idx < candidates.items.len) : (idx += 1) {
        if (scheduled >= C.max_brick_tasks_to_schedule_per_update) break;
        if (state.runtime.volumetric_brick_remesh_tasks.count() >= C.max_brick_tasks_in_flight) break;

        const key = candidates.items[idx].key;
        const mask_ptr = state.runtime.volumetric_dirty_brick_lod_masks.getPtr(key) orelse continue;
        const mask = mask_ptr.*;
        if (mask == 0) continue;
        if (state.runtime.volumetric_brick_remesh_tasks.get(key) != null) continue;

        const ent = engine.ecs_entity.Entity{ .id = key.entity_id };
        if (!state.runtime.registry.entity_manager.is_alive(ent)) continue;
        const vt = state.runtime.registry.get(components.VolumetricTerrain, ent) orelse continue;

        const visible = state.runtime.volumetric_visible_by_entity.get(ent.id) orelse true;
        if (!visible) continue;

        const selected = state.ui.selected_entity;
        const is_selected = state.runtime.registry.entity_manager.is_alive(selected) and selected.id == ent.id;
        const per_entity_count: u32 = per_entity_scheduled.get(ent.id) orelse 0;
        if (!is_selected and per_entity_count >= 2) continue;

        const last_ms = state.runtime.volumetric_brick_last_schedule_ms.get(key) orelse 0;
        if (!is_selected and last_ms != 0 and now_ms > last_ms and (now_ms - last_ms) < 50) continue;

        const desired_lod_u8 = state.runtime.volumetric_lod_by_entity.get(ent.id) orelse 0;
        const desired_lod: u32 = desired_lod_u8;
        const lod_mask = mask & C.lod_bit(desired_lod);
        if (lod_mask == 0) continue;

        const td = ensure_vt_data(state, ent) orelse continue;
        if (td.dims < 2) continue;
        const base_res: u32 = td.dims - 1;
        if (base_res < 1) continue;

        const dirty_box: VolumetricDirtyBox = state.runtime.volumetric_dirty_brick_boxes.get(key) orelse VolumetricDirtyBox{
            .min_x = 0,
            .min_y = 0,
            .min_z = 0,
            .max_x = base_res - 1,
            .max_y = base_res - 1,
            .max_z = base_res - 1,
        };

        const snapshot = acquire_density_snapshot(state, ent, vt, td) orelse continue;

        const key_lod = VolumetricBrickLodKey{ .entity_id = key.entity_id, .brick_id = key.brick_id, .lod = @intCast(desired_lod) };
        const full_rebuild = state.runtime.volumetric_brick_tile_cache.get(key_lod) == null;

        const job = alloc.create(BrickRemeshJobData) catch {
            release_density_snapshot(state, snapshot.key);
            continue;
        };
        job.* = .{
            .key = key,
            .generation = state.runtime.volumetric_brick_generation.get(key) orelse 0,
            .dirty_box = dirty_box,
            .model_id = vt.model_id,
            .base_mesh_index = vt.mesh_index,
            .size = vt.size,
            .base_res = base_res,
            .base_dims = td.dims,
            .axis = C.brick_axis_count(base_res),
            .lod = desired_lod,
            .full_rebuild = full_rebuild,
            .data_id = vt.data_id,
            .density = snapshot.density,
            .splat = snapshot.splat,
            .snapshot_key = snapshot.key,
            .tile_outputs = @constCast(&[_]BrickTileOutput{}),
        };

        const task = async_loader.cardinal_async_submit_custom_task(
            brick_task_func,
            job,
            .NORMAL,
            brick_task_callback,
            state,
        ) orelse {
            alloc.destroy(job);
            release_density_snapshot(state, snapshot.key);
            continue;
        };

        state.runtime.volumetric_brick_remesh_tasks.put(alloc, key, task) catch {};
        state.runtime.volumetric_brick_last_schedule_ms.put(alloc, key, now_ms) catch {};
        per_entity_scheduled.put(state.runtime.arena_allocator, ent.id, per_entity_count + 1) catch {};

        mask_ptr.* &= ~C.lod_bit(desired_lod);
        if (mask_ptr.* == 0) _ = state.runtime.volumetric_dirty_brick_lod_masks.remove(key);
        _ = state.runtime.volumetric_dirty_brick_boxes.remove(key);
        scheduled += 1;
    }
}

pub fn remesh_volumetric_terrain_initial(state: *EditorState, entity_id: u64) void {
    const ent = engine.ecs_entity.Entity{ .id = entity_id };
    if (!state.runtime.registry.entity_manager.is_alive(ent)) return;
    const td = Data.ensure_volumetric_terrain_data_for_entity(state, ent) orelse return;
    if (td.dims < 2) return;

    const res: u32 = td.dims - 1;
    if (res < 1) return;
    Dirty.mark_dirty_bricks_masked(state, entity_id, .{
        .min_x = 0,
        .min_y = 0,
        .min_z = 0,
        .max_x = res - 1,
        .max_y = res - 1,
        .max_z = res - 1,
    }, C.all_lods_mask, res);
    schedule_brick_remeshes(state, Data.ensure_volumetric_terrain_data_for_entity);
}

pub fn remesh_volumetric_terrain(state: *EditorState, entity_id: u64) void {
    remesh_volumetric_terrain_initial(state, entity_id);
}
