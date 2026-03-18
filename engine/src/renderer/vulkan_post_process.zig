//! Post-processing and bloom pipeline.
//!
//! Creates a post-processing pass (tone mapping, bloom composition) and a bloom compute pipeline.
//! Resources are allocated once and updated per-frame via descriptor sets/buffers.
const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const descriptor_mgr = @import("vulkan_descriptor_manager.zig");
const vk_compute = @import("vulkan_compute.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const descriptor_init = @import("util/vulkan_descriptor_init.zig");
const pipeline_json = @import("util/vulkan_pipeline_json.zig");

const pp_log = log.ScopedLogger("POST_PROCESS");

fn init_post_process_descriptor_manager(s: *types.VulkanState) bool {
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    const bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 2,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
    };

    if (!descriptor_init.create_descriptor_manager_from_bindings(renderer_allocator, &s.pipelines.post_process_pipeline.descriptorManager, s.context.device, @as(*types.VulkanAllocator, @ptrCast(&s.allocator)), s, &bindings, types.MAX_FRAMES_IN_FLIGHT, true)) {
        return false;
    }

    return descriptor_mgr.vk_descriptor_manager_allocate_sets(
        s.pipelines.post_process_pipeline.descriptorManager,
        types.MAX_FRAMES_IN_FLIGHT,
        @as([*]c.VkDescriptorSet, @ptrCast(&s.pipelines.post_process_pipeline.descriptorSets)),
    );
}

fn create_post_process_sampler(s: *types.VulkanState) bool {
    var samplerInfo = std.mem.zeroes(c.VkSamplerCreateInfo);
    samplerInfo.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = c.VK_FILTER_LINEAR;
    samplerInfo.minFilter = c.VK_FILTER_LINEAR;
    samplerInfo.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.maxAnisotropy = 1.0;
    samplerInfo.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
    samplerInfo.unnormalizedCoordinates = c.VK_FALSE;
    samplerInfo.compareEnable = c.VK_FALSE;
    samplerInfo.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;

    return c.vkCreateSampler(s.context.device, &samplerInfo, null, &s.pipelines.post_process_pipeline.sampler) == c.VK_SUCCESS;
}

fn create_bloom_image_and_view(s: *types.VulkanState) bool {
    const bloom_extent = c.VkExtent3D{ .width = s.swapchain.extent.width / 2, .height = s.swapchain.extent.height / 2, .depth = 1 };
    var imageInfo = std.mem.zeroes(c.VkImageCreateInfo);
    imageInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = c.VK_IMAGE_TYPE_2D;
    imageInfo.extent = bloom_extent;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
    imageInfo.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_STORAGE_BIT;
    imageInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    imageInfo.samples = c.VK_SAMPLE_COUNT_1_BIT;

    if (!vk_allocator.allocate_image(&s.allocator, &imageInfo, &s.pipelines.post_process_pipeline.bloom_image, &s.pipelines.post_process_pipeline.bloom_memory, &s.pipelines.post_process_pipeline.bloom_allocation, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
        return false;
    }

    var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
    viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = s.pipelines.post_process_pipeline.bloom_image;
    viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
    viewInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;

    return c.vkCreateImageView(s.context.device, &viewInfo, null, &s.pipelines.post_process_pipeline.bloom_view) == c.VK_SUCCESS;
}

fn create_post_process_params_buffers(s: *types.VulkanState) bool {
    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        var usage: c.VkBufferUsageFlags = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        if (s.context.supports_buffer_device_address) {
            usage |= c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
        }

        var bufferInfo = std.mem.zeroes(c.VkBufferCreateInfo);
        bufferInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bufferInfo.size = @sizeOf(types.PostProcessParams);
        bufferInfo.usage = usage;
        bufferInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        if (!vk_allocator.allocate_buffer(&s.allocator, &bufferInfo, &s.pipelines.post_process_pipeline.params_buffer[i], &s.pipelines.post_process_pipeline.params_memory[i], &s.pipelines.post_process_pipeline.params_allocation[i], c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, true, &s.pipelines.post_process_pipeline.params_mapped[i])) {
            return false;
        }

        const params = @as(*types.PostProcessParams, @ptrCast(@alignCast(s.pipelines.post_process_pipeline.params_mapped[i])));
        params.exposure = 1.0;
        params.contrast = 1.0;
        params.saturation = 1.0;
        params.bloomIntensity = 0.04;
        params.bloomThreshold = 1.0;
        params.bloomKnee = 0.1;
    }

    s.pipelines.post_process_pipeline.current_params = .{
        .exposure = 1.0,
        .contrast = 1.0,
        .saturation = 1.0,
        .bloomIntensity = 0.04,
        .bloomThreshold = 1.0,
        .bloomKnee = 0.1,
        .padding = .{ 0.0, 0.0 },
    };

    return true;
}

fn init_bloom_descriptor_manager(s: *types.VulkanState) bool {
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    const bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
    };

    if (!descriptor_init.create_descriptor_manager_from_bindings(renderer_allocator, &s.pipelines.post_process_pipeline.bloomDescriptorManager, s.context.device, @as(*types.VulkanAllocator, @ptrCast(&s.allocator)), s, &bindings, types.MAX_FRAMES_IN_FLIGHT, true)) {
        return false;
    }

    if (!descriptor_mgr.vk_descriptor_manager_allocate_sets(
        s.pipelines.post_process_pipeline.bloomDescriptorManager,
        types.MAX_FRAMES_IN_FLIGHT,
        @as([*]c.VkDescriptorSet, @ptrCast(&s.pipelines.post_process_pipeline.bloomDescriptorSets)),
    )) return false;

    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        if (!descriptor_mgr.vk_descriptor_manager_update_image(s.pipelines.post_process_pipeline.bloomDescriptorManager, s.pipelines.post_process_pipeline.bloomDescriptorSets[i], 1, s.pipelines.post_process_pipeline.bloom_view, null, c.VK_IMAGE_LAYOUT_GENERAL)) {
            return false;
        }
    }

    return true;
}

/// Initializes post-process descriptors, bloom resources, and pipelines.
pub fn vk_post_process_init(s: *types.VulkanState) bool {
    s.pipelines.post_process_pipeline.initialized = false;
    s.pipelines.use_post_process = true;

    if (!init_post_process_descriptor_manager(s)) {
        pp_log.err("Failed to allocate descriptor sets", .{});
        return false;
    }

    if (!create_post_process_sampler(s)) {
        pp_log.err("Failed to create sampler", .{});
        return false;
    }

    if (!create_bloom_image_and_view(s)) {
        pp_log.err("Failed to create bloom image view", .{});
        return false;
    }

    if (!create_post_process_params_buffers(s)) {
        pp_log.err("Failed to allocate post-process params buffers", .{});
        return false;
    }

    if (!init_bloom_descriptor_manager(s)) {
        pp_log.err("Failed to initialize bloom descriptor manager", .{});
        return false;
    }

    var bloom_config = std.mem.zeroes(types.ComputePipelineConfig);
    bloom_config.compute_shader_path = "assets/shaders/bloom.comp.spv";
    bloom_config.local_size_x = 16;
    bloom_config.local_size_y = 16;
    bloom_config.local_size_z = 1;
    bloom_config.push_constant_size = @sizeOf([4]f32);
    bloom_config.push_constant_stages = c.VK_SHADER_STAGE_COMPUTE_BIT;

    var bloom_layout = [_]c.VkDescriptorSetLayout{descriptor_mgr.vk_descriptor_manager_get_layout(s.pipelines.post_process_pipeline.bloomDescriptorManager)};
    bloom_config.descriptor_set_count = 1;
    bloom_config.descriptor_layouts = &bloom_layout;

    if (!vk_compute.vk_compute_create_pipeline(s, &bloom_config, &s.pipelines.post_process_pipeline.bloom_pipeline)) {
        pp_log.err("Failed to create bloom compute pipeline", .{});
        return false;
    }

    var pipelineLayoutInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipelineLayoutInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    const layout = descriptor_mgr.vk_descriptor_manager_get_layout(s.pipelines.post_process_pipeline.descriptorManager);
    pipelineLayoutInfo.pSetLayouts = &layout;

    if (c.vkCreatePipelineLayout(s.context.device, &pipelineLayoutInfo, null, &s.pipelines.post_process_pipeline.pipelineLayout) != c.VK_SUCCESS) {
        pp_log.err("Failed to create pipeline layout", .{});
        return false;
    }

    const pipeline_dir = std.mem.span(@as([*:0]const u8, @ptrCast(&s.config.pipeline_dir)));
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    const pipeline_path = std.fmt.allocPrint(renderer_allocator, "{s}/postprocess.json", .{pipeline_dir}) catch return false;
    defer renderer_allocator.free(pipeline_path);

    if (s.swapchain.format == c.VK_FORMAT_UNDEFINED) {
        pp_log.err("Swapchain format is UNDEFINED during pipeline creation!", .{});
        return false;
    }

    var extra_flags: c.VkPipelineCreateFlags = 0;
    if (s.pipelines.post_process_pipeline.descriptorManager) |mgr| {
        if (mgr.useDescriptorBuffers) extra_flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
    }

    const formats = [_]c.VkFormat{s.swapchain.format};
    if (!pipeline_json.build_graphics_pipeline_from_json(
        renderer_allocator,
        s.context.device,
        null,
        s.pipelines.post_process_pipeline.pipelineLayout,
        &s.pipelines.post_process_pipeline.pipeline,
        pipeline_path,
        &formats,
        c.VK_FORMAT_UNDEFINED,
        extra_flags,
    )) {
        return false;
    }

    s.pipelines.post_process_pipeline.initialized = true;
    pp_log.info("Post Process Pipeline Initialized with format {d}", .{s.swapchain.format});
    return true;
}

pub fn vk_post_process_destroy(s: *types.VulkanState) void {
    if (s.pipelines.post_process_pipeline.initialized) {
        c.vkDestroyPipeline(s.context.device, s.pipelines.post_process_pipeline.pipeline, null);
        c.vkDestroyPipelineLayout(s.context.device, s.pipelines.post_process_pipeline.pipelineLayout, null);
        c.vkDestroySampler(s.context.device, s.pipelines.post_process_pipeline.sampler, null);

        vk_compute.vk_compute_destroy_pipeline(s, &s.pipelines.post_process_pipeline.bloom_pipeline);

        if (s.pipelines.post_process_pipeline.bloomDescriptorManager) |mgr| {
            descriptor_mgr.vk_descriptor_manager_destroy(mgr);
            const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
            memory.cardinal_free(mem_alloc, mgr);
            s.pipelines.post_process_pipeline.bloomDescriptorManager = null;
        }

        c.vkDestroyImageView(s.context.device, s.pipelines.post_process_pipeline.bloom_view, null);
        vk_allocator.free_image(&s.allocator, s.pipelines.post_process_pipeline.bloom_image, s.pipelines.post_process_pipeline.bloom_allocation);

        var i: u32 = 0;
        while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
            vk_allocator.free_buffer(&s.allocator, s.pipelines.post_process_pipeline.params_buffer[i], s.pipelines.post_process_pipeline.params_allocation[i]);
        }

        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        if (s.pipelines.post_process_pipeline.descriptorManager) |mgr| {
            descriptor_mgr.vk_descriptor_manager_destroy(mgr);
            memory.cardinal_free(mem_alloc, mgr);
            s.pipelines.post_process_pipeline.descriptorManager = null;
        }

        s.pipelines.post_process_pipeline.initialized = false;
        pp_log.info("Post Process Pipeline Destroyed", .{});
    }
}

pub fn compute_bloom(s: *types.VulkanState, cmd: c.VkCommandBuffer, frame_index: u32, input_view: c.VkImageView) void {
    if (!s.pipelines.post_process_pipeline.initialized) return;
    const pp = &s.pipelines.post_process_pipeline;

    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, pp.bloom_pipeline.pipeline);

    if (!descriptor_mgr.vk_descriptor_manager_update_image(pp.bloomDescriptorManager, pp.bloomDescriptorSets[frame_index], 0, input_view, pp.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
        pp_log.err("Failed to update bloom input descriptor", .{});
    }

    var sets = [_]c.VkDescriptorSet{pp.bloomDescriptorSets[frame_index]};
    descriptor_mgr.vk_descriptor_manager_bind_sets(pp.bloomDescriptorManager, cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, pp.bloom_pipeline.pipeline_layout, 0, 1, &sets, 0, null);

    var params: [4]f32 = .{ 1.0, 0.1, 0.0, 0.0 };
    if (pp.params_mapped[frame_index]) |ptr| {
        const p = @as(*types.PostProcessParams, @ptrCast(@alignCast(ptr)));
        params[0] = p.bloomThreshold;
        params[1] = p.bloomKnee;
    }
    c.vkCmdPushConstants(cmd, pp.bloom_pipeline.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &params);

    const group_x = (s.swapchain.extent.width / 2 + 15) / 16;
    const group_y = (s.swapchain.extent.height / 2 + 15) / 16;
    c.vkCmdDispatch(cmd, group_x, group_y, 1);
}

pub fn draw(s: *types.VulkanState, cmd: c.VkCommandBuffer, frame_index: u32, input_view: c.VkImageView) void {
    if (!s.pipelines.post_process_pipeline.initialized) return;
    const pp = &s.pipelines.post_process_pipeline;

    const use_buffers = if (pp.descriptorManager) |mgr| mgr.useDescriptorBuffers else false;
    const descSet = pp.descriptorSets[frame_index];

    if (pp.params_mapped[frame_index]) |ptr| {
        const dst = @as(*types.PostProcessParams, @ptrCast(@alignCast(ptr)));
        dst.* = pp.current_params;
    }

    if (!use_buffers and @intFromPtr(descSet) == 0) {
        pp_log.err("Render skipped: Descriptor Set is NULL", .{});
        return;
    }

    if (!descriptor_mgr.vk_descriptor_manager_update_image(pp.descriptorManager, descSet, 0, input_view, pp.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
        pp_log.err("Failed to update descriptor set (input)", .{});
    }

    if (!descriptor_mgr.vk_descriptor_manager_update_image(pp.descriptorManager, descSet, 1, pp.bloom_view, pp.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
        pp_log.err("Failed to update descriptor set (bloom)", .{});
    }

    if (!descriptor_mgr.vk_descriptor_manager_update_buffer(pp.descriptorManager, descSet, 2, pp.params_buffer[frame_index], 0, @sizeOf(types.PostProcessParams))) {
        pp_log.err("Failed to update descriptor set (params)", .{});
    }

    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pp.pipeline);

    var sets = [_]c.VkDescriptorSet{descSet};
    descriptor_mgr.vk_descriptor_manager_bind_sets(pp.descriptorManager, cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pp.pipelineLayout, 0, 1, &sets, 0, null);

    c.vkCmdDraw(cmd, 3, 1, 0, 0);
}
