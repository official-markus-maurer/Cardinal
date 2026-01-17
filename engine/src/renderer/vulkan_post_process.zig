const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const descriptor_mgr = @import("vulkan_descriptor_manager.zig");
const vk_pso = @import("vulkan_pso.zig");
const vk_compute = @import("vulkan_compute.zig");
const vk_allocator = @import("vulkan_allocator.zig");

const pp_log = log.ScopedLogger("POST_PROCESS");

pub fn vk_post_process_init(s: *types.VulkanState) bool {
    s.pipelines.post_process_pipeline.initialized = false;
    s.pipelines.use_post_process = true;

    // 1. Create Descriptor Manager (Fragment Shader)
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (ptr == null) {
        pp_log.err("Failed to allocate memory for descriptor manager", .{});
        return false;
    }
    s.pipelines.post_process_pipeline.descriptorManager = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(ptr)));

    var desc_builder = descriptor_mgr.DescriptorBuilder.init(std.heap.page_allocator);
    defer desc_builder.deinit();

    // Binding 0: Combined Image Sampler (Input Texture)
    desc_builder.add_binding(0, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch return false;
    // Binding 1: Combined Image Sampler (Bloom Texture)
    desc_builder.add_binding(1, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch return false;
    // Binding 2: UBO (Params)
    desc_builder.add_binding(2, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch return false;

    const renderer_allocator = mem_alloc.as_allocator();
    // We need sets for all frames in flight
    if (!desc_builder.build(s.pipelines.post_process_pipeline.descriptorManager.?, s.context.device, @as(*types.VulkanAllocator, @ptrCast(&s.allocator)), s, types.MAX_FRAMES_IN_FLIGHT, true)) {
        pp_log.err("Failed to build descriptor manager", .{});
        return false;
    }

    // 2. Allocate Descriptor Sets (Fragment)
    if (!descriptor_mgr.vk_descriptor_manager_allocate_sets(s.pipelines.post_process_pipeline.descriptorManager, types.MAX_FRAMES_IN_FLIGHT, @as([*]c.VkDescriptorSet, @ptrCast(&s.pipelines.post_process_pipeline.descriptorSets)))) {
        pp_log.err("Failed to allocate descriptor sets", .{});
        return false;
    }

    // 3. Create Sampler
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

    if (c.vkCreateSampler(s.context.device, &samplerInfo, null, &s.pipelines.post_process_pipeline.sampler) != c.VK_SUCCESS) {
        pp_log.err("Failed to create sampler", .{});
        return false;
    }

    // 4. Allocate Bloom Image (Half Res)
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
        pp_log.err("Failed to allocate bloom image", .{});
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

    if (c.vkCreateImageView(s.context.device, &viewInfo, null, &s.pipelines.post_process_pipeline.bloom_view) != c.VK_SUCCESS) {
        pp_log.err("Failed to create bloom image view", .{});
        return false;
    }

    // 5. Allocate Params UBOs (Per Frame)
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

        if (!vk_allocator.allocate_buffer(&s.allocator, &bufferInfo, &s.pipelines.post_process_pipeline.params_buffer[i], &s.pipelines.post_process_pipeline.params_memory[i], &s.pipelines.post_process_pipeline.params_allocation[i], c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, true, // Map immediately
            &s.pipelines.post_process_pipeline.params_mapped[i]))
        {
            pp_log.err("Failed to allocate params buffer for frame {d}", .{i});
            return false;
        }

        // Initialize Params with defaults
        const params = @as(*types.PostProcessParams, @ptrCast(@alignCast(s.pipelines.post_process_pipeline.params_mapped[i])));
        params.exposure = 1.0;
        params.contrast = 1.0;
        params.saturation = 1.0;
        params.bloomIntensity = 0.04;
        params.bloomThreshold = 1.0;
        params.bloomKnee = 0.1;
    }

    // Initialize current_params with defaults
    s.pipelines.post_process_pipeline.current_params = .{
        .exposure = 1.0,
        .contrast = 1.0,
        .saturation = 1.0,
        .bloomIntensity = 0.04,
        .bloomThreshold = 1.0,
        .bloomKnee = 0.1,
        .padding = .{ 0.0, 0.0 },
    };

    // 6. Initialize Bloom Compute Pipeline
    // Create Descriptor Manager for Bloom
    const bloom_mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const bloom_ptr = memory.cardinal_alloc(bloom_mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (bloom_ptr == null) {
        pp_log.err("Failed to allocate memory for bloom descriptor manager", .{});
        return false;
    }
    s.pipelines.post_process_pipeline.bloomDescriptorManager = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(bloom_ptr)));

    var bloom_builder = descriptor_mgr.DescriptorBuilder.init(std.heap.page_allocator);
    defer bloom_builder.deinit();

    // Binding 0: Combined Image Sampler (Input)
    bloom_builder.add_binding(0, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_COMPUTE_BIT) catch return false;
    // Binding 1: Storage Image (Output)
    bloom_builder.add_binding(1, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, c.VK_SHADER_STAGE_COMPUTE_BIT) catch return false;

    if (!bloom_builder.build(s.pipelines.post_process_pipeline.bloomDescriptorManager.?, s.context.device, @as(*types.VulkanAllocator, @ptrCast(&s.allocator)), s, types.MAX_FRAMES_IN_FLIGHT, true)) {
        pp_log.err("Failed to build bloom descriptor manager", .{});
        return false;
    }

    // Allocate Bloom Descriptor Sets
    if (!descriptor_mgr.vk_descriptor_manager_allocate_sets(s.pipelines.post_process_pipeline.bloomDescriptorManager, types.MAX_FRAMES_IN_FLIGHT, @as([*]c.VkDescriptorSet, @ptrCast(&s.pipelines.post_process_pipeline.bloomDescriptorSets)))) {
        pp_log.err("Failed to allocate bloom descriptor sets", .{});
        return false;
    }

    // Update Bloom Descriptor Sets (Output Image is static)
    i = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        if (!descriptor_mgr.vk_descriptor_manager_update_image(s.pipelines.post_process_pipeline.bloomDescriptorManager, s.pipelines.post_process_pipeline.bloomDescriptorSets[i], 1, s.pipelines.post_process_pipeline.bloom_view, null, c.VK_IMAGE_LAYOUT_GENERAL)) {
            pp_log.err("Failed to update bloom output descriptor", .{});
            return false;
        }
    }

    // Create Bloom Compute Pipeline
    var bloom_config = std.mem.zeroes(types.ComputePipelineConfig);
    bloom_config.compute_shader_path = "assets/shaders/bloom.comp.spv";
    bloom_config.local_size_x = 16;
    bloom_config.local_size_y = 16;
    bloom_config.local_size_z = 1;
    bloom_config.push_constant_size = 16; // vec4
    bloom_config.push_constant_stages = c.VK_SHADER_STAGE_COMPUTE_BIT;

    var bloom_layout = [_]c.VkDescriptorSetLayout{descriptor_mgr.vk_descriptor_manager_get_layout(s.pipelines.post_process_pipeline.bloomDescriptorManager)};
    bloom_config.descriptor_set_count = 1;
    bloom_config.descriptor_layouts = &bloom_layout;

    if (!vk_compute.vk_compute_create_pipeline(s, &bloom_config, &s.pipelines.post_process_pipeline.bloom_pipeline)) {
        pp_log.err("Failed to create bloom compute pipeline", .{});
        return false;
    }

    // 7. Create Post Process Pipeline Layout
    var pipelineLayoutInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipelineLayoutInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    // Get layout from manager
    const layout = descriptor_mgr.vk_descriptor_manager_get_layout(s.pipelines.post_process_pipeline.descriptorManager);
    pipelineLayoutInfo.pSetLayouts = &layout;

    if (c.vkCreatePipelineLayout(s.context.device, &pipelineLayoutInfo, null, &s.pipelines.post_process_pipeline.pipelineLayout) != c.VK_SUCCESS) {
        pp_log.err("Failed to create pipeline layout", .{});
        return false;
    }

    // 8. Load Post Process Pipeline
    const pipeline_dir = std.mem.span(@as([*:0]const u8, @ptrCast(&s.config.pipeline_dir)));
    const pipeline_path = std.fmt.allocPrint(renderer_allocator, "{s}/postprocess.json", .{pipeline_dir}) catch return false;
    defer renderer_allocator.free(pipeline_path);

    var builder = vk_pso.PipelineBuilder.init(renderer_allocator, s.context.device, null);

    var parsed = vk_pso.PipelineBuilder.load_from_json(renderer_allocator, pipeline_path) catch |err| {
        pp_log.err("Failed to load pipeline JSON: {s}", .{@errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;

    if (s.swapchain.format == c.VK_FORMAT_UNDEFINED) {
        pp_log.err("Swapchain format is UNDEFINED during pipeline creation!", .{});
        return false;
    }

    const formats = renderer_allocator.alloc(c.VkFormat, 1) catch return false;
    formats[0] = s.swapchain.format;
    descriptor.rendering.color_formats = formats;
    defer renderer_allocator.free(formats);

    if (s.pipelines.post_process_pipeline.descriptorManager) |mgr| {
        if (mgr.useDescriptorBuffers) {
            descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }

    builder.build(descriptor, s.pipelines.post_process_pipeline.pipelineLayout, &s.pipelines.post_process_pipeline.pipeline) catch |err| {
        pp_log.err("Failed to build pipeline: {s}", .{@errorName(err)});
        return false;
    };

    s.pipelines.post_process_pipeline.initialized = true;
    pp_log.info("Post Process Pipeline Initialized with format {d}", .{s.swapchain.format});
    return true;
}

pub fn vk_post_process_destroy(s: *types.VulkanState) void {
    if (s.pipelines.post_process_pipeline.initialized) {
        c.vkDestroyPipeline(s.context.device, s.pipelines.post_process_pipeline.pipeline, null);
        c.vkDestroyPipelineLayout(s.context.device, s.pipelines.post_process_pipeline.pipelineLayout, null);
        c.vkDestroySampler(s.context.device, s.pipelines.post_process_pipeline.sampler, null);

        // Bloom cleanup
        vk_compute.vk_compute_destroy_pipeline(s, &s.pipelines.post_process_pipeline.bloom_pipeline);

        if (s.pipelines.post_process_pipeline.bloomDescriptorManager) |mgr| {
            descriptor_mgr.vk_descriptor_manager_destroy(mgr);
            const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
            memory.cardinal_free(mem_alloc, mgr);
            s.pipelines.post_process_pipeline.bloomDescriptorManager = null;
        }

        c.vkDestroyImageView(s.context.device, s.pipelines.post_process_pipeline.bloom_view, null);
        vk_allocator.free_image(&s.allocator, s.pipelines.post_process_pipeline.bloom_image, s.pipelines.post_process_pipeline.bloom_allocation);

        // Params cleanup
        var i: u32 = 0;
        while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
            // vmaDestroyBuffer automatically unmaps if the buffer was mapped
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

    // Transition Bloom Image to General (Compute Write)
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
    barrier.srcAccessMask = 0;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_SHADER_WRITE_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
    barrier.image = pp.bloom_image;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;

    var depInfo = std.mem.zeroes(c.VkDependencyInfo);
    depInfo.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    depInfo.imageMemoryBarrierCount = 1;
    depInfo.pImageMemoryBarriers = &barrier;

    c.vkCmdPipelineBarrier2(cmd, &depInfo);

    // Bind Compute Pipeline
    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, pp.bloom_pipeline.pipeline);

    // Update Input Descriptor (Binding 0) - this changes per frame based on input_view
    if (!descriptor_mgr.vk_descriptor_manager_update_image(pp.bloomDescriptorManager, pp.bloomDescriptorSets[frame_index], 0, input_view, pp.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
        pp_log.err("Failed to update bloom input descriptor", .{});
    }

    // Bind Descriptor Set
    var sets = [_]c.VkDescriptorSet{pp.bloomDescriptorSets[frame_index]};
    descriptor_mgr.vk_descriptor_manager_bind_sets(pp.bloomDescriptorManager, cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, pp.bloom_pipeline.pipeline_layout, 0, 1, &sets, 0, null);

    // Push Constants (Threshold/Knee)
    var params: [4]f32 = .{ 1.0, 0.1, 0.0, 0.0 };
    if (pp.params_mapped[frame_index]) |ptr| {
        const p = @as(*types.PostProcessParams, @ptrCast(@alignCast(ptr)));
        params[0] = p.bloomThreshold;
        params[1] = p.bloomKnee;
    }
    c.vkCmdPushConstants(cmd, pp.bloom_pipeline.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &params);

    // Dispatch
    const group_x = (s.swapchain.extent.width / 2 + 15) / 16;
    const group_y = (s.swapchain.extent.height / 2 + 15) / 16;
    c.vkCmdDispatch(cmd, group_x, group_y, 1);

    // Barrier: Compute Write -> Fragment Read
    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    barrier.srcAccessMask = c.VK_ACCESS_2_SHADER_WRITE_BIT;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_SHADER_READ_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_GENERAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    c.vkCmdPipelineBarrier2(cmd, &depInfo);
}

pub fn draw(s: *types.VulkanState, cmd: c.VkCommandBuffer, frame_index: u32, input_view: c.VkImageView) void {
    if (!s.pipelines.post_process_pipeline.initialized) return;
    const pp = &s.pipelines.post_process_pipeline;

    const use_buffers = if (pp.descriptorManager) |mgr| mgr.useDescriptorBuffers else false;
    const descSet = pp.descriptorSets[frame_index];

    // Update Params Buffer for current frame from current_params
    // This happens before binding/draw, and updates the buffer that is about to be used for this frame.
    // Since we are recording the command buffer for this frame, we know it's safe to update its resources (timeline semaphore wait happened).
    if (pp.params_mapped[frame_index]) |ptr| {
        const dst = @as(*types.PostProcessParams, @ptrCast(@alignCast(ptr)));
        dst.* = pp.current_params;
    }

    if (!use_buffers and @intFromPtr(descSet) == 0) {
        pp_log.err("Render skipped: Descriptor Set is NULL", .{});
        return;
    }

    // Update Descriptor Set (Input Texture)
    if (!descriptor_mgr.vk_descriptor_manager_update_image(pp.descriptorManager, descSet, 0, input_view, pp.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
        pp_log.err("Failed to update descriptor set (input)", .{});
    }

    // Update Descriptor Set (Bloom Texture)
    if (!descriptor_mgr.vk_descriptor_manager_update_image(pp.descriptorManager, descSet, 1, pp.bloom_view, pp.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
        pp_log.err("Failed to update descriptor set (bloom)", .{});
    }

    // Update Descriptor Set (Params UBO)
    if (!descriptor_mgr.vk_descriptor_manager_update_buffer(pp.descriptorManager, descSet, 2, pp.params_buffer[frame_index], 0, @sizeOf(types.PostProcessParams))) {
        pp_log.err("Failed to update descriptor set (params)", .{});
    }

    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pp.pipeline);

    var sets = [_]c.VkDescriptorSet{descSet};
    descriptor_mgr.vk_descriptor_manager_bind_sets(pp.descriptorManager, cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pp.pipelineLayout, 0, 1, &sets, 0, null);

    c.vkCmdDraw(cmd, 3, 1, 0, 0);
}
