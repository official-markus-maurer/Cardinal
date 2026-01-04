const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const renderer = engine.vulkan_renderer;
const math = engine.math;
const Vec3 = math.Vec3;
const EditorState = @import("../editor_state.zig").EditorState;

pub fn update(state: *EditorState, dt: f32) void {
    const win = state.window;
    if (win.handle == null) return;
    if (dt <= 0.0) return;

    if (state.mouse_captured) {
        const delta = engine.input.getMouseDelta();
        const xoffset = delta.x;
        const yoffset = delta.y;

        state.yaw += @floatCast(xoffset * state.mouse_sensitivity);
        state.pitch += @floatCast(yoffset * state.mouse_sensitivity);

        if (state.pitch > 89.0) state.pitch = 89.0;
        if (state.pitch < -89.0) state.pitch = -89.0;

        // Update target
        const radYaw = state.yaw * std.math.pi / 180.0;
        const radPitch = state.pitch * std.math.pi / 180.0;

        var front = Vec3{
            .x = @cos(radYaw) * @cos(radPitch),
            .y = @sin(radPitch),
            .z = @sin(radYaw) * @cos(radPitch),
        };
        front = front.normalize();

        // Keyboard
        var speed = state.camera_speed * dt;
        if (engine.input.isActionPressed(win, "Sprint")) {
            speed *= 4.0;
        }

        const up = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
        const right = front.cross(up).normalize();

        if (engine.input.isActionPressed(win, "MoveForward")) {
            state.camera.position = state.camera.position.add(front.mul(speed));
        }
        if (engine.input.isActionPressed(win, "MoveBackward")) {
            state.camera.position = state.camera.position.sub(front.mul(speed));
        }
        if (engine.input.isActionPressed(win, "StrafeLeft")) {
            state.camera.position = state.camera.position.sub(right.mul(speed));
        }
        if (engine.input.isActionPressed(win, "StrafeRight")) {
            state.camera.position = state.camera.position.add(right.mul(speed));
        }

        if (engine.input.isActionPressed(win, "Jump")) {
            state.camera.position.y += speed;
        }
        if (engine.input.isActionPressed(win, "Descend")) {
            state.camera.position.y -= speed;
        }

        // Update target based on new position
        state.camera.target = state.camera.position.add(front);

        if (state.pbr_enabled) {
            renderer.cardinal_renderer_set_camera(state.renderer, &state.camera);
        }
    }
}
