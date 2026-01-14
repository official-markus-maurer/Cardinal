const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;

const vma_log = log.ScopedLogger("VMA");

// Global storage for VMA functions to ensure they remain valid
// (VMA copies them, but just to be safe and avoid stack issues)
var g_vulkan_functions: c.VmaVulkanFunctions = undefined;

pub export fn init(alloc: ?*types.VulkanAllocator, instance: c.VkInstance, phys: c.VkPhysicalDevice, dev: c.VkDevice, bufReq: c.PFN_vkGetDeviceBufferMemoryRequirements, imgReq: c.PFN_vkGetDeviceImageMemoryRequirements, bufDevAddr: c.PFN_vkGetBufferDeviceAddress, bufReqKHR: c.PFN_vkGetDeviceBufferMemoryRequirementsKHR, imgReqKHR: c.PFN_vkGetDeviceImageMemoryRequirementsKHR, supports_maintenance8: bool) callconv(.c) bool {
    if (alloc == null or phys == null or dev == null or instance == null) {
        vma_log.err("Invalid parameters for allocator init", .{});
        return false;
    }

    _ = bufReqKHR;
    _ = imgReqKHR;

    const allocator = alloc.?;
    allocator.physical_device = phys;
    allocator.device = dev;

    // Use global storage to ensure persistence if VMA keeps the pointer (though it usually copies)
    // and to avoid stack overflow for large structs
    g_vulkan_functions = std.mem.zeroes(c.VmaVulkanFunctions);

    // Instance functions
    g_vulkan_functions.vkGetPhysicalDeviceProperties = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceProperties"));
    if (g_vulkan_functions.vkGetPhysicalDeviceProperties == null) vma_log.err("Failed to load vkGetPhysicalDeviceProperties", .{});

    g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceMemoryProperties"));
    if (g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties == null) vma_log.err("Failed to load vkGetPhysicalDeviceMemoryProperties", .{});

    g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceMemoryProperties2"));
    if (g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR == null) {
        g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceMemoryProperties2KHR"));
    }
    if (g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR == null) vma_log.err("Failed to load vkGetPhysicalDeviceMemoryProperties2", .{});

    // Device functions
    g_vulkan_functions.vkAllocateMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkAllocateMemory"));

    g_vulkan_functions.vkFreeMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkFreeMemory"));

    g_vulkan_functions.vkMapMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkMapMemory"));
    g_vulkan_functions.vkUnmapMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkUnmapMemory"));
    g_vulkan_functions.vkFlushMappedMemoryRanges = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkFlushMappedMemoryRanges"));
    g_vulkan_functions.vkInvalidateMappedMemoryRanges = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkInvalidateMappedMemoryRanges"));

    g_vulkan_functions.vkBindBufferMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindBufferMemory"));

    // IMPORTANT: VMA requires vkBindBufferMemory2KHR if VK_KHR_bind_memory2 is enabled,
    // or if the Vulkan version is >= 1.1.
    // If it's NULL, VMA might crash when trying to call it via internal logic if it detects 1.1+.
    g_vulkan_functions.vkBindBufferMemory2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindBufferMemory2"));
    if (g_vulkan_functions.vkBindBufferMemory2KHR == null) g_vulkan_functions.vkBindBufferMemory2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindBufferMemory2KHR"));

    g_vulkan_functions.vkBindImageMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindImageMemory"));
    g_vulkan_functions.vkBindImageMemory2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindImageMemory2"));
    if (g_vulkan_functions.vkBindImageMemory2KHR == null) g_vulkan_functions.vkBindImageMemory2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindImageMemory2KHR"));

    g_vulkan_functions.vkGetBufferMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetBufferMemoryRequirements"));
    g_vulkan_functions.vkGetImageMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetImageMemoryRequirements"));
    g_vulkan_functions.vkCreateBuffer = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkCreateBuffer"));
    g_vulkan_functions.vkDestroyBuffer = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkDestroyBuffer"));
    g_vulkan_functions.vkCreateImage = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkCreateImage"));
    g_vulkan_functions.vkDestroyImage = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkDestroyImage"));
    g_vulkan_functions.vkCmdCopyBuffer = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkCmdCopyBuffer"));

    g_vulkan_functions.vkGetBufferMemoryRequirements2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetBufferMemoryRequirements2"));
    if (g_vulkan_functions.vkGetBufferMemoryRequirements2KHR == null) g_vulkan_functions.vkGetBufferMemoryRequirements2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetBufferMemoryRequirements2KHR"));
    if (g_vulkan_functions.vkGetBufferMemoryRequirements2KHR == null) vma_log.err("Failed to load vkGetBufferMemoryRequirements2", .{});

    g_vulkan_functions.vkGetImageMemoryRequirements2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetImageMemoryRequirements2"));
    if (g_vulkan_functions.vkGetImageMemoryRequirements2KHR == null) g_vulkan_functions.vkGetImageMemoryRequirements2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetImageMemoryRequirements2KHR"));
    if (g_vulkan_functions.vkGetImageMemoryRequirements2KHR == null) vma_log.err("Failed to load vkGetImageMemoryRequirements2", .{});

    // We already loaded bind functions above

    g_vulkan_functions.vkGetDeviceBufferMemoryRequirements = bufReq;
    g_vulkan_functions.vkGetDeviceImageMemoryRequirements = imgReq;

    // Additional functions if available
    if (bufDevAddr != null) {
        if (@hasField(c.VmaVulkanFunctions, "vkGetBufferDeviceAddress")) {
            @field(g_vulkan_functions, "vkGetBufferDeviceAddress") = bufDevAddr;
        } else if (@hasField(c.VmaVulkanFunctions, "vkGetBufferDeviceAddressKHR")) {
            @field(g_vulkan_functions, "vkGetBufferDeviceAddressKHR") = bufDevAddr;
        } else {
            vma_log.debug("VmaVulkanFunctions missing vkGetBufferDeviceAddress field - VMA will load it internally if needed", .{});
        }
    }

    var allocatorInfo = std.mem.zeroes(c.VmaAllocatorCreateInfo);
    allocatorInfo.physicalDevice = phys;
    allocatorInfo.device = dev;
    allocatorInfo.instance = instance;
    allocatorInfo.pVulkanFunctions = &g_vulkan_functions;
    allocatorInfo.vulkanApiVersion = c.VK_API_VERSION_1_3;

    if (supports_maintenance8) {
        allocatorInfo.flags |= c.VMA_ALLOCATOR_CREATE_KHR_MAINTENANCE4_BIT;
    }

    if (bufDevAddr != null) {
        allocatorInfo.flags |= c.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT;
    }

    var vma_alloc: c.VmaAllocator = null;
    const result = c.vmaCreateAllocator(&allocatorInfo, &vma_alloc);

    if (result != c.VK_SUCCESS) {
        vma_log.err("Failed to create VMA allocator: {d}", .{result});
        return false;
    }

    allocator.handle = vma_alloc;
    vma_log.info("VMA Allocator initialized", .{});
    return true;
}

pub export fn shutdown(alloc: ?*types.VulkanAllocator) callconv(.c) void {
    if (alloc == null) return;
    const allocator = alloc.?;
    if (allocator.handle != null) {
        c.vmaDestroyAllocator(allocator.handle);
        allocator.handle = null;
    }
}

fn get_vma_usage(props: c.VkMemoryPropertyFlags) c.VmaMemoryUsage {
    if ((props & c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0) {
        return c.VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE;
    }
    if ((props & (c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) != 0) {
        return c.VMA_MEMORY_USAGE_AUTO_PREFER_HOST;
    }
    return c.VMA_MEMORY_USAGE_AUTO;
}

fn get_vma_flags(props: c.VkMemoryPropertyFlags) c.VmaAllocationCreateFlags {
    var flags: c.VmaAllocationCreateFlags = 0;
    if ((props & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
        if ((props & c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0) {
            // VMA ensures coherence for mapped memory usually, or we flush manually
            // VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT might be better for coherent
            flags |= c.VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT;
        } else {
            flags |= c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT;
        }
    }
    return flags;
}

pub export fn allocate_image(alloc: ?*types.VulkanAllocator, image_ci: ?*const c.VkImageCreateInfo, out_image: ?*c.VkImage, out_memory: ?*c.VkDeviceMemory, out_allocation: ?*c.VmaAllocation, required_props: c.VkMemoryPropertyFlags) callconv(.c) bool {
    if (alloc == null or image_ci == null or out_image == null or out_allocation == null) return false;

    var allocInfo = std.mem.zeroes(c.VmaAllocationCreateInfo);
    allocInfo.usage = get_vma_usage(required_props);
    allocInfo.flags = get_vma_flags(required_props);

    var infoOut: c.VmaAllocationInfo = undefined;

    const result = c.vmaCreateImage(alloc.?.handle, image_ci, &allocInfo, out_image, out_allocation, &infoOut);
    if (result != c.VK_SUCCESS) {
        vma_log.err("vmaCreateImage failed: {d}", .{result});
        return false;
    }

    if (out_memory != null) {
        out_memory.?.* = infoOut.deviceMemory;
    }

    return true;
}

pub export fn allocate_buffer(alloc: ?*types.VulkanAllocator, buffer_ci: ?*const c.VkBufferCreateInfo, out_buffer: ?*c.VkBuffer, out_memory: ?*c.VkDeviceMemory, out_allocation: ?*c.VmaAllocation, required_props: c.VkMemoryPropertyFlags, map_immediately: bool, out_mapped_ptr: ?*?*anyopaque) callconv(.c) bool {
    if (alloc == null or buffer_ci == null or out_buffer == null or out_allocation == null) return false;

    var allocInfo = std.mem.zeroes(c.VmaAllocationCreateInfo);
    allocInfo.usage = get_vma_usage(required_props);
    allocInfo.flags = get_vma_flags(required_props);

    var allocInfoOut: c.VmaAllocationInfo = undefined;

    const result = c.vmaCreateBuffer(alloc.?.handle, buffer_ci, &allocInfo, out_buffer, out_allocation, &allocInfoOut);
    if (result != c.VK_SUCCESS) {
        vma_log.err("vmaCreateBuffer failed: {d}", .{result});
        return false;
    }

    // Verify buffer handle
    if (out_buffer.?.* == null) {
        vma_log.err("vmaCreateBuffer returned success but buffer handle is null", .{});
        return false;
    }

    if (out_memory != null) {
        out_memory.?.* = allocInfoOut.deviceMemory;
    }

    if (map_immediately) {
        if (out_mapped_ptr) |ptr| {
            const res = c.vmaMapMemory(alloc.?.handle, out_allocation.?.*, ptr);
            if (res != c.VK_SUCCESS) {
                vma_log.err("vmaMapMemory failed: {d}", .{res});
                free_buffer(alloc, out_buffer.?.*, out_allocation.?.*);
                return false;
            }
        } else {
            var dummy_ptr: ?*anyopaque = null;
            const res = c.vmaMapMemory(alloc.?.handle, out_allocation.?.*, &dummy_ptr);
            if (res != c.VK_SUCCESS) {
                vma_log.err("vmaMapMemory failed: {d}", .{res});
                free_buffer(alloc, out_buffer.?.*, out_allocation.?.*);
                return false;
            }
        }
    } else if (out_mapped_ptr != null) {
        out_mapped_ptr.?.* = null;
    }

    return true;
}

pub export fn free_image(alloc: ?*types.VulkanAllocator, image: c.VkImage, allocation: c.VmaAllocation) callconv(.c) void {
    if (alloc == null or image == null or allocation == null) return;
    c.vmaDestroyImage(alloc.?.handle, image, allocation);
}

pub export fn free_buffer(alloc: ?*types.VulkanAllocator, buffer: c.VkBuffer, allocation: c.VmaAllocation) callconv(.c) void {
    if (alloc == null or buffer == null or allocation == null) return;
    c.vmaDestroyBuffer(alloc.?.handle, buffer, allocation);
}

// Helpers for mapped memory
pub export fn map_memory(alloc: ?*types.VulkanAllocator, allocation: c.VmaAllocation, ppData: ?*?*anyopaque) callconv(.c) c.VkResult {
    if (alloc == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    return c.vmaMapMemory(alloc.?.handle, allocation, ppData);
}

pub export fn unmap_memory(alloc: ?*types.VulkanAllocator, allocation: c.VmaAllocation) callconv(.c) void {
    if (alloc == null) return;
    c.vmaUnmapMemory(alloc.?.handle, allocation);
}
