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
        mat_log.err("material_load_async: material_data is NULL", .{});
        return null;
    }

    mat_log.debug("Starting async load for material", .{});

    const task = async_loader.cardinal_async_load_material(@ptrCast(material_data), priority, callback, user_data);
    if (task == null) {
        mat_log.err("Failed to create async material loading task", .{});
        return null;
    }

    mat_log.debug("Async task created for material loading", .{});
    return task;
}
