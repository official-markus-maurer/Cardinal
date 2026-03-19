//! Immediate-mode debug drawing helpers for editor tools.
//!
//! Provides small utilities to project world-space points into screen-space and draw simple
//! 2D primitives via the ImGui bridge.
//!
//! TODO: Consider a renderer-backed 3D debug pass for depth-tested primitives.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const c = @import("../c.zig").c;

/// Projects a clip-space position to screen space.
pub fn project_vec4_to_screen(v4: math.Vec4, win_width: u32, win_height: u32) ?c.ImVec2 {
    if (v4.w <= 0.0) return null;
    const ndc = math.Vec3{ .x = v4.x / v4.w, .y = v4.y / v4.w, .z = v4.z / v4.w };
    const w: f32 = @floatFromInt(win_width);
    const h: f32 = @floatFromInt(win_height);
    return c.ImVec2{ .x = (ndc.x + 1.0) * 0.5 * w, .y = (ndc.y + 1.0) * 0.5 * h };
}

/// Projects a world-space position to screen space using a view-projection matrix.
pub fn project_world_to_screen(view_proj: math.Mat4, win_width: u32, win_height: u32, p_world: math.Vec3) ?c.ImVec2 {
    const v4 = view_proj.mulVec4(math.Vec4{ .x = p_world.x, .y = p_world.y, .z = p_world.z, .w = 1.0 });
    return project_vec4_to_screen(v4, win_width, win_height);
}

/// Draws a line between two world-space points.
pub fn draw_line_world(view_proj: math.Mat4, win_width: u32, win_height: u32, a_world: math.Vec3, b_world: math.Vec3, color: u32, thickness: f32) void {
    const a = project_world_to_screen(view_proj, win_width, win_height, a_world) orelse return;
    const b = project_world_to_screen(view_proj, win_width, win_height, b_world) orelse return;
    c.imgui_bridge_draw_line(&a, &b, color, thickness);
}
