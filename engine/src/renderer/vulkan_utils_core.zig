//! Core Vulkan utility helpers.
//!
//! Contains logging, result formatting, and basic pointer validation utilities.
const std = @import("std");
const log = @import("../core/log.zig");

const vk_utils_log = log.ScopedLogger("VK_UTILS");

const c = @import("vulkan_c.zig").c;

/// Returns true for `VK_SUCCESS`, otherwise logs a formatted error including source location.
pub export fn vk_utils_check_result(result: c.VkResult, operation: ?[*:0]const u8, file: ?[*:0]const u8, line: c_int) callconv(.c) bool {
    if (result == c.VK_SUCCESS) {
        return true;
    }

    const result_string = vk_utils_result_string(result);
    vk_utils_log.err("Vulkan operation failed: {s}\n  Result: {s} ({d})\n  Location: {s}:{d}", .{
        if (operation) |op| std.mem.span(op) else "Unknown operation",
        std.mem.span(result_string),
        result,
        if (file) |f| std.mem.span(f) else "Unknown file",
        line,
    });
    return false;
}

/// Converts a subset of `VkResult` values into stable string names.
pub export fn vk_utils_result_string(result: c.VkResult) callconv(.c) [*:0]const u8 {
    return switch (result) {
        c.VK_SUCCESS => "VK_SUCCESS",
        c.VK_NOT_READY => "VK_NOT_READY",
        c.VK_TIMEOUT => "VK_TIMEOUT",
        c.VK_EVENT_SET => "VK_EVENT_SET",
        c.VK_EVENT_RESET => "VK_EVENT_RESET",
        c.VK_INCOMPLETE => "VK_INCOMPLETE",
        c.VK_ERROR_OUT_OF_HOST_MEMORY => "VK_ERROR_OUT_OF_HOST_MEMORY",
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => "VK_ERROR_OUT_OF_DEVICE_MEMORY",
        c.VK_ERROR_INITIALIZATION_FAILED => "VK_ERROR_INITIALIZATION_FAILED",
        c.VK_ERROR_DEVICE_LOST => "VK_ERROR_DEVICE_LOST",
        c.VK_ERROR_MEMORY_MAP_FAILED => "VK_ERROR_MEMORY_MAP_FAILED",
        c.VK_ERROR_LAYER_NOT_PRESENT => "VK_ERROR_LAYER_NOT_PRESENT",
        c.VK_ERROR_EXTENSION_NOT_PRESENT => "VK_ERROR_EXTENSION_NOT_PRESENT",
        c.VK_ERROR_FEATURE_NOT_PRESENT => "VK_ERROR_FEATURE_NOT_PRESENT",
        c.VK_ERROR_INCOMPATIBLE_DRIVER => "VK_ERROR_INCOMPATIBLE_DRIVER",
        c.VK_ERROR_TOO_MANY_OBJECTS => "VK_ERROR_TOO_MANY_OBJECTS",
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => "VK_ERROR_FORMAT_NOT_SUPPORTED",
        c.VK_ERROR_FRAGMENTED_POOL => "VK_ERROR_FRAGMENTED_POOL",
        c.VK_ERROR_UNKNOWN => "VK_ERROR_UNKNOWN",
        c.VK_ERROR_OUT_OF_POOL_MEMORY => "VK_ERROR_OUT_OF_POOL_MEMORY",
        c.VK_ERROR_INVALID_EXTERNAL_HANDLE => "VK_ERROR_INVALID_EXTERNAL_HANDLE",
        c.VK_ERROR_FRAGMENTATION => "VK_ERROR_FRAGMENTATION",
        c.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => "VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS",
        c.VK_ERROR_SURFACE_LOST_KHR => "VK_ERROR_SURFACE_LOST_KHR",
        c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR",
        c.VK_SUBOPTIMAL_KHR => "VK_SUBOPTIMAL_KHR",
        c.VK_ERROR_OUT_OF_DATE_KHR => "VK_ERROR_OUT_OF_DATE_KHR",
        c.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR => "VK_ERROR_INCOMPATIBLE_DISPLAY_KHR",
        c.VK_ERROR_VALIDATION_FAILED_EXT => "VK_ERROR_VALIDATION_FAILED_EXT",
        c.VK_ERROR_INVALID_SHADER_NV => "VK_ERROR_INVALID_SHADER_NV",
        else => "Unknown VkResult",
    };
}

/// Allocates zeroed memory using libc `malloc`.
pub export fn vk_utils_allocate(size: usize, operation_name: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (size == 0) {
        vk_utils_log.warn("Attempted to allocate 0 bytes for operation: {s}", .{if (operation_name) |op| std.mem.span(op) else "unknown"});
        return null;
    }

    const ptr = c.malloc(size);
    if (ptr == null) {
        vk_utils_log.err("Failed to allocate {d} bytes for operation: {s}", .{ size, if (operation_name) |op| std.mem.span(op) else "unknown" });
        return null;
    }

    @memset(@as([*]u8, @ptrCast(ptr))[0..size], 0);
    return ptr;
}

/// Reallocates a libc allocation (freeing `ptr` when `size` is 0).
pub export fn vk_utils_reallocate(ptr: ?*anyopaque, size: usize, operation_name: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (size == 0) {
        vk_utils_log.warn("Attempted to reallocate to 0 bytes for operation: {s}", .{if (operation_name) |op| std.mem.span(op) else "unknown"});
        if (ptr != null) c.free(ptr);
        return null;
    }

    const new_ptr = c.realloc(ptr, size);
    if (new_ptr == null) {
        vk_utils_log.err("Failed to reallocate to {d} bytes for operation: {s}", .{ size, if (operation_name) |op| std.mem.span(op) else "unknown" });
        return null;
    }

    return new_ptr;
}

/// Returns false and logs an error if `ptr` is null.
pub export fn vk_utils_validate_pointer(ptr: ?*const anyopaque, name: ?[*:0]const u8) callconv(.c) bool {
    if (ptr == null) {
        vk_utils_log.err("Null pointer validation failed: {s}", .{if (name) |n| std.mem.span(n) else "unknown"});
        return false;
    }
    return true;
}

/// Returns false and logs an error if `handle` is null.
pub export fn vk_utils_validate_handle(handle: ?*const anyopaque, name: ?[*:0]const u8) callconv(.c) bool {
    if (handle == null) {
        vk_utils_log.err("Null handle validation failed: {s}", .{if (name) |n| std.mem.span(n) else "unknown"});
        return false;
    }
    return true;
}
