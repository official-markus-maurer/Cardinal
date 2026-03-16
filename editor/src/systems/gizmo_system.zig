//! Editor gizmo manipulation.
//!
//! Tracks the current gizmo mode and applies transform edits to the selected entity.
//!
//! TODO: Consider extracting drawing primitives into a reusable debug-draw module.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const components = engine.ecs_components;
const EditorState = @import("../editor_state.zig").EditorState;
const c = @import("../c.zig").c;
const selection_raycast = @import("selection_raycast.zig");

pub const GizmoMode = enum {
    Translate,
    Scale,
    Rotate,
};

const SelectionState = struct {
    gizmo_mode: GizmoMode = .Translate,
    is_dragging: bool = false,
    drag_axis: ?u32 = null,
    drag_start_mouse: math.Vec2 = math.Vec2.zero(),
    drag_start_val: math.Vec3 = math.Vec3.zero(),
    drag_start_rot: math.Quat = math.Quat.identity(),
    drag_start_pos: math.Vec3 = math.Vec3.zero(),
    drag_start_world: math.Mat4 = math.Mat4.identity(),
    drag_parent_inv: math.Mat4 = math.Mat4.identity(),
    hover_axis: ?u32 = null,
    hover_is_rotation: bool = false,
    drag_is_rotation: bool = false,
    drag_plane_normal: math.Vec3 = math.Vec3.zero(),
    drag_start_t: f32 = 0.0,
};

var selection_state = SelectionState{};

fn axis_param_from_ray(origin: math.Vec3, axis_in: math.Vec3, ray_origin: math.Vec3, ray_dir_in: math.Vec3) ?f32 {
    const axis = axis_in.normalize();
    const ray_dir = ray_dir_in.normalize();
    const w0 = ray_origin.sub(origin);

    const d = axis.dot(ray_dir);
    const e = axis.dot(w0);
    const f = ray_dir.dot(w0);

    const denom = 1.0 - d * d;
    if (@abs(denom) < 1e-6) return null;
    return (d * f - e) / denom;
}

fn compute_entity_world_matrix(state: *EditorState, entity: engine.ecs_entity.Entity, depth: u32) math.Mat4 {
    if (depth > 2048) return math.Mat4.identity();

    var parent_world = math.Mat4.identity();
    if (state.runtime.registry.get(components.Hierarchy, entity)) |h| {
        if (h.parent) |p| {
            parent_world = compute_entity_world_matrix(state, p, depth + 1);
        }
    }

    var local = math.Mat4.identity();
    if (state.runtime.registry.get(components.Transform, entity)) |t| {
        local = math.Mat4.fromTRS(t.position, t.rotation, t.scale);
    }

    return parent_world.mul(local);
}

fn get_parent_world_and_inv(state: *EditorState, entity: engine.ecs_entity.Entity) struct { world: math.Mat4, inv: ?math.Mat4 } {
    if (state.runtime.registry.get(components.Hierarchy, entity)) |h| {
        if (h.parent) |p| {
            const world = compute_entity_world_matrix(state, p, 0);
            return .{ .world = world, .inv = world.invert() };
        }
    }
    const identity = math.Mat4.identity();
    return .{ .world = identity, .inv = identity.invert() };
}

fn mat4_translation(m: math.Mat4) math.Vec3 {
    return .{ .x = m.data[12], .y = m.data[13], .z = m.data[14] };
}

fn mat4_with_translation(m: math.Mat4, t: math.Vec3) math.Mat4 {
    var out = m;
    out.data[12] = t.x;
    out.data[13] = t.y;
    out.data[14] = t.z;
    return out;
}

/// Updates gizmo mode and resets transient state when the editor captures input.
pub fn pre_update(state: *EditorState) void {
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
}

/// Returns true when it is safe to run scene picking (mouse is not over gizmo).
pub fn allow_scene_pick() bool {
    return !selection_state.is_dragging and selection_state.hover_axis == null;
}

/// Draws and applies gizmo manipulation to `t` for the selected entity.
pub fn draw_entity_gizmo(state: *EditorState, t: *components.Transform) void {
    const entity = state.ui.selected_entity;
    if (!state.runtime.registry.entity_manager.is_alive(entity)) return;

    const world = compute_entity_world_matrix(state, entity, 0);
    const pos = mat4_translation(world);
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
                if (selection_raycast.get_ray_from_mouse(state)) |ray| {
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
        selection_state.drag_start_val = if (selection_state.gizmo_mode == .Translate) t.position else scale_vec;

        const parent_ctx = get_parent_world_and_inv(state, entity);
        const parent_inv = parent_ctx.inv orelse math.Mat4.identity();
        selection_state.drag_parent_inv = parent_inv;
        const local_start = math.Mat4.fromTRS(t.position, rot, scale_vec);
        selection_state.drag_start_world = parent_ctx.world.mul(local_start);

        if (!hovered_rot) {
            const axis = axes[hovered.?];
            const cam_dir = state.runtime.camera.target.sub(state.runtime.camera.position).normalize();
            var plane_normal = axis.cross(cam_dir).cross(axis).normalize();
            if (plane_normal.lengthSq() < 0.001) plane_normal = axis.cross(state.runtime.camera.up).cross(axis).normalize();
            selection_state.drag_plane_normal = plane_normal;

            var valid_start = false;
            if (selection_raycast.get_ray_from_mouse(state)) |ray| {
                if (axis_param_from_ray(pos, axis, ray.origin, ray.direction)) |t_axis| {
                    selection_state.drag_start_t = t_axis;
                    valid_start = true;
                } else {
                    const denom = ray.direction.dot(plane_normal);
                    if (@abs(denom) > 0.0001) {
                        const t_hit = pos.sub(ray.origin).dot(plane_normal) / denom;
                        const hit_point = ray.origin.add(ray.direction.mul(t_hit));
                        selection_state.drag_start_t = hit_point.sub(pos).dot(axis);
                        valid_start = true;
                    }
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
                const q = math.Quat.fromAxisAngle(axis, -angle).normalize();
                const r = math.Mat4.fromTRS(math.Vec3.zero(), q, math.Vec3.one());

                const start_world_pos = mat4_translation(selection_state.drag_start_world);
                const rotated = r.mul(selection_state.drag_start_world);
                const world_new = mat4_with_translation(rotated, start_world_pos);

                const local_new = selection_state.drag_parent_inv.mul(world_new);
                const decomposed = local_new.decompose();
                t.position = decomposed.t;
                t.rotation = decomposed.r;
                t.scale = decomposed.s;
                t.dirty = true;
                state.runtime.mark_transform_override_tree(state.ui.selected_entity);
            } else {
                if (selection_raycast.get_ray_from_mouse(state)) |ray| {
                    const axis = axes[axis_idx];
                    const plane_normal = selection_state.drag_plane_normal;

                    var delta_t: ?f32 = null;
                    if (axis_param_from_ray(selection_state.drag_start_pos, axis, ray.origin, ray.direction)) |t_axis| {
                        delta_t = t_axis - selection_state.drag_start_t;
                    } else {
                        const denom = ray.direction.dot(plane_normal);
                        if (@abs(denom) > 0.0001) {
                            const t_hit = selection_state.drag_start_pos.sub(ray.origin).dot(plane_normal) / denom;
                            const hit_point = ray.origin.add(ray.direction.mul(t_hit));
                            const current_t = hit_point.sub(selection_state.drag_start_pos).dot(axis);
                            delta_t = current_t - selection_state.drag_start_t;
                        }
                    }

                    if (delta_t) |dt_axis| {
                        const dt_world = -dt_axis;
                        if (selection_state.gizmo_mode == .Translate) {
                            const delta_world = axis.mul(dt_world);
                            var world_new = selection_state.drag_start_world;
                            world_new.data[12] += delta_world.x;
                            world_new.data[13] += delta_world.y;
                            world_new.data[14] += delta_world.z;

                            const local_new = selection_state.drag_parent_inv.mul(world_new);
                            const decomposed = local_new.decompose();
                            t.position = decomposed.t;
                            t.rotation = decomposed.r;
                            t.scale = decomposed.s;
                            t.dirty = true;
                            state.runtime.mark_transform_override_tree(state.ui.selected_entity);
                        } else if (selection_state.gizmo_mode == .Scale) {
                            const scale_delta = 1.0 + (dt_world / scale_factor);
                            const sx: f32 = if (axis_idx == 0) scale_delta else 1.0;
                            const sy: f32 = if (axis_idx == 1) scale_delta else 1.0;
                            const sz: f32 = if (axis_idx == 2) scale_delta else 1.0;
                            const s = math.Mat4.fromTRS(math.Vec3.zero(), math.Quat.identity(), .{ .x = sx, .y = sy, .z = sz });

                            const start_world_pos = mat4_translation(selection_state.drag_start_world);
                            const scaled = s.mul(selection_state.drag_start_world);
                            const world_new = mat4_with_translation(scaled, start_world_pos);

                            const local_new = selection_state.drag_parent_inv.mul(world_new);
                            const decomposed = local_new.decompose();
                            t.position = decomposed.t;
                            t.rotation = decomposed.r;
                            var sc = decomposed.s;
                            if (@abs(sc.x) < 0.001) sc.x = 0.001;
                            if (@abs(sc.y) < 0.001) sc.y = 0.001;
                            if (@abs(sc.z) < 0.001) sc.z = 0.001;
                            t.scale = sc;
                            t.dirty = true;
                            state.runtime.mark_transform_override_tree(state.ui.selected_entity);
                        }
                    }
                }
            }
        }
    }
}
