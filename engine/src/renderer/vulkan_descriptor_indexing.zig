const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;
const vk_allocator = @import("vulkan_allocator.zig");
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");

const desc_idx_log = log.ScopedLogger("DESC_IDX");

const CARDINAL_BINDLESS_TEXTURE_BINDING = 0;

// Helper function to create default sampler
fn create_default_sampler(device: c.VkDevice, out_sampler: *c.VkSampler) bool {
    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_info.magFilter = c.VK_FILTER_LINEAR;
    sampler_info.minFilter = c.VK_FILTER_LINEAR;
    sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.anisotropyEnable = c.VK_TRUE;
    sampler_info.maxAnisotropy = 16.0;
    sampler_info.borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    sampler_info.unnormalizedCoordinates = c.VK_FALSE;
    sampler_info.compareEnable = c.VK_FALSE;
    sampler_info.compareOp = c.VK_COMPARE_OP_ALWAYS;
    sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
    sampler_info.mipLodBias = 0.0;
    sampler_info.minLod = 0.0;
    sampler_info.maxLod = c.VK_LOD_CLAMP_NONE;

    const result = c.vkCreateSampler(device, &sampler_info, null, out_sampler);
    if (result != c.VK_SUCCESS) {
        desc_idx_log.err("Failed to create default sampler: {d}", .{result});
        return false;
    }

    return true;
}

// Helper function to create descriptor pool for bindless textures
fn create_bindless_descriptor_pool(device: c.VkDevice, max_textures: u32, out_pool: *c.VkDescriptorPool) bool {
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = max_textures },
    };

    var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.flags = c.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT;
    pool_info.maxSets = 100; // Increased from 1 to support multiple bindless sets
    pool_info.poolSizeCount = 1;
    pool_info.pPoolSizes = &pool_sizes;

    desc_idx_log.info("Creating bindless descriptor pool with {d} max sets", .{pool_info.maxSets});

    const result = c.vkCreateDescriptorPool(device, &pool_info, null, out_pool);
    if (result != c.VK_SUCCESS) {
        desc_idx_log.err("Failed to create bindless descriptor pool: {d}", .{result});
        return false;
    }

    return true;
}

pub export fn vk_bindless_texture_pool_init(pool: ?*types.BindlessTexturePool, vulkan_state: ?*types.VulkanState, max_textures: u32) callconv(.c) bool {
    if (pool == null or vulkan_state == null) {
        desc_idx_log.err("Invalid parameters for bindless texture pool initialization", .{});
        return false;
    }
    const p = pool.?;
    const state = vulkan_state.?;

    if (!vk_descriptor_indexing_supported(state)) {
        desc_idx_log.err("Descriptor indexing not supported, cannot create bindless texture pool", .{});
        return false;
    }

    @memset(@as([*]u8, @ptrCast(p))[0..@sizeOf(types.BindlessTexturePool)], 0);

    p.device = state.context.device;
    p.physical_device = state.context.physical_device;
    p.allocator = &state.allocator;
    p.max_textures = max_textures;

    // Allocate texture array
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const textures_ptr = memory.cardinal_alloc(mem_alloc, max_textures * @sizeOf(types.BindlessTexture));
    if (textures_ptr == null) {
        desc_idx_log.err("Failed to allocate memory for bindless textures", .{});
        return false;
    }
    @memset(@as([*]u8, @ptrCast(textures_ptr))[0..(max_textures * @sizeOf(types.BindlessTexture))], 0);
    p.textures = @as([*]types.BindlessTexture, @ptrCast(@alignCast(textures_ptr)));

    // Initialize free list
    const free_indices_ptr = memory.cardinal_alloc(mem_alloc, max_textures * @sizeOf(u32));
    if (free_indices_ptr == null) {
        desc_idx_log.err("Failed to allocate memory for free indices", .{});
        memory.cardinal_free(mem_alloc, p.textures);
        return false;
    }
    p.free_indices = @as([*]u32, @ptrCast(@alignCast(free_indices_ptr)));

    // Initialize all indices as free
    var i: u32 = 0;
    while (i < max_textures) : (i += 1) {
        p.free_indices.?[i] = max_textures - 1 - i; // Reverse order for stack behavior
    }
    p.free_count = max_textures;

    // Allocate pending updates array
    const pending_updates_ptr = memory.cardinal_alloc(mem_alloc, max_textures * @sizeOf(u32));
    if (pending_updates_ptr == null) {
        desc_idx_log.err("Failed to allocate memory for pending updates", .{});
        memory.cardinal_free(mem_alloc, p.textures);
        memory.cardinal_free(mem_alloc, p.free_indices);
        return false;
    }
    p.pending_updates = @as([*]u32, @ptrCast(@alignCast(pending_updates_ptr)));

    // Create default sampler
    if (!create_default_sampler(p.device, &p.default_sampler)) {
        memory.cardinal_free(mem_alloc, p.textures);
        memory.cardinal_free(mem_alloc, p.free_indices);
        memory.cardinal_free(mem_alloc, p.pending_updates);
        return false;
    }

    // Check for descriptor buffer support
    if (state.context.supports_descriptor_buffer and state.context.descriptor_buffer_extension_available) {
        p.use_descriptor_buffer = true;
    } else {
        p.use_descriptor_buffer = false;
    }

    // Create descriptor set layout
    var bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{
            .binding = CARDINAL_BINDLESS_TEXTURE_BINDING,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = max_textures,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT | c.VK_SHADER_STAGE_MESH_BIT_EXT,
            .pImmutableSamplers = null,
        },
    };

    if (!vk_create_variable_descriptor_layout(p.device, 1, &bindings, CARDINAL_BINDLESS_TEXTURE_BINDING, max_textures, &p.descriptor_layout, p.use_descriptor_buffer)) {
        c.vkDestroySampler(p.device, p.default_sampler, null);
        memory.cardinal_free(mem_alloc, p.textures);
        memory.cardinal_free(mem_alloc, p.free_indices);
        memory.cardinal_free(mem_alloc, p.pending_updates);
        return false;
    }

    if (p.use_descriptor_buffer) {
        desc_idx_log.info("Using descriptor buffer for bindless textures", .{});

        p.descriptor_size = state.context.descriptor_buffer_combined_image_sampler_size;
        p.vkGetDescriptorEXT = state.context.vkGetDescriptorEXT;
        p.vkCmdBindDescriptorBuffersEXT = state.context.vkCmdBindDescriptorBuffersEXT;
        p.vkCmdSetDescriptorBufferOffsetsEXT = state.context.vkCmdSetDescriptorBufferOffsetsEXT;

        // 1. Get Layout Size
        if (state.context.vkGetDescriptorSetLayoutSizeEXT == null) {
            desc_idx_log.err("vkGetDescriptorSetLayoutSizeEXT not loaded", .{});
            return false;
        }
        state.context.vkGetDescriptorSetLayoutSizeEXT.?(p.device, p.descriptor_layout, &p.descriptor_set_size);

        // 2. Get Binding Offset
        if (state.context.vkGetDescriptorSetLayoutBindingOffsetEXT == null) {
            desc_idx_log.err("vkGetDescriptorSetLayoutBindingOffsetEXT not loaded", .{});
            return false;
        }
        state.context.vkGetDescriptorSetLayoutBindingOffsetEXT.?(p.device, p.descriptor_layout, CARDINAL_BINDLESS_TEXTURE_BINDING, &p.descriptor_offset);

        // 3. Create Buffer
        var bufferInfo = std.mem.zeroes(c.VkBufferCreateInfo);
        bufferInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bufferInfo.size = p.descriptor_set_size;
        bufferInfo.usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
        bufferInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        if (!vk_allocator.allocate_buffer(p.allocator, &bufferInfo, &p.descriptor_buffer.handle, &p.descriptor_buffer.memory, &p.descriptor_buffer.allocation, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, true, &p.descriptor_buffer.mapped)) {
            desc_idx_log.err("Failed to create descriptor buffer for bindless pool", .{});
            return false;
        }

        // Get buffer address
        if (state.context.vkGetBufferDeviceAddress != null) {
            var addressInfo = std.mem.zeroes(c.VkBufferDeviceAddressInfo);
            addressInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
            addressInfo.buffer = p.descriptor_buffer.handle;
            p.descriptor_buffer_address = state.context.vkGetBufferDeviceAddress.?(p.device, &addressInfo);
        } else {
            desc_idx_log.err("vkGetBufferDeviceAddress not loaded, cannot get descriptor buffer address", .{});
            return false;
        }

        // Pseudo-handle for compatibility?
        // We can use a dummy value for descriptor_set if needed, but we should rely on use_descriptor_buffer flag
        p.descriptor_set = @ptrFromInt(0xDEADBEEF); // Dummy handle

    } else {
        // Create descriptor pool
        if (!create_bindless_descriptor_pool(p.device, max_textures, &p.descriptor_pool)) {
            c.vkDestroyDescriptorSetLayout(p.device, p.descriptor_layout, null);
            c.vkDestroySampler(p.device, p.default_sampler, null);
            memory.cardinal_free(mem_alloc, p.textures);
            memory.cardinal_free(mem_alloc, p.free_indices);
            memory.cardinal_free(mem_alloc, p.pending_updates);
            return false;
        }

        // Allocate descriptor set
        if (!vk_allocate_variable_descriptor_set(p.device, p.descriptor_pool, p.descriptor_layout, max_textures, &p.descriptor_set)) {
            c.vkDestroyDescriptorPool(p.device, p.descriptor_pool, null);
            c.vkDestroyDescriptorSetLayout(p.device, p.descriptor_layout, null);
            c.vkDestroySampler(p.device, p.default_sampler, null);
            memory.cardinal_free(mem_alloc, p.textures);
            memory.cardinal_free(mem_alloc, p.free_indices);
            memory.cardinal_free(mem_alloc, p.pending_updates);
            return false;
        }
    }

    desc_idx_log.info("Bindless texture pool initialized with {d} max textures", .{max_textures});
    return true;
}

pub export fn vk_bindless_texture_pool_destroy(pool: ?*types.BindlessTexturePool) callconv(.c) void {
    if (pool == null or pool.?.device == null) {
        return;
    }
    const p = pool.?;

    // Free all allocated textures
    var i: u32 = 0;
    while (i < p.max_textures) : (i += 1) {
        if (p.textures.?[i].is_allocated) {
            vk_bindless_texture_free(p, i);
        }
    }

    // Destroy descriptor buffer if used
    if (p.use_descriptor_buffer) {
        if (p.descriptor_buffer.mapped != null) {
            // vk_allocator.unmap_memory(p.allocator, p.descriptor_buffer.allocation);
            p.descriptor_buffer.mapped = null;
        }
        vk_allocator.free_buffer(p.allocator, p.descriptor_buffer.handle, p.descriptor_buffer.allocation);
    }

    // Destroy Vulkan objects
    if (p.descriptor_pool != null) {
        c.vkDestroyDescriptorPool(p.device, p.descriptor_pool, null);
    }

    if (p.descriptor_layout != null) {
        c.vkDestroyDescriptorSetLayout(p.device, p.descriptor_layout, null);
    }

    if (p.default_sampler != null) {
        c.vkDestroySampler(p.device, p.default_sampler, null);
    }

    // Free memory
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    memory.cardinal_free(mem_alloc, p.textures);
    memory.cardinal_free(mem_alloc, p.free_indices);
    memory.cardinal_free(mem_alloc, p.pending_updates);

    @memset(@as([*]u8, @ptrCast(p))[0..@sizeOf(types.BindlessTexturePool)], 0);

    desc_idx_log.info("Bindless texture pool destroyed", .{});
}

pub export fn vk_bindless_texture_pool_reset(pool: ?*types.BindlessTexturePool) callconv(.c) void {
    if (pool == null) return;
    const p = pool.?;

    var i: u32 = 0;
    while (i < p.max_textures) : (i += 1) {
        if (p.textures.?[i].is_allocated) {
            // Free resource if owned
            if (p.textures.?[i].owns_resources) {
                vk_bindless_texture_free(p, i);
            } else {
                // Just mark as free
                p.textures.?[i].is_allocated = false;
                p.textures.?[i].image = null;
                p.textures.?[i].image_view = null; // Corrected field name from view to image_view
                p.textures.?[i].sampler = null;
            }
        }
    }

    // Reset free indices
    p.free_count = p.max_textures;
    i = 0;
    while (i < p.max_textures) : (i += 1) {
        p.free_indices.?[i] = p.max_textures - 1 - i;
    }

    desc_idx_log.info("Bindless texture pool reset", .{});
}

pub export fn vk_bindless_texture_allocate(pool: ?*types.BindlessTexturePool, create_info: ?*const types.BindlessTextureCreateInfo, out_index: ?*u32) callconv(.c) bool {
    if (pool == null or create_info == null or out_index == null) {
        desc_idx_log.err("Invalid parameters for bindless texture allocation", .{});
        return false;
    }
    const p = pool.?;
    const info = create_info.?;

    if (p.free_count == 0) {
        desc_idx_log.err("No free bindless texture slots available", .{});
        return false;
    }

    // Get free index
    p.free_count -= 1;
    const index = p.free_indices.?[p.free_count];
    var texture = &p.textures.?[index];

    // Create image
    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.format = info.format;
    image_info.extent = info.extent;
    image_info.mipLevels = info.mip_levels;
    image_info.arrayLayers = 1;
    image_info.samples = info.samples;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.usage = info.usage | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;

    var result = c.vkCreateImage(p.device, &image_info, null, &texture.image);
    if (result != c.VK_SUCCESS) {
        desc_idx_log.err("Failed to create bindless texture image: {d}", .{result});
        p.free_indices.?[p.free_count] = index;
        p.free_count += 1;
        return false;
    }

    // Allocate memory for image
    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(p.device, texture.image, &mem_requirements);

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_requirements.size;
    alloc_info.memoryTypeIndex = 0; // Will be found

    // Find memory type
    var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(p.physical_device, &mem_properties);

    var memory_type_index: u32 = c.UINT32_MAX;
    var j: u32 = 0;
    while (j < mem_properties.memoryTypeCount) : (j += 1) {
        if ((mem_requirements.memoryTypeBits & (@as(u32, 1) << @intCast(j))) != 0 and
            (mem_properties.memoryTypes[j].propertyFlags & c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0)
        {
            memory_type_index = j;
            break;
        }
    }

    if (memory_type_index == c.UINT32_MAX) {
        desc_idx_log.err("Failed to find suitable memory type for bindless texture", .{});
        c.vkDestroyImage(p.device, texture.image, null);
        p.free_indices.?[p.free_count] = index;
        p.free_count += 1;
        return false;
    }

    alloc_info.memoryTypeIndex = memory_type_index;

    result = c.vkAllocateMemory(p.device, &alloc_info, null, &texture.memory);
    if (result != c.VK_SUCCESS) {
        desc_idx_log.err("Failed to allocate memory for bindless texture: {d}", .{result});
        c.vkDestroyImage(p.device, texture.image, null);
        p.free_indices.?[p.free_count] = index;
        p.free_count += 1;
        return false;
    }

    result = c.vkBindImageMemory(p.device, texture.image, texture.memory, 0);
    if (result != c.VK_SUCCESS) {
        desc_idx_log.err("Failed to bind memory to bindless texture: {d}", .{result});
        c.vkFreeMemory(p.device, texture.memory, null);
        c.vkDestroyImage(p.device, texture.image, null);
        p.free_indices.?[p.free_count] = index;
        p.free_count += 1;
        return false;
    }

    // Create image view
    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = texture.image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = info.format;
    view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = info.mip_levels;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    result = c.vkCreateImageView(p.device, &view_info, null, &texture.image_view);
    if (result != c.VK_SUCCESS) {
        desc_idx_log.err("Failed to create image view for bindless texture: {d}", .{result});
        c.vkFreeMemory(p.device, texture.memory, null);
        c.vkDestroyImage(p.device, texture.image, null);
        p.free_indices.?[p.free_count] = index;
        p.free_count += 1;
        return false;
    }

    // Set texture properties
    texture.sampler = if (info.custom_sampler != null) info.custom_sampler else p.default_sampler;
    texture.descriptor_index = index;
    texture.is_allocated = true;
    texture.format = info.format;
    texture.extent = info.extent;
    texture.mip_levels = info.mip_levels;
    texture.owns_resources = true;

    // Mark for descriptor update
    p.pending_updates.?[p.pending_update_count] = index;
    p.pending_update_count += 1;
    p.needs_descriptor_update = true;

    p.allocated_count += 1;
    out_index.?.* = index;

    desc_idx_log.debug("Allocated bindless texture at index {d}", .{index});
    return true;
}

pub export fn vk_bindless_texture_register_existing(pool: ?*types.BindlessTexturePool, image: c.VkImage, view: c.VkImageView, sampler: c.VkSampler, out_index: ?*u32) callconv(.c) bool {
    if (pool == null or out_index == null) return false;
    const p = pool.?;

    if (p.free_count == 0) {
        desc_idx_log.err("No free bindless texture slots available", .{});
        return false;
    }

    p.free_count -= 1;
    const index = p.free_indices.?[p.free_count];
    var texture = &p.textures.?[index];

    texture.image = image;
    texture.image_view = view;
    texture.sampler = sampler;
    texture.descriptor_index = index;
    texture.is_allocated = true;
    texture.owns_resources = false;

    p.pending_updates.?[p.pending_update_count] = index;
    p.pending_update_count += 1;
    p.needs_descriptor_update = true;

    p.allocated_count += 1;
    out_index.?.* = index;
    return true;
}

pub export fn vk_bindless_texture_free(pool: ?*types.BindlessTexturePool, texture_index: u32) callconv(.c) void {
    if (pool == null or texture_index >= pool.?.max_textures) {
        desc_idx_log.err("Invalid texture index for bindless texture free: {d}", .{texture_index});
        return;
    }
    const p = pool.?;

    const texture = &p.textures.?[texture_index];
    if (!texture.is_allocated) {
        desc_idx_log.warn("Attempting to free already freed bindless texture at index {d}", .{texture_index});
        return;
    }

    // Destroy Vulkan objects only if we own them
    if (texture.owns_resources) {
        if (texture.image_view != null) {
            c.vkDestroyImageView(p.device, texture.image_view, null);
        }

        if (texture.image != null) {
            c.vkDestroyImage(p.device, texture.image, null);
        }

        if (texture.memory != null) {
            c.vkFreeMemory(p.device, texture.memory, null);
        }
    }

    // Reset texture
    @memset(@as([*]u8, @ptrCast(texture))[0..@sizeOf(types.BindlessTexture)], 0);

    // Return index to free list
    p.free_indices.?[p.free_count] = texture_index;
    p.free_count += 1;
    p.allocated_count -= 1;

    desc_idx_log.debug("Freed bindless texture at index {d}", .{texture_index});
}

pub export fn vk_bindless_texture_update_data(pool: ?*types.BindlessTexturePool, texture_index: u32, data: ?*const anyopaque, data_size: c.VkDeviceSize, command_buffer: c.VkCommandBuffer, timeline_value: u64) callconv(.c) bool {
    if (pool == null or data == null or data_size == 0) return false;
    const p = pool.?;

    if (texture_index >= p.max_textures) {
        desc_idx_log.err("Invalid texture index {d}", .{texture_index});
        return false;
    }

    const texture = &p.textures.?[texture_index];
    if (!texture.is_allocated) {
        desc_idx_log.err("Texture at index {d} is not allocated", .{texture_index});
        return false;
    }

    // Allocate staging buffer
    var bufferInfo = std.mem.zeroes(c.VkBufferCreateInfo);
    bufferInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = data_size;
    bufferInfo.usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bufferInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    var staging_buffer: c.VkBuffer = null;
    var staging_memory: c.VkDeviceMemory = null;
    var staging_allocation: c.VmaAllocation = null;

    if (!vk_allocator.allocate_buffer(p.allocator, &bufferInfo, &staging_buffer, &staging_memory, &staging_allocation, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, false, null)) {
        desc_idx_log.err("Failed to allocate staging buffer for texture update", .{});
        return false;
    }

    // Copy data to staging buffer
    var mapped_data: ?*anyopaque = null;
    if (vk_allocator.map_memory(p.allocator, staging_allocation, &mapped_data) != c.VK_SUCCESS) {
        desc_idx_log.err("Failed to map staging buffer memory", .{});
        vk_allocator.free_buffer(p.allocator, staging_buffer, staging_allocation);
        return false;
    }

    @memcpy(@as([*]u8, @ptrCast(mapped_data.?))[0..data_size], @as([*]const u8, @ptrCast(data.?))[0..data_size]);
    vk_allocator.unmap_memory(p.allocator, staging_allocation);

    // Record copy commands
    // 1. Transition to Transfer Dst
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
    barrier.srcAccessMask = 0;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED; // Discard old content
    barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = texture.image;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;

    var dep_info = std.mem.zeroes(c.VkDependencyInfo);
    dep_info.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep_info.imageMemoryBarrierCount = 1;
    dep_info.pImageMemoryBarriers = &barrier;

    c.vkCmdPipelineBarrier2(command_buffer, &dep_info);

    // 2. Copy buffer to image
    var region = std.mem.zeroes(c.VkBufferImageCopy);
    region.bufferOffset = 0;
    region.bufferRowLength = 0;
    region.bufferImageHeight = 0;
    region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel = 0;
    region.imageSubresource.baseArrayLayer = 0;
    region.imageSubresource.layerCount = 1;
    region.imageOffset = .{ .x = 0, .y = 0, .z = 0 };
    region.imageExtent = texture.extent;

    c.vkCmdCopyBufferToImage(command_buffer, staging_buffer, texture.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    // 3. Transition to Shader Read Only
    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier.srcAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT; // Assuming used in fragment shader
    barrier.dstAccessMask = c.VK_ACCESS_2_SHADER_READ_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    c.vkCmdPipelineBarrier2(command_buffer, &dep_info);

    // Register cleanup
    vk_texture_utils.add_staging_buffer_cleanup(p.allocator, staging_buffer, staging_memory, staging_allocation, p.device, timeline_value);

    return true;
}

pub export fn vk_bindless_texture_get_descriptor_set(pool: ?*const types.BindlessTexturePool) callconv(.c) c.VkDescriptorSet {
    if (pool == null) return null;
    return pool.?.descriptor_set;
}

pub export fn vk_bindless_texture_get_layout(pool: ?*const types.BindlessTexturePool) callconv(.c) c.VkDescriptorSetLayout {
    if (pool == null) return null;
    return pool.?.descriptor_layout;
}

pub export fn vk_bindless_texture_flush_updates(pool: ?*types.BindlessTexturePool) callconv(.c) bool {
    if (pool == null or !pool.?.needs_descriptor_update or pool.?.pending_update_count == 0) {
        return true;
    }
    const p = pool.?;

    if (p.use_descriptor_buffer) {
        if (p.vkGetDescriptorEXT == null) {
            desc_idx_log.err("vkGetDescriptorEXT not loaded", .{});
            return false;
        }

        var i: u32 = 0;
        while (i < p.pending_update_count) : (i += 1) {
            const texture_index = p.pending_updates.?[i];
            const texture = &p.textures.?[texture_index];

            if (!texture.is_allocated) {
                continue;
            }

            // Calculate offset in descriptor buffer
            const offset = p.descriptor_offset + @as(c.VkDeviceSize, texture_index) * p.descriptor_size;

            // Get pointer to the descriptor memory
            const dst_ptr = @as([*]u8, @ptrCast(p.descriptor_buffer.mapped)) + @as(usize, @intCast(offset));

            // Prepare descriptor info
            var image_info = c.VkDescriptorImageInfo{
                .sampler = texture.sampler,
                .imageView = texture.image_view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };

            var get_info = std.mem.zeroes(c.VkDescriptorGetInfoEXT);
            get_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
            get_info.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            get_info.data.pCombinedImageSampler = &image_info;

            // Write descriptor to buffer
            p.vkGetDescriptorEXT.?(p.device, &get_info, p.descriptor_size, dst_ptr);
        }

        p.needs_descriptor_update = false;
        p.pending_update_count = 0;
        return true;
    }

    // Prepare descriptor writes for updated textures
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const writes_ptr = memory.cardinal_alloc(mem_alloc, p.pending_update_count * @sizeOf(c.VkWriteDescriptorSet));
    const image_infos_ptr = memory.cardinal_alloc(mem_alloc, p.pending_update_count * @sizeOf(c.VkDescriptorImageInfo));

    if (writes_ptr == null or image_infos_ptr == null) {
        desc_idx_log.err("Failed to allocate memory for descriptor updates", .{});
        if (writes_ptr != null) memory.cardinal_free(mem_alloc, writes_ptr);
        if (image_infos_ptr != null) memory.cardinal_free(mem_alloc, image_infos_ptr);
        return false;
    }

    const writes = @as([*]c.VkWriteDescriptorSet, @ptrCast(@alignCast(writes_ptr)));
    const image_infos = @as([*]c.VkDescriptorImageInfo, @ptrCast(@alignCast(image_infos_ptr)));

    var write_count: u32 = 0;

    var i: u32 = 0;
    while (i < p.pending_update_count) : (i += 1) {
        const texture_index = p.pending_updates.?[i];
        const texture = &p.textures.?[texture_index];

        if (!texture.is_allocated) {
            continue;
        }

        // Image descriptor write
        image_infos[i] = .{
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .imageView = texture.image_view,
            .sampler = texture.sampler,
        };

        writes[write_count] = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = p.descriptor_set,
            .dstBinding = CARDINAL_BINDLESS_TEXTURE_BINDING,
            .dstArrayElement = texture_index,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .pImageInfo = &image_infos[i],
            .pNext = null,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        write_count += 1;
    }

    // Update descriptor sets
    if (write_count > 0) {
        c.vkUpdateDescriptorSets(p.device, write_count, writes, 0, null);
        desc_idx_log.debug("Updated {d} bindless texture descriptors", .{write_count});
    }

    // Clean up
    memory.cardinal_free(mem_alloc, writes_ptr);
    memory.cardinal_free(mem_alloc, image_infos_ptr);

    p.needs_descriptor_update = false;
    p.pending_update_count = 0;

    return true;
}

pub export fn vk_bindless_texture_get(pool: ?*const types.BindlessTexturePool, texture_index: u32) callconv(.c) ?*const types.BindlessTexture {
    if (pool == null or texture_index >= pool.?.max_textures or
        !pool.?.textures.?[texture_index].is_allocated)
    {
        return null;
    }
    return &pool.?.textures.?[texture_index];
}

pub export fn vk_descriptor_indexing_supported(vulkan_state: ?*const types.VulkanState) callconv(.c) bool {
    return vulkan_state != null and vulkan_state.?.context.supports_descriptor_indexing;
}

pub export fn vk_create_variable_descriptor_layout(device: c.VkDevice, binding_count: u32, bindings: [*c]const c.VkDescriptorSetLayoutBinding, variable_binding_index: u32, max_variable_count: u32, out_layout: ?*c.VkDescriptorSetLayout, use_descriptor_buffer: bool) callconv(.c) bool {
    _ = max_variable_count;
    if (device == null or bindings == null or out_layout == null) {
        desc_idx_log.err("Invalid parameters for variable descriptor layout creation", .{});
        return false;
    }

    // Create binding flags for variable descriptor count
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const binding_flags_ptr = memory.cardinal_alloc(mem_alloc, binding_count * @sizeOf(c.VkDescriptorBindingFlags));
    if (binding_flags_ptr == null) {
        desc_idx_log.err("Failed to allocate memory for binding flags", .{});
        return false;
    }
    @memset(@as([*]u8, @ptrCast(binding_flags_ptr))[0..(binding_count * @sizeOf(c.VkDescriptorBindingFlags))], 0);
    const binding_flags = @as([*]c.VkDescriptorBindingFlags, @ptrCast(@alignCast(binding_flags_ptr)));

    // Set flags for variable binding
    if (!use_descriptor_buffer) {
        binding_flags[variable_binding_index] = c.VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT |
            c.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT |
            c.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT;
    } else {
        binding_flags[variable_binding_index] = c.VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT |
            c.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT;
    }

    // Set update-after-bind flag for other bindings if needed
    var i: u32 = 0;
    while (i < binding_count) : (i += 1) {
        if (i != variable_binding_index) {
            if (!use_descriptor_buffer) {
                binding_flags[i] = c.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT;
            }
        }
    }

    var binding_flags_info = std.mem.zeroes(c.VkDescriptorSetLayoutBindingFlagsCreateInfo);
    binding_flags_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
    binding_flags_info.bindingCount = binding_count;
    binding_flags_info.pBindingFlags = binding_flags;

    var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_info.pNext = &binding_flags_info;

    if (use_descriptor_buffer) {
        layout_info.flags = c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
    } else {
        layout_info.flags = c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT;
    }

    layout_info.bindingCount = binding_count;
    layout_info.pBindings = bindings;

    const result = c.vkCreateDescriptorSetLayout(device, &layout_info, null, out_layout.?);

    memory.cardinal_free(mem_alloc, binding_flags_ptr);

    if (result != c.VK_SUCCESS) {
        desc_idx_log.err("Failed to create variable descriptor set layout: {d}", .{result});
        return false;
    }

    return true;
}

pub export fn vk_allocate_variable_descriptor_set(device: c.VkDevice, descriptor_pool: c.VkDescriptorPool, layout: c.VkDescriptorSetLayout, variable_count: u32, out_set: ?*c.VkDescriptorSet) callconv(.c) bool {
    if (device == null or descriptor_pool == null or layout == null or out_set == null) {
        desc_idx_log.err("Invalid parameters for variable descriptor set allocation", .{});
        return false;
    }

    var variable_info = std.mem.zeroes(c.VkDescriptorSetVariableDescriptorCountAllocateInfo);
    variable_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO;
    variable_info.descriptorSetCount = 1;
    variable_info.pDescriptorCounts = &variable_count;

    var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    alloc_info.pNext = &variable_info;
    alloc_info.descriptorPool = descriptor_pool;
    alloc_info.descriptorSetCount = 1;
    alloc_info.pSetLayouts = &layout;

    const result = c.vkAllocateDescriptorSets(device, &alloc_info, out_set.?);
    if (result != c.VK_SUCCESS) {
        desc_idx_log.err("Failed to allocate variable descriptor set: {d}", .{result});
        return false;
    }

    return true;
}
