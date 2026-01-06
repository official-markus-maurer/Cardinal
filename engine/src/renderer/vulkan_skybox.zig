const std = @import("std");
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

pub fn vk_skybox_pipeline_init(pipeline: *types.SkyboxPipeline, device: c.VkDevice, format: c.VkFormat, depthFormat: c.VkFormat, allocator: *types.VulkanAllocator) bool {
    _ = allocator;
    pipeline.initialized = false;
    
    // 1. Create Descriptor Set Layout
    var binding = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
    binding.binding = 0;
    binding.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binding.descriptorCount = 1;
    binding.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
    binding.pImmutableSamplers = null;

    var layoutInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layoutInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = 1;
    layoutInfo.pBindings = &binding;

    if (c.vkCreateDescriptorSetLayout(device, &layoutInfo, null, &pipeline.descriptorSetLayout) != c.VK_SUCCESS) {
        skybox_log.err("Failed to create descriptor set layout", .{});
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
    pipelineLayoutInfo.pSetLayouts = &pipeline.descriptorSetLayout;
    pipelineLayoutInfo.pushConstantRangeCount = 1;
    pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;

    if (c.vkCreatePipelineLayout(device, &pipelineLayoutInfo, null, &pipeline.pipelineLayout) != c.VK_SUCCESS) {
        skybox_log.err("Failed to create pipeline layout", .{});
        return false;
    }

    // 3. Load Shaders & Pipeline -> Replace with PSO
    
    var builder = vk_pso.PipelineBuilder.init(std.heap.page_allocator, device, null);
    
    var parsed = vk_pso.PipelineBuilder.load_from_json(std.heap.page_allocator, "assets/pipelines/skybox.json") catch |err| {
        skybox_log.err("Failed to load skybox pipeline JSON: {s}", .{@errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;
    
    // Override rendering formats
    descriptor.rendering.color_formats = &.{format};
    descriptor.rendering.depth_format = depthFormat;

    builder.build(descriptor, pipeline.pipelineLayout, &pipeline.pipeline) catch |err| {
        skybox_log.err("Failed to build skybox pipeline: {s}", .{@errorName(err)});
        return false;
    };

    // Create Descriptor Pool
    var poolSize = std.mem.zeroes(c.VkDescriptorPoolSize);
    poolSize.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSize.descriptorCount = 1;

    var poolInfo = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    poolInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.poolSizeCount = 1;
    poolInfo.pPoolSizes = &poolSize;
    poolInfo.maxSets = 1;

    if (c.vkCreateDescriptorPool(device, &poolInfo, null, &pipeline.descriptorPool) != c.VK_SUCCESS) {
        skybox_log.err("Failed to create descriptor pool", .{});
        return false;
    }

    // Allocate Descriptor Set
    var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool = pipeline.descriptorPool;
    allocInfo.descriptorSetCount = 1;
    allocInfo.pSetLayouts = &pipeline.descriptorSetLayout;

    if (c.vkAllocateDescriptorSets(device, &allocInfo, &pipeline.descriptorSet) != c.VK_SUCCESS) {
        skybox_log.err("Failed to allocate descriptor set", .{});
        return false;
    }

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

    c.vkDestroyDescriptorPool(device, pipeline.descriptorPool, null);
    c.vkDestroyPipeline(device, pipeline.pipeline, null);
    c.vkDestroyPipelineLayout(device, pipeline.pipelineLayout, null);
    c.vkDestroyDescriptorSetLayout(device, pipeline.descriptorSetLayout, null);

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
    var imageInfo = std.mem.zeroes(c.VkDescriptorImageInfo);
    imageInfo.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    imageInfo.imageView = pipeline.texture.view;
    imageInfo.sampler = pipeline.texture.sampler;

    var descriptorWrite = std.mem.zeroes(c.VkWriteDescriptorSet);
    descriptorWrite.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrite.dstSet = pipeline.descriptorSet;
    descriptorWrite.dstBinding = 0;
    descriptorWrite.dstArrayElement = 0;
    descriptorWrite.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    descriptorWrite.descriptorCount = 1;
    descriptorWrite.pImageInfo = &imageInfo;

    c.vkUpdateDescriptorSets(device, 1, &descriptorWrite, 0, null);

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
    const sets = [_]c.VkDescriptorSet{pipeline.descriptorSet};
    c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout, 0, 1, &sets, 0, null);

    // Push Constants
    var pc: SkyboxPushConstants = undefined;
    pc.view = view;
    pc.proj = proj;

    c.vkCmdPushConstants(cmd, pipeline.pipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(SkyboxPushConstants), &pc);

    // Draw cube (36 vertices)
    c.vkCmdDraw(cmd, 36, 1, 0, 0);
}
