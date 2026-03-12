const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const scene = engine.scene;
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
    drag_axis: ?u32 = null, // 0: X, 1: Y, 2: Z
    drag_start_mouse: math.Vec2 = math.Vec2.zero(),
    drag_start_val: math.Vec3 = math.Vec3.zero(),
    drag_start_rot: math.Quat = math.Quat.identity(),
    drag_start_pos: math.Vec3 = math.Vec3.zero(), // Initial position when drag started
    hover_axis: ?u32 = null,
    hover_is_rotation: bool = false,
    drag_is_rotation: bool = false,
    drag_plane_normal: math.Vec3 = math.Vec3.zero(),
    drag_start_t: f32 = 0.0,
};

var selection_state = SelectionState{};

fn get_ray_from_mouse(state: *EditorState) ?math.Ray {
    var mouse_pos_im: c.ImVec2 = undefined;
    c.imgui_bridge_get_mouse_pos(&mouse_pos_im);
    const mouse_pos = math.Vec2{ .x = mouse_pos_im.x, .y = mouse_pos_im.y };

    // Check if mouse is valid
    if (mouse_pos.x < 0 or mouse_pos.y < 0) return null;

    const win_width = state.window.width;
    const win_height = state.window.height;

    if (win_width == 0 or win_height == 0) return null;

    // Normalized Device Coordinates (-1 to 1)
    // Vulkan: y is -1 (top) to 1 (bottom)
    const x = (2.0 * mouse_pos.x) / @as(f32, @floatFromInt(win_width)) - 1.0;
    const y = (2.0 * mouse_pos.y) / @as(f32, @floatFromInt(win_height)) - 1.0;

    const ray_nds = math.Vec3{ .x = x, .y = y, .z = 1.0 };
    const ray_clip = math.Vec4{ .x = ray_nds.x, .y = ray_nds.y, .z = -1.0, .w = 1.0 };

    // Inverse Projection
    const proj = math.Mat4.perspective(math.toRadians(state.camera.fov), state.camera.aspect, state.camera.near_plane, state.camera.far_plane);
    const inv_proj = proj.invert() orelse return null;

    var ray_eye_v4 = inv_proj.mulVec4(ray_clip);
    ray_eye_v4.z = -1.0;
    ray_eye_v4.w = 0.0;

    const ray_eye = math.Vec3{ .x = ray_eye_v4.x, .y = ray_eye_v4.y, .z = ray_eye_v4.z };

    // Inverse View
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
    // Check meshes attached to this node
    if (node.mesh_count > 0 and node.mesh_indices != null) {
        const scn = &model.scene;
        // Node transform is relative to scene root. Compose with model instance transform.
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

    // Recurse children
    if (node.child_count > 0 and node.children != null) {
        var i: u32 = 0;
        while (i < node.child_count) : (i += 1) {
            if (node.children.?[i]) |child| {
                check_node_intersection(child, model, ray, closest_t, hit_model_id);
            }
        }
    }
}

pub fn update(state: *EditorState) void {
    // Mode Switching
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

    // Raycast Selection
    // Only if not interacting with gizmo and not over UI
    const want_capture = c.imgui_bridge_want_capture_mouse();
    if (!state.mouse_captured and c.imgui_bridge_is_mouse_clicked(0) and !want_capture and !selection_state.is_dragging and selection_state.hover_axis == null) {
        if (get_ray_from_mouse(state)) |ray| {
            var closest_t: f32 = std.math.floatMax(f32);
            var hit_model_id: u32 = 0;

            // Iterate all models
            if (state.model_manager.models) |models| {
                var i: u32 = 0;
                while (i < state.model_manager.model_count) : (i += 1) {
                    const model = &models[i];
                    if (!model.visible or model.is_loading) continue;

                    const scn = &model.scene;

                    // Iterate root nodes to check intersection against world-transformed meshes
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

            // Only clear selection if we clicked in the void (and not on a gizmo, which is handled above)
            // But if we clicked and didn't hit anything, we deselect
            if (hit_model_id != 0) {
                state.selected_model_id = hit_model_id;
            } else {
                state.selected_model_id = 0;
            }
        }
    }

    // Gizmos
    if (state.selected_model_id != 0) {
        draw_gizmo(state);
    }
}

fn draw_gizmo(state: *EditorState) void {
    // Find selected model
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

    // Decompose transform
    const transform_mat = math.Mat4.fromArray(model.transform);
    const transform_parts = transform_mat.decompose();
    const pos = transform_parts.t;
    const rot = transform_parts.r;
    const scale_vec = transform_parts.s;

    // Gizmo Logic
    const view = math.Mat4.lookAt(state.camera.position, state.camera.target, state.camera.up);
    const proj = math.Mat4.perspective(math.toRadians(state.camera.fov), state.camera.aspect, state.camera.near_plane, state.camera.far_plane);
    const view_proj = proj.mul(view);

    // Screen position of the model center
    const screen_pos_v4 = view_proj.mulVec4(math.Vec4{ .x = pos.x, .y = pos.y, .z = pos.z, .w = 1.0 });
    if (screen_pos_v4.w <= 0) return; // Behind camera

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
