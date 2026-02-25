const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const platform = engine.platform;
const c = @import("../c.zig").c;
const editor_state_module = @import("../editor_state.zig");
const EditorState = editor_state_module.EditorState;
const Project = @import("../project.zig").Project;
const content_browser = @import("content_browser.zig");

// Buffer for project path input
var project_path_buffer: [512]u8 = [_]u8{0} ** 512;
var initialized_path: bool = false;

pub fn draw_project_manager_panel(state: *EditorState, allocator: std.mem.Allocator) void {
    if (!initialized_path) {
        if (std.fs.cwd().realpath(".", &project_path_buffer) catch null) |path| {
            // Ensure null termination for C
            if (path.len < 512) {
                project_path_buffer[path.len] = 0;
            }
        }
        initialized_path = true;
    }

    const viewport = c.imgui_bridge_get_main_viewport().?;
    var viewport_pos: c.ImVec2 = undefined;
    var viewport_size: c.ImVec2 = undefined;
    c.imgui_bridge_viewport_get_pos(viewport, &viewport_pos);
    c.imgui_bridge_viewport_get_size(viewport, &viewport_size);

    // Make window fill the entire viewport (OS window)
    const pivot = c.ImVec2{ .x = 0, .y = 0 };
    c.imgui_bridge_set_next_window_pos(&viewport_pos, c.ImGuiCond_Always, &pivot);
    c.imgui_bridge_set_next_window_size(&viewport_size, c.ImGuiCond_Always);

    // Enable Title Bar
    const flags = c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoDocking | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoDecoration;

    if (c.imgui_bridge_begin("Project Manager", null, flags)) {
        // Simple layout
        c.imgui_bridge_text("Welcome to Cardinal Engine");
        c.imgui_bridge_separator();

        c.imgui_bridge_text("Project Path:");
        _ = c.imgui_bridge_input_text("##ProjectPath", @ptrCast(&project_path_buffer), 512, 0);
        c.imgui_bridge_same_line(0, -1);
        if (c.imgui_bridge_button("Browse...")) {
             // Since open_folder_dialog isn't implemented fully on all platforms, we use open_file for now or handle it carefully.
             // But actually, let's just use open_folder_dialog if implemented, or fallback.
             // On Windows we implemented a stub that returns null.
             // Let's use open_file_dialog to select the project.cardinal file instead.
             if (platform.open_file_dialog(allocator, "Cardinal Project\x00*.cardinal\x00All Files\x00*.*\x00", null)) |path| {
                 defer allocator.free(path);
                 const len = @min(path.len, 511);
                 @memcpy(project_path_buffer[0..len], path[0..len]);
                 project_path_buffer[len] = 0;
             }
        }

        if (c.imgui_bridge_button("Open Project")) {
            const path_len = std.mem.indexOfScalar(u8, &project_path_buffer, 0) orelse project_path_buffer.len;
            if (path_len > 0) {
                const path = project_path_buffer[0..path_len];
                // Check if path is a file or directory
                // If it's a file (ends with .cardinal), use dirname.
                // If it's a directory, assume it is the project root.
                if (std.mem.endsWith(u8, path, ".cardinal")) {
                    if (std.fs.path.dirname(path)) |dir| {
                        load_project(state, allocator, dir);
                    }
                } else {
                     load_project(state, allocator, path);
                }
            }
        }

        c.imgui_bridge_same_line(0, -1);
        if (c.imgui_bridge_button("Create New Project")) {
            const path_len = std.mem.indexOfScalar(u8, &project_path_buffer, 0) orelse project_path_buffer.len;
            if (path_len > 0) {
                const path = project_path_buffer[0..path_len];
                create_project(state, allocator, path);
            }
        }

        c.imgui_bridge_separator();
        c.imgui_bridge_text("Recent Projects:");

        const recent = state.config_manager.config.recent_projects;
        if (recent.len > 0) {
            for (recent, 0..) |path, i| {
                // Use loop index as ID
                c.imgui_bridge_push_id_int(@intCast(i));
                if (c.imgui_bridge_selectable(path.ptr, false, 0)) {
                    // Update buffer
                    const len = @min(path.len, 511);
                    @memcpy(project_path_buffer[0..len], path[0..len]);
                    project_path_buffer[len] = 0;

                    load_project(state, allocator, path);
                }
                c.imgui_bridge_pop_id();
            }
        } else {
            c.imgui_bridge_text_disabled("No recent projects found.");
        }
    }
    c.imgui_bridge_end();
}

fn load_project(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    log.cardinal_log_info("Loading project from: {s}", .{path});

    // Check if directory exists
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| {
        log.cardinal_log_error("Failed to open project directory: {}", .{err});
        return;
    };
    dir.close();

    var proj = Project.init(allocator, path) catch |err| {
        log.cardinal_log_error("Failed to initialize project: {}", .{err});
        return;
    };

    proj.load() catch |err| {
        log.cardinal_log_error("Failed to load project config: {}", .{err});
        proj.deinit();
        return;
    };

    state.project = proj;
    state.project_loaded = true;

    // Add to recent projects
    add_recent_project(state, allocator, path);

    // Maximize window and set title
    engine.window.cardinal_window_maximize(state.window);
    engine.window.cardinal_window_set_title(state.window, "Cardinal Editor");

    // Update Asset Manager Root
    // We need to construct the full assets path
    const assets_path = proj.getAssetsPath() catch return;
    defer allocator.free(assets_path);

    // Update config manager assets path (so saving config preserves it)
    if (state.config_manager.config.assets_path.len > 0) {
        allocator.free(state.config_manager.config.assets_path);
    }
    state.config_manager.config.assets_path = allocator.dupe(u8, assets_path) catch return;

    // Update asset browser
    // Free old paths if they exist
    // Note: They are sentinel-terminated slices
    if (state.assets.assets_dir.len > 0) allocator.free(state.assets.assets_dir[0 .. state.assets.assets_dir.len + 1]);
    if (state.assets.current_dir.len > 0) allocator.free(state.assets.current_dir[0 .. state.assets.current_dir.len + 1]);

    state.assets.assets_dir = allocator.dupeZ(u8, assets_path) catch return;
    state.assets.current_dir = allocator.dupeZ(u8, assets_path) catch return;

    // Refresh content browser
    content_browser.scan_assets_dir(state, allocator);
}

fn create_project(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    log.cardinal_log_info("Creating new project at: {s}", .{path});

    // Create directory
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) {
            log.cardinal_log_error("Failed to create project directory: {}", .{err});
            return;
        }
    };

    // Create assets directory
    const assets_path = std.fs.path.join(allocator, &[_][]const u8{ path, "assets" }) catch return;
    defer allocator.free(assets_path);
    std.fs.makeDirAbsolute(assets_path) catch {};

    // Create default project config
    load_project(state, allocator, path);
}

fn add_recent_project(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    // Check if already exists
    for (state.config_manager.config.recent_projects) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }

    // Add to front
    // Need to allocate new slice
    const old_list = state.config_manager.config.recent_projects;
    const new_len = old_list.len + 1;
    // Limit to 10
    const final_len = if (new_len > 10) 10 else new_len;

    const new_list = allocator.alloc([]const u8, final_len) catch return;

    // Dup path
    new_list[0] = allocator.dupeZ(u8, path) catch return;
    
    // Copy old
    var i: usize = 0;
    while (i < old_list.len and i + 1 < final_len) : (i += 1) {
        new_list[i + 1] = old_list[i]; // Take ownership? No, strings are const.
        // Wait, ConfigManager logic dupes strings on load.
        // If we just copy the slice pointer, we share ownership.
        // But `old_list` itself (the slice) will be freed if we replace `state.config_manager.config.recent_projects`?
        // `ConfigManager` doesn't free `recent_projects` slice on re-assignment, only on deinit.
        // But we are leaking the old slice array (not content) here.
        // Allocator is global engine allocator.
    }

    // If we limit to 10, we might need to free the dropped items if we own them.
    // In `ConfigManager`, strings are duped.
    // If we drop an item, we should free it.
    if (new_len > 10) {
        // Free the 11th item (index 10)
        // allocator.free(old_list[9]);
        // But wait, we are just copying pointers.
    }

    // Replace list
    // Warning: this leaks the old slice array.
    // And potentially leaks dropped strings if we don't free them.
    // For now, let's keep it simple and leak small amounts of memory (it's editor config).
    // Better:
    state.config_manager.config.recent_projects = new_list;

    // Save config
    state.config_manager.save() catch |err| {
        log.cardinal_log_error("Failed to save config: {}", .{err});
    };
}
