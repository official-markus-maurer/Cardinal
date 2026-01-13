const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const descriptor_mgr = @import("vulkan_descriptor_manager.zig");
const vk_pso = @import("vulkan_pso.zig");

const pp_log = log.ScopedLogger("POST_PROCESS");

pub fn vk_post_process_init(s: *types.VulkanState) bool {
    s.pipelines.post_process_pipeline.initialized = false;
    s.pipelines.use_post_process = true;

    // 1. Create Descriptor Manager
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

    const renderer_allocator = mem_alloc.as_allocator();
    if (!desc_builder.build(s.pipelines.post_process_pipeline.descriptorManager.?, s.context.device, @as(*types.VulkanAllocator, @ptrCast(&s.allocator)), s, 1, true)) {
        pp_log.err("Failed to build descriptor manager", .{});
        return false;
    }

    // 2. Allocate Descriptor Set
    if (!descriptor_mgr.vk_descriptor_manager_allocate_sets(s.pipelines.post_process_pipeline.descriptorManager, 1, @as([*]c.VkDescriptorSet, @ptrCast(&s.pipelines.post_process_pipeline.descriptorSet)))) {
        pp_log.err("Failed to allocate descriptor set", .{});
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

    // 4. Create Pipeline Layout
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

    // 5. Load Pipeline
    const pipeline_dir = std.mem.span(@as([*:0]const u8, @ptrCast(&s.config.pipeline_dir)));
    const pipeline_path = std.fmt.allocPrint(renderer_allocator, "{s}/postprocess.json", .{pipeline_dir}) catch return false;
    defer renderer_allocator.free(pipeline_path);

    // Use null for pipeline cache as we don't have it easily accessible here and it's optional
    var builder = vk_pso.PipelineBuilder.init(renderer_allocator, s.context.device, null);

    var parsed = vk_pso.PipelineBuilder.load_from_json(renderer_allocator, pipeline_path) catch |err| {
        pp_log.err("Failed to load pipeline JSON: {s}", .{@errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;

    // Set output format to Swapchain format (Backbuffer)
    if (s.swapchain.format == c.VK_FORMAT_UNDEFINED) {
        pp_log.err("Swapchain format is UNDEFINED during pipeline creation!", .{});
        return false;
    }

    const formats = renderer_allocator.alloc(c.VkFormat, 1) catch return false;
    formats[0] = s.swapchain.format;
    descriptor.rendering.color_formats = formats;
    defer renderer_allocator.free(formats);

    // No depth

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
        
        // Descriptor manager and sets are handled by common destruction logic if using main pool, 
        // but here we allocated a manager. We should destroy it.
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

pub fn render(s: *types.VulkanState, cmd: c.VkCommandBuffer, input_view: c.VkImageView) void {
    if (!s.pipelines.post_process_pipeline.initialized) return;

    const pp = &s.pipelines.post_process_pipeline;

    // Check descriptor set validity
    const use_buffers = if (pp.descriptorManager) |mgr| mgr.useDescriptorBuffers else false;
    if (!use_buffers and (pp.descriptorSet == null or @intFromPtr(pp.descriptorSet) == 0)) {
        pp_log.err("Render skipped: Descriptor Set is NULL", .{});
        return;
    }

    // Update Descriptor Set (Input Texture)
    // We assume the input view is valid and in SHADER_READ_ONLY_OPTIMAL layout (ensured by RenderGraph)
    if (!descriptor_mgr.vk_descriptor_manager_update_image(pp.descriptorManager, pp.descriptorSet, 0, // Binding 0
        input_view, pp.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL))
    {
        pp_log.err("Failed to update descriptor set", .{});
    }

    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pp.pipeline);

    // Bind Descriptor Set
    var sets = [_]c.VkDescriptorSet{pp.descriptorSet};
    descriptor_mgr.vk_descriptor_manager_bind_sets(pp.descriptorManager, cmd, pp.pipelineLayout, 0, 1, &sets, 0, null);

    // Full screen triangle
    c.vkCmdDraw(cmd, 3, 1, 0, 0);
}
