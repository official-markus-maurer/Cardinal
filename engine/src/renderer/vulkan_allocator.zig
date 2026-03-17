//! Vulkan Memory Allocator (VMA) integration.
//!
//! Initializes a VMA allocator instance by wiring Vulkan function pointers and selecting
//! feature flags based on device capabilities.
const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;

const vma_log = log.ScopedLogger("VMA");

/// Global storage for VMA's Vulkan function table.
var g_vulkan_functions: c.VmaVulkanFunctions = undefined;

fn load_instance_proc(instance: c.VkInstance, primary: [*:0]const u8, fallback: ?[*:0]const u8) c.PFN_vkVoidFunction {
    const f1 = c.vkGetInstanceProcAddr(instance, primary);
    if (f1 != null) return f1;
    if (fallback) |fb| return c.vkGetInstanceProcAddr(instance, fb);
    return null;
}

fn load_device_proc(device: c.VkDevice, primary: [*:0]const u8, fallback: ?[*:0]const u8) c.PFN_vkVoidFunction {
    const f1 = c.vkGetDeviceProcAddr(device, primary);
    if (f1 != null) return f1;
    if (fallback) |fb| return c.vkGetDeviceProcAddr(device, fb);
    return null;
}

/// Initializes `alloc` with a VMA allocator instance for the given Vulkan device.
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

    g_vulkan_functions = std.mem.zeroes(c.VmaVulkanFunctions);

    g_vulkan_functions.vkGetPhysicalDeviceProperties = @ptrCast(load_instance_proc(instance, "vkGetPhysicalDeviceProperties", null));
    if (g_vulkan_functions.vkGetPhysicalDeviceProperties == null) vma_log.err("Failed to load vkGetPhysicalDeviceProperties", .{});

    g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties = @ptrCast(load_instance_proc(instance, "vkGetPhysicalDeviceMemoryProperties", null));
    if (g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties == null) vma_log.err("Failed to load vkGetPhysicalDeviceMemoryProperties", .{});

    g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR = @ptrCast(load_instance_proc(instance, "vkGetPhysicalDeviceMemoryProperties2", "vkGetPhysicalDeviceMemoryProperties2KHR"));
    if (g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR == null) vma_log.err("Failed to load vkGetPhysicalDeviceMemoryProperties2", .{});

    g_vulkan_functions.vkAllocateMemory = @ptrCast(load_device_proc(dev, "vkAllocateMemory", null));

    g_vulkan_functions.vkFreeMemory = @ptrCast(load_device_proc(dev, "vkFreeMemory", null));

    g_vulkan_functions.vkMapMemory = @ptrCast(load_device_proc(dev, "vkMapMemory", null));
    g_vulkan_functions.vkUnmapMemory = @ptrCast(load_device_proc(dev, "vkUnmapMemory", null));
    g_vulkan_functions.vkFlushMappedMemoryRanges = @ptrCast(load_device_proc(dev, "vkFlushMappedMemoryRanges", null));
    g_vulkan_functions.vkInvalidateMappedMemoryRanges = @ptrCast(load_device_proc(dev, "vkInvalidateMappedMemoryRanges", null));

    g_vulkan_functions.vkBindBufferMemory = @ptrCast(load_device_proc(dev, "vkBindBufferMemory", null));

    g_vulkan_functions.vkBindBufferMemory2KHR = @ptrCast(load_device_proc(dev, "vkBindBufferMemory2", "vkBindBufferMemory2KHR"));

    g_vulkan_functions.vkBindImageMemory = @ptrCast(load_device_proc(dev, "vkBindImageMemory", null));
    g_vulkan_functions.vkBindImageMemory2KHR = @ptrCast(load_device_proc(dev, "vkBindImageMemory2", "vkBindImageMemory2KHR"));

    g_vulkan_functions.vkGetBufferMemoryRequirements = @ptrCast(load_device_proc(dev, "vkGetBufferMemoryRequirements", null));
    g_vulkan_functions.vkGetImageMemoryRequirements = @ptrCast(load_device_proc(dev, "vkGetImageMemoryRequirements", null));
    g_vulkan_functions.vkCreateBuffer = @ptrCast(load_device_proc(dev, "vkCreateBuffer", null));
    g_vulkan_functions.vkDestroyBuffer = @ptrCast(load_device_proc(dev, "vkDestroyBuffer", null));
    g_vulkan_functions.vkCreateImage = @ptrCast(load_device_proc(dev, "vkCreateImage", null));
    g_vulkan_functions.vkDestroyImage = @ptrCast(load_device_proc(dev, "vkDestroyImage", null));
    g_vulkan_functions.vkCmdCopyBuffer = @ptrCast(load_device_proc(dev, "vkCmdCopyBuffer", null));

    g_vulkan_functions.vkGetBufferMemoryRequirements2KHR = @ptrCast(load_device_proc(dev, "vkGetBufferMemoryRequirements2", "vkGetBufferMemoryRequirements2KHR"));
    if (g_vulkan_functions.vkGetBufferMemoryRequirements2KHR == null) vma_log.err("Failed to load vkGetBufferMemoryRequirements2", .{});

    g_vulkan_functions.vkGetImageMemoryRequirements2KHR = @ptrCast(load_device_proc(dev, "vkGetImageMemoryRequirements2", "vkGetImageMemoryRequirements2KHR"));
    if (g_vulkan_functions.vkGetImageMemoryRequirements2KHR == null) vma_log.err("Failed to load vkGetImageMemoryRequirements2", .{});

    if (bufReq == null) {
        g_vulkan_functions.vkGetDeviceBufferMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetDeviceBufferMemoryRequirements"));
        if (g_vulkan_functions.vkGetDeviceBufferMemoryRequirements == null) {
            g_vulkan_functions.vkGetDeviceBufferMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetDeviceBufferMemoryRequirementsKHR"));
        }
    } else {
        g_vulkan_functions.vkGetDeviceBufferMemoryRequirements = bufReq;
    }

    if (imgReq == null) {
        g_vulkan_functions.vkGetDeviceImageMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetDeviceImageMemoryRequirements"));
        if (g_vulkan_functions.vkGetDeviceImageMemoryRequirements == null) {
            g_vulkan_functions.vkGetDeviceImageMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetDeviceImageMemoryRequirementsKHR"));
        }
    } else {
        g_vulkan_functions.vkGetDeviceImageMemoryRequirements = imgReq;
    }

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

    if (g_vulkan_functions.vkBindBufferMemory2KHR != null and g_vulkan_functions.vkBindImageMemory2KHR != null) {
        allocatorInfo.flags |= c.VMA_ALLOCATOR_CREATE_KHR_BIND_MEMORY2_BIT;
    } else {
        vma_log.warn("VMA bind-memory2 entrypoints missing; falling back to legacy bind calls", .{});
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

    vma_log.debug("Allocated image: handle={any} allocation={any}", .{ out_image.?.*, out_allocation.?.* });
    return true;
}

pub export fn allocate_buffer(alloc: ?*types.VulkanAllocator, buffer_ci: ?*const c.VkBufferCreateInfo, out_buffer: ?*c.VkBuffer, out_memory: ?*c.VkDeviceMemory, out_allocation: ?*c.VmaAllocation, required_props: c.VkMemoryPropertyFlags, map_immediately: bool, out_mapped_ptr: ?*?*anyopaque) callconv(.c) bool {
    if (alloc == null or buffer_ci == null or out_buffer == null or out_allocation == null) return false;

    var allocInfo = std.mem.zeroes(c.VmaAllocationCreateInfo);
    allocInfo.usage = get_vma_usage(required_props);
    allocInfo.flags = get_vma_flags(required_props);

    if (map_immediately) {
        allocInfo.flags |= c.VMA_ALLOCATION_CREATE_MAPPED_BIT;
    }

    var infoOut: c.VmaAllocationInfo = undefined;

    const result = c.vmaCreateBuffer(alloc.?.handle, buffer_ci, &allocInfo, out_buffer, out_allocation, &infoOut);
    if (result != c.VK_SUCCESS) {
        vma_log.err("vmaCreateBuffer failed: {d}", .{result});
        return false;
    }

    if (out_memory != null) {
        out_memory.?.* = infoOut.deviceMemory;
    }

    if (map_immediately and out_mapped_ptr != null) {
        out_mapped_ptr.?.* = infoOut.pMappedData;
    }

    vma_log.debug("Allocated buffer: handle={any} allocation={any}", .{ out_buffer.?.*, out_allocation.?.* });
    return true;
}

pub export fn free_image(alloc: ?*types.VulkanAllocator, image: c.VkImage, allocation: c.VmaAllocation) callconv(.c) void {
    if (alloc == null) return;
    if (image != null and allocation != null) {
        vma_log.debug("Freeing image: handle={any} allocation={any}", .{ image, allocation });
        c.vmaDestroyImage(alloc.?.handle, image, allocation);
    }
}

pub export fn free_buffer(alloc: ?*types.VulkanAllocator, buffer: c.VkBuffer, allocation: c.VmaAllocation) callconv(.c) void {
    if (alloc == null) return;
    if (buffer != null and allocation != null) {
        vma_log.debug("Freeing buffer: handle={any} allocation={any}", .{ buffer, allocation });
        c.vmaDestroyBuffer(alloc.?.handle, buffer, allocation);
    }
}

/// Mapped memory helpers.
pub export fn map_memory(alloc: ?*types.VulkanAllocator, allocation: c.VmaAllocation, ppData: ?*?*anyopaque) callconv(.c) c.VkResult {
    if (alloc == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    return c.vmaMapMemory(alloc.?.handle, allocation, ppData);
}

pub export fn unmap_memory(alloc: ?*types.VulkanAllocator, allocation: c.VmaAllocation) callconv(.c) void {
    if (alloc == null) return;
    c.vmaUnmapMemory(alloc.?.handle, allocation);
}
