const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("vulkan_swapchain_manager.h");
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
    } else {
        @cInclude("time.h");
    }
});

// Internal helper for time
fn get_current_time_ms() u64 {
    return @intCast(std.time.milliTimestamp());
}

// Helper functions (internal)
fn create_image_views(manager: *c.VulkanSwapchainManager) bool {
    const ptr = c.malloc(manager.imageCount * @sizeOf(c.VkImageView));
    if (ptr == null) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to allocate memory for image views", .{});
        return false;
    }
    manager.imageViews = @as([*]c.VkImageView, @ptrCast(@alignCast(ptr.?)));

    // Initialize all image views to null
    var i: u32 = 0;
    while (i < manager.imageCount) : (i += 1) {
        manager.imageViews[i] = null;
    }

    // Create image views
    i = 0;
    while (i < manager.imageCount) : (i += 1) {
        var createInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
        createInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        createInfo.image = manager.images[i];
        createInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        createInfo.format = manager.format;
        createInfo.components.r = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.components.g = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.components.b = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.components.a = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        createInfo.subresourceRange.baseMipLevel = 0;
        createInfo.subresourceRange.levelCount = 1;
        createInfo.subresourceRange.baseArrayLayer = 0;
        createInfo.subresourceRange.layerCount = 1;

        if (c.vkCreateImageView(manager.device, &createInfo, null, &manager.imageViews[i]) != c.VK_SUCCESS) {
            log.cardinal_log_error("[SWAPCHAIN] Failed to create image view {d}", .{i});

            // Clean up previously created image views
            var j: u32 = 0;
            while (j < i) : (j += 1) {
                if (manager.imageViews[j] != null) {
                    c.vkDestroyImageView(manager.device, manager.imageViews[j], null);
                }
            }
            c.free(@ptrCast(manager.imageViews));
            manager.imageViews = null;
            return false;
        }
    }

    log.cardinal_log_debug("[SWAPCHAIN] Created {d} image views", .{manager.imageCount});
    return true;
}

fn destroy_image_views(manager: *c.VulkanSwapchainManager) void {
    if (manager.imageViews != null) {
        var i: u32 = 0;
        while (i < manager.imageCount) : (i += 1) {
            if (manager.imageViews[i] != null) {
                c.vkDestroyImageView(manager.device, manager.imageViews[i], null);
            }
        }
        c.free(@ptrCast(manager.imageViews));
        manager.imageViews = null;
    }
}

fn create_swapchain_internal(manager: *c.VulkanSwapchainManager, createInfo: *const c.VulkanSwapchainCreateInfo) bool {
    // Query surface support
    var support = std.mem.zeroes(c.VulkanSurfaceSupport);
    if (!vk_swapchain_query_surface_support(manager.physicalDevice, manager.surface, &support)) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to query surface support", .{});
        return false;
    }
    defer vk_swapchain_free_surface_support(&support);

    // Choose surface format
    const surfaceFormat = vk_swapchain_choose_surface_format(
        support.formats, support.formatCount, createInfo.preferredFormat,
        createInfo.preferredColorSpace);

    // Choose present mode
    const presentMode = vk_swapchain_choose_present_mode(
        support.presentModes, support.presentModeCount, createInfo.preferredPresentMode);

    // Choose extent
    const extent = vk_swapchain_choose_extent(&support.capabilities, createInfo.windowExtent);

    // Validate extent
    if (extent.width == 0 or extent.height == 0) {
        log.cardinal_log_error("[SWAPCHAIN] Invalid swapchain extent: {d}x{d}", .{extent.width, extent.height});
        return false;
    }

    // Choose image count
    var imageCount = createInfo.preferredImageCount;
    if (imageCount == 0) {
        imageCount = support.capabilities.minImageCount + 1;
        if (support.capabilities.maxImageCount > 0 and
            imageCount > support.capabilities.maxImageCount) {
            imageCount = support.capabilities.maxImageCount;
        }
    }

    // Clamp image count to supported range
    if (imageCount < support.capabilities.minImageCount) {
        imageCount = support.capabilities.minImageCount;
    }
    if (support.capabilities.maxImageCount > 0 and imageCount > support.capabilities.maxImageCount) {
        imageCount = support.capabilities.maxImageCount;
    }

    log.cardinal_log_info("[SWAPCHAIN] Creating swapchain: {d}x{d}, {d} images, format {d}", .{extent.width, extent.height, imageCount, surfaceFormat.format});

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
    swapchainCreateInfo.preTransform = support.capabilities.currentTransform;
    swapchainCreateInfo.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    swapchainCreateInfo.presentMode = presentMode;
    swapchainCreateInfo.clipped = c.VK_TRUE;
    swapchainCreateInfo.oldSwapchain = createInfo.oldSwapchain;

    var result = c.vkCreateSwapchainKHR(manager.device, &swapchainCreateInfo, null, &manager.swapchain);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to create swapchain: {d}", .{result});
        return false;
    }

    // Store swapchain properties
    manager.format = surfaceFormat.format;
    manager.colorSpace = surfaceFormat.colorSpace;
    manager.extent = extent;
    manager.presentMode = presentMode;

    // Get swapchain images
    result = c.vkGetSwapchainImagesKHR(manager.device, manager.swapchain, &manager.imageCount, null);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to get swapchain image count: {d}", .{result});
        c.vkDestroySwapchainKHR(manager.device, manager.swapchain, null);
        manager.swapchain = null;
        return false;
    }

    if (manager.imageCount == 0) {
        log.cardinal_log_error("[SWAPCHAIN] Swapchain has no images", .{});
        c.vkDestroySwapchainKHR(manager.device, manager.swapchain, null);
        manager.swapchain = null;
        return false;
    }

    // Allocate images array
    const ptr = c.malloc(manager.imageCount * @sizeOf(c.VkImage));
    if (ptr == null) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to allocate memory for swapchain images", .{});
        c.vkDestroySwapchainKHR(manager.device, manager.swapchain, null);
        manager.swapchain = null;
        return false;
    }
    manager.images = @as([*]c.VkImage, @ptrCast(@alignCast(ptr.?)));

    // Get swapchain images
    result = c.vkGetSwapchainImagesKHR(manager.device, manager.swapchain, &manager.imageCount, manager.images);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to retrieve swapchain images: {d}", .{result});
        c.free(@ptrCast(manager.images));
        manager.images = null;
        c.vkDestroySwapchainKHR(manager.device, manager.swapchain, null);
        manager.swapchain = null;
        return false;
    }

    // Create image views
    if (!create_image_views(manager)) {
        c.free(@ptrCast(manager.images));
        manager.images = null;
        c.vkDestroySwapchainKHR(manager.device, manager.swapchain, null);
        manager.swapchain = null;
        return false;
    }

    // Update recreation tracking
    manager.recreationPending = false;
    manager.lastRecreationTime = get_current_time_ms();
    manager.recreationCount += 1;

    log.cardinal_log_info("[SWAPCHAIN] Successfully created swapchain with {d} images ({d}x{d})",
                      .{manager.imageCount, manager.extent.width, manager.extent.height});
    return true;
}

// Exported functions

pub export fn vk_swapchain_manager_create(manager: ?*c.VulkanSwapchainManager,
                                 createInfo: ?*const c.VulkanSwapchainCreateInfo) callconv(.c) bool {
    if (manager == null or createInfo == null) {
        log.cardinal_log_error("[SWAPCHAIN] Invalid parameters for swapchain manager creation", .{});
        return false;
    }
    const mgr = manager.?;
    const info = createInfo.?;

    if (info.device == null or info.physicalDevice == null or info.surface == null) {
        log.cardinal_log_error("[SWAPCHAIN] Invalid Vulkan objects in create info", .{});
        return false;
    }

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(c.VulkanSwapchainManager)], 0);

    mgr.device = info.device;
    mgr.physicalDevice = info.physicalDevice;
    mgr.surface = info.surface;

    // Create the swapchain
    if (!create_swapchain_internal(mgr, info)) {
        return false;
    }

    mgr.initialized = true;

    log.cardinal_log_info("[SWAPCHAIN] Swapchain manager created successfully", .{});
    return true;
}

pub export fn vk_swapchain_manager_destroy(manager: ?*c.VulkanSwapchainManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized) return;

    // Destroy image views
    destroy_image_views(mgr);

    // Free images array
    if (mgr.images != null) {
        c.free(@ptrCast(mgr.images));
        mgr.images = null;
    }

    // Destroy swapchain
    if (mgr.swapchain != null) {
        c.vkDestroySwapchainKHR(mgr.device, mgr.swapchain, null);
        mgr.swapchain = null;
    }

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(c.VulkanSwapchainManager)], 0);

    log.cardinal_log_debug("[SWAPCHAIN] Swapchain manager destroyed", .{});
}

pub export fn vk_swapchain_manager_recreate(manager: ?*c.VulkanSwapchainManager, newExtent: c.VkExtent2D) callconv(.c) bool {
    if (manager == null) {
        log.cardinal_log_error("[SWAPCHAIN] Invalid manager for recreation", .{});
        return false;
    }
    const mgr = manager.?;
    if (!mgr.initialized) {
        log.cardinal_log_error("[SWAPCHAIN] Invalid manager for recreation", .{});
        return false;
    }

    if (mgr.device == null) {
        log.cardinal_log_error("[SWAPCHAIN] No valid device for swapchain recreation", .{});
        return false;
    }

    log.cardinal_log_info("[SWAPCHAIN] Starting swapchain recreation", .{});

    // Wait for device to be idle
    const idleResult = c.vkDeviceWaitIdle(mgr.device);
    if (idleResult == c.VK_ERROR_DEVICE_LOST) {
        log.cardinal_log_error("[SWAPCHAIN] Device lost during recreation wait", .{});
        return false;
    }
    if (idleResult != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to wait for device idle: {d}", .{idleResult});
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
    var createInfo = std.mem.zeroes(c.VulkanSwapchainCreateInfo);
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
        log.cardinal_log_error("[SWAPCHAIN] Failed to recreate swapchain", .{});

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
        var i: u32 = 0;
        while (i < oldImageCount) : (i += 1) {
            if (oldImageViews[i] != null) {
                c.vkDestroyImageView(mgr.device, oldImageViews[i], null);
            }
        }
        c.free(@ptrCast(oldImageViews));
    }

    if (oldImages != null) {
        c.free(@ptrCast(oldImages));
    }

    if (oldSwapchain != null) {
        c.vkDestroySwapchainKHR(mgr.device, oldSwapchain, null);
    }

    log.cardinal_log_info("[SWAPCHAIN] Successfully recreated swapchain: {d}x{d} -> {d}x{d}",
                      .{oldExtent.width, oldExtent.height, mgr.extent.width, mgr.extent.height});
    return true;
}

pub export fn vk_swapchain_manager_acquire_image(manager: ?*c.VulkanSwapchainManager, timeout: u64,
                                            semaphore: c.VkSemaphore, fence: c.VkFence,
                                            imageIndex: ?*u32) callconv(.c) c.VkResult {
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

pub export fn vk_swapchain_manager_present(manager: ?*c.VulkanSwapchainManager, presentQueue: c.VkQueue,
                                      imageIndex: u32, waitSemaphoreCount: u32,
                                      waitSemaphores: ?[*]const c.VkSemaphore) callconv(.c) c.VkResult {
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

pub export fn vk_swapchain_query_surface_support(physicalDevice: c.VkPhysicalDevice, surface: c.VkSurfaceKHR,
                                        support: ?*c.VulkanSurfaceSupport) callconv(.c) bool {
    if (physicalDevice == null or surface == null or support == null) {
        return false;
    }
    const supp = support.?;

    @memset(@as([*]u8, @ptrCast(supp))[0..@sizeOf(c.VulkanSurfaceSupport)], 0);

    // Get surface capabilities
    var result = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &supp.capabilities);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to get surface capabilities: {d}", .{result});
        return false;
    }

    // Get surface formats
    result = c.vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &supp.formatCount, null);
    if (result != c.VK_SUCCESS or supp.formatCount == 0) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to get surface formats or no formats available: {d}", .{result});
        return false;
    }

    const ptr = c.malloc(supp.formatCount * @sizeOf(c.VkSurfaceFormatKHR));
    if (ptr == null) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to allocate memory for surface formats", .{});
        return false;
    }
    supp.formats = @as([*]c.VkSurfaceFormatKHR, @ptrCast(@alignCast(ptr.?)));

    result = c.vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &supp.formatCount, supp.formats);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to retrieve surface formats: {d}", .{result});
        c.free(@ptrCast(supp.formats));
        supp.formats = null;
        return false;
    }

    // Get present modes
    result = c.vkGetPhysicalDeviceSurfacePresentModesKHR(physicalDevice, surface, &supp.presentModeCount, null);
    if (result != c.VK_SUCCESS or supp.presentModeCount == 0) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to get present modes or no modes available: {d}", .{result});
        c.free(@ptrCast(supp.formats));
        supp.formats = null;
        return false;
    }

    const ptr2 = c.malloc(supp.presentModeCount * @sizeOf(c.VkPresentModeKHR));
    if (ptr2 == null) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to allocate memory for present modes", .{});
        c.free(@ptrCast(supp.formats));
        supp.formats = null;
        return false;
    }
    supp.presentModes = @as([*]c.VkPresentModeKHR, @ptrCast(@alignCast(ptr2.?)));

    result = c.vkGetPhysicalDeviceSurfacePresentModesKHR(physicalDevice, surface, &supp.presentModeCount, supp.presentModes);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to retrieve present modes: {d}", .{result});
        c.free(@ptrCast(supp.presentModes));
        supp.presentModes = null;
        c.free(@ptrCast(supp.formats));
        supp.formats = null;
        return false;
    }

    return true;
}

pub export fn vk_swapchain_free_surface_support(support: ?*c.VulkanSurfaceSupport) callconv(.c) void {
    if (support == null) return;
    const supp = support.?;

    if (supp.formats != null) {
        c.free(@ptrCast(supp.formats));
        supp.formats = null;
    }

    if (supp.presentModes != null) {
        c.free(@ptrCast(supp.presentModes));
        supp.presentModes = null;
    }

    supp.formatCount = 0;
    supp.presentModeCount = 0;
}

pub export fn vk_swapchain_choose_surface_format(availableFormats: ?[*]const c.VkSurfaceFormatKHR,
                                                      formatCount: u32,
                                                      preferredFormat: c.VkFormat,
                                                      preferredColorSpace: c.VkColorSpaceKHR) callconv(.c) c.VkSurfaceFormatKHR {
    if (availableFormats == null) {
        var defaultFormat = std.mem.zeroes(c.VkSurfaceFormatKHR);
        defaultFormat.format = c.VK_FORMAT_B8G8R8A8_SRGB;
        defaultFormat.colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
        return defaultFormat;
    }
    if (formatCount == 0) {
        return availableFormats.?[0];
    }
    const formats = availableFormats.?;

    // If preferred format is specified, look for it
    if (preferredFormat != c.VK_FORMAT_UNDEFINED) {
        var i: u32 = 0;
        while (i < formatCount) : (i += 1) {
            if (formats[i].format == preferredFormat and
                formats[i].colorSpace == preferredColorSpace) {
                return formats[i];
            }
        }
    }

    // Look for preferred formats
    const preferredFormats = [_]c.VkFormat{c.VK_FORMAT_R8G8B8A8_UNORM, c.VK_FORMAT_B8G8R8A8_UNORM,
                                   c.VK_FORMAT_R8G8B8A8_SRGB, c.VK_FORMAT_B8G8R8A8_SRGB};

    for (preferredFormats) |pf| {
        var j: u32 = 0;
        while (j < formatCount) : (j += 1) {
            if (formats[j].format == pf and
                formats[j].colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                return formats[j];
            }
        }
    }

    // Return the first available format as fallback
    return formats[0];
}

pub export fn vk_swapchain_choose_present_mode(availableModes: ?[*]const c.VkPresentModeKHR,
                                                  modeCount: u32,
                                                  preferredMode: c.VkPresentModeKHR) callconv(.c) c.VkPresentModeKHR {
    if (availableModes == null or modeCount == 0) {
        return c.VK_PRESENT_MODE_FIFO_KHR; // Always available
    }
    const modes = availableModes.?;

    // If preferred mode is specified, look for it
    if (preferredMode != c.VK_PRESENT_MODE_MAX_ENUM_KHR) {
        var i: u32 = 0;
        while (i < modeCount) : (i += 1) {
            if (modes[i] == preferredMode) {
                return preferredMode;
            }
        }
    }

    // Look for preferred modes in order
    const preferredModes = [_]c.VkPresentModeKHR{c.VK_PRESENT_MODE_MAILBOX_KHR, c.VK_PRESENT_MODE_IMMEDIATE_KHR,
                                         c.VK_PRESENT_MODE_FIFO_RELAXED_KHR,
                                         c.VK_PRESENT_MODE_FIFO_KHR};

    for (preferredModes) |pm| {
        var j: u32 = 0;
        while (j < modeCount) : (j += 1) {
            if (modes[j] == pm) {
                return pm;
            }
        }
    }

    // FIFO is guaranteed to be available
    return c.VK_PRESENT_MODE_FIFO_KHR;
}

pub export fn vk_swapchain_choose_extent(capabilities: ?*const c.VkSurfaceCapabilitiesKHR,
                                      windowExtent: c.VkExtent2D) callconv(.c) c.VkExtent2D {
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

pub export fn vk_swapchain_manager_mark_for_recreation(manager: ?*c.VulkanSwapchainManager) callconv(.c) void {
    if (manager) |mgr| {
        if (mgr.initialized) {
            mgr.recreationPending = true;
        }
    }
}

pub export fn vk_swapchain_manager_is_recreation_pending(manager: ?*const c.VulkanSwapchainManager) callconv(.c) bool {
    return if (manager) |mgr| (mgr.initialized and mgr.recreationPending) else false;
}

pub export fn vk_swapchain_manager_get_swapchain(manager: ?*const c.VulkanSwapchainManager) callconv(.c) c.VkSwapchainKHR {
    return if (manager) |mgr| (if (mgr.initialized) mgr.swapchain else null) else null;
}

pub export fn vk_swapchain_manager_get_format(manager: ?*const c.VulkanSwapchainManager) callconv(.c) c.VkFormat {
    return if (manager) |mgr| (if (mgr.initialized) mgr.format else c.VK_FORMAT_UNDEFINED) else c.VK_FORMAT_UNDEFINED;
}

pub export fn vk_swapchain_manager_get_extent(manager: ?*const c.VulkanSwapchainManager) callconv(.c) c.VkExtent2D {
    if (manager) |mgr| {
        if (mgr.initialized) {
            return mgr.extent;
        }
    }
    return .{ .width = 0, .height = 0 };
}

pub export fn vk_swapchain_manager_get_image_count(manager: ?*const c.VulkanSwapchainManager) callconv(.c) u32 {
    return if (manager) |mgr| (if (mgr.initialized) mgr.imageCount else 0) else 0;
}

pub export fn vk_swapchain_manager_get_images(manager: ?*const c.VulkanSwapchainManager) callconv(.c) ?[*]const c.VkImage {
    return if (manager) |mgr| (if (mgr.initialized) mgr.images else null) else null;
}

pub export fn vk_swapchain_manager_get_image_views(manager: ?*const c.VulkanSwapchainManager) callconv(.c) ?[*]const c.VkImageView {
    return if (manager) |mgr| (if (mgr.initialized) mgr.imageViews else null) else null;
}

pub export fn vk_swapchain_manager_get_recreation_stats(manager: ?*const c.VulkanSwapchainManager,
                                               recreationCount: ?*u32,
                                               lastRecreationTime: ?*u64) callconv(.c) void {
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
