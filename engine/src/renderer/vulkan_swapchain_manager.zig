//! Standalone swapchain manager (C-ABI oriented).
//!
//! Provides a small, self-contained swapchain creation/recreation helper used by older code paths.
//! The main renderer also has its own swapchain code; this manager is primarily kept for C interop.
const std = @import("std");
const log = @import("../core/log.zig");
const swapchain_util = @import("util/vulkan_swapchain_util.zig");
const swapchain_policy = @import("util/vulkan_swapchain_policy.zig");

const swapchain_log = log.ScopedLogger("SWAPCHAIN");

const c = @import("vulkan_c.zig").c;

pub const VulkanSwapchainManager = extern struct {
    device: c.VkDevice,
    physicalDevice: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,

    swapchain: c.VkSwapchainKHR,
    format: c.VkFormat,
    extent: c.VkExtent2D,
    colorSpace: c.VkColorSpaceKHR,
    presentMode: c.VkPresentModeKHR,

    images: ?[*]c.VkImage,
    imageViews: ?[*]c.VkImageView,
    imageCount: u32,

    recreationPending: bool,
    lastRecreationTime: u64,
    recreationCount: u32,

    initialized: bool,
};

pub const VulkanSwapchainCreateInfo = extern struct {
    device: c.VkDevice,
    physicalDevice: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,

    preferredImageCount: u32,
    preferredFormat: c.VkFormat,
    preferredColorSpace: c.VkColorSpaceKHR,
    preferredPresentMode: c.VkPresentModeKHR,

    windowExtent: c.VkExtent2D,
    oldSwapchain: c.VkSwapchainKHR,
};

pub const VulkanSurfaceSupport = extern struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: ?[*]c.VkSurfaceFormatKHR,
    formatCount: u32,
    presentModes: ?[*]c.VkPresentModeKHR,
    presentModeCount: u32,
};

/// Returns a wall-clock timestamp in milliseconds.
fn get_current_time_ms() u64 {
    return @intCast(std.time.milliTimestamp());
}

fn destroy_image_views(manager: *VulkanSwapchainManager) void {
    if (manager.imageViews != null) {
        const alloc = std.heap.c_allocator;
        const views: []c.VkImageView = manager.imageViews.?[0..@as(usize, @intCast(manager.imageCount))];
        var i: u32 = 0;
        while (i < manager.imageCount) : (i += 1) {
            if (manager.imageViews.?[i] != null) {
                c.vkDestroyImageView(manager.device, manager.imageViews.?[i], null);
            }
        }
        alloc.free(views);
        manager.imageViews = null;
    }
}

fn create_swapchain_internal(manager: *VulkanSwapchainManager, createInfo: *const VulkanSwapchainCreateInfo) bool {
    const alloc = std.heap.c_allocator;
    var caps = std.mem.zeroes(c.VkSurfaceCapabilitiesKHR);
    var formats: []c.VkSurfaceFormatKHR = &.{};
    var modes: []c.VkPresentModeKHR = &.{};
    defer {
        if (formats.len != 0) alloc.free(formats);
        if (modes.len != 0) alloc.free(modes);
    }

    if (!swapchain_util.query_surface_support(alloc, manager.physicalDevice, manager.surface, &caps, &formats, &modes)) {
        swapchain_log.err("Failed to query surface support", .{});
        return false;
    }

    const surfaceFormat = swapchain_policy.choose_surface_format_with_preference(formats.ptr, @intCast(formats.len), createInfo.preferredFormat, createInfo.preferredColorSpace, false);

    const presentMode = swapchain_policy.choose_present_mode(modes.ptr, @intCast(modes.len), createInfo.preferredPresentMode);

    const extent = swapchain_util.choose_extent(&caps, createInfo.windowExtent);

    if (extent.width == 0 or extent.height == 0) {
        swapchain_log.err("Invalid swapchain extent: {d}x{d}", .{ extent.width, extent.height });
        return false;
    }

    var imageCount = createInfo.preferredImageCount;
    if (imageCount == 0) {
        imageCount = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and
            imageCount > caps.maxImageCount)
        {
            imageCount = caps.maxImageCount;
        }
    }

    // Clamp image count to supported range
    if (imageCount < caps.minImageCount) {
        imageCount = caps.minImageCount;
    }
    if (caps.maxImageCount > 0 and imageCount > caps.maxImageCount) {
        imageCount = caps.maxImageCount;
    }

    swapchain_log.info("Creating swapchain: {d}x{d}, {d} images, format {d}", .{ extent.width, extent.height, imageCount, surfaceFormat.format });

    // Create swapchain
    var swapchainCreateInfo = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
    swapchainCreateInfo.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    swapchainCreateInfo.surface = manager.surface;
    swapchainCreateInfo.minImageCount = imageCount;
    swapchainCreateInfo.imageFormat = surfaceFormat.format;
    swapchainCreateInfo.imageColorSpace = surfaceFormat.colorSpace;
    swapchainCreateInfo.imageExtent = extent;
    swapchainCreateInfo.imageArrayLayers = 1;
    swapchainCreateInfo.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    swapchainCreateInfo.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    swapchainCreateInfo.queueFamilyIndexCount = 0;
    swapchainCreateInfo.pQueueFamilyIndices = null;
    swapchainCreateInfo.preTransform = caps.currentTransform;
    swapchainCreateInfo.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    swapchainCreateInfo.presentMode = presentMode;
    swapchainCreateInfo.clipped = c.VK_TRUE;
    swapchainCreateInfo.oldSwapchain = createInfo.oldSwapchain;

    const result = c.vkCreateSwapchainKHR(manager.device, &swapchainCreateInfo, null, &manager.swapchain);
    if (result != c.VK_SUCCESS) {
        swapchain_log.err("Failed to create swapchain: {d}", .{result});
        return false;
    }

    // Store swapchain properties
    manager.format = surfaceFormat.format;
    manager.colorSpace = surfaceFormat.colorSpace;
    manager.extent = extent;
    manager.presentMode = presentMode;

    var images: []c.VkImage = &.{};
    if (!swapchain_util.retrieve_swapchain_images(alloc, manager.device, manager.swapchain, &images)) {
        swapchain_log.err("Failed to retrieve swapchain images", .{});
        c.vkDestroySwapchainKHR(manager.device, manager.swapchain, null);
        manager.swapchain = null;
        return false;
    }
    manager.images = images.ptr;
    manager.imageCount = @intCast(images.len);

    var views: []c.VkImageView = &.{};
    if (!swapchain_util.create_image_views(alloc, manager.device, images, manager.format, &views)) {
        alloc.free(images);
        manager.images = null;
        manager.imageCount = 0;
        c.vkDestroySwapchainKHR(manager.device, manager.swapchain, null);
        manager.swapchain = null;
        return false;
    }
    manager.imageViews = views.ptr;

    // Update recreation tracking
    manager.recreationPending = false;
    manager.lastRecreationTime = get_current_time_ms();
    manager.recreationCount += 1;

    swapchain_log.info("Successfully created swapchain with {d} images ({d}x{d})", .{ manager.imageCount, manager.extent.width, manager.extent.height });
    return true;
}

/// C-ABI entrypoints for swapchain manager creation and lifecycle.
pub export fn vk_swapchain_manager_create(manager: ?*VulkanSwapchainManager, createInfo: ?*const VulkanSwapchainCreateInfo) callconv(.c) bool {
    if (manager == null or createInfo == null) {
        swapchain_log.err("Invalid parameters for swapchain manager creation", .{});
        return false;
    }
    const mgr = manager.?;
    const info = createInfo.?;

    if (info.device == null or info.physicalDevice == null or info.surface == null) {
        swapchain_log.err("Invalid Vulkan objects in create info", .{});
        return false;
    }

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(VulkanSwapchainManager)], 0);

    mgr.device = info.device;
    mgr.physicalDevice = info.physicalDevice;
    mgr.surface = info.surface;

    // Create the swapchain
    if (!create_swapchain_internal(mgr, info)) {
        return false;
    }

    mgr.initialized = true;

    swapchain_log.info("Swapchain manager created successfully", .{});
    return true;
}

pub export fn vk_swapchain_manager_destroy(manager: ?*VulkanSwapchainManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized) return;

    // Destroy image views
    destroy_image_views(mgr);

    // Free images array
    if (mgr.images != null) {
        const alloc = std.heap.c_allocator;
        const images: []c.VkImage = mgr.images.?[0..@as(usize, @intCast(mgr.imageCount))];
        alloc.free(images);
        mgr.images = null;
    }

    // Destroy swapchain
    if (mgr.swapchain != null) {
        c.vkDestroySwapchainKHR(mgr.device, mgr.swapchain, null);
        mgr.swapchain = null;
    }

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(VulkanSwapchainManager)], 0);

    swapchain_log.debug("Swapchain manager destroyed", .{});
}

pub export fn vk_swapchain_manager_recreate(manager: ?*VulkanSwapchainManager, newExtent: c.VkExtent2D) callconv(.c) bool {
    if (manager == null) {
        swapchain_log.err("Invalid manager for recreation", .{});
        return false;
    }
    const mgr = manager.?;
    if (!mgr.initialized) {
        swapchain_log.err("Invalid manager for recreation", .{});
        return false;
    }

    if (mgr.device == null) {
        swapchain_log.err("No valid device for swapchain recreation", .{});
        return false;
    }

    swapchain_log.info("Starting swapchain recreation", .{});

    // Wait for device to be idle
    const idleResult = c.vkDeviceWaitIdle(mgr.device);
    if (idleResult == c.VK_ERROR_DEVICE_LOST) {
        swapchain_log.err("Device lost during recreation wait", .{});
        return false;
    }
    if (idleResult != c.VK_SUCCESS) {
        swapchain_log.err("Failed to wait for device idle: {d}", .{idleResult});
        return false;
    }

    // Store old swapchain for recreation
    const oldSwapchain = mgr.swapchain;
    const oldImages = mgr.images;
    const oldImageViews = mgr.imageViews;
    const oldImageCount = mgr.imageCount;
    const oldExtent = mgr.extent;
    const oldFormat = mgr.format;

    // Clear current state
    mgr.swapchain = null;
    mgr.images = null;
    mgr.imageViews = null;
    mgr.imageCount = 0;

    // Create new swapchain
    var createInfo = std.mem.zeroes(VulkanSwapchainCreateInfo);
    createInfo.device = mgr.device;
    createInfo.physicalDevice = mgr.physicalDevice;
    createInfo.surface = mgr.surface;
    createInfo.preferredImageCount = 0; // Use automatic
    createInfo.preferredFormat = oldFormat;
    createInfo.preferredColorSpace = mgr.colorSpace;
    createInfo.preferredPresentMode = mgr.presentMode;
    createInfo.windowExtent = newExtent;
    createInfo.oldSwapchain = oldSwapchain;

    if (!create_swapchain_internal(mgr, &createInfo)) {
        swapchain_log.err("Failed to recreate swapchain", .{});

        // Restore old state
        mgr.swapchain = oldSwapchain;
        mgr.images = oldImages;
        mgr.imageViews = oldImageViews;
        mgr.imageCount = oldImageCount;
        mgr.extent = oldExtent;
        mgr.format = oldFormat;
        return false;
    }

    // Clean up old resources
    if (oldImageViews != null) {
        const alloc = std.heap.c_allocator;
        const old_views: []c.VkImageView = oldImageViews.?[0..@as(usize, @intCast(oldImageCount))];
        var i: u32 = 0;
        while (i < oldImageCount) : (i += 1) {
            if (oldImageViews.?[i] != null) {
                c.vkDestroyImageView(mgr.device, oldImageViews.?[i], null);
            }
        }
        alloc.free(old_views);
    }

    if (oldImages != null) {
        const alloc = std.heap.c_allocator;
        const old_images: []c.VkImage = oldImages.?[0..@as(usize, @intCast(oldImageCount))];
        alloc.free(old_images);
    }

    if (oldSwapchain != null) {
        c.vkDestroySwapchainKHR(mgr.device, oldSwapchain, null);
    }

    swapchain_log.info("Successfully recreated swapchain: {d}x{d} -> {d}x{d}", .{ oldExtent.width, oldExtent.height, mgr.extent.width, mgr.extent.height });
    return true;
}

pub export fn vk_swapchain_manager_acquire_image(manager: ?*VulkanSwapchainManager, timeout: u64, semaphore: c.VkSemaphore, fence: c.VkFence, imageIndex: ?*u32) callconv(.c) c.VkResult {
    if (manager == null or imageIndex == null) {
        return c.VK_ERROR_INITIALIZATION_FAILED;
    }
    const mgr = manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    if (mgr.swapchain == null) {
        return c.VK_ERROR_SURFACE_LOST_KHR;
    }

    return c.vkAcquireNextImageKHR(mgr.device, mgr.swapchain, timeout, semaphore, fence, imageIndex);
}

pub export fn vk_swapchain_manager_present(manager: ?*VulkanSwapchainManager, presentQueue: c.VkQueue, imageIndex: u32, waitSemaphoreCount: u32, waitSemaphores: ?[*]const c.VkSemaphore) callconv(.c) c.VkResult {
    if (manager == null or presentQueue == null) {
        return c.VK_ERROR_INITIALIZATION_FAILED;
    }
    const mgr = manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    if (mgr.swapchain == null) {
        return c.VK_ERROR_SURFACE_LOST_KHR;
    }

    var presentInfo = std.mem.zeroes(c.VkPresentInfoKHR);
    presentInfo.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    presentInfo.waitSemaphoreCount = waitSemaphoreCount;
    presentInfo.pWaitSemaphores = waitSemaphores;
    presentInfo.swapchainCount = 1;
    presentInfo.pSwapchains = &mgr.swapchain;
    presentInfo.pImageIndices = &imageIndex;
    presentInfo.pResults = null;

    return c.vkQueuePresentKHR(presentQueue, &presentInfo);
}

pub export fn vk_swapchain_query_surface_support(physicalDevice: c.VkPhysicalDevice, surface: c.VkSurfaceKHR, support: ?*VulkanSurfaceSupport) callconv(.c) bool {
    if (physicalDevice == null or surface == null or support == null) {
        return false;
    }
    const supp = support.?;

    @memset(@as([*]u8, @ptrCast(supp))[0..@sizeOf(VulkanSurfaceSupport)], 0);

    const alloc = std.heap.c_allocator;
    var formats: []c.VkSurfaceFormatKHR = &.{};
    var modes: []c.VkPresentModeKHR = &.{};
    if (!swapchain_util.query_surface_support(alloc, physicalDevice, surface, &supp.capabilities, &formats, &modes)) {
        if (formats.len != 0) alloc.free(formats);
        if (modes.len != 0) alloc.free(modes);
        return false;
    }
    supp.formats = formats.ptr;
    supp.formatCount = @intCast(formats.len);
    supp.presentModes = modes.ptr;
    supp.presentModeCount = @intCast(modes.len);
    return true;
}

pub export fn vk_swapchain_free_surface_support(support: ?*VulkanSurfaceSupport) callconv(.c) void {
    if (support == null) return;
    const supp = support.?;
    const alloc = std.heap.c_allocator;

    if (supp.formats != null) {
        const formats: []c.VkSurfaceFormatKHR = supp.formats.?[0..@as(usize, @intCast(supp.formatCount))];
        alloc.free(formats);
        supp.formats = null;
    }

    if (supp.presentModes != null) {
        const modes: []c.VkPresentModeKHR = supp.presentModes.?[0..@as(usize, @intCast(supp.presentModeCount))];
        alloc.free(modes);
        supp.presentModes = null;
    }

    supp.formatCount = 0;
    supp.presentModeCount = 0;
}

pub export fn vk_swapchain_choose_surface_format(availableFormats: ?[*]const c.VkSurfaceFormatKHR, formatCount: u32, preferredFormat: c.VkFormat, preferredColorSpace: c.VkColorSpaceKHR) callconv(.c) c.VkSurfaceFormatKHR {
    if (availableFormats == null) {
        var defaultFormat = std.mem.zeroes(c.VkSurfaceFormatKHR);
        defaultFormat.format = c.VK_FORMAT_B8G8R8A8_SRGB;
        defaultFormat.colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
        return defaultFormat;
    }
    if (formatCount == 0) {
        return availableFormats.?[0];
    }
    return swapchain_policy.choose_surface_format_with_preference(availableFormats.?, formatCount, preferredFormat, preferredColorSpace, false);
}

pub export fn vk_swapchain_choose_present_mode(availableModes: ?[*]const c.VkPresentModeKHR, modeCount: u32, preferredMode: c.VkPresentModeKHR) callconv(.c) c.VkPresentModeKHR {
    if (availableModes == null or modeCount == 0) {
        return c.VK_PRESENT_MODE_FIFO_KHR;
    }
    return swapchain_policy.choose_present_mode(availableModes.?, modeCount, preferredMode);
}

pub export fn vk_swapchain_choose_extent(capabilities: ?*const c.VkSurfaceCapabilitiesKHR, windowExtent: c.VkExtent2D) callconv(.c) c.VkExtent2D {
    if (capabilities == null) {
        return windowExtent;
    }
    const caps = capabilities.?;

    if (caps.currentExtent.width != std.math.maxInt(u32)) {
        return caps.currentExtent;
    }

    var actualExtent = windowExtent;

    // Clamp to supported range
    if (actualExtent.width < caps.minImageExtent.width) {
        actualExtent.width = caps.minImageExtent.width;
    }
    if (actualExtent.width > caps.maxImageExtent.width) {
        actualExtent.width = caps.maxImageExtent.width;
    }

    if (actualExtent.height < caps.minImageExtent.height) {
        actualExtent.height = caps.minImageExtent.height;
    }
    if (actualExtent.height > caps.maxImageExtent.height) {
        actualExtent.height = caps.maxImageExtent.height;
    }

    return actualExtent;
}

pub export fn vk_swapchain_manager_mark_for_recreation(manager: ?*VulkanSwapchainManager) callconv(.c) void {
    if (manager) |mgr| {
        if (mgr.initialized) {
            mgr.recreationPending = true;
        }
    }
}

pub export fn vk_swapchain_manager_is_recreation_pending(manager: ?*const VulkanSwapchainManager) callconv(.c) bool {
    return if (manager) |mgr| (mgr.initialized and mgr.recreationPending) else false;
}

pub export fn vk_swapchain_manager_get_swapchain(manager: ?*const VulkanSwapchainManager) callconv(.c) c.VkSwapchainKHR {
    return if (manager) |mgr| (if (mgr.initialized) mgr.swapchain else null) else null;
}

pub export fn vk_swapchain_manager_get_format(manager: ?*const VulkanSwapchainManager) callconv(.c) c.VkFormat {
    return if (manager) |mgr| (if (mgr.initialized) mgr.format else c.VK_FORMAT_UNDEFINED) else c.VK_FORMAT_UNDEFINED;
}

pub export fn vk_swapchain_manager_get_extent(manager: ?*const VulkanSwapchainManager) callconv(.c) c.VkExtent2D {
    if (manager) |mgr| {
        if (mgr.initialized) {
            return mgr.extent;
        }
    }
    return .{ .width = 0, .height = 0 };
}

pub export fn vk_swapchain_manager_get_image_count(manager: ?*const VulkanSwapchainManager) callconv(.c) u32 {
    return if (manager) |mgr| (if (mgr.initialized) mgr.imageCount else 0) else 0;
}

pub export fn vk_swapchain_manager_get_images(manager: ?*const VulkanSwapchainManager) callconv(.c) ?[*]const c.VkImage {
    return if (manager) |mgr| (if (mgr.initialized) mgr.images else null) else null;
}

pub export fn vk_swapchain_manager_get_image_views(manager: ?*const VulkanSwapchainManager) callconv(.c) ?[*]const c.VkImageView {
    return if (manager) |mgr| (if (mgr.initialized) mgr.imageViews else null) else null;
}

pub export fn vk_swapchain_manager_get_recreation_stats(manager: ?*const VulkanSwapchainManager, recreationCount: ?*u32, lastRecreationTime: ?*u64) callconv(.c) void {
    if (manager == null or !manager.?.initialized) {
        if (recreationCount) |rc| rc.* = 0;
        if (lastRecreationTime) |lrt| lrt.* = 0;
        return;
    }
    const mgr = manager.?;

    if (recreationCount) |rc| {
        rc.* = mgr.recreationCount;
    }
    if (lastRecreationTime) |lrt| {
        lrt.* = mgr.lastRecreationTime;
    }
}
