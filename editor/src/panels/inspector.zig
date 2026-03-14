//! Inspector panel.
//!
//! Displays selected model details and exposes basic visibility/removal controls.
//!
//! TODO: Replace the simplified scale editor with full TRS editing.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const model_manager = engine.model_manager;
const renderer = engine.vulkan_renderer;
const components = engine.ecs_components;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;

fn quat_to_euler_deg(q: math.Quat) [3]f32 {
    const qq = q.normalize();

    const two: f32 = 2.0;
    const one: f32 = 1.0;

    const sinr_cosp: f32 = two * (qq.w * qq.x + qq.y * qq.z);
    const cosr_cosp: f32 = one - two * (qq.x * qq.x + qq.y * qq.y);
    const roll_x = std.math.atan2(sinr_cosp, cosr_cosp);

    const sinp: f32 = two * (qq.w * qq.y - qq.z * qq.x);
    const half_pi: f32 = @as(f32, std.math.pi) / 2.0;
    const pitch_y = if (@abs(sinp) >= one) std.math.copysign(half_pi, sinp) else std.math.asin(sinp);

    const siny_cosp: f32 = two * (qq.w * qq.z + qq.x * qq.y);
    const cosy_cosp: f32 = one - two * (qq.y * qq.y + qq.z * qq.z);
    const yaw_z = std.math.atan2(siny_cosp, cosy_cosp);

    return .{ math.toDegrees(roll_x), math.toDegrees(pitch_y), math.toDegrees(yaw_z) };
}

fn euler_deg_to_quat(euler_deg: [3]f32) math.Quat {
    const roll = math.toRadians(euler_deg[0]);
    const pitch = math.toRadians(euler_deg[1]);
    const yaw = math.toRadians(euler_deg[2]);

    const half: f32 = 0.5;
    const cy = std.math.cos(yaw * half);
    const sy = std.math.sin(yaw * half);
    const cp = std.math.cos(pitch * half);
    const sp = std.math.sin(pitch * half);
    const cr = std.math.cos(roll * half);
    const sr = std.math.sin(roll * half);

    return (math.Quat{
        .x = sr * cp * cy - cr * sp * sy,
        .y = cr * sp * cy + sr * cp * sy,
        .z = cr * cp * sy - sr * sp * cy,
        .w = cr * cp * cy + sr * sp * sy,
    }).normalize();
}

fn sync_entity_buffers(state: *EditorState, entity: engine.ecs_entity.Entity) void {
    if (state.inspector_last_entity_id == entity.id) return;
    state.inspector_last_entity_id = entity.id;

    @memset(&state.inspector_node_type_search, 0);
    @memset(&state.inspector_add_component_search, 0);

    @memset(&state.inspector_name_buffer, 0);
    if (state.registry.get(components.Name, entity)) |n| {
        const s = n.slice();
        const len = @min(s.len, state.inspector_name_buffer.len - 1);
        @memcpy(state.inspector_name_buffer[0..len], s[0..len]);
        state.inspector_name_buffer[len] = 0;
    }

    @memset(&state.inspector_skybox_buffer, 0);
    if (state.registry.get(components.Skybox, entity)) |sb| {
        const s = sb.slice();
        const len = @min(s.len, state.inspector_skybox_buffer.len - 1);
        @memcpy(state.inspector_skybox_buffer[0..len], s[0..len]);
        state.inspector_skybox_buffer[len] = 0;
    }

    if (state.registry.get(components.Transform, entity)) |t| {
        state.inspector_rotation_euler_deg = quat_to_euler_deg(t.rotation);
    } else {
        state.inspector_rotation_euler_deg = .{ 0.0, 0.0, 0.0 };
    }
}

fn buffer_slice(buf: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..len];
}

fn draw_entity_inspector_panel(state: *EditorState) void {
    if (!state.show_entity_inspector) return;
    const open = c.imgui_bridge_begin("Inspector", &state.show_entity_inspector, 0);
    defer c.imgui_bridge_end();
    if (!open) return;

    if (state.selected_entity.id == std.math.maxInt(u64)) {
        c.imgui_bridge_text("No entity selected");
        c.imgui_bridge_text_wrapped("Select an entity from the Scene Graph to edit its properties.");
        return;
    }

    const entity = state.selected_entity;
    sync_entity_buffers(state, entity);

    c.imgui_bridge_text("Entity: %d", entity.index());

    if (c.imgui_bridge_collapsing_header("Components", 0)) {
        if (c.imgui_bridge_button("Add Component...")) {
            c.imgui_bridge_open_popup("add_component_popup");
        }

        if (c.imgui_bridge_begin_popup("add_component_popup", 0)) {
            _ = c.imgui_bridge_input_text_with_hint("##add_component_search", "Search components...", @ptrCast(&state.inspector_add_component_search), state.inspector_add_component_search.len);
            const query = buffer_slice(&state.inspector_add_component_search);

            _ = c.imgui_bridge_begin_child("##add_component_list", 360, 180, true, 0);
            defer c.imgui_bridge_end_child();

            const Entry = struct { label: []const u8 };
            const entries = [_]Entry{
                .{ .label = "Camera" },
                .{ .label = "Light" },
                .{ .label = "MeshRenderer" },
                .{ .label = "Skybox" },
                .{ .label = "Script" },
            };

            for (entries) |entry| {
                if (query.len != 0 and std.ascii.indexOfIgnoreCase(entry.label, query) == null) continue;

                var buf: [64]u8 = undefined;
                const label_z = std.fmt.bufPrintZ(&buf, "{s}", .{entry.label}) catch continue;
                if (c.imgui_bridge_selectable(label_z.ptr, false, 0)) {
                    if (std.mem.eql(u8, entry.label, "Camera")) {
                        if (state.registry.get(components.Camera, entity) == null) {
                            state.registry.add(entity, components.Camera{ .type = .Perspective }) catch {};
                        }
                        if (state.registry.get(components.Node, entity)) |n| n.type = .Camera3D;
                    } else if (std.mem.eql(u8, entry.label, "Light")) {
                        if (state.registry.get(components.Light, entity) == null) {
                            state.registry.add(entity, components.Light{ .type = .Directional, .cast_shadows = true }) catch {};
                        }
                        if (state.registry.get(components.Node, entity)) |n| n.type = .DirectionalLight3D;
                    } else if (std.mem.eql(u8, entry.label, "MeshRenderer")) {
                        if (state.registry.get(components.MeshRenderer, entity) == null) {
                            state.registry.add(entity, components.MeshRenderer{
                                .mesh = .{ .index = 0, .generation = 0 },
                                .material = .{ .index = 0, .generation = 0 },
                                .visible = true,
                                .cast_shadows = true,
                                .receive_shadows = true,
                            }) catch {};
                        }
                        if (state.registry.get(components.Node, entity)) |n| n.type = .MeshInstance3D;
                    } else if (std.mem.eql(u8, entry.label, "Skybox")) {
                        if (state.registry.get(components.Skybox, entity) == null) {
                            state.registry.add(entity, components.Skybox.init(buffer_slice(&state.inspector_skybox_buffer))) catch {};
                        }
                        if (state.registry.get(components.Node, entity)) |n| n.type = .Skybox;
                    } else if (std.mem.eql(u8, entry.label, "Script")) {
                        if (state.registry.get(components.Script, entity) == null) {
                            state.registry.add(entity, components.Script{}) catch {};
                        }
                    }

                    c.imgui_bridge_close_current_popup();
                    break;
                }
            }

            c.imgui_bridge_end_popup();
        }
    }

    if (c.imgui_bridge_collapsing_header("Name", 0)) {
        if (c.imgui_bridge_input_text("##entity_name", @ptrCast(&state.inspector_name_buffer), state.inspector_name_buffer.len, 0)) {
            state.registry.add(entity, components.Name.init(buffer_slice(&state.inspector_name_buffer))) catch {};
        }
    }

    if (state.registry.get(components.Node, entity)) |node| {
        if (c.imgui_bridge_collapsing_header("Node", 0)) {
            var type_buf: [128]u8 = undefined;
            const type_z = std.fmt.bufPrintZ(&type_buf, "{s}", .{@tagName(node.type)}) catch unreachable;
            c.imgui_bridge_text("Type: %s", type_z.ptr);
            _ = c.imgui_bridge_input_text_with_hint("##node_type_search", "Search node types...", @ptrCast(&state.inspector_node_type_search), state.inspector_node_type_search.len);
            const query = buffer_slice(&state.inspector_node_type_search);

            _ = c.imgui_bridge_begin_child("##node_type_list", 0, 180, true, 0);
            defer c.imgui_bridge_end_child();

            for (std.enums.values(components.NodeType)) |tag| {
                const name = @tagName(tag);
                if (query.len != 0 and std.ascii.indexOfIgnoreCase(name, query) == null) continue;

                var buf: [128]u8 = undefined;
                const label_z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch continue;
                const selected = node.type == tag;
                if (c.imgui_bridge_selectable(label_z.ptr, selected, 0)) {
                    node.type = tag;
                    if (tag == .Camera3D and state.registry.get(components.Camera, entity) == null) {
                        state.registry.add(entity, components.Camera{ .type = .Perspective }) catch {};
                    } else if (tag == .Camera2D and state.registry.get(components.Camera, entity) == null) {
                        state.registry.add(entity, components.Camera{ .type = .Orthographic }) catch {};
                    } else if ((tag == .DirectionalLight3D or tag == .PointLight3D or tag == .SpotLight3D) and state.registry.get(components.Light, entity) == null) {
                        const lt: components.LightType = if (tag == .PointLight3D) .Point else if (tag == .SpotLight3D) .Spot else .Directional;
                        state.registry.add(entity, components.Light{ .type = lt, .cast_shadows = (lt == .Directional) }) catch {};
                    } else if (tag == .Skybox and state.registry.get(components.Skybox, entity) == null) {
                        state.registry.add(entity, components.Skybox.init(buffer_slice(&state.inspector_skybox_buffer))) catch {};
                    }
                }
            }
        }
    }

    if (state.registry.get(components.Transform, entity)) |t| {
        if (c.imgui_bridge_collapsing_header("Transform", 0)) {
            var pos = [3]f32{ t.position.x, t.position.y, t.position.z };
            if (c.imgui_bridge_drag_float3("Position", &pos, 0.1, 0.0, 0.0, "%.3f", 0)) {
                t.position = .{ .x = pos[0], .y = pos[1], .z = pos[2] };
                t.dirty = true;
                state.mark_transform_override_tree(entity);
            }

            var scale = [3]f32{ t.scale.x, t.scale.y, t.scale.z };
            if (c.imgui_bridge_drag_float3("Scale", &scale, 0.01, 0.0, 0.0, "%.3f", 0)) {
                t.scale = .{ .x = scale[0], .y = scale[1], .z = scale[2] };
                t.dirty = true;
                state.mark_transform_override_tree(entity);
            }

            var rot_deg = state.inspector_rotation_euler_deg;
            if (c.imgui_bridge_drag_float3("Rotation (deg)", &rot_deg, 0.1, 0.0, 0.0, "%.3f", 0)) {
                state.inspector_rotation_euler_deg = rot_deg;
                t.rotation = euler_deg_to_quat(rot_deg);
                t.dirty = true;
                state.mark_transform_override_tree(entity);
            }
        }
    }

    if (state.registry.get(components.MeshRenderer, entity)) |mr| {
        if (c.imgui_bridge_collapsing_header("MeshRenderer", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##MeshRenderer")) {
                state.registry.remove(components.MeshRenderer, entity);
                if (state.registry.get(components.Node, entity)) |n| {
                    if (n.type == .MeshInstance3D) n.type = .Node3D;
                }
                return;
            }
            c.imgui_bridge_text("Mesh Index: %d", mr.mesh.index);
            c.imgui_bridge_text("Material Index: %d", mr.material.index);
            var visible = mr.visible;
            if (c.imgui_bridge_checkbox("Visible", &visible)) {
                mr.visible = visible;
            }
            var cast_shadows = mr.cast_shadows;
            if (c.imgui_bridge_checkbox("Cast Shadows", &cast_shadows)) {
                mr.cast_shadows = cast_shadows;
            }
            var receive_shadows = mr.receive_shadows;
            if (c.imgui_bridge_checkbox("Receive Shadows", &receive_shadows)) {
                mr.receive_shadows = receive_shadows;
            }
        }
    }

    if (state.registry.get(components.Light, entity)) |l| {
        if (c.imgui_bridge_collapsing_header("Light", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Light")) {
                state.registry.remove(components.Light, entity);
                if (state.registry.get(components.Node, entity)) |n| {
                    if (n.type == .DirectionalLight3D or n.type == .PointLight3D or n.type == .SpotLight3D) n.type = .Node3D;
                }
                return;
            }
            const items = [_][*:0]const u8{ "Directional", "Point", "Spot" };
            var current: c_int = switch (l.type) {
                .Directional => 0,
                .Point => 1,
                .Spot => 2,
            };
            if (c.imgui_bridge_combo("Type", &current, &items, items.len, items.len)) {
                l.type = switch (current) {
                    0 => .Directional,
                    1 => .Point,
                    else => .Spot,
                };
            }

            var color = [3]f32{ l.color.x, l.color.y, l.color.z };
            if (c.imgui_bridge_color_edit3("Color", &color, 0)) {
                l.color = .{ .x = color[0], .y = color[1], .z = color[2] };
            }

            _ = c.imgui_bridge_drag_float("Intensity", &l.intensity, 0.01, 0.0, 1000.0, "%.3f", 0);
            _ = c.imgui_bridge_drag_float("Range", &l.range, 0.1, 0.0, 10000.0, "%.3f", 0);
            _ = c.imgui_bridge_drag_float("Inner Cone", &l.inner_cone_angle, 0.01, 0.0, 3.14, "%.3f", 0);
            _ = c.imgui_bridge_drag_float("Outer Cone", &l.outer_cone_angle, 0.01, 0.0, 3.14, "%.3f", 0);

            var cast_shadows = l.cast_shadows;
            if (c.imgui_bridge_checkbox("Cast Shadows", &cast_shadows)) {
                l.cast_shadows = cast_shadows;
            }
        }
    }

    if (state.registry.get(components.Camera, entity)) |cam| {
        if (c.imgui_bridge_collapsing_header("Camera", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Camera")) {
                state.registry.remove(components.Camera, entity);
                if (state.registry.get(components.Node, entity)) |n| {
                    if (n.type == .Camera3D or n.type == .Camera2D) n.type = .Node3D;
                }
                return;
            }
            const items = [_][*:0]const u8{ "Perspective", "Orthographic" };
            var current: c_int = switch (cam.type) {
                .Perspective => 0,
                .Orthographic => 1,
            };
            if (c.imgui_bridge_combo("Type", &current, &items, items.len, items.len)) {
                cam.type = if (current == 0) .Perspective else .Orthographic;
            }

            _ = c.imgui_bridge_drag_float("FOV", &cam.fov, 0.1, 1.0, 179.0, "%.2f", 0);
            _ = c.imgui_bridge_drag_float("Aspect", &cam.aspect_ratio, 0.01, 0.1, 10.0, "%.3f", 0);
            _ = c.imgui_bridge_drag_float("Near", &cam.near_plane, 0.01, 0.001, 1000.0, "%.3f", 0);
            _ = c.imgui_bridge_drag_float("Far", &cam.far_plane, 1.0, 0.01, 100000.0, "%.3f", 0);
            _ = c.imgui_bridge_drag_float("Ortho Size", &cam.ortho_size, 0.1, 0.01, 100000.0, "%.3f", 0);
        }
    }

    if (state.registry.get(components.Skybox, entity)) |sb| {
        if (c.imgui_bridge_collapsing_header("Skybox", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Skybox")) {
                state.registry.remove(components.Skybox, entity);
                if (state.registry.get(components.Node, entity)) |n| {
                    if (n.type == .Skybox) n.type = .Node3D;
                }
                return;
            }
            if (c.imgui_bridge_input_text("Path", @ptrCast(&state.inspector_skybox_buffer), state.inspector_skybox_buffer.len, 0)) {
                state.registry.add(entity, components.Skybox.init(buffer_slice(&state.inspector_skybox_buffer))) catch {};
            }

            if (sb.slice().len != 0) {
                c.imgui_bridge_text_wrapped("%s", sb.slice().ptr);
            }
        }
    }

    if (state.registry.get(components.Script, entity)) |_| {
        if (c.imgui_bridge_collapsing_header("Script", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Script")) {
                state.registry.remove(components.Script, entity);
                return;
            }
            c.imgui_bridge_text_wrapped("Script component attached.");
        }
    }
}

pub fn draw_inspector_panel(state: *EditorState) void {
    draw_entity_inspector_panel(state);
    if (state.show_model_manager) {
        const open = c.imgui_bridge_begin("Model Manager", &state.show_model_manager, 0);
        defer c.imgui_bridge_end();

        if (open) {
            c.imgui_bridge_text("Loaded Models: %d", state.model_manager.model_count);
            c.imgui_bridge_separator();

            const model_count = state.model_manager.model_count;
            if (model_count == 0) {
                c.imgui_bridge_text("No models loaded");
                c.imgui_bridge_text_wrapped("Load models from the Assets panel to see them here.");
            } else {
                const child_visible = c.imgui_bridge_begin_child("##model_list", 0, 300, true, 0);
                defer c.imgui_bridge_end_child();

                if (child_visible) {
                    var i: u32 = 0;
                    while (i < state.model_manager.model_count) {
                        const model_ptr = model_manager.cardinal_model_manager_get_model_by_index(&state.model_manager, i);
                        if (model_ptr) |model| {
                            c.imgui_bridge_push_id_int(@intCast(model.id));

                            const is_selected = (state.selected_model_id == model.id);
                            const name = if (model.name) |n| std.mem.span(n) else "Unnamed Model";

                            const avail_w = c.imgui_bridge_get_content_region_avail_x();
                            const controls_w: f32 = 120.0;
                            const label_w = if (avail_w > controls_w) avail_w - controls_w else 10.0;

                            if (c.imgui_bridge_selectable_size(name.ptr, is_selected, 0, label_w, 0)) {
                                state.selected_model_id = model.id;
                                model_manager.cardinal_model_manager_set_selected(&state.model_manager, model.id);
                            }

                            c.imgui_bridge_same_line(0, -1);

                            var visible = model.visible;
                            if (c.imgui_bridge_checkbox("##visible", &visible)) {
                                _ = model_manager.cardinal_model_manager_set_visible(&state.model_manager, model.id, visible);
                            }
                            if (c.imgui_bridge_is_item_hovered(0)) {
                                c.imgui_bridge_set_tooltip("Toggle visibility");
                            }

                            c.imgui_bridge_same_line(0, -1);
                            if (c.imgui_bridge_button("Remove")) {
                                renderer.cardinal_renderer_clear_scene(state.renderer);
                                _ = model_manager.cardinal_model_manager_remove_model(&state.model_manager, model.id);
                                if (state.selected_model_id == model.id) {
                                    state.selected_model_id = 0;
                                }
                                if (model_manager.cardinal_model_manager_get_combined_scene(&state.model_manager)) |combined| {
                                    state.combined_scene = combined.*;
                                    state.pending_scene = state.combined_scene;
                                    state.scene_upload_pending = true;
                                    state.scene_loaded = (state.combined_scene.mesh_count > 0);
                                } else {
                                    state.scene_loaded = false;
                                }
                                state.selected_animation = -1;
                                state.animation_time = 0.0;
                                state.animation_playing = false;
                                c.imgui_bridge_pop_id();
                                continue;
                            }

                            if (is_selected) {
                                c.imgui_bridge_indent(10.0);
                                c.imgui_bridge_text("ID: %d", model.id);
                                c.imgui_bridge_text("Meshes: %d", model.scene.mesh_count);
                                c.imgui_bridge_text("Materials: %d", model.scene.material_count);
                                if (model.file_path) |fp| {
                                    c.imgui_bridge_text("Path: %s", fp);
                                }

                                c.imgui_bridge_separator();
                                c.imgui_bridge_text("Transform:");

                                var pos = [3]f32{ model.transform[12], model.transform[13], model.transform[14] };
                                if (c.imgui_bridge_drag_float3("Position", &pos, 0.1, 0.0, 0.0, "%.3f", 0)) {
                                    var new_transform: [16]f32 = undefined;
                                    @memcpy(&new_transform, &model.transform);
                                    new_transform[12] = pos[0];
                                    new_transform[13] = pos[1];
                                    new_transform[14] = pos[2];
                                    _ = model_manager.cardinal_model_manager_set_transform(&state.model_manager, model.id, &new_transform);
                                }

                                const current_scale = std.math.sqrt(model.transform[0] * model.transform[0] + model.transform[1] * model.transform[1] + model.transform[2] * model.transform[2]);
                                var scale = current_scale;
                                if (c.imgui_bridge_drag_float("Scale", &scale, 0.01, 0.01, 10.0, "%.3f", 0)) {
                                    var scale_matrix: [16]f32 = undefined;
                                    @memset(&scale_matrix, 0);
                                    scale_matrix[0] = scale;
                                    scale_matrix[5] = scale;
                                    scale_matrix[10] = scale;
                                    scale_matrix[15] = 1.0;
                                    scale_matrix[12] = pos[0];
                                    scale_matrix[13] = pos[1];
                                    scale_matrix[14] = pos[2];
                                    _ = model_manager.cardinal_model_manager_set_transform(&state.model_manager, model.id, &scale_matrix);
                                }

                                c.imgui_bridge_unindent(10.0);
                            }

                            c.imgui_bridge_pop_id();
                        }
                        i += 1;
                    }
                }
            }
        }
    }
}
