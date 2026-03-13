//! Vulkan shader module helpers.
//!
//! Loads SPIR-V shader bytecode from disk, creates `VkShaderModule` objects, and provides a small
//! reflection-facing helper to read SPIR-V code as `[]u32`.
//!
//! TODO: Move file I/O to an asset loader and support hot-reload notifications.
const std = @import("std");
const log = @import("../../core/log.zig");
pub const reflection = @import("vulkan_shader_reflection.zig");

const shader_utils_log = log.ScopedLogger("SHADER_UTILS");

const c = @import("../vulkan_c.zig").c;

/// Loads a SPIR-V blob from `filename` and creates a shader module.
pub export fn vk_shader_create_module(device: c.VkDevice, filename: ?[*:0]const u8, shader_module: ?*c.VkShaderModule) callconv(.c) bool {
    if (filename == null or shader_module == null) {
        shader_utils_log.err("Invalid parameters for shader module creation", .{});
        return false;
    }

    const fname = std.mem.span(filename.?);

    const file = std.fs.cwd().openFile(fname, .{}) catch |err| {
        shader_utils_log.err("Failed to open shader file: {s} ({s})", .{ fname, @errorName(err) });
        return false;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        shader_utils_log.err("Failed to stat shader file: {s} ({s})", .{ fname, @errorName(err) });
        return false;
    };

    if (stat.size == 0) {
        shader_utils_log.err("Invalid shader file size: 0", .{});
        return false;
    }

    const memory = @import("../../core/memory.zig");
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();

    const code = allocator.alloc(u8, stat.size) catch {
        shader_utils_log.err("Failed to allocate memory for shader code", .{});
        return false;
    };
    defer allocator.free(code);

    const bytes_read = file.readAll(code) catch |err| {
        shader_utils_log.err("Failed to read shader file: {s} ({s})", .{ fname, @errorName(err) });
        return false;
    };

    if (bytes_read != stat.size) {
        shader_utils_log.err("Failed to read complete shader file", .{});
        return false;
    }

    return vk_shader_create_module_from_code(device, @ptrCast(@alignCast(code.ptr)), @intCast(stat.size), shader_module);
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
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) return error.EmptyFile;

    if (stat.size % 4 != 0) return error.InvalidSpirvSize;

    const buffer = try allocator.alloc(u32, stat.size / 4);
    errdefer allocator.free(buffer);

    const bytes = std.mem.sliceAsBytes(buffer);
    const read = try file.readAll(bytes);
    if (read != stat.size) return error.IncompleteRead;

    return buffer;
}

/// Destroys a shader module if non-null.
pub export fn vk_shader_destroy_module(device: c.VkDevice, shader_module: c.VkShaderModule) callconv(.c) void {
    if (device != null and shader_module != null) {
        c.vkDestroyShaderModule(device, shader_module, null);
    }
}
