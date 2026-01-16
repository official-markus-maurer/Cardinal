const std = @import("std");
const scene = @import("scene.zig");
const async_loader = @import("../core/async_loader.zig");
const log = @import("../core/log.zig");
const scene_serializer = @import("scene_serializer.zig");
const memory = @import("../core/memory.zig");

const loader_log = log.ScopedLogger("LOADER");

// --- Externs from gltf_loader.c ---
extern fn cardinal_gltf_load_scene(path: [*:0]const u8, scene: *scene.CardinalScene) callconv(.c) bool;

// --- Helper Functions ---

fn find_ext(path: ?[*:0]const u8) ?[*:0]const u8 {
    if (path == null) return null;
    const p = std.mem.span(path.?);

    // Find last dot
    var last_dot: ?usize = null;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] == '.') {
            last_dot = i;
        }
    }

    if (last_dot) |idx| {
        // Return slice from after dot
        // We need to return a sentinel-terminated pointer.
        // The original string is sentinel-terminated, so a slice from middle to end is also valid if we cast.
        // But Zig slices carry length. We want [*:0]const u8.
        // We can just return pointer to char after dot.
        return @as([*:0]const u8, @ptrCast(path.?)) + idx + 1;
    }

    return null;
}

fn tolower_str(s: ?[*:0]u8) void {
    if (s == null) return;
    var ptr = s.?;
    while (ptr[0] != 0) : (ptr += 1) {
        ptr[0] = std.ascii.toLower(ptr[0]);
    }
}

// --- Public API ---

pub export fn cardinal_scene_load(path: ?[*:0]const u8, out_scene: ?*scene.CardinalScene) callconv(.c) bool {
    if (path == null or out_scene == null) {
        loader_log.err("Invalid parameters: path=null or out_scene=null", .{});
        return false;
    }

    loader_log.info("Scene loading requested: {s}", .{path.?});

    const ext = find_ext(path);
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

    const ext = find_ext(path);
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

    if (!std.mem.eql(u8, ext_slice, "gltf") and !std.mem.eql(u8, ext_slice, "glb")) {
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
