//! Editor selection and gizmo interaction.
//!
//! Implements raycast selection against loaded models and basic translate/scale/rotate gizmos.
//!
//! TODO: Split selection (raycast) and gizmo manipulation into separate modules.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
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

/// Computes a world-space ray from the current mouse position.
fn get_ray_from_mouse(state: *EditorState) ?math.Ray {
    var mouse_pos_im: c.ImVec2 = undefined;
    c.imgui_bridge_get_mouse_pos(&mouse_pos_im);
    const mouse_pos = math.Vec2{ .x = mouse_pos_im.x, .y = mouse_pos_im.y };

    if (mouse_pos.x < 0 or mouse_pos.y < 0) return null;

    const win_width = state.window.width;
    const win_height = state.window.height;

    if (win_width == 0 or win_height == 0) return null;

    const x = (2.0 * mouse_pos.x) / @as(f32, @floatFromInt(win_width)) - 1.0;
    const y = (2.0 * mouse_pos.y) / @as(f32, @floatFromInt(win_height)) - 1.0;

    const ray_nds = math.Vec3{ .x = x, .y = y, .z = 1.0 };
    const ray_clip = math.Vec4{ .x = ray_nds.x, .y = ray_nds.y, .z = -1.0, .w = 1.0 };

    const proj = math.Mat4.perspective(math.toRadians(state.camera.fov), state.camera.aspect, state.camera.near_plane, state.camera.far_plane);
    const inv_proj = proj.invert() orelse return null;

    var ray_eye_v4 = inv_proj.mulVec4(ray_clip);
    ray_eye_v4.z = -1.0;
    ray_eye_v4.w = 0.0;

    const ray_eye = math.Vec3{ .x = ray_eye_v4.x, .y = ray_eye_v4.y, .z = ray_eye_v4.z };

    const view = math.Mat4.lookAt(state.camera.position, state.camera.target, state.camera.up);
    const inv_view = view.invert() orelse return null;

    const ray_world_v4 = inv_view.mulVec4(math.Vec4{ .x = ray_eye.x, .y = ray_eye.y, .z = ray_eye.z, .w = 0.0 });
    var ray_world = math.Vec3{ .x = ray_world_v4.x, .y = ray_world_v4.y, .z = ray_world_v4.z };
    ray_world = ray_world.normalize();

    return math.Ray{ .origin = state.camera.position, .direction = ray_world };
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

fn pick_combined_mesh(state: *EditorState, ray: math.Ray) ?u32 {
    if (state.combined_scene.meshes == null or state.combined_scene.mesh_count == 0) return null;
    const meshes = state.combined_scene.meshes.?;

    var closest_t_alpha: f32 = std.math.floatMax(f32);
    var hit_mesh_alpha: ?u32 = null;
    var closest_t_any: f32 = std.math.floatMax(f32);
    var hit_mesh_any: ?u32 = null;

    const t_min: f32 = 0.001;
    const t_max: f32 = 10000.0;

    var i: u32 = 0;
    while (i < state.combined_scene.mesh_count) : (i += 1) {
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

        const verts: [*]const scene.CardinalVertex = @ptrCast(mesh.vertices.?);
        const idxs: [*]const u32 = @ptrCast(mesh.indices.?);

        var idx_i: u32 = 0;
        while (idx_i + 2 < mesh.index_count) : (idx_i += 3) {
            const idx0 = idxs[idx_i + 0];
            const idx1 = idxs[idx_i + 1];
            const idx2 = idxs[idx_i + 2];
            if (idx0 >= mesh.vertex_count or idx1 >= mesh.vertex_count or idx2 >= mesh.vertex_count) continue;

            const p0_local = math.Vec3{ .x = verts[idx0].px, .y = verts[idx0].py, .z = verts[idx0].pz };
            const p1_local = math.Vec3{ .x = verts[idx1].px, .y = verts[idx1].py, .z = verts[idx1].pz };
            const p2_local = math.Vec3{ .x = verts[idx2].px, .y = verts[idx2].py, .z = verts[idx2].pz };

            const p0 = world_mat.transformPoint(p0_local);
            const p1 = world_mat.transformPoint(p1_local);
            const p2 = world_mat.transformPoint(p2_local);

            if (intersect_ray_triangle(ray, p0, p1, p2, t_min, @min(t_max, closest_t_any))) |hit| {
                if (hit.t < closest_t_any) {
                    closest_t_any = hit.t;
                    hit_mesh_any = i;
                }

                if (hit_passes_alpha_test(&state.combined_scene, mesh, verts, idx0, idx1, idx2, hit.u, hit.v)) {
                    if (hit.t < closest_t_alpha) {
                        closest_t_alpha = hit.t;
                        hit_mesh_alpha = i;
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

fn find_entity_for_mesh_index(state: *EditorState, mesh_index: u32) ?engine.ecs_entity.Entity {
    var view = state.registry.view(components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        if (entry.component.mesh.index == mesh_index) return entry.entity;
    }
    return null;
}

fn find_node_name_for_mesh_index(state: *EditorState, mesh_index: u32) ?[]const u8 {
    if (state.combined_scene.all_nodes == null or state.combined_scene.all_node_count == 0) return null;

    var i: u32 = 0;
    while (i < state.combined_scene.all_node_count) : (i += 1) {
        const node_opt = state.combined_scene.all_nodes.?[i];
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

fn ensure_entity_for_mesh_index(state: *EditorState, mesh_index: u32) ?engine.ecs_entity.Entity {
    if (find_entity_for_mesh_index(state, mesh_index)) |ent| return ent;
    if (state.combined_scene.meshes == null or mesh_index >= state.combined_scene.mesh_count) return null;

    const mesh = &state.combined_scene.meshes.?[mesh_index];

    const entity = state.registry.create() catch return null;

    var name_buf: [64]u8 = undefined;
    const name = find_node_name_for_mesh_index(state, mesh_index) orelse (std.fmt.bufPrint(&name_buf, "Mesh{d}", .{mesh_index}) catch "Mesh");
    state.registry.add(entity, components.Name.init(name)) catch {};

    state.registry.add(entity, components.Node{ .type = .MeshInstance3D }) catch {};

    var transform = components.Transform{};
    const m = math.Mat4.fromArray(mesh.transform);
    const decomposed = m.decompose();
    transform.position = decomposed.t;
    transform.rotation = decomposed.r;
    transform.scale = decomposed.s;
    state.registry.add(entity, transform) catch {};

    state.registry.add(entity, components.Hierarchy{}) catch {};

    const mr = components.MeshRenderer{
        .mesh = .{ .index = mesh_index, .generation = 0 },
        .material = .{ .index = mesh.material_index, .generation = 0 },
        .visible = mesh.visible,
        .cast_shadows = true,
        .receive_shadows = true,
    };
    state.registry.add(entity, mr) catch {};

    return entity;
}

/// Updates selection and active gizmo state based on input.
pub fn update(state: *EditorState) void {
    if (c.imgui_bridge_is_shift_down()) {
        if (!selection_state.is_dragging) {
            selection_state.gizmo_mode = .Scale;
        }
    } else {
        if (!selection_state.is_dragging) {
            selection_state.gizmo_mode = .Translate;
        }
    }

    if (state.mouse_captured) {
        selection_state.is_dragging = false;
        selection_state.drag_axis = null;
        selection_state.drag_is_rotation = false;
        selection_state.hover_axis = null;
        selection_state.hover_is_rotation = false;
    }

    const want_capture = c.imgui_bridge_want_capture_mouse();
    if (!state.mouse_captured and c.imgui_bridge_is_mouse_clicked(0) and !want_capture and !selection_state.is_dragging and selection_state.hover_axis == null) {
        if (get_ray_from_mouse(state)) |ray| {
            if (pick_combined_mesh(state, ray)) |mesh_index| {
                if (find_entity_for_mesh_index(state, mesh_index) orelse ensure_entity_for_mesh_index(state, mesh_index)) |ent| {
                    state.selected_entity = ent;
                    state.selected_model_id = 0;
                    state.scene_graph_focus_target_id = ent.id;
                    state.scene_graph_focus_pending = true;
                } else {
                    state.selected_entity = .{ .id = std.math.maxInt(u64) };
                }
            } else {
                var closest_t: f32 = std.math.floatMax(f32);
                var hit_model_id: u32 = 0;

                if (state.model_manager.models) |models| {
                    var i: u32 = 0;
                    while (i < state.model_manager.model_count) : (i += 1) {
                        const model = &models[i];
                        if (!model.visible or model.is_loading) continue;

                        const scn = &model.scene;

                        if (scn.root_nodes) |roots| {
                            var r: u32 = 0;
                            while (r < scn.root_node_count) : (r += 1) {
                                if (roots[r]) |root| {
                                    check_node_intersection(root, model, ray, &closest_t, &hit_model_id);
                                }
                            }
                        }
                    }
                }

                if (hit_model_id != 0) {
                    state.selected_model_id = hit_model_id;
                    state.selected_entity = .{ .id = std.math.maxInt(u64) };
                } else {
                    state.selected_model_id = 0;
                    state.selected_entity = .{ .id = std.math.maxInt(u64) };
                }
            }
        }
    }

    if (state.selected_entity.id != std.math.maxInt(u64)) {
        if (state.registry.get(components.Transform, state.selected_entity)) |t| {
            draw_entity_gizmo(state, t);
            return;
        }
    }

    if (state.selected_model_id != 0) draw_gizmo(state);
}

fn draw_entity_gizmo(state: *EditorState, t: *components.Transform) void {
    const pos = t.position;
    const rot = t.rotation.normalize();
    const scale_vec = t.scale;

    const view = math.Mat4.lookAt(state.camera.position, state.camera.target, state.camera.up);
    const proj = math.Mat4.perspective(math.toRadians(state.camera.fov), state.camera.aspect, state.camera.near_plane, state.camera.far_plane);
    const view_proj = proj.mul(view);

    const screen_pos_v4 = view_proj.mulVec4(math.Vec4{ .x = pos.x, .y = pos.y, .z = pos.z, .w = 1.0 });
    if (screen_pos_v4.w <= 0) return;

    const ndc = math.Vec3{ .x = screen_pos_v4.x / screen_pos_v4.w, .y = screen_pos_v4.y / screen_pos_v4.w, .z = screen_pos_v4.z / screen_pos_v4.w };

    const win_width = state.window.width;
    const win_height = state.window.height;

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
    const can_interact = !state.mouse_captured and !c.imgui_bridge_want_capture_mouse();

    const dist = state.camera.position.sub(pos).length();
    const scale_factor = dist * 0.15;

    if (selection_state.gizmo_mode == .Translate or selection_state.gizmo_mode == .Rotate) {
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
                if (dx * dx + dy * dy < 100.0) {
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
            const cam_dir = state.camera.target.sub(state.camera.position).normalize();
            var plane_normal = axis.cross(cam_dir).cross(axis).normalize();
            if (plane_normal.lengthSq() < 0.001) plane_normal = axis.cross(state.camera.up).cross(axis).normalize();
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
    }

    if (!c.imgui_bridge_is_mouse_down(0)) {
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
                state.mark_transform_override_tree(state.selected_entity);
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
                            state.mark_transform_override_tree(state.selected_entity);
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
                            state.mark_transform_override_tree(state.selected_entity);
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
    if (state.model_manager.models) |models| {
        var i: u32 = 0;
        while (i < state.model_manager.model_count) : (i += 1) {
            if (models[i].id == state.selected_model_id) {
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

    const view = math.Mat4.lookAt(state.camera.position, state.camera.target, state.camera.up);
    const proj = math.Mat4.perspective(math.toRadians(state.camera.fov), state.camera.aspect, state.camera.near_plane, state.camera.far_plane);
    const view_proj = proj.mul(view);

    const screen_pos_v4 = view_proj.mulVec4(math.Vec4{ .x = pos.x, .y = pos.y, .z = pos.z, .w = 1.0 });
    if (screen_pos_v4.w <= 0) return;

    const ndc = math.Vec3{ .x = screen_pos_v4.x / screen_pos_v4.w, .y = screen_pos_v4.y / screen_pos_v4.w, .z = screen_pos_v4.z / screen_pos_v4.w };

    const win_width = state.window.width;
    const win_height = state.window.height;

    const screen_x = (ndc.x + 1.0) * 0.5 * @as(f32, @floatFromInt(win_width));
    const screen_y = (ndc.y + 1.0) * 0.5 * @as(f32, @floatFromInt(win_height));
    const center = c.ImVec2{ .x = screen_x, .y = screen_y };

    const axis_thickness = 3.0;
    const handle_size = 6.0;

    // Basis vectors in world space
    const axes = [_]math.Vec3{
        .{ .x = 1, .y = 0, .z = 0 }, // X
        .{ .x = 0, .y = 1, .z = 0 }, // Y
        .{ .x = 0, .y = 0, .z = 1 }, // Z
    };

    // ABGR Colors for ImGui
    const axis_colors = [_]u32{
        0xFF0000FF, // Red
        0xFF00FF00, // Green
        0xFFFF0000, // Blue
    };

    // Interaction
    var mouse_pos_im: c.ImVec2 = undefined;
    c.imgui_bridge_get_mouse_pos(&mouse_pos_im);
    const mouse_pos = mouse_pos_im;

    var hovered: ?u32 = null;
    var hovered_rot: bool = false;
    const can_interact = !state.mouse_captured and !c.imgui_bridge_want_capture_mouse();

    // Calculate constant screen size for gizmo
    const dist = state.camera.position.sub(pos).length();
    const scale_factor = dist * 0.15;

    // --- ROTATION RINGS (Always visible in Translate/Rotate mode, or specific mode) ---
    if (selection_state.gizmo_mode == .Translate or selection_state.gizmo_mode == .Rotate) {
        inline for (0..3) |i| {
            var is_hovered = false;
            // Interaction Check (Ray-Plane Intersection)
            if (!selection_state.is_dragging and can_interact) {
                if (get_ray_from_mouse(state)) |ray| {
                    const denom = axes[i].dot(ray.direction);
                    if (@abs(denom) > 0.0001) {
                        const t = axes[i].dot(pos.sub(ray.origin)) / denom;
                        if (t > 0) {
                            const hit_point = ray.origin.add(ray.direction.mul(t));
                            const dist_to_center = hit_point.sub(pos).length();
                            // Ring radius is scale_factor * 1.2 to be outside arrows
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

            // Draw Ring
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

    // --- TRANSLATE / SCALE AXES ---
    // Only verify hover if we haven't already hovered a rotation ring
    if (selection_state.gizmo_mode != .Rotate) { // Show axes in Translate/Scale
        inline for (0..3) |i| {
            const end_pos_world = pos.add(axes[i].mul(scale_factor));
            const end_pos_v4 = view_proj.mulVec4(math.Vec4{ .x = end_pos_world.x, .y = end_pos_world.y, .z = end_pos_world.z, .w = 1.0 });

            const end_ndc = math.Vec3{ .x = end_pos_v4.x / end_pos_v4.w, .y = end_pos_v4.y / end_pos_v4.w, .z = end_pos_v4.z / end_pos_v4.w };
            const end_screen_x = (end_ndc.x + 1.0) * 0.5 * @as(f32, @floatFromInt(win_width));
            const end_screen_y = (end_ndc.y + 1.0) * 0.5 * @as(f32, @floatFromInt(win_height));

            const p1 = center;
            const p2 = c.ImVec2{ .x = end_screen_x, .y = end_screen_y };

            // Check hover (if not already hovering ring)
            if (!selection_state.is_dragging and can_interact and hovered == null) {
                const dx = mouse_pos.x - end_screen_x;
                const dy = mouse_pos.y - end_screen_y;
                if (dx * dx + dy * dy < 100.0) { // 10 pixel radius
                    hovered = @as(u32, @intCast(i));
                    hovered_rot = false;
                }
            }

            var color = axis_colors[i];
            if ((hovered == @as(u32, @intCast(i)) and !hovered_rot) or (selection_state.drag_axis == @as(u32, @intCast(i)) and !selection_state.drag_is_rotation)) {
                color = 0xFFFFFFFF; // White highlight
            }

            c.imgui_bridge_draw_line(&p1, &p2, color, axis_thickness);

            if (selection_state.gizmo_mode == .Scale) {
                // Draw Pyramid for Scale
                const pyramid_len = scale_factor * 0.2;
                const base_width = pyramid_len * 0.5;

                const tip = end_pos_world;
                const base_center = tip.sub(axes[i].mul(pyramid_len));

                // Find perp vectors
                var u = math.Vec3{ .x = 0, .y = 1, .z = 0 };
                if (@abs(axes[i].dot(u)) > 0.9) u = math.Vec3{ .x = 0, .y = 0, .z = 1 };
                const right = axes[i].cross(u).normalize();
                const up_vec = right.cross(axes[i]).normalize();

                // 4 Base corners
                const c1 = base_center.add(right.mul(base_width)).add(up_vec.mul(base_width));
                const c2 = base_center.sub(right.mul(base_width)).add(up_vec.mul(base_width));
                const c3 = base_center.sub(right.mul(base_width)).sub(up_vec.mul(base_width));
                const c4 = base_center.add(right.mul(base_width)).sub(up_vec.mul(base_width));

                // Helper to project
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
                // Draw cone/arrow for translate
                c.imgui_bridge_draw_circle_filled(&p2, handle_size, color);
            }
        }
    }

    selection_state.hover_axis = hovered;
    selection_state.hover_is_rotation = hovered_rot;

    // Handle Dragging Start
    // Added !selection_state.is_dragging check to prevent state changes while already dragging
    if (c.imgui_bridge_is_mouse_clicked(0) and hovered != null and can_interact and !selection_state.is_dragging) {
        selection_state.is_dragging = true;
        selection_state.drag_axis = hovered;
        selection_state.drag_is_rotation = hovered_rot;
        selection_state.drag_start_mouse = math.Vec2{ .x = mouse_pos.x, .y = mouse_pos.y };
        selection_state.drag_start_pos = pos;
        selection_state.drag_start_rot = rot;
        selection_state.drag_start_val = if (selection_state.gizmo_mode == .Translate) pos else scale_vec;

        // Calculate drag plane and start t for 3D dragging
        if (!hovered_rot) {
            const axis = axes[hovered.?];
            const cam_dir = state.camera.target.sub(state.camera.position).normalize();

            // Plane Normal: Cross(Axis, Cross(CamDir, Axis))
            // This gives a vector perpendicular to Axis, lying in the plane of Axis and CamDir.
            // This ensures the plane contains the Axis line and is "most perpendicular" to the View.
            var plane_normal = axis.cross(cam_dir).cross(axis).normalize();
            if (plane_normal.lengthSq() < 0.001) {
                plane_normal = axis.cross(state.camera.up).cross(axis).normalize();
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
                // Abort drag if we can't determine start point
                selection_state.is_dragging = false;
                selection_state.drag_axis = null;
            }
        }
    }

    // Stop Dragging
    if (!c.imgui_bridge_is_mouse_down(0)) {
        selection_state.is_dragging = false;
        selection_state.drag_axis = null;
        selection_state.drag_is_rotation = false;
    }

    // Handle Dragging Update
    if (selection_state.is_dragging) {
        if (selection_state.drag_axis) |axis_idx| {
            if (selection_state.drag_is_rotation) {
                // Arcball-ish Rotation
                const mouse_curr = math.Vec2{ .x = mouse_pos.x, .y = mouse_pos.y };
                const center_2d = math.Vec2{ .x = center.x, .y = center.y };

                const v1 = selection_state.drag_start_mouse.sub(center_2d).normalize();
                const v2 = mouse_curr.sub(center_2d).normalize();

                // Angle change
                // 2D cross product: x1*y2 - y1*x2
                const cross = v1.x * v2.y - v1.y * v2.x;
                const dot = v1.x * v2.x + v1.y * v2.y;
                const angle = std.math.atan2(cross, dot);

                // Apply rotation around axis
                const axis = axes[axis_idx];
                const delta_rot = math.Quat.fromAxisAngle(axis, angle);
                const new_rot = delta_rot.mul(selection_state.drag_start_rot).normalize();

                const new_mat = math.Mat4.fromTRS(pos, new_rot, scale_vec);
                model.transform = new_mat.data;
                state.model_manager.transform_dirty = true;
            } else {
                // Translate / Scale
                if (get_ray_from_mouse(state)) |ray| {
                    const axis = axes[axis_idx];
                    const plane_normal = selection_state.drag_plane_normal;

                    const denom = ray.direction.dot(plane_normal);
                    if (@abs(denom) > 0.0001) {
                        const t_hit = selection_state.drag_start_pos.sub(ray.origin).dot(plane_normal) / denom;
                        const hit_point = ray.origin.add(ray.direction.mul(t_hit));

                        // Project onto axis
                        const current_t = hit_point.sub(selection_state.drag_start_pos).dot(axis);
                        const delta_t = current_t - selection_state.drag_start_t;

                        if (selection_state.gizmo_mode == .Translate) {
                            var new_pos = selection_state.drag_start_val;
                            new_pos = new_pos.add(axis.mul(delta_t));

                            const new_mat = math.Mat4.fromTRS(new_pos, rot, scale_vec);
                            model.transform = new_mat.data;
                            state.model_manager.transform_dirty = true;
                        } else if (selection_state.gizmo_mode == .Scale) {
                            // Normalize delta by scale_factor (gizmo visual size) to make it consistent
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
                            state.model_manager.transform_dirty = true;
                        }
                    }
                }
            }
        }
    }
}
