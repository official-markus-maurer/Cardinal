const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const renderer = engine.vulkan_renderer;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;

pub fn update(state: *EditorState, dt: f32) void {
    const win = @as(?*c.GLFWwindow, @ptrCast(state.window.handle));
    if (win == null) return;
    if (dt <= 0.0) return;

    if (state.first_mouse) {
         log.cardinal_log_info("DEBUG: camera_controller - state.window: {*}, handle: {*}", .{state.window, win});
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
        
        var front: [3]f32 = undefined;
        front[0] = @cos(radYaw) * @cos(radPitch);
        front[1] = @sin(radPitch);
        front[2] = @sin(radYaw) * @cos(radPitch);
        
        const len = @sqrt(front[0]*front[0] + front[1]*front[1] + front[2]*front[2]);
        front[0] /= len;
        front[1] /= len;
        front[2] /= len;
        
        state.camera.target[0] = state.camera.position[0] + front[0];
        state.camera.target[1] = state.camera.position[1] + front[1];
        state.camera.target[2] = state.camera.position[2] + front[2];
        
        // Keyboard
        var speed = state.camera_speed * dt;
        if (c.glfwGetKey(win, c.GLFW_KEY_LEFT_CONTROL) == c.GLFW_PRESS) {
            speed *= 4.0;
        }

        var right: [3]f32 = undefined;
        const up = [3]f32{0.0, 1.0, 0.0};
        
        right[0] = front[1] * up[2] - front[2] * up[1];
        right[1] = front[2] * up[0] - front[0] * up[2];
        right[2] = front[0] * up[1] - front[1] * up[0];
        const rlen = @sqrt(right[0]*right[0] + right[1]*right[1] + right[2]*right[2]);
        right[0] /= rlen;
        right[1] /= rlen;
        right[2] /= rlen;
        
        if (c.glfwGetKey(win, c.GLFW_KEY_W) == c.GLFW_PRESS) {
            state.camera.position[0] += front[0] * speed;
            state.camera.position[1] += front[1] * speed;
            state.camera.position[2] += front[2] * speed;
        }
        if (c.glfwGetKey(win, c.GLFW_KEY_S) == c.GLFW_PRESS) {
            state.camera.position[0] -= front[0] * speed;
            state.camera.position[1] -= front[1] * speed;
            state.camera.position[2] -= front[2] * speed;
        }
        if (c.glfwGetKey(win, c.GLFW_KEY_A) == c.GLFW_PRESS) {
            state.camera.position[0] -= right[0] * speed;
            state.camera.position[1] -= right[1] * speed;
            state.camera.position[2] -= right[2] * speed;
        }
        if (c.glfwGetKey(win, c.GLFW_KEY_D) == c.GLFW_PRESS) {
            state.camera.position[0] += right[0] * speed;
            state.camera.position[1] += right[1] * speed;
            state.camera.position[2] += right[2] * speed;
        }
        
        if (c.glfwGetKey(win, c.GLFW_KEY_SPACE) == c.GLFW_PRESS) {
            state.camera.position[1] += speed;
        }
        if (c.glfwGetKey(win, c.GLFW_KEY_LEFT_SHIFT) == c.GLFW_PRESS) {
            state.camera.position[1] -= speed;
        }
        
        if (state.pbr_enabled) {
            renderer.cardinal_renderer_set_camera(state.renderer, &state.camera);
        }
    }
}
