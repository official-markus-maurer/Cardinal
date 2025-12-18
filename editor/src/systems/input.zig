const std = @import("std");
const engine = @import("cardinal_engine");
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;

pub fn update(state: *EditorState) void {
    const win = @as(?*c.GLFWwindow, @ptrCast(state.window.handle));
    if (win == null) return;
    
    // Toggle capture
    const tab_pressed = c.glfwGetKey(win, c.GLFW_KEY_TAB) == c.GLFW_PRESS;
    if (tab_pressed and !state.tab_key_pressed) {
        state.mouse_captured = !state.mouse_captured;
        state.first_mouse = true;
        
        if (state.mouse_captured) {
            c.glfwSetInputMode(win, c.GLFW_CURSOR, c.GLFW_CURSOR_DISABLED);
        } else {
            c.glfwSetInputMode(win, c.GLFW_CURSOR, c.GLFW_CURSOR_NORMAL);
        }
    }
    state.tab_key_pressed = tab_pressed;
}
