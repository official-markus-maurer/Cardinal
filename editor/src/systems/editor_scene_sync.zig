//! Scene-derived editor runtime synchronization.
//!
//! Bridges live ECS state into renderer-facing runtime structures (combined scene), and maintains
//! small caches used during per-frame synchronization.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const renderer = engine.vulkan_renderer;
const scene = engine.scene;
const animation = engine.animation;
const EditorState = @import("../editor_state.zig").EditorState;

/// Syncs the active skybox asset from ECS into runtime state.
pub fn sync_skybox_from_ecs(state: *EditorState, allocator: std.mem.Allocator) void {
    var view = state.runtime.registry.view(engine.ecs_components.Skybox);
    var it = view.iterator();
    const entry = it.next() orelse return;
    const sky = entry.component;
    const path = sky.slice();
    if (path.len == 0) return;

    if (state.runtime.skybox_path) |p| {
        if (std.mem.eql(u8, std.mem.span(p.ptr), path)) return;
        allocator.free(p);
        state.runtime.skybox_path = null;
    }

    state.runtime.skybox_path = allocator.dupeZ(u8, path) catch return;
}

fn compute_entity_world_matrix(state: *EditorState, allocator: std.mem.Allocator, cache: *std.AutoHashMapUnmanaged(u64, math.Mat4), entity: engine.ecs_entity.Entity) engine.math.Mat4 {
    return compute_entity_world_matrix_cached(state, allocator, cache, entity, 0);
}

fn compute_entity_world_matrix_cached(state: *EditorState, allocator: std.mem.Allocator, cache: *std.AutoHashMapUnmanaged(u64, math.Mat4), entity: engine.ecs_entity.Entity, depth: u32) engine.math.Mat4 {
    if (cache.get(entity.id)) |m| return m;
    if (depth > 2048) return math.Mat4.identity();

    var parent_world = math.Mat4.identity();
    if (state.runtime.registry.get(engine.ecs_components.Hierarchy, entity)) |h| {
        if (h.parent) |p| {
            parent_world = compute_entity_world_matrix_cached(state, allocator, cache, p, depth + 1);
        }
    }

    var world = parent_world;
    if (state.runtime.registry.get(engine.ecs_components.Transform, entity)) |t| {
        const local = math.Mat4.fromTRS(t.position, t.rotation, t.scale);
        world = parent_world.mul(local);
    }

    cache.put(allocator, entity.id, world) catch {};
    return world;
}

fn node_has_mesh(node: *const scene.CardinalSceneNode, mesh_index: u32) bool {
    if (node.mesh_indices == null or node.mesh_count == 0) return false;
    const indices: []u32 = node.mesh_indices.?[0..@as(usize, @intCast(node.mesh_count))];
    for (indices) |idx| {
        if (idx == mesh_index) return true;
    }
    return false;
}

fn mesh_is_skinned(state: *EditorState, mesh_index: u32) bool {
    if (state.runtime.combined_scene.skin_count == 0) return false;
    if (state.runtime.combined_scene.skins == null) return false;
    const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(state.runtime.combined_scene.skins.?)));

    var s_idx: u32 = 0;
    while (s_idx < state.runtime.combined_scene.skin_count) : (s_idx += 1) {
        const skin = &skins[s_idx];
        if (skin.mesh_indices == null or skin.mesh_count == 0) continue;
        const indices: []u32 = skin.mesh_indices.?[0..@as(usize, @intCast(skin.mesh_count))];
        for (indices) |idx| {
            if (idx == mesh_index) return true;
        }
    }
    return false;
}

fn model_node_range_for_mesh_index(state: *EditorState, mesh_index: u32) ?struct { start: u32, count: u32 } {
    if (state.runtime.model_manager.models == null) return null;
    const models = state.runtime.model_manager.models.?;

    var mesh_offset: u32 = 0;
    var node_offset: u32 = 0;
    var i: u32 = 0;
    while (i < state.runtime.model_manager.model_count) : (i += 1) {
        const model = &models[i];
        if (!model.visible or model.is_loading) continue;

        const mesh_count = model.scene.mesh_count;
        const node_count = model.scene.all_node_count;

        if (mesh_index >= mesh_offset and mesh_index < mesh_offset + mesh_count) {
            return .{ .start = node_offset, .count = node_count };
        }

        mesh_offset += mesh_count;
        node_offset += node_count;
    }

    return null;
}

fn apply_world_delta_to_node_subtree(node: *scene.CardinalSceneNode, delta: math.Mat4, depth: u32) void {
    if (depth > 4096) return;

    const current = math.Mat4.fromArray(node.world_transform);
    const updated = delta.mul(current);
    @memcpy(node.world_transform[0..16], updated.data[0..16]);

    if (node.children == null or node.child_count == 0) return;
    const children: []?*scene.CardinalSceneNode = node.children.?[0..@as(usize, @intCast(node.child_count))];
    for (children) |child_opt| {
        const child = child_opt orelse continue;
        apply_world_delta_to_node_subtree(child, delta, depth + 1);
    }
}

fn apply_mesh_world_override_to_scene_nodes(state: *EditorState, mesh_index: u32, desired_world: math.Mat4) void {
    if (state.runtime.combined_scene.all_nodes == null or state.runtime.combined_scene.all_node_count == 0) return;
    const nodes: []?*scene.CardinalSceneNode = state.runtime.combined_scene.all_nodes.?[0..@as(usize, @intCast(state.runtime.combined_scene.all_node_count))];

    var mesh_node: ?*scene.CardinalSceneNode = null;
    for (nodes) |node_opt| {
        const n = node_opt orelse continue;
        if (node_has_mesh(n, mesh_index)) {
            mesh_node = n;
            break;
        }
    }
    if (mesh_node == null) return;

    const current_world = math.Mat4.fromArray(mesh_node.?.world_transform);
    const inv = current_world.invert() orelse return;
    const delta = desired_world.mul(inv);

    if (mesh_is_skinned(state, mesh_index)) {
        if (model_node_range_for_mesh_index(state, mesh_index)) |range| {
            const start: usize = @intCast(range.start);
            const end: usize = @intCast(range.start + range.count);
            if (start < nodes.len) {
                const clamped_end = @min(end, nodes.len);
                var i: usize = start;
                while (i < clamped_end) : (i += 1) {
                    const n = nodes[i] orelse continue;
                    const cur = math.Mat4.fromArray(n.world_transform);
                    const updated = delta.mul(cur);
                    @memcpy(n.world_transform[0..16], updated.data[0..16]);
                }
                return;
            }
        }
    }

    apply_world_delta_to_node_subtree(mesh_node.?, delta, 0);
}

/// Pushes ECS-driven transforms into the combined scene for renderer consumption.
pub fn sync_mesh_transforms_from_ecs(state: *EditorState, allocator: std.mem.Allocator, world_matrix_cache: *std.AutoHashMapUnmanaged(u64, math.Mat4)) void {
    if (!state.runtime.scene_loaded) return;
    if (state.runtime.scene_upload_pending) return;
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return;
    const meshes = state.runtime.combined_scene.meshes.?;

    world_matrix_cache.clearRetainingCapacity();

    var view = state.runtime.registry.view(engine.ecs_components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        if (state.runtime.transform_overrides.get(entry.entity.id) == null) continue;
        const mr = entry.component;
        const mesh_index = mr.mesh.index;
        if (mesh_index >= state.runtime.combined_scene.mesh_count) continue;

        const m = compute_entity_world_matrix(state, allocator, world_matrix_cache, entry.entity);
        @memcpy(meshes[mesh_index].transform[0..16], m.data[0..16]);
        apply_mesh_world_override_to_scene_nodes(state, mesh_index, m);
        _ = renderer.cardinal_renderer_update_mesh_transform(state.runtime.renderer, mesh_index, @ptrCast(&m.data));
    }
}

/// Syncs per-mesh visibility flags from ECS into the combined scene.
pub fn sync_mesh_visibility_from_ecs(state: *EditorState) void {
    if (!state.runtime.scene_loaded) return;
    if (state.runtime.scene_upload_pending) return;
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return;
    const meshes = state.runtime.combined_scene.meshes.?;

    var i: u32 = 0;
    while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
        meshes[i].visible = false;
    }

    var view = state.runtime.registry.view(engine.ecs_components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        const mr = entry.component;
        const mesh_index = mr.mesh.index;
        if (mesh_index >= state.runtime.combined_scene.mesh_count) continue;
        meshes[mesh_index].visible = mr.visible;
    }
}

/// Rebuilds mesh-index -> entity maps from ECS `MeshRenderer` components.
pub fn sync_mesh_index_maps_from_ecs(state: *EditorState, allocator: std.mem.Allocator) void {
    if (!state.runtime.scene_loaded) return;

    state.runtime.mesh_entity_by_mesh_index.clearRetainingCapacity();
    state.runtime.mesh_owner_by_mesh_index.clearRetainingCapacity();

    var view = state.runtime.registry.view(engine.ecs_components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        const mr = entry.component;
        state.runtime.mesh_entity_by_mesh_index.put(allocator, mr.mesh.index, entry.entity.id) catch {};
        state.runtime.mesh_owner_by_mesh_index.put(allocator, mr.mesh.index, entry.entity.id) catch {};
    }
}
