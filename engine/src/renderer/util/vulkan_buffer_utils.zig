const std = @import("std");
const log = @import("../../core/log.zig");
const buffer_mgr = @import("../vulkan_buffer_manager.zig");
const types = @import("../vulkan_types.zig");
const vk_allocator = @import("../vulkan_allocator.zig");

const buf_utils_log = log.ScopedLogger("BUF_UTILS");

const c = @import("../vulkan_c.zig").c;

pub export fn vk_buffer_find_memory_type(physicalDevice: c.VkPhysicalDevice, typeFilter: u32, properties: c.VkMemoryPropertyFlags) callconv(.c) u32 {
    var memProperties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProperties);

    buf_utils_log.debug("Searching for memory type: typeFilter=0x{X}, properties=0x{X}, available types={d}", .{ typeFilter, properties, memProperties.memoryTypeCount });

    var i: u32 = 0;
    while (i < memProperties.memoryTypeCount) : (i += 1) {
        const typeMatches = (typeFilter & (@as(u32, 1) << @intCast(i))) != 0;
        const propertiesMatch = (memProperties.memoryTypes[i].propertyFlags & properties) == properties;

        buf_utils_log.debug("  Type {d}: heap={d}, flags=0x{X}, typeMatch={s}, propMatch={s}", .{ i, memProperties.memoryTypes[i].heapIndex, memProperties.memoryTypes[i].propertyFlags, if (typeMatches) "yes" else "no", if (propertiesMatch) "yes" else "no" });

        if (typeMatches and propertiesMatch) {
            const heapSizeMB = memProperties.memoryHeaps[memProperties.memoryTypes[i].heapIndex].size / (1024 * 1024);
            buf_utils_log.debug("Found suitable memory type: index={d}, heap={d}, size={d} MB", .{ i, memProperties.memoryTypes[i].heapIndex, heapSizeMB });
            return i;
        }
    }

    buf_utils_log.err("Failed to find suitable memory type! typeFilter=0x{X}, properties=0x{X}", .{ typeFilter, properties });
    return c.UINT32_MAX;
}

pub fn vk_buffer_create_with_staging(allocator: ?*types.VulkanAllocator, device: c.VkDevice, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, data: ?*const anyopaque, size: c.VkDeviceSize, usage: c.VkBufferUsageFlags, buffer: ?*c.VkBuffer, bufferMemory: ?*c.VkDeviceMemory, bufferAllocation: ?*c.VmaAllocation, vulkan_state: ?*types.VulkanState) bool {
    if (data == null or size == 0 or allocator == null or buffer == null or bufferAllocation == null) {
        buf_utils_log.err("Invalid parameters for staging buffer creation", .{});
        return false;
    }

    var destBufferObj = std.mem.zeroes(buffer_mgr.VulkanBuffer);

    // Use the core manager function
    if (!buffer_mgr.vk_buffer_create_device_local(&destBufferObj, device, @ptrCast(allocator), commandPool, graphicsQueue, data, size, usage, @ptrCast(vulkan_state))) {
        buf_utils_log.err("Failed to create device local buffer with staging", .{});
        return false;
    }

    // Return raw handles for compatibility
    buffer.?.* = destBufferObj.handle;
    if (bufferMemory != null) {
        bufferMemory.?.* = destBufferObj.memory;
    }
    bufferAllocation.?.* = destBufferObj.allocation;

    buf_utils_log.debug("Successfully created buffer with staging: size={d} bytes, usage=0x{X}", .{ size, usage });
    return true;
}

pub fn create_buffer(
    allocator: ?*types.VulkanAllocator,
    size: c.VkDeviceSize,
    usage: c.VkBufferUsageFlags,
    properties: c.VkMemoryPropertyFlags,
    buffer: *c.VkBuffer,
    bufferMemory: *c.VkDeviceMemory,
    bufferAllocation: *c.VmaAllocation,
) bool {
    var bufferInfo = std.mem.zeroes(c.VkBufferCreateInfo);
    bufferInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = size;
    bufferInfo.usage = usage;
    bufferInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    return vk_allocator.allocate_buffer(allocator, &bufferInfo, buffer, bufferMemory, bufferAllocation, properties, false, null);
}
