const std = @import("std");
const log = @import("../../core/log.zig");
const types = @import("../vulkan_types.zig");
const vk_allocator = @import("../vulkan_allocator.zig");

const c = @import("../vulkan_c.zig").c;

fn get_state(s: *types.VulkanState) *types.VulkanState {
    return s;
}

export fn vk_descriptor_buffer_create_manager(create_info: ?*const types.DescriptorBufferCreateInfo, manager: ?*types.DescriptorBufferManager, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (create_info == null or manager == null or vulkan_state == null) {
        log.cardinal_log_error("Invalid parameters for descriptor buffer manager creation", .{});
        return false;
    }
    
    const s = vulkan_state.?;
    const m = manager.?;
    const ci = create_info.?;
    
    if (!s.context.supports_descriptor_buffer) {
        log.cardinal_log_error("VK_EXT_descriptor_buffer extension not supported", .{});
        return false;
    }
    
    _ = c.memset(m, 0, @sizeOf(types.DescriptorBufferManager));
    m.device = ci.device;
    m.allocator = ci.allocator;
    m.layout = ci.layout;
    
    // Get descriptor set layout size
    s.context.vkGetDescriptorSetLayoutSizeEXT.?(m.device, m.layout, &m.layout_size);
    
    // Get descriptor buffer properties
    var desc_buffer_props = std.mem.zeroes(c.VkPhysicalDeviceDescriptorBufferPropertiesEXT);
    desc_buffer_props.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT;
    
    var props2 = std.mem.zeroes(c.VkPhysicalDeviceProperties2);
    props2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    props2.pNext = &desc_buffer_props;
    
    c.vkGetPhysicalDeviceProperties2(s.context.physical_device, &props2);
    m.buffer_alignment = desc_buffer_props.descriptorBufferOffsetAlignment;
    
    // Calculate total buffer size (aligned for multiple sets)
    const aligned_layout_size = (m.layout_size + m.buffer_alignment - 1) & ~(m.buffer_alignment - 1);
    const total_size = aligned_layout_size * ci.max_sets;
    
    // Create descriptor buffer
    var buffer_info = std.mem.zeroes(c.VkBufferCreateInfo);
    buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = total_size;
    buffer_info.usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT; // | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    
    // Use project's VulkanAllocator instead of VMA
    if (!vk_allocator.vk_allocator_allocate_buffer(@ptrCast(@alignCast(m.allocator)), &buffer_info, &m.buffer_alloc.buffer, &m.buffer_alloc.memory, &m.buffer_alloc.allocation, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
        log.cardinal_log_error("Failed to create descriptor buffer", .{});
        return false;
    }
    
    // Map the buffer memory
    const result = c.vkMapMemory(m.device, m.buffer_alloc.memory, 0, total_size, 0, &m.buffer_alloc.mapped_data);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to map descriptor buffer memory: {d}", .{result});
        vk_allocator.vk_allocator_free_buffer(@ptrCast(@alignCast(m.allocator)), m.buffer_alloc.buffer, m.buffer_alloc.allocation);
        return false;
    }
    
    m.buffer_alloc.size = total_size;
    m.buffer_alloc.alignment = m.buffer_alignment;
    m.buffer_alloc.usage = buffer_info.usage;
    
    // Get binding offsets
    const max_bindings: u32 = 16;
    const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
    const memory = @import("../../core/memory.zig");
    const offsets_ptr = memory.cardinal_alloc(mem_alloc, max_bindings * @sizeOf(c.VkDeviceSize));
    m.binding_offsets = @ptrCast(@alignCast(offsets_ptr));
    if (m.binding_offsets == null) {
        log.cardinal_log_error("Failed to allocate memory for binding offsets", .{});
        c.vkUnmapMemory(m.device, m.buffer_alloc.memory);
        vk_allocator.vk_allocator_free_buffer(@ptrCast(@alignCast(m.allocator)), m.buffer_alloc.buffer, m.buffer_alloc.allocation);
        return false;
    }
    
    var i: u32 = 0;
    while (i < max_bindings) : (i += 1) {
        s.context.vkGetDescriptorSetLayoutBindingOffsetEXT.?(m.device, m.layout, i, &m.binding_offsets.?[i]);
    }
    m.binding_count = max_bindings;
    
    log.cardinal_log_info("Descriptor buffer manager created: size={d}, alignment={d}", .{total_size, m.buffer_alignment});
    return true;
}

export fn vk_descriptor_buffer_destroy_manager(manager: ?*types.DescriptorBufferManager) callconv(.c) void {
    if (manager == null or manager.?.device == null) {
        return;
    }
    const m = manager.?;
    
    if (m.buffer_alloc.buffer != null) {
        if (m.buffer_alloc.mapped_data != null) {
            c.vkUnmapMemory(m.device, m.buffer_alloc.memory);
        }
        vk_allocator.vk_allocator_free_buffer(@ptrCast(@alignCast(m.allocator)), m.buffer_alloc.buffer, m.buffer_alloc.allocation);
    }
    
    c.free(m.binding_offsets);
    _ = c.memset(m, 0, @sizeOf(types.DescriptorBufferManager));
}

export fn vk_descriptor_buffer_get_address(manager: ?*const types.DescriptorBufferManager, set_index: u32, vulkan_state: ?*types.VulkanState) callconv(.c) c.VkDeviceAddress {
    if (manager == null or vulkan_state == null) {
        return 0;
    }
    const m = manager.?;
    const s = vulkan_state.?;
    
    var address_info = std.mem.zeroes(c.VkBufferDeviceAddressInfo);
    address_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
    address_info.buffer = m.buffer_alloc.buffer;
    
    const base_address = s.context.vkGetBufferDeviceAddress.?(m.device, &address_info);
    
    const aligned_layout_size = (m.layout_size + m.buffer_alignment - 1) & ~(m.buffer_alignment - 1);
    
    return base_address + (aligned_layout_size * set_index);
}

export fn vk_descriptor_buffer_update_uniform_buffer(manager: ?*types.DescriptorBufferManager, set_index: u32, binding: u32, buffer: c.VkBuffer, offset: c.VkDeviceSize, range: c.VkDeviceSize, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (manager == null or vulkan_state == null or binding >= manager.?.binding_count) {
        log.cardinal_log_error("Invalid parameters for uniform buffer update", .{});
        return false;
    }
    const m = manager.?;
    const s = vulkan_state.?;
    
    var address_info = std.mem.zeroes(c.VkBufferDeviceAddressInfo);
    address_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
    address_info.buffer = buffer;
    
    const buffer_address = s.context.vkGetBufferDeviceAddress.?(m.device, &address_info);
    
    var address_desc = std.mem.zeroes(c.VkDescriptorAddressInfoEXT);
    address_desc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT;
    address_desc.address = buffer_address + offset;
    address_desc.range = range;
    
    var desc_info = std.mem.zeroes(c.VkDescriptorGetInfoEXT);
    desc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
    desc_info.type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    desc_info.data.pUniformBuffer = &address_desc;
    
    const aligned_layout_size = (m.layout_size + m.buffer_alignment - 1) & ~(m.buffer_alignment - 1);
    const set_offset = aligned_layout_size * set_index;
    const binding_offset = m.binding_offsets.?[binding];
    
    const dest_ptr = @as([*]u8, @ptrCast(m.buffer_alloc.mapped_data)) + set_offset + binding_offset;
    
    s.context.vkGetDescriptorEXT.?(m.device, &desc_info, s.context.descriptor_buffer_uniform_buffer_size, @ptrCast(dest_ptr));
    
    m.needs_update = true;
    return true;
}

export fn vk_descriptor_buffer_update_image_sampler(manager: ?*types.DescriptorBufferManager, set_index: u32, binding: u32, array_element: u32, image_view: c.VkImageView, vk_sampler: c.VkSampler, image_layout: c.VkImageLayout, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (manager == null or vulkan_state == null or binding >= manager.?.binding_count) {
        log.cardinal_log_error("Invalid parameters for image sampler update", .{});
        return false;
    }
    const m = manager.?;
    const s = vulkan_state.?;
    
    var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
    image_info.sampler = vk_sampler;
    image_info.imageView = image_view;
    image_info.imageLayout = image_layout;
    
    var desc_info = std.mem.zeroes(c.VkDescriptorGetInfoEXT);
    desc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
    desc_info.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    desc_info.data.pCombinedImageSampler = &image_info;
    
    const aligned_layout_size = (m.layout_size + m.buffer_alignment - 1) & ~(m.buffer_alignment - 1);
    const set_offset = aligned_layout_size * set_index;
    const binding_offset = m.binding_offsets.?[binding];
    
    const element_offset = array_element * s.context.descriptor_buffer_combined_image_sampler_size;
    
    const dest_ptr = @as([*]u8, @ptrCast(m.buffer_alloc.mapped_data)) + set_offset + binding_offset + element_offset;
    
    s.context.vkGetDescriptorEXT.?(m.device, &desc_info, s.context.descriptor_buffer_combined_image_sampler_size, @ptrCast(dest_ptr));
    
    m.needs_update = true;
    return true;
}

export fn vk_descriptor_buffer_bind(cmd_buffer: c.VkCommandBuffer, pipeline_bind_point: c.VkPipelineBindPoint, layout: c.VkPipelineLayout, first_set: u32, set_count: u32, buffers: ?[*]const c.VkBuffer, offsets: ?[*]const c.VkDeviceSize, vulkan_state: ?*types.VulkanState) callconv(.c) void {
    _ = pipeline_bind_point;
    _ = layout;
    _ = first_set;
    _ = offsets;
    
    if (vulkan_state == null or vulkan_state.?.context.vkCmdBindDescriptorBuffersEXT == null) {
        log.cardinal_log_error("Descriptor buffer extension not available", .{});
        return;
    }
    const s = vulkan_state.?;
    
    const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
    const memory = @import("../../core/memory.zig");

    const binding_infos = memory.cardinal_alloc(mem_alloc, set_count * @sizeOf(c.VkDescriptorBufferBindingInfoEXT));
    if (binding_infos == null) {
        log.cardinal_log_error("Failed to allocate memory for binding infos", .{});
        return;
    }
    defer memory.cardinal_free(mem_alloc, binding_infos);
    
    const infos = @as([*]c.VkDescriptorBufferBindingInfoEXT, @ptrCast(@alignCast(binding_infos)));
    
    var i: u32 = 0;
    while (i < set_count) : (i += 1) {
        var address_info = std.mem.zeroes(c.VkBufferDeviceAddressInfo);
        address_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
        address_info.buffer = buffers.?[i];
        
        const buffer_address = s.context.vkGetBufferDeviceAddress.?(s.context.device, &address_info);
        
        infos[i] = std.mem.zeroes(c.VkDescriptorBufferBindingInfoEXT);
        infos[i].sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT;
        infos[i].address = buffer_address;
        infos[i].usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT;
    }
    
    s.context.vkCmdBindDescriptorBuffersEXT.?(cmd_buffer, set_count, infos);
}

export fn vk_descriptor_buffer_set_offsets(cmd_buffer: c.VkCommandBuffer, pipeline_bind_point: c.VkPipelineBindPoint, layout: c.VkPipelineLayout, first_set: u32, set_count: u32, buffer_indices: ?[*]const u32, offsets: ?[*]const c.VkDeviceSize, vulkan_state: ?*types.VulkanState) callconv(.c) void {
    if (cmd_buffer == null or vulkan_state == null or !vulkan_state.?.context.supports_descriptor_buffer) {
        log.cardinal_log_error("Invalid parameters or descriptor buffer not supported", .{});
        return;
    }
    const s = vulkan_state.?;
    
    if (s.context.vkCmdSetDescriptorBufferOffsetsEXT == null) {
        log.cardinal_log_error("vkCmdSetDescriptorBufferOffsetsEXT function not loaded", .{});
        return;
    }
    
    s.context.vkCmdSetDescriptorBufferOffsetsEXT.?(cmd_buffer, pipeline_bind_point, layout, first_set, set_count, buffer_indices, offsets);
}
