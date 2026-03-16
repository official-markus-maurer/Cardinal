//! Inspector panel.
//!
//! Displays selected entity details and exposes component editing.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const components = engine.ecs_components;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;

fn wrap_angle_deg_180(angle_deg: f32) f32 {
    return angle_deg - 360.0 * std.math.floor((angle_deg + 180.0) / 360.0);
}

fn unwrap_angle_deg(prev_deg: f32, curr_deg: f32) f32 {
    var curr = wrap_angle_deg_180(curr_deg);
    var delta = curr - prev_deg;

    while (delta > 180.0) {
        curr -= 360.0;
        delta -= 360.0;
    }

    while (delta < -180.0) {
        curr += 360.0;
        delta += 360.0;
    }

    return curr;
}

fn unwrap_euler_deg(prev_deg: [3]f32, curr_deg: [3]f32) [3]f32 {
    return .{
        unwrap_angle_deg(prev_deg[0], curr_deg[0]),
        unwrap_angle_deg(prev_deg[1], curr_deg[1]),
        unwrap_angle_deg(prev_deg[2], curr_deg[2]),
    };
}

fn quat_to_euler_xyz_deg(q: math.Quat) [3]f32 {
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

    return .{
        wrap_angle_deg_180(math.toDegrees(roll_x)),
        wrap_angle_deg_180(math.toDegrees(pitch_y)),
        wrap_angle_deg_180(math.toDegrees(yaw_z)),
    };
}

fn euler_xyz_deg_to_quat(euler_deg: [3]f32) math.Quat {
    const roll = math.toRadians(wrap_angle_deg_180(euler_deg[0]));
    const pitch = math.toRadians(wrap_angle_deg_180(euler_deg[1]));
    const yaw = math.toRadians(wrap_angle_deg_180(euler_deg[2]));

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
    if (state.ui.inspector_last_entity_id == entity.id) return;
    state.ui.inspector_last_entity_id = entity.id;
    state.ui.inspector_rotation_editing = false;

    @memset(&state.ui.inspector_node_type_search, 0);
    @memset(&state.ui.inspector_add_component_search, 0);

    @memset(&state.ui.inspector_name_buffer, 0);
    if (state.runtime.registry.get(components.Name, entity)) |n| {
        const s = n.slice();
        const len = @min(s.len, state.ui.inspector_name_buffer.len - 1);
        @memcpy(state.ui.inspector_name_buffer[0..len], s[0..len]);
        state.ui.inspector_name_buffer[len] = 0;
    }

    @memset(&state.ui.inspector_skybox_buffer, 0);
    if (state.runtime.registry.get(components.Skybox, entity)) |sb| {
        const s = sb.slice();
        const len = @min(s.len, state.ui.inspector_skybox_buffer.len - 1);
        @memcpy(state.ui.inspector_skybox_buffer[0..len], s[0..len]);
        state.ui.inspector_skybox_buffer[len] = 0;
    }

    if (state.runtime.registry.get(components.Transform, entity)) |t| {
        state.ui.inspector_rotation_euler_deg = quat_to_euler_xyz_deg(t.rotation);
    } else {
        state.ui.inspector_rotation_euler_deg = .{ 0.0, 0.0, 0.0 };
    }
}

fn buffer_slice(buf: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..len];
}

fn draw_entity_inspector_panel(state: *EditorState) void {
    if (!state.ui.show_entity_inspector) return;
    const open = c.imgui_bridge_begin("Inspector", &state.ui.show_entity_inspector, 0);
    defer c.imgui_bridge_end();
    if (!open) return;

    if (state.ui.selected_entity.id == std.math.maxInt(u64)) {
        c.imgui_bridge_text("No entity selected");
        c.imgui_bridge_text_wrapped("Select an entity from the Scene Graph to edit its properties.");
        return;
    }

    const entity = state.ui.selected_entity;
    sync_entity_buffers(state, entity);

    c.imgui_bridge_text("Entity: %d", entity.index());

    if (c.imgui_bridge_collapsing_header("Components", 0)) {
        if (c.imgui_bridge_button("Add Component...")) {
            c.imgui_bridge_open_popup("add_component_popup");
        }

        if (c.imgui_bridge_begin_popup("add_component_popup", 0)) {
            _ = c.imgui_bridge_input_text_with_hint("##add_component_search", "Search components...", @ptrCast(&state.ui.inspector_add_component_search), state.ui.inspector_add_component_search.len);
            const query = buffer_slice(&state.ui.inspector_add_component_search);

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
                        if (state.runtime.registry.get(components.Camera, entity) == null) {
                            const after = components.Camera{ .type = .Perspective };
                            state.ui.undo.push(.{ .EntityCamera = .{
                                .entity_id = entity.id,
                                .before_present = false,
                                .after_present = true,
                                .before = std.mem.zeroes(components.Camera),
                                .after = after,
                            } });
                            state.runtime.registry.add(entity, after) catch {};
                        }
                        if (state.runtime.registry.get(components.Node, entity)) |n| n.type = .Camera3D;
                    } else if (std.mem.eql(u8, entry.label, "Light")) {
                        if (state.runtime.registry.get(components.Light, entity) == null) {
                            const after = components.Light{ .type = .Directional, .cast_shadows = true };
                            state.ui.undo.push(.{ .EntityLight = .{
                                .entity_id = entity.id,
                                .before_present = false,
                                .after_present = true,
                                .before = std.mem.zeroes(components.Light),
                                .after = after,
                            } });
                            state.runtime.registry.add(entity, after) catch {};
                        }
                        if (state.runtime.registry.get(components.Node, entity)) |n| n.type = .DirectionalLight3D;
                    } else if (std.mem.eql(u8, entry.label, "MeshRenderer")) {
                        if (state.runtime.registry.get(components.MeshRenderer, entity) == null) {
                            const after = components.MeshRenderer{
                                .mesh = .{ .index = 0, .generation = 0 },
                                .material = .{ .index = 0, .generation = 0 },
                                .visible = true,
                                .cast_shadows = true,
                                .receive_shadows = true,
                            };
                            state.ui.undo.push(.{ .EntityMeshRenderer = .{
                                .entity_id = entity.id,
                                .before_present = false,
                                .after_present = true,
                                .before = std.mem.zeroes(components.MeshRenderer),
                                .after = after,
                            } });
                            state.runtime.registry.add(entity, after) catch {};
                        }
                        if (state.runtime.registry.get(components.Node, entity)) |n| n.type = .MeshInstance3D;
                    } else if (std.mem.eql(u8, entry.label, "Skybox")) {
                        if (state.runtime.registry.get(components.Skybox, entity) == null) {
                            const after = components.Skybox.init(buffer_slice(&state.ui.inspector_skybox_buffer));
                            state.ui.undo.push(.{ .EntitySkybox = .{
                                .entity_id = entity.id,
                                .before_present = false,
                                .after_present = true,
                                .before = std.mem.zeroes(components.Skybox),
                                .after = after,
                            } });
                            state.runtime.registry.add(entity, after) catch {};
                        }
                        if (state.runtime.registry.get(components.Node, entity)) |n| n.type = .Skybox;
                    } else if (std.mem.eql(u8, entry.label, "Script")) {
                        if (state.runtime.registry.get(components.Script, entity) == null) {
                            state.runtime.registry.add(entity, components.Script{}) catch {};
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
        const before = if (state.runtime.registry.get(components.Name, entity)) |n| n.* else std.mem.zeroes(components.Name);
        const changed = c.imgui_bridge_input_text("##entity_name", @ptrCast(&state.ui.inspector_name_buffer), state.ui.inspector_name_buffer.len, 0);
        if (c.imgui_bridge_is_item_active()) {
            state.ui.undo.begin_entity_name(entity.id, before);
        }
        if (changed) {
            state.runtime.registry.add(entity, components.Name.init(buffer_slice(&state.ui.inspector_name_buffer))) catch {};
        }
        if (!c.imgui_bridge_is_any_item_active()) {
            if (state.runtime.registry.get(components.Name, entity)) |n| {
                state.ui.undo.end_entity_name(entity.id, n.*);
            }
        }
    }

    if (state.runtime.registry.get(components.Node, entity)) |node| {
        if (c.imgui_bridge_collapsing_header("Node", 0)) {
            var type_buf: [128]u8 = undefined;
            const type_z = std.fmt.bufPrintZ(&type_buf, "{s}", .{@tagName(node.type)}) catch unreachable;
            c.imgui_bridge_text("Type: %s", type_z.ptr);
            _ = c.imgui_bridge_input_text_with_hint("##node_type_search", "Search node types...", @ptrCast(&state.ui.inspector_node_type_search), state.ui.inspector_node_type_search.len);
            const query = buffer_slice(&state.ui.inspector_node_type_search);

            _ = c.imgui_bridge_begin_child("##node_type_list", 0, 180, true, 0);
            defer c.imgui_bridge_end_child();

            for (std.enums.values(components.NodeType)) |tag| {
                const name = @tagName(tag);
                if (query.len != 0 and std.ascii.indexOfIgnoreCase(name, query) == null) continue;

                var buf: [128]u8 = undefined;
                const label_z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch continue;
                const selected = node.type == tag;
                if (c.imgui_bridge_selectable(label_z.ptr, selected, 0)) {
                    const before = node.*;
                    node.type = tag;
                    state.ui.undo.push(.{ .EntityNode = .{
                        .entity_id = entity.id,
                        .before_present = true,
                        .after_present = true,
                        .before = before,
                        .after = node.*,
                    } });
                    if (tag == .Camera3D and state.runtime.registry.get(components.Camera, entity) == null) {
                        state.runtime.registry.add(entity, components.Camera{ .type = .Perspective }) catch {};
                    } else if (tag == .Camera2D and state.runtime.registry.get(components.Camera, entity) == null) {
                        state.runtime.registry.add(entity, components.Camera{ .type = .Orthographic }) catch {};
                    } else if ((tag == .DirectionalLight3D or tag == .PointLight3D or tag == .SpotLight3D) and state.runtime.registry.get(components.Light, entity) == null) {
                        const lt: components.LightType = if (tag == .PointLight3D) .Point else if (tag == .SpotLight3D) .Spot else .Directional;
                        state.runtime.registry.add(entity, components.Light{ .type = lt, .cast_shadows = (lt == .Directional) }) catch {};
                    } else if (tag == .Skybox and state.runtime.registry.get(components.Skybox, entity) == null) {
                        state.runtime.registry.add(entity, components.Skybox.init(buffer_slice(&state.ui.inspector_skybox_buffer))) catch {};
                    }
                }
            }
        }
    }

    if (state.runtime.registry.get(components.Transform, entity)) |t| {
        if (c.imgui_bridge_collapsing_header("Transform", 0)) {
            const any_active = c.imgui_bridge_is_any_item_active();

            const before_pos = t.*;
            var pos = [3]f32{ t.position.x, t.position.y, t.position.z };
            if (c.imgui_bridge_drag_float3("Position", &pos, 0.1, 0.0, 0.0, "%.3f", 0)) {
                t.position = .{ .x = pos[0], .y = pos[1], .z = pos[2] };
                t.dirty = true;
                state.runtime.mark_transform_override_tree(entity);
            }
            if (c.imgui_bridge_is_item_active()) {
                state.ui.undo.begin_entity_transform(entity.id, before_pos);
            }

            const before_scale = t.*;
            var scale = [3]f32{ t.scale.x, t.scale.y, t.scale.z };
            if (c.imgui_bridge_drag_float3("Scale", &scale, 0.01, 0.0, 0.0, "%.3f", 0)) {
                t.scale = .{ .x = scale[0], .y = scale[1], .z = scale[2] };
                t.dirty = true;
                state.runtime.mark_transform_override_tree(entity);
            }
            if (c.imgui_bridge_is_item_active()) {
                state.ui.undo.begin_entity_transform(entity.id, before_scale);
            }

            const before_rot = t.*;
            if (!state.ui.inspector_rotation_editing) {
                const curr = quat_to_euler_xyz_deg(t.rotation);
                state.ui.inspector_rotation_euler_deg = unwrap_euler_deg(state.ui.inspector_rotation_euler_deg, curr);
            }
            var rot_deg = state.ui.inspector_rotation_euler_deg;
            if (c.imgui_bridge_drag_float3("Rotation XYZ (deg)", &rot_deg, 0.1, 0.0, 0.0, "%.3f", 0)) {
                state.ui.inspector_rotation_euler_deg = rot_deg;
                t.rotation = euler_xyz_deg_to_quat(rot_deg);
                t.dirty = true;
                state.runtime.mark_transform_override_tree(entity);
            }
            state.ui.inspector_rotation_editing = c.imgui_bridge_is_item_active();
            if (c.imgui_bridge_is_item_active()) {
                state.ui.undo.begin_entity_transform(entity.id, before_rot);
            }

            if (!any_active and !c.imgui_bridge_is_any_item_active()) {
                state.ui.undo.end_entity_transform(entity.id, t.*);
            }
        }
    }

    if (state.runtime.registry.get(components.MeshRenderer, entity)) |mr| {
        if (c.imgui_bridge_collapsing_header("MeshRenderer", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##MeshRenderer")) {
                const before = mr.*;
                state.ui.undo.push(.{ .EntityMeshRenderer = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = false,
                    .before = before,
                    .after = std.mem.zeroes(components.MeshRenderer),
                } });
                state.runtime.registry.remove(components.MeshRenderer, entity);
                if (state.runtime.registry.get(components.Node, entity)) |n| {
                    if (n.type == .MeshInstance3D) n.type = .Node3D;
                }
                return;
            }
            c.imgui_bridge_text("Mesh Index: %d", mr.mesh.index);
            c.imgui_bridge_text("Material Index: %d", mr.material.index);
            var visible = mr.visible;
            if (c.imgui_bridge_checkbox("Visible", &visible)) {
                const before = mr.*;
                mr.visible = visible;
                state.ui.undo.push(.{ .EntityMeshRenderer = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = mr.*,
                } });
            }
            var cast_shadows = mr.cast_shadows;
            if (c.imgui_bridge_checkbox("Cast Shadows", &cast_shadows)) {
                const before = mr.*;
                mr.cast_shadows = cast_shadows;
                state.ui.undo.push(.{ .EntityMeshRenderer = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = mr.*,
                } });
            }
            var receive_shadows = mr.receive_shadows;
            if (c.imgui_bridge_checkbox("Receive Shadows", &receive_shadows)) {
                const before = mr.*;
                mr.receive_shadows = receive_shadows;
                state.ui.undo.push(.{ .EntityMeshRenderer = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = mr.*,
                } });
            }
        }
    }

    if (state.runtime.registry.get(components.Light, entity)) |l| {
        if (c.imgui_bridge_collapsing_header("Light", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Light")) {
                const before = l.*;
                state.ui.undo.push(.{ .EntityLight = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = false,
                    .before = before,
                    .after = std.mem.zeroes(components.Light),
                } });
                state.runtime.registry.remove(components.Light, entity);
                if (state.runtime.registry.get(components.Node, entity)) |n| {
                    if (n.type == .DirectionalLight3D or n.type == .PointLight3D or n.type == .SpotLight3D) n.type = .Node3D;
                }
                return;
            }

            const any_active = c.imgui_bridge_is_any_item_active();

            const items = [_][*:0]const u8{ "Directional", "Point", "Spot" };
            var current: c_int = switch (l.type) {
                .Directional => 0,
                .Point => 1,
                .Spot => 2,
            };
            if (c.imgui_bridge_combo("Type", &current, &items, items.len, items.len)) {
                const before = l.*;
                l.type = switch (current) {
                    0 => .Directional,
                    1 => .Point,
                    else => .Spot,
                };
                state.ui.undo.push(.{ .EntityLight = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = l.*,
                } });
            }

            var color = [3]f32{ l.color.x, l.color.y, l.color.z };
            if (c.imgui_bridge_color_edit3("Color", &color, 0)) {
                const before = l.*;
                l.color = .{ .x = color[0], .y = color[1], .z = color[2] };
                if (c.imgui_bridge_is_item_active()) {
                    state.ui.undo.begin_entity_light(entity.id, before);
                }
            }

            {
                const before = l.*;
                _ = c.imgui_bridge_drag_float("Intensity", &l.intensity, 0.01, 0.0, 1000.0, "%.3f", 0);
                if (c.imgui_bridge_is_item_active()) state.ui.undo.begin_entity_light(entity.id, before);
            }
            {
                const before = l.*;
                _ = c.imgui_bridge_drag_float("Range", &l.range, 0.1, 0.0, 10000.0, "%.3f", 0);
                if (c.imgui_bridge_is_item_active()) state.ui.undo.begin_entity_light(entity.id, before);
            }
            {
                const before = l.*;
                _ = c.imgui_bridge_drag_float("Inner Cone", &l.inner_cone_angle, 0.01, 0.0, 3.14, "%.3f", 0);
                if (c.imgui_bridge_is_item_active()) state.ui.undo.begin_entity_light(entity.id, before);
            }
            {
                const before = l.*;
                _ = c.imgui_bridge_drag_float("Outer Cone", &l.outer_cone_angle, 0.01, 0.0, 3.14, "%.3f", 0);
                if (c.imgui_bridge_is_item_active()) state.ui.undo.begin_entity_light(entity.id, before);
            }

            var cast_shadows = l.cast_shadows;
            if (c.imgui_bridge_checkbox("Cast Shadows", &cast_shadows)) {
                const before = l.*;
                l.cast_shadows = cast_shadows;
                state.ui.undo.push(.{ .EntityLight = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = l.*,
                } });
            }

            if (!any_active and !c.imgui_bridge_is_any_item_active()) {
                state.ui.undo.end_entity_light(entity.id, l.*);
            }
        }
    }

    if (state.runtime.registry.get(components.Camera, entity)) |cam| {
        if (c.imgui_bridge_collapsing_header("Camera", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Camera")) {
                const before = cam.*;
                state.ui.undo.push(.{ .EntityCamera = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = false,
                    .before = before,
                    .after = std.mem.zeroes(components.Camera),
                } });
                state.runtime.registry.remove(components.Camera, entity);
                if (state.runtime.registry.get(components.Node, entity)) |n| {
                    if (n.type == .Camera3D or n.type == .Camera2D) n.type = .Node3D;
                }
                return;
            }
            const any_active = c.imgui_bridge_is_any_item_active();
            const items = [_][*:0]const u8{ "Perspective", "Orthographic" };
            var current: c_int = switch (cam.type) {
                .Perspective => 0,
                .Orthographic => 1,
            };
            if (c.imgui_bridge_combo("Type", &current, &items, items.len, items.len)) {
                const before = cam.*;
                cam.type = if (current == 0) .Perspective else .Orthographic;
                state.ui.undo.push(.{ .EntityCamera = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = cam.*,
                } });
            }

            {
                const before = cam.*;
                _ = c.imgui_bridge_drag_float("FOV", &cam.fov, 0.1, 1.0, 179.0, "%.2f", 0);
                if (c.imgui_bridge_is_item_active()) state.ui.undo.begin_entity_camera(entity.id, before);
            }
            {
                const before = cam.*;
                _ = c.imgui_bridge_drag_float("Aspect", &cam.aspect_ratio, 0.01, 0.1, 10.0, "%.3f", 0);
                if (c.imgui_bridge_is_item_active()) state.ui.undo.begin_entity_camera(entity.id, before);
            }
            {
                const before = cam.*;
                _ = c.imgui_bridge_drag_float("Near", &cam.near_plane, 0.01, 0.001, 1000.0, "%.3f", 0);
                if (c.imgui_bridge_is_item_active()) state.ui.undo.begin_entity_camera(entity.id, before);
            }
            {
                const before = cam.*;
                _ = c.imgui_bridge_drag_float("Far", &cam.far_plane, 1.0, 0.01, 100000.0, "%.3f", 0);
                if (c.imgui_bridge_is_item_active()) state.ui.undo.begin_entity_camera(entity.id, before);
            }
            {
                const before = cam.*;
                _ = c.imgui_bridge_drag_float("Ortho Size", &cam.ortho_size, 0.1, 0.01, 100000.0, "%.3f", 0);
                if (c.imgui_bridge_is_item_active()) state.ui.undo.begin_entity_camera(entity.id, before);
            }

            if (!any_active and !c.imgui_bridge_is_any_item_active()) {
                state.ui.undo.end_entity_camera(entity.id, cam.*);
            }
        }
    }

    if (state.runtime.registry.get(components.Skybox, entity)) |sb| {
        if (c.imgui_bridge_collapsing_header("Skybox", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Skybox")) {
                const before = sb.*;
                state.ui.undo.push(.{ .EntitySkybox = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = false,
                    .before = before,
                    .after = std.mem.zeroes(components.Skybox),
                } });
                state.runtime.registry.remove(components.Skybox, entity);
                if (state.runtime.registry.get(components.Node, entity)) |n| {
                    if (n.type == .Skybox) n.type = .Node3D;
                }
                return;
            }
            const before = sb.*;
            const changed = c.imgui_bridge_input_text("Path", @ptrCast(&state.ui.inspector_skybox_buffer), state.ui.inspector_skybox_buffer.len, 0);
            if (c.imgui_bridge_is_item_active()) {
                state.ui.undo.begin_entity_skybox(entity.id, before);
            }
            if (changed) {
                state.runtime.registry.add(entity, components.Skybox.init(buffer_slice(&state.ui.inspector_skybox_buffer))) catch {};
            }
            if (!c.imgui_bridge_is_any_item_active()) {
                if (state.runtime.registry.get(components.Skybox, entity)) |s| {
                    state.ui.undo.end_entity_skybox(entity.id, s.*);
                }
            }

            if (sb.slice().len != 0) {
                c.imgui_bridge_text_wrapped("%s", sb.slice().ptr);
            }
        }
    }

    if (state.runtime.registry.get(components.Script, entity)) |_| {
        if (c.imgui_bridge_collapsing_header("Script", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Script")) {
                state.runtime.registry.remove(components.Script, entity);
                return;
            }
            c.imgui_bridge_text_wrapped("Script component attached.");
        }
    }
}

pub fn draw_inspector_panel(state: *EditorState) void {
    draw_entity_inspector_panel(state);
}
