const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const renderer = engine.vulkan_renderer;
const math = engine.math;
const Vec3 = math.Vec3;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;

pub fn update(state: *EditorState, dt: f32) void {
    const win = @as(?*c.GLFWwindow, @ptrCast(state.window.handle));
    if (win == null) return;
    if (dt <= 0.0) return;

    if (state.first_mouse) {
        log.cardinal_log_info("DEBUG: camera_controller - state.window: {*}, handle: {*}", .{ state.window, win });
    }

    if (state.mouse_captured) {
        var xpos: f64 = 0;
        var ypos: f64 = 0;
        c.glfwGetCursorPos(win, &xpos, &ypos);

        if (state.first_mouse) {
            state.last_mouse_x = xpos;
            state.last_mouse_y = ypos;
            state.first_mouse = false;
        }

        const xoffset = xpos - state.last_mouse_x;
        const yoffset = state.last_mouse_y - ypos; // Reversed
        state.last_mouse_x = xpos;
        state.last_mouse_y = ypos;

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
        if (c.glfwGetKey(win, c.GLFW_KEY_LEFT_CONTROL) == c.GLFW_PRESS) {
            speed *= 4.0;
        }

        const up = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
        const right = front.cross(up).normalize();

        if (c.glfwGetKey(win, c.GLFW_KEY_W) == c.GLFW_PRESS) {
            state.camera.position = state.camera.position.add(front.mul(speed));
        }
        if (c.glfwGetKey(win, c.GLFW_KEY_S) == c.GLFW_PRESS) {
            state.camera.position = state.camera.position.sub(front.mul(speed));
        }
        if (c.glfwGetKey(win, c.GLFW_KEY_A) == c.GLFW_PRESS) {
            state.camera.position = state.camera.position.sub(right.mul(speed));
        }
        if (c.glfwGetKey(win, c.GLFW_KEY_D) == c.GLFW_PRESS) {
            state.camera.position = state.camera.position.add(right.mul(speed));
        }

        if (c.glfwGetKey(win, c.GLFW_KEY_SPACE) == c.GLFW_PRESS) {
            state.camera.position.y += speed;
        }
        if (c.glfwGetKey(win, c.GLFW_KEY_LEFT_SHIFT) == c.GLFW_PRESS) {
            state.camera.position.y -= speed;
        }

        // Update target based on new position
        state.camera.target = state.camera.position.add(front);

        if (state.pbr_enabled) {
            renderer.cardinal_renderer_set_camera(state.renderer, &state.camera);
        }
    }
}
