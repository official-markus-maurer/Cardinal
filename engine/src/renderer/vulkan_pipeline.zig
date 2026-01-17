const std = @import("std");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const c = @import("vulkan_c.zig").c;
const memory = @import("../core/memory.zig");

const pipe_log = log.ScopedLogger("PIPELINE");

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
        pipe_log.err("failed to find suitable depth format", .{});
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
    imageInfo.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    imageInfo.samples = c.VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    // Use VulkanAllocator to allocate and bind image + memory
    if (!vk_allocator.allocate_image(&s.allocator, &imageInfo, &s.swapchain.depth_image, &s.swapchain.depth_image_memory, &s.swapchain.depth_image_allocation, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
        pipe_log.err("allocator failed to create depth image", .{});
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
        pipe_log.err("failed to create depth image view", .{});
        // Free image + memory via allocator on failure
        vk_allocator.free_image(&s.allocator, s.swapchain.depth_image, s.swapchain.depth_image_allocation);
        s.swapchain.depth_image = null;
        s.swapchain.depth_image_memory = null;
        return false;
    }

    // Initialize layout tracking
    s.swapchain.depth_layout_initialized = false;

    pipe_log.info("depth resources created", .{});
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
            vk_allocator.free_image(&s.allocator, s.swapchain.depth_image, s.swapchain.depth_image_allocation);
        }
        s.swapchain.depth_image = null;
        s.swapchain.depth_image_memory = null;
    }

    // Reset layout tracking when depth resources are destroyed
    s.swapchain.depth_layout_initialized = false;
}

fn create_pipeline_cache(s: *types.VulkanState) bool {
    var cache_info = std.mem.zeroes(c.VkPipelineCacheCreateInfo);
    cache_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO;

    // Try to load cache
    var file_buffer: []u8 = &[_]u8{};
    const file = std.fs.cwd().openFile("pipeline_cache.bin", .{}) catch null;
    if (file) |f| {
        defer f.close();
        if (f.stat()) |stat| {
            if (stat.size > 0) {
                const alloc = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
                if (alloc.alloc(u8, stat.size)) |buf| {
                    if (f.readAll(buf)) |read_bytes| {
                        if (read_bytes == stat.size) {
                            cache_info.initialDataSize = stat.size;
                            cache_info.pInitialData = buf.ptr;
                            file_buffer = buf;
                            pipe_log.info("Loading pipeline cache ({d} bytes)", .{stat.size});
                        }
                    } else |_| {}
                } else |_| {}
            }
        } else |_| {}
    }
    defer if (file_buffer.len > 0) {
        const alloc = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
        alloc.free(file_buffer);
    };

    if (c.vkCreatePipelineCache(s.context.device, &cache_info, null, &s.pipelines.pipeline_cache) != c.VK_SUCCESS) {
        pipe_log.err("Failed to create pipeline cache", .{});
        return false;
    }
    return true;
}

fn destroy_pipeline_cache(s: *types.VulkanState) void {
    if (s.pipelines.pipeline_cache != null) {
        // Save cache
        var size: usize = 0;
        if (c.vkGetPipelineCacheData(s.context.device, s.pipelines.pipeline_cache, &size, null) == c.VK_SUCCESS) {
            if (size > 0) {
                const alloc = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
                if (alloc.alloc(u8, size)) |buf| {
                    defer alloc.free(buf);
                    if (c.vkGetPipelineCacheData(s.context.device, s.pipelines.pipeline_cache, &size, buf.ptr) == c.VK_SUCCESS) {
                        if (std.fs.cwd().createFile("pipeline_cache.bin", .{})) |file| {
                            defer file.close();
                            _ = file.writeAll(buf) catch {};
                            pipe_log.info("Saved pipeline cache ({d} bytes)", .{size});
                        } else |_| {
                            pipe_log.warn("Failed to create cache file", .{});
                        }
                    }
                } else |_| {}
            }
        }

        c.vkDestroyPipelineCache(s.context.device, s.pipelines.pipeline_cache, null);
        s.pipelines.pipeline_cache = null;
    }
}

pub export fn vk_create_pipeline(s: ?*types.VulkanState) callconv(.c) bool {
    if (s == null) return false;
    const vs = s.?;

    // Create Pipeline Cache
    if (!create_pipeline_cache(vs)) {
        return false;
    }

    pipe_log.info("create depth resources", .{});
    if (!create_depth_resources(vs)) {
        return false;
    }

    pipe_log.info("pipeline: depth resources created - no simple triangle pipeline needed", .{});
    return true;
}

pub export fn vk_destroy_pipeline(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null or s.?.context.device == null) return;
    const vs = s.?;

    // Wait for device to be idle before destroying resources for thread safety
    const result = c.vkDeviceWaitIdle(vs.context.device);
    if (result != c.VK_SUCCESS) {
        pipe_log.err("pipeline: vkDeviceWaitIdle failed during destruction: {d}", .{result});
        // Continue with destruction anyway to prevent resource leaks
    }

    destroy_pipeline_cache(vs);
    destroy_depth_resources(vs);

    pipe_log.info("pipeline resources destroyed", .{});
}
