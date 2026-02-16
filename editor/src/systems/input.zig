const std = @import("std");
const engine = @import("cardinal_engine");
const EditorState = @import("../editor_state.zig").EditorState;

pub fn update(state: *EditorState) void {
    const win = state.window;
    if (win.handle == null) return;

    // Toggle capture
    const tab_pressed = engine.input.isActionPressed(win, "ToggleCursor");
    if (tab_pressed and !state.tab_key_pressed) {
        state.mouse_captured = !state.mouse_captured;

        engine.input.setCursorMode(win, state.mouse_captured);
        
        if (state.mouse_captured) {
            engine.input.pushLayer("Game", false); // Don't block Base layer (ToggleCursor)
        } else {
            engine.input.popLayer(); // Pop Game
        }
    }
    state.tab_key_pressed = tab_pressed;

    // Manual minidump trigger (Print Screen)
    if (engine.input.isActionPressed(win, "CreateMinidump")) {
        const ok = engine.platform.write_minidump();
        std.debug.print("CreateMinidump action: {s}\n", .{if (ok) "OK" else "FAILED"});
    }
}
