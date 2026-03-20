//! Vulkan shader module helpers.
//!
//! Loads SPIR-V shader bytecode via the asset file I/O layer, creates `VkShaderModule` objects,
//! and provides a helper to read SPIR-V code as `[]u32`.
const std = @import("std");
const log = @import("../../core/log.zig");
pub const reflection = @import("vulkan_shader_reflection.zig");
const file_io = @import("../../assets/file_io.zig");
const memory = @import("../../core/memory.zig");

const shader_utils_log = log.ScopedLogger("SHADER_UTILS");

const c = @import("../vulkan_c.zig").c;

/// Callback invoked when a watched shader file changes.
pub const ShaderHotReloadCallback = ?*const fn ([*:0]const u8, ?*anyopaque) callconv(.c) void;

const Watcher = struct {
    callback: ShaderHotReloadCallback,
    user_data: ?*anyopaque,
};

var g_watch_mutex: std.Thread.Mutex = .{};

const WatchGroup = struct {
    path: [:0]u8,
    last_mtime_ns: u64,
    watchers: std.ArrayListUnmanaged(Watcher) = .{},
};

var g_watch_map: std.StringHashMapUnmanaged(WatchGroup) = .{};

/// Loads a SPIR-V blob from `filename` and creates a shader module.
pub export fn vk_shader_create_module(device: c.VkDevice, filename: ?[*:0]const u8, shader_module: ?*c.VkShaderModule) callconv(.c) bool {
    if (filename == null or shader_module == null) {
        shader_utils_log.err("Invalid parameters for shader module creation", .{});
        return false;
    }

    const fname = std.mem.span(filename.?);

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    const code = file_io.read_file_alloc(allocator, fname) catch |err| {
        shader_utils_log.err("Failed to read shader file: {s} ({s})", .{ fname, @errorName(err) });
        return false;
    };
    defer allocator.free(code);

    if (code.len == 0) {
        shader_utils_log.err("Invalid shader file size: 0", .{});
        return false;
    }
    if (code.len % 4 != 0) {
        shader_utils_log.err("Invalid SPIR-V size: {d} (not 4-byte aligned)", .{code.len});
        return false;
    }

    return vk_shader_create_module_from_code(device, @ptrCast(@alignCast(code.ptr)), code.len, shader_module);
}

/// Creates a shader module from an in-memory SPIR-V blob.
pub export fn vk_shader_create_module_from_code(device: c.VkDevice, code: ?[*]const u32, code_size: usize, shader_module: ?*c.VkShaderModule) callconv(.c) bool {
    if (device == null or code == null or code_size == 0 or shader_module == null) {
        shader_utils_log.err("Invalid parameters for shader module creation from code", .{});
        return false;
    }

    var create_info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    create_info.codeSize = code_size;
    create_info.pCode = code;

    const result = c.vkCreateShaderModule(device, &create_info, null, shader_module);
    if (result != c.VK_SUCCESS) {
        shader_utils_log.err("Failed to create shader module: {d}", .{result});
        return false;
    }

    return true;
}

/// Reads a SPIR-V file into an owned `[]u32` slice.
pub fn vk_shader_read_file(allocator: std.mem.Allocator, filename: []const u8) ![]u32 {
    return try file_io.read_file_u32(allocator, filename);
}

/// Destroys a shader module if non-null.
pub export fn vk_shader_destroy_module(device: c.VkDevice, shader_module: c.VkShaderModule) callconv(.c) void {
    if (device != null and shader_module != null) {
        c.vkDestroyShaderModule(device, shader_module, null);
    }
}

/// Registers a callback that fires when `path` changes.
pub export fn vk_shader_watch_file(path: ?[*:0]const u8, callback: ShaderHotReloadCallback, user_data: ?*anyopaque) callconv(.c) bool {
    if (path == null or callback == null) return false;
    const p = std.mem.span(path.?);
    if (p.len == 0) return false;

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();

    g_watch_mutex.lock();
    defer g_watch_mutex.unlock();

    if (g_watch_map.getPtr(p)) |group| {
        group.watchers.append(allocator, .{ .callback = callback, .user_data = user_data }) catch return false;
        return true;
    }

    const owned = allocator.dupeZ(u8, p) catch return false;
    const mtime = file_io.get_mtime_ns(p) catch 0;

    var group = WatchGroup{
        .path = owned,
        .last_mtime_ns = mtime,
        .watchers = .{},
    };
    errdefer allocator.free(owned[0 .. owned.len + 1]);
    group.watchers.append(allocator, .{ .callback = callback, .user_data = user_data }) catch return false;
    g_watch_map.put(allocator, owned, group) catch return false;

    return true;
}

/// Unregisters a previously registered watch entry.
pub export fn vk_shader_unwatch_file(path: ?[*:0]const u8, callback: ShaderHotReloadCallback, user_data: ?*anyopaque) callconv(.c) void {
    if (path == null or callback == null) return;
    const p = std.mem.span(path.?);

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();

    g_watch_mutex.lock();
    defer g_watch_mutex.unlock();

    const group = g_watch_map.getPtr(p) orelse return;
    var i: usize = 0;
    while (i < group.watchers.items.len) {
        const w = group.watchers.items[i];
        if (w.callback == callback and w.user_data == user_data) {
            _ = group.watchers.swapRemove(i);
            continue;
        }
        i += 1;
    }

    if (group.watchers.items.len == 0) {
        var removed = g_watch_map.fetchRemove(p) orelse return;
        removed.value.watchers.deinit(allocator);
        allocator.free(removed.value.path[0 .. removed.value.path.len + 1]);
    }
}

/// Polls watched shader paths and invokes callbacks for changes.
pub export fn vk_shader_poll_hot_reload() callconv(.c) void {
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();

    const Fire = struct {
        path: [*:0]const u8,
        callback: ShaderHotReloadCallback,
        user_data: ?*anyopaque,
    };

    var to_fire: std.ArrayListUnmanaged(Fire) = .{};
    defer to_fire.deinit(allocator);

    g_watch_mutex.lock();

    var it = g_watch_map.iterator();
    while (it.next()) |entry| {
        const group = entry.value_ptr;
        const mtime = file_io.get_mtime_ns(group.path) catch continue;
        if (mtime > group.last_mtime_ns) {
            group.last_mtime_ns = mtime;
            for (group.watchers.items) |w| {
                to_fire.append(allocator, .{ .path = group.path.ptr, .callback = w.callback, .user_data = w.user_data }) catch {};
            }
        }
    }

    g_watch_mutex.unlock();

    for (to_fire.items) |f| {
        if (f.callback) |cb| cb(f.path, f.user_data);
    }
}

/// Frees all registered watch entries.
pub export fn vk_shader_hot_reload_shutdown() callconv(.c) void {
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();

    g_watch_mutex.lock();
    defer g_watch_mutex.unlock();

    var it = g_watch_map.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.watchers.deinit(allocator);
        allocator.free(entry.value_ptr.path[0 .. entry.value_ptr.path.len + 1]);
    }
    g_watch_map.deinit(allocator);
    g_watch_map = .{};
}
