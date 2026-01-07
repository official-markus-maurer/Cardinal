const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_types.zig");
const vk_simple_pipelines = @import("vulkan_simple_pipelines.zig");
const vk_mesh_shader = @import("vulkan_mesh_shader.zig");
const vk_pipeline = @import("vulkan_pipeline.zig");
const vk_swapchain = @import("vulkan_swapchain.zig");
const vk_commands = @import("vulkan_commands.zig");
const vk_texture_manager = @import("vulkan_texture_manager.zig");
const vk_descriptor_manager = @import("vulkan_descriptor_manager.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const vk_compute = @import("vulkan_compute.zig");

const c = @import("vulkan_c.zig").c;

pub const VulkanResourceManager = extern struct {
    vulkan_state: ?*types.VulkanState,
    initialized: bool,
};

pub export fn vulkan_resource_manager_init(manager: ?*VulkanResourceManager, vulkan_state: ?*types.VulkanState) callconv(.c) c.VkResult {
    if (manager == null or vulkan_state == null) {
        log.cardinal_log_error("[RESOURCE_MANAGER] Invalid parameters for initialization", .{});
        return c.VK_ERROR_INITIALIZATION_FAILED;
    }
    const mgr = manager.?;

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(VulkanResourceManager)], 0);
    mgr.vulkan_state = vulkan_state.?;
    mgr.initialized = true;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Initialized successfully", .{});
    return c.VK_SUCCESS;
}

pub export fn vulkan_resource_manager_destroy(manager: ?*VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized) return;

    mgr.vulkan_state = null;
    mgr.initialized = false;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroyed successfully", .{});
}

pub export fn vulkan_resource_manager_destroy_all(manager: ?*VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state.?;

    log.cardinal_log_info("[RESOURCE_MANAGER] Starting complete resource destruction", .{});

    _ = vulkan_resource_manager_wait_idle(mgr);

    vulkan_resource_manager_process_mesh_cleanup(mgr);

    vulkan_resource_manager_destroy_commands_sync(mgr);
    vulkan_resource_manager_destroy_scene(mgr);

    if (s.pipelines.compute_shader_initialized) {
        vk_compute.vk_compute_cleanup(s);
    }

    vulkan_resource_manager_destroy_pipelines(mgr);
    vulkan_resource_manager_destroy_swapchain_resources(mgr);

    log.cardinal_log_info("[RESOURCE_MANAGER] Complete resource destruction finished", .{});
}

pub export fn vulkan_resource_manager_destroy_scene(manager: ?*VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state.?;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying scene buffers", .{});

    if (s.scene_meshes != null) {
        var i: u32 = 0;
        while (i < s.scene_mesh_count) : (i += 1) {
            var m = &s.scene_meshes.?[i];
            if (m.vbuf != null) {
                vulkan_resource_manager_destroy_buffer(mgr, m.vbuf, m.v_allocation);
                m.vbuf = null;
            }
            if (m.ibuf != null) {
                vulkan_resource_manager_destroy_buffer(mgr, m.ibuf, m.i_allocation);
                m.ibuf = null;
            }
        }

        vulkan_resource_manager_free(s.scene_meshes);
        s.scene_meshes = null;
        s.scene_mesh_count = 0;
    }
}

pub export fn vulkan_resource_manager_destroy_pipelines(manager: ?*VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state.?;

    if (s.pipelines.pbr_pipeline.initialized) {
        log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying PBR pipeline resources", .{});
        vulkan_resource_manager_destroy_textures(manager, &s.pipelines.pbr_pipeline);
        
        // Destroy PBR buffers
        const pbr = &s.pipelines.pbr_pipeline;
        if (pbr.uniformBuffer != null) {
            vulkan_resource_manager_destroy_buffer(manager, pbr.uniformBuffer, pbr.uniformBufferAllocation);
            pbr.uniformBuffer = null;
        }
        if (pbr.lightingBuffer != null) {
            vulkan_resource_manager_destroy_buffer(manager, pbr.lightingBuffer, pbr.lightingBufferAllocation);
            pbr.lightingBuffer = null;
        }
        if (pbr.boneMatricesBuffer != null) {
            vulkan_resource_manager_destroy_buffer(manager, pbr.boneMatricesBuffer, pbr.boneMatricesBufferAllocation);
            pbr.boneMatricesBuffer = null;
        }
        if (pbr.vertexBuffer != null) {
            vulkan_resource_manager_destroy_buffer(manager, pbr.vertexBuffer, pbr.vertexBufferAllocation);
            pbr.vertexBuffer = null;
        }
        if (pbr.indexBuffer != null) {
            vulkan_resource_manager_destroy_buffer(manager, pbr.indexBuffer, pbr.indexBufferAllocation);
            pbr.indexBuffer = null;
        }
        if (pbr.shadowUBO != null) {
             vulkan_resource_manager_destroy_buffer(manager, pbr.shadowUBO, pbr.shadowUBOAllocation);
             pbr.shadowUBO = null;
        }
        
        // Descriptor manager should also be destroyed if it exists
        if (pbr.descriptorManager) |dm| {
             // We need a function to destroy descriptor manager or just free it if it was allocated via cardinal_alloc
             // create_pbr_descriptor_manager allocated it.
             vk_descriptor_manager.vk_descriptor_manager_destroy(dm);
             const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
             memory.cardinal_free(allocator, dm);
             pbr.descriptorManager = null;
        }
    }

    // TODO: Update vk_simple_pipelines to accept types.VulkanState or cast
    vk_simple_pipelines.vk_destroy_simple_pipelines(s);

    _ = vulkan_resource_manager_wait_idle(mgr);

    vk_mesh_shader.vk_mesh_shader_cleanup(s);

    vk_pipeline.vk_destroy_pipeline(s);
}

pub export fn vulkan_resource_manager_destroy_swapchain_resources(manager: ?*VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying swapchain resources", .{});

    vk_swapchain.vk_destroy_swapchain(mgr.vulkan_state.?);
}

pub export fn vulkan_resource_manager_destroy_commands_sync(manager: ?*VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying command buffers and synchronization objects", .{});

    vk_commands.vk_destroy_commands_sync(@ptrCast(mgr.vulkan_state.?));
}

pub export fn vulkan_resource_manager_destroy_depth_resources(manager: ?*VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state.?;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying depth resources", .{});

    if (s.swapchain.depth_image_view != null) {
        c.vkDestroyImageView(s.context.device, s.swapchain.depth_image_view, null);
        s.swapchain.depth_image_view = null;
    }

    if (s.swapchain.depth_image != null) {
        vulkan_resource_manager_destroy_image(mgr, s.swapchain.depth_image, s.swapchain.depth_image_allocation);
        s.swapchain.depth_image = null;
        s.swapchain.depth_image_memory = null;
    }
}

pub export fn vulkan_resource_manager_destroy_textures(manager: ?*VulkanResourceManager, pipeline: ?*types.VulkanPBRPipeline) callconv(.c) void {
    if (manager == null or pipeline == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying texture resources", .{});

    _ = vulkan_resource_manager_wait_idle(mgr);

    if (pipeline.?.textureManager != null) {
        vk_texture_manager.vk_texture_manager_destroy(pipeline.?.textureManager.?);
        vulkan_resource_manager_free(pipeline.?.textureManager);
        pipeline.?.textureManager = null;
    }
}

pub export fn vulkan_resource_manager_destroy_buffer(manager: ?*VulkanResourceManager, buffer: c.VkBuffer, allocation: c.VmaAllocation) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    if (buffer != null) {
        vk_allocator.vk_allocator_free_buffer(&mgr.vulkan_state.?.allocator, buffer, allocation);
    }
}

pub export fn vulkan_resource_manager_destroy_image(manager: ?*VulkanResourceManager, image: c.VkImage, allocation: c.VmaAllocation) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    if (image != null) {
        vk_allocator.vk_allocator_free_image(&mgr.vulkan_state.?.allocator, image, allocation);
    }
}

pub export fn vulkan_resource_manager_destroy_shader_modules(manager: ?*VulkanResourceManager, shader_modules: ?[*]c.VkShaderModule, count: u32) callconv(.c) void {
    if (manager == null or shader_modules == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.?.context.device;
    const modules = shader_modules.?;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (modules[i] != null) {
            c.vkDestroyShaderModule(device, modules[i], null);
            modules[i] = null;
        }
    }
}

pub export fn vulkan_resource_manager_destroy_descriptors(manager: ?*VulkanResourceManager, pool: c.VkDescriptorPool, layout: c.VkDescriptorSetLayout) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.?.context.device;

    _ = vulkan_resource_manager_wait_idle(mgr);

    if (pool != null) {
        c.vkDestroyDescriptorPool(device, pool, null);
    }

    if (layout != null) {
        c.vkDestroyDescriptorSetLayout(device, layout, null);
    }
}

pub export fn vulkan_resource_manager_destroy_pipeline(manager: ?*VulkanResourceManager, pipeline: c.VkPipeline, layout: c.VkPipelineLayout) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.?.context.device;

    if (pipeline != null) {
        c.vkDestroyPipeline(device, pipeline, null);
    }

    if (layout != null) {
        c.vkDestroyPipelineLayout(device, layout, null);
    }
}

pub export fn vulkan_resource_manager_wait_idle(manager: ?*VulkanResourceManager) callconv(.c) c.VkResult {
    if (manager == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return c.VK_ERROR_INITIALIZATION_FAILED;

    const result = c.vkDeviceWaitIdle(mgr.vulkan_state.?.context.device);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[RESOURCE_MANAGER] Failed to wait for device idle: {d}", .{result});
    }

    return result;
}

pub export fn vulkan_resource_manager_process_mesh_cleanup(manager: ?*VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state.?;
    if (s.context.supports_mesh_shader) {
        vk_mesh_shader.vk_mesh_shader_process_pending_cleanup(s);
    }
}

pub export fn vulkan_resource_manager_free(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        c.free(p);
    }
}

pub export fn vulkan_resource_manager_destroy_image_views(manager: ?*VulkanResourceManager, image_views: ?[*]c.VkImageView, count: u32) callconv(.c) void {
    if (manager == null or image_views == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.?.context.device;
    const views = image_views.?;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (views[i] != null) {
            c.vkDestroyImageView(device, views[i], null);
            views[i] = null;
        }
    }
}

pub export fn vulkan_resource_manager_destroy_command_pools(manager: ?*VulkanResourceManager, pools: ?[*]c.VkCommandPool, count: u32) callconv(.c) void {
    if (manager == null or pools == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.?.context.device;
    const pool_array = pools.?;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pool_array[i] != null) {
            c.vkDestroyCommandPool(device, pool_array[i], null);
            pool_array[i] = null;
        }
    }
}
