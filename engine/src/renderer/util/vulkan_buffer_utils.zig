const std = @import("std");
const log = @import("../../core/log.zig");
const buffer_mgr = @import("../vulkan_buffer_manager.zig");
const types = @import("../vulkan_types.zig");

const c = @import("../vulkan_c.zig").c;

pub export fn vk_buffer_find_memory_type(physicalDevice: c.VkPhysicalDevice, typeFilter: u32, properties: c.VkMemoryPropertyFlags) callconv(.c) u32 {
    var memProperties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProperties);

    log.cardinal_log_debug("Searching for memory type: typeFilter=0x{X}, properties=0x{X}, available types={d}", .{typeFilter, properties, memProperties.memoryTypeCount});

    var i: u32 = 0;
    while (i < memProperties.memoryTypeCount) : (i += 1) {
        const typeMatches = (typeFilter & (@as(u32, 1) << @intCast(i))) != 0;
        const propertiesMatch = (memProperties.memoryTypes[i].propertyFlags & properties) == properties;

        log.cardinal_log_debug("  Type {d}: heap={d}, flags=0x{X}, typeMatch={s}, propMatch={s}", .{
            i,
            memProperties.memoryTypes[i].heapIndex,
            memProperties.memoryTypes[i].propertyFlags,
            if (typeMatches) "yes" else "no",
            if (propertiesMatch) "yes" else "no"
        });

        if (typeMatches and propertiesMatch) {
            const heapSizeMB = memProperties.memoryHeaps[memProperties.memoryTypes[i].heapIndex].size / (1024 * 1024);
            log.cardinal_log_debug("Found suitable memory type: index={d}, heap={d}, size={d} MB", .{
                i,
                memProperties.memoryTypes[i].heapIndex,
                heapSizeMB
            });
            return i;
        }
    }

    log.cardinal_log_error("Failed to find suitable memory type! typeFilter=0x{X}, properties=0x{X}", .{typeFilter, properties});
    return c.UINT32_MAX;
}

pub fn vk_buffer_create_with_staging(allocator: ?*types.VulkanAllocator, device: c.VkDevice,
                                            commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue,
                                            data: ?*const anyopaque, size: c.VkDeviceSize,
                                            usage: c.VkBufferUsageFlags, buffer: ?*c.VkBuffer,
                                            bufferMemory: ?*c.VkDeviceMemory, bufferAllocation: ?*c.VmaAllocation, vulkan_state: ?*types.VulkanState) bool {
    if (data == null or size == 0 or allocator == null or buffer == null or bufferAllocation == null) {
        log.cardinal_log_error("Invalid parameters for staging buffer creation", .{});
        return false;
    }

    var destBufferObj = std.mem.zeroes(buffer_mgr.VulkanBuffer);

    // Use the core manager function
    if (!buffer_mgr.vk_buffer_create_device_local(&destBufferObj, device, @ptrCast(allocator), commandPool,
                                       graphicsQueue, data, size, usage, @ptrCast(vulkan_state))) {
        log.cardinal_log_error("Failed to create device local buffer with staging", .{});
        return false;
    }

    // Return raw handles for compatibility
    buffer.?.* = destBufferObj.handle;
    if (bufferMemory != null) {
        bufferMemory.?.* = destBufferObj.memory;
    }
    bufferAllocation.?.* = destBufferObj.allocation;

    log.cardinal_log_debug("Successfully created buffer with staging: size={d} bytes, usage=0x{X}", .{size, usage});
    return true;
}
