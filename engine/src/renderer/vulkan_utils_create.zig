//! Vulkan object creation helpers.
//!
//! Thin wrappers around Vulkan creation functions with consistent validation and logging.
const std = @import("std");
const log = @import("../core/log.zig");
const core = @import("vulkan_utils_core.zig");

const vk_utils_log = log.ScopedLogger("VK_UTILS");

const c = @import("vulkan_c.zig").c;

fn check_result(result: c.VkResult, operation_name: ?[*:0]const u8) bool {
    if (result != c.VK_SUCCESS) {
        const op = if (operation_name) |name| std.mem.span(name) else "Unknown operation";
        const res_str = std.mem.span(core.vk_utils_result_string(result));
        vk_utils_log.err("Vulkan operation failed: {s} (Result: {s})", .{ op, res_str });
        return false;
    }
    return true;
}

pub export fn vk_utils_create_semaphore(device: c.VkDevice, semaphore: ?*c.VkSemaphore, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!core.vk_utils_validate_pointer(device, "device") or !core.vk_utils_validate_pointer(@ptrCast(semaphore), "semaphore")) {
        return false;
    }

    var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    semaphore_info.pNext = null;
    semaphore_info.flags = 0;

    const result = c.vkCreateSemaphore(device, &semaphore_info, null, semaphore);
    return check_result(result, if (operation_name) |op| op else "create semaphore");
}

/// Creates a fence on `device`, optionally signaled.
pub export fn vk_utils_create_fence(device: c.VkDevice, fence: ?*c.VkFence, signaled: bool, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!core.vk_utils_validate_pointer(device, "device") or !core.vk_utils_validate_pointer(@ptrCast(fence), "fence")) {
        return false;
    }

    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fence_info.pNext = null;
    fence_info.flags = if (signaled) c.VK_FENCE_CREATE_SIGNALED_BIT else 0;

    const result = c.vkCreateFence(device, &fence_info, null, fence);
    return check_result(result, if (operation_name) |op| op else "create fence");
}

/// Creates a command pool for the given queue family.
pub export fn vk_utils_create_command_pool(device: c.VkDevice, queue_family_index: u32, flags: c.VkCommandPoolCreateFlags, command_pool: ?*c.VkCommandPool, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!core.vk_utils_validate_pointer(device, "device") or !core.vk_utils_validate_pointer(@ptrCast(command_pool), "command_pool")) {
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

/// Creates a descriptor pool using a provided `VkDescriptorPoolCreateInfo`.
pub export fn vk_utils_create_descriptor_pool(device: c.VkDevice, pool_info: ?*const c.VkDescriptorPoolCreateInfo, descriptor_pool: ?*c.VkDescriptorPool, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!core.vk_utils_validate_pointer(device, "device") or !core.vk_utils_validate_pointer(pool_info, "pool_info") or !core.vk_utils_validate_pointer(@ptrCast(descriptor_pool), "descriptor_pool")) {
        return false;
    }

    const result = c.vkCreateDescriptorPool(device, pool_info, null, descriptor_pool);
    return check_result(result, if (operation_name) |op| op else "create descriptor pool");
}

/// Creates a pipeline layout using a provided `VkPipelineLayoutCreateInfo`.
pub export fn vk_utils_create_pipeline_layout(device: c.VkDevice, layout_info: ?*const c.VkPipelineLayoutCreateInfo, pipeline_layout: ?*c.VkPipelineLayout, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!core.vk_utils_validate_pointer(device, "device") or !core.vk_utils_validate_pointer(layout_info, "layout_info") or !core.vk_utils_validate_pointer(@ptrCast(pipeline_layout), "pipeline_layout")) {
        return false;
    }

    const result = c.vkCreatePipelineLayout(device, layout_info, null, pipeline_layout);
    return check_result(result, if (operation_name) |op| op else "create pipeline layout");
}

/// Creates a sampler using a provided `VkSamplerCreateInfo`.
pub export fn vk_utils_create_sampler(device: c.VkDevice, sampler_info: ?*const c.VkSamplerCreateInfo, sampler: ?*c.VkSampler, operation_name: ?[*:0]const u8) callconv(.c) bool {
    if (!core.vk_utils_validate_pointer(device, "device") or !core.vk_utils_validate_pointer(sampler_info, "sampler_info") or !core.vk_utils_validate_pointer(@ptrCast(sampler), "sampler")) {
        return false;
    }

    const result = c.vkCreateSampler(device, sampler_info, null, sampler);
    return check_result(result, if (operation_name) |op| op else "create sampler");
}
