//! Editor selection orchestration.
//!
//! This module intentionally stays small and delegates to specialized systems:
//! - `selection_raycast` for picking and selection helpers
//! - `gizmo_system` for manipulation widgets
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const components = engine.ecs_components;
const editor_state = @import("../editor_state.zig");
const EditorState = editor_state.EditorState;
const c = @import("../c.zig").c;
const gizmo_system = @import("gizmo_system.zig");
const selection_raycast = @import("selection_raycast.zig");
const terrain_volume = @import("terrain_volume.zig");
const debug_draw = @import("debug_draw.zig");

pub const GizmoMode = gizmo_system.GizmoMode;

/// Clears cached data used by picking.
pub fn reset_picking_cache() void {
    selection_raycast.reset_picking_cache();
}

/// Frames `root` in the scene view based on its computed bounds.
pub fn frame_entity_in_scene_view(state: *EditorState, root: engine.ecs_entity.Entity) void {
    selection_raycast.frame_entity_in_scene_view(state, root);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn sample_height_bilinear(td: *editor_state.TerrainData, terr: *components.Terrain, local_x: f32, local_z: f32, use_bottom: bool) f32 {
    if (td.dims < 2) return 0.0;
    const grid: u32 = td.dims - 1;
    const half_x = terr.size.x * 0.5;
    const half_z = terr.size.y * 0.5;
    const height_map: []const f32 = if (use_bottom and terr.thickness > 0.01) td.bottom_height else td.height;

    const fx = std.math.clamp((local_x + half_x) / terr.size.x, 0.0, 1.0);
    const fz = std.math.clamp((local_z + half_z) / terr.size.y, 0.0, 1.0);

    const x_f = fx * @as(f32, @floatFromInt(grid));
    const z_f = fz * @as(f32, @floatFromInt(grid));

    const x0_u32: u32 = @intFromFloat(@floor(x_f));
    const z0_u32: u32 = @intFromFloat(@floor(z_f));
    const x1_u32: u32 = @min(x0_u32 + 1, grid);
    const z1_u32: u32 = @min(z0_u32 + 1, grid);

    const tx = x_f - @as(f32, @floatFromInt(x0_u32));
    const tz = z_f - @as(f32, @floatFromInt(z0_u32));

    const vps: u32 = td.dims;
    const idx00: usize = @as(usize, z0_u32) * @as(usize, vps) + @as(usize, x0_u32);
    const idx10: usize = @as(usize, z0_u32) * @as(usize, vps) + @as(usize, x1_u32);
    const idx01: usize = @as(usize, z1_u32) * @as(usize, vps) + @as(usize, x0_u32);
    const idx11: usize = @as(usize, z1_u32) * @as(usize, vps) + @as(usize, x1_u32);

    if (idx11 >= height_map.len) return 0.0;

    const h00 = height_map[idx00];
    const h10 = height_map[idx10];
    const h01 = height_map[idx01];
    const h11 = height_map[idx11];
    return lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), tz);
}

fn brush_falloff(radius: f32, dx: f32, dz: f32) f32 {
    const d2 = dx * dx + dz * dz;
    if (d2 > radius * radius) return 0.0;
    const d = @sqrt(@max(0.0, d2));
    var w = 1.0 - (d / radius);
    w = w * w;
    return w;
}

fn find_terrain_height_at_world_xz(
    state: *EditorState,
    terrain_group: []const engine.ecs_entity.Entity,
    world_x: f32,
    world_z: f32,
) ?struct { terr: *components.Terrain, tr: *components.Transform, td: *editor_state.TerrainData, local_x: f32, local_z: f32, base_h: f32 } {
    for (terrain_group) |e| {
        const terr = state.runtime.registry.get(components.Terrain, e) orelse continue;
        const tr = state.runtime.registry.get(components.Transform, e) orelse continue;
        const td = state.runtime.terrain_data_by_entity.getPtr(e.id) orelse continue;

        const local_x = world_x - tr.position.x;
        const local_z = world_z - tr.position.z;

        const half_x = terr.size.x * 0.5;
        const half_z = terr.size.y * 0.5;
        if (local_x < -half_x or local_x > half_x) continue;
        if (local_z < -half_z or local_z > half_z) continue;

        const use_bottom = (state.ui.terrain_brush_outline_tool == 0 and state.ui.terrain_brush_outline_surface == 1 and terr.thickness > 0.01);
        const base = sample_height_bilinear(td, terr, local_x, local_z, use_bottom);
        return .{ .terr = terr, .tr = tr, .td = td, .local_x = local_x, .local_z = local_z, .base_h = base };
    }
    return null;
}

fn predicted_height_delta(
    terr: *components.Terrain,
    td: *editor_state.TerrainData,
    base_h: f32,
    local_x: f32,
    local_z: f32,
    center_world: math.Vec3,
    tr: *components.Transform,
    tool: i32,
    mode: i32,
    radius: f32,
    strength_in: f32,
    flatten_target: f32,
    use_bottom: bool,
) f32 {
    if (tool != 0) return 0.0;

    const dx = (tr.position.x + local_x) - center_world.x;
    const dz = (tr.position.z + local_z) - center_world.z;
    const w = brush_falloff(radius, dx, dz);
    if (w <= 0.0) return 0.0;

    const strength = if (mode == 0 or mode == 1) @max(0.0, strength_in) else @min(1.0, @max(0.0, strength_in));

    if (mode == 0) return (if (use_bottom) -strength * w else strength * w);
    if (mode == 1) return (if (use_bottom) strength * w else -strength * w);
    if (mode == 2) return (flatten_target - base_h) * (strength * w);
    if (mode == 3) {
        if (td.dims < 2) return 0.0;
        const grid: u32 = td.dims - 1;
        const step_x = terr.size.x / @as(f32, @floatFromInt(grid));
        const step_z = terr.size.y / @as(f32, @floatFromInt(grid));
        const h1 = sample_height_bilinear(td, terr, local_x - step_x, local_z, use_bottom);
        const h2 = sample_height_bilinear(td, terr, local_x + step_x, local_z, use_bottom);
        const h3 = sample_height_bilinear(td, terr, local_x, local_z - step_z, use_bottom);
        const h4 = sample_height_bilinear(td, terr, local_x, local_z + step_z, use_bottom);
        const avg = (base_h + h1 + h2 + h3 + h4) / 5.0;
        return (avg - base_h) * (strength * w);
    }

    return 0.0;
}

fn draw_terrain_brush_outline(state: *EditorState, terrain_group: []const engine.ecs_entity.Entity) void {
    if (!state.ui.terrain_brush_outline_enabled) return;
    if (state.runtime.mouse_captured) return;
    if (terrain_group.len == 0) return;

    const win_width = state.runtime.window.width;
    const win_height = state.runtime.window.height;
    if (win_width == 0 or win_height == 0) return;

    const center_world = math.Vec3{
        .x = state.ui.terrain_brush_outline_pos[0],
        .y = state.ui.terrain_brush_outline_pos[1],
        .z = state.ui.terrain_brush_outline_pos[2],
    };
    const radius = @max(0.001, state.ui.terrain_brush_outline_radius);

    const view = math.Mat4.lookAt(state.runtime.camera.position, state.runtime.camera.target, state.runtime.camera.up);
    const proj = math.Mat4.perspective(math.toRadians(state.runtime.camera.fov), state.runtime.camera.aspect, state.runtime.camera.near_plane, state.runtime.camera.far_plane);
    const view_proj = proj.mul(view);

    const ring_scales = [_]f32{ 1.0, 0.66, 0.33 };
    const segments: u32 = 64;
    const thickness: f32 = 2.0;

    const strength = std.math.clamp(state.ui.terrain_brush_outline_strength, 0.0, 1.0);
    const alpha: u32 = @intFromFloat(std.math.clamp(strength, 0.15, 1.0) * 255.0);
    const color_rgb: u32 = if (state.ui.terrain_brush_outline_tool == 0) 0x0000FF00 else if (state.ui.terrain_brush_outline_tool == 1) 0x0000FFFF else 0x00FFAA00;
    const color: u32 = (alpha << 24) | color_rgb;
    const y_offset: f32 = 0.03;

    var flatten_target = center_world.y;
    if (find_terrain_height_at_world_xz(state, terrain_group, center_world.x, center_world.z)) |center_sample| {
        flatten_target = center_sample.tr.position.y + center_sample.base_h;
    }

    inline for (ring_scales) |rs| {
        const r = radius * rs;
        var i: u32 = 0;
        while (i < segments) : (i += 1) {
            const a0 = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments))) * std.math.tau;
            const a1 = (@as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments))) * std.math.tau;

            const x0 = center_world.x + @cos(a0) * r;
            const z0 = center_world.z + @sin(a0) * r;
            const x1 = center_world.x + @cos(a1) * r;
            const z1 = center_world.z + @sin(a1) * r;

            const s0 = find_terrain_height_at_world_xz(state, terrain_group, x0, z0) orelse continue;
            const s1 = find_terrain_height_at_world_xz(state, terrain_group, x1, z1) orelse continue;

            const tool = state.ui.terrain_brush_outline_tool;
            const mode = state.ui.terrain_brush_outline_mode;

            const use_bottom0 = (tool == 0 and state.ui.terrain_brush_outline_surface == 1 and s0.terr.thickness > 0.01);
            const use_bottom1 = (tool == 0 and state.ui.terrain_brush_outline_surface == 1 and s1.terr.thickness > 0.01);

            const delta0 = predicted_height_delta(s0.terr, s0.td, s0.base_h, s0.local_x, s0.local_z, center_world, s0.tr, tool, mode, radius, state.ui.terrain_brush_outline_strength, flatten_target, use_bottom0);
            const delta1 = predicted_height_delta(s1.terr, s1.td, s1.base_h, s1.local_x, s1.local_z, center_world, s1.tr, tool, mode, radius, state.ui.terrain_brush_outline_strength, flatten_target, use_bottom1);

            const p0 = math.Vec3{ .x = x0, .y = s0.tr.position.y + s0.base_h + delta0 + y_offset, .z = z0 };
            const p1 = math.Vec3{ .x = x1, .y = s1.tr.position.y + s1.base_h + delta1 + y_offset, .z = z1 };
            debug_draw.draw_line_world(view_proj, win_width, win_height, p0, p1, color, thickness);
        }
    }
}

/// Updates selection and gizmo interaction for the current frame.
pub fn update(state: *EditorState) void {
    gizmo_system.pre_update(state);

    if (state.runtime.preview_game_camera) {
        state.ui.selected_model_id = 0;
        return;
    }

    const want_capture = c.imgui_bridge_want_capture_mouse();
    if (!state.runtime.mouse_captured and c.imgui_bridge_is_mouse_clicked(0) and !want_capture and gizmo_system.allow_scene_pick()) {
        selection_raycast.pick_under_mouse(state);
    }

    if (state.ui.selected_entity.id != std.math.maxInt(u64)) {
        if (state.runtime.registry.get(components.EditorGlobals, state.ui.selected_entity) != null) {
            state.ui.selected_model_id = 0;
            return;
        }
        if (state.runtime.registry.get(components.Terrain, state.ui.selected_entity)) |_| {
            var group: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
            defer group.deinit(state.runtime.arena_allocator);
            terrain_volume.collect_connected_terrain(&state.runtime, state.ui.selected_entity, state.runtime.arena_allocator, &group);
            selection_raycast.draw_selection_xray_group(state, group.items);
            draw_terrain_brush_outline(state, group.items);
        } else {
            selection_raycast.draw_selection_xray(state, state.ui.selected_entity);
        }
        if (state.runtime.registry.get(components.Transform, state.ui.selected_entity)) |t| {
            gizmo_system.draw_entity_gizmo(state, t);
            return;
        }
    }

    state.ui.selected_model_id = 0;
}
