const std = @import("std");
const log = @import("../core/log.zig");

const c = @import("vulkan_c.zig").c;

// =============================================================================
// Error Handling Implementation
// =============================================================================

pub export fn vk_utils_check_result(result: c.VkResult, operation: ?[*:0]const u8, file: ?[*:0]const u8, line: c_int) callconv(.c) bool {
    if (result == c.VK_SUCCESS) {
        return true;
    }

    const result_string = vk_utils_result_string(result);
    log.cardinal_log_error("Vulkan operation failed: {s}\n  Result: {s} ({d})\n  Location: {s}:{d}", .{
        if (operation) |op| std.mem.span(op) else "Unknown operation",
        std.mem.span(result_string),
        result,
        if (file) |f| std.mem.span(f) else "Unknown file",
        line,
    });
    return false;
}

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

// =============================================================================
// Resource Creation Helpers
// =============================================================================

fn check_result(result: c.VkResult, operation_name: ?[*:0]const u8) bool {
    if (result != c.VK_SUCCESS) {
        const op = if (operation_name) |name| std.mem.span(name) else "Unknown operation";
        const res_str = std.mem.span(vk_utils_result_string(result));
        log.cardinal_log_error("Vulkan operation failed: {s} (Result: {s})", .{ op, res_str });
        return false;
    }
    return true;
}

pub export fn vk_utils_create_semaphore(device: c.VkDevice, semaphore: ?*c.VkSemaphore, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!vk_utils_validate_pointer(device, "device") or !vk_utils_validate_pointer(@ptrCast(semaphore), "semaphore")) {
        return false;
    }

    var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    semaphore_info.pNext = null;
    semaphore_info.flags = 0;

    const result = c.vkCreateSemaphore(device, &semaphore_info, null, semaphore);
    return check_result(result, if (operation_name) |op| op else "create semaphore");
}

pub export fn vk_utils_create_fence(device: c.VkDevice, fence: ?*c.VkFence, signaled: bool, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!vk_utils_validate_pointer(device, "device") or !vk_utils_validate_pointer(@ptrCast(fence), "fence")) {
        return false;
    }

    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fence_info.pNext = null;
    fence_info.flags = if (signaled) c.VK_FENCE_CREATE_SIGNALED_BIT else 0;

    const result = c.vkCreateFence(device, &fence_info, null, fence);
    return check_result(result, if (operation_name) |op| op else "create fence");
}

pub export fn vk_utils_create_command_pool(device: c.VkDevice, queue_family_index: u32, flags: c.VkCommandPoolCreateFlags, command_pool: ?*c.VkCommandPool, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!vk_utils_validate_pointer(device, "device") or !vk_utils_validate_pointer(@ptrCast(command_pool), "command_pool")) {
        return false;
    }

    var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.pNext = null;
    pool_info.flags = flags;
    pool_info.queueFamilyIndex = queue_family_index;

    const result = c.vkCreateCommandPool(device, &pool_info, null, command_pool);
    return check_result(result, if (operation_name) |op| op else "create command pool");
}

pub export fn vk_utils_create_descriptor_pool(device: c.VkDevice, pool_info: ?*const c.VkDescriptorPoolCreateInfo, descriptor_pool: ?*c.VkDescriptorPool, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!vk_utils_validate_pointer(device, "device") or !vk_utils_validate_pointer(pool_info, "pool_info") or !vk_utils_validate_pointer(@ptrCast(descriptor_pool), "descriptor_pool")) {
        return false;
    }

    const result = c.vkCreateDescriptorPool(device, pool_info, null, descriptor_pool);
    return check_result(result, if (operation_name) |op| op else "create descriptor pool");
}

pub export fn vk_utils_create_pipeline_layout(device: c.VkDevice, layout_info: ?*const c.VkPipelineLayoutCreateInfo, pipeline_layout: ?*c.VkPipelineLayout, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!vk_utils_validate_pointer(device, "device") or !vk_utils_validate_pointer(layout_info, "layout_info") or !vk_utils_validate_pointer(@ptrCast(pipeline_layout), "pipeline_layout")) {
        return false;
    }

    const result = c.vkCreatePipelineLayout(device, layout_info, null, pipeline_layout);
    return check_result(result, if (operation_name) |op| op else "create pipeline layout");
}

pub export fn vk_utils_create_sampler(device: c.VkDevice, sampler_info: ?*const c.VkSamplerCreateInfo, sampler: ?*c.VkSampler, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!vk_utils_validate_pointer(device, "device") or !vk_utils_validate_pointer(sampler_info, "sampler_info") or !vk_utils_validate_pointer(@ptrCast(sampler), "sampler")) {
        return false;
    }

    const result = c.vkCreateSampler(device, sampler_info, null, sampler);
    return check_result(result, if (operation_name) |op| op else "create sampler");
}

// =============================================================================
// Memory and Allocation Helpers
// =============================================================================

pub export fn vk_utils_allocate(size: usize, operation_name: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (size == 0) {
        log.cardinal_log_warn("Attempted to allocate 0 bytes for operation: {s}", .{if (operation_name) |op| std.mem.span(op) else "unknown"});
        return null;
    }

    const ptr = c.malloc(size);
    if (ptr == null) {
        log.cardinal_log_error("Failed to allocate {d} bytes for operation: {s}", .{ size, if (operation_name) |op| std.mem.span(op) else "unknown" });
        return null;
    }

    // Initialize to zero for safety
    @memset(@as([*]u8, @ptrCast(ptr))[0..size], 0);
    return ptr;
}

pub export fn vk_utils_reallocate(ptr: ?*anyopaque, size: usize, operation_name: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    if (size == 0) {
        log.cardinal_log_warn("Attempted to reallocate to 0 bytes for operation: {s}", .{if (operation_name) |op| std.mem.span(op) else "unknown"});
        if (ptr != null) c.free(ptr);
        return null;
    }

    const new_ptr = c.realloc(ptr, size);
    if (new_ptr == null) {
        log.cardinal_log_error("Failed to reallocate to {d} bytes for operation: {s}", .{ size, if (operation_name) |op| std.mem.span(op) else "unknown" });
        return null;
    }

    return new_ptr;
}

// =============================================================================
// Validation and Debugging
// =============================================================================

pub export fn vk_utils_validate_pointer(ptr: ?*const anyopaque, name: ?[*:0]const u8) callconv(.c) bool {
    if (ptr == null) {
        log.cardinal_log_error("Null pointer validation failed: {s}", .{if (name) |n| std.mem.span(n) else "unknown"});
        return false;
    }
    return true;
}

pub export fn vk_utils_validate_handle(handle: ?*const anyopaque, name: ?[*:0]const u8) callconv(.c) bool {
    if (handle == null) {
        log.cardinal_log_error("Null handle validation failed: {s}", .{if (name) |n| std.mem.span(n) else "unknown"});
        return false;
    }
    return true;
}
