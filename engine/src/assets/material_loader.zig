const std = @import("std");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const async_loader = @import("../core/async_loader.zig");
const scene = @import("scene.zig");

const mat_log = log.ScopedLogger("MATERIAL");

// --- Public API ---

pub export fn material_data_free(material: ?*scene.CardinalMaterial) callconv(.c) void {
    if (material) |mat| {
        @memset(@as([*]u8, @ptrCast(mat))[0..@sizeOf(scene.CardinalMaterial)], 0);
    }
}

pub export fn material_load_async(material_data: ?*const scene.CardinalMaterial, priority: async_loader.CardinalAsyncPriority, callback: async_loader.CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*async_loader.CardinalAsyncTask {
    if (material_data == null) {
        log.cardinal_log_error("material_load_async: material_data is NULL", .{});
        return null;
    }

    log.cardinal_log_debug("[MATERIAL] Starting async load for material", .{});

    const task = async_loader.cardinal_async_load_material(@ptrCast(material_data), priority, callback, user_data);
    if (task == null) {
        log.cardinal_log_error("Failed to create async material loading task", .{});
        return null;
    }

    log.cardinal_log_debug("[MATERIAL] Async task created for material loading", .{});
    return task;
}
