const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("stdint.h");
    
    // Skip stdatomic.h and define types manually to avoid C import errors
    @cDefine("__STDATOMIC_H", "1");
    @cDefine("_STDATOMIC_H", "1");
    @cDefine("__CLANG_STDATOMIC_H", "1");
    @cDefine("__zig_translate_c__", "1");
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    
    @cInclude("vulkan/vulkan.h");
    @cInclude("vulkan_state.h");
    @cInclude("cardinal/renderer/vulkan_mt.h");
    @cInclude("cardinal/core/log.h");
});

// Helper for memory type finding
fn find_memory_type(alloc: *c.VulkanAllocator, type_filter: u32, properties: c.VkMemoryPropertyFlags, out_type_index: *u32) bool {
    var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(alloc.physical_device, &mem_props);

    var i: u32 = 0;
    while (i < mem_props.memoryTypeCount) : (i += 1) {
        if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and
            (mem_props.memoryTypes[i].propertyFlags & properties) == properties) {
            out_type_index.* = i;
            return true;
        }
    }

    return false;
}

// Helper for memory budget checking
fn check_memory_budget(alloc: *c.VulkanAllocator, requested_size: c.VkDeviceSize, memory_type_index: u32) bool {
    var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(alloc.physical_device, &mem_props);

    if (memory_type_index >= mem_props.memoryTypeCount) {
        log.cardinal_log_error("Invalid memory type index: {d}", .{memory_type_index});
        return false;
    }

    const heap_index = mem_props.memoryTypes[memory_type_index].heapIndex;
    const heap_size = mem_props.memoryHeaps[heap_index].size;

    const current_allocated = alloc.total_device_mem_allocated;

    // Safety threshold: reject allocation if it would use more than 85% of heap
    const safe_limit = (heap_size * 85) / 100;
    const projected_usage = current_allocated + requested_size;

    if (projected_usage > safe_limit) {
        log.cardinal_log_error("MEMORY PRESSURE DETECTED! Requested: {d} bytes, Current: {d} bytes, Heap size: {d} bytes, Safe limit: {d} bytes",
            .{requested_size, current_allocated, heap_size, safe_limit});
        return false;
    }

    // Warn if approaching 75% usage
    const warning_limit = (heap_size * 75) / 100;
    if (projected_usage > warning_limit) {
        const usage_percent = @as(f64, @floatFromInt(projected_usage)) / @as(f64, @floatFromInt(heap_size)) * 100.0;
        log.cardinal_log_warn("Memory usage approaching limit: {d}/{d} bytes ({d:.1}% of heap)",
            .{projected_usage, heap_size, usage_percent});
    }

    return true;
}

pub export fn vk_allocator_init(alloc: ?*c.VulkanAllocator, phys: c.VkPhysicalDevice, dev: c.VkDevice,
                       bufReq: c.PFN_vkGetDeviceBufferMemoryRequirements,
                       imgReq: c.PFN_vkGetDeviceImageMemoryRequirements,
                       bufDevAddr: c.PFN_vkGetBufferDeviceAddress,
                       bufReqKHR: c.PFN_vkGetDeviceBufferMemoryRequirementsKHR,
                       imgReqKHR: c.PFN_vkGetDeviceImageMemoryRequirementsKHR,
                       supports_maintenance8: bool) callconv(.c) bool {
    
    if (alloc == null or phys == null or dev == null or bufReq == null or imgReq == null or bufDevAddr == null) {
        log.cardinal_log_error("Invalid parameters for allocator init", .{});
        return false;
    }

    // Initialize struct with zeroes
    const allocator = alloc.?;
    allocator.* = std.mem.zeroes(c.VulkanAllocator);
    
    allocator.device = dev;
    allocator.physical_device = phys;
    allocator.fpGetDeviceBufferMemReq = bufReq;
    allocator.fpGetDeviceImageMemReq = imgReq;
    allocator.fpGetBufferDeviceAddress = bufDevAddr;
    allocator.fpGetDeviceBufferMemReqKHR = bufReqKHR;
    allocator.fpGetDeviceImageMemReqKHR = imgReqKHR;
    allocator.supports_maintenance8 = supports_maintenance8;
    allocator.total_device_mem_allocated = 0;
    allocator.total_device_mem_freed = 0;

    // Initialize mutex
    if (!c.cardinal_mt_mutex_init(&allocator.allocation_mutex)) {
        log.cardinal_log_error("Failed to initialize allocation mutex", .{});
        return false;
    }

    const maint8_str = if (supports_maintenance8) "enabled" else "not available";
    log.cardinal_log_info("Initialized - maintenance4: required, maintenance8: {s}, buffer device address: enabled", .{maint8_str});
    return true;
}

pub export fn vk_allocator_shutdown(alloc: ?*c.VulkanAllocator) callconv(.c) void {
    if (alloc == null) return;
    const allocator = alloc.?;

    // Fix integer overflow by checking bounds before subtraction
    const net = if (allocator.total_device_mem_allocated >= allocator.total_device_mem_freed)
        allocator.total_device_mem_allocated - allocator.total_device_mem_freed
        else 0;
    log.cardinal_log_info("Shutdown - Total allocated: {d} bytes, freed: {d} bytes, net: {d} bytes",
        .{allocator.total_device_mem_allocated, allocator.total_device_mem_freed, net});

    if (net > 0) {
        log.cardinal_log_warn("Memory leak detected: {d} bytes not freed", .{net});
    }

    c.cardinal_mt_mutex_destroy(&allocator.allocation_mutex);
    allocator.* = std.mem.zeroes(c.VulkanAllocator);
}

pub export fn vk_allocator_allocate_image(alloc: ?*c.VulkanAllocator, image_ci: ?*const c.VkImageCreateInfo,
                                 out_image: ?*c.VkImage, out_memory: ?*c.VkDeviceMemory,
                                 required_props: c.VkMemoryPropertyFlags) callconv(.c) bool {
    if (alloc == null or image_ci == null or out_image == null or out_memory == null) {
        log.cardinal_log_error("Invalid parameters for image allocation", .{});
        return false;
    }
    const allocator = alloc.?;
    const create_info = image_ci.?;

    log.cardinal_log_info("allocate_image: extent={d}x{d} fmt={d} usage=0x{x} props=0x{x}",
        .{create_info.extent.width, create_info.extent.height, create_info.format, create_info.usage, required_props});

    c.cardinal_mt_mutex_lock(&allocator.allocation_mutex);

    // Create image
    var result = c.vkCreateImage(allocator.device, create_info, null, out_image);
    log.cardinal_log_info("vkCreateImage => {d}, handle={*}", .{result, out_image.?.*});
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create image: {d}", .{result});
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    // Get memory requirements
    var mem_requirements: c.VkMemoryRequirements = undefined;
    var device_req = std.mem.zeroes(c.VkDeviceImageMemoryRequirements);
    device_req.sType = c.VK_STRUCTURE_TYPE_DEVICE_IMAGE_MEMORY_REQUIREMENTS;
    device_req.pNext = null;
    device_req.pCreateInfo = create_info;

    var mem_req2 = std.mem.zeroes(c.VkMemoryRequirements2);
    mem_req2.sType = c.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2;
    mem_req2.pNext = null;

    if (allocator.fpGetDeviceImageMemReqKHR != null) {
        log.cardinal_log_debug("Using vkGetDeviceImageMemoryRequirements for image allocation", .{});
        allocator.fpGetDeviceImageMemReqKHR.?(allocator.device, &device_req, &mem_req2);
    } else {
        allocator.fpGetDeviceImageMemReq.?(allocator.device, &device_req, &mem_req2);
    }
    mem_requirements = mem_req2.memoryRequirements;
    
    log.cardinal_log_info("Image mem reqs: size={d} align={d} types=0x{x}",
        .{mem_requirements.size, mem_requirements.alignment, mem_requirements.memoryTypeBits});

    if (mem_requirements.size == 0 or mem_requirements.memoryTypeBits == 0) {
        log.cardinal_log_error("Invalid image memory requirements (size={d}, types=0x{x})",
            .{mem_requirements.size, mem_requirements.memoryTypeBits});
        c.vkDestroyImage(allocator.device, out_image.?.*, null);
        out_image.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    var memory_type_index: u32 = 0;
    if (!find_memory_type(allocator, mem_requirements.memoryTypeBits, required_props, &memory_type_index)) {
        log.cardinal_log_error("Failed to find suitable memory type for image (required_props=0x{x})", .{required_props});
        c.vkDestroyImage(allocator.device, out_image.?.*, null);
        out_image.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }
    log.cardinal_log_info("Image memory type index: {d}", .{memory_type_index});

    if (!check_memory_budget(allocator, mem_requirements.size, memory_type_index)) {
        log.cardinal_log_error("Memory budget check failed for image allocation ({d} bytes)", .{mem_requirements.size});
        c.vkDestroyImage(allocator.device, out_image.?.*, null);
        out_image.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_requirements.size;
    alloc_info.memoryTypeIndex = memory_type_index;

    result = c.vkAllocateMemory(allocator.device, &alloc_info, null, out_memory);
    log.cardinal_log_info("vkAllocateMemory(Image) => {d}, mem={*} size={d}", .{result, out_memory.?.*, alloc_info.allocationSize});
    
    if (result != c.VK_SUCCESS) {
        if (result == c.VK_ERROR_OUT_OF_DEVICE_MEMORY) {
            log.cardinal_log_error("OUT OF DEVICE MEMORY! Failed to allocate {d} bytes for image. Total allocated: {d} bytes",
                .{alloc_info.allocationSize, allocator.total_device_mem_allocated});
        } else if (result == c.VK_ERROR_OUT_OF_HOST_MEMORY) {
            log.cardinal_log_error("OUT OF HOST MEMORY! Failed to allocate {d} bytes for image",
                .{alloc_info.allocationSize});
        } else {
            log.cardinal_log_error("Failed to allocate image memory: {d}", .{result});
        }
        c.vkDestroyImage(allocator.device, out_image.?.*, null);
        out_image.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    result = c.vkBindImageMemory(allocator.device, out_image.?.*, out_memory.?.*, 0);
    log.cardinal_log_info("vkBindImageMemory => {d}", .{result});
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to bind image memory: {d}", .{result});
        c.vkFreeMemory(allocator.device, out_memory.?.*, null);
        c.vkDestroyImage(allocator.device, out_image.?.*, null);
        out_image.?.* = null;
        out_memory.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    allocator.total_device_mem_allocated += mem_requirements.size;
    
    log.cardinal_log_info("Allocated image memory: {d} bytes (type: {d}). Total GPU memory: {d} bytes",
        .{mem_requirements.size, memory_type_index, allocator.total_device_mem_allocated});

    c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
    return true;
}

pub export fn vk_allocator_allocate_buffer(alloc: ?*c.VulkanAllocator, buffer_ci: ?*const c.VkBufferCreateInfo,
                                  out_buffer: ?*c.VkBuffer, out_memory: ?*c.VkDeviceMemory,
                                  required_props: c.VkMemoryPropertyFlags) callconv(.c) bool {
    if (alloc == null or buffer_ci == null or out_buffer == null or out_memory == null) {
        log.cardinal_log_error("Invalid parameters for buffer allocation", .{});
        return false;
    }
    const allocator = alloc.?;
    const create_info = buffer_ci.?;

    log.cardinal_log_info("allocate_buffer: size={d} usage=0x{x} sharingMode={d} props=0x{x}",
        .{create_info.size, create_info.usage, create_info.sharingMode, required_props});

    c.cardinal_mt_mutex_lock(&allocator.allocation_mutex);

    var result = c.vkCreateBuffer(allocator.device, create_info, null, out_buffer);
    log.cardinal_log_info("vkCreateBuffer => {d}, handle={*}", .{result, out_buffer.?.*});
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create buffer: {d}", .{result});
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    var mem_requirements: c.VkMemoryRequirements = undefined;
    var device_req = std.mem.zeroes(c.VkDeviceBufferMemoryRequirements);
    device_req.sType = c.VK_STRUCTURE_TYPE_DEVICE_BUFFER_MEMORY_REQUIREMENTS;
    device_req.pNext = null;
    device_req.pCreateInfo = create_info;

    var mem_req2 = std.mem.zeroes(c.VkMemoryRequirements2);
    mem_req2.sType = c.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2;
    mem_req2.pNext = null;

    if (allocator.fpGetDeviceBufferMemReqKHR != null) {
        log.cardinal_log_debug("Using vkGetDeviceBufferMemoryRequirements for buffer allocation", .{});
        allocator.fpGetDeviceBufferMemReqKHR.?(allocator.device, &device_req, &mem_req2);
    } else {
        allocator.fpGetDeviceBufferMemReq.?(allocator.device, &device_req, &mem_req2);
    }
    mem_requirements = mem_req2.memoryRequirements;
    
    log.cardinal_log_info("Buffer mem reqs: size={d} align={d} types=0x{x}",
        .{mem_requirements.size, mem_requirements.alignment, mem_requirements.memoryTypeBits});

    if (mem_requirements.size == 0 or mem_requirements.memoryTypeBits == 0) {
        log.cardinal_log_error("Invalid buffer memory requirements (size={d}, types=0x{x})",
            .{mem_requirements.size, mem_requirements.memoryTypeBits});
        c.vkDestroyBuffer(allocator.device, out_buffer.?.*, null);
        out_buffer.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    var memory_type_index: u32 = 0;
    if (!find_memory_type(allocator, mem_requirements.memoryTypeBits, required_props, &memory_type_index)) {
        log.cardinal_log_error("Failed to find suitable memory type for buffer (required_props=0x{x})", .{required_props});
        c.vkDestroyBuffer(allocator.device, out_buffer.?.*, null);
        out_buffer.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }
    log.cardinal_log_info("Buffer memory type index: {d}", .{memory_type_index});

    if (!check_memory_budget(allocator, mem_requirements.size, memory_type_index)) {
        log.cardinal_log_error("Memory budget check failed for buffer allocation ({d} bytes)", .{mem_requirements.size});
        c.vkDestroyBuffer(allocator.device, out_buffer.?.*, null);
        out_buffer.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_requirements.size;
    alloc_info.memoryTypeIndex = memory_type_index;

    var flags_info = std.mem.zeroes(c.VkMemoryAllocateFlagsInfo);
    if ((create_info.usage & c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT) != 0) {
        flags_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO;
        flags_info.flags = c.VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
        alloc_info.pNext = &flags_info;
        log.cardinal_log_info("Adding VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT for buffer with device address usage", .{});
    }

    result = c.vkAllocateMemory(allocator.device, &alloc_info, null, out_memory);
    log.cardinal_log_info("vkAllocateMemory(Buffer) => {d}, mem={*} size={d}", .{result, out_memory.?.*, alloc_info.allocationSize});
    
    if (result != c.VK_SUCCESS) {
        if (result == c.VK_ERROR_OUT_OF_DEVICE_MEMORY) {
            log.cardinal_log_error("OUT OF DEVICE MEMORY! Failed to allocate {d} bytes. Total allocated: {d} bytes",
                .{alloc_info.allocationSize, allocator.total_device_mem_allocated});
        } else if (result == c.VK_ERROR_OUT_OF_HOST_MEMORY) {
            log.cardinal_log_error("OUT OF HOST MEMORY! Failed to allocate {d} bytes",
                .{alloc_info.allocationSize});
        } else {
            log.cardinal_log_error("Failed to allocate buffer memory: {d}", .{result});
        }
        c.vkDestroyBuffer(allocator.device, out_buffer.?.*, null);
        out_buffer.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    result = c.vkBindBufferMemory(allocator.device, out_buffer.?.*, out_memory.?.*, 0);
    log.cardinal_log_info("vkBindBufferMemory => {d}", .{result});
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to bind buffer memory: {d}", .{result});
        c.vkFreeMemory(allocator.device, out_memory.?.*, null);
        c.vkDestroyBuffer(allocator.device, out_buffer.?.*, null);
        out_buffer.?.* = null;
        out_memory.?.* = null;
        c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
        return false;
    }

    allocator.total_device_mem_allocated += mem_requirements.size;
    
    log.cardinal_log_info("Allocated buffer memory: {d} bytes (type: {d}). Total GPU memory: {d} bytes",
        .{mem_requirements.size, memory_type_index, allocator.total_device_mem_allocated});

    c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
    return true;
}

pub export fn vk_allocator_free_image(alloc: ?*c.VulkanAllocator, image: c.VkImage, memory: c.VkDeviceMemory) callconv(.c) void {
    if (alloc == null) return;
    const allocator = alloc.?;
    
    log.cardinal_log_info("free_image: image={*} mem={*}", .{image, memory});

    c.cardinal_mt_mutex_lock(&allocator.allocation_mutex);

    var size: c.VkDeviceSize = 0;
    if (memory != null) {
        var mem_req2 = std.mem.zeroes(c.VkMemoryRequirements2);
        mem_req2.sType = c.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2;
        mem_req2.pNext = null;
        
        if (image != null) {
            var img_info = std.mem.zeroes(c.VkImageMemoryRequirementsInfo2);
            img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2;
            img_info.pNext = null;
            img_info.image = image;
            c.vkGetImageMemoryRequirements2(allocator.device, &img_info, &mem_req2);
            size = mem_req2.memoryRequirements.size;
        }

        c.vkFreeMemory(allocator.device, memory, null);
        allocator.total_device_mem_freed += size;
        
        log.cardinal_log_info("Freed image memory: {d} bytes", .{size});
    }

    if (image != null) {
        c.vkDestroyImage(allocator.device, image, null);
    }

    c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
}

pub export fn vk_allocator_free_buffer(alloc: ?*c.VulkanAllocator, buffer: c.VkBuffer, memory: c.VkDeviceMemory) callconv(.c) void {
    if (alloc == null) return;
    const allocator = alloc.?;

    log.cardinal_log_info("BUFFER_DESTROY_START: buffer={*} mem={*} device={*}", .{buffer, memory, allocator.device});

    c.cardinal_mt_mutex_lock(&allocator.allocation_mutex);

    var size: c.VkDeviceSize = 0;
    if (memory != null) {
        var mem_req2 = std.mem.zeroes(c.VkMemoryRequirements2);
        mem_req2.sType = c.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2;
        mem_req2.pNext = null;
        
        if (buffer != null) {
            var buf_info = std.mem.zeroes(c.VkBufferMemoryRequirementsInfo2);
            buf_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_REQUIREMENTS_INFO_2;
            buf_info.pNext = null;
            buf_info.buffer = buffer;
            c.vkGetBufferMemoryRequirements2(allocator.device, &buf_info, &mem_req2);
            size = mem_req2.memoryRequirements.size;
        }

        log.cardinal_log_info("MEMORY_FREE: buffer={*} memory={*} size={d} bytes", .{buffer, memory, size});
        c.vkFreeMemory(allocator.device, memory, null);
        allocator.total_device_mem_freed += size;
        log.cardinal_log_info("MEMORY_FREED: buffer={*} memory={*}", .{buffer, memory});
    }

    if (buffer != null) {
        log.cardinal_log_info("BUFFER_DESTROY: About to call vkDestroyBuffer on buffer={*}", .{buffer});
        c.vkDestroyBuffer(allocator.device, buffer, null);
        log.cardinal_log_info("BUFFER_DESTROYED: Successfully destroyed buffer={*}", .{buffer});
    }

    c.cardinal_mt_mutex_unlock(&allocator.allocation_mutex);
    log.cardinal_log_info("BUFFER_DESTROY_COMPLETE: buffer={*} mem={*}", .{buffer, memory});
}

pub export fn vk_allocator_get_buffer_device_address(alloc: ?*c.VulkanAllocator, buffer: c.VkBuffer) callconv(.c) c.VkDeviceAddress {
    if (alloc == null or alloc.?.fpGetBufferDeviceAddress == null or buffer == null) {
        log.cardinal_log_error("Invalid parameters for buffer device address query", .{});
        return 0;
    }
    const allocator = alloc.?;

    var address_info = std.mem.zeroes(c.VkBufferDeviceAddressInfo);
    address_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
    address_info.buffer = buffer;

    const address = allocator.fpGetBufferDeviceAddress.?(allocator.device, &address_info);
    log.cardinal_log_debug("Buffer device address: buffer={*} address=0x{x}", .{buffer, address});

    return address;
}
