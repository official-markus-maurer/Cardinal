//! Inspector panel.
//!
//! Displays selected entity details and exposes component editing.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const components = engine.ecs_components;
const memory = engine.memory;
const renderer = engine.vulkan_renderer;
const types = engine.vulkan_types;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;
const editor_state = @import("../editor_state.zig");

var g_scene_mesh_label_cache: std.AutoHashMapUnmanaged(u32, [:0]u8) = .{};
var g_scene_mesh_label_cache_marker: u64 = 0;

fn inspector_label_allocator() std.mem.Allocator {
    return memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
}

fn reset_scene_mesh_label_cache() void {
    const alloc = inspector_label_allocator();
    var it = g_scene_mesh_label_cache.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.value_ptr.*);
    }
    g_scene_mesh_label_cache.deinit(alloc);
    g_scene_mesh_label_cache = .{};
}

fn scene_mesh_label_cache_marker(state: *EditorState) u64 {
    const ptr_val: u64 = if (state.runtime.combined_scene.meshes) |p| @intFromPtr(p) else 0;
    return (ptr_val ^ (@as(u64, state.runtime.combined_scene.mesh_count) << 32));
}

fn ensure_scene_mesh_label_cache_current(state: *EditorState) void {
    const marker = scene_mesh_label_cache_marker(state);
    if (marker == g_scene_mesh_label_cache_marker) return;
    g_scene_mesh_label_cache_marker = marker;
    reset_scene_mesh_label_cache();
}

fn scene_mesh_label(state: *EditorState, mesh_index: u32) [*:0]const u8 {
    ensure_scene_mesh_label_cache_current(state);

    var buf: [256]u8 = undefined;
    const label: [:0]const u8 = blk: {
        if (state.runtime.mesh_entity_by_mesh_index.get(mesh_index)) |id| {
            const ent = engine.ecs_entity.Entity{ .id = id };
            if (state.runtime.registry.entity_manager.is_alive(ent)) {
                if (state.runtime.registry.get(components.Name, ent)) |n| {
                    break :blk std.fmt.bufPrintZ(&buf, "{s} (mesh {d})", .{ n.slice(), mesh_index }) catch "Mesh\x00";
                }
            }
        }
        if (state.runtime.combined_scene.meshes) |meshes| {
            if (mesh_index < state.runtime.combined_scene.mesh_count) {
                const m = meshes[mesh_index];
                break :blk std.fmt.bufPrintZ(&buf, "Mesh {d} ({d} vtx, {d} idx)", .{ mesh_index, m.vertex_count, m.index_count }) catch "Mesh\x00";
            }
        }
        break :blk std.fmt.bufPrintZ(&buf, "Mesh {d}", .{mesh_index}) catch "Mesh\x00";
    };

    const alloc = inspector_label_allocator();
    const entry = g_scene_mesh_label_cache.getOrPut(alloc, mesh_index) catch return label.ptr;
    if (entry.found_existing) {
        const cached = entry.value_ptr.*;
        if (cached.len == label.len and std.mem.eql(u8, cached[0..cached.len], label[0..label.len])) {
            return cached.ptr;
        }
        alloc.free(cached);
    }

    const duped = alloc.dupeZ(u8, label) catch return label.ptr;
    entry.value_ptr.* = duped;
    return duped.ptr;
}

fn scene_material_label(state: *EditorState, material_index: u32) [*:0]const u8 {
    const alloc = state.runtime.arena_allocator;
    if (state.runtime.combined_scene.materials) |mats| {
        if (material_index < state.runtime.combined_scene.material_count) {
            const mat = mats[material_index];
            if (state.runtime.combined_scene.textures) |texs| {
                if (mat.albedo_texture.index < state.runtime.combined_scene.texture_count) {
                    const tex = texs[mat.albedo_texture.index];
                    if (tex.path) |p| {
                        const base = std.fs.path.basename(std.mem.span(p));
                        var tmp: [256]u8 = undefined;
                        const z = std.fmt.bufPrintZ(&tmp, "{s} (mat {d})", .{ base, material_index }) catch null;
                        if (z) |zs| {
                            const out = alloc.alloc(u8, zs.len + 1) catch return zs.ptr;
                            @memcpy(out[0..zs.len], zs[0..zs.len]);
                            out[zs.len] = 0;
                            return @ptrCast(out.ptr);
                        }
                    }
                }
            }
        }
    }
    var tmp: [64]u8 = undefined;
    const z = std.fmt.bufPrintZ(&tmp, "Material {d}", .{material_index}) catch null;
    if (z) |zs| {
        const out = alloc.alloc(u8, zs.len + 1) catch return zs.ptr;
        @memcpy(out[0..zs.len], zs[0..zs.len]);
        out[zs.len] = 0;
        return @ptrCast(out.ptr);
    }
    return "Material\x00".ptr;
}

fn find_material_by_texture_basename(state: *EditorState, texture_path: []const u8) ?u32 {
    const base = std.fs.path.basename(texture_path);
    if (base.len == 0) return null;
    if (state.runtime.combined_scene.materials == null or state.runtime.combined_scene.textures == null) return null;

    const mats = state.runtime.combined_scene.materials.?;
    const texs = state.runtime.combined_scene.textures.?;

    var i: u32 = 0;
    while (i < state.runtime.combined_scene.material_count) : (i += 1) {
        const mat = mats[i];
        if (mat.albedo_texture.index >= state.runtime.combined_scene.texture_count) continue;
        const tex = texs[mat.albedo_texture.index];
        if (tex.path) |p| {
            const tb = std.fs.path.basename(std.mem.span(p));
            if (std.mem.eql(u8, tb, base)) return i;
        }
    }
    return null;
}

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

fn draw_editor_globals(state: *EditorState, entity: engine.ecs_entity.Entity, g: *components.EditorGlobals) void {
    if (!c.imgui_bridge_collapsing_header("Globals", c.ImGuiTreeNodeFlags_DefaultOpen)) return;

    const any_active = c.imgui_bridge_is_any_item_active();
    g.show_game_view = false;
    g.enable_viewports = false;
    const before = g.*;
    var any_item_active = false;
    var changed = false;

    if (c.imgui_bridge_collapsing_header("Camera", c.ImGuiTreeNodeFlags_DefaultOpen)) {
        var pos = [3]f32{ g.camera_position.x, g.camera_position.y, g.camera_position.z };
        if (c.imgui_bridge_drag_float3("Position##Globals", &pos, 0.1, 0.0, 0.0, "%.3f", 0)) {
            g.camera_position = .{ .x = pos[0], .y = pos[1], .z = pos[2] };
            changed = true;
        }
        if (c.imgui_bridge_is_item_active()) any_item_active = true;

        var tgt = [3]f32{ g.camera_target.x, g.camera_target.y, g.camera_target.z };
        if (c.imgui_bridge_drag_float3("Target##Globals", &tgt, 0.1, 0.0, 0.0, "%.3f", 0)) {
            g.camera_target = .{ .x = tgt[0], .y = tgt[1], .z = tgt[2] };
            changed = true;
        }
        if (c.imgui_bridge_is_item_active()) any_item_active = true;

        var up = [3]f32{ g.camera_up.x, g.camera_up.y, g.camera_up.z };
        if (c.imgui_bridge_drag_float3("Up##Globals", &up, 0.05, 0.0, 0.0, "%.3f", 0)) {
            g.camera_up = .{ .x = up[0], .y = up[1], .z = up[2] };
            changed = true;
        }
        if (c.imgui_bridge_is_item_active()) any_item_active = true;

        if (c.imgui_bridge_slider_float("FOV##Globals", &g.camera_fov, 10.0, 120.0, "%.1f")) changed = true;
        if (c.imgui_bridge_is_item_active()) any_item_active = true;
        if (c.imgui_bridge_drag_float("Aspect##Globals", &g.camera_aspect, 0.01, 0.1, 10.0, "%.3f", 0)) changed = true;
        if (c.imgui_bridge_is_item_active()) any_item_active = true;
        if (c.imgui_bridge_drag_float("Near##Globals", &g.camera_near, 0.01, 0.001, 1000.0, "%.3f", 0)) changed = true;
        if (c.imgui_bridge_is_item_active()) any_item_active = true;
        if (c.imgui_bridge_drag_float("Far##Globals", &g.camera_far, 1.0, 0.01, 100000.0, "%.3f", 0)) changed = true;
        if (c.imgui_bridge_is_item_active()) any_item_active = true;
    }

    if (c.imgui_bridge_collapsing_header("Panels", 0)) {
        if (c.imgui_bridge_checkbox("Scene View", &g.show_scene_view)) changed = true;
        if (c.imgui_bridge_checkbox("Scene Graph", &g.show_scene_graph)) changed = true;
        if (c.imgui_bridge_checkbox("Assets", &g.show_assets)) changed = true;
        if (c.imgui_bridge_checkbox("Model Manager", &g.show_model_manager)) changed = true;
        if (c.imgui_bridge_checkbox("Inspector", &g.show_entity_inspector)) changed = true;
        if (c.imgui_bridge_checkbox("Scene Manager", &g.show_scene_manager)) changed = true;
        if (c.imgui_bridge_checkbox("PBR Settings", &g.show_pbr_settings)) changed = true;
        if (c.imgui_bridge_checkbox("Animation", &g.show_animation)) changed = true;
        if (c.imgui_bridge_checkbox("Terrain", &g.show_terrain_panel)) changed = true;
        if (c.imgui_bridge_checkbox("Performance", &g.show_performance_panel)) changed = true;
        if (c.imgui_bridge_checkbox("Grid & Axes", &g.show_grid_axes)) {
            changed = true;
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
                changed = true;
            }
        }
        c.imgui_bridge_same_line(0, -1);
        if (c.imgui_bridge_button("Clear")) {
            g.game_camera_entity_id = std.math.maxInt(u64);
            changed = true;
        }
    }

    if (c.imgui_bridge_collapsing_header("Rendering", c.ImGuiTreeNodeFlags_DefaultOpen)) {
        if (c.imgui_bridge_checkbox("Enable PBR Rendering", &g.pbr_enabled)) {
            changed = true;
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
            changed = true;
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
        if (c.imgui_bridge_is_item_active()) any_item_active = true;
        if (c.imgui_bridge_slider_float("Contrast", &g.post_contrast, 0.1, 3.0, "%.2f")) pp_changed = true;
        if (c.imgui_bridge_is_item_active()) any_item_active = true;
        if (c.imgui_bridge_slider_float("Saturation", &g.post_saturation, 0.0, 3.0, "%.2f")) pp_changed = true;
        if (c.imgui_bridge_is_item_active()) any_item_active = true;
        c.imgui_bridge_separator();
        c.imgui_bridge_text("Bloom");
        if (c.imgui_bridge_slider_float("Bloom Intensity", &g.post_bloom_intensity, 0.0, 1.0, "%.3f")) pp_changed = true;
        if (c.imgui_bridge_is_item_active()) any_item_active = true;
        if (c.imgui_bridge_slider_float("Threshold", &g.post_bloom_threshold, 0.0, 5.0, "%.2f")) pp_changed = true;
        if (c.imgui_bridge_is_item_active()) any_item_active = true;
        if (c.imgui_bridge_slider_float("Knee", &g.post_bloom_knee, 0.0, 1.0, "%.2f")) pp_changed = true;
        if (c.imgui_bridge_is_item_active()) any_item_active = true;

        if (pp_changed) {
            changed = true;
            state.runtime.post_process.exposure = g.post_exposure;
            state.runtime.post_process.contrast = g.post_contrast;
            state.runtime.post_process.saturation = g.post_saturation;
            state.runtime.post_process.bloomIntensity = g.post_bloom_intensity;
            state.runtime.post_process.bloomThreshold = g.post_bloom_threshold;
            state.runtime.post_process.bloomKnee = g.post_bloom_knee;
            renderer.cardinal_renderer_set_post_process_params(state.runtime.renderer, &state.runtime.post_process);
        }
    }

    if (any_item_active) {
        state.ui.undo.begin_entity_editor_globals(entity.id, before);
    }
    if (changed and !any_item_active and !c.imgui_bridge_is_any_item_active()) {
        state.ui.undo.push(.{ .EntityEditorGlobals = .{
            .entity_id = entity.id,
            .before_present = true,
            .after_present = true,
            .before = before,
            .after = g.*,
        } });
    }
    if (!any_active and !c.imgui_bridge_is_any_item_active()) {
        state.ui.undo.end_entity_editor_globals(entity.id, g.*);
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
        draw_editor_globals(state, entity, g);
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
                            const after = components.Script{};
                            state.ui.undo.push(.{ .EntityScript = .{
                                .entity_id = entity.id,
                                .before_present = false,
                                .after_present = true,
                                .before = std.mem.zeroes(components.Script),
                                .after = after,
                            } });
                            state.runtime.registry.add(entity, after) catch {};
                        }
                    }

                    c.imgui_bridge_close_current_popup();
                    break;
                }
            }

            c.imgui_bridge_end_popup();
        }
    }

    const Kind = enum(u8) { Name = 1, Node = 2, Transform = 3, MeshRenderer = 4, Terrain = 5, Light = 6, Camera = 7, Skybox = 8, Script = 9 };
    const default_order = [_]Kind{ .Name, .Node, .Transform, .MeshRenderer, .Terrain, .Light, .Camera, .Skybox, .Script };

    const kind_to_bit = struct {
        fn f(k: Kind) u32 {
            return @as(u32, 1) << (@as(u5, @intCast(@intFromEnum(k))) - 1);
        }
    }.f;

    const ensure_order = struct {
        fn f(st: *EditorState, ent: engine.ecs_entity.Entity) *editor_state.InspectorComponentOrder {
            const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
            if (st.ui.inspector_component_order_by_entity.getPtr(ent.id)) |p| return p;
            var v = editor_state.InspectorComponentOrder{};
            v.len = @intCast(default_order.len);
            for (default_order, 0..) |k, i| v.order[i] = @intFromEnum(k);
            st.ui.inspector_component_order_by_entity.put(alloc, ent.id, v) catch {};
            return st.ui.inspector_component_order_by_entity.getPtr(ent.id).?;
        }
    }.f;

    const move_before = struct {
        fn f(order: *editor_state.InspectorComponentOrder, src: u8, dst: u8) void {
            const len: usize = @intCast(order.len);
            if (len == 0) return;

            var src_i: ?usize = null;
            var dst_i: ?usize = null;
            for (0..len) |i| {
                if (order.order[i] == src) src_i = i;
                if (order.order[i] == dst) dst_i = i;
            }
            if (src_i == null or dst_i == null) return;
            const si = src_i.?;
            const di = dst_i.?;
            if (si == di) return;

            var tmp: [16]u8 = [_]u8{0} ** 16;
            var out_i: usize = 0;

            for (0..len) |i| {
                const v = order.order[i];
                if (v == src) continue;
                if (out_i < tmp.len) {
                    tmp[out_i] = v;
                    out_i += 1;
                }
            }

            var insert_at: usize = 0;
            for (0..out_i) |i| {
                if (tmp[i] == dst) {
                    insert_at = i;
                    break;
                }
            }

            var shifted: [16]u8 = [_]u8{0} ** 16;
            var j: usize = 0;
            while (j < insert_at and j < shifted.len) : (j += 1) shifted[j] = tmp[j];
            if (insert_at < shifted.len) shifted[insert_at] = src;
            var k: usize = insert_at;
            while (k < out_i and (k + 1) < shifted.len) : (k += 1) {
                shifted[k + 1] = tmp[k];
            }

            for (0..len) |i| order.order[i] = shifted[i];
        }
    }.f;

    if (c.imgui_bridge_button("Copy Components")) {
        var cb = state.ui.component_clipboard;
        cb = .{};
        cb.has = true;
        if (state.runtime.registry.get(components.Name, entity)) |n| {
            cb.has_name = true;
            cb.name = n.*;
        }
        if (state.runtime.registry.get(components.Transform, entity)) |t| {
            cb.has_transform = true;
            cb.transform = t.*;
        }
        if (state.runtime.registry.get(components.Node, entity)) |n| {
            cb.has_node = true;
            cb.node = n.*;
        }
        if (state.runtime.registry.get(components.MeshRenderer, entity)) |mr| {
            cb.has_mesh_renderer = true;
            cb.mesh_renderer = mr.*;
        }
        if (state.runtime.registry.get(components.Light, entity)) |l| {
            cb.has_light = true;
            cb.light = l.*;
        }
        if (state.runtime.registry.get(components.Camera, entity)) |cam| {
            cb.has_camera = true;
            cb.camera = cam.*;
        }
        if (state.runtime.registry.get(components.Skybox, entity)) |sb| {
            cb.has_skybox = true;
            cb.skybox = sb.*;
        }
        if (state.runtime.registry.get(components.Script, entity)) |s| {
            cb.has_script = true;
            cb.script = s.*;
        }
        state.ui.component_clipboard = cb;
    }
    c.imgui_bridge_same_line(0, -1);
    if (c.imgui_bridge_button("Paste Components")) {
        if (state.ui.component_clipboard.has) {
            const cb = state.ui.component_clipboard;
            if (cb.has_name) {
                const before_ptr = state.runtime.registry.get(components.Name, entity);
                state.ui.undo.push(.{ .EntityName = .{
                    .entity_id = entity.id,
                    .before_present = before_ptr != null,
                    .after_present = true,
                    .before = if (before_ptr) |p| p.* else std.mem.zeroes(components.Name),
                    .after = cb.name,
                } });
                state.runtime.registry.add(entity, cb.name) catch {};
            }
            if (cb.has_transform) {
                const before_ptr = state.runtime.registry.get(components.Transform, entity);
                state.ui.undo.push(.{ .EntityTransform = .{
                    .entity_id = entity.id,
                    .before_present = before_ptr != null,
                    .after_present = true,
                    .before = if (before_ptr) |p| p.* else std.mem.zeroes(components.Transform),
                    .after = cb.transform,
                } });
                state.runtime.registry.add(entity, cb.transform) catch {};
                state.runtime.mark_transform_override_tree(entity);
            }
            if (cb.has_node) {
                const before_ptr = state.runtime.registry.get(components.Node, entity);
                state.ui.undo.push(.{ .EntityNode = .{
                    .entity_id = entity.id,
                    .before_present = before_ptr != null,
                    .after_present = true,
                    .before = if (before_ptr) |p| p.* else std.mem.zeroes(components.Node),
                    .after = cb.node,
                } });
                state.runtime.registry.add(entity, cb.node) catch {};
            }
            if (cb.has_mesh_renderer) {
                const before_ptr = state.runtime.registry.get(components.MeshRenderer, entity);
                state.ui.undo.push(.{ .EntityMeshRenderer = .{
                    .entity_id = entity.id,
                    .before_present = before_ptr != null,
                    .after_present = true,
                    .before = if (before_ptr) |p| p.* else std.mem.zeroes(components.MeshRenderer),
                    .after = cb.mesh_renderer,
                } });
                state.runtime.registry.add(entity, cb.mesh_renderer) catch {};
            }
            if (cb.has_light) {
                const before_ptr = state.runtime.registry.get(components.Light, entity);
                state.ui.undo.push(.{ .EntityLight = .{
                    .entity_id = entity.id,
                    .before_present = before_ptr != null,
                    .after_present = true,
                    .before = if (before_ptr) |p| p.* else std.mem.zeroes(components.Light),
                    .after = cb.light,
                } });
                state.runtime.registry.add(entity, cb.light) catch {};
            }
            if (cb.has_camera) {
                const before_ptr = state.runtime.registry.get(components.Camera, entity);
                state.ui.undo.push(.{ .EntityCamera = .{
                    .entity_id = entity.id,
                    .before_present = before_ptr != null,
                    .after_present = true,
                    .before = if (before_ptr) |p| p.* else std.mem.zeroes(components.Camera),
                    .after = cb.camera,
                } });
                state.runtime.registry.add(entity, cb.camera) catch {};
            }
            if (cb.has_skybox) {
                const before_ptr = state.runtime.registry.get(components.Skybox, entity);
                state.ui.undo.push(.{ .EntitySkybox = .{
                    .entity_id = entity.id,
                    .before_present = before_ptr != null,
                    .after_present = true,
                    .before = if (before_ptr) |p| p.* else std.mem.zeroes(components.Skybox),
                    .after = cb.skybox,
                } });
                state.runtime.registry.add(entity, cb.skybox) catch {};
            }
            if (cb.has_script) {
                const before_ptr = state.runtime.registry.get(components.Script, entity);
                state.ui.undo.push(.{ .EntityScript = .{
                    .entity_id = entity.id,
                    .before_present = before_ptr != null,
                    .after_present = true,
                    .before = if (before_ptr) |p| p.* else std.mem.zeroes(components.Script),
                    .after = cb.script,
                } });
                state.runtime.registry.add(entity, cb.script) catch {};
            }
        }
    }
    c.imgui_bridge_same_line(0, -1);
    if (c.imgui_bridge_button("Expand All")) state.ui.inspector_force_open = 1;
    c.imgui_bridge_same_line(0, -1);
    if (c.imgui_bridge_button("Collapse All")) state.ui.inspector_force_open = -1;

    const order_ptr = ensure_order(state, entity);
    var ordered: [16]Kind = undefined;
    var ordered_len: usize = 0;
    for (0..@as(usize, @intCast(order_ptr.len))) |i| {
        const k: Kind = @enumFromInt(order_ptr.order[i]);
        ordered[ordered_len] = k;
        ordered_len += 1;
    }

    var pinned: [16]Kind = undefined;
    var pinned_len: usize = 0;
    var unpinned: [16]Kind = undefined;
    var unpinned_len: usize = 0;
    for (ordered[0..ordered_len]) |k| {
        const bit = kind_to_bit(k);
        const is_pinned = (state.ui.inspector_pinned_mask & bit) != 0;
        if (is_pinned) {
            pinned[pinned_len] = k;
            pinned_len += 1;
        } else {
            unpinned[unpinned_len] = k;
            unpinned_len += 1;
        }
    }

    const apply_reorder_target = struct {
        fn f(st: *EditorState, ent: engine.ecs_entity.Entity, target: Kind, order: *editor_state.InspectorComponentOrder) void {
            if (c.imgui_bridge_begin_drag_drop_target()) {
                if (c.imgui_bridge_accept_drag_drop_payload("INSPECTOR_COMP", 0)) |payload| {
                    const data_ptr = c.imgui_bridge_payload_get_data(payload);
                    if (data_ptr != null) {
                        const src = @as(*const u8, @ptrCast(@alignCast(data_ptr))).*;
                        const dst: u8 = @intFromEnum(target);
                        if (src != dst) {
                            move_before(order, src, dst);
                            const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
                            st.ui.inspector_component_order_by_entity.put(alloc, ent.id, order.*) catch {};
                        }
                    }
                }
                c.imgui_bridge_end_drag_drop_target();
            }
        }
    }.f;

    const draw_pin = struct {
        fn f(st: *EditorState, k: Kind) void {
            c.imgui_bridge_same_line(0, -1);
            var buf: [64]u8 = undefined;
            const label = std.fmt.bufPrintZ(&buf, "Pin##{d}", .{@intFromEnum(k)}) catch return;
            if (c.imgui_bridge_button(label.ptr)) {
                const bit = kind_to_bit(k);
                if ((st.ui.inspector_pinned_mask & bit) != 0) {
                    st.ui.inspector_pinned_mask &= ~bit;
                } else {
                    st.ui.inspector_pinned_mask |= bit;
                }
            }
        }
    }.f;

    const set_payload = struct {
        fn f(k: Kind) void {
            const v: u8 = @intFromEnum(k);
            _ = c.imgui_bridge_set_drag_drop_payload("INSPECTOR_COMP", &v, @sizeOf(u8), 0);
        }
    }.f;

    const draw_kind = struct {
        fn f(st: *EditorState, ent: engine.ecs_entity.Entity, k: Kind, order: *editor_state.InspectorComponentOrder) void {
            const should_force = st.ui.inspector_force_open != 0;
            if (should_force) {
                c.imgui_bridge_set_next_item_open(st.ui.inspector_force_open > 0, c.ImGuiCond_Always);
            }

            switch (k) {
                .Name => {
                    const section_open = c.imgui_bridge_collapsing_header("Name", 0);
                    if (c.imgui_bridge_begin_drag_drop_source(0)) {
                        set_payload(k);
                        c.imgui_bridge_end_drag_drop_source();
                    }
                    apply_reorder_target(st, ent, k, order);
                    draw_pin(st, k);

                    if (!section_open) return;
                    const before = if (st.runtime.registry.get(components.Name, ent)) |n| n.* else std.mem.zeroes(components.Name);
                    const changed = c.imgui_bridge_input_text("##entity_name", @ptrCast(&st.ui.inspector_name_buffer), st.ui.inspector_name_buffer.len, 0);
                    if (c.imgui_bridge_is_item_active()) {
                        st.ui.undo.begin_entity_name(ent.id, before);
                    }
                    if (changed) {
                        st.runtime.registry.add(ent, components.Name.init(buffer_slice(&st.ui.inspector_name_buffer))) catch {};
                    }
                    if (!c.imgui_bridge_is_any_item_active()) {
                        if (st.runtime.registry.get(components.Name, ent)) |n| {
                            st.ui.undo.end_entity_name(ent.id, n.*);
                        }
                    }
                },
                .Node => {
                    if (st.runtime.registry.get(components.Node, ent) == null) return;
                    const section_open = c.imgui_bridge_collapsing_header("Node", 0);
                    if (c.imgui_bridge_begin_drag_drop_source(0)) {
                        set_payload(k);
                        c.imgui_bridge_end_drag_drop_source();
                    }
                    apply_reorder_target(st, ent, k, order);
                    draw_pin(st, k);

                    if (!section_open) return;
                    const node = st.runtime.registry.get(components.Node, ent).?;
                    var type_buf: [128]u8 = undefined;
                    const type_z = std.fmt.bufPrintZ(&type_buf, "{s}", .{@tagName(node.type)}) catch unreachable;
                    c.imgui_bridge_text("Type: %s", type_z.ptr);
                    _ = c.imgui_bridge_input_text_with_hint("##node_type_search", "Search node types...", @ptrCast(&st.ui.inspector_node_type_search), st.ui.inspector_node_type_search.len);
                    const query = buffer_slice(&st.ui.inspector_node_type_search);
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
                            st.ui.undo.push(.{ .EntityNode = .{
                                .entity_id = ent.id,
                                .before_present = true,
                                .after_present = true,
                                .before = before,
                                .after = node.*,
                            } });
                            if (tag == .Camera3D and st.runtime.registry.get(components.Camera, ent) == null) {
                                st.runtime.registry.add(ent, components.Camera{ .type = .Perspective }) catch {};
                            } else if (tag == .Camera2D and st.runtime.registry.get(components.Camera, ent) == null) {
                                st.runtime.registry.add(ent, components.Camera{ .type = .Orthographic }) catch {};
                            } else if ((tag == .DirectionalLight3D or tag == .PointLight3D or tag == .SpotLight3D) and st.runtime.registry.get(components.Light, ent) == null) {
                                const lt: components.LightType = if (tag == .PointLight3D) .Point else if (tag == .SpotLight3D) .Spot else .Directional;
                                st.runtime.registry.add(ent, components.Light{ .type = lt, .cast_shadows = (lt == .Directional) }) catch {};
                            } else if (tag == .Skybox and st.runtime.registry.get(components.Skybox, ent) == null) {
                                st.runtime.registry.add(ent, components.Skybox.init(buffer_slice(&st.ui.inspector_skybox_buffer))) catch {};
                            }
                        }
                    }
                },
                .Transform => {
                    if (st.runtime.registry.get(components.Transform, ent) == null) return;
                    const section_open = c.imgui_bridge_collapsing_header("Transform", 0);
                    if (c.imgui_bridge_begin_drag_drop_source(0)) {
                        set_payload(k);
                        c.imgui_bridge_end_drag_drop_source();
                    }
                    apply_reorder_target(st, ent, k, order);
                    draw_pin(st, k);

                    if (!section_open) return;

                    const t = st.runtime.registry.get(components.Transform, ent).?;
                    const any_active = c.imgui_bridge_is_any_item_active();
                    const before = t.*;

                    c.imgui_bridge_text("%s", if (st.ui.transform_space_world) "Space: World" else "Space: Local");
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button(if (st.ui.transform_space_world) "Local" else "World")) {
                        st.ui.transform_space_world = !st.ui.transform_space_world;
                    }
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Copy TRS")) {
                        st.ui.transform_clipboard_valid = true;
                        st.ui.transform_clipboard_pos = t.position.toArray();
                        st.ui.transform_clipboard_rot = t.rotation.toArray();
                        st.ui.transform_clipboard_scale = t.scale.toArray();
                    }
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Paste TRS")) {
                        if (st.ui.transform_clipboard_valid) {
                            st.ui.undo.push(.{ .EntityTransform = .{
                                .entity_id = ent.id,
                                .before_present = true,
                                .after_present = true,
                                .before = before,
                                .after = .{
                                    .position = math.Vec3.fromArray(st.ui.transform_clipboard_pos),
                                    .rotation = math.Quat.fromArray(st.ui.transform_clipboard_rot),
                                    .scale = math.Vec3.fromArray(st.ui.transform_clipboard_scale),
                                    .world_matrix = t.world_matrix,
                                    .dirty = true,
                                },
                            } });
                            t.position = math.Vec3.fromArray(st.ui.transform_clipboard_pos);
                            t.rotation = math.Quat.fromArray(st.ui.transform_clipboard_rot);
                            t.scale = math.Vec3.fromArray(st.ui.transform_clipboard_scale);
                            t.dirty = true;
                            st.runtime.mark_transform_override_tree(ent);
                        }
                    }
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Reset TRS")) {
                        st.ui.undo.push(.{ .EntityTransform = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = true,
                            .before = before,
                            .after = .{
                                .position = math.Vec3.zero(),
                                .rotation = math.Quat.identity(),
                                .scale = math.Vec3.one(),
                                .world_matrix = t.world_matrix,
                                .dirty = true,
                            },
                        } });
                        t.position = math.Vec3.zero();
                        t.rotation = math.Quat.identity();
                        t.scale = math.Vec3.one();
                        t.dirty = true;
                        st.runtime.mark_transform_override_tree(ent);
                    }

                    const compute_world = struct {
                        fn f(st2: *EditorState, e2: engine.ecs_entity.Entity) math.Mat4 {
                            var chain: [128]engine.ecs_entity.Entity = undefined;
                            var len: usize = 0;
                            var cur: ?engine.ecs_entity.Entity = e2;
                            var guard: u32 = 0;
                            while (cur) |ce| {
                                if (guard > 2048 or len >= chain.len) break;
                                guard += 1;
                                chain[len] = ce;
                                len += 1;
                                if (st2.runtime.registry.get(components.Hierarchy, ce)) |h| {
                                    if (h.parent) |p| {
                                        if (st2.runtime.registry.entity_manager.is_alive(p)) {
                                            cur = p;
                                            continue;
                                        }
                                    }
                                }
                                cur = null;
                            }

                            var world = math.Mat4.identity();
                            var i: usize = len;
                            while (i > 0) {
                                i -= 1;
                                const e = chain[i];
                                if (st2.runtime.registry.get(components.Transform, e)) |tt| {
                                    const local = math.Mat4.fromTRS(tt.position, tt.rotation, tt.scale);
                                    world = world.mul(local);
                                }
                            }
                            return world;
                        }
                    }.f;

                    if (st.ui.transform_space_world) {
                        const world = compute_world(st, ent);
                        const trs = world.decompose();

                        var wpos = trs.t.toArray();
                        if (c.imgui_bridge_drag_float3("World Position", &wpos, 0.1, 0.0, 0.0, "%.3f", 0)) {
                            const parent_world = blk: {
                                if (st.runtime.registry.get(components.Hierarchy, ent)) |h| {
                                    if (h.parent) |p| {
                                        if (st.runtime.registry.entity_manager.is_alive(p)) break :blk compute_world(st, p);
                                    }
                                }
                                break :blk math.Mat4.identity();
                            };
                            const inv_parent = parent_world.invert() orelse math.Mat4.identity();
                            const desired_world = math.Mat4.fromTRS(math.Vec3.fromArray(wpos), trs.r, trs.s);
                            const local_mat = inv_parent.mul(desired_world);
                            const local_trs = local_mat.decompose();
                            t.position = local_trs.t;
                            t.rotation = local_trs.r;
                            t.scale = local_trs.s;
                            t.dirty = true;
                            st.runtime.mark_transform_override_tree(ent);
                        }
                        if (c.imgui_bridge_is_item_active()) st.ui.undo.begin_entity_transform(ent.id, before);

                        var wscale = trs.s.toArray();
                        if (c.imgui_bridge_drag_float3("World Scale", &wscale, 0.01, 0.0, 0.0, "%.3f", 0)) {
                            const parent_world = blk: {
                                if (st.runtime.registry.get(components.Hierarchy, ent)) |h| {
                                    if (h.parent) |p| {
                                        if (st.runtime.registry.entity_manager.is_alive(p)) break :blk compute_world(st, p);
                                    }
                                }
                                break :blk math.Mat4.identity();
                            };
                            const inv_parent = parent_world.invert() orelse math.Mat4.identity();
                            const desired_world = math.Mat4.fromTRS(trs.t, trs.r, math.Vec3.fromArray(wscale));
                            const local_mat = inv_parent.mul(desired_world);
                            const local_trs = local_mat.decompose();
                            t.position = local_trs.t;
                            t.rotation = local_trs.r;
                            t.scale = local_trs.s;
                            t.dirty = true;
                            st.runtime.mark_transform_override_tree(ent);
                        }
                        if (c.imgui_bridge_is_item_active()) st.ui.undo.begin_entity_transform(ent.id, before);

                        if (!st.ui.inspector_rotation_world_editing) {
                            const curr = quat_to_euler_xyz_deg(trs.r);
                            st.ui.inspector_rotation_world_euler_deg = unwrap_euler_deg(st.ui.inspector_rotation_world_euler_deg, curr);
                        }
                        var wrot_deg = st.ui.inspector_rotation_world_euler_deg;
                        if (c.imgui_bridge_drag_float3("World Rotation XYZ (deg)", &wrot_deg, 0.1, 0.0, 0.0, "%.3f", 0)) {
                            st.ui.inspector_rotation_world_euler_deg = wrot_deg;
                            const new_r = euler_xyz_deg_to_quat(wrot_deg);
                            const parent_world = blk: {
                                if (st.runtime.registry.get(components.Hierarchy, ent)) |h| {
                                    if (h.parent) |p| {
                                        if (st.runtime.registry.entity_manager.is_alive(p)) break :blk compute_world(st, p);
                                    }
                                }
                                break :blk math.Mat4.identity();
                            };
                            const inv_parent = parent_world.invert() orelse math.Mat4.identity();
                            const desired_world = math.Mat4.fromTRS(trs.t, new_r, trs.s);
                            const local_mat = inv_parent.mul(desired_world);
                            const local_trs = local_mat.decompose();
                            t.position = local_trs.t;
                            t.rotation = local_trs.r;
                            t.scale = local_trs.s;
                            t.dirty = true;
                            st.runtime.mark_transform_override_tree(ent);
                        }
                        st.ui.inspector_rotation_world_editing = c.imgui_bridge_is_item_active();
                        if (c.imgui_bridge_is_item_active()) st.ui.undo.begin_entity_transform(ent.id, before);
                    } else {
                        var pos = t.position.toArray();
                        if (c.imgui_bridge_drag_float3("Position", &pos, 0.1, 0.0, 0.0, "%.3f", 0)) {
                            t.position = math.Vec3.fromArray(pos);
                            t.dirty = true;
                            st.runtime.mark_transform_override_tree(ent);
                        }
                        if (c.imgui_bridge_is_item_active()) st.ui.undo.begin_entity_transform(ent.id, before);

                        var scale = t.scale.toArray();
                        if (c.imgui_bridge_drag_float3("Scale", &scale, 0.01, 0.0, 0.0, "%.3f", 0)) {
                            t.scale = math.Vec3.fromArray(scale);
                            t.dirty = true;
                            st.runtime.mark_transform_override_tree(ent);
                        }
                        if (c.imgui_bridge_is_item_active()) st.ui.undo.begin_entity_transform(ent.id, before);

                        if (!st.ui.inspector_rotation_editing) {
                            const curr = quat_to_euler_xyz_deg(t.rotation);
                            st.ui.inspector_rotation_euler_deg = unwrap_euler_deg(st.ui.inspector_rotation_euler_deg, curr);
                        }
                        var rot_deg = st.ui.inspector_rotation_euler_deg;
                        if (c.imgui_bridge_drag_float3("Rotation XYZ (deg)", &rot_deg, 0.1, 0.0, 0.0, "%.3f", 0)) {
                            st.ui.inspector_rotation_euler_deg = rot_deg;
                            t.rotation = euler_xyz_deg_to_quat(rot_deg);
                            t.dirty = true;
                            st.runtime.mark_transform_override_tree(ent);
                        }
                        st.ui.inspector_rotation_editing = c.imgui_bridge_is_item_active();
                        if (c.imgui_bridge_is_item_active()) st.ui.undo.begin_entity_transform(ent.id, before);
                    }

                    if (!any_active and !c.imgui_bridge_is_any_item_active()) {
                        st.ui.undo.end_entity_transform(ent.id, t.*);
                    }
                },
                .MeshRenderer => {
                    if (st.runtime.registry.get(components.MeshRenderer, ent) == null) return;
                    const section_open = c.imgui_bridge_collapsing_header("MeshRenderer", 0);
                    if (c.imgui_bridge_begin_drag_drop_source(0)) {
                        set_payload(k);
                        c.imgui_bridge_end_drag_drop_source();
                    }
                    apply_reorder_target(st, ent, k, order);
                    draw_pin(st, k);
                    if (!section_open) return;

                    const mr = st.runtime.registry.get(components.MeshRenderer, ent).?;
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Remove##MeshRenderer")) {
                        const before = mr.*;
                        st.ui.undo.push(.{ .EntityMeshRenderer = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = false,
                            .before = before,
                            .after = std.mem.zeroes(components.MeshRenderer),
                        } });
                        st.runtime.registry.remove(components.MeshRenderer, ent);
                        if (st.runtime.registry.get(components.Node, ent)) |n| {
                            if (n.type == .MeshInstance3D) n.type = .Node3D;
                        }
                        return;
                    }

                    const before = mr.*;
                    var changed = false;
                    if (st.runtime.combined_scene.mesh_count > 0) {
                        const mesh_count: usize = @intCast(st.runtime.combined_scene.mesh_count);
                        const alloc = st.runtime.arena_allocator;
                        const items = alloc.alloc([*:0]const u8, mesh_count) catch return;
                        var i: u32 = 0;
                        while (i < st.runtime.combined_scene.mesh_count) : (i += 1) {
                            items[i] = scene_mesh_label(st, i);
                        }
                        var current_item: i32 = @intCast(@min(mr.mesh.index, st.runtime.combined_scene.mesh_count - 1));
                        if (c.imgui_bridge_combo("Mesh", &current_item, @ptrCast(items.ptr), @intCast(items.len), 10)) {
                            const new_index: u32 = @intCast(@max(0, current_item));
                            if (mr.mesh.index != new_index) {
                                mr.mesh.index = new_index;
                                if (st.runtime.combined_scene.meshes) |meshes| {
                                    const mi = meshes[new_index].material_index;
                                    if (mi < st.runtime.combined_scene.material_count) {
                                        mr.material.index = mi;
                                    }
                                }
                                changed = true;
                            }
                        }
                    } else {
                        c.imgui_bridge_text("Mesh: (no scene loaded)");
                    }

                    if (st.runtime.combined_scene.material_count > 0) {
                        const mat_count: usize = @intCast(st.runtime.combined_scene.material_count);
                        const alloc = st.runtime.arena_allocator;
                        const items = alloc.alloc([*:0]const u8, mat_count) catch return;
                        var i: u32 = 0;
                        while (i < st.runtime.combined_scene.material_count) : (i += 1) {
                            items[i] = scene_material_label(st, i);
                        }
                        var current_item: i32 = @intCast(@min(mr.material.index, st.runtime.combined_scene.material_count - 1));
                        if (c.imgui_bridge_combo("Material", &current_item, @ptrCast(items.ptr), @intCast(items.len), 10)) {
                            const new_index: u32 = @intCast(@max(0, current_item));
                            if (mr.material.index != new_index) {
                                mr.material.index = new_index;
                                changed = true;
                            }
                        }
                        if (c.imgui_bridge_begin_drag_drop_target()) {
                            if (c.imgui_bridge_accept_drag_drop_payload("ASSET_PATH", 0)) |payload| {
                                const data_ptr = c.imgui_bridge_payload_get_data(payload);
                                const data_size = c.imgui_bridge_payload_get_data_size(payload);
                                if (data_ptr != null and data_size > 0) {
                                    const data = @as([*]const u8, @ptrCast(data_ptr));
                                    const len = @as(usize, @intCast(data_size));
                                    const path = std.mem.sliceTo(data[0..len], 0);
                                    if (find_material_by_texture_basename(st, path)) |idx| {
                                        if (mr.material.index != idx) {
                                            mr.material.index = idx;
                                            changed = true;
                                        }
                                    }
                                }
                            }
                            c.imgui_bridge_end_drag_drop_target();
                        }
                    } else {
                        c.imgui_bridge_text("Material: (no materials)");
                    }

                    var any_item_active = false;
                    if (reflect_edit_component_fields(components.MeshRenderer, mr, &any_item_active)) {
                        changed = true;
                    }
                    if (changed) {
                        st.ui.undo.push(.{ .EntityMeshRenderer = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = true,
                            .before = before,
                            .after = mr.*,
                        } });
                    }
                },
                .Terrain => {
                    if (st.runtime.registry.get(components.Terrain, ent) == null) return;
                    const section_open = c.imgui_bridge_collapsing_header("Terrain", 0);
                    if (c.imgui_bridge_begin_drag_drop_source(0)) {
                        set_payload(k);
                        c.imgui_bridge_end_drag_drop_source();
                    }
                    apply_reorder_target(st, ent, k, order);
                    draw_pin(st, k);
                    if (!section_open) return;

                    const terr = st.runtime.registry.get(components.Terrain, ent).?;
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Remove##Terrain")) {
                        const before_t = terr.*;
                        st.ui.undo.push(.{ .EntityTerrain = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = false,
                            .before = before_t,
                            .after = std.mem.zeroes(components.Terrain),
                        } });
                        st.runtime.registry.remove(components.Terrain, ent);
                        return;
                    }
                    const before_t = terr.*;
                    var any_item_active = false;
                    if (reflect_edit_component_fields(components.Terrain, terr, &any_item_active)) {
                        st.ui.undo.push(.{ .EntityTerrain = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = true,
                            .before = before_t,
                            .after = terr.*,
                        } });
                        st.runtime.pending_scene = st.runtime.combined_scene;
                        st.runtime.scene_upload_pending = true;
                        st.runtime.picking_cache_dirty = true;
                    }
                },
                .Light => {
                    if (st.runtime.registry.get(components.Light, ent) == null) return;
                    const section_open = c.imgui_bridge_collapsing_header("Light", 0);
                    if (c.imgui_bridge_begin_drag_drop_source(0)) {
                        set_payload(k);
                        c.imgui_bridge_end_drag_drop_source();
                    }
                    apply_reorder_target(st, ent, k, order);
                    draw_pin(st, k);
                    if (!section_open) return;

                    const l = st.runtime.registry.get(components.Light, ent).?;
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Remove##Light")) {
                        const before_l = l.*;
                        st.ui.undo.push(.{ .EntityLight = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = false,
                            .before = before_l,
                            .after = std.mem.zeroes(components.Light),
                        } });
                        st.runtime.registry.remove(components.Light, ent);
                        if (st.runtime.registry.get(components.Node, ent)) |n| {
                            if (n.type == .DirectionalLight3D or n.type == .PointLight3D or n.type == .SpotLight3D) n.type = .Node3D;
                        }
                        return;
                    }
                    const any_active = c.imgui_bridge_is_any_item_active();
                    const before_l = l.*;
                    var any_item_active = false;
                    const changed = reflect_edit_component_fields(components.Light, l, &any_item_active);
                    if (any_item_active) {
                        st.ui.undo.begin_entity_light(ent.id, before_l);
                    }
                    if (changed and !any_item_active and !c.imgui_bridge_is_any_item_active() and !st.ui.undo.is_capturing_entity_light(ent.id)) {
                        st.ui.undo.push(.{ .EntityLight = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = true,
                            .before = before_l,
                            .after = l.*,
                        } });
                    }
                    if (!any_active and !c.imgui_bridge_is_any_item_active()) {
                        st.ui.undo.end_entity_light(ent.id, l.*);
                    }
                },
                .Camera => {
                    if (st.runtime.registry.get(components.Camera, ent) == null) return;
                    const section_open = c.imgui_bridge_collapsing_header("Camera", 0);
                    if (c.imgui_bridge_begin_drag_drop_source(0)) {
                        set_payload(k);
                        c.imgui_bridge_end_drag_drop_source();
                    }
                    apply_reorder_target(st, ent, k, order);
                    draw_pin(st, k);
                    if (!section_open) return;

                    const cam = st.runtime.registry.get(components.Camera, ent).?;
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Remove##Camera")) {
                        const before_c = cam.*;
                        st.ui.undo.push(.{ .EntityCamera = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = false,
                            .before = before_c,
                            .after = std.mem.zeroes(components.Camera),
                        } });
                        st.runtime.registry.remove(components.Camera, ent);
                        if (st.runtime.registry.get(components.Node, ent)) |n| {
                            if (n.type == .Camera3D or n.type == .Camera2D) n.type = .Node3D;
                        }
                        return;
                    }
                    const any_active = c.imgui_bridge_is_any_item_active();
                    const before_c = cam.*;
                    var any_item_active = false;
                    const changed = reflect_edit_component_fields(components.Camera, cam, &any_item_active);
                    if (any_item_active) {
                        st.ui.undo.begin_entity_camera(ent.id, before_c);
                    }
                    if (changed and !any_item_active and !c.imgui_bridge_is_any_item_active() and !st.ui.undo.is_capturing_entity_camera(ent.id)) {
                        st.ui.undo.push(.{ .EntityCamera = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = true,
                            .before = before_c,
                            .after = cam.*,
                        } });
                    }
                    if (!any_active and !c.imgui_bridge_is_any_item_active()) {
                        st.ui.undo.end_entity_camera(ent.id, cam.*);
                    }
                },
                .Skybox => {
                    if (st.runtime.registry.get(components.Skybox, ent) == null) return;
                    const section_open = c.imgui_bridge_collapsing_header("Skybox", 0);
                    if (c.imgui_bridge_begin_drag_drop_source(0)) {
                        set_payload(k);
                        c.imgui_bridge_end_drag_drop_source();
                    }
                    apply_reorder_target(st, ent, k, order);
                    draw_pin(st, k);
                    if (!section_open) return;

                    const sb = st.runtime.registry.get(components.Skybox, ent).?;
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Remove##Skybox")) {
                        const before_s = sb.*;
                        st.ui.undo.push(.{ .EntitySkybox = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = false,
                            .before = before_s,
                            .after = std.mem.zeroes(components.Skybox),
                        } });
                        st.runtime.registry.remove(components.Skybox, ent);
                        if (st.runtime.registry.get(components.Node, ent)) |n| {
                            if (n.type == .Skybox) n.type = .Node3D;
                        }
                        return;
                    }
                    const before_s = sb.*;
                    const changed = c.imgui_bridge_input_text("Path", @ptrCast(&st.ui.inspector_skybox_buffer), st.ui.inspector_skybox_buffer.len, 0);
                    if (c.imgui_bridge_is_item_active()) {
                        st.ui.undo.begin_entity_skybox(ent.id, before_s);
                    }
                    if (c.imgui_bridge_begin_drag_drop_target()) {
                        if (c.imgui_bridge_accept_drag_drop_payload("ASSET_PATH", 0)) |payload| {
                            const data_ptr = c.imgui_bridge_payload_get_data(payload);
                            if (data_ptr != null) {
                                const path_c: [*:0]const u8 = @ptrCast(@alignCast(data_ptr));
                                const path = std.mem.span(path_c);
                                const ext = std.fs.path.extension(path);
                                if (std.mem.eql(u8, ext, ".hdr") or std.mem.eql(u8, ext, ".exr")) {
                                    const len = @min(path.len, st.ui.inspector_skybox_buffer.len - 1);
                                    @memcpy(st.ui.inspector_skybox_buffer[0..len], path[0..len]);
                                    st.ui.inspector_skybox_buffer[len] = 0;
                                    st.runtime.registry.add(ent, components.Skybox.init(path)) catch {};
                                }
                            }
                        }
                        c.imgui_bridge_end_drag_drop_target();
                    }
                    if (changed) {
                        st.runtime.registry.add(ent, components.Skybox.init(buffer_slice(&st.ui.inspector_skybox_buffer))) catch {};
                    }
                    if (!c.imgui_bridge_is_any_item_active()) {
                        if (st.runtime.registry.get(components.Skybox, ent)) |s| {
                            st.ui.undo.end_entity_skybox(ent.id, s.*);
                        }
                    }
                    if (sb.slice().len != 0) {
                        c.imgui_bridge_text_wrapped("%s", sb.slice().ptr);
                    }
                },
                .Script => {
                    if (st.runtime.registry.get(components.Script, ent) == null) return;
                    const section_open = c.imgui_bridge_collapsing_header("Script", 0);
                    if (c.imgui_bridge_begin_drag_drop_source(0)) {
                        set_payload(k);
                        c.imgui_bridge_end_drag_drop_source();
                    }
                    apply_reorder_target(st, ent, k, order);
                    draw_pin(st, k);
                    if (!section_open) return;

                    const s = st.runtime.registry.get(components.Script, ent).?;
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Remove##Script")) {
                        const before_s = s.*;
                        st.ui.undo.push(.{ .EntityScript = .{
                            .entity_id = ent.id,
                            .before_present = true,
                            .after_present = false,
                            .before = before_s,
                            .after = std.mem.zeroes(components.Script),
                        } });
                        st.runtime.registry.remove(components.Script, ent);
                        return;
                    }
                    c.imgui_bridge_text_wrapped("Script component attached.");
                },
            }
        }
    }.f;

    for (pinned[0..pinned_len]) |k| draw_kind(state, entity, k, order_ptr);
    for (unpinned[0..unpinned_len]) |k| draw_kind(state, entity, k, order_ptr);
    state.ui.inspector_force_open = 0;
}

pub fn draw_inspector_panel(state: *EditorState) void {
    draw_entity_inspector_panel(state);
}
