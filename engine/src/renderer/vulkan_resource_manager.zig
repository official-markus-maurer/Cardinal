const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("vulkan_resource_manager.h");
    @cInclude("vulkan_state.h");
    @cInclude("cardinal/renderer/vulkan_commands.h");
    @cInclude("cardinal/renderer/vulkan_compute.h");
    @cInclude("cardinal/renderer/vulkan_mesh_shader.h");
    @cInclude("cardinal/renderer/vulkan_pipeline.h");
    @cInclude("cardinal/renderer/vulkan_swapchain.h");
    @cInclude("cardinal/renderer/vulkan_texture_manager.h");
    @cInclude("vulkan_simple_pipelines.h");
    
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
    }
});

pub export fn vulkan_resource_manager_init(manager: ?*c.VulkanResourceManager, vulkan_state: ?*c.VulkanState) callconv(.c) c.VkResult {
    if (manager == null or vulkan_state == null) {
        log.cardinal_log_error("[RESOURCE_MANAGER] Invalid parameters for initialization", .{});
        return c.VK_ERROR_INITIALIZATION_FAILED;
    }
    const mgr = manager.?;
    
    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(c.VulkanResourceManager)], 0);
    mgr.vulkan_state = vulkan_state.?;
    mgr.initialized = true;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Initialized successfully", .{});
    return c.VK_SUCCESS;
}

pub export fn vulkan_resource_manager_destroy(manager: ?*c.VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized) return;

    mgr.vulkan_state = null;
    mgr.initialized = false;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroyed successfully", .{});
}

pub export fn vulkan_resource_manager_destroy_all(manager: ?*c.VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state;

    log.cardinal_log_info("[RESOURCE_MANAGER] Starting complete resource destruction", .{});

    _ = vulkan_resource_manager_wait_idle(mgr);

    vulkan_resource_manager_process_mesh_cleanup(mgr);

    vulkan_resource_manager_destroy_commands_sync(mgr);
    vulkan_resource_manager_destroy_scene(mgr);

    if (s.*.pipelines.compute_shader_initialized) {
        c.vk_compute_cleanup(s);
    }

    vulkan_resource_manager_destroy_pipelines(mgr);
    vulkan_resource_manager_destroy_swapchain_resources(mgr);

    log.cardinal_log_info("[RESOURCE_MANAGER] Complete resource destruction finished", .{});
}

pub export fn vulkan_resource_manager_destroy_scene(manager: ?*c.VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying scene buffers", .{});

    if (s.*.scene_meshes != null) {
        var i: u32 = 0;
        while (i < s.*.scene_mesh_count) : (i += 1) {
            var m = &s.*.scene_meshes[i];
            if (m.vbuf != null) {
                vulkan_resource_manager_destroy_buffer(mgr, m.vbuf, m.vmem);
                m.vbuf = null;
            }
            if (m.ibuf != null) {
                vulkan_resource_manager_destroy_buffer(mgr, m.ibuf, m.imem);
                m.ibuf = null;
            }
        }

        vulkan_resource_manager_free(s.*.scene_meshes);
        s.*.scene_meshes = null;
        s.*.scene_mesh_count = 0;
    }
}

pub export fn vulkan_resource_manager_destroy_pipelines(manager: ?*c.VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying pipelines", .{});

    c.vk_destroy_simple_pipelines(s);

    _ = vulkan_resource_manager_wait_idle(mgr);

    vulkan_resource_manager_process_mesh_cleanup(mgr);

    if (s.*.pending_cleanup_draw_data != null) {
        vulkan_resource_manager_free(s.*.pending_cleanup_draw_data);
        s.*.pending_cleanup_draw_data = null;
        s.*.pending_cleanup_count = 0;
        s.*.pending_cleanup_capacity = 0;
    }

    if (s.*.context.supports_mesh_shader) {
        // vk_mesh_shader_destroy_pipeline
    }

    c.vk_destroy_pipeline(s);
}

pub export fn vulkan_resource_manager_destroy_swapchain_resources(manager: ?*c.VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying swapchain resources", .{});

    c.vk_destroy_swapchain(mgr.vulkan_state);
}

pub export fn vulkan_resource_manager_destroy_commands_sync(manager: ?*c.VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying command buffers and synchronization objects", .{});

    c.vk_destroy_commands_sync(mgr.vulkan_state);
}

pub export fn vulkan_resource_manager_destroy_depth_resources(manager: ?*c.VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying depth resources", .{});

    if (s.*.swapchain.depth_image_view != null) {
        c.vkDestroyImageView(s.*.context.device, s.*.swapchain.depth_image_view, null);
        s.*.swapchain.depth_image_view = null;
    }

    if (s.*.swapchain.depth_image != null) {
        vulkan_resource_manager_destroy_image(mgr, s.*.swapchain.depth_image, s.*.swapchain.depth_image_memory);
        s.*.swapchain.depth_image = null;
        s.*.swapchain.depth_image_memory = null;
    }
}

pub export fn vulkan_resource_manager_destroy_textures(manager: ?*c.VulkanResourceManager, pipeline: ?*c.VulkanPBRPipeline) callconv(.c) void {
    if (manager == null or pipeline == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    log.cardinal_log_debug("[RESOURCE_MANAGER] Destroying texture resources", .{});

    _ = vulkan_resource_manager_wait_idle(mgr);

    if (pipeline.?.textureManager != null) {
        c.vk_texture_manager_destroy(pipeline.?.textureManager);
        vulkan_resource_manager_free(pipeline.?.textureManager);
        pipeline.?.textureManager = null;
    }
}

pub export fn vulkan_resource_manager_destroy_buffer(manager: ?*c.VulkanResourceManager, buffer: c.VkBuffer, memory: c.VkDeviceMemory) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    if (buffer != null) {
        c.vk_allocator_free_buffer(&mgr.vulkan_state.*.allocator, buffer, memory);
    }
}

pub export fn vulkan_resource_manager_destroy_image(manager: ?*c.VulkanResourceManager, image: c.VkImage, memory: c.VkDeviceMemory) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    if (image != null) {
        c.vk_allocator_free_image(&mgr.vulkan_state.*.allocator, image, memory);
    }
}

pub export fn vulkan_resource_manager_destroy_shader_modules(manager: ?*c.VulkanResourceManager, shader_modules: ?[*]c.VkShaderModule, count: u32) callconv(.c) void {
    if (manager == null or shader_modules == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.*.context.device;
    const modules = shader_modules.?;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (modules[i] != null) {
            c.vkDestroyShaderModule(device, modules[i], null);
            modules[i] = null;
        }
    }
}

pub export fn vulkan_resource_manager_destroy_descriptors(manager: ?*c.VulkanResourceManager, pool: c.VkDescriptorPool, layout: c.VkDescriptorSetLayout) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.*.context.device;

    _ = vulkan_resource_manager_wait_idle(mgr);

    if (pool != null) {
        c.vkDestroyDescriptorPool(device, pool, null);
    }

    if (layout != null) {
        c.vkDestroyDescriptorSetLayout(device, layout, null);
    }
}

pub export fn vulkan_resource_manager_destroy_pipeline(manager: ?*c.VulkanResourceManager, pipeline: c.VkPipeline, layout: c.VkPipelineLayout) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.*.context.device;

    if (pipeline != null) {
        c.vkDestroyPipeline(device, pipeline, null);
    }

    if (layout != null) {
        c.vkDestroyPipelineLayout(device, layout, null);
    }
}

pub export fn vulkan_resource_manager_wait_idle(manager: ?*c.VulkanResourceManager) callconv(.c) c.VkResult {
    if (manager == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return c.VK_ERROR_INITIALIZATION_FAILED;

    const result = c.vkDeviceWaitIdle(mgr.vulkan_state.*.context.device);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[RESOURCE_MANAGER] Failed to wait for device idle: {d}", .{result});
    }

    return result;
}

pub export fn vulkan_resource_manager_process_mesh_cleanup(manager: ?*c.VulkanResourceManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const s = mgr.vulkan_state;
    if (s.*.context.supports_mesh_shader) {
        // vk_mesh_shader_process_pending_cleanup(s);
    }
}

pub export fn vulkan_resource_manager_free(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        c.free(p);
    }
}

pub export fn vulkan_resource_manager_destroy_image_views(manager: ?*c.VulkanResourceManager, image_views: ?[*]c.VkImageView, count: u32) callconv(.c) void {
    if (manager == null or image_views == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.*.context.device;
    const views = image_views.?;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (views[i] != null) {
            c.vkDestroyImageView(device, views[i], null);
            views[i] = null;
        }
    }
}

pub export fn vulkan_resource_manager_destroy_command_pools(manager: ?*c.VulkanResourceManager, pools: ?[*]c.VkCommandPool, count: u32) callconv(.c) void {
    if (manager == null or pools == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or mgr.vulkan_state == null) return;

    const device = mgr.vulkan_state.*.context.device;
    const pl = pools.?;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pl[i] != null) {
            c.vkDestroyCommandPool(device, pl[i], null);
            pl[i] = null;
        }
    }
}
