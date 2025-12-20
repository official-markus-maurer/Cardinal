const std = @import("std");
const rhi = @import("../rhi_types.zig");
const renderer_types = @import("../../renderer/vulkan_types.zig");
const c = @import("../../renderer/vulkan_c.zig").c;
const vk_allocator = @import("../../renderer/vulkan_allocator.zig");

fn toVkBufferUsage(usage: rhi.BufferUsage) c.VkBufferUsageFlags {
    var flags: c.VkBufferUsageFlags = 0;
    if (usage.transfer_src) flags |= c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    if (usage.transfer_dst) flags |= c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    if (usage.uniform_texel_buffer) flags |= c.VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT;
    if (usage.storage_texel_buffer) flags |= c.VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT;
    if (usage.uniform_buffer) flags |= c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    if (usage.storage_buffer) flags |= c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    if (usage.index_buffer) flags |= c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
    if (usage.vertex_buffer) flags |= c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    if (usage.indirect_buffer) flags |= c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
    if (usage.shader_device_address) flags |= c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    return flags;
}

fn toVkImageUsage(usage: rhi.TextureUsage) c.VkImageUsageFlags {
    var flags: c.VkImageUsageFlags = 0;
    if (usage.transfer_src) flags |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (usage.transfer_dst) flags |= c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (usage.sampled) flags |= c.VK_IMAGE_USAGE_SAMPLED_BIT;
    if (usage.storage) flags |= c.VK_IMAGE_USAGE_STORAGE_BIT;
    if (usage.color_attachment) flags |= c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (usage.depth_stencil_attachment) flags |= c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    if (usage.transient_attachment) flags |= c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT;
    if (usage.input_attachment) flags |= c.VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT;
    return flags;
}

fn toVkMemoryPropertyFlags(usage: rhi.MemoryUsage) c.VkMemoryPropertyFlags {
    return switch (usage) {
        .GPU_ONLY => c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .CPU_ONLY => c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        .CPU_TO_GPU => c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .GPU_TO_CPU => c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
    };
}

fn toVkFormat(format: rhi.Format) c.VkFormat {
    return switch (format) {
        .UNDEFINED => c.VK_FORMAT_UNDEFINED,
        .R8_UNORM => c.VK_FORMAT_R8_UNORM,
        .R8G8B8A8_UNORM => c.VK_FORMAT_R8G8B8A8_UNORM,
        .R8G8B8A8_SRGB => c.VK_FORMAT_R8G8B8A8_SRGB,
        .B8G8R8A8_UNORM => c.VK_FORMAT_B8G8R8A8_UNORM,
        .B8G8R8A8_SRGB => c.VK_FORMAT_B8G8R8A8_SRGB,
        .D32_FLOAT => c.VK_FORMAT_D32_SFLOAT,
        else => c.VK_FORMAT_UNDEFINED,
    };
}

fn toVkIndexType(type_: rhi.IndexType) c.VkIndexType {
    return switch (type_) {
        .UINT16 => c.VK_INDEX_TYPE_UINT16,
        .UINT32 => c.VK_INDEX_TYPE_UINT32,
    };
}

fn toVkPipelineBindPoint(point: rhi.PipelineBindPoint) c.VkPipelineBindPoint {
    return switch (point) {
        .GRAPHICS => c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .COMPUTE => c.VK_PIPELINE_BIND_POINT_COMPUTE,
        .RAY_TRACING => c.VK_PIPELINE_BIND_POINT_RAY_TRACING_KHR,
    };
}

pub const Buffer = struct {
    handle: c.VkBuffer,
    allocation: c.VmaAllocation,
    memory: c.VkDeviceMemory,
    size: u64,
    mapped_ptr: ?*anyopaque = null,
};

pub const Texture = struct {
    image: c.VkImage,
    view: c.VkImageView,
    allocation: c.VmaAllocation,
    memory: c.VkDeviceMemory,
    width: u32,
    height: u32,
    format: c.VkFormat,
};

pub const Pipeline = struct {
    handle: c.VkPipeline,
    layout: c.VkPipelineLayout,
    bind_point: c.VkPipelineBindPoint,
};

pub const CommandList = struct {
    handle: c.VkCommandBuffer,

    pub fn begin(self: CommandList) void {
        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        _ = c.vkBeginCommandBuffer(self.handle, &begin_info);
    }

    pub fn end(self: CommandList) void {
        _ = c.vkEndCommandBuffer(self.handle);
    }

    pub fn draw(self: CommandList, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        c.vkCmdDraw(self.handle, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexed(self: CommandList, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void {
        c.vkCmdDrawIndexed(self.handle, index_count, instance_count, first_index, vertex_offset, first_instance);
    }

    pub fn dispatch(self: CommandList, x: u32, y: u32, z: u32) void {
        c.vkCmdDispatch(self.handle, x, y, z);
    }

    pub fn bindPipeline(self: CommandList, pipeline: Pipeline) void {
        c.vkCmdBindPipeline(self.handle, pipeline.bind_point, pipeline.handle);
    }

    pub fn bindVertexBuffer(self: CommandList, binding: u32, buffer: Buffer, offset: u64) void {
        var buffers = [_]c.VkBuffer{buffer.handle};
        var offsets = [_]c.VkDeviceSize{offset};
        c.vkCmdBindVertexBuffers(self.handle, binding, 1, &buffers, &offsets);
    }

    pub fn bindIndexBuffer(self: CommandList, buffer: Buffer, offset: u64, index_type: rhi.IndexType) void {
        c.vkCmdBindIndexBuffer(self.handle, buffer.handle, offset, toVkIndexType(index_type));
    }
};

pub const Device = struct {
    allocator: *renderer_types.VulkanAllocator,
    device: c.VkDevice,
    physical_device: c.VkPhysicalDevice,

    pub fn init(device: c.VkDevice, physical_device: c.VkPhysicalDevice, allocator: *renderer_types.VulkanAllocator) Device {
        return Device{
            .device = device,
            .physical_device = physical_device,
            .allocator = allocator,
        };
    }

    pub fn createBuffer(self: *Device, size: u64, usage: rhi.BufferUsage, memory_usage: rhi.MemoryUsage) !Buffer {
        var buffer_ci = std.mem.zeroes(c.VkBufferCreateInfo);
        buffer_ci.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        buffer_ci.size = size;
        buffer_ci.usage = toVkBufferUsage(usage);
        buffer_ci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        var buffer: c.VkBuffer = null;
        var memory: c.VkDeviceMemory = null;
        var allocation: c.VmaAllocation = null;

        const props = toVkMemoryPropertyFlags(memory_usage);

        if (!vk_allocator.vk_allocator_allocate_buffer(
            @ptrCast(self.allocator),
            &buffer_ci,
            &buffer,
            &memory,
            &allocation,
            props
        )) {
            return error.OutOfMemory;
        }

        return Buffer{
            .handle = buffer,
            .allocation = allocation,
            .memory = memory,
            .size = size,
        };
    }

    pub fn destroyBuffer(self: *Device, buffer: Buffer) void {
        vk_allocator.vk_allocator_free_buffer(@ptrCast(self.allocator), buffer.handle, buffer.allocation);
    }

    pub fn mapBuffer(self: *Device, buffer: *Buffer) !*anyopaque {
        if (buffer.mapped_ptr) |ptr| return ptr;
        
        var ptr: ?*anyopaque = null;
        const res = vk_allocator.vk_allocator_map_memory(@ptrCast(self.allocator), buffer.allocation, &ptr);
        if (res != c.VK_SUCCESS) return error.MapFailed;
        
        buffer.mapped_ptr = ptr;
        return ptr.?;
    }

    pub fn unmapBuffer(self: *Device, buffer: *Buffer) void {
        if (buffer.mapped_ptr == null) return;
        vk_allocator.vk_allocator_unmap_memory(@ptrCast(self.allocator), buffer.allocation);
        buffer.mapped_ptr = null;
    }

    pub fn createTexture(self: *Device, width: u32, height: u32, format: rhi.Format, usage: rhi.TextureUsage, memory_usage: rhi.MemoryUsage) !Texture {
        var image_ci = std.mem.zeroes(c.VkImageCreateInfo);
        image_ci.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_ci.imageType = c.VK_IMAGE_TYPE_2D;
        image_ci.extent.width = width;
        image_ci.extent.height = height;
        image_ci.extent.depth = 1;
        image_ci.mipLevels = 1;
        image_ci.arrayLayers = 1;
        image_ci.format = toVkFormat(format);
        image_ci.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_ci.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        image_ci.usage = toVkImageUsage(usage);
        image_ci.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_ci.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        var image: c.VkImage = null;
        var memory: c.VkDeviceMemory = null;
        var allocation: c.VmaAllocation = null;

        const props = toVkMemoryPropertyFlags(memory_usage);

        if (!vk_allocator.vk_allocator_allocate_image(
            @ptrCast(self.allocator),
            &image_ci,
            &image,
            &memory,
            &allocation,
            props
        )) {
            return error.OutOfMemory;
        }

        var view_ci = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_ci.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_ci.image = image;
        view_ci.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_ci.format = image_ci.format;
        view_ci.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        if (format == .D32_FLOAT) {
             view_ci.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        }
        view_ci.subresourceRange.baseMipLevel = 0;
        view_ci.subresourceRange.levelCount = 1;
        view_ci.subresourceRange.baseArrayLayer = 0;
        view_ci.subresourceRange.layerCount = 1;

        var view: c.VkImageView = null;
        if (c.vkCreateImageView(self.device, &view_ci, null, &view) != c.VK_SUCCESS) {
            vk_allocator.vk_allocator_free_image(@ptrCast(self.allocator), image, allocation);
            return error.ImageViewCreationFailed;
        }

        return Texture{
            .image = image,
            .view = view,
            .allocation = allocation,
            .memory = memory,
            .width = width,
            .height = height,
            .format = image_ci.format,
        };
    }

    pub fn destroyTexture(self: *Device, texture: Texture) void {
        c.vkDestroyImageView(self.device, texture.view, null);
        vk_allocator.vk_allocator_free_image(@ptrCast(self.allocator), texture.image, texture.allocation);
    }
};
