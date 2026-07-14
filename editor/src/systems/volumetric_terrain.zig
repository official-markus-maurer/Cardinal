const C = @import("volumetric_terrain/common.zig");
const std = C.std;
const engine = C.engine;
const EditorState = C.EditorState;
const memory = C.memory;
const components = C.components;
const math = C.math;

const lod_level_count = C.lod_level_count;
const brick_axis_count = C.brick_axis_count;

const Data = @import("volumetric_terrain/data.zig");
const Gpu = @import("volumetric_terrain/gpu.zig");
const Bricks = @import("volumetric_terrain/bricks.zig");
const Streaming = @import("volumetric_terrain/streaming.zig");
const Tasks = @import("volumetric_terrain/tasks.zig");
const Editing = @import("volumetric_terrain/editing.zig");

pub const ensure_volumetric_terrain_data_for_entity = Data.ensure_volumetric_terrain_data_for_entity;
pub const flush_volumetric_pending_uploads = Gpu.flush_volumetric_pending_uploads;
pub const ensure_volumetric_material_bound = Gpu.ensure_volumetric_material_bound;
pub const ensure_brick_entities = Bricks.ensure_brick_entities;
pub const build_scene = Bricks.build_scene;
pub const StreamingHooks = Streaming.StreamingHooks;
pub const StreamingConfig = Streaming.StreamingConfig;
pub var streaming_config: StreamingConfig = .{};
pub fn set_streaming_hooks(hooks: StreamingHooks) void {
    Streaming.set_streaming_hooks(hooks);
}

pub const apply_sculpt_group = Editing.apply_sculpt_group;
pub const apply_paint = Editing.apply_paint;
pub const apply_paint_group = Editing.apply_paint_group;

pub const remesh_volumetric_terrain_initial = Tasks.remesh_volumetric_terrain_initial;
pub const remesh_volumetric_terrain = Tasks.remesh_volumetric_terrain;

fn schedule_brick_remeshes(state: *EditorState) void {
    Tasks.schedule_brick_remeshes(state, ensure_volumetric_terrain_data_for_entity);
}


pub fn update_lods_and_streaming(state: *EditorState) void {
    if (!state.runtime.scene_loaded) return;
    Streaming.streaming_config = streaming_config;

    const cam_pos = state.runtime.camera.position;
    const view_mat = math.Mat4.lookAt(state.runtime.camera.position, state.runtime.camera.target, state.runtime.camera.up);
    const proj_mat = math.Mat4.perspective(math.toRadians(state.runtime.camera.fov), state.runtime.camera.aspect, state.runtime.camera.near_plane, state.runtime.camera.far_plane);
    const frustum = math.Frustum.fromMatrix(proj_mat.mul(view_mat));
    const frame_alloc = state.runtime.arena_allocator;
    const persistent_alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    const Key = struct {
        parent_id: u64,
        x: i32,
        y: i32,
        z: i32,
    };
    const Entry = struct { ent: engine.ecs_entity.Entity, vt: *components.VolumetricTerrain, key: Key, desired_lod: u8, visible: bool };

    var lod_by_key: std.AutoHashMapUnmanaged(Key, u8) = .{};
    var entries: std.ArrayListUnmanaged(Entry) = .{};
    defer lod_by_key.deinit(frame_alloc);
    defer entries.deinit(frame_alloc);

    var vt_view = state.runtime.registry.view(components.VolumetricTerrain);
    var it = vt_view.iterator();
    while (it.next()) |entry| {
        const ent = entry.entity;
        const vt = entry.component;
        const tr = state.runtime.registry.get(components.Transform, ent) orelse continue;
        ensure_brick_entities(state, ent);

        const dist = tr.position.sub(cam_pos).length();
        const base_size = @max(vt.size.x, @max(vt.size.y, vt.size.z));
        const unload_dist = base_size * streaming_config.unload_distance_multiplier;

        const visible = (!streaming_config.enable) or (dist <= unload_dist);
        if (visible) _ = ensure_volumetric_terrain_data_for_entity(state, ent);
        const prev_visible = state.runtime.volumetric_visible_by_entity.get(ent.id) orelse true;
        if (prev_visible != visible) {
            state.runtime.volumetric_visible_by_entity.put(persistent_alloc, ent.id, visible) catch {};
            if (Streaming.g_streaming_hooks.on_chunk_visibility_changed) |hook| hook(state, ent.id, visible);
        }

        const lod: u32 = Streaming.compute_desired_lod_hysteresis(state, ent, vt, tr);

        const hier = state.runtime.registry.get(components.Hierarchy, ent);
        const parent_id: u64 = if (hier) |h| if (h.parent) |p| p.id else 0 else 0;

        const key = Key{ .parent_id = parent_id, .x = vt.chunk_x, .y = vt.chunk_y, .z = vt.chunk_z };
        const desired: u8 = @intCast(lod);
        lod_by_key.put(frame_alloc, key, desired) catch {};
        entries.append(frame_alloc, .{
            .ent = ent,
            .vt = vt,
            .key = key,
            .desired_lod = desired,
            .visible = visible,
        }) catch {};
    }

    var iter_count: u32 = 0;
    while (iter_count < 4) : (iter_count += 1) {
        var changed = false;
        for (entries.items) |e| {
            var my_lod: u8 = lod_by_key.get(e.key) orelse e.desired_lod;
            const nx = [_][3]i32{
                .{ 1, 0, 0 },
                .{ -1, 0, 0 },
                .{ 0, 1, 0 },
                .{ 0, -1, 0 },
                .{ 0, 0, 1 },
                .{ 0, 0, -1 },
            };
            for (nx) |d| {
                const nk = Key{
                    .parent_id = e.key.parent_id,
                    .x = e.key.x + d[0],
                    .y = e.key.y + d[1],
                    .z = e.key.z + d[2],
                };
                const n_lod = lod_by_key.get(nk) orelse continue;
                if (streaming_config.crack_free_lod) {
                    const m: u8 = @min(my_lod, n_lod);
                    if (my_lod != m) {
                        my_lod = m;
                        lod_by_key.put(frame_alloc, e.key, my_lod) catch {};
                        changed = true;
                    }
                    if (n_lod != m) {
                        lod_by_key.put(frame_alloc, nk, m) catch {};
                        changed = true;
                    }
                } else {
                    const max_allowed: u8 = @intCast(@min(@as(u32, n_lod) + 1, lod_level_count - 1));
                    if (my_lod > max_allowed) {
                        my_lod = max_allowed;
                        lod_by_key.put(frame_alloc, e.key, my_lod) catch {};
                        changed = true;
                    }
                }
            }
        }
        if (!changed) break;
    }

    var lod_changes_left: u32 = 16;
    for (entries.items) |e| {
        const final_lod: u32 = @intCast(lod_by_key.get(e.key) orelse e.desired_lod);
        const prev_lod_u8: u8 = state.runtime.volumetric_lod_by_entity.get(e.ent.id) orelse @as(u8, @intCast(final_lod));
        var applied: u32 = final_lod;
        if (prev_lod_u8 != @as(u8, @intCast(final_lod))) {
            const selected = state.ui.selected_entity;
            const is_selected = state.runtime.registry.entity_manager.is_alive(selected) and selected.id == e.ent.id;
            if (!is_selected and lod_changes_left == 0) {
                applied = prev_lod_u8;
            } else if (!is_selected) {
                lod_changes_left -= 1;
            }
        }
        state.runtime.volumetric_lod_by_entity.put(persistent_alloc, e.ent.id, @intCast(applied)) catch {};
        state.runtime.volumetric_visible_by_entity.put(persistent_alloc, e.ent.id, e.visible) catch {};
    }

    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return;
    const meshes = state.runtime.combined_scene.meshes.?;

    var bview = state.runtime.registry.view(components.VolumetricTerrainBrick);
    var bit = bview.iterator();
    while (bit.next()) |bentry| {
        const brick = bentry.component;
        const ent = bentry.entity;
        const mr = state.runtime.registry.get(components.MeshRenderer, ent) orelse continue;
        const parent_ent = engine.ecs_entity.Entity{ .id = brick.parent_id };
        if (!state.runtime.registry.entity_manager.is_alive(parent_ent)) {
            mr.visible = false;
            continue;
        }
        const vt = state.runtime.registry.get(components.VolumetricTerrain, parent_ent) orelse {
            mr.visible = false;
            continue;
        };
        const tr = state.runtime.registry.get(components.Transform, parent_ent) orelse {
            mr.visible = false;
            continue;
        };

        const visible = state.runtime.volumetric_visible_by_entity.get(parent_ent.id) orelse true;

        const desired_lod: u32 = state.runtime.volumetric_lod_by_entity.get(parent_ent.id) orelse 0;
        const axis = brick_axis_count(if (vt.resolution < 1) 1 else vt.resolution);
        const bcount: u32 = axis * axis * axis;

        {
            var li: u32 = 0;
            while (li < lod_level_count) : (li += 1) {
                const idx = vt.mesh_index + li * bcount + brick.brick_id;
                if (idx < state.runtime.combined_scene.mesh_count) {
                    meshes[idx].visible = false;
                }
            }
        }

        var chosen: u32 = desired_lod;
        while (chosen > 0) : (chosen -= 1) {
            const idx = vt.mesh_index + chosen * bcount + brick.brick_id;
            if (idx < state.runtime.combined_scene.mesh_count) {
                if (meshes[idx].vertex_count != 0) break;
            }
        }
        const mesh_index = vt.mesh_index + chosen * bcount + brick.brick_id;
        if (mesh_index < state.runtime.combined_scene.mesh_count) {
            mr.mesh.index = mesh_index;
            mr.material.index = meshes[mesh_index].material_index;
        }

        if (!visible) {
            mr.visible = false;
            meshes[mr.mesh.index].visible = false;
            continue;
        }

        if (streaming_config.enable_frustum_culling) {
            const bb_min = meshes[mr.mesh.index].bounding_box_min;
            const bb_max = meshes[mr.mesh.index].bounding_box_max;
            const aabb = math.AABB{
                .min = .{ .x = tr.position.x + bb_min[0], .y = tr.position.y + bb_min[1], .z = tr.position.z + bb_min[2] },
                .max = .{ .x = tr.position.x + bb_max[0], .y = tr.position.y + bb_max[1], .z = tr.position.z + bb_max[2] },
            };
            mr.visible = math.aabbIntersectsFrustum(aabb, frustum);
        } else {
            mr.visible = true;
        }
        meshes[mr.mesh.index].visible = mr.visible;
    }

    schedule_brick_remeshes(state);
}
