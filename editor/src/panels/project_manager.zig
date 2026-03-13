//! Project manager panel.
//!
//! Provides a launcher-style UI to open/create projects and manage the recent project list.
//!
//! TODO: Fix ownership/lifetime of recent project strings to avoid leaks.
const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const platform = engine.platform;
const c = @import("../c.zig").c;
const editor_state_module = @import("../editor_state.zig");
const EditorState = editor_state_module.EditorState;
const Project = @import("../project.zig").Project;
const content_browser = @import("content_browser.zig");

/// Buffer for project path input.
var project_path_buffer: [512]u8 = [_]u8{0} ** 512;
var initialized_path: bool = false;

/// Draws the fullscreen project manager panel.
pub fn draw_project_manager_panel(state: *EditorState, allocator: std.mem.Allocator) void {
    if (!initialized_path) {
        if (std.fs.cwd().realpath(".", &project_path_buffer) catch null) |path| {
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

    const pivot = c.ImVec2{ .x = 0, .y = 0 };
    c.imgui_bridge_set_next_window_pos(&viewport_pos, c.ImGuiCond_Always, &pivot);
    c.imgui_bridge_set_next_window_size(&viewport_size, c.ImGuiCond_Always);

    const flags = c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoDocking | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoDecoration;

    if (c.imgui_bridge_begin("Project Manager", null, flags)) {
        c.imgui_bridge_text("Welcome to Cardinal Engine");
        c.imgui_bridge_separator();

        c.imgui_bridge_text("Project Path:");
        _ = c.imgui_bridge_input_text("##ProjectPath", @ptrCast(&project_path_buffer), 512, 0);
        c.imgui_bridge_same_line(0, -1);
        if (c.imgui_bridge_button("Browse...")) {
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
                c.imgui_bridge_push_id_int(@intCast(i));
                if (c.imgui_bridge_selectable(path.ptr, false, 0)) {
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

/// Loads a project directory and updates editor state accordingly.
fn load_project(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    log.cardinal_log_info("Loading project from: {s}", .{path});

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

    engine.window.cardinal_window_maximize(state.window);
    engine.window.cardinal_window_set_title(state.window, "Cardinal Editor");

    const assets_path = proj.getAssetsPath() catch return;
    defer allocator.free(assets_path);

    if (state.config_manager.config.assets_path.len > 0) {
        allocator.free(state.config_manager.config.assets_path);
    }
    state.config_manager.config.assets_path = allocator.dupe(u8, assets_path) catch return;

    if (state.assets.assets_dir.len > 0) allocator.free(state.assets.assets_dir[0 .. state.assets.assets_dir.len + 1]);
    if (state.assets.current_dir.len > 0) allocator.free(state.assets.current_dir[0 .. state.assets.current_dir.len + 1]);

    state.assets.assets_dir = allocator.dupeZ(u8, assets_path) catch return;
    state.assets.current_dir = allocator.dupeZ(u8, assets_path) catch return;

    content_browser.scan_assets_dir(state, allocator);
}

/// Creates a new project directory and loads it.
fn create_project(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    log.cardinal_log_info("Creating new project at: {s}", .{path});

    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) {
            log.cardinal_log_error("Failed to create project directory: {}", .{err});
            return;
        }
    };

    const assets_path = std.fs.path.join(allocator, &[_][]const u8{ path, "assets" }) catch return;
    defer allocator.free(assets_path);
    std.fs.makeDirAbsolute(assets_path) catch {};

    load_project(state, allocator, path);
}

fn add_recent_project(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    // TODO: Fix ownership and properly free/rotate recent project storage.
    for (state.config_manager.config.recent_projects) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }

    const old_list = state.config_manager.config.recent_projects;
    const new_len = old_list.len + 1;
    const final_len = if (new_len > 10) 10 else new_len;

    const new_list = allocator.alloc([]const u8, final_len) catch return;

    new_list[0] = allocator.dupeZ(u8, path) catch return;

    var i: usize = 0;
    while (i < old_list.len and i + 1 < final_len) : (i += 1) {
        new_list[i + 1] = old_list[i];
    }
    state.config_manager.config.recent_projects = new_list;

    state.config_manager.save() catch |err| {
        log.cardinal_log_error("Failed to save config: {}", .{err});
    };
}
