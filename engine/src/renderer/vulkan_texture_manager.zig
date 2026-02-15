const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_types.zig");

const tex_mgr_log = log.ScopedLogger("TEX_MGR");

const c = @import("vulkan_c.zig").c;
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const vk_sync_mgr = @import("vulkan_sync_manager.zig");
const scene = @import("../assets/scene.zig");
const vk_mt = @import("vulkan_mt.zig");
const vk_commands = @import("vulkan_commands.zig");
const vk_descriptor_indexing = @import("vulkan_descriptor_indexing.zig");
const handles = @import("../core/handles.zig");
const ref_counting = @import("../core/ref_counting.zig");
const resource_state = @import("../core/resource_state.zig");
const texture_loader = @import("../assets/texture_loader.zig");
const asset_manager = @import("../assets/asset_manager.zig");

const TextureUploadContext = struct {
    // Input
    allocator: *types.VulkanAllocator,
    device: c.VkDevice,
    texture: *const scene.CardinalTexture,
    managed_texture: *types.VulkanManagedTexture,

    // Output
    staging_buffer: c.VkBuffer,
    staging_memory: c.VkDeviceMemory,
    staging_allocation: c.VmaAllocation,
    secondary_context: types.CardinalSecondaryCommandContext,
    success: bool,
    finished: std.atomic.Value(bool),
};

const AsyncTextureUpdateContext = struct {
    allocator: *types.VulkanAllocator,
    device: c.VkDevice,
    managed_texture: *types.VulkanManagedTexture,

    // Staging resources
    staging_buffer: c.VkBuffer,
    staging_memory: c.VkDeviceMemory,
    staging_allocation: c.VmaAllocation,

    // New texture resources
    new_image: c.VkImage,
    new_memory: c.VkDeviceMemory,
    new_view: c.VkImageView,
    new_allocation: c.VmaAllocation,
    new_sampler: c.VkSampler,

    secondary_context: types.CardinalSecondaryCommandContext,

    // Texture data copy
    texture_data: scene.CardinalTexture,

    finished: std.atomic.Value(bool),
    success: bool,
    next: ?*AsyncTextureUpdateContext,
};

fn update_texture_task(data: ?*anyopaque) callconv(.c) void {
    if (data == null) return;
    const ctx: *AsyncTextureUpdateContext = @ptrCast(@alignCast(data));
    ctx.success = false;

    // Get thread command pool
    const pool = vk_mt.cardinal_mt_get_thread_command_pool(&vk_mt.g_cardinal_mt_subsystem.command_manager);
    if (pool == null) {
        tex_mgr_log.err("Failed to get thread command pool for update task", .{});
        ctx.finished.store(true, .release);
        return;
    }

    // Allocate secondary command buffer
    if (!vk_mt.cardinal_mt_allocate_secondary_command_buffer(pool.?, &ctx.secondary_context)) {
        tex_mgr_log.err("Failed to allocate secondary command buffer for update task", .{});
        ctx.finished.store(true, .release);
        return;
    }

    // Create new image and memory
    var format: c.VkFormat = if (ctx.texture_data.format != 0) @intCast(ctx.texture_data.format) else c.VK_FORMAT_UNDEFINED;
    if (format == c.VK_FORMAT_UNDEFINED) {
        format = if (ctx.texture_data.is_hdr != 0) c.VK_FORMAT_R32G32B32A32_SFLOAT else c.VK_FORMAT_R8G8B8A8_SRGB;
    }
    if (!vk_texture_utils.create_image_and_memory(ctx.allocator, ctx.device, ctx.texture_data.width, ctx.texture_data.height, format, &ctx.new_image, &ctx.new_memory, &ctx.new_allocation)) {
        tex_mgr_log.err("Failed to create new image for update: {d}x{d} fmt={d}", .{ ctx.texture_data.width, ctx.texture_data.height, format });
        ctx.finished.store(true, .release);
        return;
    }

    // Create staging buffer and copy data
    tex_mgr_log.debug("Update texture task: {d}x{d}, Size: {d}, Format: {d}", .{ ctx.texture_data.width, ctx.texture_data.height, ctx.texture_data.data_size, ctx.texture_data.format });
    if (!vk_texture_utils.create_staging_buffer_with_data(ctx.allocator, ctx.device, &ctx.texture_data, &ctx.staging_buffer, &ctx.staging_memory, &ctx.staging_allocation)) {
        tex_mgr_log.err("Failed to create staging buffer for update (Size: {d})", .{ctx.texture_data.data_size});
        ctx.finished.store(true, .release);
        return;
    }

    // Create new view
    if (!vk_texture_utils.create_texture_image_view(ctx.device, ctx.new_image, &ctx.new_view, format)) {
        tex_mgr_log.err("Failed to create new view for update", .{});
        ctx.finished.store(true, .release);
        return;
    }

    // Record copy commands
    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    var inheritance = std.mem.zeroes(c.VkCommandBufferInheritanceInfo);
    inheritance.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO;
    begin_info.pInheritanceInfo = &inheritance;

    if (c.vkBeginCommandBuffer(ctx.secondary_context.command_buffer, &begin_info) != c.VK_SUCCESS) {
        tex_mgr_log.err("Failed to begin secondary command buffer for update", .{});
        ctx.finished.store(true, .release);
        return;
    }

    vk_texture_utils.record_texture_copy_commands(ctx.secondary_context.command_buffer, ctx.staging_buffer, ctx.new_image, ctx.texture_data.width, ctx.texture_data.height);

    if (c.vkEndCommandBuffer(ctx.secondary_context.command_buffer) != c.VK_SUCCESS) {
        tex_mgr_log.err("Failed to end secondary command buffer for update", .{});
        ctx.finished.store(true, .release);
        return;
    }

    ctx.success = true;
    ctx.finished.store(true, .release);
}

fn upload_texture_task(data: ?*anyopaque) callconv(.c) void {
    if (data == null) return;
    const ctx: *TextureUploadContext = @ptrCast(@alignCast(data));
    ctx.success = false;

    // Get thread command pool
    const pool = vk_mt.cardinal_mt_get_thread_command_pool(&vk_mt.g_cardinal_mt_subsystem.command_manager);
    if (pool == null) {
        tex_mgr_log.err("Failed to get thread command pool", .{});
        ctx.finished.store(true, .release);
        return;
    }

    // Allocate secondary command buffer
    if (!vk_mt.cardinal_mt_allocate_secondary_command_buffer(pool.?, &ctx.secondary_context)) {
        tex_mgr_log.err("Failed to allocate secondary command buffer", .{});
        ctx.finished.store(true, .release);
        return;
    }

    // Create staging buffer and copy data
    if (!vk_texture_utils.create_staging_buffer_with_data(ctx.allocator, ctx.device, ctx.texture, &ctx.staging_buffer, &ctx.staging_memory, &ctx.staging_allocation)) {
        tex_mgr_log.err("Failed to create staging buffer", .{});
        ctx.finished.store(true, .release);
        return;
    }

    // Record copy commands
    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    // Secondary command buffers MUST have inheritance info
    var inheritance = std.mem.zeroes(c.VkCommandBufferInheritanceInfo);
    inheritance.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO;
    begin_info.pInheritanceInfo = &inheritance;

    if (c.vkBeginCommandBuffer(ctx.secondary_context.command_buffer, &begin_info) != c.VK_SUCCESS) {
        tex_mgr_log.err("Failed to begin secondary command buffer", .{});
        ctx.finished.store(true, .release);
        return;
    }

    vk_texture_utils.record_texture_copy_commands(ctx.secondary_context.command_buffer, ctx.staging_buffer, ctx.managed_texture.image, ctx.texture.width, ctx.texture.height);

    if (c.vkEndCommandBuffer(ctx.secondary_context.command_buffer) != c.VK_SUCCESS) {
        tex_mgr_log.err("Failed to end secondary command buffer", .{});
        ctx.finished.store(true, .release);
        return;
    }

    ctx.success = true;
    ctx.finished.store(true, .release);
}

pub fn vk_texture_manager_init(manager: *types.VulkanTextureManager, config: *const types.VulkanTextureManagerConfig) bool {
    manager.device = config.device;
    // Get physical device from allocator or vulkan_state
    if (config.allocator.physical_device != null) {
        manager.physicalDevice = config.allocator.physical_device;
    } else if (config.vulkan_state != null) {
        const vs = @as(*types.VulkanState, @ptrCast(@alignCast(config.vulkan_state.?)));
        manager.physicalDevice = vs.context.physical_device;
    } else {
        return false;
    }

    manager.allocator = config.allocator;
    manager.commandPool = config.commandPool;
    manager.graphicsQueue = config.graphicsQueue;
    manager.syncManager = config.syncManager;
    manager.textures = null;
    manager.textureCount = 0;
    manager.textureCapacity = 0;
    manager.hasPlaceholder = false;
    manager.pending_updates = null;
    manager.bindless_pool = std.mem.zeroes(types.BindlessTexturePool);

    // Initialize bindless pool if vulkan_state is available
    if (config.vulkan_state != null) {
        const vs = @as(*types.VulkanState, @ptrCast(@alignCast(config.vulkan_state.?)));

        // Copy vkQueueSubmit2 function pointer
        manager.vkQueueSubmit2 = vs.context.vkQueueSubmit2;

        // Use a large enough capacity for bindless textures (e.g. 4096)
        if (!vk_descriptor_indexing.vk_bindless_texture_pool_init(&manager.bindless_pool, vs, 4096)) {
            tex_mgr_log.err("Failed to initialize bindless texture pool", .{});
            return false;
        }
    }

    // Initialize async upload buffers
    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        var allocInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        allocInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocInfo.commandPool = manager.commandPool;
        allocInfo.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocInfo.commandBufferCount = 1;

        if (c.vkAllocateCommandBuffers(manager.device, &allocInfo, &manager.upload_command_buffers[i]) != c.VK_SUCCESS) {
            tex_mgr_log.err("Failed to allocate upload command buffer {d}", .{i});
            return false;
        }
        manager.upload_fence_values[i] = 0;
    }
    manager.upload_buffer_index = 0;

    return true;
}

pub fn vk_texture_manager_wait_idle(manager: *types.VulkanTextureManager) void {
    var curr_ptr = @as(?*AsyncTextureUpdateContext, @ptrCast(@alignCast(manager.pending_updates)));
    while (curr_ptr) |ctx| {
        while (!ctx.finished.load(.acquire)) {
            if (builtin.os.tag == .windows) {
                c.Sleep(1);
            } else {
                std.atomic.spinLoopHint();
            }
        }
        curr_ptr = ctx.next;
    }
}

pub fn vk_texture_manager_destroy(manager: *types.VulkanTextureManager) void {
    // Wait for and cleanup pending updates
    vk_texture_manager_wait_idle(manager);

    var curr_ptr = @as(?*AsyncTextureUpdateContext, @ptrCast(@alignCast(manager.pending_updates)));
    while (curr_ptr) |ctx| {
        // Cleanup resources
        if (ctx.new_view != null) c.vkDestroyImageView(manager.device, ctx.new_view, null);
        if (ctx.new_image != null) vk_allocator.free_image(manager.allocator, ctx.new_image, ctx.new_allocation);
        if (ctx.staging_buffer != null) vk_allocator.free_buffer(manager.allocator, ctx.staging_buffer, ctx.staging_allocation);

        const next = ctx.next;
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, ctx);

        curr_ptr = next;
    }
    manager.pending_updates = null;

    vk_texture_manager_clear_textures(manager);

    // Destroy placeholder if it exists (index 0)
    if (manager.hasPlaceholder and manager.textures != null) {
        const tex = &manager.textures.?[0];
        if (tex.is_allocated) {
            if (tex.view != null) c.vkDestroyImageView(manager.device, tex.view, null);
            if (tex.sampler != null) c.vkDestroySampler(manager.device, tex.sampler, null);
            if (tex.image != null) vk_allocator.free_image(manager.allocator, tex.image, tex.allocation);
        }
        manager.hasPlaceholder = false;
        manager.textureCount = 0;
    }

    if (manager.textures != null) {
        const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(allocator, manager.textures);
        manager.textures = null;
    }

    vk_descriptor_indexing.vk_bindless_texture_pool_destroy(&manager.bindless_pool);

    // Free upload command buffers
    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        if (manager.upload_command_buffers[i] != null) {
            c.vkFreeCommandBuffers(manager.device, manager.commandPool, 1, &manager.upload_command_buffers[i]);
            manager.upload_command_buffers[i] = null;
        }
    }

    manager.textureCapacity = 0;
}

fn ensure_capacity(manager: *types.VulkanTextureManager, required: u32) bool {
    if (manager.textureCapacity >= required) return true;

    const new_capacity = if (manager.textureCapacity == 0) @max(16, required) else @max(manager.textureCapacity * 2, required);
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);

    // Reallocate
    const old_ptr = manager.textures;
    const new_size = new_capacity * @sizeOf(types.VulkanManagedTexture);
    const new_ptr = memory.cardinal_realloc(allocator, old_ptr, new_size);

    if (new_ptr) |ptr| {
        manager.textures = @as([*]types.VulkanManagedTexture, @ptrCast(@alignCast(ptr)));
        // Zero out the newly allocated portion to prevent garbage data
        const old_size = manager.textureCapacity * @sizeOf(types.VulkanManagedTexture);
        if (new_size > old_size) {
            const diff = new_size - old_size;
            const dest = @as([*]u8, @ptrCast(ptr)) + old_size;
            @memset(dest[0..diff], 0);
        }
        manager.textureCapacity = new_capacity;
        return true;
    }

    return false;
}

pub fn vk_texture_manager_create_placeholder(manager: *types.VulkanTextureManager, out_index: *u32) bool {
    if (manager.hasPlaceholder and manager.textureCount > 0) {
        out_index.* = 0;
        return true;
    }

    if (!ensure_capacity(manager, 1)) return false;

    var tex = &manager.textures.?[0];

    // Create placeholder texture using utils
    if (!vk_texture_utils.vk_texture_create_placeholder(manager.allocator, manager.device, manager.commandPool, manager.graphicsQueue, &tex.image, &tex.memory, &tex.view, &tex.format, &tex.allocation)) {
        return false;
    }

    // Create sampler
    if (!vk_texture_utils.vk_texture_create_sampler(manager.device, manager.physicalDevice, &tex.sampler)) {
        if (tex.view != null) c.vkDestroyImageView(manager.device, tex.view, null);
        if (tex.image != null) vk_allocator.free_image(manager.allocator, tex.image, tex.allocation);
        return false;
    }

    tex.width = 1;
    tex.height = 1;
    tex.channels = 4;
    tex.mip_levels = 1;
    tex.layer_count = 1;
    tex.is_allocated = true;
    tex.isPlaceholder = true;
    tex.path = null;
    tex.bindless_index = 0; // Will be set by bindless system if used
    tex.resource = null;

    // Register placeholder in bindless pool
    if (manager.bindless_pool.textures != null) {
        var bindless_idx: u32 = 0;
        if (vk_descriptor_indexing.vk_bindless_texture_register_existing(&manager.bindless_pool, tex.image, tex.view, tex.sampler, &bindless_idx)) {
            tex.bindless_index = bindless_idx;
            _ = vk_descriptor_indexing.vk_bindless_texture_flush_updates(&manager.bindless_pool);
        }
    }

    manager.textureCount = 1;
    manager.hasPlaceholder = true;
    out_index.* = 0;

    return true;
}

pub fn vk_texture_manager_clear_textures(manager: *types.VulkanTextureManager) void {
    if (manager.textures == null) return;

    // Destroy all textures except placeholder (index 0)
    var i: u32 = 1;
    while (i < manager.textureCount) : (i += 1) {
        const tex = &manager.textures.?[i];
        if (tex.is_allocated) {
            if (tex.view != null) c.vkDestroyImageView(manager.device, tex.view, null);
            if (tex.sampler != null) c.vkDestroySampler(manager.device, tex.sampler, null);
            if (tex.image != null) vk_allocator.free_image(manager.allocator, tex.image, tex.allocation);
        } else {
            // Unallocated textures (fallbacks) might own view/sampler but not image
            if (tex.view != null) c.vkDestroyImageView(manager.device, tex.view, null);
            if (tex.sampler != null) c.vkDestroySampler(manager.device, tex.sampler, null);
        }
    }

    // Reset count to 1 (keep placeholder)
    if (manager.hasPlaceholder) {
        manager.textureCount = 1;
    } else {
        manager.textureCount = 0;
    }
}

pub fn vk_texture_manager_load_scene_textures(manager: *types.VulkanTextureManager, scene_data: ?*const scene.CardinalScene) bool {
    if (scene_data == null) {
        tex_mgr_log.err("Invalid parameters for scene texture loading", .{});
        return false;
    }

    // Clear existing textures (except placeholder)
    vk_texture_manager_clear_textures(manager);

    // Reset bindless pool to free all indices
    // This is safe because we just cleared all textures that were using these indices
    vk_descriptor_indexing.vk_bindless_texture_pool_reset(&manager.bindless_pool);

    // Ensure we have a placeholder texture at index 0
    if (!manager.hasPlaceholder) {
        var placeholder_index: u32 = 0;
        if (!vk_texture_manager_create_placeholder(manager, &placeholder_index)) {
            tex_mgr_log.err("Failed to create placeholder texture", .{});
            return false;
        }
    } else {
        // Re-register existing placeholder (index 0) because we reset the pool
        // manager.textures[0] is still valid from clear_textures logic
        if (manager.textureCount > 0 and manager.bindless_pool.textures != null) {
            const tex = &manager.textures.?[0];
            var bindless_idx: u32 = 0;
            if (vk_descriptor_indexing.vk_bindless_texture_register_existing(&manager.bindless_pool, tex.image, tex.view, tex.sampler, &bindless_idx)) {
                tex.bindless_index = bindless_idx;
                _ = vk_descriptor_indexing.vk_bindless_texture_flush_updates(&manager.bindless_pool);
            } else {
                tex_mgr_log.err("Failed to re-register placeholder texture after pool reset", .{});
            }
        }
    }

    // If no scene textures, we're done (placeholder is sufficient)
    if (scene_data.?.texture_count == 0 or scene_data.?.textures == null) {
        tex_mgr_log.info("No scene textures to load, using placeholder only", .{});
        return true;
    }

    // Ensure capacity for all scene textures
    const required_capacity = scene_data.?.texture_count + 1; // +1 for placeholder
    if (!ensure_capacity(manager, required_capacity)) {
        tex_mgr_log.err("Failed to ensure capacity for {d} textures", .{required_capacity});
        return false;
    }

    // Wait for and cleanup all pending updates to prevent race conditions with pool reset
    var curr_ptr = @as(?*AsyncTextureUpdateContext, @ptrCast(@alignCast(manager.pending_updates)));
    while (curr_ptr) |ctx| {
        // Wait for task completion
        while (!ctx.finished.load(.acquire)) {
            if (builtin.os.tag == .windows) {
                c.Sleep(1);
            } else {
                std.atomic.spinLoopHint();
            }
        }

        // Cleanup resources
        // Note: Contexts are calloc'd so uninitialized fields are null/safe to free
        c.vkDestroyImageView(manager.device, ctx.new_view, null);
        vk_allocator.free_image(manager.allocator, ctx.new_image, ctx.new_allocation);
        vk_allocator.free_buffer(manager.allocator, ctx.staging_buffer, ctx.staging_allocation);

        const next = ctx.next;
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, ctx);

        curr_ptr = next;
    }
    manager.pending_updates = null;

    // Reset command pools to ensure we have enough secondary command buffers
    _ = c.vkDeviceWaitIdle(manager.device);
    vk_mt.cardinal_mt_reset_all_command_pools(&vk_mt.g_cardinal_mt_subsystem.command_manager);

    tex_mgr_log.info("Queueing {d} textures for async streaming...", .{scene_data.?.texture_count});

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const placeholder = &manager.textures.?[0];

    // Initialize all textures as placeholders and queue uploads for those with data
    var tasks_submitted: u32 = 0;
    var i: u32 = 0;
    while (i < scene_data.?.texture_count) : (i += 1) {
        const texture = &scene_data.?.textures.?[i];
        // Texture index maps to manager index i + 1 (0 is placeholder)
        const slot_index = 1 + i;

        // Initialize managed texture
        var tex = &manager.textures.?[slot_index];
        // Ensure struct is zeroed before use
        @memset(@as([*]u8, @ptrCast(tex))[0..@sizeOf(types.VulkanManagedTexture)], 0);

        // Set to placeholder initially
        tex.width = placeholder.width;
        tex.height = placeholder.height;
        tex.channels = placeholder.channels;
        tex.format = placeholder.format;
        tex.isPlaceholder = true;
        tex.is_allocated = false; // Do not own image memory yet
        tex.path = texture.path;
        tex.resource = null;

        // Create view for placeholder image
        if (!vk_texture_utils.create_texture_image_view(manager.device, placeholder.image, &tex.view, placeholder.format)) {
            tex_mgr_log.err("Failed to create fallback view for texture {d}", .{i});
            tex.view = null;
        }

        // Create default sampler
        var sampler_config = std.mem.zeroes(scene.CardinalSampler);
        sampler_config.wrap_s = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        sampler_config.wrap_t = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        sampler_config.min_filter = c.VK_FILTER_LINEAR;
        sampler_config.mag_filter = c.VK_FILTER_LINEAR;
        tex.sampler = create_sampler_from_config(manager.device, &sampler_config);

        if (tex.sampler == null) {
            tex_mgr_log.err("Failed to create sampler for texture {d}", .{i});
        }

        // Check ref resource
        var is_loading_resource = false;
        if (texture.ref_resource) |res| {
            tex.resource = @ptrCast(res);
            // We always start as placeholder on GPU until we upload the real data
            if (res.identifier) |id| {
                const state = resource_state.cardinal_resource_state_get(id);
                if (state != .LOADED) is_loading_resource = true;
            }
        }

        // Use placeholder bindless index
        if (manager.hasPlaceholder) {
            // Assign a new bindless slot for this texture, pointing to the placeholder initially.
            // This ensures each texture has a unique slot that materials can reference.
            // When the real texture loads, we just update this slot.
            var bindless_idx: u32 = 0;
            if (tex.view != null and tex.sampler != null and manager.bindless_pool.textures != null and 
                vk_descriptor_indexing.vk_bindless_texture_register_existing(&manager.bindless_pool, placeholder.image, tex.view, tex.sampler, &bindless_idx)) 
            {
                tex.bindless_index = bindless_idx;
                // No need to flush here, we can flush once at the end or let the system handle it
            } else {
                 tex_mgr_log.err("Failed to allocate bindless slot for texture {d} (View: {any}, Sampler: {any})", .{i, tex.view, tex.sampler});
                 tex.bindless_index = c.UINT32_MAX;
            }
        } else {
            tex.bindless_index = c.UINT32_MAX;
        }

    // Try to set desired format from scene texture if available
    // If it's 0 (undefined), we keep placeholder format for now, but update will pick it up later from AssetManager
    // Actually, we can't easily change tex.format here if it differs from placeholder image format
    // because view/image must match. So we rely on update task to swap image and format.

    // If texture has data, queue an async update immediately
    // Skip if resource is still loading (data points to placeholder)
        if (texture.data != null and texture.width > 0 and texture.height > 0 and !is_loading_resource) {
            // Allocate context for async update
            const ctx_ptr = memory.cardinal_calloc(allocator, 1, @sizeOf(AsyncTextureUpdateContext));
            if (ctx_ptr) |ptr| {
                const ctx = @as(*AsyncTextureUpdateContext, @ptrCast(@alignCast(ptr)));
                ctx.allocator = manager.allocator.?;
                ctx.device = manager.device;
                ctx.managed_texture = tex;
                ctx.texture_data = texture.*; // Copy structure (pointer to data is preserved)

                // If we have a loaded resource, ensure we use its fresh data dimensions/format
                // (Scene texture data might be stale placeholder data if loaded async before scene setup)
                if (texture.ref_resource != null) {
                    const res = @as(*ref_counting.CardinalRefCountedResource, @ptrCast(@alignCast(texture.ref_resource.?)));
                    const res_data = @as(*texture_loader.TextureData, @ptrCast(@alignCast(res.resource.?)));

                    ctx.texture_data.data = res_data.data;
                    ctx.texture_data.width = res_data.width;
                    ctx.texture_data.height = res_data.height;
                    ctx.texture_data.channels = res_data.channels;
                    ctx.texture_data.is_hdr = res_data.is_hdr;
                    // Prefer the scene texture format if it's set (allows overriding SRGB to UNORM for normal maps)
                    // If scene format is 0 (undefined), fall back to resource format
                    ctx.texture_data.format = if (ctx.texture_data.format != 0) ctx.texture_data.format else res_data.format;
                    ctx.texture_data.data_size = res_data.data_size;
                }

                ctx.next = null;
                ctx.finished = std.atomic.Value(bool).init(false);
                ctx.success = false;

                // Allocate task
                const task_ptr = memory.cardinal_alloc(allocator, @sizeOf(types.CardinalMTTask));
                if (task_ptr) |tptr| {
                    const task: *types.CardinalMTTask = @ptrCast(@alignCast(tptr));
                    task.type = types.CardinalMTTaskType.CARDINAL_MT_TASK_COMMAND_RECORD;
                    task.data = ctx;
                    task.execute_func = update_texture_task;
                    task.callback_func = null;
                    task.is_completed = false;
                    task.success = false;
                    task.next = null;

                    if (vk_mt.cardinal_mt_submit_task(task)) {
                        tex.is_updating = true;
                        // Add to pending list (prepend)
                        ctx.next = @ptrCast(@alignCast(manager.pending_updates));
                        manager.pending_updates = ctx;
                        tasks_submitted += 1;
                    } else {
                        tex_mgr_log.err("Failed to submit async texture task for texture {d}", .{i});
                        memory.cardinal_free(allocator, tptr);
                        memory.cardinal_free(allocator, ptr);
                    }
                } else {
                    tex_mgr_log.err("Failed to allocate task for texture {d}", .{i});
                    memory.cardinal_free(allocator, ptr);
                }
            } else {
                tex_mgr_log.err("Failed to allocate context for texture {d}", .{i});
            }
        } else if (texture.data == null and texture.ref_resource == null) {
            tex_mgr_log.warn("Texture {d} has no data and no ref_resource, staying as placeholder", .{i});
        }
    }

    // Update manager count immediately so renderer sees them (as placeholders)
    manager.textureCount = scene_data.?.texture_count + 1;

    // Flush bindless updates if we allocated new slots
    if (manager.bindless_pool.textures != null) {
        _ = vk_descriptor_indexing.vk_bindless_texture_flush_updates(&manager.bindless_pool);
    }

    tex_mgr_log.info("Queued {d} textures for async upload. Scene ready for rendering (with placeholders).", .{tasks_submitted});
    return true;
}

fn create_sampler_from_config(device: c.VkDevice, config: *const scene.CardinalSampler) c.VkSampler {
    var samplerInfo = std.mem.zeroes(c.VkSamplerCreateInfo);
    samplerInfo.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = @intCast(config.mag_filter);
    samplerInfo.minFilter = @intCast(config.min_filter);
    samplerInfo.addressModeU = @intCast(config.wrap_s);
    samplerInfo.addressModeV = @intCast(config.wrap_t); // Casts
    samplerInfo.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.anisotropyEnable = c.VK_TRUE;
    samplerInfo.maxAnisotropy = 16.0;
    samplerInfo.borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    samplerInfo.unnormalizedCoordinates = c.VK_FALSE;
    samplerInfo.compareEnable = c.VK_FALSE;
    samplerInfo.compareOp = c.VK_COMPARE_OP_ALWAYS;
    samplerInfo.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
    samplerInfo.mipLodBias = 0.0;
    samplerInfo.minLod = 0.0;
    samplerInfo.maxLod = 0.0;

    var sampler: c.VkSampler = null;
    if (c.vkCreateSampler(device, &samplerInfo, null, &sampler) != c.VK_SUCCESS) {
        tex_mgr_log.err("Failed to create sampler", .{});
        return null;
    }
    return sampler;
}

pub fn vk_texture_manager_update_textures(manager: *types.VulkanTextureManager) ?u64 {
    if (manager.textures == null) return null;

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    var last_signal_value: ?u64 = null;

    // 1. Process pending updates
    var curr_ptr: ?*AsyncTextureUpdateContext = @ptrCast(@alignCast(manager.pending_updates));

    var head = curr_ptr;
    var prev: ?*AsyncTextureUpdateContext = null;

    var completed_list: ?*AsyncTextureUpdateContext = null;
    var completed_count: u32 = 0;

    while (curr_ptr) |ctx| {
        const next = ctx.next;

        if (ctx.finished.load(.acquire)) {
            // Remove from pending list
            if (prev) |p| {
                p.next = next;
            } else {
                head = next;
            }

            // Add to completed list
            ctx.next = completed_list;
            completed_list = ctx;
            completed_count += 1;

            curr_ptr = next;
        } else {
            prev = curr_ptr;
            curr_ptr = next;
        }
    }
    manager.pending_updates = @ptrCast(@alignCast(head));

    // Batch process completed updates
    if (completed_count > 0) {
        tex_mgr_log.info("Processing {d} completed texture updates...", .{completed_count});
        var submit_success = false;
        var signal_val: u64 = 0;
        var primary_cmd: c.VkCommandBuffer = null;
        var using_reusable = false;
        var reused_index: ?u32 = null;

        // Collect secondary command buffers for successful tasks
        const cmd_bufs_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkCommandBuffer) * completed_count);

        if (cmd_bufs_ptr) |ptr| {
            const bufs = @as([*]c.VkCommandBuffer, @ptrCast(@alignCast(ptr)));
            var valid_count: u32 = 0;

            var iter = completed_list;
            while (iter) |ctx| : (iter = ctx.next) {
                if (ctx.success) {
                    bufs[valid_count] = ctx.secondary_context.command_buffer;
                    valid_count += 1;
                }
            }

            if (valid_count > 0) {
                // Batch completed updates into one primary buffer.
                // Try to find a reusable buffer
                var reusable_cmd: c.VkCommandBuffer = null;

                if (manager.syncManager) |sync| {
                    var gpu_val: u64 = 0;
                    _ = c.vkGetSemaphoreCounterValue(manager.device, sync.timeline_semaphore, &gpu_val);

                    var i: u32 = 0;
                    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
                        const idx = (manager.upload_buffer_index + i) % types.MAX_FRAMES_IN_FLIGHT;
                        if (gpu_val >= manager.upload_fence_values[idx]) {
                            reusable_cmd = manager.upload_command_buffers[idx];
                            reused_index = idx;
                            manager.upload_buffer_index = (idx + 1) % types.MAX_FRAMES_IN_FLIGHT;
                            break;
                        }
                    }
                } else {
                    reusable_cmd = manager.upload_command_buffers[0];
                    reused_index = 0;
                }

                if (reusable_cmd != null) {
                    primary_cmd = reusable_cmd;
                    using_reusable = true;
                    _ = c.vkResetCommandBuffer(primary_cmd, 0);
                } else {
                    var cmd_buf_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
                    cmd_buf_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
                    cmd_buf_info.commandPool = manager.commandPool;
                    cmd_buf_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
                    cmd_buf_info.commandBufferCount = 1;

                    if (c.vkAllocateCommandBuffers(manager.device, &cmd_buf_info, &primary_cmd) != c.VK_SUCCESS) {
                        primary_cmd = null;
                    }
                }

                if (primary_cmd != null) {
                    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
                    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
                    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

                    _ = c.vkBeginCommandBuffer(primary_cmd, &begin_info);
                    c.vkCmdExecuteCommands(primary_cmd, valid_count, bufs);
                    _ = c.vkEndCommandBuffer(primary_cmd);

                    var submit_info = std.mem.zeroes(c.VkSubmitInfo2);
                    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;

                    var cmd_info = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
                    cmd_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
                    cmd_info.commandBuffer = primary_cmd;
                    submit_info.commandBufferInfoCount = 1;
                    submit_info.pCommandBufferInfos = &cmd_info;

                    // Use timeline semaphore to signal completion
                    var signal_info = std.mem.zeroes(c.VkSemaphoreSubmitInfo);

                    if (manager.syncManager) |sync| {
                        signal_val = vk_sync_mgr.vulkan_sync_manager_get_next_timeline_value(sync);
                        signal_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
                        signal_info.semaphore = sync.timeline_semaphore;
                        signal_info.value = signal_val;
                        signal_info.stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
                        submit_info.signalSemaphoreInfoCount = 1;
                        submit_info.pSignalSemaphoreInfos = &signal_info;
                    }

                    // Use loaded function pointer for modern submit
                    if (vk_sync_mgr.vulkan_sync_manager_submit_queue2(manager.graphicsQueue, 1, @ptrCast(&submit_info), null, manager.vkQueueSubmit2) == c.VK_SUCCESS) {
                        submit_success = true;
                        last_signal_value = signal_val;
                    } else {
                        tex_mgr_log.err("vkQueueSubmit2 failed", .{});
                    }
                } else {
                    tex_mgr_log.err("Failed to allocate primary command buffer for async upload batch", .{});
                }
            }
            memory.cardinal_free(mem_alloc, ptr);
        }

        // If no sync manager, wait for the batch to complete before processing cleanups
        if (submit_success and manager.syncManager == null) {
            _ = c.vkQueueWaitIdle(manager.graphicsQueue); // This should also be locked if concurrent
        }

        // Process results for all completed tasks
    var iter = completed_list;
    while (iter) |ctx| {
        const next = ctx.next;

        // Log completion status for debugging
        if (!ctx.success) {
            tex_mgr_log.err("Processing failed task for texture {d}x{d} (fmt: {d})", .{ctx.texture_data.width, ctx.texture_data.height, ctx.texture_data.format});
        }

        // If the batch submit succeeded AND this specific task was successful
            if (submit_success and ctx.success) {
                // Register cleanup for staging buffer and OLD image
                if (manager.syncManager != null) {
                    vk_texture_utils.add_staging_buffer_cleanup(manager.allocator, ctx.staging_buffer, ctx.staging_memory, ctx.staging_allocation, manager.device, signal_val);
                } else {
                    // We have already waited idle above, so we can free immediately.
                    vk_allocator.free_buffer(manager.allocator, ctx.staging_buffer, ctx.staging_allocation);
                }

                // Update managed texture
                const tex = ctx.managed_texture;
                tex_mgr_log.info("Updating texture ptr: {*}, BindlessIndex: {d}", .{tex, tex.bindless_index});

                // Cleanup old placeholder resources
                if (tex.is_allocated) {
                    if (tex.view != null) c.vkDestroyImageView(manager.device, tex.view, null);
                    if (tex.image != null) {
                        if (manager.syncManager != null) {
                            vk_texture_utils.add_image_cleanup(manager.allocator, tex.image, tex.allocation, signal_val);
                        } else {
                            vk_allocator.free_image(manager.allocator, tex.image, tex.allocation);
                        }
                    }
                } else {
                    // Was a placeholder pointing to shared image, but we own the view
                    if (tex.view != null) c.vkDestroyImageView(manager.device, tex.view, null);
                }

                tex.image = ctx.new_image;
                tex.memory = ctx.new_memory;
                tex.view = ctx.new_view;
                tex.allocation = ctx.new_allocation;
                tex.width = ctx.texture_data.width;
                tex.height = ctx.texture_data.height;
                tex.channels = ctx.texture_data.channels;
                tex.isPlaceholder = false;
                tex.is_allocated = true;
                tex.is_updating = false;

                // Register bindless
                if (manager.bindless_pool.textures != null) {
                    var bindless_idx: u32 = 0;
                    var success = false;
                    const old_idx = tex.bindless_index;

                    // Try to update existing slot if valid
                    if (old_idx != c.UINT32_MAX) {
                         if (vk_descriptor_indexing.vk_bindless_texture_update_at_index(&manager.bindless_pool, old_idx, tex.image, tex.view, tex.sampler)) {
                            bindless_idx = old_idx;
                            success = true;
                            tex_mgr_log.info("Async texture upload complete. Updated existing bindless index: {d}", .{old_idx});
                         }
                    }

                    if (!success) {
                        if (tex.sampler != null and vk_descriptor_indexing.vk_bindless_texture_register_existing(&manager.bindless_pool, tex.image, tex.view, tex.sampler, &bindless_idx)) {
                            tex.bindless_index = bindless_idx;
                            success = true;
                            tex_mgr_log.info("Async texture upload complete. Allocated new bindless index: {d} (Old: {d})", .{bindless_idx, old_idx});
                        } else if (tex.sampler == null) {
                            tex_mgr_log.err("Cannot register bindless texture: sampler is null", .{});
                        }
                    }

                    if (success) {
                        _ = vk_descriptor_indexing.vk_bindless_texture_flush_updates(&manager.bindless_pool);
                    } else {
                        tex_mgr_log.err("Failed to register bindless texture after async upload", .{});
                    }
                }
            } else {
                // Task failed OR batch submit failed
                if (ctx.success) {
                    // Task was fine, but submit failed. Need to cleanup new resources.
                    tex_mgr_log.err("Failed to submit async texture upload batch (Error code from submit)", .{});
                } else {
                    tex_mgr_log.err("Async texture task failed execution (check worker logs)", .{});
                }

                c.vkDestroyImageView(manager.device, ctx.new_view, null);
                vk_allocator.free_image(manager.allocator, ctx.new_image, ctx.new_allocation);
                vk_allocator.free_buffer(manager.allocator, ctx.staging_buffer, ctx.staging_allocation);
                // Secondary command buffer belongs to thread pool, do not free here.

                ctx.managed_texture.is_updating = false;
                ctx.managed_texture.update_failed = true; // Mark as failed to prevent loop
                tex_mgr_log.err("Marked texture as failed to update", .{});
            }

            // Free context
            memory.cardinal_free(mem_alloc, ctx);

            iter = next;
        }

        // Cleanup the primary command buffer used for the batch
        if (primary_cmd != null) {
            if (submit_success) {
                if (manager.syncManager != null) {
                    if (using_reusable) {
                        if (reused_index) |idx| {
                            manager.upload_fence_values[idx] = signal_val;
                        }
                    } else {
                        vk_texture_utils.add_command_buffer_cleanup(primary_cmd, manager.commandPool, manager.device, signal_val);
                    }
                } else {
                    // We already waited idle if syncManager is null
                    if (!using_reusable) {
                        c.vkFreeCommandBuffers(manager.device, manager.commandPool, 1, &primary_cmd);
                    }
                }
            } else {
                if (!using_reusable) {
                    c.vkFreeCommandBuffers(manager.device, manager.commandPool, 1, &primary_cmd);
                }
            }
        }
    }

    // 2. Check for new updates
    var i: u32 = 1;
    while (i < manager.textureCount) : (i += 1) {
        var tex = &manager.textures.?[i];

        // Only update if placeholder, has resource, and NOT already updating
        // Also skip if previous update failed to prevent infinite loops
        if (tex.isPlaceholder and tex.resource != null) {
            if (tex.is_updating) {
                // Already updating, skip
                continue;
            }
            if (tex.update_failed) {
                // Previous update failed, skip to avoid loop
                // tex_mgr_log.warn("Skipping texture {d} because update previously failed", .{i});
                continue;
            }

            const res = @as(*ref_counting.CardinalRefCountedResource, @ptrCast(@alignCast(tex.resource.?)));
            const state = if (res.identifier != null) resource_state.cardinal_resource_state_get(res.identifier.?) else .ERROR;

            if (state == .LOADED) {
                tex_mgr_log.info("Texture {d} loaded (id: {s}), queuing async upload", .{ i, if (res.identifier) |id| std.mem.span(id) else "null" });
                const data = @as(*texture_loader.TextureData, @ptrCast(@alignCast(res.resource.?)));
                tex_mgr_log.debug("Reading texture data from {*}: Size={d}, Format={d}", .{ data, data.data_size, data.format });

                // Allocate context
                const ctx_ptr = memory.cardinal_calloc(mem_alloc, 1, @sizeOf(AsyncTextureUpdateContext));
                if (ctx_ptr) |ptr| {
                    const ctx = @as(*AsyncTextureUpdateContext, @ptrCast(@alignCast(ptr)));
                    ctx.allocator = manager.allocator.?;
                    ctx.device = manager.device;
                    ctx.managed_texture = tex;

                    // Copy texture data fields explicitly
                    ctx.texture_data.data = data.data; // Pointer to data in resource
                    ctx.texture_data.width = data.width;
                    ctx.texture_data.height = data.height;
                    ctx.texture_data.channels = data.channels;
                    ctx.texture_data.sampler = std.mem.zeroes(scene.CardinalSampler); // Sampler is not in TextureData, zero it
                    ctx.texture_data.path = null; // Path is not in TextureData
                    ctx.texture_data.ref_resource = null; // Ref resource is not in TextureData
                    ctx.texture_data.is_hdr = data.is_hdr;
                    ctx.texture_data.format = data.format;
                    ctx.texture_data.data_size = data.data_size;

                    // Try to look up desired format from AssetManager (to support UNORM override for normal maps)
                    if (tex.path) |path| {
                        if (asset_manager.get().findTexture(std.mem.span(path))) |scene_tex| {
                            // If scene texture has a specific format (and it's not 0/undefined), use it
                            if (scene_tex.format != 0) {
                                ctx.texture_data.format = scene_tex.format;
                                tex_mgr_log.info("Overriding format for texture {s} to {d} (from scene)", .{ std.mem.span(path), scene_tex.format });
                            }
                        }
                    }

                    ctx.next = null;
                    ctx.finished = std.atomic.Value(bool).init(false);
                    ctx.success = false;

                    // Allocate task separately
                    const task_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.CardinalMTTask));
                    if (task_ptr) |tptr| {
                        const task: *types.CardinalMTTask = @ptrCast(@alignCast(tptr));
                        task.type = types.CardinalMTTaskType.CARDINAL_MT_TASK_COMMAND_RECORD;
                        task.data = ctx;
                        task.execute_func = update_texture_task;
                        task.callback_func = null;
                        task.is_completed = false;
                        task.success = false;
                        task.next = null;

                        if (vk_mt.cardinal_mt_submit_task(task)) {
                            tex.is_updating = true;
                            // Add to pending list (prepend)
                            ctx.next = @ptrCast(@alignCast(manager.pending_updates));
                            manager.pending_updates = ctx;
                        } else {
                            tex_mgr_log.err("Failed to submit async texture task", .{});
                            tex.update_failed = true; // Mark as failed
                            memory.cardinal_free(mem_alloc, tptr);
                            memory.cardinal_free(mem_alloc, ptr);
                        }
                    } else {
                        tex_mgr_log.err("Failed to allocate task for texture update", .{});
                        tex.update_failed = true; // Mark as failed
                        memory.cardinal_free(mem_alloc, ptr);
                    }
                } else {
                    tex_mgr_log.err("Failed to allocate context for texture update", .{});
                    tex.update_failed = true; // Mark as failed
                }
            }
        }
    }

    return last_signal_value;
}
