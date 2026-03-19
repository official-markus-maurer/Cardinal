//! Content browser panel (asset scanning and file actions).
//!
//! Provides directory scanning, filtering, and simple actions like loading scenes and setting
//! a skybox texture.
//!
//! TODO: Cache directory scan results and update incrementally.
const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const loader = engine.loader;
const async_loader = engine.async_loader;
const vulkan_renderer = engine.vulkan_renderer;
const texture_loader = engine.texture_loader;
const c = @import("../c.zig").c;
const editor_state_module = @import("../editor_state.zig");
const EditorState = editor_state_module.EditorState;
const LoadingTaskInfo = editor_state_module.LoadingTaskInfo;
const AssetState = editor_state_module.AssetState;

fn ensure_texture_thumbnail(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) u64 {
    if (state.runtime.asset_thumbnails.getPtr(path)) |existing| {
        return existing.imgui_id;
    }

    var tex = std.mem.zeroes(texture_loader.TextureData);
    const path_z = allocator.dupeZ(u8, path) catch return 0;
    defer allocator.free(path_z);

    if (!texture_loader.texture_load_from_disk(@ptrCast(path_z.ptr), &tex)) {
        return 0;
    }
    defer texture_loader.texture_data_free(&tex);

    if (tex.data == null or tex.width == 0 or tex.height == 0) return 0;
    if (tex.is_hdr != 0) return 0;
    if (tex.channels != 3 and tex.channels != 4) return 0;

    const thumb_size: u32 = 64;
    var thumb_buf = allocator.alloc(u8, @as(usize, thumb_size) * @as(usize, thumb_size) * 4) catch return 0;
    defer allocator.free(thumb_buf);

    const src = tex.data.?;
    const src_w: u32 = tex.width;
    const src_h: u32 = tex.height;
    const src_ch: u32 = tex.channels;

    var y: u32 = 0;
    while (y < thumb_size) : (y += 1) {
        var x: u32 = 0;
        const sy: u32 = @min((y * src_h) / thumb_size, src_h - 1);
        while (x < thumb_size) : (x += 1) {
            const sx: u32 = @min((x * src_w) / thumb_size, src_w - 1);
            const src_idx: usize = (@as(usize, sy) * @as(usize, src_w) + @as(usize, sx)) * @as(usize, src_ch);
            const dst_idx: usize = (@as(usize, y) * @as(usize, thumb_size) + @as(usize, x)) * 4;

            thumb_buf[dst_idx + 0] = src[src_idx + 0];
            thumb_buf[dst_idx + 1] = if (src_ch > 1) src[src_idx + 1] else src[src_idx + 0];
            thumb_buf[dst_idx + 2] = if (src_ch > 2) src[src_idx + 2] else src[src_idx + 0];
            thumb_buf[dst_idx + 3] = if (src_ch > 3) src[src_idx + 3] else 255;
        }
    }

    var handle: u32 = 0;
    if (!vulkan_renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, thumb_size, thumb_size, c.VK_FORMAT_R8G8B8A8_UNORM, &handle)) {
        return 0;
    }

    if (!vulkan_renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, handle, @ptrCast(thumb_buf.ptr), thumb_buf.len)) {
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    }

    var sampler_raw: ?*anyopaque = null;
    var view_raw: ?*anyopaque = null;
    if (!vulkan_renderer.cardinal_renderer_runtime_texture_get_vk_handles(state.runtime.renderer, handle, @ptrCast(@alignCast(&sampler_raw)), @ptrCast(@alignCast(&view_raw)))) {
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    }

    const imgui_id = c.imgui_bridge_vk_add_texture(@ptrCast(sampler_raw), @ptrCast(view_raw), c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    if (imgui_id == 0) {
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    }

    const key_copy = allocator.dupe(u8, path) catch {
        c.imgui_bridge_vk_remove_texture(imgui_id);
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    };
    state.runtime.asset_thumbnails.put(allocator, key_copy, .{
        .handle = handle,
        .imgui_id = imgui_id,
        .width = thumb_size,
        .height = thumb_size,
    }) catch {
        allocator.free(key_copy);
        c.imgui_bridge_vk_remove_texture(imgui_id);
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    };

    return imgui_id;
}

/// Returns the inferred asset type based on file extension.
fn get_asset_type(path: []const u8) AssetState.AssetType {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".gltf")) return .GLTF;
    if (std.mem.eql(u8, ext, ".glb")) return .GLB;
    if (std.mem.eql(u8, ext, ".kfm")) return .KFM;
    if (std.mem.eql(u8, ext, ".nif")) return .NIF;
    if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or
        std.mem.eql(u8, ext, ".tga") or std.mem.eql(u8, ext, ".bmp") or
        std.mem.eql(u8, ext, ".jpeg") or
        std.mem.eql(u8, ext, ".hdr") or
        std.mem.eql(u8, ext, ".exr")) return .TEXTURE;
    return .OTHER;
}

/// Loads an HDR/EXR texture and sets it as the renderer skybox.
fn load_skybox(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    const ext = std.fs.path.extension(path);
    if (!std.mem.eql(u8, ext, ".hdr") and !std.mem.eql(u8, ext, ".exr")) return;

    _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Loading skybox: {s}...", .{path}) catch {};

    if (state.runtime.skybox_path) |p| {
        allocator.free(p);
        state.runtime.skybox_path = null;
    }

    state.runtime.skybox_path = allocator.dupeZ(u8, path) catch return;

    var view = state.runtime.registry.view(engine.ecs_components.Skybox);
    var it = view.iterator();
    if (it.next()) |entry| {
        state.runtime.registry.add(entry.entity, engine.ecs_components.Skybox.init(path)) catch {};
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Skybox set to: {s}", .{path}) catch {};
    } else {
        const opts = engine.ecs_node_factory.CreateNodeOptions{ .skybox_path = path };
        _ = engine.ecs_node_factory.create_node(state.runtime.registry, null, .Skybox, "Skybox", opts) catch {};
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Skybox node created: {s}", .{path}) catch {};
    }
}

/// Scans the current assets directory, populating both raw and filtered entry lists.
pub fn scan_assets_dir(state: *EditorState, allocator: std.mem.Allocator) void {
    log.cardinal_log_info("Scanning assets dir: {s}", .{state.ui.assets.current_dir});

    for (state.ui.assets.entries.items) |entry| {
        entry.deinit(allocator);
    }
    state.ui.assets.entries.clearRetainingCapacity();
    state.ui.assets.filtered_entries.clearRetainingCapacity();

    var dir = std.fs.openDirAbsolute(state.ui.assets.current_dir, .{ .iterate = true }) catch |err| {
        log.cardinal_log_error("Failed to open directory {s}: {}", .{ state.ui.assets.current_dir, err });
        return;
    };
    defer dir.close();

    var meta_db: engine.asset_database.AssetDatabase = undefined;
    var meta_db_ready = false;
    defer if (meta_db_ready) meta_db.deinit();

    if (engine.asset_database.AssetDatabase.init(allocator, state.ui.assets.assets_dir)) |db| {
        meta_db = db;
        meta_db_ready = true;
    } else |_| {}

    const parent_path = std.fs.path.dirname(state.ui.assets.current_dir);
    if (parent_path) |parent| {
        if (!std.mem.eql(u8, state.ui.assets.current_dir, state.ui.assets.assets_dir)) {
            state.ui.assets.entries.append(allocator, .{
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
        if (entry.kind != .directory and std.mem.endsWith(u8, entry.name, ".meta")) continue;

        const full_path = std.fs.path.join(allocator, &[_][]const u8{ state.ui.assets.current_dir, entry.name }) catch continue;
        const relative = std.fs.path.relative(allocator, state.ui.assets.assets_dir, full_path) catch full_path;

        var asset_type: AssetState.AssetType = .OTHER;
        var is_dir = false;

        if (entry.kind == .directory) {
            asset_type = .FOLDER;
            is_dir = true;
        } else {
            asset_type = get_asset_type(entry.name);
        }

        if (!is_dir and meta_db_ready) {
            _ = meta_db.getOrCreateGuidForAsset(full_path) catch {};
        }

        const full_path_z = allocator.dupeZ(u8, full_path) catch continue;
        const relative_z = allocator.dupeZ(u8, relative) catch continue;

        const full_path_start = @intFromPtr(full_path.ptr);
        const full_path_end = full_path_start + full_path.len;
        const assets_dir_start = @intFromPtr(state.ui.assets.assets_dir.ptr);
        const assets_dir_end = assets_dir_start + state.ui.assets.assets_dir.len;
        const relative_start = @intFromPtr(relative.ptr);

        const is_slice_of_full = (relative_start >= full_path_start and relative_start < full_path_end);
        const is_slice_of_assets = (relative_start >= assets_dir_start and relative_start < assets_dir_end);

        if (!is_slice_of_full and !is_slice_of_assets) {
            allocator.free(relative);
        }

        if (full_path.ptr != state.ui.assets.current_dir.ptr) allocator.free(full_path);

        state.ui.assets.entries.append(allocator, .{
            .display = allocator.dupeZ(u8, entry.name) catch continue,
            .full_path = full_path_z,
            .relative_path = relative_z,
            .type = asset_type,
            .is_directory = is_dir,
        }) catch continue;
    }

    std.sort.block(AssetState.AssetEntry, state.ui.assets.entries.items, {}, struct {
        fn less(_: void, lhs: AssetState.AssetEntry, rhs: AssetState.AssetEntry) bool {
            if (std.mem.eql(u8, lhs.display, "..")) return true;
            if (std.mem.eql(u8, rhs.display, "..")) return false;
            if (lhs.is_directory != rhs.is_directory) return lhs.is_directory;
            return std.mem.lessThan(u8, lhs.display, rhs.display);
        }
    }.less);

    const filter_text = std.mem.span(@as([*:0]const u8, @ptrCast(state.ui.assets.search_filter.ptr)));

    for (state.ui.assets.entries.items) |entry| {
        if (filter_text.len > 0) {
            if (std.mem.indexOf(u8, entry.display, filter_text) == null) continue;
        }

        if (state.ui.assets.show_folders_only and !entry.is_directory) continue;
        if (state.ui.assets.show_gltf_only and entry.type != .GLTF and entry.type != .GLB and entry.type != .KFM and entry.type != .NIF) continue;
        if (state.ui.assets.show_textures_only and entry.type != .TEXTURE) continue;

        state.ui.assets.filtered_entries.append(allocator, entry) catch continue;
    }
}

/// Starts loading a scene file and tracks it in the editor loading list.
pub fn load_scene(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    state.runtime.is_loading = true;
    _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Loading scene: {s}...", .{path}) catch {};

    const path_copy = allocator.dupeZ(u8, path) catch return;

    const task = loader.cardinal_scene_load_async(path_copy, .HIGH, null, null);

    if (task) |t| {
        state.runtime.loading_tasks.append(allocator, .{
            .task = t,
            .path = path_copy,
        }) catch {
            _ = async_loader.cardinal_async_cancel_task(t);
            async_loader.cardinal_async_free_task(t);
            allocator.free(path_copy);
        };
    } else {
        allocator.free(path_copy);
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Failed to start loading: {s}", .{path}) catch {};
    }
}

const scene_io = @import("../systems/scene_io.zig");

pub fn draw_asset_browser_panel(state: *EditorState, allocator: std.mem.Allocator) void {
    if (state.ui.show_assets) {
        const open = c.imgui_bridge_begin("Assets", &state.ui.show_assets, 0);
        defer c.imgui_bridge_end();

        if (open) {
            c.imgui_bridge_text("Project Assets");
            c.imgui_bridge_separator();

            c.imgui_bridge_text("Assets Root:");
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_button("Config")) {
                c.imgui_bridge_open_popup("ConfigAssets");
            }

            if (c.imgui_bridge_begin_popup("ConfigAssets", 0)) {
                c.imgui_bridge_text("Configure Assets Path");

                var path_buf: [512]u8 = [_]u8{0} ** 512;
                const current_path = state.runtime.config_manager.config.assets_path;
                @memcpy(path_buf[0..current_path.len], current_path);
                path_buf[current_path.len] = 0;

                if (c.imgui_bridge_input_text_with_hint("Path", "Absolute path to assets", @ptrCast(&path_buf), 512)) {}

                if (c.imgui_bridge_button("Save & Reload")) {
                    const new_len = std.mem.indexOf(u8, &path_buf, &[_]u8{0}) orelse path_buf.len;
                    const new_path = path_buf[0..new_len];

                    state.runtime.config_manager.setAssetsPath(new_path) catch |err| {
                        log.cardinal_log_error("Failed to set assets path: {}", .{err});
                    };

                    state.runtime.config_manager.save() catch |err| {
                        log.cardinal_log_error("Failed to save config: {}", .{err});
                    };

                    allocator.free(state.ui.assets.assets_dir);
                    allocator.free(state.ui.assets.current_dir);

                    state.ui.assets.assets_dir = allocator.dupeZ(u8, new_path) catch {
                        log.cardinal_log_error("Failed to allocate assets dir", .{});
                        return;
                    };
                    state.ui.assets.current_dir = allocator.dupeZ(u8, new_path) catch {
                        allocator.free(state.ui.assets.assets_dir);
                        log.cardinal_log_error("Failed to allocate current dir", .{});
                        return;
                    };

                    scan_assets_dir(state, allocator);
                    c.imgui_bridge_close_current_popup();
                }

                c.imgui_bridge_end_popup();
            }

            c.imgui_bridge_set_next_item_width(-1.0);

            if (c.imgui_bridge_button("Refresh")) {
                scan_assets_dir(state, allocator);
            }

            c.imgui_bridge_text("Current: %s", state.ui.assets.current_dir.ptr);

            c.imgui_bridge_separator();

            c.imgui_bridge_text("Search & Filter:");
            c.imgui_bridge_set_next_item_width(-1.0);

            if (c.imgui_bridge_input_text_with_hint("##search_filter", "Search files...", @as([*c]u8, @ptrCast(state.ui.assets.search_filter.ptr)), state.ui.assets.search_filter.len)) {
                scan_assets_dir(state, allocator);
            }

            var filter_changed = false;
            if (c.imgui_bridge_checkbox("Folders Only", &state.ui.assets.show_folders_only)) filter_changed = true;
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_checkbox("Models", &state.ui.assets.show_gltf_only)) filter_changed = true;
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_checkbox("Textures", &state.ui.assets.show_textures_only)) filter_changed = true;

            if (filter_changed) {
                scan_assets_dir(state, allocator);
            }

            if (c.imgui_bridge_button("Clear Filters")) {
                @memset(state.ui.assets.search_filter, 0);
                state.ui.assets.show_folders_only = false;
                state.ui.assets.show_gltf_only = false;
                state.ui.assets.show_textures_only = false;
                scan_assets_dir(state, allocator);
            }

            c.imgui_bridge_separator();

            c.imgui_bridge_text("Import Model");
            c.imgui_bridge_set_next_item_width(-1.0);
            if (c.imgui_bridge_input_text_with_hint("##scene_path", "C:/path/to/model.gltf, .glb, .kfm", @ptrCast(&state.ui.scene_path), state.ui.scene_path.len)) {}
            if (c.imgui_bridge_button("Import")) {
                const path_len = std.mem.indexOf(u8, &state.ui.scene_path, &[_]u8{0}) orelse state.ui.scene_path.len;
                if (path_len > 0) {
                    load_scene(state, allocator, state.ui.scene_path[0..path_len]);
                }
            }

            if (state.runtime.is_loading) {
                c.imgui_bridge_same_line(0, -1);
                c.imgui_bridge_text("Loading...");
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_begin_child("##assets_list", 0, 0, true, 0)) {
                if (state.ui.assets.filtered_entries.items.len == 0) {
                    c.imgui_bridge_text_disabled("No assets found in '%s'", state.ui.assets.current_dir.ptr);
                } else {
                    for (state.ui.assets.filtered_entries.items) |entry| {
                        if (entry.type == .TEXTURE and !entry.is_directory) {
                            const id = ensure_texture_thumbnail(state, allocator, entry.full_path);
                            if (id != 0) {
                                c.imgui_bridge_image_u64(id, 18.0, 18.0);
                            } else {
                                c.imgui_bridge_text("%s", "[T]");
                            }
                        } else {
                            const icon = switch (entry.type) {
                                .FOLDER => "[D]",
                                .GLTF, .GLB, .KFM, .NIF => "[M]",
                                else => "[F]",
                            };
                            c.imgui_bridge_text("%s", icon);
                        }
                        c.imgui_bridge_same_line(0, -1);

                        if (c.imgui_bridge_selectable(@as([*:0]const u8, @ptrCast(entry.display.ptr)), false, 0)) {
                            if (entry.is_directory) {
                                const old_dir = state.ui.assets.current_dir;
                                if (std.mem.eql(u8, entry.display, "..")) {
                                    const parent = std.fs.path.dirname(old_dir) orelse old_dir;
                                    state.ui.assets.current_dir = allocator.dupeZ(u8, parent) catch old_dir;
                                } else {
                                    state.ui.assets.current_dir = allocator.dupeZ(u8, entry.full_path) catch old_dir;
                                }

                                if (state.ui.assets.current_dir.ptr != old_dir.ptr) allocator.free(old_dir[0 .. old_dir.len + 1]);
                                scan_assets_dir(state, allocator);
                                break;
                            } else if (entry.type == .GLTF or entry.type == .GLB or entry.type == .KFM or entry.type == .NIF) {
                                load_scene(state, allocator, entry.full_path);
                            } else if (entry.type == .TEXTURE) {
                                load_skybox(state, allocator, entry.full_path);
                            }
                        }

                        if (!entry.is_directory and c.imgui_bridge_begin_drag_drop_source(0)) {
                            _ = c.imgui_bridge_set_drag_drop_payload("ASSET_PATH", entry.full_path.ptr, entry.full_path.len + 1, c.ImGuiCond_Once);
                            c.imgui_bridge_text("%s", entry.display.ptr);
                            c.imgui_bridge_end_drag_drop_source();
                        }

                        if (!entry.is_directory and c.imgui_bridge_is_item_hovered(0) and c.imgui_bridge_is_mouse_double_clicked(0)) {
                            if (entry.type == .GLTF or entry.type == .GLB or entry.type == .KFM or entry.type == .NIF) {
                                load_scene(state, allocator, entry.full_path);
                            } else if (entry.type == .TEXTURE) {
                                load_skybox(state, allocator, entry.full_path);
                            }
                        }
                    }
                }
            }
            c.imgui_bridge_end_child();
        }
    }
}
