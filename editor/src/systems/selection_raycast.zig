//! Editor-side raycast selection helpers.
//!
//! Provides picking against the combined scene plus some view utilities (frame selection, xray AABBs).
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const renderer = engine.vulkan_renderer;
const scene = engine.scene;
const components = engine.ecs_components;
const EditorState = @import("../editor_state.zig").EditorState;
const c = @import("../c.zig").c;

fn compute_entity_world_matrix_cached(
    state: *EditorState,
    allocator: std.mem.Allocator,
    cache: *std.AutoHashMapUnmanaged(u64, math.Mat4),
    entity: engine.ecs_entity.Entity,
    depth: u32,
) math.Mat4 {
    if (cache.get(entity.id)) |m| return m;
    if (depth > 2048) return math.Mat4.identity();

    var parent_world = math.Mat4.identity();
    if (state.runtime.registry.get(components.Hierarchy, entity)) |h| {
        if (h.parent) |p| {
            if (state.runtime.registry.entity_manager.is_alive(p)) {
                parent_world = compute_entity_world_matrix_cached(state, allocator, cache, p, depth + 1);
            }
        }
    }

    const local = if (state.runtime.registry.get(components.Transform, entity)) |t|
        math.Mat4.fromTRS(t.position, t.rotation, t.scale)
    else
        math.Mat4.identity();

    const world = parent_world.mul(local);
    cache.put(allocator, entity.id, world) catch {};
    return world;
}

fn compute_entity_world_matrix(
    state: *EditorState,
    allocator: std.mem.Allocator,
    cache: *std.AutoHashMapUnmanaged(u64, math.Mat4),
    entity: engine.ecs_entity.Entity,
) math.Mat4 {
    return compute_entity_world_matrix_cached(state, allocator, cache, entity, 0);
}

fn mesh_world_matrix(state: *EditorState, allocator: std.mem.Allocator, cache: *std.AutoHashMapUnmanaged(u64, math.Mat4), mesh_index: u32, mesh: *const scene.CardinalMesh) math.Mat4 {
    if (mesh_index_to_entity(state, mesh_index, false)) |e| {
        return compute_entity_world_matrix(state, allocator, cache, e);
    }
    if (mesh_index_to_entity(state, mesh_index, true)) |e| {
        return compute_entity_world_matrix(state, allocator, cache, e);
    }
    return math.Mat4.fromArray(mesh.transform);
}

/// Computes a world-space bounds for `root` by scanning meshes belonging to its subtree.
fn compute_selection_world_aabb(state: *EditorState, root: engine.ecs_entity.Entity) ?math.AABB {
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return null;

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var world_cache: std.AutoHashMapUnmanaged(u64, math.Mat4) = .{};
    defer world_cache.deinit(alloc);

    var found_any = false;
    var out = math.AABB{ .min = math.Vec3.zero(), .max = math.Vec3.zero() };

    var stack: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
    defer stack.deinit(alloc);

    stack.append(alloc, root) catch return null;

    while (stack.items.len > 0) {
        const last = stack.items.len - 1;
        const e = stack.items[last];
        stack.items.len = last;

        if (state.runtime.registry.get(components.MeshRenderer, e)) |mr| {
            const mesh_index = mr.mesh.index;
            if (mesh_index < state.runtime.combined_scene.mesh_count and state.runtime.combined_scene.meshes != null) {
                const mesh = &state.runtime.combined_scene.meshes.?[mesh_index];
                const min = math.Vec3.fromArray(mesh.bounding_box_min);
                const max = math.Vec3.fromArray(mesh.bounding_box_max);
                const aabb = math.AABB{ .min = min, .max = max };
                const world_mat = compute_entity_world_matrix(state, alloc, &world_cache, e);
                const world_aabb = aabb.transform(world_mat);
                if (!found_any) {
                    out = world_aabb;
                    found_any = true;
                } else {
                    out.min.x = @min(out.min.x, world_aabb.min.x);
                    out.min.y = @min(out.min.y, world_aabb.min.y);
                    out.min.z = @min(out.min.z, world_aabb.min.z);
                    out.max.x = @max(out.max.x, world_aabb.max.x);
                    out.max.y = @max(out.max.y, world_aabb.max.y);
                    out.max.z = @max(out.max.z, world_aabb.max.z);
                }
            }
        }

        const h = state.runtime.registry.get(components.Hierarchy, e) orelse continue;
        var child = h.first_child;
        var guard: u32 = 0;
        while (child) |c_ent| {
            if (guard > 100000) break;
            guard += 1;
            stack.append(alloc, c_ent) catch break;
            const ch = state.runtime.registry.get(components.Hierarchy, c_ent) orelse break;
            child = ch.next_sibling;
        }
    }

    return if (found_any) out else null;
}

/// Frames `root` in the scene view based on its subtree bounds.
pub fn frame_entity_in_scene_view(state: *EditorState, root: engine.ecs_entity.Entity) void {
    const aabb = compute_selection_world_aabb(state, root) orelse return;
    const center = aabb.min.add(aabb.max).mul(0.5);
    const extent = aabb.max.sub(aabb.min);
    const radius = 0.5 * extent.length();
    const dist = @max(2.0, radius * 2.5);

    var dir = state.runtime.camera.position.sub(state.runtime.camera.target);
    if (dir.lengthSq() < 0.0001) {
        dir = math.Vec3{ .x = 0.0, .y = 0.0, .z = 1.0 };
    }
    dir = dir.normalize();

    state.runtime.camera.target = center;
    state.runtime.camera.position = center.add(dir.mul(dist));

    const front = state.runtime.camera.target.sub(state.runtime.camera.position).normalize();
    state.runtime.pitch = math.toDegrees(std.math.asin(front.y));
    state.runtime.yaw = math.toDegrees(std.math.atan2(front.z, front.x));

    if (state.runtime.pbr_enabled) {
        renderer.cardinal_renderer_set_camera(state.runtime.renderer, &state.runtime.camera);
    }
}

fn project_to_screen(state: *EditorState, view_proj: math.Mat4, p: math.Vec3) ?c.ImVec2 {
    const win_width = state.runtime.window.width;
    const win_height = state.runtime.window.height;

    const v4 = view_proj.mulVec4(math.Vec4{ .x = p.x, .y = p.y, .z = p.z, .w = 1.0 });
    if (v4.w <= 0.0) return null;
    const ndc = math.Vec3{ .x = v4.x / v4.w, .y = v4.y / v4.w, .z = v4.z / v4.w };

    const x = (ndc.x + 1.0) * 0.5 * @as(f32, @floatFromInt(win_width));
    const y = (ndc.y + 1.0) * 0.5 * @as(f32, @floatFromInt(win_height));
    return c.ImVec2{ .x = x, .y = y };
}

fn draw_aabb_xray(state: *EditorState, view_proj: math.Mat4, aabb: math.AABB, color: u32, thickness: f32) void {
    const min = aabb.min;
    const max = aabb.max;

    const corners = [_]math.Vec3{
        .{ .x = min.x, .y = min.y, .z = min.z },
        .{ .x = max.x, .y = min.y, .z = min.z },
        .{ .x = max.x, .y = max.y, .z = min.z },
        .{ .x = min.x, .y = max.y, .z = min.z },
        .{ .x = min.x, .y = min.y, .z = max.z },
        .{ .x = max.x, .y = min.y, .z = max.z },
        .{ .x = max.x, .y = max.y, .z = max.z },
        .{ .x = min.x, .y = max.y, .z = max.z },
    };

    var pts: [8]?c.ImVec2 = undefined;
    for (0..8) |i| {
        pts[i] = project_to_screen(state, view_proj, corners[i]);
    }

    const edges = [_][2]u8{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 },
        .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 },
        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
    };

    for (edges) |e| {
        const a = pts[e[0]];
        const b = pts[e[1]];
        if (a == null or b == null) continue;
        var pa = a.?;
        var pb = b.?;
        c.imgui_bridge_draw_line(&pa, &pb, color, thickness);
    }
}

fn draw_obb_xray(state: *EditorState, view_proj: math.Mat4, local: math.AABB, world_mat: math.Mat4, color: u32, thickness: f32) void {
    const min = local.min;
    const max = local.max;

    var corners = [_]math.Vec3{
        .{ .x = min.x, .y = min.y, .z = min.z },
        .{ .x = max.x, .y = min.y, .z = min.z },
        .{ .x = max.x, .y = max.y, .z = min.z },
        .{ .x = min.x, .y = max.y, .z = min.z },
        .{ .x = min.x, .y = min.y, .z = max.z },
        .{ .x = max.x, .y = min.y, .z = max.z },
        .{ .x = max.x, .y = max.y, .z = max.z },
        .{ .x = min.x, .y = max.y, .z = max.z },
    };

    for (0..8) |i| {
        corners[i] = world_mat.transformPoint(corners[i]);
    }

    var pts: [8]?c.ImVec2 = undefined;
    for (0..8) |i| {
        pts[i] = project_to_screen(state, view_proj, corners[i]);
    }

    const edges = [_][2]u8{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 },
        .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 },
        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
    };

    for (edges) |e| {
        const a = pts[e[0]];
        const b = pts[e[1]];
        if (a == null or b == null) continue;
        var pa = a.?;
        var pb = b.?;
        c.imgui_bridge_draw_line(&pa, &pb, color, thickness);
    }
}

/// Draws xray AABBs for meshes owned by entities in `root` subtree.
pub fn draw_selection_xray(state: *EditorState, root: engine.ecs_entity.Entity) void {
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return;

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var world_cache: std.AutoHashMapUnmanaged(u64, math.Mat4) = .{};
    defer world_cache.deinit(alloc);

    const view = math.Mat4.lookAt(state.runtime.camera.position, state.runtime.camera.target, state.runtime.camera.up);
    const proj = math.Mat4.perspective(math.toRadians(state.runtime.camera.fov), state.runtime.camera.aspect, state.runtime.camera.near_plane, state.runtime.camera.far_plane);
    const view_proj = proj.mul(view);

    var stack: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
    defer stack.deinit(alloc);
    stack.append(alloc, root) catch return;

    while (stack.items.len > 0) {
        const last = stack.items.len - 1;
        const e = stack.items[last];
        stack.items.len = last;

        if (state.runtime.registry.get(components.MeshRenderer, e)) |mr| {
            const mesh_index = mr.mesh.index;
            if (mesh_index < state.runtime.combined_scene.mesh_count and state.runtime.combined_scene.meshes != null) {
                const mesh = &state.runtime.combined_scene.meshes.?[mesh_index];
                const min_arr = mesh.bounding_box_min;
                const max_arr = mesh.bounding_box_max;
                const min = math.Vec3{ .x = min_arr[0], .y = min_arr[1], .z = min_arr[2] };
                const max = math.Vec3{ .x = max_arr[0], .y = max_arr[1], .z = max_arr[2] };

                const aabb = math.AABB{ .min = min, .max = max };
                const world_mat = compute_entity_world_matrix(state, alloc, &world_cache, e);

                const is_root = e.id == root.id;
                draw_obb_xray(state, view_proj, aabb, world_mat, if (is_root) 0x8000FFFF else 0x4000FFFF, if (is_root) 2.0 else 1.0);
            }
        }

        const h = state.runtime.registry.get(components.Hierarchy, e) orelse continue;
        var child = h.first_child;
        var guard: u32 = 0;
        while (child) |c_ent| {
            if (guard > 100000) break;
            guard += 1;
            stack.append(alloc, c_ent) catch break;
            const ch = state.runtime.registry.get(components.Hierarchy, c_ent) orelse break;
            child = ch.next_sibling;
        }
    }
}

fn draw_selection_xray_subtree(state: *EditorState, root: engine.ecs_entity.Entity, view_proj: math.Mat4, color: u32, thickness: f32) void {
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return;

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var world_cache: std.AutoHashMapUnmanaged(u64, math.Mat4) = .{};
    defer world_cache.deinit(alloc);

    var stack: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
    defer stack.deinit(alloc);
    stack.append(alloc, root) catch return;

    while (stack.items.len > 0) {
        const last = stack.items.len - 1;
        const e = stack.items[last];
        stack.items.len = last;

        if (state.runtime.registry.get(components.MeshRenderer, e)) |mr| {
            const mesh_index = mr.mesh.index;
            if (mesh_index < state.runtime.combined_scene.mesh_count and state.runtime.combined_scene.meshes != null) {
                const mesh = &state.runtime.combined_scene.meshes.?[mesh_index];
                const aabb = math.AABB{ .min = math.Vec3.fromArray(mesh.bounding_box_min), .max = math.Vec3.fromArray(mesh.bounding_box_max) };
                const world_mat = compute_entity_world_matrix(state, alloc, &world_cache, e);
                draw_obb_xray(state, view_proj, aabb, world_mat, color, thickness);
            }
        }

        const h = state.runtime.registry.get(components.Hierarchy, e) orelse continue;
        var child = h.first_child;
        var guard: u32 = 0;
        while (child) |c_ent| {
            if (guard > 100000) break;
            guard += 1;
            stack.append(alloc, c_ent) catch break;
            const ch = state.runtime.registry.get(components.Hierarchy, c_ent) orelse break;
            child = ch.next_sibling;
        }
    }
}

pub fn draw_selection_xray_group(state: *EditorState, roots: []const engine.ecs_entity.Entity) void {
    if (roots.len == 0) return;

    const view = math.Mat4.lookAt(state.runtime.camera.position, state.runtime.camera.target, state.runtime.camera.up);
    const proj = math.Mat4.perspective(math.toRadians(state.runtime.camera.fov), state.runtime.camera.aspect, state.runtime.camera.near_plane, state.runtime.camera.far_plane);
    const view_proj = proj.mul(view);

    var found_any = false;
    var union_aabb = math.AABB{ .min = math.Vec3.zero(), .max = math.Vec3.zero() };
    for (roots) |r| {
        const aabb = compute_selection_world_aabb(state, r) orelse continue;
        if (!found_any) {
            union_aabb = aabb;
            found_any = true;
        } else {
            union_aabb.min.x = @min(union_aabb.min.x, aabb.min.x);
            union_aabb.min.y = @min(union_aabb.min.y, aabb.min.y);
            union_aabb.min.z = @min(union_aabb.min.z, aabb.min.z);
            union_aabb.max.x = @max(union_aabb.max.x, aabb.max.x);
            union_aabb.max.y = @max(union_aabb.max.y, aabb.max.y);
            union_aabb.max.z = @max(union_aabb.max.z, aabb.max.z);
        }
    }

    if (found_any) {
        draw_aabb_xray(state, view_proj, union_aabb, 0x8000FFFF, 2.0);
    }

    for (roots) |r| {
        draw_selection_xray_subtree(state, r, view_proj, 0x4000FFFF, 1.0);
    }
}

const BVHNode = struct {
    aabb: math.AABB,
    left: u32,
    right: u32,
    first: u32,
    count: u32,
};

const MeshPickBvh = struct {
    nodes: []BVHNode,
    tri_offsets: []u32,
    root: u32,
    vertices_ptr: usize,
    indices_ptr: usize,
    vertex_count: u32,
    index_count: u32,

    fn deinit(self: *MeshPickBvh, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.tri_offsets);
    }
};

var pick_bvh_cache: std.AutoHashMapUnmanaged(u32, MeshPickBvh) = .{};

/// Clears cached BVHs used for triangle-accurate mesh picking.
pub fn reset_picking_cache() void {
    const allocator = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var it = pick_bvh_cache.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    pick_bvh_cache.deinit(allocator);
    pick_bvh_cache = .{};
}

/// Computes a world-space ray from the current mouse position.
pub fn get_ray_from_mouse(state: *EditorState) ?math.Ray {
    var mouse_pos_im: c.ImVec2 = undefined;
    c.imgui_bridge_get_mouse_pos(&mouse_pos_im);
    const mouse_pos = math.Vec2{ .x = mouse_pos_im.x, .y = mouse_pos_im.y };

    if (mouse_pos.x < 0 or mouse_pos.y < 0) return null;

    const win_width = state.runtime.window.width;
    const win_height = state.runtime.window.height;

    if (win_width == 0 or win_height == 0) return null;

    const x = (2.0 * mouse_pos.x) / @as(f32, @floatFromInt(win_width)) - 1.0;
    const y = (2.0 * mouse_pos.y) / @as(f32, @floatFromInt(win_height)) - 1.0;

    const ray_nds = math.Vec3{ .x = x, .y = y, .z = 1.0 };
    const ray_clip = math.Vec4{ .x = ray_nds.x, .y = ray_nds.y, .z = -1.0, .w = 1.0 };

    const proj = math.Mat4.perspective(math.toRadians(state.runtime.camera.fov), state.runtime.camera.aspect, state.runtime.camera.near_plane, state.runtime.camera.far_plane);
    const inv_proj = proj.invert() orelse return null;

    var ray_eye_v4 = inv_proj.mulVec4(ray_clip);
    ray_eye_v4.z = -1.0;
    ray_eye_v4.w = 0.0;

    const ray_eye = math.Vec3{ .x = ray_eye_v4.x, .y = ray_eye_v4.y, .z = ray_eye_v4.z };

    const view = math.Mat4.lookAt(state.runtime.camera.position, state.runtime.camera.target, state.runtime.camera.up);
    const inv_view = view.invert() orelse return null;

    const ray_world_v4 = inv_view.mulVec4(math.Vec4{ .x = ray_eye.x, .y = ray_eye.y, .z = ray_eye.z, .w = 0.0 });
    var ray_world = math.Vec3{ .x = ray_world_v4.x, .y = ray_world_v4.y, .z = ray_world_v4.z };
    ray_world = ray_world.normalize();

    return math.Ray{ .origin = state.runtime.camera.position, .direction = ray_world };
}

fn build_mesh_bvh(mesh: *const scene.CardinalMesh) ?MeshPickBvh {
    const allocator = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const verts: [*]const scene.CardinalVertex = @ptrCast(mesh.vertices.?);
    const idxs: [*]const u32 = @ptrCast(mesh.indices.?);

    const tri_count: u32 = mesh.index_count / 3;
    if (tri_count == 0) return null;

    const TriBuild = struct {
        tri_offset: u32,
        centroid: math.Vec3,
        aabb: math.AABB,
    };

    var tri_build = allocator.alloc(TriBuild, tri_count) catch return null;
    defer allocator.free(tri_build);

    var ti: u32 = 0;
    while (ti < tri_count) : (ti += 1) {
        const tri_offset: u32 = ti * 3;
        const idx0 = idxs[tri_offset + 0];
        const idx1 = idxs[tri_offset + 1];
        const idx2 = idxs[tri_offset + 2];
        if (idx0 >= mesh.vertex_count or idx1 >= mesh.vertex_count or idx2 >= mesh.vertex_count) {
            tri_build[ti] = .{
                .tri_offset = tri_offset,
                .centroid = math.Vec3.zero(),
                .aabb = .{ .min = math.Vec3.zero(), .max = math.Vec3.zero() },
            };
            continue;
        }

        const p0 = math.Vec3{ .x = verts[idx0].px, .y = verts[idx0].py, .z = verts[idx0].pz };
        const p1 = math.Vec3{ .x = verts[idx1].px, .y = verts[idx1].py, .z = verts[idx1].pz };
        const p2 = math.Vec3{ .x = verts[idx2].px, .y = verts[idx2].py, .z = verts[idx2].pz };

        const min = math.Vec3{
            .x = @min(p0.x, @min(p1.x, p2.x)),
            .y = @min(p0.y, @min(p1.y, p2.y)),
            .z = @min(p0.z, @min(p1.z, p2.z)),
        };
        const max = math.Vec3{
            .x = @max(p0.x, @max(p1.x, p2.x)),
            .y = @max(p0.y, @max(p1.y, p2.y)),
            .z = @max(p0.z, @max(p1.z, p2.z)),
        };

        tri_build[ti] = .{
            .tri_offset = tri_offset,
            .centroid = p0.add(p1).add(p2).mul(1.0 / 3.0),
            .aabb = .{ .min = min, .max = max },
        };
    }

    var tri_offsets = allocator.alloc(u32, tri_count) catch return null;
    errdefer allocator.free(tri_offsets);
    for (tri_build, 0..) |t, i| tri_offsets[i] = t.tri_offset;

    var nodes_list = std.ArrayListUnmanaged(BVHNode){};
    errdefer {
        allocator.free(tri_offsets);
        nodes_list.deinit(allocator);
    }

    const BuildCtx = struct {
        tris: []TriBuild,
        offsets: []u32,
        nodes: *std.ArrayListUnmanaged(BVHNode),
        allocator: std.mem.Allocator,

        fn build(self: *@This(), start: u32, count: u32) !u32 {
            const node_index: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, undefined);

            var bounds_min = math.Vec3{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32), .z = std.math.floatMax(f32) };
            var bounds_max = math.Vec3{ .x = -std.math.floatMax(f32), .y = -std.math.floatMax(f32), .z = -std.math.floatMax(f32) };

            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const t = self.tris[start + i];
                bounds_min.x = @min(bounds_min.x, t.aabb.min.x);
                bounds_min.y = @min(bounds_min.y, t.aabb.min.y);
                bounds_min.z = @min(bounds_min.z, t.aabb.min.z);
                bounds_max.x = @max(bounds_max.x, t.aabb.max.x);
                bounds_max.y = @max(bounds_max.y, t.aabb.max.y);
                bounds_max.z = @max(bounds_max.z, t.aabb.max.z);
            }

            if (count <= 8) {
                self.nodes.items[node_index] = .{
                    .aabb = .{ .min = bounds_min, .max = bounds_max },
                    .left = 0,
                    .right = 0,
                    .first = start,
                    .count = count,
                };
                return node_index;
            }

            var cmin = math.Vec3{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32), .z = std.math.floatMax(f32) };
            var cmax = math.Vec3{ .x = -std.math.floatMax(f32), .y = -std.math.floatMax(f32), .z = -std.math.floatMax(f32) };
            i = 0;
            while (i < count) : (i += 1) {
                const cent = self.tris[start + i].centroid;
                cmin.x = @min(cmin.x, cent.x);
                cmin.y = @min(cmin.y, cent.y);
                cmin.z = @min(cmin.z, cent.z);
                cmax.x = @max(cmax.x, cent.x);
                cmax.y = @max(cmax.y, cent.y);
                cmax.z = @max(cmax.z, cent.z);
            }

            const ext = cmax.sub(cmin);
            const axis: u32 = if (ext.x >= ext.y and ext.x >= ext.z) 0 else if (ext.y >= ext.z) 1 else 2;

            const slice = self.tris[start .. start + count];
            const Cmp = struct {
                axis: u32,
                fn less_than(ctx: @This(), a: TriBuild, b: TriBuild) bool {
                    return switch (ctx.axis) {
                        0 => a.centroid.x < b.centroid.x,
                        1 => a.centroid.y < b.centroid.y,
                        else => a.centroid.z < b.centroid.z,
                    };
                }
            };
            std.sort.pdq(TriBuild, slice, Cmp{ .axis = axis }, Cmp.less_than);

            const mid = start + count / 2;
            const left = try self.build(start, mid - start);
            const right = try self.build(mid, start + count - mid);

            self.nodes.items[node_index] = .{
                .aabb = .{ .min = bounds_min, .max = bounds_max },
                .left = left,
                .right = right,
                .first = 0,
                .count = 0,
            };
            return node_index;
        }
    };

    var ctx = BuildCtx{ .tris = tri_build, .offsets = tri_offsets, .nodes = &nodes_list, .allocator = allocator };
    const root = ctx.build(0, tri_count) catch return null;

    for (ctx.tris, 0..) |t, i| ctx.offsets[i] = t.tri_offset;

    const nodes = nodes_list.toOwnedSlice(allocator) catch return null;
    return .{
        .nodes = nodes,
        .tri_offsets = tri_offsets,
        .root = root,
        .vertices_ptr = @intFromPtr(mesh.vertices.?),
        .indices_ptr = @intFromPtr(mesh.indices.?),
        .vertex_count = mesh.vertex_count,
        .index_count = mesh.index_count,
    };
}

fn get_mesh_bvh(mesh_index: u32, mesh: *const scene.CardinalMesh) ?*const MeshPickBvh {
    const allocator = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    if (pick_bvh_cache.getPtr(mesh_index)) |bvh| {
        if (bvh.vertices_ptr == @intFromPtr(mesh.vertices.?) and
            bvh.indices_ptr == @intFromPtr(mesh.indices.?) and
            bvh.vertex_count == mesh.vertex_count and
            bvh.index_count == mesh.index_count)
        {
            return bvh;
        }
        bvh.deinit(allocator);
        _ = pick_bvh_cache.remove(mesh_index);
    }

    const built = build_mesh_bvh(mesh) orelse return null;
    pick_bvh_cache.put(allocator, mesh_index, built) catch {
        var tmp = built;
        tmp.deinit(allocator);
        return null;
    };
    return pick_bvh_cache.getPtr(mesh_index);
}

/// Raycasts against a combined-scene mesh and returns the closest hit point in world space.
///
/// Uses the per-mesh BVH cache for performance. Intended for editor tools that need
/// accurate surface hits (e.g. terrain sculpting from the side).
pub fn raycast_combined_mesh_point(state: *EditorState, mesh_index: u32, ray: math.Ray) ?math.Vec3 {
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return null;
    if (mesh_index >= state.runtime.combined_scene.mesh_count) return null;

    const mesh = &state.runtime.combined_scene.meshes.?[mesh_index];
    if (!mesh.visible) return null;
    if (mesh.vertices == null or mesh.indices == null or mesh.index_count < 3) return null;

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var world_cache: std.AutoHashMapUnmanaged(u64, math.Mat4) = .{};
    defer world_cache.deinit(alloc);

    const min_arr = mesh.bounding_box_min;
    const max_arr = mesh.bounding_box_max;
    const min = math.Vec3{ .x = min_arr[0], .y = min_arr[1], .z = min_arr[2] };
    const max = math.Vec3{ .x = max_arr[0], .y = max_arr[1], .z = max_arr[2] };
    const aabb = math.AABB{ .min = min, .max = max };

    const world_mat = mesh_world_matrix(state, alloc, &world_cache, mesh_index, mesh);
    const world_aabb = aabb.transform(world_mat);
    _ = math.intersectRayAABB(ray, world_aabb, 0.001, 10000.0) orelse return null;

    const inv_world = world_mat.invert() orelse return null;
    const local_origin = inv_world.transformPoint(ray.origin);
    const local_dir = inv_world.transformVector(ray.direction);
    const local_ray = math.Ray{ .origin = local_origin, .direction = local_dir };

    const bvh = get_mesh_bvh(mesh_index, mesh) orelse return null;
    const verts: [*]const scene.CardinalVertex = @ptrCast(mesh.vertices.?);
    const idxs: [*]const u32 = @ptrCast(mesh.indices.?);

    var closest_t: f32 = std.math.floatMax(f32);
    var closest_world: ?math.Vec3 = null;

    var stack: [128]u32 = undefined;
    var sp: usize = 0;
    stack[sp] = bvh.root;
    sp += 1;

    while (sp > 0) {
        sp -= 1;
        const node_index = stack[sp];
        const node = bvh.nodes[node_index];

        const t_local = math.intersectRayAABB(local_ray, node.aabb, 0.0, std.math.floatMax(f32)) orelse continue;
        const local_p = local_ray.origin.add(local_ray.direction.mul(t_local));
        const world_p = world_mat.transformPoint(local_p);
        const t_world = world_p.sub(ray.origin).dot(ray.direction);
        if (t_world <= 0.0 or t_world >= closest_t) continue;

        if (node.count == 0) {
            if (sp + 2 <= stack.len) {
                stack[sp] = node.left;
                stack[sp + 1] = node.right;
                sp += 2;
            }
            continue;
        }

        var j: u32 = 0;
        while (j < node.count) : (j += 1) {
            const tri_off = bvh.tri_offsets[node.first + j];
            if (tri_off + 2 >= mesh.index_count) continue;

            const idx0 = idxs[tri_off + 0];
            const idx1 = idxs[tri_off + 1];
            const idx2 = idxs[tri_off + 2];
            if (idx0 >= mesh.vertex_count or idx1 >= mesh.vertex_count or idx2 >= mesh.vertex_count) continue;
            if (idx0 == idx1 or idx1 == idx2 or idx0 == idx2) continue;

            const p0 = math.Vec3{ .x = verts[idx0].px, .y = verts[idx0].py, .z = verts[idx0].pz };
            const p1 = math.Vec3{ .x = verts[idx1].px, .y = verts[idx1].py, .z = verts[idx1].pz };
            const p2 = math.Vec3{ .x = verts[idx2].px, .y = verts[idx2].py, .z = verts[idx2].pz };

            if (intersect_ray_triangle(local_ray, p0, p1, p2, 0.0, std.math.floatMax(f32))) |hit| {
                const local_hit = local_ray.origin.add(local_ray.direction.mul(hit.t));
                const world_hit = world_mat.transformPoint(local_hit);
                const hit_t_world = world_hit.sub(ray.origin).dot(ray.direction);
                if (hit_t_world <= 0.0 or hit_t_world >= closest_t) continue;

                closest_t = hit_t_world;
                closest_world = world_hit;
            }
        }
    }

    return closest_world;
}

pub fn raycast_combined_mesh_point_allow_invisible(state: *EditorState, mesh_index: u32, ray: math.Ray) ?math.Vec3 {
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return null;
    if (mesh_index >= state.runtime.combined_scene.mesh_count) return null;

    const mesh = &state.runtime.combined_scene.meshes.?[mesh_index];
    if (mesh.vertices == null or mesh.indices == null or mesh.index_count < 3) return null;

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var world_cache: std.AutoHashMapUnmanaged(u64, math.Mat4) = .{};
    defer world_cache.deinit(alloc);

    const min_arr = mesh.bounding_box_min;
    const max_arr = mesh.bounding_box_max;
    const min = math.Vec3{ .x = min_arr[0], .y = min_arr[1], .z = min_arr[2] };
    const max = math.Vec3{ .x = max_arr[0], .y = max_arr[1], .z = max_arr[2] };
    const aabb = math.AABB{ .min = min, .max = max };

    const world_mat = mesh_world_matrix(state, alloc, &world_cache, mesh_index, mesh);
    const world_aabb = aabb.transform(world_mat);
    _ = math.intersectRayAABB(ray, world_aabb, 0.001, 10000.0) orelse return null;

    const inv_world = world_mat.invert() orelse return null;
    const local_origin = inv_world.transformPoint(ray.origin);
    const local_dir = inv_world.transformVector(ray.direction);
    const local_ray = math.Ray{ .origin = local_origin, .direction = local_dir };

    const bvh = get_mesh_bvh(mesh_index, mesh) orelse return null;
    const verts: [*]const scene.CardinalVertex = @ptrCast(mesh.vertices.?);
    const idxs: [*]const u32 = @ptrCast(mesh.indices.?);

    var closest_t: f32 = std.math.floatMax(f32);
    var closest_world: ?math.Vec3 = null;

    var stack: [128]u32 = undefined;
    var sp: usize = 0;
    stack[sp] = bvh.root;
    sp += 1;

    while (sp > 0) {
        sp -= 1;
        const node_index = stack[sp];
        const node = bvh.nodes[node_index];

        const t_local = math.intersectRayAABB(local_ray, node.aabb, 0.0, std.math.floatMax(f32)) orelse continue;
        const local_p = local_ray.origin.add(local_ray.direction.mul(t_local));
        const world_p = world_mat.transformPoint(local_p);
        const t_world = world_p.sub(ray.origin).dot(ray.direction);
        if (t_world <= 0.0 or t_world >= closest_t) continue;

        if (node.count == 0) {
            if (sp + 2 <= stack.len) {
                stack[sp] = node.left;
                stack[sp + 1] = node.right;
                sp += 2;
            }
            continue;
        }

        var j: u32 = 0;
        while (j < node.count) : (j += 1) {
            const tri_off = bvh.tri_offsets[node.first + j];
            if (tri_off + 2 >= mesh.index_count) continue;

            const idx0 = idxs[tri_off + 0];
            const idx1 = idxs[tri_off + 1];
            const idx2 = idxs[tri_off + 2];
            if (idx0 >= mesh.vertex_count or idx1 >= mesh.vertex_count or idx2 >= mesh.vertex_count) continue;
            if (idx0 == idx1 or idx1 == idx2 or idx0 == idx2) continue;

            const p0 = math.Vec3{ .x = verts[idx0].px, .y = verts[idx0].py, .z = verts[idx0].pz };
            const p1 = math.Vec3{ .x = verts[idx1].px, .y = verts[idx1].py, .z = verts[idx1].pz };
            const p2 = math.Vec3{ .x = verts[idx2].px, .y = verts[idx2].py, .z = verts[idx2].pz };

            if (intersect_ray_triangle(local_ray, p0, p1, p2, 0.0, std.math.floatMax(f32))) |hit| {
                const local_hit = local_ray.origin.add(local_ray.direction.mul(hit.t));
                const world_hit = world_mat.transformPoint(local_hit);
                const hit_t_world = world_hit.sub(ray.origin).dot(ray.direction);
                if (hit_t_world <= 0.0 or hit_t_world >= closest_t) continue;

                closest_t = hit_t_world;
                closest_world = world_hit;
            }
        }
    }

    return closest_world;
}

fn pick_combined_mesh(state: *EditorState, ray: math.Ray) ?u32 {
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return null;
    const meshes = state.runtime.combined_scene.meshes.?;

    var closest_t_alpha: f32 = std.math.floatMax(f32);
    var hit_mesh_alpha: ?u32 = null;
    var closest_t_any: f32 = std.math.floatMax(f32);
    var hit_mesh_any: ?u32 = null;

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var world_cache: std.AutoHashMapUnmanaged(u64, math.Mat4) = .{};
    defer world_cache.deinit(alloc);

    const t_min: f32 = 0.001;
    const t_max: f32 = 10000.0;

    var i: u32 = 0;
    while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
        const mesh = &meshes[i];
        if (!mesh.visible) continue;
        if (mesh.vertices == null or mesh.indices == null or mesh.index_count < 3) continue;

        const min_arr = mesh.bounding_box_min;
        const max_arr = mesh.bounding_box_max;
        const min = math.Vec3{ .x = min_arr[0], .y = min_arr[1], .z = min_arr[2] };
        const max = math.Vec3{ .x = max_arr[0], .y = max_arr[1], .z = max_arr[2] };

        const aabb = math.AABB{ .min = min, .max = max };
        const world_mat = mesh_world_matrix(state, alloc, &world_cache, i, mesh);
        const world_aabb = aabb.transform(world_mat);

        const aabb_t = math.intersectRayAABB(ray, world_aabb, t_min, t_max) orelse continue;
        if (aabb_t >= closest_t_any) continue;

        const inv_world = world_mat.invert() orelse continue;
        const local_origin = inv_world.transformPoint(ray.origin);
        const local_dir = inv_world.transformVector(ray.direction);
        const local_ray = math.Ray{ .origin = local_origin, .direction = local_dir };

        const bvh = get_mesh_bvh(i, mesh) orelse continue;

        const verts: [*]const scene.CardinalVertex = @ptrCast(mesh.vertices.?);
        const idxs: [*]const u32 = @ptrCast(mesh.indices.?);

        var stack: [128]u32 = undefined;
        var sp: usize = 0;
        stack[sp] = bvh.root;
        sp += 1;

        while (sp > 0) {
            sp -= 1;
            const node_index = stack[sp];
            const node = bvh.nodes[node_index];

            const t_local = math.intersectRayAABB(local_ray, node.aabb, 0.0, std.math.floatMax(f32)) orelse continue;
            const local_p = local_ray.origin.add(local_ray.direction.mul(t_local));
            const world_p = world_mat.transformPoint(local_p);
            const t_world = world_p.sub(ray.origin).dot(ray.direction);
            if (t_world <= 0.0 or t_world >= closest_t_any) continue;

            if (node.count == 0) {
                if (sp + 2 <= stack.len) {
                    stack[sp] = node.left;
                    stack[sp + 1] = node.right;
                    sp += 2;
                }
                continue;
            }

            var j: u32 = 0;
            while (j < node.count) : (j += 1) {
                const tri_off = bvh.tri_offsets[node.first + j];
                if (tri_off + 2 >= mesh.index_count) continue;

                const idx0 = idxs[tri_off + 0];
                const idx1 = idxs[tri_off + 1];
                const idx2 = idxs[tri_off + 2];
                if (idx0 >= mesh.vertex_count or idx1 >= mesh.vertex_count or idx2 >= mesh.vertex_count) continue;

                const p0 = math.Vec3{ .x = verts[idx0].px, .y = verts[idx0].py, .z = verts[idx0].pz };
                const p1 = math.Vec3{ .x = verts[idx1].px, .y = verts[idx1].py, .z = verts[idx1].pz };
                const p2 = math.Vec3{ .x = verts[idx2].px, .y = verts[idx2].py, .z = verts[idx2].pz };

                if (intersect_ray_triangle(local_ray, p0, p1, p2, 0.0, std.math.floatMax(f32))) |hit| {
                    const local_hit = local_ray.origin.add(local_ray.direction.mul(hit.t));
                    const world_hit = world_mat.transformPoint(local_hit);
                    const hit_t_world = world_hit.sub(ray.origin).dot(ray.direction);
                    if (hit_t_world <= 0.0 or hit_t_world >= closest_t_any) continue;

                    closest_t_any = hit_t_world;
                    hit_mesh_any = i;

                    if (hit_passes_alpha_test(&state.runtime.combined_scene, mesh, verts, idx0, idx1, idx2, hit.u, hit.v)) {
                        if (hit_t_world < closest_t_alpha) {
                            closest_t_alpha = hit_t_world;
                            hit_mesh_alpha = i;
                        }
                    }
                }
            }
        }
    }

    return hit_mesh_alpha orelse hit_mesh_any;
}

const TriHit = struct {
    t: f32,
    u: f32,
    v: f32,
};

fn intersect_ray_triangle(ray: math.Ray, v0: math.Vec3, v1: math.Vec3, v2: math.Vec3, t_min: f32, t_max: f32) ?TriHit {
    const eps: f32 = 0.000001;

    const edge1 = v1.sub(v0);
    const edge2 = v2.sub(v0);

    const h = ray.direction.cross(edge2);
    const a = edge1.dot(h);
    if (@abs(a) < eps) return null;

    const f = 1.0 / a;
    const s = ray.origin.sub(v0);
    const u = f * s.dot(h);
    if (u < 0.0 or u > 1.0) return null;

    const q = s.cross(edge1);
    const v = f * ray.direction.dot(q);
    if (v < 0.0 or (u + v) > 1.0) return null;

    const t = f * edge2.dot(q);
    if (t < t_min or t > t_max) return null;
    return .{ .t = t, .u = u, .v = v };
}

fn hit_passes_alpha_test(scn: *const scene.CardinalScene, mesh: *const scene.CardinalMesh, verts: [*]const scene.CardinalVertex, idx0: u32, idx1: u32, idx2: u32, bc_u: f32, bc_v: f32) bool {
    if (scn.materials == null or mesh.material_index >= scn.material_count) return true;
    const mat = &scn.materials.?[mesh.material_index];
    if (mat.alpha_mode == scene.CardinalAlphaMode.OPAQUE) return true;

    const w0 = 1.0 - bc_u - bc_v;
    const w1 = bc_u;
    const w2 = bc_v;

    const uv_set: u8 = mat.uv_indices[0];
    const uv0 = if (uv_set == 1) math.Vec2{ .x = verts[idx0].u1, .y = verts[idx0].v1 } else math.Vec2{ .x = verts[idx0].u, .y = verts[idx0].v };
    const uv1 = if (uv_set == 1) math.Vec2{ .x = verts[idx1].u1, .y = verts[idx1].v1 } else math.Vec2{ .x = verts[idx1].u, .y = verts[idx1].v };
    const uv2 = if (uv_set == 1) math.Vec2{ .x = verts[idx2].u1, .y = verts[idx2].v1 } else math.Vec2{ .x = verts[idx2].u, .y = verts[idx2].v };

    var uv = uv0.scale(w0).add(uv1.scale(w1)).add(uv2.scale(w2));
    uv = apply_uv_transform(uv, mat.albedo_transform);

    const alpha = sample_albedo_alpha(scn, mat, uv);

    return switch (mat.alpha_mode) {
        .MASK => alpha >= mat.alpha_cutoff,
        .BLEND => alpha >= 0.05,
        else => true,
    };
}

fn apply_uv_transform(uv: math.Vec2, tr: scene.CardinalTextureTransform) math.Vec2 {
    var out = uv;
    out.x *= tr.scale[0];
    out.y *= tr.scale[1];

    if (tr.rotation != 0.0) {
        const c_r = std.math.cos(tr.rotation);
        const s_r = std.math.sin(tr.rotation);
        const x = out.x * c_r - out.y * s_r;
        const y = out.x * s_r + out.y * c_r;
        out.x = x;
        out.y = y;
    }

    out.x += tr.offset[0];
    out.y += tr.offset[1];
    return out;
}

fn wrap_uv(u: f32, mode: c_int) f32 {
    return switch (mode) {
        0 => u - std.math.floor(u),
        1 => blk: {
            const f = u - std.math.floor(u);
            const whole = @as(i32, @intFromFloat(std.math.floor(u)));
            break :blk if ((whole & 1) == 0) f else (1.0 - f);
        },
        2 => std.math.clamp(u, 0.0, 1.0),
        else => std.math.clamp(u, 0.0, 1.0),
    };
}

fn sample_albedo_alpha(scn: *const scene.CardinalScene, mat: *const scene.CardinalMaterial, uv_in: math.Vec2) f32 {
    var alpha: f32 = mat.albedo_factor[3];

    if (!mat.albedo_texture.is_valid()) return alpha;
    if (scn.textures == null or mat.albedo_texture.index >= scn.texture_count) return alpha;

    const tex = &scn.textures.?[mat.albedo_texture.index];
    if (tex.data == null or tex.width == 0 or tex.height == 0) return alpha;
    if (tex.is_hdr != 0) return alpha;

    const channels = if (tex.channels == 0) 4 else tex.channels;
    if (channels < 4) return alpha;

    const u = wrap_uv(uv_in.x, tex.sampler.wrap_s);
    const v = wrap_uv(uv_in.y, tex.sampler.wrap_t);

    const x = @min(@as(u32, @intFromFloat(u * @as(f32, @floatFromInt(tex.width)))), tex.width - 1);
    const y = @min(@as(u32, @intFromFloat(v * @as(f32, @floatFromInt(tex.height)))), tex.height - 1);

    const idx: u64 = (@as(u64, y) * tex.width + x) * channels + 3;
    if (idx >= tex.data_size and tex.data_size != 0) return alpha;

    const a8: u8 = tex.data.?[idx];
    alpha *= @as(f32, @floatFromInt(a8)) / 255.0;
    return alpha;
}

fn mesh_index_to_entity(state: *EditorState, mesh_index: u32, owner: bool) ?engine.ecs_entity.Entity {
    const id_opt = if (owner) state.runtime.mesh_owner_by_mesh_index.get(mesh_index) else state.runtime.mesh_entity_by_mesh_index.get(mesh_index);
    if (id_opt) |id| {
        const ent = engine.ecs_entity.Entity{ .id = id };
        if (state.runtime.registry.entity_manager.is_alive(ent)) return ent;
    }
    return null;
}

/// Picks the closest mesh under the cursor and updates UI selection.
pub fn pick_under_mouse(state: *EditorState) void {
    if (get_ray_from_mouse(state)) |ray| {
        if (pick_combined_mesh(state, ray)) |mesh_index| {
            const pick_single_mesh = c.imgui_bridge_is_alt_down();
            const ent = if (pick_single_mesh)
                mesh_index_to_entity(state, mesh_index, false)
            else
                mesh_index_to_entity(state, mesh_index, true) orelse mesh_index_to_entity(state, mesh_index, false);

            if (ent) |e| {
                const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
                state.ui.selected_entity = e;
                state.ui.selected_model_id = 0;
                state.ui.scene_graph_focus_target_id = e.id;
                state.ui.scene_graph_focus_pending = true;
                if (!c.imgui_bridge_is_ctrl_down()) {
                    state.ui.selected_entities.clearRetainingCapacity();
                }
                if (c.imgui_bridge_is_ctrl_down() and state.ui.selected_entities.contains(e.id)) {
                    _ = state.ui.selected_entities.remove(e.id);
                    if (state.ui.selected_entities.count() == 0) {
                        state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
                    }
                } else {
                    state.ui.selected_entities.put(alloc, e.id, {}) catch {};
                }
            } else {
                state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
                state.ui.selected_entities.clearRetainingCapacity();
            }
        } else {
            state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
            state.ui.selected_entities.clearRetainingCapacity();
        }
    }
}
