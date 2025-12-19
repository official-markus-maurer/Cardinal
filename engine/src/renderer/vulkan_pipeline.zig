const std = @import("std");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const c = @import("vulkan_c.zig").c;

fn create_depth_resources(s: *types.VulkanState) bool {
    // Find a suitable depth format
    const candidates = [_]c.VkFormat{ c.VK_FORMAT_D32_SFLOAT, c.VK_FORMAT_D32_SFLOAT_S8_UINT, c.VK_FORMAT_D24_UNORM_S8_UINT };
    s.swapchain.depth_format = c.VK_FORMAT_UNDEFINED;

    for (candidates) |format| {
        var props: c.VkFormatProperties = undefined;
        c.vkGetPhysicalDeviceFormatProperties(s.context.physical_device, format, &props);
        if ((props.optimalTilingFeatures & c.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0) {
            s.swapchain.depth_format = format;
            break;
        }
    }

    if (s.swapchain.depth_format == c.VK_FORMAT_UNDEFINED) {
        log.cardinal_log_error("pipeline: failed to find suitable depth format", .{});
        return false;
    }

    // Create depth image
    var imageInfo = std.mem.zeroes(c.VkImageCreateInfo);
    imageInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = c.VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = s.swapchain.extent.width;
    imageInfo.extent.height = s.swapchain.extent.height;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = s.swapchain.depth_format;
    imageInfo.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    imageInfo.samples = c.VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    // Use VulkanAllocator to allocate and bind image + memory
    if (!vk_allocator.vk_allocator_allocate_image(&s.allocator, &imageInfo, &s.swapchain.depth_image,
                                     &s.swapchain.depth_image_memory, &s.swapchain.depth_image_allocation,
                                     c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
        log.cardinal_log_error("pipeline: allocator failed to create depth image", .{});
        return false;
    }

    // Create depth image view
    var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
    viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = s.swapchain.depth_image;
    viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = s.swapchain.depth_format;
    viewInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;

    if (c.vkCreateImageView(s.context.device, &viewInfo, null, &s.swapchain.depth_image_view) != c.VK_SUCCESS) {
        log.cardinal_log_error("pipeline: failed to create depth image view", .{});
        // Free image + memory via allocator on failure
        vk_allocator.vk_allocator_free_image(&s.allocator, s.swapchain.depth_image, s.swapchain.depth_image_allocation);
        s.swapchain.depth_image = null;
        s.swapchain.depth_image_memory = null;
        return false;
    }

    // Initialize layout tracking
    s.swapchain.depth_layout_initialized = false;

    log.cardinal_log_info("pipeline: depth resources created", .{});
    return true;
}

fn destroy_depth_resources(s: *types.VulkanState) void {
    if (s.context.device == null) return;

    // Validate and destroy depth image view
    if (s.swapchain.depth_image_view != null) {
        c.vkDestroyImageView(s.context.device, s.swapchain.depth_image_view, null);
        s.swapchain.depth_image_view = null;
    }

    // Validate and free image + memory using allocator
    if (s.swapchain.depth_image != null or s.swapchain.depth_image_memory != null) {
        // Ensure allocator is valid before freeing
        if (s.allocator.device != null) {
            vk_allocator.vk_allocator_free_image(&s.allocator, s.swapchain.depth_image, s.swapchain.depth_image_allocation);
        }
        s.swapchain.depth_image = null;
        s.swapchain.depth_image_memory = null;
    }

    // Reset layout tracking when depth resources are destroyed
    s.swapchain.depth_layout_initialized = false;
}

pub export fn vk_create_pipeline(s: ?*types.VulkanState) callconv(.c) bool {
    if (s == null) return false;
    const vs = s.?;

    log.cardinal_log_info("pipeline: create depth resources", .{});
    if (!create_depth_resources(vs)) {
        return false;
    }

    log.cardinal_log_info("pipeline: depth resources created - no simple triangle pipeline needed", .{});
    return true;
}

pub export fn vk_destroy_pipeline(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null or s.?.context.device == null) return;
    const vs = s.?;

    // Wait for device to be idle before destroying resources for thread safety
    const result = c.vkDeviceWaitIdle(vs.context.device);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("pipeline: vkDeviceWaitIdle failed during destruction: {d}", .{result});
        // Continue with destruction anyway to prevent resource leaks
    }

    destroy_depth_resources(vs);

    log.cardinal_log_info("pipeline: pipeline resources destroyed", .{});
}
