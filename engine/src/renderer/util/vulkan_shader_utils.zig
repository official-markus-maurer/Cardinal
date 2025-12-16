const std = @import("std");
const log = @import("../../core/log.zig");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("vulkan/vulkan.h");
    @cInclude("stdlib.h");
});

export fn vk_shader_create_module(device: c.VkDevice, filename: ?[*:0]const u8, shader_module: ?*c.VkShaderModule) callconv(.c) bool {
    if (filename == null or shader_module == null) {
        log.cardinal_log_error("Invalid parameters for shader module creation", .{});
        return false;
    }
    
    const fname = std.mem.span(filename.?);
    
    const file = std.fs.cwd().openFile(fname, .{}) catch |err| {
        log.cardinal_log_error("Failed to open shader file: {s} ({s})", .{fname, @errorName(err)});
        return false;
    };
    defer file.close();
    
    const stat = file.stat() catch |err| {
        log.cardinal_log_error("Failed to stat shader file: {s} ({s})", .{fname, @errorName(err)});
        return false;
    };
    
    if (stat.size == 0) {
        log.cardinal_log_error("Invalid shader file size: 0", .{});
        return false;
    }
    
    // We use the C allocator to match the original C implementation's behavior if needed, 
    // but here we just need a temporary buffer. Zig allocator is fine.
    // However, we need to ensure alignment for uint32.
    const allocator = std.heap.c_allocator;
    
    const code = allocator.alloc(u8, stat.size) catch {
        log.cardinal_log_error("Failed to allocate memory for shader code", .{});
        return false;
    };
    defer allocator.free(code);
    
    const bytes_read = file.readAll(code) catch |err| {
        log.cardinal_log_error("Failed to read shader file: {s} ({s})", .{fname, @errorName(err)});
        return false;
    };
    
    if (bytes_read != stat.size) {
        log.cardinal_log_error("Failed to read complete shader file", .{});
        return false;
    }
    
    // Ensure 4-byte alignment for SPIR-V
    // allocator.alloc(u8) usually returns aligned memory, but strict alignment is better checked or enforced.
    // Actually, c_allocator uses malloc which returns suitably aligned memory for any standard type.
    
    return vk_shader_create_module_from_code(device, @ptrCast(@alignCast(code.ptr)), @intCast(stat.size), shader_module);
}

export fn vk_shader_create_module_from_code(device: c.VkDevice, code: ?[*]const u32, code_size: usize, shader_module: ?*c.VkShaderModule) callconv(.c) bool {
    if (device == null or code == null or code_size == 0 or shader_module == null) {
        log.cardinal_log_error("Invalid parameters for shader module creation from code", .{});
        return false;
    }
    
    var create_info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    create_info.codeSize = code_size;
    create_info.pCode = code;
    
    const result = c.vkCreateShaderModule(device, &create_info, null, shader_module);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create shader module: {d}", .{result});
        return false;
    }
    
    return true;
}

export fn vk_shader_destroy_module(device: c.VkDevice, shader_module: c.VkShaderModule) callconv(.c) void {
    if (device != null and shader_module != null) {
        c.vkDestroyShaderModule(device, shader_module, null);
    }
}
