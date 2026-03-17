//! PBR pipeline initialization helpers.
//!
//! Extracts common setup for descriptor and texture managers used by the PBR pipeline.
const std = @import("std");
const memory = @import("../../core/memory.zig");
const descriptor_mgr = @import("../vulkan_descriptor_manager.zig");
const descriptor_init = @import("vulkan_descriptor_init.zig");
const types = @import("../vulkan_types.zig");
const vk_texture_mgr = @import("../vulkan_texture_manager.zig");
const log = @import("../../core/log.zig");
const c = @import("../vulkan_c.zig").c;

const pbr_init_log = log.ScopedLogger("PBR_INIT");

/// Builds and allocates a descriptor manager and per-frame descriptor sets for the PBR pipeline.
pub fn create_pbr_descriptor_manager(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, vulkan_state: ?*types.VulkanState, bindings_map: *std.AutoHashMap(u32, c.VkDescriptorSetLayoutBinding)) bool {
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();

    const prefer_descriptor_buffers = true;
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    if (!descriptor_init.create_descriptor_manager_from_binding_map(renderer_allocator, &pipeline.descriptorManager, device, allocator, vulkan_state, bindings_map, types.MAX_FRAMES_IN_FLIGHT, prefer_descriptor_buffers)) {
        pbr_init_log.err("Failed to create descriptor manager!", .{});
        pipeline.descriptorManager = null;
        return false;
    }

    var sets: [types.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = undefined;
    if (!descriptor_mgr.vk_descriptor_manager_allocate_sets(pipeline.descriptorManager, types.MAX_FRAMES_IN_FLIGHT, &sets)) {
        pbr_init_log.err("Failed to allocate descriptor sets", .{});
        descriptor_mgr.vk_descriptor_manager_destroy(pipeline.descriptorManager);
        memory.cardinal_free(mem_alloc, pipeline.descriptorManager);
        pipeline.descriptorManager = null;
        return false;
    }

    return true;
}

/// Initializes the PBR texture manager, optionally enabling timeline-backed async uploads.
pub fn create_pbr_texture_manager(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, vulkan_state: ?*types.VulkanState) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanTextureManager));
    if (ptr == null) {
        pbr_init_log.err("Failed to allocate texture manager for PBR pipeline", .{});
        return false;
    }
    pipeline.textureManager = @as(*types.VulkanTextureManager, @ptrCast(@alignCast(ptr)));

    var textureConfig = std.mem.zeroes(types.VulkanTextureManagerConfig);
    textureConfig.device = device;
    textureConfig.allocator = allocator;
    textureConfig.commandPool = commandPool;
    textureConfig.graphicsQueue = graphicsQueue;
    textureConfig.syncManager = null;

    if (vulkan_state != null and vulkan_state.?.sync_manager != null and
        vulkan_state.?.sync_manager.?.timeline_semaphore != null)
    {
        textureConfig.syncManager = vulkan_state.?.sync_manager;
    }

    textureConfig.vulkan_state = vulkan_state;
    textureConfig.initialCapacity = 16;

    if (!vk_texture_mgr.vk_texture_manager_init(pipeline.textureManager.?, &textureConfig)) {
        pbr_init_log.err("Failed to initialize texture manager for PBR pipeline", .{});
        memory.cardinal_free(mem_alloc, pipeline.textureManager);
        pipeline.textureManager = null;
        return false;
    }
    return true;
}
