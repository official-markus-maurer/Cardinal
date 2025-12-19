const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const vk_sync_mgr = @import("vulkan_sync_manager.zig");
const scene = @import("../assets/scene.zig");
const vk_mt = @import("vulkan_mt.zig");
const vk_commands = @import("vulkan_commands.zig");

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
    finished: bool, // Simple flag, read/write should be atomic enough for bool on x86/x64, but better use atomic if possible. For now volatile is okayish or just careful.
};

fn upload_texture_task(data: ?*anyopaque) callconv(.c) void {
    if (data == null) return;
    const ctx: *TextureUploadContext = @ptrCast(@alignCast(data));
    ctx.success = false;

    // Get thread command pool
    const pool = vk_mt.cardinal_mt_get_thread_command_pool(&vk_mt.g_cardinal_mt_subsystem.command_manager);
    if (pool == null) {
        log.cardinal_log_error("Failed to get thread command pool", .{});
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    // Allocate secondary command buffer
    if (!vk_mt.cardinal_mt_allocate_secondary_command_buffer(pool.?, &ctx.secondary_context)) {
        log.cardinal_log_error("Failed to allocate secondary command buffer", .{});
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    // Begin command buffer (manually to avoid RENDER_PASS_CONTINUE_BIT)
    var inheritance_info = std.mem.zeroes(c.VkCommandBufferInheritanceInfo);
    inheritance_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO;
    inheritance_info.renderPass = null;
    inheritance_info.subpass = 0;
    inheritance_info.framebuffer = null;
    inheritance_info.occlusionQueryEnable = c.VK_FALSE;
    inheritance_info.queryFlags = 0;
    inheritance_info.pipelineStatistics = 0;

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    begin_info.pInheritanceInfo = &inheritance_info;

    // Debug log to ensure we are setting inheritance info
    // log.cardinal_log_debug("Starting secondary cmd buffer: {any}, inheritance={*}", .{ctx.secondary_context.command_buffer, begin_info.pInheritanceInfo});

    if (c.vkBeginCommandBuffer(ctx.secondary_context.command_buffer, &begin_info) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to begin secondary command buffer", .{});
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }
    ctx.secondary_context.is_recording = true;

    // Create staging buffer and copy data
    if (!vk_texture_utils.create_staging_buffer_with_data(@ptrCast(ctx.allocator), ctx.device, ctx.texture, &ctx.staging_buffer, &ctx.staging_memory, &ctx.staging_allocation)) {
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    // Create image and memory
    if (!vk_texture_utils.create_image_and_memory(@ptrCast(ctx.allocator), ctx.device, ctx.texture.width, ctx.texture.height, &ctx.managed_texture.image, &ctx.managed_texture.memory, &ctx.managed_texture.allocation)) {
        vk_allocator.vk_allocator_free_buffer(@ptrCast(ctx.allocator), ctx.staging_buffer, ctx.staging_allocation);
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    // Record commands
    vk_texture_utils.record_texture_copy_commands(ctx.secondary_context.command_buffer, ctx.staging_buffer, ctx.managed_texture.image, ctx.texture.width, ctx.texture.height);

    // Create image view
    if (!vk_texture_utils.create_texture_image_view(ctx.device, ctx.managed_texture.image, &ctx.managed_texture.view)) {
        vk_allocator.vk_allocator_free_buffer(@ptrCast(ctx.allocator), ctx.staging_buffer, ctx.staging_allocation);
        vk_allocator.vk_allocator_free_image(@ptrCast(ctx.allocator), ctx.managed_texture.image, ctx.managed_texture.allocation);
        ctx.managed_texture.image = null;
        ctx.managed_texture.memory = null;
        ctx.managed_texture.allocation = null;
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    // Metadata & Sampler
    ctx.managed_texture.width = ctx.texture.width;
    ctx.managed_texture.height = ctx.texture.height;
    ctx.managed_texture.channels = ctx.texture.channels;
    ctx.managed_texture.isPlaceholder = false;

    ctx.managed_texture.sampler = create_sampler_from_config(ctx.device, &ctx.texture.sampler);
    if (ctx.managed_texture.sampler == null) {
        var default_sampler_config = std.mem.zeroes(scene.CardinalSampler);
        default_sampler_config.wrap_s = .REPEAT;
        default_sampler_config.wrap_t = .REPEAT;
        default_sampler_config.min_filter = .LINEAR;
        default_sampler_config.mag_filter = .LINEAR;
        ctx.managed_texture.sampler = create_sampler_from_config(ctx.device, &default_sampler_config);
    }

    // Path copy
    if (ctx.texture.path) |path| {
        const len = c.strlen(path);
        const allocator_cat = memory.cardinal_get_allocator_for_category(.RENDERER);
        const path_copy = memory.cardinal_alloc(allocator_cat, len + 1);
        if (path_copy) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..len], @as([*]const u8, @ptrCast(path))[0..len]);
            @as([*]u8, @ptrCast(ptr))[len] = 0;
            ctx.managed_texture.path = @ptrCast(ptr);
        }
    }

    // End command buffer
    if (c.vkEndCommandBuffer(ctx.secondary_context.command_buffer) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to end secondary command buffer", .{});
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }
    ctx.secondary_context.is_recording = false;

    ctx.success = true;
    @atomicStore(bool, &ctx.finished, true, .release);
}

// Internal helper functions
fn create_default_sampler(manager: *types.VulkanTextureManager) bool {
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

fn ensure_capacity(manager: *types.VulkanTextureManager, required_capacity: u32) bool {
    if (manager.textureCapacity >= required_capacity) {
        return true;
    }

    var new_capacity = manager.textureCapacity;
    while (new_capacity < required_capacity) {
        new_capacity *= 2;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const new_size = new_capacity * @sizeOf(types.VulkanManagedTexture);

    // Using Zig's allocator for reallocation
    // Note: C implementation used realloc. We should try to use cardinal_realloc if possible or just malloc/realloc via C for compatibility if we want.
    // But since we are porting, let's stick to C allocator for now to match the struct expectations or use memory.zig wrappers.
    // memory.zig has cardinal_realloc.

    const new_textures_ptr = memory.cardinal_realloc(allocator, manager.textures, new_size);
    if (new_textures_ptr == null) {
        log.cardinal_log_error("Failed to reallocate texture storage for capacity {d}", .{new_capacity});
        return false;
    }

    const new_textures = @as([*]types.VulkanManagedTexture, @ptrCast(@alignCast(new_textures_ptr)));

    // Initialize new slots
    for (manager.textureCapacity..new_capacity) |i| {
        new_textures[i] = std.mem.zeroes(types.VulkanManagedTexture);
    }

    manager.textures = new_textures;
    manager.textureCapacity = new_capacity;

    log.cardinal_log_debug("Expanded texture capacity to {d}", .{new_capacity});
    return true;
}

fn destroy_texture(manager: *types.VulkanTextureManager, index: u32) void {
    if (index >= manager.textureCount) {
        return;
    }

    // log.cardinal_log_debug("Destroying texture {d}", .{index});
    var texture = &manager.textures.?[index];

    if (texture.view != null) {
        c.vkDestroyImageView(manager.device, texture.view, null);
        texture.view = null;
    }

    if (texture.image != null and texture.memory != null) {
        vk_allocator.vk_allocator_free_image(@ptrCast(manager.allocator), texture.image, texture.allocation);
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

    texture.* = std.mem.zeroes(types.VulkanManagedTexture);
}

fn create_sampler_from_config(device: c.VkDevice, config: *const scene.CardinalSampler) c.VkSampler {
    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;

    // Map filters
    sampler_info.magFilter = if (config.mag_filter == .NEAREST) c.VK_FILTER_NEAREST else c.VK_FILTER_LINEAR;
    sampler_info.minFilter = if (config.min_filter == .NEAREST) c.VK_FILTER_NEAREST else c.VK_FILTER_LINEAR;

    // Map address modes
    var wrap_s = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    if (config.wrap_s == .MIRRORED_REPEAT) {
        wrap_s = c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;
    } else if (config.wrap_s == .CLAMP_TO_EDGE) {
        wrap_s = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    }

    var wrap_t = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    if (config.wrap_t == .MIRRORED_REPEAT) {
        wrap_t = c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;
    } else if (config.wrap_t == .CLAMP_TO_EDGE) {
        wrap_t = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    }

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

    return sampler;
}

// Public API Implementation

pub fn vk_texture_manager_init(manager: *types.VulkanTextureManager, config: ?*const types.VulkanTextureManagerConfig) bool {
    if (config == null) {
        log.cardinal_log_error("Invalid parameters for texture manager initialization", .{});
        return false;
    }

    manager.* = std.mem.zeroes(types.VulkanTextureManager);

    manager.device = config.?.device;
    manager.allocator = config.?.allocator;
    manager.commandPool = config.?.commandPool;
    manager.graphicsQueue = config.?.graphicsQueue;
    manager.syncManager = config.?.syncManager;

    // Initialize texture storage
    const initial_capacity = if (config.?.initialCapacity > 0) config.?.initialCapacity else 16;
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const textures_ptr = memory.cardinal_calloc(allocator, initial_capacity, @sizeOf(types.VulkanManagedTexture));

    if (textures_ptr == null) {
        log.cardinal_log_error("Failed to allocate texture storage", .{});
        return false;
    }

    manager.textures = @as([*]types.VulkanManagedTexture, @ptrCast(@alignCast(textures_ptr)));
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

pub fn vk_texture_manager_destroy(manager: *types.VulkanTextureManager) void {
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
    if (manager.textureCapacity > 0) {
        const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(manager.textures)));
    }

    manager.* = std.mem.zeroes(types.VulkanTextureManager);
    log.cardinal_log_debug("Texture manager destroyed", .{});
}

pub fn vk_texture_manager_load_scene_textures(manager: *types.VulkanTextureManager, scene_data: ?*const scene.CardinalScene) bool {
    if (scene_data == null) {
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
    if (scene_data.?.texture_count == 0 or scene_data.?.textures == null) {
        log.cardinal_log_info("No scene textures to load, using placeholder only", .{});
        return true;
    }

    // Ensure capacity for all scene textures
    const required_capacity = scene_data.?.texture_count + 1; // +1 for placeholder
    if (!ensure_capacity(manager, required_capacity)) {
        log.cardinal_log_error("Failed to ensure capacity for {d} textures", .{required_capacity});
        return false;
    }

    // Reset command pools to ensure we have enough secondary command buffers
    // This prevents "Thread command pool exhausted" errors when loading many textures
    _ = c.vkDeviceWaitIdle(manager.device);
    vk_mt.cardinal_mt_reset_all_command_pools(&vk_mt.g_cardinal_mt_subsystem.command_manager);

    log.cardinal_log_info("Loading {d} textures from scene (Parallel)", .{scene_data.?.texture_count});

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);

    // Allocate contexts array
    const contexts = memory.cardinal_calloc(allocator, scene_data.?.texture_count, @sizeOf(TextureUploadContext));
    if (contexts == null) {
        log.cardinal_log_error("Failed to allocate texture upload contexts", .{});
        return false;
    }
    const ctx_array = @as([*]TextureUploadContext, @ptrCast(@alignCast(contexts)));

    // Create tasks
    var tasks_submitted: u32 = 0;
    var i: u32 = 0;
    while (i < scene_data.?.texture_count) : (i += 1) {
        const texture = &scene_data.?.textures.?[i];

        // Skip invalid textures
        if (texture.data == null or texture.width == 0 or texture.height == 0) {
            continue;
        }

        // Texture index maps to manager index i + 1 (0 is placeholder)
        const slot_index = 1 + i;

        // Initialize context
        ctx_array[tasks_submitted].allocator = manager.allocator.?;
        ctx_array[tasks_submitted].device = manager.device;
        ctx_array[tasks_submitted].texture = texture;
        ctx_array[tasks_submitted].managed_texture = &manager.textures.?[slot_index];
        ctx_array[tasks_submitted].finished = false;

        // Create task
        const task_ptr = memory.cardinal_alloc(allocator, @sizeOf(types.CardinalMTTask));
        if (task_ptr) |ptr| {
            const task: *types.CardinalMTTask = @ptrCast(@alignCast(ptr));
            task.type = types.CardinalMTTaskType.CARDINAL_MT_TASK_COMMAND_RECORD;
            task.data = &ctx_array[tasks_submitted];
            task.execute_func = upload_texture_task;
            task.callback_func = null;
            task.is_completed = false;
            task.success = false;
            task.next = null;

            if (vk_mt.cardinal_mt_submit_task(task)) {
                tasks_submitted += 1;
            } else {
                log.cardinal_log_error("Failed to submit texture task {d}", .{i});
                memory.cardinal_free(allocator, ptr);
            }
        }
    }

    // Wait for completion
    log.cardinal_log_info("Waiting for {d} texture upload tasks...", .{tasks_submitted});
    var finished_count: u32 = 0;
    while (finished_count < tasks_submitted) {
        // Drain completed queue to free task memory
        vk_mt.cardinal_mt_process_completed_tasks(16);

        finished_count = 0;
        var j: u32 = 0;
        while (j < tasks_submitted) : (j += 1) {
            if (@atomicLoad(bool, &ctx_array[j].finished, .acquire)) {
                finished_count += 1;
            }
        }

        if (finished_count < tasks_submitted) {
            if (builtin.os.tag == .windows) {
                c.Sleep(1);
            } else {
                _ = c.usleep(1000);
            }
        }
    }

    // Execute secondary command buffers
    log.cardinal_log_info("Executing texture copy commands...", .{});

    // Allocate primary command buffer
    var cmd_buf_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    cmd_buf_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cmd_buf_info.commandPool = manager.commandPool;
    cmd_buf_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cmd_buf_info.commandBufferCount = 1;

    var primary_cmd: c.VkCommandBuffer = null;
    if (c.vkAllocateCommandBuffers(manager.device, &cmd_buf_info, &primary_cmd) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to allocate primary command buffer for texture upload", .{});
        memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(contexts)));
        return false;
    }

    // Begin primary
    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    _ = c.vkBeginCommandBuffer(primary_cmd, &begin_info);

    // Collect and execute secondary buffers
    var success_count: u32 = 0;
    var j: u32 = 0;
    while (j < tasks_submitted) : (j += 1) {
        if (ctx_array[j].success) {
            c.vkCmdExecuteCommands(primary_cmd, 1, &ctx_array[j].secondary_context.command_buffer);
            success_count += 1;
        }
    }

    _ = c.vkEndCommandBuffer(primary_cmd);

    // Submit
    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &primary_cmd;

    // Fence for wait
    var fence: c.VkFence = null;
    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    _ = c.vkCreateFence(manager.device, &fence_info, null, &fence);

    if (c.vkQueueSubmit(manager.graphicsQueue, 1, &submit_info, fence) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to submit texture upload commands", .{});
        c.vkDestroyFence(manager.device, fence, null);
        c.vkFreeCommandBuffers(manager.device, manager.commandPool, 1, &primary_cmd);
        memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(contexts)));
        return false;
    } else {
        const wait_result = c.vkWaitForFences(manager.device, 1, &fence, c.VK_TRUE, c.UINT64_MAX);
        if (wait_result != c.VK_SUCCESS) {
            log.cardinal_log_error("Failed to wait for texture upload fence: {d}", .{wait_result});
            c.vkDestroyFence(manager.device, fence, null);
            c.vkFreeCommandBuffers(manager.device, manager.commandPool, 1, &primary_cmd);
            memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(contexts)));
            return false;
        }
    }

    c.vkDestroyFence(manager.device, fence, null);
    c.vkFreeCommandBuffers(manager.device, manager.commandPool, 1, &primary_cmd);

    // Update manager count
    manager.textureCount = scene_data.?.texture_count + 1;

    // Check for failed textures and fill with placeholder
    const placeholder = &manager.textures.?[0];
    var k: u32 = 1;
    while (k < manager.textureCount) : (k += 1) {
        var tex = &manager.textures.?[k];
        if (tex.view == null) {
            log.cardinal_log_warn("Texture {d} failed to load or was skipped, using placeholder", .{k});

            // Create view for placeholder image
            if (!vk_texture_utils.create_texture_image_view(manager.device, placeholder.image, &tex.view)) {
                log.cardinal_log_error("Failed to create fallback view for texture {d}", .{k});
                // Critical failure if we can't even create fallback view
            }

            // Create sampler (copy of placeholder sampler)
            var default_sampler_config = std.mem.zeroes(scene.CardinalSampler);
            default_sampler_config.wrap_s = .REPEAT;
            default_sampler_config.wrap_t = .REPEAT;
            default_sampler_config.min_filter = .LINEAR;
            default_sampler_config.mag_filter = .LINEAR;
            tex.sampler = create_sampler_from_config(manager.device, &default_sampler_config);

            tex.image = null; // Do not own image
            tex.memory = null;
            tex.allocation = null;
            tex.isPlaceholder = true;
            tex.width = placeholder.width;
            tex.height = placeholder.height;
            tex.channels = placeholder.channels;
            tex.path = null;
        }
    }

    // Cleanup staging buffers

    j = 0;
    while (j < tasks_submitted) : (j += 1) {
        if (ctx_array[j].staging_buffer != null) {
            vk_allocator.vk_allocator_free_buffer(manager.allocator, ctx_array[j].staging_buffer, ctx_array[j].staging_allocation);
        }
    }

    memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(contexts)));

    // Reset command pools again to free up resources for the renderer
    // The texture loading likely consumed many secondary buffers, which are now finished.
    _ = c.vkDeviceWaitIdle(manager.device);
    vk_mt.cardinal_mt_reset_all_command_pools(&vk_mt.g_cardinal_mt_subsystem.command_manager);

    log.cardinal_log_info("Successfully uploaded {d} textures", .{success_count});
    return true;
}

pub fn vk_texture_manager_load_texture(manager: *types.VulkanTextureManager, texture: ?*const scene.CardinalTexture, out_index: ?*u32, out_timeline_value: *u64) bool {
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
    var managed_texture = &manager.textures.?[index];

    // Use existing texture utility to create the texture
    if (!vk_texture_utils.vk_texture_create_from_data(manager.allocator, manager.device, manager.commandPool, manager.graphicsQueue, manager.syncManager, @ptrCast(texture.?), &managed_texture.image, &managed_texture.memory, &managed_texture.view, out_timeline_value, &managed_texture.allocation)) {
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
        var default_sampler_config = std.mem.zeroes(scene.CardinalSampler);
        default_sampler_config.wrap_s = @enumFromInt(c.CARDINAL_SAMPLER_WRAP_REPEAT);
        default_sampler_config.wrap_t = @enumFromInt(c.CARDINAL_SAMPLER_WRAP_REPEAT);
        default_sampler_config.min_filter = @enumFromInt(c.CARDINAL_SAMPLER_FILTER_LINEAR);
        default_sampler_config.mag_filter = @enumFromInt(c.CARDINAL_SAMPLER_FILTER_LINEAR);
        managed_texture.sampler = create_sampler_from_config(manager.device, &default_sampler_config);
    }

    // Copy path if available
    if (texture.?.path) |path| {
        const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
        const path_len = std.mem.len(path) + 1;
        const path_ptr = memory.cardinal_alloc(allocator, path_len);
        if (path_ptr) |ptr| {
            managed_texture.path = @as([*c]u8, @ptrCast(ptr));
            _ = c.strcpy(managed_texture.path, path);
        }
    } else {
        managed_texture.path = null;
    }

    manager.textureCount += 1;
    out_index.?.* = index;

    const path_str = if (managed_texture.path) |p| std.mem.span(p) else "unknown";
    log.cardinal_log_debug("Loaded texture at index {d}: {d}x{d}, {d} channels ({s})", .{ index, managed_texture.width, managed_texture.height, managed_texture.channels, path_str });

    return true;
}

pub fn vk_texture_manager_create_placeholder(manager: *types.VulkanTextureManager, out_index: ?*u32) bool {
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
    var managed_texture = &manager.textures.?[index];

    // Use existing texture utility to create placeholder
    if (!vk_texture_utils.vk_texture_create_placeholder(manager.allocator, manager.device, manager.commandPool, manager.graphicsQueue, &managed_texture.image, &managed_texture.memory, &managed_texture.view, null, &managed_texture.allocation)) {
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
    var default_sampler_config = std.mem.zeroes(scene.CardinalSampler);
    default_sampler_config.wrap_s = .REPEAT;
    default_sampler_config.wrap_t = .REPEAT;
    default_sampler_config.min_filter = .LINEAR;
    default_sampler_config.mag_filter = .LINEAR;
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

pub fn vk_texture_manager_get_texture(manager: *const types.VulkanTextureManager, index: u32) ?*const types.VulkanManagedTexture {
    if (index >= manager.textureCount) {
        return null;
    }
    return &manager.textures.?[index];
}

pub fn vk_texture_manager_get_default_sampler(manager: ?*const types.VulkanTextureManager) c.VkSampler {
    return if (manager) |m| m.defaultSampler else null;
}

pub fn vk_texture_manager_get_texture_count(manager: ?*const types.VulkanTextureManager) u32 {
    return if (manager) |m| m.textureCount else 0;
}

pub fn vk_texture_manager_get_image_views(manager: *const types.VulkanTextureManager, out_views: [*c]c.VkImageView, max_views: u32) u32 {
    if (out_views == null or max_views == 0) {
        return 0;
    }

    const copy_count = if (manager.textureCount < max_views) manager.textureCount else max_views;

    var i: u32 = 0;
    while (i < copy_count) : (i += 1) {
        out_views[i] = manager.textures.?[i].view;
    }

    return copy_count;
}

pub fn vk_texture_manager_clear_textures(manager: *types.VulkanTextureManager) void {
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
