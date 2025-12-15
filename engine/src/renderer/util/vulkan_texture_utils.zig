const std = @import("std");
const log = @import("../../core/log.zig");
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("vulkan_state.h");
    @cInclude("vulkan_buffer_manager.h");
    @cInclude("cardinal/renderer/util/vulkan_buffer_utils.h");
    @cInclude("cardinal/renderer/util/vulkan_texture_utils.h");
    @cInclude("cardinal/renderer/vulkan_barrier_validation.h");
    @cInclude("cardinal/renderer/vulkan_sync_manager.h");
    @cInclude("vulkan_context_struct.h");
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
    } else {
        @cInclude("unistd.h");
        @cInclude("sys/syscall.h");
    }
});

const StagingBufferCleanup = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    device: c.VkDevice,
    timeline_value: u64,
    next: ?*StagingBufferCleanup,
};

var g_pending_cleanups: ?*StagingBufferCleanup = null;
var g_cleanup_system_initialized: bool = false;

fn get_current_thread_id() u32 {
    if (builtin.os.tag == .windows) {
        return c.GetCurrentThreadId();
    } else {
        return @intCast(c.syscall(c.SYS_gettid));
    }
}

fn add_staging_buffer_cleanup(buffer: c.VkBuffer, memory: c.VkDeviceMemory, device: c.VkDevice, timeline_value: u64) void {
    const cleanup = c.malloc(@sizeOf(StagingBufferCleanup));
    if (cleanup == null) {
        log.cardinal_log_error("[TEXTURE_UTILS] Failed to allocate cleanup tracking, immediate cleanup", .{});
        c.vkDestroyBuffer(device, buffer, null);
        c.vkFreeMemory(device, memory, null);
        return;
    }
    
    const ptr = @as(*StagingBufferCleanup, @ptrCast(@alignCast(cleanup)));
    ptr.buffer = buffer;
    ptr.memory = memory;
    ptr.device = device;
    ptr.timeline_value = timeline_value;
    ptr.next = g_pending_cleanups;
    g_pending_cleanups = ptr;
    g_cleanup_system_initialized = true;

    log.cardinal_log_debug("[TEXTURE_UTILS] Added staging buffer {any} to deferred cleanup (timeline: {d})", .{buffer, timeline_value});
}

fn process_staging_buffer_cleanups(sync_manager: ?*c.VulkanSyncManager) void {
    if (!g_cleanup_system_initialized or sync_manager == null) return;

    var current = &g_pending_cleanups;
    while (current.*) |cleanup| {
        var reached: bool = false;
        if (c.vulkan_sync_manager_is_timeline_value_reached(sync_manager, cleanup.timeline_value, &reached) == c.VK_SUCCESS and reached) {
            log.cardinal_log_debug("[TEXTURE_UTILS] Cleaning up completed staging buffer {any} (timeline: {d})", .{cleanup.buffer, cleanup.timeline_value});
            
            c.vkDestroyBuffer(cleanup.device, cleanup.buffer, null);
            c.vkFreeMemory(cleanup.device, cleanup.memory, null);

            current.* = cleanup.next;
            c.free(cleanup);
        } else {
            current = &cleanup.next;
        }
    }
}

fn create_staging_buffer_with_data(allocator: ?*c.VulkanAllocator, device: c.VkDevice, texture: *const c.CardinalTexture, outStagingBuffer: *c.VkBuffer, outStagingMemory: *c.VkDeviceMemory) bool {
    const imageSize: c.VkDeviceSize = texture.width * texture.height * 4; // Always RGBA

    var stagingBufferObj = std.mem.zeroes(c.VulkanBuffer);
    var stagingCreateInfo = std.mem.zeroes(c.VulkanBufferCreateInfo);
    stagingCreateInfo.size = imageSize;
    stagingCreateInfo.usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    stagingCreateInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    stagingCreateInfo.persistentlyMapped = true;

    if (!c.vk_buffer_create(&stagingBufferObj, device, allocator, &stagingCreateInfo)) {
        log.cardinal_log_error("Failed to create staging buffer for texture", .{});
        return false;
    }

    outStagingBuffer.* = stagingBufferObj.handle;
    outStagingMemory.* = stagingBufferObj.memory;
    const data = stagingBufferObj.mapped;

    if (texture.channels == 4) {
        @memcpy(@as([*]u8, @ptrCast(data))[0..imageSize], @as([*]const u8, @ptrCast(texture.data))[0..imageSize]);
    } else if (texture.channels == 3) {
        const src = @as([*]const u8, @ptrCast(texture.data));
        const dst = @as([*]u8, @ptrCast(data));
        var i: u32 = 0;
        while (i < texture.width * texture.height) : (i += 1) {
            dst[i * 4 + 0] = src[i * 3 + 0];
            dst[i * 4 + 1] = src[i * 3 + 1];
            dst[i * 4 + 2] = src[i * 3 + 2];
            dst[i * 4 + 3] = 255;
        }
    } else {
        log.cardinal_log_error("Unsupported texture channel count: {d}", .{texture.channels});
        c.vkDestroyBuffer(device, outStagingBuffer.*, null);
        c.vkFreeMemory(device, outStagingMemory.*, null);
        return false;
    }

    return true;
}

fn create_image_and_memory(allocator: ?*c.VulkanAllocator, device: c.VkDevice, width: u32, height: u32, outImage: *c.VkImage, outMemory: *c.VkDeviceMemory) bool {
    var imageInfo = std.mem.zeroes(c.VkImageCreateInfo);
    imageInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = c.VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = width;
    imageInfo.extent.height = height;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = c.VK_FORMAT_R8G8B8A8_SRGB;
    imageInfo.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    imageInfo.samples = c.VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    if (c.vkCreateImage(device, &imageInfo, null, outImage) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create texture image", .{});
        return false;
    }

    var memRequirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(device, outImage.*, &memRequirements);

    var allocInfo = std.mem.zeroes(c.VkMemoryAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocInfo.allocationSize = memRequirements.size;
    allocInfo.memoryTypeIndex = c.vk_buffer_find_memory_type(allocator.?.physical_device, memRequirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

    if (c.vkAllocateMemory(device, &allocInfo, null, outMemory) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to allocate texture image memory", .{});
        c.vkDestroyImage(device, outImage.*, null);
        return false;
    }

    _ = c.vkBindImageMemory(device, outImage.*, outMemory.*, 0);
    return true;
}

fn record_texture_copy_commands(commandBuffer: c.VkCommandBuffer, stagingBuffer: c.VkBuffer, textureImage: c.VkImage, width: u32, height: u32) void {
    var beginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    beginInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    _ = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);

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

    const thread_id = get_current_thread_id();
    if (!c.cardinal_barrier_validation_validate_pipeline_barrier(&dependencyInfo, commandBuffer, thread_id)) {
        log.cardinal_log_warn("Pipeline barrier validation failed for texture transfer transition", .{});
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

    if (!c.cardinal_barrier_validation_validate_pipeline_barrier(&dependencyInfo, commandBuffer, thread_id)) {
        log.cardinal_log_warn("Pipeline barrier validation failed for texture shader read transition", .{});
    }

    c.vkCmdPipelineBarrier2(commandBuffer, &dependencyInfo);
    _ = c.vkEndCommandBuffer(commandBuffer);
}

fn submit_texture_upload(device: c.VkDevice, graphicsQueue: c.VkQueue, commandBuffer: c.VkCommandBuffer, sync_manager: ?*c.VulkanSyncManager, outTimelineValue: ?*u64) bool {
    var cmdBufSubmitInfo = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
    cmdBufSubmitInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    cmdBufSubmitInfo.commandBuffer = commandBuffer;

    var submitInfo = std.mem.zeroes(c.VkSubmitInfo2);
    submitInfo.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    submitInfo.commandBufferInfoCount = 1;
    submitInfo.pCommandBufferInfos = &cmdBufSubmitInfo;

    if (sync_manager) |sync| {
        const timeline_value = c.vulkan_sync_manager_get_next_timeline_value(sync);
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

        if (c.vkQueueSubmit2(graphicsQueue, 1, &submitInfo, uploadFence) != c.VK_SUCCESS) {
            c.vkDestroyFence(device, uploadFence, null);
            return false;
        }

        if (c.vkWaitForFences(device, 1, &uploadFence, c.VK_TRUE, 5000000000) != c.VK_SUCCESS) {
            log.cardinal_log_error("Texture upload fence wait failed or timed out", .{});
        }
        c.vkDestroyFence(device, uploadFence, null);

        var waitInfo = std.mem.zeroes(c.VkSemaphoreWaitInfo);
        waitInfo.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
        waitInfo.semaphoreCount = 1;
        waitInfo.pSemaphores = &sync.timeline_semaphore;
        waitInfo.pValues = &timeline_value;
        _ = c.vkWaitSemaphores(device, &waitInfo, c.UINT64_MAX);
    } else {
        if (c.vkQueueSubmit2(graphicsQueue, 1, &submitInfo, null) != c.VK_SUCCESS) {
            return false;
        }
        _ = c.vkQueueWaitIdle(graphicsQueue);
    }
    return true;
}

fn create_texture_image_view(device: c.VkDevice, image: c.VkImage, outImageView: *c.VkImageView) bool {
    var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
    viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = image;
    viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = c.VK_FORMAT_R8G8B8A8_SRGB;
    viewInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;

    if (c.vkCreateImageView(device, &viewInfo, null, outImageView) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create texture image view", .{});
        return false;
    }
    return true;
}

pub export fn vk_texture_create_from_data(allocator: ?*c.VulkanAllocator, device: c.VkDevice,
                                          commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue,
                                          sync_manager: ?*c.VulkanSyncManager, texture: ?*const c.CardinalTexture,
                                          textureImage: ?*c.VkImage, textureImageMemory: ?*c.VkDeviceMemory,
                                          textureImageView: ?*c.VkImageView, outTimelineValue: ?*u64) callconv(.c) bool {
    if (texture == null or texture.?.data == null or textureImage == null or textureImageMemory == null or textureImageView == null) {
        log.cardinal_log_error("Invalid parameters for texture creation", .{});
        return false;
    }

    var stagingBuffer: c.VkBuffer = null;
    var stagingBufferMemory: c.VkDeviceMemory = null;
    if (!create_staging_buffer_with_data(allocator, device, texture.?, &stagingBuffer, &stagingBufferMemory)) {
        return false;
    }

    if (!create_image_and_memory(allocator, device, texture.?.width, texture.?.height, textureImage.?, textureImageMemory.?)) {
        c.vkDestroyBuffer(device, stagingBuffer, null);
        c.vkFreeMemory(device, stagingBufferMemory, null);
        return false;
    }

    var allocInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandPool = commandPool;
    allocInfo.commandBufferCount = 1;

    var commandBuffer: c.VkCommandBuffer = null;
    _ = c.vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);

    record_texture_copy_commands(commandBuffer, stagingBuffer, textureImage.?.*, texture.?.width, texture.?.height);

    if (!submit_texture_upload(device, graphicsQueue, commandBuffer, sync_manager, outTimelineValue)) {
        log.cardinal_log_error("Failed to submit texture upload", .{});
        c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        c.vkDestroyBuffer(device, stagingBuffer, null);
        c.vkFreeMemory(device, stagingBufferMemory, null);
        c.vkDestroyImage(device, textureImage.?.*, null);
        c.vkFreeMemory(device, textureImageMemory.?.*, null);
        return false;
    }

    c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);

    if (sync_manager != null and outTimelineValue != null) {
        add_staging_buffer_cleanup(stagingBuffer, stagingBufferMemory, device, outTimelineValue.?.*);
        process_staging_buffer_cleanups(sync_manager);
    } else {
        c.vkDestroyBuffer(device, stagingBuffer, null);
        c.vkFreeMemory(device, stagingBufferMemory, null);
    }

    if (!create_texture_image_view(device, textureImage.?.*, textureImageView.?)) {
        c.vkDestroyImage(device, textureImage.?.*, null);
        c.vkFreeMemory(device, textureImageMemory.?.*, null);
        return false;
    }

    return true;
}

pub export fn vk_texture_create_placeholder(allocator: ?*c.VulkanAllocator, device: c.VkDevice,
                                            commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue,
                                            textureImage: ?*c.VkImage, textureImageMemory: ?*c.VkDeviceMemory,
                                            textureImageView: ?*c.VkImageView, format: ?*const c.VkFormat) callconv(.c) bool {
    _ = format;
    var whitePixel = [_]u8{ 255, 255, 255, 255 };
    var placeholderTexture = std.mem.zeroes(c.CardinalTexture);
    placeholderTexture.data = &whitePixel;
    placeholderTexture.width = 1;
    placeholderTexture.height = 1;
    placeholderTexture.channels = 4;
    placeholderTexture.path = @as([*c]u8, @constCast("placeholder"));

    return vk_texture_create_from_data(allocator, device, commandPool, graphicsQueue, null,
                                       &placeholderTexture, textureImage, textureImageMemory,
                                       textureImageView, null);
}

pub export fn vk_texture_create_sampler(device: c.VkDevice, physicalDevice: c.VkPhysicalDevice,
                                        sampler: ?*c.VkSampler) callconv(.c) bool {
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
        log.cardinal_log_error("Failed to create texture sampler", .{});
        return false;
    }

    return true;
}
