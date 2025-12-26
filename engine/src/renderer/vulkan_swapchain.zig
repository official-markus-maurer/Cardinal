const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const vk_simple_pipelines = @import("vulkan_simple_pipelines.zig");
const types = @import("vulkan_types.zig");
const vk_commands = @import("vulkan_commands.zig");
const vk_pipeline = @import("vulkan_pipeline.zig");
const vk_mesh_shader = @import("vulkan_mesh_shader.zig");

const swap_log = log.ScopedLogger("SWAPCHAIN");

const c = @import("vulkan_c.zig").c;

// Helper functions

fn get_current_time_ms() u64 {
    if (builtin.os.tag == .windows) {
        return c.GetTickCount64();
    } else {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1000000;
    }
}

fn should_throttle_recreation(s: *types.VulkanState) bool {
    if (!s.swapchain.frame_pacing_enabled) {
        return false;
    }

    const current_time = get_current_time_ms();
    const time_since_last = current_time - s.swapchain.last_recreation_time;

    // Throttle if less than 100ms since last recreation and we've had multiple failures
    if (time_since_last < 100 and s.swapchain.consecutive_recreation_failures > 0) {
        return true;
    }

    // More aggressive throttling if we've had many consecutive failures
    if (s.swapchain.consecutive_recreation_failures >= 3 and time_since_last < 500) {
        // Only log this warning once every 1000ms to reduce spam
        const static = struct {
            var last_throttle_log: u64 = 0;
        };
        if (current_time - static.last_throttle_log > 1000) {
            swap_log.warn("Aggressive throttling: {d} consecutive failures", .{s.swapchain.consecutive_recreation_failures});
            static.last_throttle_log = current_time;
        }
        return true;
    }

    // Extreme throttling for persistent failures
    if (s.swapchain.consecutive_recreation_failures >= 6) {
        // Wait much longer between attempts when we have many failures
        if (time_since_last < 2000) {
            return true;
        }
    }

    return false;
}

fn choose_surface_format(formats: [*]const c.VkSurfaceFormatKHR, count: u32) c.VkSurfaceFormatKHR {
    if (count == 0) {
        return std.mem.zeroes(c.VkSurfaceFormatKHR);
    }

    // Allow opting into HDR via environment variable CARDINAL_PREFER_HDR
    var prefer_hdr = false;
    const env_hdr = c.getenv("CARDINAL_PREFER_HDR");
    if (env_hdr != null) {
        const h = env_hdr[0];
        if (h == '1' or h == 'T' or h == 't' or h == 'Y' or h == 'y') {
            prefer_hdr = true;
        }
    }

    var best_score: i32 = -1;
    var best = formats[0];

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const f = &formats[i];
        var score: i32 = 0;

        // Color space preference
        if (prefer_hdr) {
            if (f.colorSpace == c.VK_COLOR_SPACE_HDR10_ST2084_EXT or
                f.colorSpace == c.VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT or
                f.colorSpace == c.VK_COLOR_SPACE_BT2020_LINEAR_EXT)
            {
                score += 50;
            }
        }
        // Prefer standard sRGB nonlinear by default
        if (f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            score += 10;
        }

        // Format preference ordering
        switch (f.format) {
            c.VK_FORMAT_R16G16B16A16_SFLOAT => {
                if (prefer_hdr) score += 40;
            },
            c.VK_FORMAT_A2B10G10R10_UNORM_PACK32 => {
                if (prefer_hdr) score += 30;
            },
            c.VK_FORMAT_B8G8R8A8_UNORM => {
                score += 20;
            },
            c.VK_FORMAT_R8G8B8A8_UNORM => {
                score += 15;
            },
            else => {},
        }

        if (score > best_score) {
            best_score = score;
            best = f.*;
        }
    }

    return best;
}

fn choose_present_mode(modes: [*]const c.VkPresentModeKHR, count: u32) c.VkPresentModeKHR {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (modes[i] == c.VK_PRESENT_MODE_MAILBOX_KHR)
            return c.VK_PRESENT_MODE_MAILBOX_KHR;
    }
    return c.VK_PRESENT_MODE_FIFO_KHR;
}

fn wait_device_idle_for_swapchain(s: *types.VulkanState) bool {
    const t_idle0 = get_current_time_ms();
    const res = c.vkDeviceWaitIdle(s.context.device);
    const dt = get_current_time_ms() - t_idle0;

    if (dt > 200) {
        log.cardinal_log_warn("[WATCHDOG] Swapchain create: device wait idle duration {d} ms", .{dt});
    }

    if (res == c.VK_ERROR_DEVICE_LOST) {
        log.cardinal_log_error("[SWAPCHAIN] Device lost during swapchain creation", .{});
        s.recovery.device_lost = true;
        return false;
    } else if (res != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Device not ready for swapchain creation: {d}", .{res});
        return false;
    }
    return true;
}

fn get_surface_details(s: *types.VulkanState, caps: *c.VkSurfaceCapabilitiesKHR, out_fmt: *c.VkSurfaceFormatKHR, out_mode: *c.VkPresentModeKHR) bool {
    if (c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(s.context.physical_device, s.context.surface, caps) != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to get surface capabilities", .{});
        return false;
    }

    if (caps.minImageCount == 0 or caps.maxImageExtent.width == 0 or caps.maxImageExtent.height == 0) {
        log.cardinal_log_error("[SWAPCHAIN] Invalid surface capabilities detected", .{});
        return false;
    }

    var count: u32 = 0;
    if (c.vkGetPhysicalDeviceSurfaceFormatsKHR(s.context.physical_device, s.context.surface, &count, null) != c.VK_SUCCESS or count == 0) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to get surface formats", .{});
        return false;
    }

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const fmts_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkSurfaceFormatKHR) * count);
    if (fmts_ptr == null) return false;
    const fmts = @as([*]c.VkSurfaceFormatKHR, @ptrCast(@alignCast(fmts_ptr)));
    defer memory.cardinal_free(mem_alloc, fmts_ptr);

    if (c.vkGetPhysicalDeviceSurfaceFormatsKHR(s.context.physical_device, s.context.surface, &count, fmts) != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to retrieve surface formats", .{});
        return false;
    }
    out_fmt.* = choose_surface_format(fmts, count);

    if (c.vkGetPhysicalDeviceSurfacePresentModesKHR(s.context.physical_device, s.context.surface, &count, null) != c.VK_SUCCESS or count == 0) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to get present modes", .{});
        return false;
    }

    const modes_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkPresentModeKHR) * count);
    if (modes_ptr == null) return false;
    const modes = @as([*]c.VkPresentModeKHR, @ptrCast(@alignCast(modes_ptr)));
    defer memory.cardinal_free(mem_alloc, modes_ptr);

    if (c.vkGetPhysicalDeviceSurfacePresentModesKHR(s.context.physical_device, s.context.surface, &count, modes) != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to retrieve present modes", .{});
        return false;
    }
    out_mode.* = choose_present_mode(modes, count);

    return true;
}

fn select_swapchain_extent(s: *types.VulkanState, caps: *const c.VkSurfaceCapabilitiesKHR) c.VkExtent2D {
    if (caps.currentExtent.width != c.UINT32_MAX) {
        return caps.currentExtent;
    }

    var extent = c.VkExtent2D{ .width = 800, .height = 600 };
    if (s.recovery.window != null) {
        const win = s.recovery.window.?;
        if (win.handle != null) {
            var w: c_int = 0;
            var h: c_int = 0;
            c.glfwGetFramebufferSize(@ptrCast(win.handle), &w, &h);
            extent.width = @intCast(w);
            extent.height = @intCast(h);
        }
    } else if (s.swapchain.window_resize_pending and s.swapchain.pending_width > 0) {
        extent.width = s.swapchain.pending_width;
        extent.height = s.swapchain.pending_height;
    }

    if (extent.width < caps.minImageExtent.width) extent.width = caps.minImageExtent.width;
    if (extent.width > caps.maxImageExtent.width) extent.width = caps.maxImageExtent.width;
    if (extent.height < caps.minImageExtent.height) extent.height = caps.minImageExtent.height;
    if (extent.height > caps.maxImageExtent.height) extent.height = caps.maxImageExtent.height;

    return extent;
}

fn create_swapchain_object(s: *types.VulkanState, caps: *const c.VkSurfaceCapabilitiesKHR, fmt: c.VkSurfaceFormatKHR, mode: c.VkPresentModeKHR, extent: c.VkExtent2D) bool {
    var image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) {
        image_count = caps.maxImageCount;
    }

    log.cardinal_log_info("[SWAPCHAIN] Creating swapchain: {d}x{d}, {d} images, format {d}", .{ extent.width, extent.height, image_count, fmt.format });

    var sci = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
    sci.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    sci.surface = s.context.surface;
    sci.minImageCount = image_count;
    sci.imageFormat = fmt.format;
    sci.imageColorSpace = fmt.colorSpace;
    sci.imageExtent = extent;
    sci.imageArrayLayers = 1;
    sci.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    sci.preTransform = caps.currentTransform;
    sci.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    sci.presentMode = mode;
    sci.clipped = c.VK_TRUE;

    if (s.context.graphics_queue_family != s.context.present_queue_family) {
        var indices = [_]u32{ s.context.graphics_queue_family, s.context.present_queue_family };
        sci.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
        sci.queueFamilyIndexCount = 2;
        sci.pQueueFamilyIndices = &indices;
    } else {
        sci.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    }

    const res = c.vkCreateSwapchainKHR(s.context.device, &sci, null, &s.swapchain.handle);
    if (res != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to create swapchain: {d}", .{res});
        if (res == c.VK_ERROR_DEVICE_LOST) {
            s.recovery.device_lost = true;
        }
        return false;
    }

    s.swapchain.extent = extent;
    s.swapchain.format = fmt.format;
    return true;
}

fn retrieve_swapchain_images(s: *types.VulkanState) bool {
    if (c.vkGetSwapchainImagesKHR(s.context.device, s.swapchain.handle, &s.swapchain.image_count, null) != c.VK_SUCCESS or s.swapchain.image_count == 0) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to get image count", .{});
        return false;
    }

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const images_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkImage) * s.swapchain.image_count);
    if (images_ptr == null) return false;
    s.swapchain.images = @as([*]c.VkImage, @ptrCast(@alignCast(images_ptr)));

    if (c.vkGetSwapchainImagesKHR(s.context.device, s.swapchain.handle, &s.swapchain.image_count, s.swapchain.images.?) != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to get images", .{});
        return false;
    }
    return true;
}

fn create_swapchain_image_views(s: *types.VulkanState) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const views_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkImageView) * s.swapchain.image_count);
    if (views_ptr == null) return false;
    s.swapchain.image_views = @as([*]c.VkImageView, @ptrCast(@alignCast(views_ptr)));

    var i: u32 = 0;
    while (i < s.swapchain.image_count) : (i += 1) {
        s.swapchain.image_views.?[i] = null;
    }

    i = 0;
    while (i < s.swapchain.image_count) : (i += 1) {
        var iv = std.mem.zeroes(c.VkImageViewCreateInfo);
        iv.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        iv.image = s.swapchain.images.?[i];
        iv.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        iv.format = s.swapchain.format;
        iv.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        iv.subresourceRange.levelCount = 1;
        iv.subresourceRange.layerCount = 1;

        if (c.vkCreateImageView(s.context.device, &iv, null, &s.swapchain.image_views.?[i]) != c.VK_SUCCESS) {
            log.cardinal_log_error("[SWAPCHAIN] Failed to create image view {d}", .{i});
            var j: u32 = 0;
            while (j < i) : (j += 1) {
                c.vkDestroyImageView(s.context.device, s.swapchain.image_views.?[j], null);
            }
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(s.swapchain.image_views)));
            s.swapchain.image_views = null;
            return false;
        }
    }
    return true;
}

// Backup state for recreation
const SwapchainBackupState = struct {
    handle: c.VkSwapchainKHR,
    images: ?[*]c.VkImage,
    image_views: ?[*]c.VkImageView,
    image_count: u32,
    extent: c.VkExtent2D,
    format: c.VkFormat,
    layout_initialized: ?[*]bool,
};

fn backup_swapchain_state(s: *types.VulkanState, backup: *SwapchainBackupState) void {
    backup.handle = s.swapchain.handle;
    backup.images = s.swapchain.images;
    backup.image_views = s.swapchain.image_views;
    backup.image_count = s.swapchain.image_count;
    backup.extent = s.swapchain.extent;
    backup.format = s.swapchain.format;
    backup.layout_initialized = s.swapchain.image_layout_initialized;

    s.swapchain.handle = null;
    s.swapchain.images = null;
    s.swapchain.image_views = null;
    s.swapchain.image_count = 0;
    s.swapchain.image_layout_initialized = null;
}

fn restore_swapchain_state(s: *types.VulkanState, backup: *const SwapchainBackupState) void {
    s.swapchain.handle = backup.handle;
    s.swapchain.images = backup.images;
    s.swapchain.image_views = backup.image_views;
    s.swapchain.image_count = backup.image_count;
    s.swapchain.extent = backup.extent;
    s.swapchain.format = backup.format;
    s.swapchain.image_layout_initialized = backup.layout_initialized;
}

fn handle_recreation_failure(s: *types.VulkanState, old_state: *const SwapchainBackupState) bool {
    log.cardinal_log_error("[SWAPCHAIN] Recreation failed", .{});
    s.swapchain.consecutive_recreation_failures += 1;

    // Cleanup new swapchain if it exists
    if (s.swapchain.handle != null) {
        vk_destroy_swapchain(s);
    }
    if (s.swapchain.image_layout_initialized != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, s.swapchain.image_layout_initialized);
        s.swapchain.image_layout_initialized = null;
    }

    // Restore basic state
    s.swapchain.extent = old_state.extent;
    s.swapchain.format = old_state.format;

    // Notify application of recreation failure
    if (s.recovery.device_loss_callback) |cb| {
        cb(s.recovery.callback_user_data);
    }

    return false;
}

fn destroy_backup_resources(s: *types.VulkanState, backup: *const SwapchainBackupState) void {
    if (backup.image_views) |views| {
        var i: u32 = 0;
        while (i < backup.image_count) : (i += 1) {
            if (views[i] != null) {
                c.vkDestroyImageView(s.context.device, views[i], null);
            }
        }
        c.free(@as(?*anyopaque, @ptrCast(views)));
    }
    if (backup.images) |imgs| {
        c.free(@as(?*anyopaque, @ptrCast(imgs)));
    }
    if (backup.handle != null) {
        c.vkDestroySwapchainKHR(s.context.device, backup.handle, null);
    }
    if (backup.layout_initialized) |ptr| {
        c.free(@as(?*anyopaque, @ptrCast(ptr)));
    }
}

fn recreate_mesh_shader_pipeline_logic(s: *types.VulkanState) bool {
    var base: [*c]const u8 = @ptrCast(c.getenv("CARDINAL_SHADERS_DIR"));
    if (base == null or base[0] == 0) {
        base = "assets/shaders";
    }

    var mesh_path: [512]u8 = undefined;
    var task_path: [512]u8 = undefined;
    var frag_path: [512]u8 = undefined;

    _ = c.snprintf(&mesh_path, 512, "%s/mesh.mesh.spv", base);
    _ = c.snprintf(&task_path, 512, "%s/task.task.spv", base);
    _ = c.snprintf(&frag_path, 512, "%s/mesh.frag.spv", base);

    var config = std.mem.zeroes(types.MeshShaderPipelineConfig);
    config.mesh_shader_path = @as(?[*:0]const u8, @ptrCast(&mesh_path));
    config.task_shader_path = @as(?[*:0]const u8, @ptrCast(&task_path));
    config.fragment_shader_path = @as(?[*:0]const u8, @ptrCast(&frag_path));
    config.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    config.polygon_mode = c.VK_POLYGON_MODE_FILL;
    config.cull_mode = c.VK_CULL_MODE_BACK_BIT;
    config.front_face = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
    config.depth_test_enable = true;
    config.depth_write_enable = true;
    config.depth_compare_op = c.VK_COMPARE_OP_LESS;
    config.blend_enable = false;
    config.src_color_blend_factor = c.VK_BLEND_FACTOR_ONE;
    config.dst_color_blend_factor = c.VK_BLEND_FACTOR_ZERO;
    config.color_blend_op = c.VK_BLEND_OP_ADD;
    config.max_vertices_per_meshlet = 64;
    config.max_primitives_per_meshlet = 126;

    if (!vk_mesh_shader.vk_mesh_shader_create_pipeline(@ptrCast(s), &config, s.swapchain.format, s.swapchain.depth_format, @ptrCast(&s.pipelines.mesh_shader_pipeline), null)) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to recreate mesh shader pipeline", .{});
        return false;
    }
    log.cardinal_log_info("[SWAPCHAIN] Mesh shader pipeline recreated successfully", .{});
    return true;
}

// Exported functions

pub export fn vk_create_swapchain(s: ?*types.VulkanState) callconv(.c) bool {
    if (s == null or s.?.context.device == null or s.?.context.physical_device == null or s.?.context.surface == null) {
        log.cardinal_log_error("[SWAPCHAIN] Invalid VulkanState or missing required components", .{});
        return false;
    }
    const vs = s.?;

    if (!wait_device_idle_for_swapchain(vs)) return false;

    var caps: c.VkSurfaceCapabilitiesKHR = undefined;
    var fmt: c.VkSurfaceFormatKHR = undefined;
    var mode: c.VkPresentModeKHR = undefined;

    if (!get_surface_details(vs, &caps, &fmt, &mode)) return false;

    const extent = select_swapchain_extent(vs, &caps);
    if (extent.width == 0 or extent.height == 0) {
        log.cardinal_log_warn("[SWAPCHAIN] Invalid swapchain extent: {d}x{d} (minimized?), skipping creation", .{ extent.width, extent.height });
        return false;
    }

    if (!create_swapchain_object(vs, &caps, fmt, mode, extent)) return false;

    if (!retrieve_swapchain_images(vs)) {
        c.vkDestroySwapchainKHR(vs.context.device, vs.swapchain.handle, null);
        vs.swapchain.handle = null;
        return false;
    }

    if (!create_swapchain_image_views(vs)) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.swapchain.images)));
        vs.swapchain.images = null;
        c.vkDestroySwapchainKHR(vs.context.device, vs.swapchain.handle, null);
        vs.swapchain.handle = null;
        return false;
    }

    vs.swapchain.recreation_pending = false;
    vs.swapchain.last_recreation_time = get_current_time_ms();
    vs.swapchain.recreation_count += 1;
    vs.swapchain.consecutive_recreation_failures = 0;
    vs.swapchain.frame_pacing_enabled = true;

    log.cardinal_log_info("[SWAPCHAIN] Successfully created swapchain with {d} images ({d}x{d})", .{ vs.swapchain.image_count, vs.swapchain.extent.width, vs.swapchain.extent.height });
    return true;
}

pub export fn vk_destroy_swapchain(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    if (vs.swapchain.image_views != null) {
        var i: u32 = 0;
        while (i < vs.swapchain.image_count) : (i += 1) {
            if (vs.swapchain.image_views.?[i] != null) {
                c.vkDestroyImageView(vs.context.device, vs.swapchain.image_views.?[i], null);
            }
        }
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.swapchain.image_views)));
        vs.swapchain.image_views = null;
    }

    if (vs.swapchain.images != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.swapchain.images)));
        vs.swapchain.images = null;
    }

    if (vs.swapchain.handle != null) {
        c.vkDestroySwapchainKHR(vs.context.device, vs.swapchain.handle, null);
        vs.swapchain.handle = null;
    }
}

pub export fn vk_recreate_swapchain(s: ?*types.VulkanState) callconv(.c) bool {
    if (s == null) {
        log.cardinal_log_error("[SWAPCHAIN] Invalid VulkanState for recreation", .{});
        return false;
    }
    const vs = s.?;

    if (vs.context.device == null) {
        log.cardinal_log_error("[SWAPCHAIN] No valid device for swapchain recreation", .{});
        return false;
    }

    if (should_throttle_recreation(vs)) return false;

    log.cardinal_log_info("[SWAPCHAIN] Starting swapchain recreation", .{});

    vs.swapchain.last_recreation_time = get_current_time_ms();

    var backup: SwapchainBackupState = undefined;
    backup_swapchain_state(vs, &backup);

    const t_idle0 = get_current_time_ms();
    const idle_result = c.vkDeviceWaitIdle(vs.context.device);
    const idle_dt = get_current_time_ms() - t_idle0;

    if (idle_dt > 200) {
        log.cardinal_log_warn("[WATCHDOG] Swapchain recreate: device wait idle duration {d} ms", .{idle_dt});
    }

    if (idle_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SWAPCHAIN] Failed to wait for device idle: {d}", .{idle_result});
        if (idle_result == c.VK_ERROR_DEVICE_LOST) {
            log.cardinal_log_error("[SWAPCHAIN] Device lost during recreation wait", .{});
            vs.recovery.device_lost = true;
        }
        restore_swapchain_state(vs, &backup);
        return false;
    }

    vk_pipeline.vk_destroy_pipeline(@ptrCast(vs));

    if (vs.pipelines.use_mesh_shader_pipeline) {
        vk_mesh_shader.vk_mesh_shader_destroy_pipeline(@ptrCast(vs), @ptrCast(&vs.pipelines.mesh_shader_pipeline));
    }

    destroy_backup_resources(vs, &backup);

    if (!vk_create_swapchain(vs)) {
        return handle_recreation_failure(vs, &backup);
    }

    if (!vk_commands.vk_recreate_images_in_flight(@ptrCast(vs))) {
        return handle_recreation_failure(vs, &backup);
    }

    if (!vk_pipeline.vk_create_pipeline(@ptrCast(vs))) {
        return handle_recreation_failure(vs, &backup);
    }

    vs.swapchain.depth_layout_initialized = false;

    if (!vk_simple_pipelines.vk_create_simple_pipelines(vs, null)) {
        return handle_recreation_failure(vs, &backup);
    }

    if (vs.pipelines.use_mesh_shader_pipeline and vs.context.supports_mesh_shader) {
        if (!recreate_mesh_shader_pipeline_logic(vs)) {
            return handle_recreation_failure(vs, &backup);
        }
    }

    vs.swapchain.consecutive_recreation_failures = 0;

    log.cardinal_log_info("[SWAPCHAIN] Successfully recreated swapchain: {d}x{d} -> {d}x{d}", .{ backup.extent.width, backup.extent.height, vs.swapchain.extent.width, vs.swapchain.extent.height });

    if (vs.recovery.recovery_complete_callback) |cb| {
        cb(vs.recovery.callback_user_data, true);
    }

    return true;
}
