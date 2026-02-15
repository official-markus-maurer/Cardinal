const std = @import("std");
const builtin = @import("builtin");
const log = @import("../../core/log.zig");
const platform = @import("../../core/platform.zig");
const types = @import("../vulkan_types.zig");

const tex_utils_log = log.ScopedLogger("TEX_UTILS");

const buffer_mgr = @import("../vulkan_buffer_manager.zig");
const vk_sync_manager = @import("../vulkan_sync_manager.zig");
const vk_allocator = @import("../vulkan_allocator.zig");
const scene = @import("../../assets/scene.zig");

const c = @import("../vulkan_c.zig").c;

const StagingBufferCleanup = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    allocation: c.VmaAllocation,
    device: c.VkDevice,
    timeline_value: u64,
    next: ?*StagingBufferCleanup,
};

const ImageCleanup = struct {
    image: c.VkImage,
    allocation: c.VmaAllocation,
    timeline_value: u64,
    next: ?*ImageCleanup,
};

const CommandBufferCleanup = struct {
    commandBuffer: c.VkCommandBuffer,
    commandPool: c.VkCommandPool,
    device: c.VkDevice,
    timeline_value: u64,
    next: ?*CommandBufferCleanup,
};

var g_pending_cleanups: ?*StagingBufferCleanup = null;
var g_pending_image_cleanups: ?*ImageCleanup = null;
var g_pending_cmd_cleanups: ?*CommandBufferCleanup = null;
var g_cleanup_system_initialized: bool = false;
var g_is_shutting_down: bool = false;

pub fn add_staging_buffer_cleanup(allocator: ?*types.VulkanAllocator, buffer: c.VkBuffer, memory: c.VkDeviceMemory, allocation: c.VmaAllocation, device: c.VkDevice, timeline_value: u64) void {
    if (g_is_shutting_down) {
        tex_utils_log.debug("Immediate cleanup of staging buffer {any} due to shutdown", .{buffer});
        vk_allocator.free_buffer(allocator, buffer, allocation);
        return;
    }

    const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
    const mem_utils = @import("../../core/memory.zig");
    const cleanup = mem_utils.cardinal_alloc(mem_alloc, @sizeOf(StagingBufferCleanup));
    if (cleanup == null) {
        tex_utils_log.err("Failed to allocate cleanup tracking, immediate cleanup", .{});
        return;
    }

    const ptr = @as(*StagingBufferCleanup, @ptrCast(@alignCast(cleanup)));
    ptr.buffer = buffer;
    ptr.memory = memory;
    ptr.allocation = allocation;
    ptr.device = device;
    ptr.timeline_value = timeline_value;
    ptr.next = g_pending_cleanups;
    g_pending_cleanups = ptr;
    g_cleanup_system_initialized = true;

    tex_utils_log.debug("Added staging buffer {any} to deferred cleanup (timeline: {d})", .{ buffer, timeline_value });
}

pub fn add_image_cleanup(allocator: ?*types.VulkanAllocator, image: c.VkImage, allocation: c.VmaAllocation, timeline_value: u64) void {
    if (g_is_shutting_down) {
        tex_utils_log.debug("Immediate cleanup of image {any} due to shutdown", .{image});
        vk_allocator.free_image(allocator, image, allocation);
        return;
    }

    const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
    const mem_utils = @import("../../core/memory.zig");
    const cleanup = mem_utils.cardinal_alloc(mem_alloc, @sizeOf(ImageCleanup));
    if (cleanup == null) {
        tex_utils_log.err("Failed to allocate image cleanup tracking, immediate cleanup might leak if used", .{});
        return;
    }

    const ptr = @as(*ImageCleanup, @ptrCast(@alignCast(cleanup)));
    ptr.image = image;
    ptr.allocation = allocation;
    ptr.timeline_value = timeline_value;
    ptr.next = g_pending_image_cleanups;
    g_pending_image_cleanups = ptr;
    g_cleanup_system_initialized = true;

    tex_utils_log.debug("Added image {any} to deferred cleanup (timeline: {d})", .{ image, timeline_value });
}

pub fn process_staging_buffer_cleanups(sync_manager: ?*types.VulkanSyncManager, allocator: ?*types.VulkanAllocator) void {
    if (!g_cleanup_system_initialized or sync_manager == null or allocator == null) return;

    // Process staging buffers
    var current = &g_pending_cleanups;
    while (current.*) |cleanup| {
        var reached: bool = false;
        if (vk_sync_manager.vulkan_sync_manager_is_timeline_value_reached(@ptrCast(sync_manager), cleanup.timeline_value, &reached) == c.VK_SUCCESS and reached) {
            tex_utils_log.debug("Cleaning up completed staging buffer {any} (timeline: {d})", .{ cleanup.buffer, cleanup.timeline_value });

            vk_allocator.free_buffer(allocator, cleanup.buffer, cleanup.allocation);

            current.* = cleanup.next;

            const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
            const mem_utils = @import("../../core/memory.zig");
            mem_utils.cardinal_free(mem_alloc, cleanup);
        } else {
            current = &cleanup.next;
        }
    }

    // Process images
    var current_img = &g_pending_image_cleanups;
    while (current_img.*) |cleanup| {
        var reached: bool = false;
        if (vk_sync_manager.vulkan_sync_manager_is_timeline_value_reached(@ptrCast(sync_manager), cleanup.timeline_value, &reached) == c.VK_SUCCESS and reached) {
            tex_utils_log.debug("Cleaning up completed image {any} (timeline: {d})", .{ cleanup.image, cleanup.timeline_value });

            vk_allocator.free_image(allocator, cleanup.image, cleanup.allocation);

            current_img.* = cleanup.next;

            const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
            const mem_utils = @import("../../core/memory.zig");
            mem_utils.cardinal_free(mem_alloc, cleanup);
        } else {
            current_img = &cleanup.next;
        }
    }

    // Process command buffers
    var current_cmd = &g_pending_cmd_cleanups;
    while (current_cmd.*) |cleanup| {
        var reached: bool = false;
        if (vk_sync_manager.vulkan_sync_manager_is_timeline_value_reached(@ptrCast(sync_manager), cleanup.timeline_value, &reached) == c.VK_SUCCESS and reached) {
            tex_utils_log.debug("Cleaning up completed command buffer {any} (timeline: {d})", .{ cleanup.commandBuffer, cleanup.timeline_value });

            var cmd_buf = cleanup.commandBuffer;
            c.vkFreeCommandBuffers(cleanup.device, cleanup.commandPool, 1, &cmd_buf);

            current_cmd.* = cleanup.next;

            const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
            const mem_utils = @import("../../core/memory.zig");
            mem_utils.cardinal_free(mem_alloc, cleanup);
        } else {
            current_cmd = &cleanup.next;
        }
    }
}

pub fn add_command_buffer_cleanup(commandBuffer: c.VkCommandBuffer, commandPool: c.VkCommandPool, device: c.VkDevice, timeline_value: u64) void {
    if (g_is_shutting_down) {
        tex_utils_log.debug("Immediate cleanup of command buffer {any} due to shutdown", .{commandBuffer});
        var cmd_buf = commandBuffer;
        c.vkFreeCommandBuffers(device, commandPool, 1, &cmd_buf);
        return;
    }

    const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
    const mem_utils = @import("../../core/memory.zig");
    const cleanup = mem_utils.cardinal_alloc(mem_alloc, @sizeOf(CommandBufferCleanup));
    if (cleanup == null) {
        tex_utils_log.err("Failed to allocate command buffer cleanup tracking, immediate cleanup might leak if used", .{});
        return;
    }

    const ptr = @as(*CommandBufferCleanup, @ptrCast(@alignCast(cleanup)));
    ptr.commandBuffer = commandBuffer;
    ptr.commandPool = commandPool;
    ptr.device = device;
    ptr.timeline_value = timeline_value;
    ptr.next = g_pending_cmd_cleanups;
    g_pending_cmd_cleanups = ptr;
    g_cleanup_system_initialized = true;

    tex_utils_log.debug("Added command buffer {any} to deferred cleanup (timeline: {d})", .{ commandBuffer, timeline_value });
}

pub fn shutdown_staging_buffer_cleanups(allocator: *types.VulkanAllocator) void {
    g_is_shutting_down = true;
    if (!g_cleanup_system_initialized) return;

    var current = g_pending_cleanups;
    while (current) |cleanup| {
        const next = cleanup.next;
        tex_utils_log.debug("Force cleaning up staging buffer {any} on shutdown", .{cleanup.buffer});
        vk_allocator.free_buffer(allocator, cleanup.buffer, cleanup.allocation);

        const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
        const mem_utils = @import("../../core/memory.zig");
        mem_utils.cardinal_free(mem_alloc, cleanup);

        current = next;
    }
    g_pending_cleanups = null;

    var current_img = g_pending_image_cleanups;
    while (current_img) |cleanup| {
        const next = cleanup.next;
        tex_utils_log.debug("Force cleaning up image {any} on shutdown", .{cleanup.image});
        vk_allocator.free_image(allocator, cleanup.image, cleanup.allocation);

        const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
        const mem_utils = @import("../../core/memory.zig");
        mem_utils.cardinal_free(mem_alloc, cleanup);

        current_img = next;
    }
    g_pending_image_cleanups = null;

    var current_cmd = g_pending_cmd_cleanups;
    while (current_cmd) |cleanup| {
        const next = cleanup.next;
        tex_utils_log.debug("Force cleaning up command buffer {any} on shutdown", .{cleanup.commandBuffer});
        var cmd_buf = cleanup.commandBuffer;
        c.vkFreeCommandBuffers(cleanup.device, cleanup.commandPool, 1, &cmd_buf);

        const mem_alloc = @import("../../core/memory.zig").cardinal_get_allocator_for_category(.RENDERER);
        const mem_utils = @import("../../core/memory.zig");
        mem_utils.cardinal_free(mem_alloc, cleanup);

        current_cmd = next;
    }
    g_pending_cmd_cleanups = null;

    g_cleanup_system_initialized = false;
}

pub fn create_staging_buffer_with_data(allocator: ?*types.VulkanAllocator, device: c.VkDevice, texture: *const scene.CardinalTexture, outBuffer: *c.VkBuffer, outMemory: *c.VkDeviceMemory, outAllocation: *c.VmaAllocation) bool {
    _ = device; // unused if using VMA

    var imageSize: c.VkDeviceSize = 0;
    if (texture.data_size > 0) {
        imageSize = texture.data_size;
    } else {
        const pixel_size: u64 = if (texture.is_hdr != 0) 16 else 4;
        imageSize = @as(c.VkDeviceSize, texture.width) * texture.height * pixel_size;
    }

    // Ensure imageSize is at least 4 bytes to avoid validation errors for tiny/empty textures
    if (imageSize < 4) imageSize = 4;

    // Validation: Check if imageSize is sufficient for the texture dimensions
    // Note: Compressed textures (BC1-BC5) are much smaller than uncompressed (R8G8B8A8).
    // If data_size was provided explicitly (e.g. from DDS loader), we trust it.
    // We only enforce the W*H*4 size check if we calculated the size ourselves (data_size == 0) OR if the format implies uncompressed data.

    if (texture.data_size == 0) {
        const pixel_size_check: u64 = if (texture.is_hdr != 0) 16 else 4;
        const required_size = @as(c.VkDeviceSize, texture.width) * texture.height * pixel_size_check;
        if (imageSize < required_size) {
            tex_utils_log.warn("Staging buffer size {d} is smaller than required {d} for {d}x{d} texture. Adjusting.", .{ imageSize, required_size, texture.width, texture.height });
            imageSize = required_size;
        }
    } else {
        // Data size provided explicitly.
        // If it's absurdly small (e.g. 4 bytes for 512x512), we should probably warn, but respecting the loader's decision is usually safer for compressed formats.
        // However, if we get the "size 4" issue, we need to know why.
        if (texture.width > 4 and imageSize <= 4) {
            tex_utils_log.warn("Staging buffer size is extremely small ({d}) for {d}x{d} texture. Format: {d}. This might be a placeholder or corrupted data.", .{ imageSize, texture.width, texture.height, texture.format });
            // Force adjust if it looks like a placeholder mismatch
            const safe_min = @as(c.VkDeviceSize, texture.width) * texture.height / 2; // Rough lower bound for high compression
            if (imageSize < safe_min) {
                tex_utils_log.warn("Adjusting buffer size to {d} to prevent crash.", .{safe_min});
                imageSize = safe_min;
            }
        }
    }

    var bufferInfo = std.mem.zeroes(c.VkBufferCreateInfo);
    bufferInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = imageSize;
    bufferInfo.usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    bufferInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    // Use VMA to allocate buffer
    if (!vk_allocator.allocate_buffer(allocator, &bufferInfo, outBuffer, outMemory, outAllocation, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, false, null)) {
        tex_utils_log.err("Failed to create staging buffer with VMA", .{});
        return false;
    }

    var data: ?*anyopaque = null;
    if (vk_allocator.map_memory(allocator, outAllocation.*, &data) != c.VK_SUCCESS) {
        tex_utils_log.err("Failed to map staging buffer memory", .{});
        vk_allocator.free_buffer(allocator, outBuffer.*, outAllocation.*);
        return false;
    }

    const src_data = @as([*]const u8, @ptrCast(texture.data));
    @memcpy(@as([*]u8, @ptrCast(data.?))[0..imageSize], src_data[0..imageSize]);

    vk_allocator.unmap_memory(allocator, outAllocation.*);
    return true;
}

pub fn create_image_and_memory(allocator: ?*types.VulkanAllocator, device: c.VkDevice, width: u32, height: u32, format: c.VkFormat, outImage: *c.VkImage, outMemory: *c.VkDeviceMemory, outAllocation: *c.VmaAllocation) bool {
    _ = device;
    var imageInfo = std.mem.zeroes(c.VkImageCreateInfo);
    imageInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = c.VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = width;
    imageInfo.extent.height = height;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = format;
    if (imageInfo.format == c.VK_FORMAT_UNDEFINED) {
        // Fallback or guess
        // We can't access texture.is_hdr here easily unless we pass it or check format family
        // But the caller usually passes a valid format.
        // If caller passed UNDEFINED, we might have a problem.
        tex_utils_log.warn("create_image_and_memory received VK_FORMAT_UNDEFINED", .{});
        imageInfo.format = c.VK_FORMAT_R8G8B8A8_SRGB;
    }
    imageInfo.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    imageInfo.samples = c.VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    // const vk_allocator = @import("../vulkan_allocator.zig");
    if (!vk_allocator.allocate_image(allocator, &imageInfo, outImage, outMemory, outAllocation, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
        tex_utils_log.err("Failed to allocate texture image with VMA", .{});
        return false;
    }

    return true;
}

pub fn record_texture_copy_commands(commandBuffer: c.VkCommandBuffer, stagingBuffer: c.VkBuffer, textureImage: c.VkImage, width: u32, height: u32) void {
    // The command buffer must be in recording state before calling this function.

    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
    barrier.srcAccessMask = 0;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = textureImage;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;

    var dependencyInfo = std.mem.zeroes(c.VkDependencyInfo);
    dependencyInfo.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dependencyInfo.imageMemoryBarrierCount = 1;
    dependencyInfo.pImageMemoryBarriers = &barrier;

    const thread_id = platform.get_current_thread_id();
    const vk_barrier_validation = @import("../vulkan_barrier_validation.zig");

    // ...

    if (!vk_barrier_validation.cardinal_barrier_validation_validate_pipeline_barrier(&dependencyInfo, commandBuffer, thread_id)) {
        tex_utils_log.warn("Pipeline barrier validation failed during texture upload", .{});
    }

    c.vkCmdPipelineBarrier2(commandBuffer, &dependencyInfo);

    var region = std.mem.zeroes(c.VkBufferImageCopy);
    region.bufferOffset = 0;
    region.bufferRowLength = 0;
    region.bufferImageHeight = 0;
    region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel = 0;
    region.imageSubresource.baseArrayLayer = 0;
    region.imageSubresource.layerCount = 1;
    region.imageOffset = .{ .x = 0, .y = 0, .z = 0 };
    region.imageExtent = .{ .width = width, .height = height, .depth = 1 };

    c.vkCmdCopyBufferToImage(commandBuffer, stagingBuffer, textureImage, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier.srcAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_SHADER_READ_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    if (!vk_barrier_validation.cardinal_barrier_validation_validate_pipeline_barrier(&dependencyInfo, commandBuffer, thread_id)) {
        tex_utils_log.warn("Pipeline barrier validation failed for texture shader read transition", .{});
    }

    c.vkCmdPipelineBarrier2(commandBuffer, &dependencyInfo);
    // _ = c.vkEndCommandBuffer(commandBuffer); // Removed
}

fn submit_texture_upload(device: c.VkDevice, graphicsQueue: c.VkQueue, commandBuffer: c.VkCommandBuffer, sync_manager: ?*types.VulkanSyncManager, outTimelineValue: ?*u64) bool {
    var cmdBufSubmitInfo = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
    cmdBufSubmitInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    cmdBufSubmitInfo.commandBuffer = commandBuffer;

    var submitInfo = std.mem.zeroes(c.VkSubmitInfo2);
    submitInfo.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    submitInfo.commandBufferInfoCount = 1;
    submitInfo.pCommandBufferInfos = &cmdBufSubmitInfo;

    if (sync_manager) |sync| {
        const timeline_value = vk_sync_manager.vulkan_sync_manager_get_next_timeline_value(@ptrCast(sync));
        if (outTimelineValue) |out| out.* = timeline_value;

        var signal_info = std.mem.zeroes(c.VkSemaphoreSubmitInfo);
        signal_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
        signal_info.semaphore = sync.timeline_semaphore;
        signal_info.value = timeline_value;
        signal_info.stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;

        submitInfo.signalSemaphoreInfoCount = 1;
        submitInfo.pSignalSemaphoreInfos = &signal_info;

        var uploadFence: c.VkFence = null;
        var fenceInfo = std.mem.zeroes(c.VkFenceCreateInfo);
        fenceInfo.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        if (c.vkCreateFence(device, &fenceInfo, null, &uploadFence) != c.VK_SUCCESS) {
            return false;
        }

        // Use synchronized submit
        if (vk_sync_manager.vulkan_sync_manager_submit_queue2(graphicsQueue, 1, @ptrCast(&submitInfo), uploadFence, null) != c.VK_SUCCESS) {
            c.vkDestroyFence(device, uploadFence, null);
            return false;
        }

        if (c.vkWaitForFences(device, 1, &uploadFence, c.VK_TRUE, 5000000000) != c.VK_SUCCESS) {
            tex_utils_log.err("Texture upload fence wait failed or timed out", .{});
        }
        c.vkDestroyFence(device, uploadFence, null);

        var waitInfo = std.mem.zeroes(c.VkSemaphoreWaitInfo);
        waitInfo.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
        waitInfo.semaphoreCount = 1;
        waitInfo.pSemaphores = &sync.timeline_semaphore;
        waitInfo.pValues = &timeline_value;
        _ = c.vkWaitSemaphores(device, &waitInfo, c.UINT64_MAX);
    } else {
        // Use synchronized submit
        if (vk_sync_manager.vulkan_sync_manager_submit_queue2(graphicsQueue, 1, @ptrCast(&submitInfo), null, null) != c.VK_SUCCESS) {
            return false;
        }
        _ = c.vkQueueWaitIdle(graphicsQueue);
    }
    return true;
}

pub fn create_texture_image_view(device: c.VkDevice, image: c.VkImage, outView: *c.VkImageView, format: c.VkFormat) bool {
    var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
    viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = image;
    viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = format;
    if (viewInfo.format == c.VK_FORMAT_UNDEFINED) {
        viewInfo.format = c.VK_FORMAT_R8G8B8A8_SRGB;
    }
    viewInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;

    if (c.vkCreateImageView(device, &viewInfo, null, outView) != c.VK_SUCCESS) {
        tex_utils_log.err("Failed to create texture image view", .{});
        return false;
    }
    return true;
}

pub export fn vk_texture_create_from_data(allocator: ?*types.VulkanAllocator, device: c.VkDevice, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, sync_manager: ?*types.VulkanSyncManager, texture: ?*const scene.CardinalTexture, textureImage: ?*c.VkImage, textureImageMemory: ?*c.VkDeviceMemory, textureImageView: ?*c.VkImageView, outTimelineValue: ?*u64, textureAllocation: ?*c.VmaAllocation) callconv(.c) bool {
    if (texture == null or texture.?.data == null or textureImage == null or textureImageMemory == null or textureImageView == null or textureAllocation == null) {
        tex_utils_log.err("Invalid parameters for texture creation", .{});
        return false;
    }

    var stagingBuffer: c.VkBuffer = null;
    var stagingBufferMemory: c.VkDeviceMemory = null;
    var stagingBufferAllocation: c.VmaAllocation = null;
    if (!create_staging_buffer_with_data(allocator, device, @ptrCast(texture.?), &stagingBuffer, &stagingBufferMemory, &stagingBufferAllocation)) {
        return false;
    }

    var format: c.VkFormat = if (texture.?.format != 0) @intCast(texture.?.format) else c.VK_FORMAT_UNDEFINED;
    if (format == c.VK_FORMAT_UNDEFINED) {
        if (texture == null) {
            // Fallback for null texture pointer
            format = c.VK_FORMAT_R8G8B8A8_SRGB;
        } else {
            format = if (texture.?.is_hdr != 0) c.VK_FORMAT_R32G32B32A32_SFLOAT else c.VK_FORMAT_R8G8B8A8_SRGB;
        }
    }

    if (!create_image_and_memory(allocator, device, texture.?.width, texture.?.height, format, textureImage.?, textureImageMemory.?, textureAllocation.?)) {
        vk_allocator.free_buffer(allocator, stagingBuffer, stagingBufferAllocation);
        return false;
    }

    var allocInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandPool = commandPool;
    allocInfo.commandBufferCount = 1;

    var commandBuffer: c.VkCommandBuffer = null;
    _ = c.vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);

    var beginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    beginInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    _ = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);

    record_texture_copy_commands(commandBuffer, stagingBuffer, textureImage.?.*, texture.?.width, texture.?.height);

    _ = c.vkEndCommandBuffer(commandBuffer);

    if (!submit_texture_upload(device, graphicsQueue, commandBuffer, sync_manager, outTimelineValue)) {
        tex_utils_log.err("Failed to submit texture upload", .{});
        c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        vk_allocator.free_buffer(allocator, stagingBuffer, stagingBufferAllocation);
        vk_allocator.free_image(allocator, textureImage.?.*, textureAllocation.?.*);
        return false;
    }

    c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);

    if (sync_manager != null and outTimelineValue != null) {
        add_staging_buffer_cleanup(allocator, stagingBuffer, stagingBufferMemory, stagingBufferAllocation, device, outTimelineValue.?.*);
        process_staging_buffer_cleanups(sync_manager, allocator);
    } else {
        vk_allocator.free_buffer(allocator, stagingBuffer, stagingBufferAllocation);
    }

    if (!create_texture_image_view(device, textureImage.?.*, textureImageView.?, format)) {
        // const vk_allocator = @import("../vulkan_allocator.zig");
        vk_allocator.free_image(allocator, textureImage.?.*, textureAllocation.?.*);
        return false;
    }

    return true;
}

pub fn transition_image_layout(device: c.VkDevice, graphicsQueue: c.VkQueue, commandPool: c.VkCommandPool, image: c.VkImage, format: c.VkFormat, oldLayout: c.VkImageLayout, newLayout: c.VkImageLayout) void {
    _ = format;

    var commandBuffer: c.VkCommandBuffer = null;

    var allocInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandPool = commandPool;
    allocInfo.commandBufferCount = 1;

    _ = c.vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);

    var beginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    beginInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    _ = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);

    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.oldLayout = oldLayout;
    barrier.newLayout = newLayout;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;

    var srcStageMask: c.VkPipelineStageFlags2 = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
    var dstStageMask: c.VkPipelineStageFlags2 = c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT;

    if (oldLayout == c.VK_IMAGE_LAYOUT_UNDEFINED) {
        barrier.srcAccessMask = 0;
        srcStageMask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
    } else if (oldLayout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
        barrier.srcAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
        srcStageMask = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    } else if (oldLayout == c.VK_IMAGE_LAYOUT_GENERAL) {
        barrier.srcAccessMask = c.VK_ACCESS_2_SHADER_WRITE_BIT;
        srcStageMask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    }

    if (newLayout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
        barrier.dstAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT;
        dstStageMask = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    } else if (newLayout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
        barrier.dstAccessMask = c.VK_ACCESS_2_SHADER_READ_BIT;
        dstStageMask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    } else if (newLayout == c.VK_IMAGE_LAYOUT_GENERAL) {
        barrier.dstAccessMask = c.VK_ACCESS_2_SHADER_READ_BIT | c.VK_ACCESS_2_SHADER_WRITE_BIT;
        dstStageMask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    }

    barrier.srcStageMask = srcStageMask;
    barrier.dstStageMask = dstStageMask;

    var depInfo = std.mem.zeroes(c.VkDependencyInfo);
    depInfo.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    depInfo.imageMemoryBarrierCount = 1;
    depInfo.pImageMemoryBarriers = &barrier;

    c.vkCmdPipelineBarrier2(commandBuffer, &depInfo);

    _ = c.vkEndCommandBuffer(commandBuffer);

    var cmdBufferInfo = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
    cmdBufferInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    cmdBufferInfo.commandBuffer = commandBuffer;

    var submitInfo = std.mem.zeroes(c.VkSubmitInfo2);
    submitInfo.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    submitInfo.commandBufferInfoCount = 1;
    submitInfo.pCommandBufferInfos = &cmdBufferInfo;

    _ = c.vkQueueSubmit2(graphicsQueue, 1, &submitInfo, null);
    _ = c.vkQueueWaitIdle(graphicsQueue);

    c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
}

pub export fn vk_texture_create_placeholder(allocator: ?*types.VulkanAllocator, device: c.VkDevice, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, textureImage: ?*c.VkImage, textureImageMemory: ?*c.VkDeviceMemory, textureImageView: ?*c.VkImageView, format: ?*c.VkFormat, textureAllocation: ?*c.VmaAllocation) callconv(.c) bool {
    if (format) |fmt| {
        fmt.* = c.VK_FORMAT_R8G8B8A8_SRGB;
    }
    // Magenta placeholder (R=255, G=0, B=255, A=255)
    var magentaPixel = [_]u8{ 255, 0, 255, 255 };
    var placeholderTexture = std.mem.zeroes(scene.CardinalTexture);
    placeholderTexture.data = &magentaPixel;
    placeholderTexture.width = 1;
    placeholderTexture.height = 1;
    placeholderTexture.channels = 4;
    placeholderTexture.path = @as([*c]u8, @constCast("placeholder"));

    return vk_texture_create_from_data(allocator, device, commandPool, graphicsQueue, null, @ptrCast(&placeholderTexture), textureImage, textureImageMemory, textureImageView, null, textureAllocation);
}

pub fn copy_buffer_to_image(device: c.VkDevice, graphicsQueue: c.VkQueue, commandPool: c.VkCommandPool, buffer: c.VkBuffer, image: c.VkImage, width: u32, height: u32) void {
    var commandBuffer: c.VkCommandBuffer = null;

    var allocInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandPool = commandPool;
    allocInfo.commandBufferCount = 1;

    _ = c.vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);

    var beginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    beginInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    _ = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);

    var region = std.mem.zeroes(c.VkBufferImageCopy);
    region.bufferOffset = 0;
    region.bufferRowLength = 0;
    region.bufferImageHeight = 0;
    region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel = 0;
    region.imageSubresource.baseArrayLayer = 0;
    region.imageSubresource.layerCount = 1;
    region.imageOffset = .{ .x = 0, .y = 0, .z = 0 };
    region.imageExtent = .{ .width = width, .height = height, .depth = 1 };

    c.vkCmdCopyBufferToImage(commandBuffer, buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    _ = c.vkEndCommandBuffer(commandBuffer);

    var cmdBufferInfo = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
    cmdBufferInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    cmdBufferInfo.commandBuffer = commandBuffer;

    var submitInfo = std.mem.zeroes(c.VkSubmitInfo2);
    submitInfo.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    submitInfo.commandBufferInfoCount = 1;
    submitInfo.pCommandBufferInfos = &cmdBufferInfo;

    _ = c.vkQueueSubmit2(graphicsQueue, 1, &submitInfo, null);
    _ = c.vkQueueWaitIdle(graphicsQueue);

    c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
}

pub export fn vk_texture_create_sampler(device: c.VkDevice, physicalDevice: c.VkPhysicalDevice, sampler: ?*c.VkSampler) callconv(.c) bool {
    var properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(physicalDevice, &properties);

    var samplerInfo = std.mem.zeroes(c.VkSamplerCreateInfo);
    samplerInfo.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = c.VK_FILTER_LINEAR;
    samplerInfo.minFilter = c.VK_FILTER_LINEAR;
    samplerInfo.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.anisotropyEnable = c.VK_TRUE;
    samplerInfo.maxAnisotropy = properties.limits.maxSamplerAnisotropy;
    samplerInfo.borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    samplerInfo.unnormalizedCoordinates = c.VK_FALSE;
    samplerInfo.compareEnable = c.VK_FALSE;
    samplerInfo.compareOp = c.VK_COMPARE_OP_ALWAYS;
    samplerInfo.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
    samplerInfo.mipLodBias = 0.0;
    samplerInfo.minLod = 0.0;
    samplerInfo.maxLod = 0.0;

    if (c.vkCreateSampler(device, &samplerInfo, null, sampler) != c.VK_SUCCESS) {
        tex_utils_log.err("Failed to create texture sampler", .{});
        return false;
    }

    return true;
}
