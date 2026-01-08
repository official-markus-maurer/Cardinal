const std = @import("std");
const memory = @import("../core/memory.zig");
const descriptor_mgr = @import("vulkan_descriptor_manager.zig");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const log = @import("../core/log.zig");
const vk_pipeline = @import("vulkan_pipeline.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");
const shader_utils = @import("util/vulkan_shader_utils.zig");
const texture_loader = @import("../assets/texture_loader.zig");
const math = @import("../core/math.zig");
const scene = @import("../assets/scene.zig");
const ref_counting = @import("../core/ref_counting.zig");
const resource_state = @import("../core/resource_state.zig");
const vk_pso = @import("vulkan_pso.zig");

const skybox_log = log.ScopedLogger("SKYBOX");

pub const SkyboxPushConstants = extern struct {
    view: math.Mat4,
    proj: math.Mat4,
};

pub fn vk_skybox_pipeline_init(pipeline: *types.SkyboxPipeline, device: c.VkDevice, format: c.VkFormat, depthFormat: c.VkFormat, allocator: *types.VulkanAllocator, vulkan_state: ?*types.VulkanState) bool {
    pipeline.initialized = false;
    
    // Create Descriptor Manager
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (ptr == null) {
        skybox_log.err("Failed to allocate memory for skybox descriptor manager", .{});
        return false;
    }
    pipeline.descriptorManager = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(ptr)));

    var desc_builder = descriptor_mgr.DescriptorBuilder.init(std.heap.page_allocator);
    defer desc_builder.deinit();

    // Binding 0: Combined Image Sampler
    desc_builder.add_binding(0, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch return false;

    if (!desc_builder.build(pipeline.descriptorManager.?, device, allocator, vulkan_state, 1, true)) {
        skybox_log.err("Failed to build skybox descriptor manager", .{});
        return false;
    }

    // Allocate Descriptor Set
    if (!descriptor_mgr.vk_descriptor_manager_allocate_sets(pipeline.descriptorManager, 1, @as([*]c.VkDescriptorSet, @ptrCast(&pipeline.descriptorSet)))) {
        skybox_log.err("Failed to allocate descriptor set", .{});
        return false;
    }

    // 2. Create Pipeline Layout
    var pushConstantRange = std.mem.zeroes(c.VkPushConstantRange);
    pushConstantRange.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT;
    pushConstantRange.offset = 0;
    pushConstantRange.size = @sizeOf(SkyboxPushConstants);

    var pipelineLayoutInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipelineLayoutInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    // Get layout from manager
    const layout = descriptor_mgr.vk_descriptor_manager_get_layout(pipeline.descriptorManager);
    pipelineLayoutInfo.pSetLayouts = &layout;
    pipelineLayoutInfo.pushConstantRangeCount = 1;
    pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;

    if (c.vkCreatePipelineLayout(device, &pipelineLayoutInfo, null, &pipeline.pipelineLayout) != c.VK_SUCCESS) {
        skybox_log.err("Failed to create pipeline layout", .{});
        return false;
    }

    // 3. Load Shaders & Pipeline -> Replace with PSO
    
    const renderer_allocator = mem_alloc.as_allocator();
    var builder = vk_pso.PipelineBuilder.init(renderer_allocator, device, null);
    
    var parsed = vk_pso.PipelineBuilder.load_from_json(renderer_allocator, "assets/pipelines/skybox.json") catch |err| {
        skybox_log.err("Failed to load skybox pipeline JSON: {s}", .{@errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;
    
    // Override rendering formats
    descriptor.rendering.color_formats = &.{format};
    descriptor.rendering.depth_format = depthFormat;

    if (pipeline.descriptorManager) |mgr| {
        if (mgr.useDescriptorBuffers) {
            descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }

    builder.build(descriptor, pipeline.pipelineLayout, &pipeline.pipeline) catch |err| {
        skybox_log.err("Failed to build skybox pipeline: {s}", .{@errorName(err)});
        return false;
    };

    pipeline.initialized = true;
    return true;
}

pub fn vk_skybox_pipeline_destroy(pipeline: *types.SkyboxPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator) void {
    if (!pipeline.initialized) return;

    if (pipeline.texture.is_allocated) {
        vk_allocator.vk_allocator_free_image(allocator, pipeline.texture.image, pipeline.texture.allocation);
        c.vkDestroyImageView(device, pipeline.texture.view, null);
        c.vkDestroySampler(device, pipeline.texture.sampler, null);
    }

    if (pipeline.descriptorManager != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        descriptor_mgr.vk_descriptor_manager_destroy(@ptrCast(pipeline.descriptorManager));
        memory.cardinal_free(mem_alloc, pipeline.descriptorManager);
        pipeline.descriptorManager = null;
    }
    c.vkDestroyPipeline(device, pipeline.pipeline, null);
    c.vkDestroyPipelineLayout(device, pipeline.pipelineLayout, null);

    pipeline.initialized = false;
}

pub fn vk_skybox_load_from_data(pipeline: *types.SkyboxPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, sync_manager: ?*types.VulkanSyncManager, textureData: texture_loader.TextureData) bool {
    // Clean up old texture
    if (pipeline.texture.is_allocated) {
        // Wait for device idle to ensure no frames are using the sampler/image
        // This causes a stall but prevents validation errors when hot-swapping textures
        _ = c.vkDeviceWaitIdle(device);

        c.vkDestroySampler(device, pipeline.texture.sampler, null);
        c.vkDestroyImageView(device, pipeline.texture.view, null);
        vk_allocator.vk_allocator_free_image(allocator, pipeline.texture.image, pipeline.texture.allocation);
        pipeline.texture.is_allocated = false;
    }

    // Convert to CardinalTexture for utils
    var cardTex = std.mem.zeroes(scene.CardinalTexture);
    cardTex.width = textureData.width;
    cardTex.height = textureData.height;
    cardTex.channels = textureData.channels;
    cardTex.data = textureData.data;
    cardTex.is_hdr = textureData.is_hdr;
    
    // Create resources
    if (!vk_texture_utils.vk_texture_create_from_data(allocator, device, commandPool, graphicsQueue, sync_manager, &cardTex, &pipeline.texture.image, &pipeline.texture.memory, &pipeline.texture.view, null, &pipeline.texture.allocation)) {
        skybox_log.err("Failed to create skybox texture resources", .{});
        return false;
    }

    // Create Sampler
    var samplerInfo = std.mem.zeroes(c.VkSamplerCreateInfo);
    samplerInfo.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = c.VK_FILTER_LINEAR;
    samplerInfo.minFilter = c.VK_FILTER_LINEAR;
    samplerInfo.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT; // Equirectangular wraps horizontally
    samplerInfo.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE; // Clamps vertically
    samplerInfo.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.anisotropyEnable = c.VK_TRUE;
    samplerInfo.maxAnisotropy = 16.0;
    samplerInfo.borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    samplerInfo.unnormalizedCoordinates = c.VK_FALSE;
    samplerInfo.compareEnable = c.VK_FALSE;
    samplerInfo.compareOp = c.VK_COMPARE_OP_ALWAYS;
    samplerInfo.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;

    if (c.vkCreateSampler(device, &samplerInfo, null, &pipeline.texture.sampler) != c.VK_SUCCESS) {
        skybox_log.err("Failed to create skybox sampler", .{});
        return false;
    }

    pipeline.texture.is_allocated = true;
    pipeline.texture.width = textureData.width;
    pipeline.texture.height = textureData.height;
    pipeline.texture.format = if (textureData.is_hdr) c.VK_FORMAT_R32G32B32A32_SFLOAT else c.VK_FORMAT_R8G8B8A8_SRGB;

    // Update Descriptor Set
    if (!descriptor_mgr.vk_descriptor_manager_update_textures(pipeline.descriptorManager, pipeline.descriptorSet, 0, @ptrCast(&pipeline.texture.view), pipeline.texture.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, 1)) {
        skybox_log.err("Failed to update skybox descriptor", .{});
        return false;
    }

    skybox_log.info("Skybox uploaded successfully", .{});
    return true;
}

pub fn vk_skybox_load(pipeline: *types.SkyboxPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, sync_manager: ?*types.VulkanSyncManager, path: [:0]const u8) bool {
    var textureData = std.mem.zeroes(texture_loader.TextureData);
    
    // Load texture asynchronously
    const res = texture_loader.texture_load_with_ref_counting(path.ptr, &textureData);
    if (res == null) {
        skybox_log.err("Failed to load skybox texture: {s}", .{path});
        return false;
    }

    // Upload the initial data (might be placeholder)
    if (vk_skybox_load_from_data(pipeline, device, allocator, commandPool, graphicsQueue, sync_manager, textureData)) {
        // Track the resource for updates
        pipeline.texture.resource = res;
        
        // If the resource is still loading, mark as placeholder to trigger updates
        const state = resource_state.cardinal_resource_state_get(res.?.identifier.?);
        pipeline.texture.isPlaceholder = (state == .LOADING);
        
        skybox_log.info("Skybox set to: {s} (Placeholder={any})", .{path, pipeline.texture.isPlaceholder});
        return true;
    }
    return false;
}

pub fn vk_skybox_update(pipeline: *types.SkyboxPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, sync_manager: ?*types.VulkanSyncManager) void {
    if (!pipeline.initialized or !pipeline.texture.is_allocated) return;
    
    if (pipeline.texture.isPlaceholder and pipeline.texture.resource != null) {
        const res = @as(*ref_counting.CardinalRefCountedResource, @ptrCast(@alignCast(pipeline.texture.resource.?)));
        
        if (res.identifier != null and resource_state.cardinal_resource_state_get(res.identifier) == .LOADED) {
             const data = @as(*texture_loader.TextureData, @ptrCast(@alignCast(res.resource.?)));
             
             skybox_log.info("Updating skybox from placeholder to loaded texture", .{});
             
             // Upload actual data
             if (vk_skybox_load_from_data(pipeline, device, allocator, commandPool, graphicsQueue, sync_manager, data.*)) {
                 pipeline.texture.isPlaceholder = false;
                 // Keep the resource pointer
                 pipeline.texture.resource = res;
             }
        }
    }
}

pub fn render(pipeline: *types.SkyboxPipeline, cmd: c.VkCommandBuffer, view: math.Mat4, proj: math.Mat4) void {
    if (!pipeline.initialized or !pipeline.texture.is_allocated) return;

    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline);

    // Bind Descriptor Set
    var use_buffers = false;
    if (pipeline.descriptorManager) |mgr| {
        use_buffers = mgr.useDescriptorBuffers;
    }

    if (!use_buffers and (pipeline.descriptorSet == null or @intFromPtr(pipeline.descriptorSet) == 0)) {
        return;
    }
    const sets = [_]c.VkDescriptorSet{pipeline.descriptorSet};
    if (pipeline.descriptorManager) |mgr| {
        descriptor_mgr.vk_descriptor_manager_bind_sets(mgr, cmd, pipeline.pipelineLayout, 0, 1, &sets, 0, null);
    } else {
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout, 0, 1, &sets, 0, null);
    }

    // Push Constants
    var pc: SkyboxPushConstants = undefined;
    pc.view = view;
    pc.proj = proj;

    c.vkCmdPushConstants(cmd, pipeline.pipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(SkyboxPushConstants), &pc);

    // Draw cube (36 vertices)
    c.vkCmdDraw(cmd, 36, 1, 0, 0);
}
