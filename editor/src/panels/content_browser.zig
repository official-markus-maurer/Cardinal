const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const loader = engine.loader;
const async_loader = engine.async_loader;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;
const AssetState = @import("../editor_state.zig").AssetState;

fn get_asset_type(path: []const u8) AssetState.AssetType {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".gltf")) return .GLTF;
    if (std.mem.eql(u8, ext, ".glb")) return .GLB;
    if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or
        std.mem.eql(u8, ext, ".tga") or std.mem.eql(u8, ext, ".bmp") or
        std.mem.eql(u8, ext, ".jpeg")) return .TEXTURE;
    return .OTHER;
}

pub fn scan_assets_dir(state: *EditorState, allocator: std.mem.Allocator) void {
    log.cardinal_log_info("Scanning assets dir: {s}", .{state.assets.current_dir});

    // Clear old entries
    for (state.assets.entries.items) |entry| {
        entry.deinit(allocator);
    }
    state.assets.entries.clearRetainingCapacity();
    state.assets.filtered_entries.clearRetainingCapacity();

    var dir = std.fs.openDirAbsolute(state.assets.current_dir, .{ .iterate = true }) catch |err| {
        log.cardinal_log_error("Failed to open directory {s}: {}", .{ state.assets.current_dir, err });
        return;
    };
    defer dir.close();

    // Add parent directory if not root
    const parent_path = std.fs.path.dirname(state.assets.current_dir);
    if (parent_path) |parent| {
        if (!std.mem.eql(u8, state.assets.current_dir, state.assets.assets_dir)) {
            state.assets.entries.append(allocator, .{
                .display = allocator.dupeZ(u8, "..") catch return,
                .full_path = allocator.dupeZ(u8, parent) catch return,
                .relative_path = allocator.dupeZ(u8, "..") catch return,
                .type = .FOLDER,
                .is_directory = true,
            }) catch return;
        }
    }

    var iterator = dir.iterate();
    while (iterator.next() catch return) |entry| {
        const full_path = std.fs.path.join(allocator, &[_][]const u8{ state.assets.current_dir, entry.name }) catch continue;
        const relative = std.fs.path.relative(allocator, state.assets.assets_dir, full_path) catch full_path;

        var asset_type: AssetState.AssetType = .OTHER;
        var is_dir = false;

        if (entry.kind == .directory) {
            asset_type = .FOLDER;
            is_dir = true;
        } else {
            asset_type = get_asset_type(entry.name);
        }

        const full_path_z = allocator.dupeZ(u8, full_path) catch continue;
        const relative_z = allocator.dupeZ(u8, relative) catch continue;

        const full_path_start = @intFromPtr(full_path.ptr);
        const full_path_end = full_path_start + full_path.len;
        const assets_dir_start = @intFromPtr(state.assets.assets_dir.ptr);
        const assets_dir_end = assets_dir_start + state.assets.assets_dir.len;
        const relative_start = @intFromPtr(relative.ptr);

        const is_slice_of_full = (relative_start >= full_path_start and relative_start < full_path_end);
        const is_slice_of_assets = (relative_start >= assets_dir_start and relative_start < assets_dir_end);

        if (!is_slice_of_full and !is_slice_of_assets) {
            allocator.free(relative);
        }

        if (full_path.ptr != state.assets.current_dir.ptr) allocator.free(full_path);

        state.assets.entries.append(allocator, .{
            .display = allocator.dupeZ(u8, entry.name) catch continue,
            .full_path = full_path_z,
            .relative_path = relative_z,
            .type = asset_type,
            .is_directory = is_dir,
        }) catch continue;
    }

    // Sort
    std.sort.block(AssetState.AssetEntry, state.assets.entries.items, {}, struct {
        fn less(_: void, lhs: AssetState.AssetEntry, rhs: AssetState.AssetEntry) bool {
            if (std.mem.eql(u8, lhs.display, "..")) return true;
            if (std.mem.eql(u8, rhs.display, "..")) return false;
            if (lhs.is_directory != rhs.is_directory) return lhs.is_directory;
            return std.mem.lessThan(u8, lhs.display, rhs.display);
        }
    }.less);

    // Filter
    const filter_text = std.mem.span(@as([*:0]const u8, @ptrCast(&state.assets.search_filter)));

    for (state.assets.entries.items) |entry| {
        if (filter_text.len > 0) {
            if (std.mem.indexOf(u8, entry.display, filter_text) == null) continue;
        }

        if (state.assets.show_folders_only and !entry.is_directory) continue;
        if (state.assets.show_gltf_only and entry.type != .GLTF and entry.type != .GLB) continue;
        if (state.assets.show_textures_only and entry.type != .TEXTURE) continue;

        state.assets.filtered_entries.append(allocator, entry) catch continue;
    }
}

pub fn load_scene(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    if (state.is_loading) {
        _ = std.fmt.bufPrintZ(&state.status_msg, "Already loading...", .{}) catch {};
        return;
    }

    if (state.loading_task) |task| {
        _ = async_loader.cardinal_async_cancel_task(task);
        async_loader.cardinal_async_free_task(task);
        state.loading_task = null;
    }

    if (state.loading_scene_path) |p| {
        allocator.free(p);
        state.loading_scene_path = null;
    }

    state.is_loading = true;
    _ = std.fmt.bufPrintZ(&state.status_msg, "Loading scene: {s}...", .{path}) catch {};

    const path_copy = allocator.dupeZ(u8, path) catch return;
    state.loading_scene_path = path_copy;

    state.loading_task = loader.cardinal_scene_load_async(path_copy, .HIGH, null, null);
}

pub fn draw_asset_browser_panel(state: *EditorState, allocator: std.mem.Allocator) void {
    if (state.show_assets) {
        if (c.imgui_bridge_begin("Assets", &state.show_assets, 0)) {
            c.imgui_bridge_text("Project Assets");
            c.imgui_bridge_separator();

            c.imgui_bridge_text("Assets Root:");
            c.imgui_bridge_set_next_item_width(-1.0);

            if (c.imgui_bridge_button("Refresh")) {
                scan_assets_dir(state, allocator);
            }

            c.imgui_bridge_text("Current: %s", state.assets.current_dir.ptr);

            c.imgui_bridge_separator();

            c.imgui_bridge_text("Search & Filter:");
            c.imgui_bridge_set_next_item_width(-1.0);

            if (c.imgui_bridge_input_text_with_hint("##search_filter", "Search files...", @as([*c]u8, @ptrCast(state.assets.search_filter.ptr)), state.assets.search_filter.len)) {
                scan_assets_dir(state, allocator);
            }

            var filter_changed = false;
            if (c.imgui_bridge_checkbox("Folders Only", &state.assets.show_folders_only)) filter_changed = true;
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_checkbox("glTF/GLB", &state.assets.show_gltf_only)) filter_changed = true;
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_checkbox("Textures", &state.assets.show_textures_only)) filter_changed = true;

            if (filter_changed) {
                scan_assets_dir(state, allocator);
            }

            if (c.imgui_bridge_button("Clear Filters")) {
                @memset(state.assets.search_filter, 0);
                state.assets.show_folders_only = false;
                state.assets.show_gltf_only = false;
                state.assets.show_textures_only = false;
                scan_assets_dir(state, allocator);
            }

            c.imgui_bridge_separator();

            c.imgui_bridge_text("Load Scene (glTF/glb)");
            c.imgui_bridge_set_next_item_width(-1.0);
            if (c.imgui_bridge_input_text_with_hint("##scene_path", "C:/path/to/scene.gltf or .glb", @ptrCast(&state.scene_path), state.scene_path.len)) {
                // Input handling
            }
            if (c.imgui_bridge_button("Load")) {
                const path_len = std.mem.indexOf(u8, &state.scene_path, &[_]u8{0}) orelse state.scene_path.len;
                if (path_len > 0) {
                    load_scene(state, allocator, state.scene_path[0..path_len]);
                }
            }

            if (state.is_loading) {
                c.imgui_bridge_same_line(0, -1);
                c.imgui_bridge_text("Loading...");
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_begin_child("##assets_list", 0, 0, true, 0)) {
                if (state.assets.filtered_entries.items.len == 0) {
                    c.imgui_bridge_text_disabled("No assets found in '%s'", state.assets.current_dir.ptr);
                } else {
                    for (state.assets.filtered_entries.items) |entry| {
                        const icon = switch (entry.type) {
                            .FOLDER => "[D]",
                            .GLTF, .GLB => "[M]",
                            .TEXTURE => "[T]",
                            else => "[F]",
                        };
                        c.imgui_bridge_text("%s", icon);
                        c.imgui_bridge_same_line(0, -1);

                        if (c.imgui_bridge_selectable(@as([*:0]const u8, @ptrCast(entry.display.ptr)), false, 0)) {
                            if (entry.is_directory) {
                                const old_dir = state.assets.current_dir;
                                if (std.mem.eql(u8, entry.display, "..")) {
                                    const parent = std.fs.path.dirname(old_dir) orelse old_dir;
                                    state.assets.current_dir = allocator.dupeZ(u8, parent) catch old_dir;
                                } else {
                                    state.assets.current_dir = allocator.dupeZ(u8, entry.full_path) catch old_dir;
                                }

                                if (state.assets.current_dir.ptr != old_dir.ptr) allocator.free(old_dir[0 .. old_dir.len + 1]);
                                scan_assets_dir(state, allocator);
                                break;
                            } else if (entry.type == .GLTF or entry.type == .GLB) {
                                load_scene(state, allocator, entry.full_path);
                            }
                        }

                        if (!entry.is_directory and c.imgui_bridge_is_item_hovered(0) and c.imgui_bridge_is_mouse_double_clicked(0)) {
                            if (entry.type == .GLTF or entry.type == .GLB) {
                                load_scene(state, allocator, entry.full_path);
                            }
                        }
                    }
                }
            }
            c.imgui_bridge_end_child();
        }
        c.imgui_bridge_end();
    }
}
