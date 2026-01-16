const std = @import("std");
const engine = @import("cardinal_engine");
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;
const scene_io = @import("../systems/scene_io.zig");

pub fn draw_scene_manager_panel(state: *EditorState, allocator: std.mem.Allocator) void {
    if (state.show_scene_manager) {
        const open = c.imgui_bridge_begin("Scene Manager", &state.show_scene_manager, 0);
        defer c.imgui_bridge_end();

        if (open) {
            // Save Scene
            c.imgui_bridge_text("Save As:");
            c.imgui_bridge_set_next_item_width(-1.0);
            _ = c.imgui_bridge_input_text_with_hint("##save_scene_name", "Scene Name (e.g. my_scene)", @ptrCast(&state.save_scene_name), state.save_scene_name.len);

            if (c.imgui_bridge_button("Save Scene")) {
                const len = std.mem.indexOf(u8, &state.save_scene_name, &[_]u8{0}) orelse state.save_scene_name.len;
                if (len > 0) {
                    const name = state.save_scene_name[0..len];
                    var path_buf: [512]u8 = undefined;
                    const full_path = std.fmt.bufPrint(&path_buf, "assets/scenes/{s}{s}", .{ name, if (std.mem.endsWith(u8, name, ".json")) "" else ".json" }) catch "assets/scenes/scene.json";

                    scene_io.save_scene(state, allocator, full_path);
                    scene_io.refresh_available_scenes(state, allocator);
                }
            }

            c.imgui_bridge_separator();

            // Load Scene List
            c.imgui_bridge_text("Available Scenes:");
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Refresh")) {
                scene_io.refresh_available_scenes(state, allocator);
            }

            if (c.imgui_bridge_begin_child("##scene_list", 0, 0, true, 0)) {
                if (state.available_scenes.items.len == 0) {
                    c.imgui_bridge_text_disabled("No scenes found.");
                } else {
                    for (state.available_scenes.items) |scene_name| {
                        // Cast slice pointer to C pointer (it's null terminated from dupeZ)
                        const name_ptr: [*:0]const u8 = @ptrCast(scene_name.ptr);
                        if (c.imgui_bridge_button(name_ptr)) {
                            var path_buf: [512]u8 = undefined;
                            const full_path = std.fmt.bufPrint(&path_buf, "assets/scenes/{s}", .{scene_name}) catch "assets/scenes/scene.json";
                            scene_io.load_scene(state, allocator, full_path);
                        }

                        // Right-click context menu
                        if (c.imgui_bridge_is_item_clicked(1)) {
                            // Copy name to scene_context_menu_name
                            const len = @min(scene_name.len, state.scene_context_menu_name.len - 1);
                            @memcpy(state.scene_context_menu_name[0..len], scene_name[0..len]);
                            state.scene_context_menu_name[len] = 0;

                            // Initialize rename buffer
                            @memset(&state.rename_scene_buffer, 0);
                            @memcpy(state.rename_scene_buffer[0..len], scene_name[0..len]);

                            c.imgui_bridge_open_popup("SceneContextMenu");
                        }
                    }
                }

                // Context Menu
                if (c.imgui_bridge_begin_popup("SceneContextMenu", 0)) {
                    c.imgui_bridge_text("Actions for:");
                    c.imgui_bridge_text(@ptrCast(&state.scene_context_menu_name));
                    c.imgui_bridge_separator();

                    if (c.imgui_bridge_menu_item("Rename", null, false, true)) {
                        state.open_rename_popup = true;
                        c.imgui_bridge_close_current_popup();
                    }

                    if (c.imgui_bridge_menu_item("Delete", null, false, true)) {
                        state.open_delete_popup = true;
                        c.imgui_bridge_close_current_popup();
                    }

                    c.imgui_bridge_end_popup();
                }
            }
            c.imgui_bridge_end_child();

            if (state.open_rename_popup) {
                c.imgui_bridge_open_popup("Rename Scene");
                state.open_rename_popup = false;
            }

            if (state.open_delete_popup) {
                c.imgui_bridge_open_popup("Delete Scene");
                state.open_delete_popup = false;
            }

            // Rename Popup
            if (c.imgui_bridge_begin_popup_modal("Rename Scene", null, 1 << 6)) { // ImGuiWindowFlags_AlwaysAutoResize
                c.imgui_bridge_text("New Name:");
                if (c.imgui_bridge_is_window_appearing()) {
                    c.imgui_bridge_set_keyboard_focus_here(0);
                }
                const flags = (1 << 5) | (1 << 4); // ImGuiInputTextFlags_EnterReturnsTrue | ImGuiInputTextFlags_AutoSelectAll
                const enter_pressed = c.imgui_bridge_input_text("##new_name", @ptrCast(&state.rename_scene_buffer), state.rename_scene_buffer.len, flags);

                if (c.imgui_bridge_button("Rename") or enter_pressed) {
                    // Check if rename buffer is empty, if so, don't rename
                    const len = std.mem.indexOf(u8, &state.rename_scene_buffer, &[_]u8{0}) orelse state.rename_scene_buffer.len;
                    if (len > 0) {
                        rename_scene(state, allocator);
                        c.imgui_bridge_close_current_popup();
                        scene_io.refresh_available_scenes(state, allocator);
                    }
                }
                c.imgui_bridge_same_line(0, -1);
                if (c.imgui_bridge_button("Cancel") or c.imgui_bridge_is_key_pressed(526)) { // ImGuiKey_Escape
                    c.imgui_bridge_close_current_popup();
                }
                c.imgui_bridge_end_popup();
            }

            // Delete Popup
            if (c.imgui_bridge_begin_popup_modal("Delete Scene", null, 1 << 6)) { // ImGuiWindowFlags_AlwaysAutoResize
                c.imgui_bridge_text("Are you sure you want to delete?");
                c.imgui_bridge_text(@ptrCast(&state.scene_context_menu_name));
                c.imgui_bridge_separator();

                if (c.imgui_bridge_button("Yes, Delete")) {
                    delete_scene(state, allocator);
                    c.imgui_bridge_close_current_popup();
                    scene_io.refresh_available_scenes(state, allocator);
                }
                c.imgui_bridge_same_line(0, -1);
                if (c.imgui_bridge_button("Cancel")) {
                    c.imgui_bridge_close_current_popup();
                }
                c.imgui_bridge_end_popup();
            }
        }
    }
}

fn rename_scene(state: *EditorState, allocator: std.mem.Allocator) void {
    _ = allocator;
    const old_name_len = std.mem.indexOf(u8, &state.scene_context_menu_name, &[_]u8{0}) orelse state.scene_context_menu_name.len;
    if (old_name_len == 0) return;
    const old_name = state.scene_context_menu_name[0..old_name_len];

    const new_name_len = std.mem.indexOf(u8, &state.rename_scene_buffer, &[_]u8{0}) orelse state.rename_scene_buffer.len;
    if (new_name_len == 0) return;
    const new_name = state.rename_scene_buffer[0..new_name_len];

    var old_path_buf: [512]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_path_buf, "assets/scenes/{s}", .{old_name}) catch return;

    // Check if new path has .json extension, if not append it
    // Actually, user might have removed it, or added it.
    // If user provided extension, use it. If not, append .json if old one had it?
    // Let's assume we want to keep it simple: just rename as user typed.
    // But if user typed "myscene" and old was "oldscene.json", we probably want "myscene.json".

    // Better logic: ensure .json extension if it's missing.
    var final_new_path_buf: [512]u8 = undefined;
    var final_new_path: []const u8 = undefined;

    if (std.mem.endsWith(u8, new_name, ".json")) {
        final_new_path = std.fmt.bufPrint(&final_new_path_buf, "assets/scenes/{s}", .{new_name}) catch return;
    } else {
        final_new_path = std.fmt.bufPrint(&final_new_path_buf, "assets/scenes/{s}.json", .{new_name}) catch return;
    }

    std.fs.cwd().rename(old_path, final_new_path) catch |err| {
        std.log.err("Failed to rename scene from {s} to {s}: {any}", .{ old_path, final_new_path, err });
    };
}

fn delete_scene(state: *EditorState, allocator: std.mem.Allocator) void {
    _ = allocator;
    const name_len = std.mem.indexOf(u8, &state.scene_context_menu_name, &[_]u8{0}) orelse state.scene_context_menu_name.len;
    if (name_len == 0) return;
    const name = state.scene_context_menu_name[0..name_len];

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "assets/scenes/{s}", .{name}) catch return;

    std.fs.cwd().deleteFile(path) catch |err| {
        std.log.err("Failed to delete scene {s}: {any}", .{ path, err });
    };
}
