const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;

// Global storage for VMA functions to ensure they remain valid
// (VMA copies them, but just to be safe and avoid stack issues)
var g_vulkan_functions: c.VmaVulkanFunctions = undefined;

// Debug wrapper for vkAllocateMemory
var real_vkAllocateMemory: c.PFN_vkAllocateMemory = null;
var real_vkFreeMemory: c.PFN_vkFreeMemory = null;
var real_vkBindBufferMemory: c.PFN_vkBindBufferMemory = null;

fn debug_vkAllocateMemory(device: c.VkDevice, pAllocateInfo: ?*const c.VkMemoryAllocateInfo, pAllocator: ?*const c.VkAllocationCallbacks, pMemory: ?*c.VkDeviceMemory) callconv(.c) c.VkResult {
    if (real_vkAllocateMemory) |func| {
        const res = func(device, pAllocateInfo, pAllocator, pMemory);
        if (res == c.VK_SUCCESS and pMemory != null) {
            log.cardinal_log_warn("[VMA_DEBUG] vkAllocateMemory success, handle: {any}", .{pMemory.?.*});
        } else {
            log.cardinal_log_error("[VMA_DEBUG] vkAllocateMemory failed: {d}", .{res});
        }
        return res;
    }
    return c.VK_ERROR_INITIALIZATION_FAILED;
}

fn debug_vkFreeMemory(device: c.VkDevice, memory: c.VkDeviceMemory, pAllocator: ?*const c.VkAllocationCallbacks) callconv(.c) void {
    if (real_vkFreeMemory) |func| {
        log.cardinal_log_warn("[VMA_DEBUG] vkFreeMemory called, handle: {any}", .{memory});
        func(device, memory, pAllocator);
    }
}

fn debug_vkBindBufferMemory(device: c.VkDevice, buffer: c.VkBuffer, memory: c.VkDeviceMemory, memoryOffset: c.VkDeviceSize) callconv(.c) c.VkResult {
    if (real_vkBindBufferMemory) |func| {
        log.cardinal_log_warn("[VMA_DEBUG] vkBindBufferMemory called. Buffer: {any}, Memory: {any}, Offset: {d}", .{ buffer, memory, memoryOffset });
        return func(device, buffer, memory, memoryOffset);
    }
    return c.VK_ERROR_INITIALIZATION_FAILED;
}

pub export fn vk_allocator_init(alloc: ?*types.VulkanAllocator, instance: c.VkInstance, phys: c.VkPhysicalDevice, dev: c.VkDevice, bufReq: c.PFN_vkGetDeviceBufferMemoryRequirements, imgReq: c.PFN_vkGetDeviceImageMemoryRequirements, bufDevAddr: c.PFN_vkGetBufferDeviceAddress, bufReqKHR: c.PFN_vkGetDeviceBufferMemoryRequirementsKHR, imgReqKHR: c.PFN_vkGetDeviceImageMemoryRequirementsKHR, supports_maintenance8: bool) callconv(.c) bool {
    if (alloc == null or phys == null or dev == null or instance == null) {
        log.cardinal_log_error("Invalid parameters for allocator init", .{});
        return false;
    }

    _ = bufReqKHR;
    _ = imgReqKHR;
    _ = bufDevAddr;

    const allocator = alloc.?;
    allocator.physical_device = phys;
    allocator.device = dev;

    // Use global storage to ensure persistence if VMA keeps the pointer (though it usually copies)
    // and to avoid stack overflow for large structs
    g_vulkan_functions = std.mem.zeroes(c.VmaVulkanFunctions);

    // Instance functions
    g_vulkan_functions.vkGetPhysicalDeviceProperties = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceProperties"));
    if (g_vulkan_functions.vkGetPhysicalDeviceProperties == null) log.cardinal_log_error("Failed to load vkGetPhysicalDeviceProperties", .{});

    g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceMemoryProperties"));
    if (g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties == null) log.cardinal_log_error("Failed to load vkGetPhysicalDeviceMemoryProperties", .{});

    g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceMemoryProperties2"));
    if (g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR == null) {
        g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceMemoryProperties2KHR"));
    }
    if (g_vulkan_functions.vkGetPhysicalDeviceMemoryProperties2KHR == null) log.cardinal_log_error("Failed to load vkGetPhysicalDeviceMemoryProperties2", .{});

    // Device functions
    // real_vkAllocateMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkAllocateMemory"));
    g_vulkan_functions.vkAllocateMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkAllocateMemory")); // debug_vkAllocateMemory;

    // real_vkFreeMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkFreeMemory"));
    g_vulkan_functions.vkFreeMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkFreeMemory")); // debug_vkFreeMemory;

    g_vulkan_functions.vkMapMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkMapMemory"));
    g_vulkan_functions.vkUnmapMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkUnmapMemory"));
    g_vulkan_functions.vkFlushMappedMemoryRanges = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkFlushMappedMemoryRanges"));
    g_vulkan_functions.vkInvalidateMappedMemoryRanges = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkInvalidateMappedMemoryRanges"));

    // real_vkBindBufferMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindBufferMemory"));
    g_vulkan_functions.vkBindBufferMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindBufferMemory")); // debug_vkBindBufferMemory;

    g_vulkan_functions.vkBindImageMemory = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindImageMemory"));
    g_vulkan_functions.vkGetBufferMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetBufferMemoryRequirements"));
    g_vulkan_functions.vkGetImageMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetImageMemoryRequirements"));
    g_vulkan_functions.vkCreateBuffer = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkCreateBuffer"));
    g_vulkan_functions.vkDestroyBuffer = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkDestroyBuffer"));
    g_vulkan_functions.vkCreateImage = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkCreateImage"));
    g_vulkan_functions.vkDestroyImage = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkDestroyImage"));
    g_vulkan_functions.vkCmdCopyBuffer = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkCmdCopyBuffer"));

    g_vulkan_functions.vkGetBufferMemoryRequirements2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetBufferMemoryRequirements2"));
    if (g_vulkan_functions.vkGetBufferMemoryRequirements2KHR == null) g_vulkan_functions.vkGetBufferMemoryRequirements2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetBufferMemoryRequirements2KHR"));
    if (g_vulkan_functions.vkGetBufferMemoryRequirements2KHR == null) log.cardinal_log_error("Failed to load vkGetBufferMemoryRequirements2", .{});

    g_vulkan_functions.vkGetImageMemoryRequirements2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetImageMemoryRequirements2"));
    if (g_vulkan_functions.vkGetImageMemoryRequirements2KHR == null) g_vulkan_functions.vkGetImageMemoryRequirements2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkGetImageMemoryRequirements2KHR"));
    if (g_vulkan_functions.vkGetImageMemoryRequirements2KHR == null) log.cardinal_log_error("Failed to load vkGetImageMemoryRequirements2", .{});

    g_vulkan_functions.vkBindBufferMemory2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindBufferMemory2"));
    if (g_vulkan_functions.vkBindBufferMemory2KHR == null) g_vulkan_functions.vkBindBufferMemory2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindBufferMemory2KHR"));

    g_vulkan_functions.vkBindImageMemory2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindImageMemory2"));
    if (g_vulkan_functions.vkBindImageMemory2KHR == null) g_vulkan_functions.vkBindImageMemory2KHR = @ptrCast(c.vkGetDeviceProcAddr(dev, "vkBindImageMemory2KHR"));

    g_vulkan_functions.vkGetDeviceBufferMemoryRequirements = bufReq;
    g_vulkan_functions.vkGetDeviceImageMemoryRequirements = imgReq;

    // Additional functions if available
    // vulkanFunctions.vkGetBufferDeviceAddress = bufDevAddr;

    var allocatorInfo = std.mem.zeroes(c.VmaAllocatorCreateInfo);
    allocatorInfo.physicalDevice = phys;
    allocatorInfo.device = dev;
    allocatorInfo.instance = instance;
    allocatorInfo.pVulkanFunctions = &g_vulkan_functions;
    allocatorInfo.vulkanApiVersion = c.VK_API_VERSION_1_3;

    if (supports_maintenance8) {
        allocatorInfo.flags |= c.VMA_ALLOCATOR_CREATE_KHR_MAINTENANCE4_BIT;
    }

    // if (bufDevAddr != null) {
    //    allocatorInfo.flags |= c.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT;
    // }

    var vma_alloc: c.VmaAllocator = null;
    const result = c.vmaCreateAllocator(&allocatorInfo, &vma_alloc);

    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create VMA allocator: {d}", .{result});
        return false;
    }

    allocator.handle = vma_alloc;
    log.cardinal_log_info("VMA Allocator initialized", .{});
    return true;
}

pub export fn vk_allocator_shutdown(alloc: ?*types.VulkanAllocator) callconv(.c) void {
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

pub export fn vk_allocator_allocate_image(alloc: ?*types.VulkanAllocator, image_ci: ?*const c.VkImageCreateInfo, out_image: ?*c.VkImage, out_memory: ?*c.VkDeviceMemory, out_allocation: ?*c.VmaAllocation, required_props: c.VkMemoryPropertyFlags) callconv(.c) bool {
    if (alloc == null or image_ci == null or out_image == null or out_allocation == null) return false;

    var allocInfo = std.mem.zeroes(c.VmaAllocationCreateInfo);
    allocInfo.usage = get_vma_usage(required_props);
    allocInfo.flags = get_vma_flags(required_props);

    var infoOut: c.VmaAllocationInfo = undefined;

    const result = c.vmaCreateImage(alloc.?.handle, image_ci, &allocInfo, out_image, out_allocation, &infoOut);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("vmaCreateImage failed: {d}", .{result});
        return false;
    }

    if (out_memory != null) {
        out_memory.?.* = infoOut.deviceMemory;
    }

    log.cardinal_log_info("vk_allocator_allocate_image success", .{});
    return true;
}

pub export fn vk_allocator_allocate_buffer(alloc: ?*types.VulkanAllocator, buffer_ci: ?*const c.VkBufferCreateInfo, out_buffer: ?*c.VkBuffer, out_memory: ?*c.VkDeviceMemory, out_allocation: ?*c.VmaAllocation, required_props: c.VkMemoryPropertyFlags) callconv(.c) bool {
    if (alloc == null or buffer_ci == null or out_buffer == null or out_allocation == null) return false;

    var allocInfo = std.mem.zeroes(c.VmaAllocationCreateInfo);
    allocInfo.usage = get_vma_usage(required_props);
    allocInfo.flags = get_vma_flags(required_props);
    if ((required_props & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
        // allocInfo.flags |= c.VMA_ALLOCATION_CREATE_MAPPED_BIT;
    }

    var allocInfoOut: c.VmaAllocationInfo = undefined;

    log.cardinal_log_info("Calling vmaCreateBuffer: size={d}, usage={d}, flags={d}", .{ buffer_ci.?.size, buffer_ci.?.usage, allocInfo.flags });

    const result = c.vmaCreateBuffer(alloc.?.handle, buffer_ci, &allocInfo, out_buffer, out_allocation, &allocInfoOut);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("vmaCreateBuffer failed: {d}", .{result});
        return false;
    }

    if (out_memory != null) {
        out_memory.?.* = allocInfoOut.deviceMemory;
        log.cardinal_log_debug("vmaCreateBuffer returned memory handle: {any}", .{allocInfoOut.deviceMemory});
    }

    log.cardinal_log_info("vk_allocator_allocate_buffer success", .{});
    return true;
}

pub export fn vk_allocator_free_image(alloc: ?*types.VulkanAllocator, image: c.VkImage, allocation: c.VmaAllocation) callconv(.c) void {
    if (alloc == null or image == null or allocation == null) return;
    c.vmaDestroyImage(alloc.?.handle, image, allocation);
}

pub export fn vk_allocator_free_buffer(alloc: ?*types.VulkanAllocator, buffer: c.VkBuffer, allocation: c.VmaAllocation) callconv(.c) void {
    if (alloc == null or buffer == null or allocation == null) return;
    c.vmaDestroyBuffer(alloc.?.handle, buffer, allocation);
}

// Helpers for mapped memory
pub export fn vk_allocator_map_memory(alloc: ?*types.VulkanAllocator, allocation: c.VmaAllocation, ppData: ?*?*anyopaque) callconv(.c) c.VkResult {
    if (alloc == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    return c.vmaMapMemory(alloc.?.handle, allocation, ppData);
}

pub export fn vk_allocator_unmap_memory(alloc: ?*types.VulkanAllocator, allocation: c.VmaAllocation) callconv(.c) void {
    if (alloc == null) return;
    c.vmaUnmapMemory(alloc.?.handle, allocation);
}
