//! Editor selection and gizmo interaction.
//!
//! Implements raycast selection against loaded models and basic translate/scale/rotate gizmos.
//!
//! TODO: Split selection (raycast) and gizmo manipulation into separate modules.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const renderer = engine.vulkan_renderer;
const scene = engine.scene;
const components = engine.ecs_components;
const EditorState = @import("../editor_state.zig").EditorState;
const c = @import("../c.zig").c;

pub const GizmoMode = enum {
    Translate,
    Scale,
    Rotate,
};

pub const SelectionState = struct {
    gizmo_mode: GizmoMode = .Translate,
    is_dragging: bool = false,
    /// 0 = X, 1 = Y, 2 = Z.
    drag_axis: ?u32 = null,
    drag_start_mouse: math.Vec2 = math.Vec2.zero(),
    drag_start_val: math.Vec3 = math.Vec3.zero(),
    drag_start_rot: math.Quat = math.Quat.identity(),
    /// Initial position when drag started.
    drag_start_pos: math.Vec3 = math.Vec3.zero(),
    hover_axis: ?u32 = null,
    hover_is_rotation: bool = false,
    drag_is_rotation: bool = false,
    drag_plane_normal: math.Vec3 = math.Vec3.zero(),
    drag_start_t: f32 = 0.0,
};

var selection_state = SelectionState{};

fn collect_subtree_entities(state: *EditorState, root: engine.ecs_entity.Entity, out: *std.AutoHashMapUnmanaged(u64, void)) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    var stack: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
    defer stack.deinit(alloc);

    stack.append(alloc, root) catch return;

    while (stack.items.len > 0) {
        const last = stack.items.len - 1;
        const e = stack.items[last];
        stack.items.len = last;

        out.put(alloc, e.id, {}) catch {};

        const h = state.runtime.registry.get(components.Hierarchy, e) orelse continue;
        var child = h.first_child;
        var guard: u32 = 0;
        while (child) |c_ent| {
            if (guard > 100000) break;
            guard += 1;

            stack.append(alloc, c_ent) catch return;

            const ch = state.runtime.registry.get(components.Hierarchy, c_ent) orelse break;
            child = ch.next_sibling;
        }
    }
}

fn compute_selection_world_aabb(state: *EditorState, root: engine.ecs_entity.Entity) ?math.AABB {
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return null;

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var subtree: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer subtree.deinit(alloc);
    collect_subtree_entities(state, root, &subtree);

    var found_any = false;
    var out = math.AABB{ .min = math.Vec3.zero(), .max = math.Vec3.zero() };

    const meshes = state.runtime.combined_scene.meshes.?;
    var i: u32 = 0;
    while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
        const owner = state.runtime.mesh_owner_by_mesh_index.get(i);
        const ent = state.runtime.mesh_entity_by_mesh_index.get(i);
        const in_subtree = (owner != null and subtree.contains(owner.?)) or (ent != null and subtree.contains(ent.?));
        if (!in_subtree) continue;

        const mesh = &meshes[i];
        const min_arr = mesh.bounding_box_min;
        const max_arr = mesh.bounding_box_max;
        const min = math.Vec3{ .x = min_arr[0], .y = min_arr[1], .z = min_arr[2] };
        const max = math.Vec3{ .x = max_arr[0], .y = max_arr[1], .z = max_arr[2] };

        const aabb = math.AABB{ .min = min, .max = max };
        const world_mat = math.Mat4.fromArray(mesh.transform);
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

    return if (found_any) out else null;
}

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

fn draw_selection_xray(state: *EditorState, root: engine.ecs_entity.Entity) void {
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return;

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var subtree: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer subtree.deinit(alloc);
    collect_subtree_entities(state, root, &subtree);

    const view = math.Mat4.lookAt(state.runtime.camera.position, state.runtime.camera.target, state.runtime.camera.up);
    const proj = math.Mat4.perspective(math.toRadians(state.runtime.camera.fov), state.runtime.camera.aspect, state.runtime.camera.near_plane, state.runtime.camera.far_plane);
    const view_proj = proj.mul(view);

    const meshes = state.runtime.combined_scene.meshes.?;
    var i: u32 = 0;
    while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
        const owner_id = state.runtime.mesh_owner_by_mesh_index.get(i);
        const ent_id = state.runtime.mesh_entity_by_mesh_index.get(i);
        const in_subtree = (owner_id != null and subtree.contains(owner_id.?)) or (ent_id != null and subtree.contains(ent_id.?));
        if (!in_subtree) continue;

        const mesh = &meshes[i];
        const min_arr = mesh.bounding_box_min;
        const max_arr = mesh.bounding_box_max;
        const min = math.Vec3{ .x = min_arr[0], .y = min_arr[1], .z = min_arr[2] };
        const max = math.Vec3{ .x = max_arr[0], .y = max_arr[1], .z = max_arr[2] };

        const aabb = math.AABB{ .min = min, .max = max };
        const world_mat = math.Mat4.fromArray(mesh.transform);
        const world_aabb = aabb.transform(world_mat);

        const is_root = (ent_id != null and ent_id.? == root.id) or (owner_id != null and owner_id.? == root.id);
        draw_aabb_xray(state, view_proj, world_aabb, if (is_root) 0x8000FFFF else 0x4000FFFF, if (is_root) 2.0 else 1.0);
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
fn get_ray_from_mouse(state: *EditorState) ?math.Ray {
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

fn check_node_intersection(
    node: *scene.CardinalSceneNode,
    model: *engine.model_manager.CardinalModelInstance,
    ray: math.Ray,
    closest_t: *f32,
    hit_model_id: *u32,
) void {
    if (node.mesh_count > 0 and node.mesh_indices != null) {
        const scn = &model.scene;
        const model_mat = math.Mat4.fromArray(model.transform);
        const node_local_mat = math.Mat4.fromArray(node.world_transform);
        const node_transform = model_mat.mul(node_local_mat);

        var i: u32 = 0;
        while (i < node.mesh_count) : (i += 1) {
            const mesh_idx = node.mesh_indices.?[i];
            if (scn.meshes) |meshes| {
                if (mesh_idx < scn.mesh_count) {
                    const mesh = &meshes[mesh_idx];

                    const min_arr = mesh.bounding_box_min;
                    const max_arr = mesh.bounding_box_max;
                    const min = math.Vec3{ .x = min_arr[0], .y = min_arr[1], .z = min_arr[2] };
                    const max = math.Vec3{ .x = max_arr[0], .y = max_arr[1], .z = max_arr[2] };

                    const aabb = math.AABB{ .min = min, .max = max };
                    const world_aabb = aabb.transform(node_transform);

                    if (math.intersectRayAABB(ray, world_aabb, 0.1, 1000.0)) |t| {
                        if (t < closest_t.*) {
                            closest_t.* = t;
                            hit_model_id.* = model.id;
                        }
                    }
                }
            }
        }
    }

    if (node.child_count > 0 and node.children != null) {
        var i: u32 = 0;
        while (i < node.child_count) : (i += 1) {
            if (node.children.?[i]) |child| {
                check_node_intersection(child, model, ray, closest_t, hit_model_id);
            }
        }
    }
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

        fn centroid_less_than(_: void, a: TriBuild, b: TriBuild) bool {
            return a.centroid.x < b.centroid.x;
        }

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

/// Returns the mesh index hit by `ray` in the combined scene.
///
/// Uses a coarse AABB test, then triangle intersection. For alpha-masked/blended materials, a hit
/// must also pass a cheap albedo-alpha test; otherwise the closest non-alpha-tested hit is used.
fn pick_combined_mesh(state: *EditorState, ray: math.Ray) ?u32 {
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return null;
    const meshes = state.runtime.combined_scene.meshes.?;

    var closest_t_alpha: f32 = std.math.floatMax(f32);
    var hit_mesh_alpha: ?u32 = null;
    var closest_t_any: f32 = std.math.floatMax(f32);
    var hit_mesh_any: ?u32 = null;

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
        const world_mat = math.Mat4.fromArray(mesh.transform);
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

/// Ray/triangle intersection result with barycentric coordinates.
const TriHit = struct {
    t: f32,
    u: f32,
    v: f32,
};

/// Möller–Trumbore intersection with barycentric output.
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

/// Returns whether the hit point on a triangle should be considered "solid" for selection.
///
/// For alpha-masked materials this approximates the fragment discard by sampling albedo alpha.
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

/// Applies a glTF-style UV transform.
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

/// Wraps `u` for a sampler mode.
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

/// Samples alpha from the albedo texture if possible, multiplying by `albedo_factor.a`.
///
/// Falls back to the factor alpha when the texture data is unavailable (e.g. HDR or missing CPU data).
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

fn find_entity_for_mesh_index(state: *EditorState, mesh_index: u32) ?engine.ecs_entity.Entity {
    var view = state.runtime.registry.view(components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        if (entry.component.mesh.index == mesh_index) return entry.entity;
    }
    return null;
}

fn find_node_name_for_mesh_index(state: *EditorState, mesh_index: u32) ?[]const u8 {
    if (state.runtime.combined_scene.all_nodes == null or state.runtime.combined_scene.all_node_count == 0) return null;

    var i: u32 = 0;
    while (i < state.runtime.combined_scene.all_node_count) : (i += 1) {
        const node_opt = state.runtime.combined_scene.all_nodes.?[i];
        if (node_opt == null) continue;
        const node = node_opt.?;
        if (node.name == null or node.mesh_indices == null or node.mesh_count == 0) continue;

        var m: u32 = 0;
        while (m < node.mesh_count) : (m += 1) {
            if (node.mesh_indices.?[m] == mesh_index) {
                return std.mem.span(node.name.?);
            }
        }
    }

    return null;
}

fn mesh_index_to_entity(state: *EditorState, mesh_index: u32, owner: bool) ?engine.ecs_entity.Entity {
    const id_opt = if (owner) state.runtime.mesh_owner_by_mesh_index.get(mesh_index) else state.runtime.mesh_entity_by_mesh_index.get(mesh_index);
    if (id_opt) |id| {
        const ent = engine.ecs_entity.Entity{ .id = id };
        if (state.runtime.registry.entity_manager.is_alive(ent)) return ent;
    }
    return null;
}

/// Ensures an ECS entity exists for a combined scene mesh index so it can be selected and edited.
fn ensure_entity_for_mesh_index(state: *EditorState, mesh_index: u32) ?engine.ecs_entity.Entity {
    if (find_entity_for_mesh_index(state, mesh_index)) |ent| return ent;
    if (state.runtime.combined_scene.meshes == null or mesh_index >= state.runtime.combined_scene.mesh_count) return null;

    const mesh = &state.runtime.combined_scene.meshes.?[mesh_index];
    const map_alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    const entity = state.runtime.registry.create() catch return null;

    var name_buf: [64]u8 = undefined;
    const name = find_node_name_for_mesh_index(state, mesh_index) orelse (std.fmt.bufPrint(&name_buf, "Mesh{d}", .{mesh_index}) catch "Mesh");
    state.runtime.registry.add(entity, components.Name.init(name)) catch {};

    state.runtime.registry.add(entity, components.Node{ .type = .MeshInstance3D }) catch {};

    var transform = components.Transform{};
    const m = math.Mat4.fromArray(mesh.transform);
    const decomposed = m.decompose();
    transform.position = decomposed.t;
    transform.rotation = decomposed.r;
    transform.scale = decomposed.s;
    state.runtime.registry.add(entity, transform) catch {};

    state.runtime.registry.add(entity, components.Hierarchy{}) catch {};

    const mr = components.MeshRenderer{
        .mesh = .{ .index = mesh_index, .generation = 0 },
        .material = .{ .index = mesh.material_index, .generation = 0 },
        .visible = mesh.visible,
        .cast_shadows = true,
        .receive_shadows = true,
    };
    state.runtime.registry.add(entity, mr) catch {};

    state.runtime.mesh_owner_by_mesh_index.put(map_alloc, mesh_index, entity.id) catch {};
    state.runtime.mesh_entity_by_mesh_index.put(map_alloc, mesh_index, entity.id) catch {};

    return entity;
}

/// Updates selection and active gizmo state based on input.
pub fn update(state: *EditorState) void {
    const ctrl_down = c.imgui_bridge_is_ctrl_down();
    const shift_down = c.imgui_bridge_is_shift_down();

    if (!selection_state.is_dragging) {
        if (ctrl_down) {
            selection_state.gizmo_mode = .Rotate;
        } else if (shift_down) {
            selection_state.gizmo_mode = .Scale;
        } else {
            selection_state.gizmo_mode = .Translate;
        }
    }

    if (state.runtime.mouse_captured) {
        selection_state.is_dragging = false;
        selection_state.drag_axis = null;
        selection_state.drag_is_rotation = false;
        selection_state.hover_axis = null;
        selection_state.hover_is_rotation = false;
    }

    const want_capture = c.imgui_bridge_want_capture_mouse();
    if (!state.runtime.mouse_captured and c.imgui_bridge_is_mouse_clicked(0) and !want_capture and !selection_state.is_dragging and selection_state.hover_axis == null) {
        if (get_ray_from_mouse(state)) |ray| {
            if (pick_combined_mesh(state, ray)) |mesh_index| {
                const pick_single_mesh = c.imgui_bridge_is_alt_down();
                const ent = if (pick_single_mesh)
                    mesh_index_to_entity(state, mesh_index, false)
                else
                    mesh_index_to_entity(state, mesh_index, true) orelse mesh_index_to_entity(state, mesh_index, false);

                if (ent) |e| {
                    state.ui.selected_entity = e;
                    state.ui.selected_model_id = 0;
                    state.ui.scene_graph_focus_target_id = e.id;
                    state.ui.scene_graph_focus_pending = true;
                } else {
                    state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
                }
            } else {
                state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
            }
        }
    }

    if (state.ui.selected_entity.id != std.math.maxInt(u64)) {
        draw_selection_xray(state, state.ui.selected_entity);
        if (state.runtime.registry.get(components.Transform, state.ui.selected_entity)) |t| {
            draw_entity_gizmo(state, t);
            return;
        }
    }

    state.ui.selected_model_id = 0;
}

fn draw_entity_gizmo(state: *EditorState, t: *components.Transform) void {
    const pos = t.position;
    const rot = t.rotation.normalize();
    const scale_vec = t.scale;

    const view = math.Mat4.lookAt(state.runtime.camera.position, state.runtime.camera.target, state.runtime.camera.up);
    const proj = math.Mat4.perspective(math.toRadians(state.runtime.camera.fov), state.runtime.camera.aspect, state.runtime.camera.near_plane, state.runtime.camera.far_plane);
    const view_proj = proj.mul(view);

    const screen_pos_v4 = view_proj.mulVec4(math.Vec4{ .x = pos.x, .y = pos.y, .z = pos.z, .w = 1.0 });
    if (screen_pos_v4.w <= 0) return;

    const ndc = math.Vec3{ .x = screen_pos_v4.x / screen_pos_v4.w, .y = screen_pos_v4.y / screen_pos_v4.w, .z = screen_pos_v4.z / screen_pos_v4.w };

    const win_width = state.runtime.window.width;
    const win_height = state.runtime.window.height;

    const screen_x = (ndc.x + 1.0) * 0.5 * @as(f32, @floatFromInt(win_width));
    const screen_y = (ndc.y + 1.0) * 0.5 * @as(f32, @floatFromInt(win_height));
    const center = c.ImVec2{ .x = screen_x, .y = screen_y };

    const axis_thickness = 3.0;
    const handle_size = 6.0;

    const axes = [_]math.Vec3{
        .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 1, .z = 0 },
        .{ .x = 0, .y = 0, .z = 1 },
    };

    const axis_colors = [_]u32{
        0xFF0000FF,
        0xFF00FF00,
        0xFFFF0000,
    };

    var mouse_pos_im: c.ImVec2 = undefined;
    c.imgui_bridge_get_mouse_pos(&mouse_pos_im);
    const mouse_pos = mouse_pos_im;

    var hovered: ?u32 = null;
    var hovered_rot: bool = false;
    const can_interact = !state.runtime.mouse_captured and !c.imgui_bridge_want_capture_mouse();

    const dist = state.runtime.camera.position.sub(pos).length();
    const scale_factor = dist * 0.15;

    if (selection_state.gizmo_mode == .Rotate) {
        inline for (0..3) |i| {
            var is_hovered = false;
            if (!selection_state.is_dragging and can_interact) {
                if (get_ray_from_mouse(state)) |ray| {
                    const denom = axes[i].dot(ray.direction);
                    if (@abs(denom) > 0.0001) {
                        const t_hit = axes[i].dot(pos.sub(ray.origin)) / denom;
                        if (t_hit > 0) {
                            const hit_point = ray.origin.add(ray.direction.mul(t_hit));
                            const dist_to_center = hit_point.sub(pos).length();
                            const ring_radius = scale_factor * 1.2;
                            const ring_thickness = scale_factor * 0.1;
                            if (@abs(dist_to_center - ring_radius) < ring_thickness) {
                                is_hovered = true;
                                hovered = @as(u32, @intCast(i));
                                hovered_rot = true;
                            }
                        }
                    }
                }
            }
            if (selection_state.drag_axis == @as(u32, @intCast(i)) and selection_state.drag_is_rotation) is_hovered = true;
            const color = if (is_hovered) 0xFFFFFFFF else axis_colors[i];

            var u = math.Vec3{ .x = 0, .y = 1, .z = 0 };
            if (@abs(axes[i].dot(u)) > 0.9) u = math.Vec3{ .x = 0, .y = 0, .z = 1 };
            const v = axes[i].cross(u).normalize();
            u = v.cross(axes[i]).normalize();

            const ring_radius = scale_factor * 1.2;
            const segments = 64;
            var prev_p: c.ImVec2 = undefined;

            for (0..segments + 1) |s| {
                const angle = (@as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments))) * std.math.pi * 2.0;
                const p_local = u.mul(std.math.cos(angle) * ring_radius).add(v.mul(std.math.sin(angle) * ring_radius));
                const p_world = pos.add(p_local);

                const p_v4 = view_proj.mulVec4(math.Vec4{ .x = p_world.x, .y = p_world.y, .z = p_world.z, .w = 1.0 });
                if (p_v4.w <= 0) continue;

                const p_ndc = math.Vec3{ .x = p_v4.x / p_v4.w, .y = p_v4.y / p_v4.w, .z = p_v4.z / p_v4.w };
                const px = (p_ndc.x + 1.0) * 0.5 * @as(f32, @floatFromInt(win_width));
                const py = (p_ndc.y + 1.0) * 0.5 * @as(f32, @floatFromInt(win_height));
                const current_p = c.ImVec2{ .x = px, .y = py };

                if (s > 0) c.imgui_bridge_draw_line(&prev_p, &current_p, color, axis_thickness);
                prev_p = current_p;
            }
        }
    }

    if (selection_state.gizmo_mode != .Rotate) {
        const tip_hit_dist_sq: f32 = if (selection_state.gizmo_mode == .Scale) 625.0 else 100.0;
        inline for (0..3) |i| {
            const end_pos_world = pos.add(axes[i].mul(scale_factor));
            const end_pos_v4 = view_proj.mulVec4(math.Vec4{ .x = end_pos_world.x, .y = end_pos_world.y, .z = end_pos_world.z, .w = 1.0 });

            const end_ndc = math.Vec3{ .x = end_pos_v4.x / end_pos_v4.w, .y = end_pos_v4.y / end_pos_v4.w, .z = end_pos_v4.z / end_pos_v4.w };
            const end_screen_x = (end_ndc.x + 1.0) * 0.5 * @as(f32, @floatFromInt(win_width));
            const end_screen_y = (end_ndc.y + 1.0) * 0.5 * @as(f32, @floatFromInt(win_height));

            const p1 = center;
            const p2 = c.ImVec2{ .x = end_screen_x, .y = end_screen_y };

            if (!selection_state.is_dragging and can_interact and hovered == null) {
                const dx = mouse_pos.x - end_screen_x;
                const dy = mouse_pos.y - end_screen_y;
                if (dx * dx + dy * dy < tip_hit_dist_sq) {
                    hovered = @as(u32, @intCast(i));
                    hovered_rot = false;
                }
            }

            var color = axis_colors[i];
            if ((hovered == @as(u32, @intCast(i)) and !hovered_rot) or (selection_state.drag_axis == @as(u32, @intCast(i)) and !selection_state.drag_is_rotation)) {
                color = 0xFFFFFFFF;
            }

            c.imgui_bridge_draw_line(&p1, &p2, color, axis_thickness);

            if (selection_state.gizmo_mode == .Scale) {
                const pyramid_len = scale_factor * 0.2;
                const base_width = pyramid_len * 0.5;

                const tip = end_pos_world;
                const base_center = tip.sub(axes[i].mul(pyramid_len));

                var u = math.Vec3{ .x = 0, .y = 1, .z = 0 };
                if (@abs(axes[i].dot(u)) > 0.9) u = math.Vec3{ .x = 0, .y = 0, .z = 1 };
                const right = axes[i].cross(u).normalize();
                const up_vec = right.cross(axes[i]).normalize();

                const c1 = base_center.add(right.mul(base_width)).add(up_vec.mul(base_width));
                const c2 = base_center.sub(right.mul(base_width)).add(up_vec.mul(base_width));
                const c3 = base_center.sub(right.mul(base_width)).sub(up_vec.mul(base_width));
                const c4 = base_center.add(right.mul(base_width)).sub(up_vec.mul(base_width));

                const p_tip_v4 = view_proj.mulVec4(math.Vec4{ .x = tip.x, .y = tip.y, .z = tip.z, .w = 1.0 });
                const p_c1_v4 = view_proj.mulVec4(math.Vec4{ .x = c1.x, .y = c1.y, .z = c1.z, .w = 1.0 });
                const p_c2_v4 = view_proj.mulVec4(math.Vec4{ .x = c2.x, .y = c2.y, .z = c2.z, .w = 1.0 });
                const p_c3_v4 = view_proj.mulVec4(math.Vec4{ .x = c3.x, .y = c3.y, .z = c3.z, .w = 1.0 });
                const p_c4_v4 = view_proj.mulVec4(math.Vec4{ .x = c4.x, .y = c4.y, .z = c4.z, .w = 1.0 });

                if (p_tip_v4.w > 0 and p_c1_v4.w > 0 and p_c2_v4.w > 0 and p_c3_v4.w > 0 and p_c4_v4.w > 0) {
                    const mk_pt = struct {
                        fn call(v4: math.Vec4, w: f32, h: f32) c.ImVec2 {
                            const n = math.Vec3{ .x = v4.x / v4.w, .y = v4.y / v4.w, .z = v4.z / v4.w };
                            return c.ImVec2{ .x = (n.x + 1.0) * 0.5 * w, .y = (n.y + 1.0) * 0.5 * h };
                        }
                    }.call;

                    const p_tip = mk_pt(p_tip_v4, @floatFromInt(win_width), @floatFromInt(win_height));
                    const p_c1 = mk_pt(p_c1_v4, @floatFromInt(win_width), @floatFromInt(win_height));
                    const p_c2 = mk_pt(p_c2_v4, @floatFromInt(win_width), @floatFromInt(win_height));
                    const p_c3 = mk_pt(p_c3_v4, @floatFromInt(win_width), @floatFromInt(win_height));
                    const p_c4 = mk_pt(p_c4_v4, @floatFromInt(win_width), @floatFromInt(win_height));

                    c.imgui_bridge_draw_triangle_filled(&p_tip, &p_c1, &p_c2, color);
                    c.imgui_bridge_draw_triangle_filled(&p_tip, &p_c2, &p_c3, color);
                    c.imgui_bridge_draw_triangle_filled(&p_tip, &p_c3, &p_c4, color);
                    c.imgui_bridge_draw_triangle_filled(&p_tip, &p_c4, &p_c1, color);
                }
            } else {
                c.imgui_bridge_draw_circle_filled(&p2, handle_size, color);
            }
        }
    }

    selection_state.hover_axis = hovered;
    selection_state.hover_is_rotation = hovered_rot;

    if (c.imgui_bridge_is_mouse_clicked(0) and hovered != null and can_interact and !selection_state.is_dragging) {
        selection_state.is_dragging = true;
        selection_state.drag_axis = hovered;
        selection_state.drag_is_rotation = hovered_rot;
        selection_state.drag_start_mouse = math.Vec2{ .x = mouse_pos.x, .y = mouse_pos.y };
        selection_state.drag_start_pos = pos;
        selection_state.drag_start_rot = rot;
        selection_state.drag_start_val = if (selection_state.gizmo_mode == .Translate) pos else scale_vec;

        if (!hovered_rot) {
            const axis = axes[hovered.?];
            const cam_dir = state.runtime.camera.target.sub(state.runtime.camera.position).normalize();
            var plane_normal = axis.cross(cam_dir).cross(axis).normalize();
            if (plane_normal.lengthSq() < 0.001) plane_normal = axis.cross(state.runtime.camera.up).cross(axis).normalize();
            selection_state.drag_plane_normal = plane_normal;

            var valid_start = false;
            if (get_ray_from_mouse(state)) |ray| {
                const denom = ray.direction.dot(plane_normal);
                if (@abs(denom) > 0.0001) {
                    const t_hit = pos.sub(ray.origin).dot(plane_normal) / denom;
                    const hit_point = ray.origin.add(ray.direction.mul(t_hit));
                    selection_state.drag_start_t = hit_point.sub(pos).dot(axis);
                    valid_start = true;
                }
            }
            if (!valid_start) {
                selection_state.is_dragging = false;
                selection_state.drag_axis = null;
            }
        }

        if (selection_state.is_dragging) {
            state.ui.undo.begin_entity_transform(state.ui.selected_entity.id, t.*);
        }
    }

    if (!c.imgui_bridge_is_mouse_down(0) and selection_state.is_dragging) {
        state.ui.undo.end_entity_transform(state.ui.selected_entity.id, t.*);
        selection_state.is_dragging = false;
        selection_state.drag_axis = null;
        selection_state.drag_is_rotation = false;
    }

    if (selection_state.is_dragging) {
        if (selection_state.drag_axis) |axis_idx| {
            if (selection_state.drag_is_rotation) {
                const mouse_curr = math.Vec2{ .x = mouse_pos.x, .y = mouse_pos.y };
                const center_2d = math.Vec2{ .x = center.x, .y = center.y };

                const v1 = selection_state.drag_start_mouse.sub(center_2d).normalize();
                const v2 = mouse_curr.sub(center_2d).normalize();

                const cross = v1.x * v2.y - v1.y * v2.x;
                const dot = v1.x * v2.x + v1.y * v2.y;
                const angle = std.math.atan2(cross, dot);

                const axis = axes[axis_idx];
                const delta_rot = math.Quat.fromAxisAngle(axis, angle);
                const new_rot = delta_rot.mul(selection_state.drag_start_rot).normalize();

                t.rotation = new_rot;
                t.dirty = true;
                state.runtime.mark_transform_override_tree(state.ui.selected_entity);
            } else {
                if (get_ray_from_mouse(state)) |ray| {
                    const axis = axes[axis_idx];
                    const plane_normal = selection_state.drag_plane_normal;

                    const denom = ray.direction.dot(plane_normal);
                    if (@abs(denom) > 0.0001) {
                        const t_hit = selection_state.drag_start_pos.sub(ray.origin).dot(plane_normal) / denom;
                        const hit_point = ray.origin.add(ray.direction.mul(t_hit));

                        const current_t = hit_point.sub(selection_state.drag_start_pos).dot(axis);
                        const delta_t = current_t - selection_state.drag_start_t;

                        if (selection_state.gizmo_mode == .Translate) {
                            var new_pos = selection_state.drag_start_val;
                            new_pos = new_pos.add(axis.mul(delta_t));
                            t.position = new_pos;
                            t.dirty = true;
                            state.runtime.mark_transform_override_tree(state.ui.selected_entity);
                        } else if (selection_state.gizmo_mode == .Scale) {
                            const scale_delta = 1.0 + (delta_t / scale_factor);

                            var new_scale = selection_state.drag_start_val;
                            if (axis_idx == 0) new_scale.x *= scale_delta;
                            if (axis_idx == 1) new_scale.y *= scale_delta;
                            if (axis_idx == 2) new_scale.z *= scale_delta;

                            if (@abs(new_scale.x) < 0.001) new_scale.x = 0.001;
                            if (@abs(new_scale.y) < 0.001) new_scale.y = 0.001;
                            if (@abs(new_scale.z) < 0.001) new_scale.z = 0.001;

                            t.scale = new_scale;
                            t.dirty = true;
                            state.runtime.mark_transform_override_tree(state.ui.selected_entity);
                        }
                    }
                }
            }
        }
    }
}

/// Draws and applies manipulation gizmos for the currently selected model.
fn draw_gizmo(state: *EditorState) void {
    var selected_model: ?*engine.model_manager.CardinalModelInstance = null;
    if (state.runtime.model_manager.models) |models| {
        var i: u32 = 0;
        while (i < state.runtime.model_manager.model_count) : (i += 1) {
            if (models[i].id == state.ui.selected_model_id) {
                selected_model = &models[i];
                break;
            }
        }
    }

    const model = selected_model orelse return;

    const transform_mat = math.Mat4.fromArray(model.transform);
    const transform_parts = transform_mat.decompose();
    const pos = transform_parts.t;
    const rot = transform_parts.r;
    const scale_vec = transform_parts.s;

    const view = math.Mat4.lookAt(state.runtime.camera.position, state.runtime.camera.target, state.runtime.camera.up);
    const proj = math.Mat4.perspective(math.toRadians(state.runtime.camera.fov), state.runtime.camera.aspect, state.runtime.camera.near_plane, state.runtime.camera.far_plane);
    const view_proj = proj.mul(view);

    const screen_pos_v4 = view_proj.mulVec4(math.Vec4{ .x = pos.x, .y = pos.y, .z = pos.z, .w = 1.0 });
    if (screen_pos_v4.w <= 0) return;

    const ndc = math.Vec3{ .x = screen_pos_v4.x / screen_pos_v4.w, .y = screen_pos_v4.y / screen_pos_v4.w, .z = screen_pos_v4.z / screen_pos_v4.w };

    const win_width = state.runtime.window.width;
    const win_height = state.runtime.window.height;

    const screen_x = (ndc.x + 1.0) * 0.5 * @as(f32, @floatFromInt(win_width));
    const screen_y = (ndc.y + 1.0) * 0.5 * @as(f32, @floatFromInt(win_height));
    const center = c.ImVec2{ .x = screen_x, .y = screen_y };

    const axis_thickness = 3.0;
    const handle_size = 6.0;

    const axes = [_]math.Vec3{
        .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 1, .z = 0 },
        .{ .x = 0, .y = 0, .z = 1 },
    };

    const axis_colors = [_]u32{
        0xFF0000FF,
        0xFF00FF00,
        0xFFFF0000,
    };

    var mouse_pos_im: c.ImVec2 = undefined;
    c.imgui_bridge_get_mouse_pos(&mouse_pos_im);
    const mouse_pos = mouse_pos_im;

    var hovered: ?u32 = null;
    var hovered_rot: bool = false;
    const can_interact = !state.runtime.mouse_captured and !c.imgui_bridge_want_capture_mouse();

    const dist = state.runtime.camera.position.sub(pos).length();
    const scale_factor = dist * 0.15;

    if (selection_state.gizmo_mode == .Rotate) {
        inline for (0..3) |i| {
            var is_hovered = false;
            if (!selection_state.is_dragging and can_interact) {
                if (get_ray_from_mouse(state)) |ray| {
                    const denom = axes[i].dot(ray.direction);
                    if (@abs(denom) > 0.0001) {
                        const t = axes[i].dot(pos.sub(ray.origin)) / denom;
                        if (t > 0) {
                            const hit_point = ray.origin.add(ray.direction.mul(t));
                            const dist_to_center = hit_point.sub(pos).length();
                            const ring_radius = scale_factor * 1.2;
                            const ring_thickness = scale_factor * 0.1;

                            if (@abs(dist_to_center - ring_radius) < ring_thickness) {
                                is_hovered = true;
                                hovered = @as(u32, @intCast(i));
                                hovered_rot = true;
                            }
                        }
                    }
                }
            }
            if (selection_state.drag_axis == @as(u32, @intCast(i)) and selection_state.drag_is_rotation) is_hovered = true;

            const color = if (is_hovered) 0xFFFFFFFF else axis_colors[i];

            var u = math.Vec3{ .x = 0, .y = 1, .z = 0 };
            if (@abs(axes[i].dot(u)) > 0.9) u = math.Vec3{ .x = 0, .y = 0, .z = 1 };
            const v = axes[i].cross(u).normalize();
            u = v.cross(axes[i]).normalize();

            const ring_radius = scale_factor * 1.2;
            const segments = 64;
            var prev_p: c.ImVec2 = undefined;

            for (0..segments + 1) |s| {
                const angle = (@as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments))) * std.math.pi * 2.0;
                const p_local = u.mul(std.math.cos(angle) * ring_radius).add(v.mul(std.math.sin(angle) * ring_radius));
                const p_world = pos.add(p_local);

                const p_v4 = view_proj.mulVec4(math.Vec4{ .x = p_world.x, .y = p_world.y, .z = p_world.z, .w = 1.0 });
                if (p_v4.w <= 0) continue;

                const p_ndc = math.Vec3{ .x = p_v4.x / p_v4.w, .y = p_v4.y / p_v4.w, .z = p_v4.z / p_v4.w };
                const px = (p_ndc.x + 1.0) * 0.5 * @as(f32, @floatFromInt(win_width));
                const py = (p_ndc.y + 1.0) * 0.5 * @as(f32, @floatFromInt(win_height));
                const current_p = c.ImVec2{ .x = px, .y = py };

                if (s > 0) {
                    c.imgui_bridge_draw_line(&prev_p, &current_p, color, axis_thickness);
                }
                prev_p = current_p;
            }
        }
    }

    if (selection_state.gizmo_mode != .Rotate) {
        const tip_hit_dist_sq: f32 = if (selection_state.gizmo_mode == .Scale) 625.0 else 100.0;
        inline for (0..3) |i| {
            const end_pos_world = pos.add(axes[i].mul(scale_factor));
            const end_pos_v4 = view_proj.mulVec4(math.Vec4{ .x = end_pos_world.x, .y = end_pos_world.y, .z = end_pos_world.z, .w = 1.0 });

            const end_ndc = math.Vec3{ .x = end_pos_v4.x / end_pos_v4.w, .y = end_pos_v4.y / end_pos_v4.w, .z = end_pos_v4.z / end_pos_v4.w };
            const end_screen_x = (end_ndc.x + 1.0) * 0.5 * @as(f32, @floatFromInt(win_width));
            const end_screen_y = (end_ndc.y + 1.0) * 0.5 * @as(f32, @floatFromInt(win_height));

            const p1 = center;
            const p2 = c.ImVec2{ .x = end_screen_x, .y = end_screen_y };

            if (!selection_state.is_dragging and can_interact and hovered == null) {
                const dx = mouse_pos.x - end_screen_x;
                const dy = mouse_pos.y - end_screen_y;
                if (dx * dx + dy * dy < tip_hit_dist_sq) {
                    hovered = @as(u32, @intCast(i));
                    hovered_rot = false;
                }
            }

            var color = axis_colors[i];
            if ((hovered == @as(u32, @intCast(i)) and !hovered_rot) or (selection_state.drag_axis == @as(u32, @intCast(i)) and !selection_state.drag_is_rotation)) {
                color = 0xFFFFFFFF;
            }

            c.imgui_bridge_draw_line(&p1, &p2, color, axis_thickness);

            if (selection_state.gizmo_mode == .Scale) {
                const pyramid_len = scale_factor * 0.2;
                const base_width = pyramid_len * 0.5;

                const tip = end_pos_world;
                const base_center = tip.sub(axes[i].mul(pyramid_len));

                var u = math.Vec3{ .x = 0, .y = 1, .z = 0 };
                if (@abs(axes[i].dot(u)) > 0.9) u = math.Vec3{ .x = 0, .y = 0, .z = 1 };
                const right = axes[i].cross(u).normalize();
                const up_vec = right.cross(axes[i]).normalize();

                const c1 = base_center.add(right.mul(base_width)).add(up_vec.mul(base_width));
                const c2 = base_center.sub(right.mul(base_width)).add(up_vec.mul(base_width));
                const c3 = base_center.sub(right.mul(base_width)).sub(up_vec.mul(base_width));
                const c4 = base_center.add(right.mul(base_width)).sub(up_vec.mul(base_width));

                const p_tip_v4 = view_proj.mulVec4(math.Vec4{ .x = tip.x, .y = tip.y, .z = tip.z, .w = 1.0 });
                const p_c1_v4 = view_proj.mulVec4(math.Vec4{ .x = c1.x, .y = c1.y, .z = c1.z, .w = 1.0 });
                const p_c2_v4 = view_proj.mulVec4(math.Vec4{ .x = c2.x, .y = c2.y, .z = c2.z, .w = 1.0 });
                const p_c3_v4 = view_proj.mulVec4(math.Vec4{ .x = c3.x, .y = c3.y, .z = c3.z, .w = 1.0 });
                const p_c4_v4 = view_proj.mulVec4(math.Vec4{ .x = c4.x, .y = c4.y, .z = c4.z, .w = 1.0 });

                if (p_tip_v4.w > 0 and p_c1_v4.w > 0 and p_c2_v4.w > 0 and p_c3_v4.w > 0 and p_c4_v4.w > 0) {
                    const mk_pt = struct {
                        fn call(v4: math.Vec4, w: f32, h: f32) c.ImVec2 {
                            const n = math.Vec3{ .x = v4.x / v4.w, .y = v4.y / v4.w, .z = v4.z / v4.w };
                            return c.ImVec2{ .x = (n.x + 1.0) * 0.5 * w, .y = (n.y + 1.0) * 0.5 * h };
                        }
                    }.call;

                    const p_tip = mk_pt(p_tip_v4, @floatFromInt(win_width), @floatFromInt(win_height));
                    const p_c1 = mk_pt(p_c1_v4, @floatFromInt(win_width), @floatFromInt(win_height));
                    const p_c2 = mk_pt(p_c2_v4, @floatFromInt(win_width), @floatFromInt(win_height));
                    const p_c3 = mk_pt(p_c3_v4, @floatFromInt(win_width), @floatFromInt(win_height));
                    const p_c4 = mk_pt(p_c4_v4, @floatFromInt(win_width), @floatFromInt(win_height));

                    c.imgui_bridge_draw_triangle_filled(&p_tip, &p_c1, &p_c2, color);
                    c.imgui_bridge_draw_triangle_filled(&p_tip, &p_c2, &p_c3, color);
                    c.imgui_bridge_draw_triangle_filled(&p_tip, &p_c3, &p_c4, color);
                    c.imgui_bridge_draw_triangle_filled(&p_tip, &p_c4, &p_c1, color);
                }
            } else {
                c.imgui_bridge_draw_circle_filled(&p2, handle_size, color);
            }
        }
    }

    selection_state.hover_axis = hovered;
    selection_state.hover_is_rotation = hovered_rot;

    if (c.imgui_bridge_is_mouse_clicked(0) and hovered != null and can_interact and !selection_state.is_dragging) {
        selection_state.is_dragging = true;
        selection_state.drag_axis = hovered;
        selection_state.drag_is_rotation = hovered_rot;
        selection_state.drag_start_mouse = math.Vec2{ .x = mouse_pos.x, .y = mouse_pos.y };
        selection_state.drag_start_pos = pos;
        selection_state.drag_start_rot = rot;
        selection_state.drag_start_val = if (selection_state.gizmo_mode == .Translate) pos else scale_vec;

        if (!hovered_rot) {
            const axis = axes[hovered.?];
            const cam_dir = state.runtime.camera.target.sub(state.runtime.camera.position).normalize();

            var plane_normal = axis.cross(cam_dir).cross(axis).normalize();
            if (plane_normal.lengthSq() < 0.001) {
                plane_normal = axis.cross(state.runtime.camera.up).cross(axis).normalize();
            }
            selection_state.drag_plane_normal = plane_normal;

            var valid_start = false;
            if (get_ray_from_mouse(state)) |ray| {
                const denom = ray.direction.dot(plane_normal);
                if (@abs(denom) > 0.0001) {
                    const t_hit = pos.sub(ray.origin).dot(plane_normal) / denom;
                    const hit_point = ray.origin.add(ray.direction.mul(t_hit));
                    selection_state.drag_start_t = hit_point.sub(pos).dot(axis);
                    valid_start = true;
                }
            }

            if (!valid_start) {
                selection_state.is_dragging = false;
                selection_state.drag_axis = null;
            }
        }

        if (selection_state.is_dragging) {
            state.ui.undo.begin_model_transform(model.id, model.transform);
        }
    }

    if (!c.imgui_bridge_is_mouse_down(0) and selection_state.is_dragging) {
        state.ui.undo.end_model_transform(model.id, model.transform);
        selection_state.is_dragging = false;
        selection_state.drag_axis = null;
        selection_state.drag_is_rotation = false;
    }

    if (selection_state.is_dragging) {
        if (selection_state.drag_axis) |axis_idx| {
            if (selection_state.drag_is_rotation) {
                const mouse_curr = math.Vec2{ .x = mouse_pos.x, .y = mouse_pos.y };
                const center_2d = math.Vec2{ .x = center.x, .y = center.y };

                const v1 = selection_state.drag_start_mouse.sub(center_2d).normalize();
                const v2 = mouse_curr.sub(center_2d).normalize();

                const cross = v1.x * v2.y - v1.y * v2.x;
                const dot = v1.x * v2.x + v1.y * v2.y;
                const angle = std.math.atan2(cross, dot);

                const axis = axes[axis_idx];
                const delta_rot = math.Quat.fromAxisAngle(axis, angle);
                const new_rot = delta_rot.mul(selection_state.drag_start_rot).normalize();

                const new_mat = math.Mat4.fromTRS(pos, new_rot, scale_vec);
                model.transform = new_mat.data;
                state.runtime.model_manager.transform_dirty = true;
            } else {
                if (get_ray_from_mouse(state)) |ray| {
                    const axis = axes[axis_idx];
                    const plane_normal = selection_state.drag_plane_normal;

                    const denom = ray.direction.dot(plane_normal);
                    if (@abs(denom) > 0.0001) {
                        const t_hit = selection_state.drag_start_pos.sub(ray.origin).dot(plane_normal) / denom;
                        const hit_point = ray.origin.add(ray.direction.mul(t_hit));

                        const current_t = hit_point.sub(selection_state.drag_start_pos).dot(axis);
                        const delta_t = current_t - selection_state.drag_start_t;

                        if (selection_state.gizmo_mode == .Translate) {
                            var new_pos = selection_state.drag_start_val;
                            new_pos = new_pos.add(axis.mul(delta_t));

                            const new_mat = math.Mat4.fromTRS(new_pos, rot, scale_vec);
                            model.transform = new_mat.data;
                            state.runtime.model_manager.transform_dirty = true;
                        } else if (selection_state.gizmo_mode == .Scale) {
                            const scale_delta = 1.0 + (delta_t / scale_factor);

                            var new_scale = selection_state.drag_start_val;
                            if (axis_idx == 0) new_scale.x *= scale_delta;
                            if (axis_idx == 1) new_scale.y *= scale_delta;
                            if (axis_idx == 2) new_scale.z *= scale_delta;

                            if (@abs(new_scale.x) < 0.001) new_scale.x = 0.001;
                            if (@abs(new_scale.y) < 0.001) new_scale.y = 0.001;
                            if (@abs(new_scale.z) < 0.001) new_scale.z = 0.001;

                            const new_mat = math.Mat4.fromTRS(pos, rot, new_scale);
                            model.transform = new_mat.data;
                            state.runtime.model_manager.transform_dirty = true;
                        }
                    }
                }
            }
        }
    }
}
