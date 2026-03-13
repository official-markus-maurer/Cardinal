//! Editor input system.
//!
//! Handles editor-level input actions like cursor capture toggling and manual minidump triggers.
//!
//! TODO: Add separate input layers for UI vs viewport interaction.
const std = @import("std");
const engine = @import("cardinal_engine");
const EditorState = @import("../editor_state.zig").EditorState;

/// Updates editor input state for the current frame.
pub fn update(state: *EditorState) void {
    const win = state.window;
    if (win.handle == null) return;

    const tab_pressed = engine.input.isActionPressed(win, "ToggleCursor");
    if (tab_pressed and !state.tab_key_pressed) {
        state.mouse_captured = !state.mouse_captured;

        engine.input.setCursorMode(win, state.mouse_captured);

        if (state.mouse_captured) {
            engine.input.pushLayer("Game", false);
        } else {
            engine.input.popLayer();
        }
    }
    state.tab_key_pressed = tab_pressed;

    if (engine.input.isActionPressed(win, "CreateMinidump")) {
        const ok = engine.platform.write_minidump();
        std.debug.print("CreateMinidump action: {s}\n", .{if (ok) "OK" else "FAILED"});
    }
}
