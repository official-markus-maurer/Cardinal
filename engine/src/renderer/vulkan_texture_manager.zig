const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("cardinal/renderer/vulkan_texture_manager.h");
    @cInclude("cardinal/renderer/util/vulkan_texture_utils.h");
    @cInclude("vulkan_state.h");
});

// Internal helper functions
fn create_default_sampler(manager: *c.VulkanTextureManager) bool {
    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_info.magFilter = c.VK_FILTER_LINEAR;
    sampler_info.minFilter = c.VK_FILTER_LINEAR;
    sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.anisotropyEnable = c.VK_FALSE;
    sampler_info.maxAnisotropy = 1.0;
    sampler_info.borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    sampler_info.unnormalizedCoordinates = c.VK_FALSE;
    sampler_info.compareEnable = c.VK_FALSE;
    sampler_info.compareOp = c.VK_COMPARE_OP_ALWAYS;
    sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
    sampler_info.mipLodBias = 0.0;
    sampler_info.minLod = 0.0;
    sampler_info.maxLod = 0.0;

    if (c.vkCreateSampler(manager.device, &sampler_info, null, &manager.defaultSampler) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create default texture sampler", .{});
        return false;
    }

    log.cardinal_log_debug("Default texture sampler created: handle={any}", .{manager.defaultSampler});
    return true;
}

fn ensure_capacity(manager: *c.VulkanTextureManager, required_capacity: u32) bool {
    if (manager.textureCapacity >= required_capacity) {
        return true;
    }

    var new_capacity = manager.textureCapacity;
    while (new_capacity < required_capacity) {
        new_capacity *= 2;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const new_size = new_capacity * @sizeOf(c.VulkanManagedTexture);
    
    // Using Zig's allocator for reallocation
    // Note: C implementation used realloc. We should try to use cardinal_realloc if possible or just malloc/realloc via C for compatibility if we want.
    // But since we are porting, let's stick to C allocator for now to match the struct expectations or use memory.zig wrappers.
    // memory.zig has cardinal_realloc.
    
    const new_textures_ptr = memory.cardinal_realloc(allocator, manager.textures, new_size);
    if (new_textures_ptr == null) {
        log.cardinal_log_error("Failed to reallocate texture storage for capacity {d}", .{new_capacity});
        return false;
    }

    const new_textures = @as([*]c.VulkanManagedTexture, @ptrCast(@alignCast(new_textures_ptr)));

    // Initialize new slots
    var i: u32 = manager.textureCapacity;
    while (i < new_capacity) : (i += 1) {
        new_textures[i] = std.mem.zeroes(c.VulkanManagedTexture);
    }

    manager.textures = new_textures;
    manager.textureCapacity = new_capacity;

    log.cardinal_log_debug("Expanded texture capacity to {d}", .{new_capacity});
    return true;
}

fn destroy_texture(manager: *c.VulkanTextureManager, index: u32) void {
    if (index >= manager.textureCount) {
        return;
    }

    // log.cardinal_log_debug("Destroying texture {d}", .{index});
    var texture = &manager.textures[index];

    if (texture.view != null) {
        c.vkDestroyImageView(manager.device, texture.view, null);
        texture.view = null;
    }

    if (texture.image != null and texture.memory != null) {
        c.vk_allocator_free_image(manager.allocator, texture.image, texture.memory);
        texture.image = null;
        texture.memory = null;
    }

    if (texture.path != null) {
        const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(texture.path)));
        texture.path = null;
    }

    if (texture.sampler != null) {
        c.vkDestroySampler(manager.device, texture.sampler, null);
        texture.sampler = null;
    }
    
    texture.* = std.mem.zeroes(c.VulkanManagedTexture);
}

fn create_sampler_from_config(device: c.VkDevice, config: *const c.CardinalSampler) c.VkSampler {
    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    
    // Map filters
    sampler_info.magFilter = if (config.mag_filter == c.CARDINAL_SAMPLER_FILTER_NEAREST) c.VK_FILTER_NEAREST else c.VK_FILTER_LINEAR;
    sampler_info.minFilter = if (config.min_filter == c.CARDINAL_SAMPLER_FILTER_NEAREST) c.VK_FILTER_NEAREST else c.VK_FILTER_LINEAR;

    // Map address modes
    // Force REPEAT even if CLAMP_TO_EDGE is requested, to fix asset export issues (matching C code comment)
    var wrap_s = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    if (config.wrap_s == c.CARDINAL_SAMPLER_WRAP_MIRRORED_REPEAT) wrap_s = c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;

    var wrap_t = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    if (config.wrap_t == c.CARDINAL_SAMPLER_WRAP_MIRRORED_REPEAT) wrap_t = c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;

    sampler_info.addressModeU = @intCast(wrap_s);
    sampler_info.addressModeV = @intCast(wrap_t);
    sampler_info.addressModeW = @intCast(c.VK_SAMPLER_ADDRESS_MODE_REPEAT); // Usually not used for 2D textures

    sampler_info.anisotropyEnable = c.VK_FALSE;
    sampler_info.maxAnisotropy = 1.0;
    sampler_info.borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    sampler_info.unnormalizedCoordinates = c.VK_FALSE;
    sampler_info.compareEnable = c.VK_FALSE;
    sampler_info.compareOp = c.VK_COMPARE_OP_ALWAYS;
    sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
    sampler_info.mipLodBias = 0.0;
    sampler_info.minLod = 0.0;
    sampler_info.maxLod = c.VK_LOD_CLAMP_NONE;

    var sampler: c.VkSampler = null;
    if (c.vkCreateSampler(device, &sampler_info, null, &sampler) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create texture sampler", .{});
        return null;
    }

    log.cardinal_log_debug("Created sampler: handle={any}, addrU={d}, addrV={d}, min={d}, mag={d}",
        .{sampler, sampler_info.addressModeU, sampler_info.addressModeV, sampler_info.minFilter, sampler_info.magFilter});

    return sampler;
}

// Public API Implementation

pub export fn vk_texture_manager_init(manager: *c.VulkanTextureManager, config: ?*const c.VulkanTextureManagerConfig) callconv(.c) bool {
    if (config == null) {
        log.cardinal_log_error("Invalid parameters for texture manager initialization", .{});
        return false;
    }

    manager.* = std.mem.zeroes(c.VulkanTextureManager);

    manager.device = config.?.device;
    manager.allocator = config.?.allocator;
    manager.commandPool = config.?.commandPool;
    manager.graphicsQueue = config.?.graphicsQueue;
    manager.syncManager = config.?.syncManager;

    // Initialize texture storage
    const initial_capacity = if (config.?.initialCapacity > 0) config.?.initialCapacity else 16;
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const textures_ptr = memory.cardinal_calloc(allocator, initial_capacity, @sizeOf(c.VulkanManagedTexture));
    
    if (textures_ptr == null) {
        log.cardinal_log_error("Failed to allocate texture storage", .{});
        return false;
    }
    
    manager.textures = @as([*]c.VulkanManagedTexture, @ptrCast(@alignCast(textures_ptr)));
    manager.textureCapacity = initial_capacity;
    manager.textureCount = 0;
    manager.hasPlaceholder = false;

    // Create default sampler
    if (!create_default_sampler(manager)) {
        log.cardinal_log_error("Failed to create default sampler", .{});
        memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(manager.textures)));
        return false;
    }

    // Always create a placeholder texture at index 0 to ensure valid descriptors
    var placeholder_index: u32 = 0;
    if (!vk_texture_manager_create_placeholder(manager, &placeholder_index)) {
        log.cardinal_log_error("Failed to create default placeholder texture", .{});
        c.vkDestroySampler(manager.device, manager.defaultSampler, null);
        memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(manager.textures)));
        return false;
    }
    manager.hasPlaceholder = true;

    log.cardinal_log_info("Texture manager initialized with capacity {d} and default placeholder", .{initial_capacity});
    return true;
}

pub export fn vk_texture_manager_destroy(manager: *c.VulkanTextureManager) callconv(.c) void {
    // Destroy all textures
    var i: u32 = 0;
    while (i < manager.textureCount) : (i += 1) {
        destroy_texture(manager, i);
    }

    // Destroy default sampler
    if (manager.defaultSampler != null) {
        c.vkDestroySampler(manager.device, manager.defaultSampler, null);
        manager.defaultSampler = null;
    }

    // Free texture storage
    if (manager.textures != null) {
        const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(manager.textures)));
        manager.textures = null;
    }

    manager.* = std.mem.zeroes(c.VulkanTextureManager);
    log.cardinal_log_debug("Texture manager destroyed", .{});
}

fn load_single_scene_texture(manager: *c.VulkanTextureManager, scene: *const c.CardinalScene, index: u32, successful_uploads: *u32, max_timeline_value: *u64) void {
    const texture = &scene.textures[index];
    var texture_index: u32 = 0;

    // Skip invalid textures and create placeholder for them
    if (texture.data == null or texture.width == 0 or texture.height == 0) {
        const path = if (texture.path != null) std.mem.span(texture.path) else "unknown";
        log.cardinal_log_warn("Skipping invalid texture {d} ({s}) - using placeholder", .{index, path});
        return;
    }

    const path = if (texture.path != null) std.mem.span(texture.path) else "unknown";
    log.cardinal_log_info("Uploading texture {d}: {d}x{d}, {d} channels ({s})", .{index, texture.width, texture.height, texture.channels, path});

    var timeline_value: u64 = 0;
    if (vk_texture_manager_load_texture(manager, texture, &texture_index, &timeline_value)) {
        successful_uploads.* += 1;
        if (timeline_value > max_timeline_value.*) {
            max_timeline_value.* = timeline_value;
        }
    } else {
        log.cardinal_log_error("Failed to upload texture {d} ({s}) - creating placeholder", .{index, path});
        // Create a placeholder texture for the failed upload to maintain texture array consistency
        var placeholder_index: u32 = 0;
        if (vk_texture_manager_create_placeholder(manager, &placeholder_index)) {
            log.cardinal_log_info("Created placeholder texture at index {d} for failed texture {d}", .{placeholder_index, index});
        } else {
            log.cardinal_log_error("Failed to create placeholder for failed texture {d}", .{index});
        }
    }
}

pub export fn vk_texture_manager_load_scene_textures(manager: *c.VulkanTextureManager, scene: ?*const c.CardinalScene) callconv(.c) bool {
    if (scene == null) {
        log.cardinal_log_error("Invalid parameters for scene texture loading", .{});
        return false;
    }

    // Clear existing textures (except placeholder)
    vk_texture_manager_clear_textures(manager);

    // Ensure we have a placeholder texture at index 0
    if (!manager.hasPlaceholder) {
        var placeholder_index: u32 = 0;
        if (!vk_texture_manager_create_placeholder(manager, &placeholder_index)) {
            log.cardinal_log_error("Failed to create placeholder texture", .{});
            return false;
        }
    }

    // If no scene textures, we're done (placeholder is sufficient)
    if (scene.?.texture_count == 0 or scene.?.textures == null) {
        log.cardinal_log_info("No scene textures to load, using placeholder only", .{});
        return true;
    }

    // Ensure capacity for all scene textures
    const required_capacity = scene.?.texture_count + 1; // +1 for placeholder
    if (!ensure_capacity(manager, required_capacity)) {
        log.cardinal_log_error("Failed to ensure capacity for {d} textures", .{required_capacity});
        return false;
    }

    log.cardinal_log_info("Loading {d} textures from scene", .{scene.?.texture_count});

    var successful_uploads: u32 = 0;
    var max_timeline_value: u64 = 0;

    // Load scene textures starting from index 1 (index 0 is placeholder)
    var i: u32 = 0;
    while (i < scene.?.texture_count) : (i += 1) {
        load_single_scene_texture(manager, scene.?, i, &successful_uploads, &max_timeline_value);
    }

    log.cardinal_log_info("Texture loading phase completed. Max timeline value: {d}", .{max_timeline_value});

    // Check if we encountered device loss during uploads
    const device_status = c.vkDeviceWaitIdle(manager.device);
    if (device_status != c.VK_SUCCESS) {
        log.cardinal_log_error("Device status check failed after texture loading: {d}", .{device_status});
    }

    if (successful_uploads < scene.?.texture_count) {
        log.cardinal_log_warn("Uploaded {d}/{d} textures (some failed)", .{successful_uploads, scene.?.texture_count});
    } else {
        log.cardinal_log_info("Successfully uploaded all {d} textures", .{successful_uploads});
    }

    return true;
}

pub export fn vk_texture_manager_load_texture(manager: *c.VulkanTextureManager, texture: ?*const c.CardinalTexture, out_index: ?*u32, out_timeline_value: *u64) callconv(.c) bool {
    if (texture == null or out_index == null) {
        log.cardinal_log_error("Invalid parameters for texture loading", .{});
        return false;
    }

    // Ensure capacity
    if (!ensure_capacity(manager, manager.textureCount + 1)) {
        log.cardinal_log_error("Failed to ensure capacity for new texture", .{});
        return false;
    }

    const index = manager.textureCount;
    var managed_texture = &manager.textures[index];

    // Use existing texture utility to create the texture
    if (!c.vk_texture_create_from_data(manager.allocator, manager.device, manager.commandPool,
                                     manager.graphicsQueue, manager.syncManager, texture.?,
                                     &managed_texture.image, &managed_texture.memory,
                                     &managed_texture.view, out_timeline_value)) {
        log.cardinal_log_error("Failed to create texture from data", .{});
        return false;
    }

    // Store texture metadata
    managed_texture.width = texture.?.width;
    managed_texture.height = texture.?.height;
    managed_texture.channels = texture.?.channels;
    managed_texture.isPlaceholder = false;

    // Create sampler based on configuration
    managed_texture.sampler = create_sampler_from_config(manager.device, &texture.?.sampler);
    if (managed_texture.sampler == null) {
        log.cardinal_log_error("Failed to create sampler for texture {d} - using default", .{index});
        // Let's create a default sampler copy to keep ownership consistent
        var default_sampler_config = std.mem.zeroes(c.CardinalSampler);
        default_sampler_config.wrap_s = c.CARDINAL_SAMPLER_WRAP_REPEAT;
        default_sampler_config.wrap_t = c.CARDINAL_SAMPLER_WRAP_REPEAT;
        default_sampler_config.min_filter = c.CARDINAL_SAMPLER_FILTER_LINEAR;
        default_sampler_config.mag_filter = c.CARDINAL_SAMPLER_FILTER_LINEAR;
        managed_texture.sampler = create_sampler_from_config(manager.device, &default_sampler_config);
    }

    // Copy path if available
    if (texture.?.path != null) {
        const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
        const path_len = std.mem.len(texture.?.path) + 1;
        const path_ptr = memory.cardinal_alloc(allocator, path_len);
        if (path_ptr) |ptr| {
            managed_texture.path = @as([*c]u8, @ptrCast(ptr));
            _ = c.strcpy(managed_texture.path, texture.?.path);
        }
    } else {
        managed_texture.path = null;
    }

    manager.textureCount += 1;
    out_index.?.* = index;

    const path_str = if (managed_texture.path != null) std.mem.span(managed_texture.path) else "unknown";
    log.cardinal_log_debug("Loaded texture at index {d}: {d}x{d} ({s})", .{index, managed_texture.width, managed_texture.height, path_str});

    return true;
}

pub export fn vk_texture_manager_create_placeholder(manager: *c.VulkanTextureManager, out_index: ?*u32) callconv(.c) bool {
    if (out_index == null) {
        log.cardinal_log_error("Invalid parameters for placeholder creation", .{});
        return false;
    }

    // Ensure capacity
    if (!ensure_capacity(manager, manager.textureCount + 1)) {
        log.cardinal_log_error("Failed to ensure capacity for placeholder texture", .{});
        return false;
    }

    const index = manager.textureCount;
    var managed_texture = &manager.textures[index];

    // Use existing texture utility to create placeholder
    if (!c.vk_texture_create_placeholder(manager.allocator, manager.device, manager.commandPool,
                                       manager.graphicsQueue, &managed_texture.image,
                                       &managed_texture.memory, &managed_texture.view, null)) {
        log.cardinal_log_error("Failed to create placeholder texture", .{});
        return false;
    }

    // Store placeholder metadata
    managed_texture.width = 1;
    managed_texture.height = 1;
    managed_texture.channels = 4;
    managed_texture.isPlaceholder = true;
    managed_texture.path = null;

    // Create default sampler for placeholder
    var default_sampler_config = std.mem.zeroes(c.CardinalSampler);
    default_sampler_config.wrap_s = c.CARDINAL_SAMPLER_WRAP_REPEAT;
    default_sampler_config.wrap_t = c.CARDINAL_SAMPLER_WRAP_REPEAT;
    default_sampler_config.min_filter = c.CARDINAL_SAMPLER_FILTER_LINEAR;
    default_sampler_config.mag_filter = c.CARDINAL_SAMPLER_FILTER_LINEAR;
    managed_texture.sampler = create_sampler_from_config(manager.device, &default_sampler_config);

    manager.textureCount += 1;
    out_index.?.* = index;

    // Mark that we have at least one placeholder
    if (index == 0) {
        manager.hasPlaceholder = true;
    }

    log.cardinal_log_debug("Created placeholder texture at index {d}", .{index});
    return true;
}

pub export fn vk_texture_manager_get_texture(manager: *const c.VulkanTextureManager, index: u32) callconv(.c) ?*const c.VulkanManagedTexture {
    if (index >= manager.textureCount) {
        return null;
    }
    return &manager.textures[index];
}

pub export fn vk_texture_manager_get_default_sampler(manager: ?*const c.VulkanTextureManager) callconv(.c) c.VkSampler {
    return if (manager) |m| m.defaultSampler else null;
}

pub export fn vk_texture_manager_get_texture_count(manager: ?*const c.VulkanTextureManager) callconv(.c) u32 {
    return if (manager) |m| m.textureCount else 0;
}

pub export fn vk_texture_manager_get_image_views(manager: *const c.VulkanTextureManager, out_views: [*c]c.VkImageView, max_views: u32) callconv(.c) u32 {
    if (out_views == null or max_views == 0) {
        return 0;
    }

    const copy_count = if (manager.textureCount < max_views) manager.textureCount else max_views;

    var i: u32 = 0;
    while (i < copy_count) : (i += 1) {
        out_views[i] = manager.textures[i].view;
    }

    return copy_count;
}

pub export fn vk_texture_manager_clear_textures(manager: *c.VulkanTextureManager) callconv(.c) void {
    // Destroy all textures except placeholder (if it exists)
    const start_index: u32 = if (manager.hasPlaceholder) 1 else 0;

    var i: u32 = start_index;
    while (i < manager.textureCount) : (i += 1) {
        destroy_texture(manager, i);
    }

    // Reset count but keep placeholder
    manager.textureCount = if (manager.hasPlaceholder) 1 else 0;

    log.cardinal_log_debug("Cleared textures, keeping {d} textures", .{manager.textureCount});
}
