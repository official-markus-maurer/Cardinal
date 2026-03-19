//! Inspector panel.
//!
//! Displays selected entity details and exposes component editing.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const components = engine.ecs_components;
const renderer = engine.vulkan_renderer;
const types = engine.vulkan_types;
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

fn enum_item_array(comptime E: type) [std.meta.tags(E).len][*:0]const u8 {
    const tags = std.meta.tags(E);
    comptime var items: [tags.len][*:0]const u8 = undefined;
    inline for (tags, 0..) |t, i| {
        items[i] = (@tagName(t) ++ "\x00").ptr;
    }
    return items;
}

fn reflect_edit_component_fields(comptime T: type, value: *T, out_any_item_active: ?*bool) bool {
    var changed = false;
    const info = @typeInfo(T);
    if (info != .@"struct") return false;

    inline for (info.@"struct".fields) |field| {
        const FieldType = field.type;
        if (@typeInfo(FieldType) == .pointer) continue;
        if (@typeInfo(FieldType) == .@"fn") continue;

        if (comptime T == components.Terrain) {
            if (comptime (std.mem.eql(u8, field.name, "model_id") or std.mem.eql(u8, field.name, "mesh_index") or std.mem.eql(u8, field.name, "data_id"))) continue;
        }
        if (comptime T == components.MeshRenderer) {
            if (comptime (std.mem.eql(u8, field.name, "mesh") or std.mem.eql(u8, field.name, "material"))) continue;
        }

        const label = comptime field.name ++ "\x00";

        if (FieldType == bool) {
            var v: bool = @field(value.*, field.name);
            if (c.imgui_bridge_checkbox(label.ptr, &v)) {
                @field(value.*, field.name) = v;
                changed = true;
            }
            if (out_any_item_active) |p| {
                if (c.imgui_bridge_is_item_active()) p.* = true;
            }
            continue;
        }

        if (FieldType == f32) {
            var v: f32 = @field(value.*, field.name);
            if (c.imgui_bridge_drag_float(label.ptr, &v, 0.05, 0.0, 0.0, "%.3f", 0)) {
                @field(value.*, field.name) = v;
                changed = true;
            }
            if (out_any_item_active) |p| {
                if (c.imgui_bridge_is_item_active()) p.* = true;
            }
            continue;
        }

        if (FieldType == u32) {
            var tmp: c_int = @intCast(@field(value.*, field.name));
            if (c.imgui_bridge_drag_int(label.ptr, &tmp, 0.5, 0, std.math.maxInt(c_int), "%d", 0)) {
                @field(value.*, field.name) = @intCast(@max(0, tmp));
                changed = true;
            }
            if (out_any_item_active) |p| {
                if (c.imgui_bridge_is_item_active()) p.* = true;
            }
            continue;
        }

        if (FieldType == math.Vec2) {
            var v: [2]f32 = .{ @field(value.*, field.name).x, @field(value.*, field.name).y };
            if (c.imgui_bridge_drag_float2(label.ptr, &v, 0.05, 0.0, 0.0, "%.3f", 0)) {
                @field(value.*, field.name) = .{ .x = v[0], .y = v[1] };
                changed = true;
            }
            if (out_any_item_active) |p| {
                if (c.imgui_bridge_is_item_active()) p.* = true;
            }
            continue;
        }

        if (FieldType == math.Vec3) {
            var v: [3]f32 = .{ @field(value.*, field.name).x, @field(value.*, field.name).y, @field(value.*, field.name).z };
            if (comptime std.mem.indexOf(u8, field.name, "color") != null) {
                if (c.imgui_bridge_color_edit3(label.ptr, &v, 0)) {
                    @field(value.*, field.name) = .{ .x = v[0], .y = v[1], .z = v[2] };
                    changed = true;
                }
            } else {
                if (c.imgui_bridge_drag_float3(label.ptr, &v, 0.05, 0.0, 0.0, "%.3f", 0)) {
                    @field(value.*, field.name) = .{ .x = v[0], .y = v[1], .z = v[2] };
                    changed = true;
                }
            }
            if (out_any_item_active) |p| {
                if (c.imgui_bridge_is_item_active()) p.* = true;
            }
            continue;
        }

        if (@typeInfo(FieldType) == .@"enum") {
            const items = comptime enum_item_array(FieldType);
            const tags = std.meta.tags(FieldType);
            const current_tag = @field(value.*, field.name);
            var idx: c_int = 0;
            inline for (tags, 0..) |t, i| {
                if (t == current_tag) idx = @intCast(i);
            }
            if (c.imgui_bridge_combo(label.ptr, &idx, &items, @intCast(items.len), @intCast(items.len))) {
                @field(value.*, field.name) = tags[@intCast(std.math.clamp(idx, 0, @as(c_int, @intCast(tags.len - 1))))];
                changed = true;
            }
            if (out_any_item_active) |p| {
                if (c.imgui_bridge_is_item_active()) p.* = true;
            }
            continue;
        }
    }

    return changed;
}

fn draw_editor_globals(state: *EditorState, g: *components.EditorGlobals) void {
    if (!c.imgui_bridge_collapsing_header("Globals", c.ImGuiTreeNodeFlags_DefaultOpen)) return;

    if (c.imgui_bridge_collapsing_header("Camera", c.ImGuiTreeNodeFlags_DefaultOpen)) {
        var pos = [3]f32{ g.camera_position.x, g.camera_position.y, g.camera_position.z };
        if (c.imgui_bridge_drag_float3("Position##Globals", &pos, 0.1, 0.0, 0.0, "%.3f", 0)) {
            g.camera_position = .{ .x = pos[0], .y = pos[1], .z = pos[2] };
        }

        var tgt = [3]f32{ g.camera_target.x, g.camera_target.y, g.camera_target.z };
        if (c.imgui_bridge_drag_float3("Target##Globals", &tgt, 0.1, 0.0, 0.0, "%.3f", 0)) {
            g.camera_target = .{ .x = tgt[0], .y = tgt[1], .z = tgt[2] };
        }

        var up = [3]f32{ g.camera_up.x, g.camera_up.y, g.camera_up.z };
        if (c.imgui_bridge_drag_float3("Up##Globals", &up, 0.05, 0.0, 0.0, "%.3f", 0)) {
            g.camera_up = .{ .x = up[0], .y = up[1], .z = up[2] };
        }

        _ = c.imgui_bridge_slider_float("FOV##Globals", &g.camera_fov, 10.0, 120.0, "%.1f");
        _ = c.imgui_bridge_drag_float("Aspect##Globals", &g.camera_aspect, 0.01, 0.1, 10.0, "%.3f", 0);
        _ = c.imgui_bridge_drag_float("Near##Globals", &g.camera_near, 0.01, 0.001, 1000.0, "%.3f", 0);
        _ = c.imgui_bridge_drag_float("Far##Globals", &g.camera_far, 1.0, 0.01, 100000.0, "%.3f", 0);
    }

    if (c.imgui_bridge_collapsing_header("Panels", 0)) {
        _ = c.imgui_bridge_checkbox("Scene View", &g.show_scene_view);
        _ = c.imgui_bridge_checkbox("Scene Graph", &g.show_scene_graph);
        _ = c.imgui_bridge_checkbox("Assets", &g.show_assets);
        _ = c.imgui_bridge_checkbox("Model Manager", &g.show_model_manager);
        _ = c.imgui_bridge_checkbox("Inspector", &g.show_entity_inspector);
        _ = c.imgui_bridge_checkbox("Scene Manager", &g.show_scene_manager);
        _ = c.imgui_bridge_checkbox("PBR Settings", &g.show_pbr_settings);
        _ = c.imgui_bridge_checkbox("Animation", &g.show_animation);
        _ = c.imgui_bridge_checkbox("Terrain", &g.show_terrain_panel);
        _ = c.imgui_bridge_checkbox("Performance", &g.show_performance_panel);
        if (c.imgui_bridge_checkbox("Grid & Axes", &g.show_grid_axes)) {
            renderer.cardinal_renderer_set_debug_grid(state.runtime.renderer, g.show_grid_axes);
        }
    }

    if (c.imgui_bridge_collapsing_header("Game Camera", 0)) {
        if (g.game_camera_entity_id != std.math.maxInt(u64)) {
            const ent = engine.ecs_entity.Entity{ .id = g.game_camera_entity_id };
            if (state.runtime.registry.entity_manager.is_alive(ent)) {
                if (state.runtime.registry.get(components.Name, ent)) |n| {
                    c.imgui_bridge_text("Camera: %s", @as([*:0]const u8, @ptrCast(&n.value)));
                } else {
                    c.imgui_bridge_text("Camera Entity: %d", ent.index());
                }
            } else {
                c.imgui_bridge_text("Camera: (missing)");
            }
        } else {
            c.imgui_bridge_text("Camera: (auto)");
        }

        if (c.imgui_bridge_button("Use Selected Camera")) {
            const ent = state.ui.selected_entity;
            if (state.runtime.registry.entity_manager.is_alive(ent) and state.runtime.registry.get(components.Camera, ent) != null) {
                g.game_camera_entity_id = ent.id;
            }
        }
        c.imgui_bridge_same_line(0, -1);
        if (c.imgui_bridge_button("Clear")) {
            g.game_camera_entity_id = std.math.maxInt(u64);
        }
    }

    if (c.imgui_bridge_collapsing_header("Rendering", c.ImGuiTreeNodeFlags_DefaultOpen)) {
        if (c.imgui_bridge_checkbox("Enable PBR Rendering", &g.pbr_enabled)) {
            state.runtime.pbr_enabled = g.pbr_enabled;
            renderer.cardinal_renderer_enable_pbr(state.runtime.renderer, state.runtime.pbr_enabled);
            if (state.runtime.pbr_enabled) {
                renderer.cardinal_renderer_set_camera(state.runtime.renderer, &state.runtime.camera);
                renderer.cardinal_renderer_set_lighting(state.runtime.renderer, &state.runtime.light);
            }
        }

        const items = [_][*:0]const u8{ "Normal", "UV Visualization", "Wireframe", "Mesh Shader" };
        var current_item: i32 = @intCast(@min(g.rendering_mode, 3));
        if (c.imgui_bridge_combo("Mode", &current_item, &items[0], @intCast(items.len), -1)) {
            g.rendering_mode = @intCast(@max(0, current_item));
            const mode: types.CardinalRenderingMode = switch (current_item) {
                0 => .NORMAL,
                1 => .UV,
                2 => .WIREFRAME,
                3 => .MESH_SHADER,
                else => .NORMAL,
            };
            renderer.cardinal_renderer_set_rendering_mode(state.runtime.renderer, mode);
        }
    }

    if (c.imgui_bridge_collapsing_header("Post Process", c.ImGuiTreeNodeFlags_DefaultOpen)) {
        var pp_changed = false;
        if (c.imgui_bridge_slider_float("Exposure", &g.post_exposure, 0.1, 10.0, "%.2f")) pp_changed = true;
        if (c.imgui_bridge_slider_float("Contrast", &g.post_contrast, 0.1, 3.0, "%.2f")) pp_changed = true;
        if (c.imgui_bridge_slider_float("Saturation", &g.post_saturation, 0.0, 3.0, "%.2f")) pp_changed = true;
        c.imgui_bridge_separator();
        c.imgui_bridge_text("Bloom");
        if (c.imgui_bridge_slider_float("Bloom Intensity", &g.post_bloom_intensity, 0.0, 1.0, "%.3f")) pp_changed = true;
        if (c.imgui_bridge_slider_float("Threshold", &g.post_bloom_threshold, 0.0, 5.0, "%.2f")) pp_changed = true;
        if (c.imgui_bridge_slider_float("Knee", &g.post_bloom_knee, 0.0, 1.0, "%.2f")) pp_changed = true;

        if (pp_changed) {
            state.runtime.post_process.exposure = g.post_exposure;
            state.runtime.post_process.contrast = g.post_contrast;
            state.runtime.post_process.saturation = g.post_saturation;
            state.runtime.post_process.bloomIntensity = g.post_bloom_intensity;
            state.runtime.post_process.bloomThreshold = g.post_bloom_threshold;
            state.runtime.post_process.bloomKnee = g.post_bloom_knee;
            renderer.cardinal_renderer_set_post_process_params(state.runtime.renderer, &state.runtime.post_process);
        }
    }

    state.runtime.camera.position = g.camera_position;
    state.runtime.camera.target = g.camera_target;
    state.runtime.camera.up = g.camera_up;
    state.runtime.camera.fov = g.camera_fov;
    state.runtime.camera.aspect = g.camera_aspect;
    state.runtime.camera.near_plane = g.camera_near;
    state.runtime.camera.far_plane = g.camera_far;

    state.ui.show_scene_view = g.show_scene_view;
    g.show_game_view = false;
    state.ui.show_game_view = false;
    state.ui.show_scene_graph = g.show_scene_graph;
    state.ui.show_assets = g.show_assets;
    state.ui.show_model_manager = g.show_model_manager;
    state.ui.show_entity_inspector = g.show_entity_inspector;
    state.ui.show_scene_manager = g.show_scene_manager;
    state.ui.show_pbr_settings = g.show_pbr_settings;
    state.ui.show_animation = g.show_animation;
    state.ui.show_terrain_panel = g.show_terrain_panel;
    state.ui.show_grid_axes = g.show_grid_axes;
    state.ui.show_performance_panel = g.show_performance_panel;
    g.enable_viewports = false;
    state.ui.enable_viewports = false;
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

    if (state.runtime.registry.get(components.EditorGlobals, entity)) |g| {
        draw_editor_globals(state, g);
    }

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

            const before = mr.*;
            var any_item_active = false;
            if (reflect_edit_component_fields(components.MeshRenderer, mr, &any_item_active)) {
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

    if (state.runtime.registry.get(components.Node, entity)) |node| {
        if (c.imgui_bridge_collapsing_header("Node", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Node")) {
                const before = node.*;
                state.ui.undo.push(.{ .EntityNode = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = false,
                    .before = before,
                    .after = std.mem.zeroes(components.Node),
                } });
                state.runtime.registry.remove(components.Node, entity);
                return;
            }

            const before = node.*;
            var any_item_active = false;
            if (reflect_edit_component_fields(components.Node, node, &any_item_active)) {
                state.ui.undo.push(.{ .EntityNode = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = node.*,
                } });
                state.runtime.pending_scene = state.runtime.combined_scene;
                state.runtime.scene_upload_pending = true;
                state.runtime.picking_cache_dirty = true;
            }
        }
    }

    if (state.runtime.registry.get(components.Terrain, entity)) |terr| {
        if (c.imgui_bridge_collapsing_header("Terrain", 0)) {
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Remove##Terrain")) {
                const before = terr.*;
                state.ui.undo.push(.{ .EntityTerrain = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = false,
                    .before = before,
                    .after = std.mem.zeroes(components.Terrain),
                } });
                state.runtime.registry.remove(components.Terrain, entity);
                return;
            }

            const before = terr.*;
            var any_item_active = false;
            if (reflect_edit_component_fields(components.Terrain, terr, &any_item_active)) {
                state.ui.undo.push(.{ .EntityTerrain = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = terr.*,
                } });
                state.runtime.pending_scene = state.runtime.combined_scene;
                state.runtime.scene_upload_pending = true;
                state.runtime.picking_cache_dirty = true;
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
            const before = l.*;
            var any_item_active = false;
            const changed = reflect_edit_component_fields(components.Light, l, &any_item_active);
            if (any_item_active) {
                state.ui.undo.begin_entity_light(entity.id, before);
            }
            if (changed and !any_item_active and !c.imgui_bridge_is_any_item_active()) {
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
            const before = cam.*;
            var any_item_active = false;
            const changed = reflect_edit_component_fields(components.Camera, cam, &any_item_active);
            if (any_item_active) {
                state.ui.undo.begin_entity_camera(entity.id, before);
            }
            if (changed and !any_item_active and !c.imgui_bridge_is_any_item_active()) {
                state.ui.undo.push(.{ .EntityCamera = .{
                    .entity_id = entity.id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = cam.*,
                } });
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
            if (c.imgui_bridge_begin_drag_drop_target()) {
                if (c.imgui_bridge_accept_drag_drop_payload("ASSET_PATH", 0)) |payload| {
                    const data_ptr = c.imgui_bridge_payload_get_data(payload);
                    if (data_ptr != null) {
                        const path_c: [*:0]const u8 = @ptrCast(@alignCast(data_ptr));
                        const path = std.mem.span(path_c);
                        const ext = std.fs.path.extension(path);
                        if (std.mem.eql(u8, ext, ".hdr") or std.mem.eql(u8, ext, ".exr")) {
                            const len = @min(path.len, state.ui.inspector_skybox_buffer.len - 1);
                            @memcpy(state.ui.inspector_skybox_buffer[0..len], path[0..len]);
                            state.ui.inspector_skybox_buffer[len] = 0;
                            state.runtime.registry.add(entity, components.Skybox.init(path)) catch {};
                        }
                    }
                }
                c.imgui_bridge_end_drag_drop_target();
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
