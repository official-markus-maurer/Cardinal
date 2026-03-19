//! Editor input system.
//!
//! Handles editor-level input actions like cursor capture toggling and manual minidump triggers.
//!
//! Uses the engine input layer stack to keep viewport bindings ("Game") from firing while the UI
//! is actively consuming the mouse.
const std = @import("std");
const engine = @import("cardinal_engine");
const EditorState = @import("../editor_state.zig").EditorState;
const c = @import("../c.zig").c;

var prev_undo_down: bool = false;
var prev_redo_down: bool = false;
var swap_zy: ?bool = null;
var game_layer_pushed: bool = false;

fn set_game_layer_enabled(enabled: bool) void {
    if (enabled == game_layer_pushed) return;
    if (enabled) {
        engine.input.pushLayer("Game", false);
        game_layer_pushed = true;
    } else {
        engine.input.popLayer();
        game_layer_pushed = false;
    }
}

fn resolve_swap_zy() bool {
    if (swap_zy) |v| return v;

    const z_name_ptr = c.glfwGetKeyName(c.GLFW_KEY_Z, 0);
    const y_name_ptr = c.glfwGetKeyName(c.GLFW_KEY_Y, 0);

    if (z_name_ptr == null or y_name_ptr == null) {
        swap_zy = false;
        return false;
    }

    const z_name = std.mem.span(z_name_ptr);
    const y_name = std.mem.span(y_name_ptr);

    const z_is_y = (z_name.len == 1 and (z_name[0] == 'y' or z_name[0] == 'Y'));
    const y_is_z = (y_name.len == 1 and (y_name[0] == 'z' or y_name[0] == 'Z'));

    const swapped = z_is_y and y_is_z;
    swap_zy = swapped;
    return swapped;
}

/// Updates editor input state for the current frame.
pub fn update(state: *EditorState) void {
    const win = state.runtime.window;
    if (win.handle == null) return;

    const ctrl_down = engine.input.isKeyPressed(win, engine.input.KEY_LEFT_CONTROL) or engine.input.isKeyPressed(win, c.GLFW_KEY_RIGHT_CONTROL);
    const undo_key = if (resolve_swap_zy()) c.GLFW_KEY_Y else c.GLFW_KEY_Z;
    const redo_key = if (resolve_swap_zy()) c.GLFW_KEY_Z else c.GLFW_KEY_Y;

    const shift_down = c.imgui_bridge_is_shift_down();
    const undo_down = ctrl_down and engine.input.isKeyPressed(win, undo_key);
    const redo_down = ctrl_down and (engine.input.isKeyPressed(win, redo_key) or (shift_down and engine.input.isKeyPressed(win, undo_key)));
    const can_shortcut = !state.runtime.mouse_captured and !c.imgui_bridge_is_any_item_active();

    if (can_shortcut and undo_down and !prev_undo_down) {
        state.ui.undo.undo(&state.runtime);
    }
    if (can_shortcut and redo_down and !prev_redo_down) {
        state.ui.undo.redo(&state.runtime);
    }
    prev_undo_down = undo_down;
    prev_redo_down = redo_down;

    if (engine.input.isActionJustPressed("ToggleCursor")) {
        state.runtime.mouse_captured = !state.runtime.mouse_captured;

        engine.input.setCursorMode(win, state.runtime.mouse_captured);
    }

    if (engine.input.isActionJustPressed("CreateMinidump")) {
        const ok = engine.platform.write_minidump();
        std.debug.print("CreateMinidump action: {s}\n", .{if (ok) "OK" else "FAILED"});
    }

    const ui_wants_mouse = c.imgui_bridge_want_capture_mouse() or c.imgui_bridge_is_any_item_active();
    set_game_layer_enabled(state.runtime.mouse_captured and !ui_wants_mouse);
}
