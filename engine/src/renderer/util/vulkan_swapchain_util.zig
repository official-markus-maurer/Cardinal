//! Swapchain helper utilities shared between swapchain implementations.
const std = @import("std");
const c = @import("../vulkan_c.zig").c;

/// Queries surface capabilities and returns owned slices for formats and present modes.
///
/// The caller owns `out_formats` and `out_present_modes` and must free them with the allocator
/// passed in.
pub fn query_surface_support(alloc: std.mem.Allocator, physical_device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR, out_caps: *c.VkSurfaceCapabilitiesKHR, out_formats: *[]c.VkSurfaceFormatKHR, out_present_modes: *[]c.VkPresentModeKHR) bool {
    out_formats.* = &.{};
    out_present_modes.* = &.{};

    if (physical_device == null or surface == null) return false;

    if (c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, out_caps) != c.VK_SUCCESS) {
        return false;
    }

    var fmt_count: u32 = 0;
    if (c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &fmt_count, null) != c.VK_SUCCESS or fmt_count == 0) {
        return false;
    }
    const fmts = alloc.alloc(c.VkSurfaceFormatKHR, fmt_count) catch return false;
    errdefer alloc.free(fmts);
    if (c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &fmt_count, fmts.ptr) != c.VK_SUCCESS) {
        return false;
    }
    out_formats.* = fmts;

    var mode_count: u32 = 0;
    if (c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &mode_count, null) != c.VK_SUCCESS or mode_count == 0) {
        return false;
    }
    const modes = alloc.alloc(c.VkPresentModeKHR, mode_count) catch return false;
    errdefer alloc.free(modes);
    if (c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &mode_count, modes.ptr) != c.VK_SUCCESS) {
        return false;
    }
    out_present_modes.* = modes;

    return true;
}

/// Clamps `window_extent` to the surface capabilities.
pub fn choose_extent(capabilities: *const c.VkSurfaceCapabilitiesKHR, window_extent: c.VkExtent2D) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }

    var actual = window_extent;

    if (actual.width < capabilities.minImageExtent.width) actual.width = capabilities.minImageExtent.width;
    if (actual.width > capabilities.maxImageExtent.width) actual.width = capabilities.maxImageExtent.width;
    if (actual.height < capabilities.minImageExtent.height) actual.height = capabilities.minImageExtent.height;
    if (actual.height > capabilities.maxImageExtent.height) actual.height = capabilities.maxImageExtent.height;

    return actual;
}

/// Retrieves swapchain images into an owned slice.
pub fn retrieve_swapchain_images(alloc: std.mem.Allocator, device: c.VkDevice, swapchain: c.VkSwapchainKHR, out_images: *[]c.VkImage) bool {
    out_images.* = &.{};
    var count: u32 = 0;
    if (c.vkGetSwapchainImagesKHR(device, swapchain, &count, null) != c.VK_SUCCESS or count == 0) {
        return false;
    }

    const images = alloc.alloc(c.VkImage, count) catch return false;
    errdefer alloc.free(images);
    if (c.vkGetSwapchainImagesKHR(device, swapchain, &count, images.ptr) != c.VK_SUCCESS) {
        return false;
    }
    out_images.* = images;
    return true;
}

/// Creates image views for swapchain images into an owned slice.
pub fn create_image_views(alloc: std.mem.Allocator, device: c.VkDevice, images: []const c.VkImage, format: c.VkFormat, out_views: *[]c.VkImageView) bool {
    out_views.* = &.{};
    const views = alloc.alloc(c.VkImageView, images.len) catch return false;
    errdefer alloc.free(views);

    @memset(views, null);

    var i: usize = 0;
    while (i < images.len) : (i += 1) {
        var createInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
        createInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        createInfo.image = images[i];
        createInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        createInfo.format = format;
        createInfo.components.r = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.components.g = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.components.b = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.components.a = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        createInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        createInfo.subresourceRange.baseMipLevel = 0;
        createInfo.subresourceRange.levelCount = 1;
        createInfo.subresourceRange.baseArrayLayer = 0;
        createInfo.subresourceRange.layerCount = 1;

        if (c.vkCreateImageView(device, &createInfo, null, &views[i]) != c.VK_SUCCESS) {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                if (views[j] != null) {
                    c.vkDestroyImageView(device, views[j], null);
                }
            }
            return false;
        }
    }

    out_views.* = views;
    return true;
}
