const std = @import("std");
const scene = @import("scene.zig");
const async_loader = @import("../core/async_loader.zig");
const log = @import("../core/log.zig");
const scene_serializer = @import("scene_serializer.zig");
const memory = @import("../core/memory.zig");
const nif_loader = @import("nif_loader.zig");
const kfm_loader = @import("kfm_loader.zig");
const asset_utils = @import("asset_utils.zig");

const loader_log = log.ScopedLogger("LOADER");

// --- Externs from gltf_loader.c ---
extern fn cardinal_gltf_load_scene(path: [*:0]const u8, scene: *scene.CardinalScene) callconv(.c) bool;

// --- Helper Functions ---



// --- Public API ---

pub export fn cardinal_scene_load(path: ?[*:0]const u8, out_scene: ?*scene.CardinalScene) callconv(.c) bool {
    if (path == null or out_scene == null) {
        loader_log.err("Invalid parameters: path=null or out_scene=null", .{});
        return false;
    }

    loader_log.info("Scene loading requested: {s}", .{path.?});

    const ext = asset_utils.find_extension(path);
    if (ext == null) {
        loader_log.err("No file extension found in path: {s}", .{path.?});
        return false;
    }

    loader_log.debug("Detected file extension: {s}", .{ext.?});

    var ext_buf: [16]u8 = undefined;
    const ext_len = std.mem.len(ext.?);
    if (ext_len >= 16) {
        loader_log.err("Extension too long", .{});
        return false;
    }

    @memcpy(ext_buf[0..ext_len], std.mem.span(ext.?));
    ext_buf[ext_len] = 0;
    const ext_slice = ext_buf[0..ext_len :0];

    // In-place lower case
    for (ext_slice) |*c| {
        c.* = std.ascii.toLower(c.*);
    }

    loader_log.debug("Normalized extension: {s}", .{ext_slice});

    if (std.mem.eql(u8, ext_slice, "gltf") or std.mem.eql(u8, ext_slice, "glb")) {
        loader_log.debug("Routing to GLTF loader", .{});
        return cardinal_gltf_load_scene(path.?, out_scene.?);
    }

    if (std.mem.eql(u8, ext_slice, "nif")) {
        loader_log.debug("Routing to NIF loader", .{});
        return nif_loader.cardinal_nif_load_scene(path.?, out_scene.?);
    }

    if (std.mem.eql(u8, ext_slice, "kfm")) {
        loader_log.debug("Routing to KFM loader", .{});
        return kfm_loader.cardinal_kfm_load_scene(path.?, out_scene.?);
    }

    if (std.mem.eql(u8, ext_slice, "kf")) {
        loader_log.debug("Routing to KF loader (merge)", .{});
        return nif_loader.cardinal_nif_merge_kf(path.?, out_scene.?);
    }

    loader_log.err("Unsupported file format: {s} (extension: {s})", .{ path.?, ext_slice });
    return false;
}

pub export fn cardinal_scene_load_async(path: ?[*:0]const u8, priority: async_loader.CardinalAsyncPriority, callback: async_loader.CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*async_loader.CardinalAsyncTask {
    if (path == null) {
        loader_log.err("Invalid path parameter", .{});
        return null;
    }

    if (!async_loader.cardinal_async_loader_is_initialized()) {
        loader_log.err("Async loader not initialized", .{});
        return null;
    }

    loader_log.info("Async scene loading requested: {s}", .{path.?});

    const ext = asset_utils.find_extension(path);
    if (ext == null) {
        loader_log.err("No file extension found in path: {s}", .{path.?});
        return null;
    }

    var ext_buf: [16]u8 = undefined;
    const ext_len = std.mem.len(ext.?);
    if (ext_len >= 16) {
        loader_log.err("Extension too long", .{});
        return null;
    }

    @memcpy(ext_buf[0..ext_len], std.mem.span(ext.?));
    ext_buf[ext_len] = 0;
    const ext_slice = ext_buf[0..ext_len :0];

    for (ext_slice) |*c| {
        c.* = std.ascii.toLower(c.*);
    }

    if (!std.mem.eql(u8, ext_slice, "gltf") and !std.mem.eql(u8, ext_slice, "glb") and
        !std.mem.eql(u8, ext_slice, "kfm") and !std.mem.eql(u8, ext_slice, "nif") and
        !std.mem.eql(u8, ext_slice, "kf"))
    {
        loader_log.err("Unsupported file format for async loading: {s} (extension: {s})", .{ path.?, ext_slice });
        return null;
    }

    return async_loader.cardinal_async_load_scene(@ptrCast(path.?), priority, callback, user_data);
}

fn ecs_scene_loader_impl(file_path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (file_path == null) return null;

    const allocator_handle = memory.cardinal_get_allocator_for_category(.ASSETS);
    const allocator = allocator_handle.as_allocator();

    const path_slice = std.mem.span(file_path.?);
    const file = std.fs.cwd().openFile(path_slice, .{}) catch {
        loader_log.err("Failed to open file: {s}", .{path_slice});
        return null;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |err| {
        loader_log.err("Failed to read file: {}", .{err});
        return null;
    };
    // Do NOT free content here; ownership passed to ParsedScene

    const parsed = scene_serializer.SceneSerializer.loadSceneData(allocator, content, path_slice) catch |err| {
        loader_log.err("Failed to parse scene: {}", .{err});
        allocator.free(content); // Free content if parsing fails
        return null;
    };

    const ptr = allocator.create(scene_serializer.SceneSerializer.ParsedScene) catch return null;
    ptr.* = parsed;

    return ptr;
}

pub export fn cardinal_ecs_scene_load_async(path: ?[*:0]const u8, priority: async_loader.CardinalAsyncPriority, callback: async_loader.CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*async_loader.CardinalAsyncTask {
    if (async_loader.Loaders.ecs_scene_load_fn == null) {
        async_loader.cardinal_async_register_ecs_scene_loader(ecs_scene_loader_impl);
    }
    return async_loader.cardinal_async_load_ecs_scene(path, priority, callback, user_data);
}
