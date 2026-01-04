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
        tex_mgr_log.err("Failed to get thread command pool", .{});
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    // Allocate secondary command buffer
    if (!vk_mt.cardinal_mt_allocate_secondary_command_buffer(pool.?, &ctx.secondary_context)) {
        tex_mgr_log.err("Failed to allocate secondary command buffer", .{});
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    // Create staging buffer and copy data
    if (!vk_texture_utils.create_staging_buffer_with_data(ctx.allocator, ctx.device, ctx.texture, &ctx.staging_buffer, &ctx.staging_memory, &ctx.staging_allocation)) {
        tex_mgr_log.err("Failed to create staging buffer", .{});
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    // Record copy commands
    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    
    // Fix: Secondary command buffers MUST have inheritance info
    var inheritance = std.mem.zeroes(c.VkCommandBufferInheritanceInfo);
    inheritance.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO;
    begin_info.pInheritanceInfo = &inheritance;

    if (c.vkBeginCommandBuffer(ctx.secondary_context.command_buffer, &begin_info) != c.VK_SUCCESS) {
        tex_mgr_log.err("Failed to begin secondary command buffer", .{});
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    vk_texture_utils.record_texture_copy_commands(ctx.secondary_context.command_buffer, ctx.staging_buffer, ctx.managed_texture.image, ctx.texture.width, ctx.texture.height);

    if (c.vkEndCommandBuffer(ctx.secondary_context.command_buffer) != c.VK_SUCCESS) {
        tex_mgr_log.err("Failed to end secondary command buffer", .{});
        @atomicStore(bool, &ctx.finished, true, .release);
        return;
    }

    ctx.success = true;
    @atomicStore(bool, &ctx.finished, true, .release);
}

// ... (Rest of the file until end of vk_texture_manager_load_scene_textures) ...
// I will rewrite the file to include the new function at the end.

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
    manager.bindless_pool = std.mem.zeroes(types.BindlessTexturePool);

    // Initialize bindless pool if vulkan_state is available
    if (config.vulkan_state != null) {
        const vs = @as(*types.VulkanState, @ptrCast(@alignCast(config.vulkan_state.?)));
        // Use a large enough capacity for bindless textures (e.g. 4096)
        if (!vk_descriptor_indexing.vk_bindless_texture_pool_init(&manager.bindless_pool, vs, 4096)) {
            tex_mgr_log.err("Failed to initialize bindless texture pool", .{});
            return false;
        }
    }

    return true;
}

pub fn vk_texture_manager_destroy(manager: *types.VulkanTextureManager) void {
    vk_texture_manager_clear_textures(manager);

    // Destroy placeholder if it exists (index 0)
    if (manager.hasPlaceholder and manager.textures != null) {
        const tex = &manager.textures.?[0];
        if (tex.is_allocated) {
            if (tex.view != null) c.vkDestroyImageView(manager.device, tex.view, null);
            if (tex.sampler != null) c.vkDestroySampler(manager.device, tex.sampler, null);
            if (tex.image != null) vk_allocator.vk_allocator_free_image(manager.allocator, tex.image, tex.allocation);
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
    if (!vk_texture_utils.vk_texture_create_placeholder(
        manager.allocator, 
        manager.device, 
        manager.commandPool, 
        manager.graphicsQueue, 
        &tex.image, 
        &tex.memory, 
        &tex.view, 
        &tex.format,
        &tex.allocation
    )) {
        return false;
    }

    // Create sampler
    if (!vk_texture_utils.vk_texture_create_sampler(manager.device, manager.physicalDevice, &tex.sampler)) {
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
        if (vk_descriptor_indexing.vk_bindless_texture_register_existing(
            &manager.bindless_pool,
            tex.image,
            tex.view,
            tex.sampler,
            &bindless_idx
        )) {
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
            if (tex.image != null) vk_allocator.vk_allocator_free_image(manager.allocator, tex.image, tex.allocation);
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

    // Ensure we have a placeholder texture at index 0
    if (!manager.hasPlaceholder) {
        var placeholder_index: u32 = 0;
        if (!vk_texture_manager_create_placeholder(manager, &placeholder_index)) {
            tex_mgr_log.err("Failed to create placeholder texture", .{});
            return false;
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

    // Reset command pools to ensure we have enough secondary command buffers
    _ = c.vkDeviceWaitIdle(manager.device);
    vk_mt.cardinal_mt_reset_all_command_pools(&vk_mt.g_cardinal_mt_subsystem.command_manager);

    tex_mgr_log.info("Loading {d} textures from scene (Parallel)", .{scene_data.?.texture_count});

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);

    // Allocate contexts array
    const contexts = memory.cardinal_calloc(allocator, scene_data.?.texture_count, @sizeOf(TextureUploadContext));
    if (contexts == null) {
        tex_mgr_log.err("Failed to allocate texture upload contexts", .{});
        return false;
    }
    const ctx_array = @as([*]TextureUploadContext, @ptrCast(@alignCast(contexts)));

    // Create tasks
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
        
        // Default to placeholder bindless index if available
        // This ensures that if the texture is loading async or fails, it shows the placeholder
        if (manager.hasPlaceholder) {
            tex.bindless_index = manager.textures.?[0].bindless_index;
        } else {
            tex.bindless_index = c.UINT32_MAX;
        }

        tex.path = texture.path;

        // Check ref resource
        if (texture.ref_resource) |res| {
            tex.resource = @ptrCast(res);
            // Check if it's currently loading
            const state = resource_state.cardinal_resource_state_get(res.identifier.?);
            tex.isPlaceholder = (state == .LOADING);
            if (tex.isPlaceholder) {
                tex_mgr_log.info("Texture {d} is loading asynchronously, using placeholder (ref: {*} at {*})", .{i, res, &texture.ref_resource});
            } else {
                tex_mgr_log.debug("Texture {d} is loaded/ready (ref: {*} at {*})", .{i, res, &texture.ref_resource});
            }
        } else {
            tex_mgr_log.warn("Texture {d} has NULL ref_resource (at {*})", .{i, &texture.ref_resource});
            tex.resource = null;
            tex.isPlaceholder = false;
        }

        // Handle async/invalid textures
        if (texture.data == null or texture.width == 0 or texture.height == 0) {
             if (tex.resource != null) {
                 tex_mgr_log.info("Texture {d} is async/pending, initializing as placeholder", .{i});
                 
                 // Create view for placeholder image
                 const placeholder = &manager.textures.?[0];
                 if (!vk_texture_utils.create_texture_image_view(manager.device, placeholder.image, &tex.view, placeholder.format)) {
                      tex_mgr_log.err("Failed to create fallback view for texture {d}", .{i});
                      continue;
                 }
                 
                 // Create default sampler
                 var sampler_config = std.mem.zeroes(scene.CardinalSampler);
                 sampler_config.wrap_s = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
                 sampler_config.wrap_t = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
                 sampler_config.min_filter = c.VK_FILTER_LINEAR;
                 sampler_config.mag_filter = c.VK_FILTER_LINEAR;
                 tex.sampler = create_sampler_from_config(manager.device, &sampler_config);
                 
                 tex.width = placeholder.width;
                 tex.height = placeholder.height;
                 tex.channels = placeholder.channels;
                 tex.format = placeholder.format;
                 tex.isPlaceholder = true;
                 tex.is_allocated = false; // Do not own image memory
                 
                 continue; // Skip upload task
             } else {
                 tex_mgr_log.warn("Skipping invalid texture at index {d}", .{i});
                 continue;
             }
        }

        // Initialize context
        ctx_array[tasks_submitted].allocator = manager.allocator.?;
        ctx_array[tasks_submitted].device = manager.device;
        ctx_array[tasks_submitted].texture = texture;
        ctx_array[tasks_submitted].managed_texture = tex;
        ctx_array[tasks_submitted].finished = false;
        
        const format: c.VkFormat = if (texture.is_hdr) c.VK_FORMAT_R32G32B32A32_SFLOAT else c.VK_FORMAT_R8G8B8A8_SRGB;
        
        if (!vk_texture_utils.create_image_and_memory(manager.allocator, manager.device, texture.width, texture.height, format, &tex.image, &tex.memory, &tex.allocation)) {
             tex_mgr_log.err("Failed to create image for texture {d}", .{i});
             continue;
        }
        
        if (!vk_texture_utils.create_texture_image_view(manager.device, tex.image, &tex.view, format)) {
             tex_mgr_log.err("Failed to create view for texture {d}", .{i});
             continue;
        }
        
        // Sampler
        var sampler_config = std.mem.zeroes(scene.CardinalSampler);
        // Copy sampler config from scene if available, else default
        sampler_config.wrap_s = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        sampler_config.wrap_t = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        sampler_config.min_filter = c.VK_FILTER_LINEAR;
        sampler_config.mag_filter = c.VK_FILTER_LINEAR;
        tex.sampler = create_sampler_from_config(manager.device, &sampler_config);
        
        tex.width = texture.width;
        tex.height = texture.height;
        tex.channels = texture.channels;
        tex.format = format;
        tex.is_allocated = true;
        // tex.isPlaceholder is set above based on resource state

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
                tex_mgr_log.err("Failed to submit texture task {d}", .{i});
                memory.cardinal_free(allocator, ptr);
            }
        }
    }

    // Wait for completion
    tex_mgr_log.info("Waiting for {d} texture upload tasks...", .{tasks_submitted});
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
    
    vk_mt.cardinal_mt_process_completed_tasks(100);

    // Register textures in bindless pool
    if (manager.bindless_pool.textures != null) {
        tex_mgr_log.info("Registering {d} textures in bindless pool...", .{tasks_submitted});
        var k: u32 = 0;
        var registered_count: u32 = 0;
        while (k < tasks_submitted) : (k += 1) {
            const ctx = &ctx_array[k];
            if (ctx.success) {
                var bindless_idx: u32 = 0;
                if (vk_descriptor_indexing.vk_bindless_texture_register_existing(
                    &manager.bindless_pool,
                    ctx.managed_texture.image,
                    ctx.managed_texture.view,
                    ctx.managed_texture.sampler,
                    &bindless_idx
                )) {
                    ctx.managed_texture.bindless_index = bindless_idx;
                    registered_count += 1;
                    // tex_mgr_log.debug("Registered texture {d} at bindless index {d}", .{k, bindless_idx});
                } else {
                    tex_mgr_log.err("Failed to register texture {d} in bindless pool", .{k});
                }
            } else {
                tex_mgr_log.err("Texture upload task {d} failed, skipping bindless registration", .{k});
            }
        }
        tex_mgr_log.info("Registered {d}/{d} textures in bindless pool", .{registered_count, tasks_submitted});
        _ = vk_descriptor_indexing.vk_bindless_texture_flush_updates(&manager.bindless_pool);
    } else {
        tex_mgr_log.err("Bindless pool textures array is NULL! Cannot register textures.", .{});
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
        tex_mgr_log.err("Failed to submit texture upload commands", .{});
        c.vkDestroyFence(manager.device, fence, null);
        c.vkFreeCommandBuffers(manager.device, manager.commandPool, 1, &primary_cmd);
        memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(contexts)));
        return false;
    } else {
        const wait_result = c.vkWaitForFences(manager.device, 1, &fence, c.VK_TRUE, c.UINT64_MAX);
        if (wait_result != c.VK_SUCCESS) {
            tex_mgr_log.err("Failed to wait for texture upload fence: {d}", .{wait_result});
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
            if (!vk_texture_utils.create_texture_image_view(manager.device, placeholder.image, &tex.view, c.VK_FORMAT_R8G8B8A8_SRGB)) {
                log.cardinal_log_error("Failed to create fallback view for texture {d}", .{k});
            }

            // Create sampler (copy of placeholder sampler)
            var default_sampler_config = std.mem.zeroes(scene.CardinalSampler);
            default_sampler_config.wrap_s = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
            default_sampler_config.wrap_t = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
            default_sampler_config.min_filter = c.VK_FILTER_LINEAR;
            default_sampler_config.mag_filter = c.VK_FILTER_LINEAR;
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
            ctx_array[j].staging_buffer = null; // Prevent double free
            ctx_array[j].staging_allocation = null;
        }
    }

    memory.cardinal_free(allocator, @as(?*anyopaque, @ptrCast(contexts)));

    // Reset command pools again
    _ = c.vkDeviceWaitIdle(manager.device);
    vk_mt.cardinal_mt_reset_all_command_pools(&vk_mt.g_cardinal_mt_subsystem.command_manager);

    log.cardinal_log_info("Successfully uploaded {d} textures", .{success_count});
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
    _ = c.vkCreateSampler(device, &samplerInfo, null, &sampler);
    return sampler;
}

pub fn vk_texture_manager_update_textures(manager: *types.VulkanTextureManager) void {
    if (manager.textures == null) return;

    var i: u32 = 1; 
    while (i < manager.textureCount) : (i += 1) {
        var tex = &manager.textures.?[i];
        if (tex.isPlaceholder and tex.resource != null) {
            const res = @as(*ref_counting.CardinalRefCountedResource, @ptrCast(@alignCast(tex.resource.?)));
            const state = if (res.identifier != null) resource_state.cardinal_resource_state_get(res.identifier.?) else .ERROR;
            
            if (state == .LOADED) {
                 tex_mgr_log.debug("Texture {d} loaded (id: {s}), starting upload", .{i, if (res.identifier) |id| std.mem.span(id) else "null"});
                 const data = @as(*texture_loader.TextureData, @ptrCast(@alignCast(res.resource.?)));
                 
                 // Synchronous upload for now (blocking main thread for ~5ms per texture)
                 // This is acceptable compared to blocking for disk IO.
                 
                 var temp_texture = std.mem.zeroes(scene.CardinalTexture);
                 temp_texture.data = data.data;
                 temp_texture.width = data.width;
                 temp_texture.height = data.height;
                 temp_texture.channels = data.channels;
                 temp_texture.is_hdr = data.is_hdr;
                 
                 var new_image: c.VkImage = null;
                 var new_mem: c.VkDeviceMemory = null;
                 var new_view: c.VkImageView = null;
                 var new_alloc: c.VmaAllocation = null;
                 
                 if (vk_texture_utils.vk_texture_create_from_data(
                     manager.allocator,
                     manager.device,
                     manager.commandPool,
                     manager.graphicsQueue,
                     null, // No sync manager = wait idle
                     &temp_texture,
                     &new_image,
                     &new_mem,
                     &new_view,
                     null,
                     &new_alloc
                 )) {
                      // Destroy old placeholder view if we own it
                      if (tex.view != null) {
                          c.vkDestroyImageView(manager.device, tex.view, null);
                      }

                      // Free old placeholder image memory
                      if (tex.is_allocated and tex.image != null) {
                          vk_allocator.vk_allocator_free_image(manager.allocator, tex.image, tex.allocation);
                      }
                      
                      tex.image = new_image;
                      tex.memory = new_mem;
                      tex.view = new_view;
                      tex.allocation = new_alloc;
                      tex.width = data.width;
                      tex.height = data.height;
                      tex.channels = data.channels;
                      tex.isPlaceholder = false;
                      tex.is_allocated = true;
                      
                      // Register bindless
                       if (manager.bindless_pool.textures != null) {
                           var bindless_idx: u32 = 0;
                           if (vk_descriptor_indexing.vk_bindless_texture_register_existing(
                               &manager.bindless_pool,
                               tex.image,
                               tex.view,
                               tex.sampler,
                               &bindless_idx
                           )) {
                               tex.bindless_index = bindless_idx;
                                _ = vk_descriptor_indexing.vk_bindless_texture_flush_updates(&manager.bindless_pool);
                           }
                       }
                       
                       tex_mgr_log.info("Async texture loaded and uploaded: {s}", .{res.identifier.?});
                 }
            }
        }
    }
}
