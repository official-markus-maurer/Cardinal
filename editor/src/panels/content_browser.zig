//! Content browser panel (asset scanning and file actions).
//!
//! Provides directory scanning, filtering, and simple actions like loading scenes and setting
//! a skybox texture.
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

fn imgui_backend_ptr() u64 {
    return c.imgui_bridge_vk_backend_user_data_ptr();
}

fn imgui_vk_generation() u64 {
    return c.imgui_bridge_vk_generation();
}

const ThumbCacheHeader = extern struct {
    magic: [4]u8,
    version: u32,
    width: u32,
    height: u32,
    src_mtime_ns: u64,
    src_size: u64,
};

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[:0]u8 {
    const tmp = std.fmt.allocPrint(allocator, fmt, args) catch return null;
    defer allocator.free(tmp);
    return allocator.dupeZ(u8, tmp) catch null;
}

fn stat_file_abs(path: []const u8) ?std.fs.File.Stat {
    var f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    return f.stat() catch null;
}

fn stat_dir_abs(path: []const u8) ?std.fs.File.Stat {
    var d = std.fs.openDirAbsolute(path, .{}) catch return null;
    defer d.close();
    return d.stat() catch null;
}

fn dir_mtime_ns(path: []const u8) u64 {
    const st = stat_dir_abs(path) orelse return 0;
    return @intCast(@max(0, st.mtime));
}

fn dir_hash(path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    return hasher.final();
}

fn rebuild_filtered_entries(state: *EditorState, allocator: std.mem.Allocator) void {
    state.ui.assets.filtered_entries.clearRetainingCapacity();

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

fn ensure_assets_cache_dirs(state: *EditorState) void {
    var dir = std.fs.openDirAbsolute(state.ui.assets.assets_dir, .{}) catch return;
    defer dir.close();
    dir.makePath(".cache/thumbnails") catch {};
}

fn thumbnail_cache_path(state: *EditorState, allocator: std.mem.Allocator, asset_path: []const u8) ?[:0]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(asset_path);
    const h = hasher.final();
    var hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{h}) catch return null;
    return allocPrintZ(allocator, "{s}\\.cache\\thumbnails\\{s}.cth", .{ state.ui.assets.assets_dir, hex[0..] });
}

fn try_load_cached_thumbnail(state: *EditorState, allocator: std.mem.Allocator, asset_path: []const u8) ?struct { width: u32, height: u32, pixels: []u8 } {
    ensure_assets_cache_dirs(state);
    const cache_path_z = thumbnail_cache_path(state, allocator, asset_path) orelse return null;
    defer allocator.free(cache_path_z);

    const stat = stat_file_abs(asset_path) orelse return null;

    var file = std.fs.openFileAbsolute(cache_path_z, .{}) catch return null;
    defer file.close();

    var header: ThumbCacheHeader = undefined;
    const read_bytes = file.readAll(std.mem.asBytes(&header)) catch return null;
    if (read_bytes != @sizeOf(ThumbCacheHeader)) return null;
    if (!std.mem.eql(u8, &header.magic, "CTH0")) return null;
    if (header.version != 1) return null;

    const mtime: u64 = @intCast(@max(0, stat.mtime));
    const size_u64: u64 = @intCast(stat.size);
    if (header.src_mtime_ns != mtime or header.src_size != size_u64) return null;
    if (header.width == 0 or header.height == 0) return null;

    const pixel_len: usize = @as(usize, header.width) * @as(usize, header.height) * 4;
    const pixels = allocator.alloc(u8, pixel_len) catch return null;
    errdefer allocator.free(pixels);
    const got = file.readAll(pixels) catch return null;
    if (got != pixel_len) return null;

    return .{ .width = header.width, .height = header.height, .pixels = pixels };
}

fn write_cached_thumbnail(state: *EditorState, allocator: std.mem.Allocator, asset_path: []const u8, width: u32, height: u32, pixels: []const u8) void {
    ensure_assets_cache_dirs(state);
    const cache_path_z = thumbnail_cache_path(state, allocator, asset_path) orelse return;
    defer allocator.free(cache_path_z);

    const stat = stat_file_abs(asset_path) orelse return;
    const mtime: u64 = @intCast(@max(0, stat.mtime));
    const size_u64: u64 = @intCast(stat.size);

    var file = std.fs.createFileAbsolute(cache_path_z, .{ .truncate = true }) catch return;
    defer file.close();

    const header = ThumbCacheHeader{
        .magic = .{ 'C', 'T', 'H', '0' },
        .version = 1,
        .width = width,
        .height = height,
        .src_mtime_ns = mtime,
        .src_size = size_u64,
    };
    _ = file.writeAll(std.mem.asBytes(&header)) catch return;
    _ = file.writeAll(pixels) catch return;
}

fn ensure_builtin_icon(state: *EditorState, allocator: std.mem.Allocator, key: []const u8) u64 {
    if (state.runtime.asset_thumbnails.getPtr(key)) |existing| {
        const gen = imgui_vk_generation();
        if (existing.imgui_id != 0 and existing.imgui_vulkan_generation == gen and gen != 0) {
            return existing.imgui_id;
        }
        existing.imgui_id = 0;
        existing.imgui_backend_user_data_ptr = 0;
        existing.imgui_vulkan_generation = 0;
        if (existing.handle != std.math.maxInt(u32) and gen != 0) {
            var sampler_raw: ?*anyopaque = null;
            var view_raw: ?*anyopaque = null;
            if (vulkan_renderer.cardinal_renderer_runtime_texture_get_vk_handles(state.runtime.renderer, existing.handle, @ptrCast(@alignCast(&sampler_raw)), @ptrCast(@alignCast(&view_raw)))) {
                const new_id = c.imgui_bridge_vk_add_texture(@ptrCast(sampler_raw), @ptrCast(view_raw), c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
                if (new_id != 0) {
                    existing.imgui_id = new_id;
                    existing.imgui_backend_user_data_ptr = imgui_backend_ptr();
                    existing.imgui_vulkan_generation = gen;
                    return new_id;
                }
            }
        }
        return 0;
    }

    const w: u32 = 32;
    const h: u32 = 32;

    const buf = allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4) catch return 0;
    defer allocator.free(buf);
    @memset(buf, 0);

    const kind = key;
    const draw_rect = struct {
        fn f(pixels: []u8, x0: u32, y0: u32, x1: u32, y1: u32, color: [4]u8) void {
            var y: u32 = y0;
            while (y < y1) : (y += 1) {
                var x: u32 = x0;
                while (x < x1) : (x += 1) {
                    const idx: usize = (@as(usize, y) * 32 + @as(usize, x)) * 4;
                    pixels[idx + 0] = color[0];
                    pixels[idx + 1] = color[1];
                    pixels[idx + 2] = color[2];
                    pixels[idx + 3] = color[3];
                }
            }
        }
    }.f;

    if (std.mem.eql(u8, kind, "__icon_folder__")) {
        draw_rect(buf, 4, 12, 28, 28, .{ 235, 190, 60, 255 });
        draw_rect(buf, 6, 8, 18, 14, .{ 255, 215, 110, 255 });
        draw_rect(buf, 6, 14, 26, 26, .{ 245, 205, 75, 255 });
    } else if (std.mem.eql(u8, kind, "__icon_model__")) {
        draw_rect(buf, 6, 6, 26, 26, .{ 120, 180, 255, 255 });
        draw_rect(buf, 10, 10, 22, 22, .{ 40, 90, 170, 255 });
    } else if (std.mem.eql(u8, kind, "__icon_image__")) {
        draw_rect(buf, 6, 6, 26, 26, .{ 80, 200, 120, 255 });
        draw_rect(buf, 8, 8, 24, 24, .{ 20, 60, 30, 255 });
        draw_rect(buf, 9, 18, 23, 23, .{ 80, 200, 120, 255 });
        draw_rect(buf, 9, 15, 15, 18, .{ 80, 200, 120, 255 });
    } else {
        draw_rect(buf, 7, 5, 25, 27, .{ 170, 170, 170, 255 });
        draw_rect(buf, 18, 5, 25, 12, .{ 200, 200, 200, 255 });
    }

    var handle: u32 = 0;
    if (!vulkan_renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, w, h, c.VK_FORMAT_R8G8B8A8_UNORM, &handle)) {
        return 0;
    }
    if (!vulkan_renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, handle, @ptrCast(buf.ptr), buf.len)) {
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

    const key_copy = allocator.dupe(u8, key) catch {
        c.imgui_bridge_vk_remove_texture(imgui_id);
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    };
    const gen = imgui_vk_generation();
    state.runtime.asset_thumbnails.put(allocator, key_copy, .{ .handle = handle, .imgui_id = imgui_id, .imgui_backend_user_data_ptr = imgui_backend_ptr(), .imgui_vulkan_generation = if (imgui_id != 0) gen else 0, .width = w, .height = h }) catch {
        allocator.free(key_copy);
        c.imgui_bridge_vk_remove_texture(imgui_id);
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    };

    return imgui_id;
}

fn cache_thumbnail_failure(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    if (state.runtime.asset_thumbnails.getPtr(path) != null) return;
    const key_copy = allocator.dupe(u8, path) catch return;
    state.runtime.asset_thumbnails.put(allocator, key_copy, .{}) catch {
        allocator.free(key_copy);
    };
}

fn ensure_existing_thumbnail_imgui_id(state: *EditorState, thumb: *editor_state_module.AssetThumbnail) u64 {
    const gen = imgui_vk_generation();
    if (thumb.handle != std.math.maxInt(u32)) {
        var sampler_raw: ?*anyopaque = null;
        var view_raw: ?*anyopaque = null;
        if (!vulkan_renderer.cardinal_renderer_runtime_texture_get_vk_handles(state.runtime.renderer, thumb.handle, @ptrCast(@alignCast(&sampler_raw)), @ptrCast(@alignCast(&view_raw))) or sampler_raw == null or view_raw == null) {
            thumb.imgui_id = 0;
            thumb.imgui_backend_user_data_ptr = 0;
            thumb.imgui_vulkan_generation = 0;
            thumb.handle = std.math.maxInt(u32);
            thumb.width = 0;
            thumb.height = 0;
            return 0;
        }
    }

    if (thumb.imgui_id != 0 and thumb.imgui_vulkan_generation == gen and gen != 0) return thumb.imgui_id;
    thumb.imgui_id = 0;
    thumb.imgui_backend_user_data_ptr = 0;
    thumb.imgui_vulkan_generation = 0;
    if (thumb.handle != std.math.maxInt(u32) and gen != 0) {
        var sampler_raw: ?*anyopaque = null;
        var view_raw: ?*anyopaque = null;
        if (vulkan_renderer.cardinal_renderer_runtime_texture_get_vk_handles(state.runtime.renderer, thumb.handle, @ptrCast(@alignCast(&sampler_raw)), @ptrCast(@alignCast(&view_raw)))) {
            const new_id = c.imgui_bridge_vk_add_texture(@ptrCast(sampler_raw), @ptrCast(view_raw), c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
            if (new_id != 0) {
                thumb.imgui_id = new_id;
                thumb.imgui_backend_user_data_ptr = imgui_backend_ptr();
                thumb.imgui_vulkan_generation = gen;
                return new_id;
            }
        }
    }
    return 0;
}

fn ensure_texture_thumbnail_cached_only(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) u64 {
    _ = allocator;
    if (state.runtime.asset_thumbnails.getPtr(path)) |thumb| {
        if (thumb.handle == std.math.maxInt(u32) and thumb.imgui_id == 0) return 0;
        return ensure_existing_thumbnail_imgui_id(state, thumb);
    }
    return 0;
}

fn ensure_texture_thumbnail(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) u64 {
    if (state.runtime.asset_thumbnails.getPtr(path)) |existing| {
        if (existing.handle == std.math.maxInt(u32) and existing.imgui_id == 0) return 0;
        const id = ensure_existing_thumbnail_imgui_id(state, existing);
        if (id != 0) return id;
    }

    if (try_load_cached_thumbnail(state, allocator, path)) |cached| {
        defer allocator.free(cached.pixels);
        var handle: u32 = 0;
        if (!vulkan_renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, cached.width, cached.height, c.VK_FORMAT_R8G8B8A8_UNORM, &handle)) {
            return 0;
        }
        if (!vulkan_renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, handle, @ptrCast(cached.pixels.ptr), cached.pixels.len)) {
            vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
            return 0;
        }

        var sampler_raw: ?*anyopaque = null;
        var view_raw: ?*anyopaque = null;
        if (!vulkan_renderer.cardinal_renderer_runtime_texture_get_vk_handles(state.runtime.renderer, handle, @ptrCast(@alignCast(&sampler_raw)), @ptrCast(@alignCast(&view_raw)))) {
            vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
            return 0;
        }

        const key_copy = allocator.dupe(u8, path) catch {
            vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
            return 0;
        };
        const imgui_id = c.imgui_bridge_vk_add_texture(@ptrCast(sampler_raw), @ptrCast(view_raw), c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        const backend = imgui_backend_ptr();
        const gen = imgui_vk_generation();
        state.runtime.asset_thumbnails.put(allocator, key_copy, .{ .handle = handle, .imgui_id = imgui_id, .imgui_backend_user_data_ptr = if (imgui_id != 0) backend else 0, .imgui_vulkan_generation = if (imgui_id != 0) gen else 0, .width = cached.width, .height = cached.height }) catch {
            allocator.free(key_copy);
            if (imgui_id != 0) c.imgui_bridge_vk_remove_texture(imgui_id);
            vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
            return 0;
        };

        return if (imgui_id != 0) imgui_id else 0;
    }

    var tex = std.mem.zeroes(texture_loader.TextureData);
    const path_z = allocator.dupeZ(u8, path) catch return 0;
    defer allocator.free(path_z);

    if (!texture_loader.texture_load_from_disk(@ptrCast(path_z.ptr), &tex)) {
        cache_thumbnail_failure(state, allocator, path);
        return 0;
    }
    defer texture_loader.texture_data_free(&tex);

    if (tex.data == null or tex.width == 0 or tex.height == 0) {
        cache_thumbnail_failure(state, allocator, path);
        return 0;
    }
    if (tex.is_hdr != 0) {
        cache_thumbnail_failure(state, allocator, path);
        return 0;
    }

    const fmt: c.VkFormat = @intCast(tex.format);
    const is_rgba8 = (fmt == c.VK_FORMAT_R8G8B8A8_UNORM or fmt == c.VK_FORMAT_R8G8B8A8_SRGB);

    if (is_rgba8 and (tex.channels == 3 or tex.channels == 4)) {
        const thumb_size: u32 = 128;
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

        write_cached_thumbnail(state, allocator, path, thumb_size, thumb_size, thumb_buf);

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
        const gen = imgui_vk_generation();
        state.runtime.asset_thumbnails.put(allocator, key_copy, .{
            .handle = handle,
            .imgui_id = imgui_id,
            .imgui_backend_user_data_ptr = imgui_backend_ptr(),
            .imgui_vulkan_generation = if (imgui_id != 0) gen else 0,
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

    if (tex.width > 1024 or tex.height > 1024) {
        cache_thumbnail_failure(state, allocator, path);
        return 0;
    }
    if (tex.data_size == 0 or tex.data == null) {
        cache_thumbnail_failure(state, allocator, path);
        return 0;
    }

    var sampler_raw: ?*anyopaque = null;
    var view_raw: ?*anyopaque = null;
    var handle: u32 = 0;
    if (!vulkan_renderer.cardinal_renderer_runtime_texture_allocate(state.runtime.renderer, tex.width, tex.height, fmt, &handle)) {
        return 0;
    }
    const data_size: usize = @intCast(tex.data_size);
    if (!vulkan_renderer.cardinal_renderer_runtime_texture_upload_full(state.runtime.renderer, handle, @ptrCast(tex.data.?), data_size)) {
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    }
    if (!vulkan_renderer.cardinal_renderer_runtime_texture_get_vk_handles(state.runtime.renderer, handle, @ptrCast(@alignCast(&sampler_raw)), @ptrCast(@alignCast(&view_raw)))) {
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    }
    const key_copy = allocator.dupe(u8, path) catch {
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    };
    const imgui_id = c.imgui_bridge_vk_add_texture(@ptrCast(sampler_raw), @ptrCast(view_raw), c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    const backend = imgui_backend_ptr();
    const gen = imgui_vk_generation();
    state.runtime.asset_thumbnails.put(allocator, key_copy, .{ .handle = handle, .imgui_id = imgui_id, .imgui_backend_user_data_ptr = if (imgui_id != 0) backend else 0, .imgui_vulkan_generation = if (imgui_id != 0) gen else 0, .width = tex.width, .height = tex.height }) catch {
        allocator.free(key_copy);
        if (imgui_id != 0) c.imgui_bridge_vk_remove_texture(imgui_id);
        vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, handle);
        return 0;
    };
    return if (imgui_id != 0) imgui_id else 0;
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
        std.mem.eql(u8, ext, ".dds") or
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
        const before = entry.component.*;
        const after = engine.ecs_components.Skybox.init(path);
        state.ui.undo.push(.{ .EntitySkybox = .{
            .entity_id = entry.entity.id,
            .before_present = true,
            .after_present = true,
            .before = before,
            .after = after,
        } });
        state.runtime.registry.add(entry.entity, after) catch {};
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Skybox set to: {s}", .{path}) catch {};
    } else {
        const opts = engine.ecs_node_factory.CreateNodeOptions{ .skybox_path = path };
        const created = engine.ecs_node_factory.create_node(state.runtime.registry, null, .Skybox, "Skybox", opts) catch return;
        state.ui.undo.push_entity_subtree(state.runtime.registry, created, .Create, &[_]u64{}, &[_]engine.ecs_components.Hierarchy{}, &[_]engine.ecs_components.Hierarchy{});
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

    state.ui.assets.last_scan_dir_hash = dir_hash(state.ui.assets.current_dir);
    state.ui.assets.last_scan_dir_mtime_ns = dir_mtime_ns(state.ui.assets.current_dir);

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
        if (entry.kind == .directory and std.mem.eql(u8, entry.name, ".cache")) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
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
            const lhs_dotdot = std.mem.eql(u8, lhs.display, "..");
            const rhs_dotdot = std.mem.eql(u8, rhs.display, "..");
            if (lhs_dotdot) return !rhs_dotdot;
            if (rhs_dotdot) return false;
            if (lhs.is_directory != rhs.is_directory) return lhs.is_directory;
            if (std.mem.eql(u8, lhs.display, rhs.display)) return false;
            return std.mem.lessThan(u8, lhs.display, rhs.display);
        }
    }.less);

    rebuild_filtered_entries(state, allocator);
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
            const current_hash = dir_hash(state.ui.assets.current_dir);
            const current_mtime = dir_mtime_ns(state.ui.assets.current_dir);
            const is_root_dir = std.mem.eql(u8, state.ui.assets.current_dir, state.ui.assets.assets_dir);
            if (current_hash != state.ui.assets.last_scan_dir_hash or (!is_root_dir and current_mtime != 0 and current_mtime != state.ui.assets.last_scan_dir_mtime_ns)) {
                scan_assets_dir(state, allocator);
            }

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
                rebuild_filtered_entries(state, allocator);
            }

            var filter_changed = false;
            if (c.imgui_bridge_checkbox("Folders Only", &state.ui.assets.show_folders_only)) filter_changed = true;
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_checkbox("Models", &state.ui.assets.show_gltf_only)) filter_changed = true;
            c.imgui_bridge_same_line(0, -1);
            if (c.imgui_bridge_checkbox("Textures", &state.ui.assets.show_textures_only)) filter_changed = true;

            if (filter_changed) {
                rebuild_filtered_entries(state, allocator);
            }

            if (c.imgui_bridge_button("Clear Filters")) {
                @memset(state.ui.assets.search_filter, 0);
                state.ui.assets.show_folders_only = false;
                state.ui.assets.show_gltf_only = false;
                state.ui.assets.show_textures_only = false;
                rebuild_filtered_entries(state, allocator);
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
                        const icon_size: f32 = 22.0;
                        var icon_id: u64 = 0;
                        if (entry.is_directory) {
                            icon_id = ensure_builtin_icon(state, allocator, "__icon_folder__");
                        } else if (entry.type == .TEXTURE) {
                            const ext = std.fs.path.extension(entry.display);
                            if (std.mem.eql(u8, ext, ".dds")) {
                                icon_id = ensure_texture_thumbnail_cached_only(state, allocator, entry.full_path);
                            } else {
                                icon_id = ensure_texture_thumbnail(state, allocator, entry.full_path);
                            }
                            if (icon_id == 0) icon_id = ensure_builtin_icon(state, allocator, "__icon_image__");
                        } else if (entry.type == .GLTF or entry.type == .GLB or entry.type == .KFM or entry.type == .NIF) {
                            icon_id = ensure_builtin_icon(state, allocator, "__icon_model__");
                        } else {
                            icon_id = ensure_builtin_icon(state, allocator, "__icon_file__");
                        }

                        if (icon_id != 0) {
                            c.imgui_bridge_image_u64(icon_id, icon_size, icon_size);
                        } else {
                            c.imgui_bridge_text("%s", " ");
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

                        if (!entry.is_directory and entry.type == .TEXTURE and c.imgui_bridge_is_item_hovered(c.ImGuiHoveredFlags_ForTooltip)) {
                            const preview_id = ensure_texture_thumbnail(state, allocator, entry.full_path);
                            if (preview_id != 0) {
                                if (state.runtime.asset_thumbnails.get(entry.full_path)) |thumb| {
                                    const max_size: f32 = 256.0;
                                    var w: f32 = @floatFromInt(thumb.width);
                                    var h: f32 = @floatFromInt(thumb.height);
                                    if (w <= 0.0 or h <= 0.0) {
                                        w = max_size;
                                        h = max_size;
                                    } else {
                                        const scale = max_size / @max(w, h);
                                        w *= scale;
                                        h *= scale;
                                    }
                                    c.imgui_bridge_begin_tooltip();
                                    c.imgui_bridge_image_u64(preview_id, w, h);
                                    c.imgui_bridge_end_tooltip();
                                }
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
