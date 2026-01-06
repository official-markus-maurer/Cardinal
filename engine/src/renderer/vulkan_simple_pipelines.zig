const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const buffer_mgr = @import("vulkan_buffer_manager.zig");
const descriptor_mgr = @import("vulkan_descriptor_manager.zig");
const types = @import("vulkan_types.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const scene = @import("../assets/scene.zig");
const shader_utils = @import("util/vulkan_shader_utils.zig");
const material_utils = @import("util/vulkan_material_utils.zig");
const wrappers = @import("vulkan_wrappers.zig");
const vk_pso = @import("vulkan_pso.zig");

const c = @import("vulkan_c.zig").c;

const SimpleUniformBufferObject = extern struct {
    model: [16]f32,
    view: [16]f32,
    proj: [16]f32,
};

fn create_simple_descriptor_resources(s: *types.VulkanState) bool {
    const memory = @import("../core/memory.zig");
    // Create Descriptor Manager
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for simple descriptor manager", .{});
        return false;
    }
    s.pipelines.simple_descriptor_manager = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(ptr)));

    var desc_builder = descriptor_mgr.DescriptorBuilder.init(std.heap.page_allocator);
    defer desc_builder.deinit();

    // Binding 0: Uniform Buffer
    desc_builder.add_binding(0, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, c.VK_SHADER_STAGE_VERTEX_BIT) catch return false;

    if (!desc_builder.build(s.pipelines.simple_descriptor_manager.?, s.context.device, @constCast(&s.allocator), s, 1, true)) {
        log.cardinal_log_error("Failed to build simple descriptor manager", .{});
        return false;
    }

    // Allocate Set
    if (!descriptor_mgr.vk_descriptor_manager_allocate_sets(s.pipelines.simple_descriptor_manager, 1, @as([*]c.VkDescriptorSet, @ptrCast(&s.pipelines.simple_descriptor_set)))) {
        log.cardinal_log_error("Failed to allocate simple descriptor set", .{});
        return false;
    }

    // Update Set
    if (!descriptor_mgr.vk_descriptor_manager_update_buffer(s.pipelines.simple_descriptor_manager, s.pipelines.simple_descriptor_set, 0, s.pipelines.simple_uniform_buffer, 0, @sizeOf(SimpleUniformBufferObject))) {
         log.cardinal_log_error("Failed to update simple UBO descriptor", .{});
         return false;
    }

    return true;
}

fn create_simple_uniform_buffer(s: *types.VulkanState) bool {
    const bufferSize = @sizeOf(SimpleUniformBufferObject);

    var simpleBuffer = std.mem.zeroes(buffer_mgr.VulkanBuffer);
    var createInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
    createInfo.size = bufferSize;
    createInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    createInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    createInfo.persistentlyMapped = true;

    if (!buffer_mgr.vk_buffer_create(&simpleBuffer, s.context.device, @ptrCast(&s.allocator), &createInfo)) {
        log.cardinal_log_error("Failed to create simple uniform buffer!", .{});
        return false;
    }

    // Store buffer handles for compatibility with existing code
    s.pipelines.simple_uniform_buffer = simpleBuffer.handle;
    s.pipelines.simple_uniform_buffer_memory = simpleBuffer.memory;
    s.pipelines.simple_uniform_buffer_allocation = simpleBuffer.allocation;
    s.pipelines.simple_uniform_buffer_mapped = simpleBuffer.mapped;

    if (s.pipelines.simple_uniform_buffer_mapped == null) {
        log.cardinal_log_error("Failed to map simple uniform buffer memory!", .{});
        return false;
    }

    return true;
}



fn create_simple_pipeline_from_json(s: *types.VulkanState, json_path: []const u8, pipeline: *c.VkPipeline, pipelineLayout: *c.VkPipelineLayout, pipelineCache: c.VkPipelineCache) bool {
    var builder = vk_pso.PipelineBuilder.init(std.heap.page_allocator, s.context.device, pipelineCache);
    
    var parsed = vk_pso.PipelineBuilder.load_from_json(std.heap.page_allocator, json_path) catch |err| {
        log.cardinal_log_error("Failed to load pipeline JSON '{s}': {s}", .{json_path, @errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;
    
    // Override rendering formats
    const colorFormat = s.swapchain.format;
    descriptor.rendering.color_formats = &.{colorFormat};
    descriptor.rendering.depth_format = s.swapchain.depth_format;

    // Create pipeline layout with push constants
    var pushConstantRange = std.mem.zeroes(c.VkPushConstantRange);
    pushConstantRange.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    pushConstantRange.offset = 0;
    pushConstantRange.size = @sizeOf(types.PBRPushConstants);

    var pipelineLayoutInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipelineLayoutInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    const layout = descriptor_mgr.vk_descriptor_manager_get_layout(s.pipelines.simple_descriptor_manager);
    pipelineLayoutInfo.pSetLayouts = &layout;
    pipelineLayoutInfo.pushConstantRangeCount = 1;
    pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;

    if (c.vkCreatePipelineLayout(s.context.device, &pipelineLayoutInfo, null, pipelineLayout) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create simple pipeline layout!", .{});
        return false;
    }

    if (s.pipelines.simple_descriptor_manager) |mgr| {
        if (mgr.useDescriptorBuffers) {
            descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }

    builder.build(descriptor, pipelineLayout.*, pipeline) catch |err| {
        log.cardinal_log_error("Failed to build simple pipeline: {s}", .{@errorName(err)});
        return false;
    };

    return true;
}

pub export fn vk_create_simple_pipelines(s: ?*types.VulkanState, pipelineCache: c.VkPipelineCache) callconv(.c) bool {
    if (s == null) return false;
    const vs = s.?;

    // Create shared uniform buffer
    if (!create_simple_uniform_buffer(vs)) {
        return false;
    }

    // Create shared descriptor layout and update descriptors
    if (!create_simple_descriptor_resources(vs)) {
        return false;
    }

    // Create UV pipeline
    if (!create_simple_pipeline_from_json(vs, "assets/pipelines/debug_uv.json", &vs.pipelines.uv_pipeline, &vs.pipelines.uv_pipeline_layout, pipelineCache)) {
        log.cardinal_log_error("Failed to create UV pipeline", .{});
        return false;
    }

    // Create wireframe pipeline
    if (!create_simple_pipeline_from_json(vs, "assets/pipelines/debug_wireframe.json", &vs.pipelines.wireframe_pipeline, &vs.pipelines.wireframe_pipeline_layout, pipelineCache)) {
        log.cardinal_log_error("Failed to create wireframe pipeline", .{});
        return false;
    }

    log.cardinal_log_info("Simple pipelines created successfully", .{});
    return true;
}

pub export fn vk_destroy_simple_pipelines(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    if (vs.pipelines.simple_uniform_buffer_mapped != null) {
        vk_allocator.vk_allocator_unmap_memory(&vs.allocator, vs.pipelines.simple_uniform_buffer_allocation);
        vs.pipelines.simple_uniform_buffer_mapped = null;
    }

    if (vs.pipelines.simple_uniform_buffer != null or vs.pipelines.simple_uniform_buffer_memory != null) {
        vk_allocator.vk_allocator_free_buffer(&vs.allocator, vs.pipelines.simple_uniform_buffer, vs.pipelines.simple_uniform_buffer_allocation);
        vs.pipelines.simple_uniform_buffer = null;
        vs.pipelines.simple_uniform_buffer_memory = null;
    }

    if (vs.pipelines.simple_descriptor_manager != null) {
        const memory = @import("../core/memory.zig");
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        descriptor_mgr.vk_descriptor_manager_destroy(@ptrCast(vs.pipelines.simple_descriptor_manager));
        memory.cardinal_free(mem_alloc, vs.pipelines.simple_descriptor_manager);
        vs.pipelines.simple_descriptor_manager = null;
    }

    if (vs.pipelines.uv_pipeline != null) {
        c.vkDestroyPipeline(vs.context.device, vs.pipelines.uv_pipeline, null);
        vs.pipelines.uv_pipeline = null;
    }

    if (vs.pipelines.uv_pipeline_layout != null) {
        c.vkDestroyPipelineLayout(vs.context.device, vs.pipelines.uv_pipeline_layout, null);
        vs.pipelines.uv_pipeline_layout = null;
    }

    if (vs.pipelines.wireframe_pipeline != null) {
        c.vkDestroyPipeline(vs.context.device, vs.pipelines.wireframe_pipeline, null);
        vs.pipelines.wireframe_pipeline = null;
    }

    if (vs.pipelines.wireframe_pipeline_layout != null) {
        c.vkDestroyPipelineLayout(vs.context.device, vs.pipelines.wireframe_pipeline_layout, null);
        vs.pipelines.wireframe_pipeline_layout = null;
    }
}

pub export fn vk_update_simple_uniforms(s: ?*types.VulkanState, model: ?*const f32, view: ?*const f32, proj: ?*const f32) callconv(.c) void {
    if (s == null or s.?.pipelines.simple_uniform_buffer_mapped == null or model == null or view == null or proj == null) return;
    const vs = s.?;

    var ubo: SimpleUniformBufferObject = undefined;
    @memcpy(ubo.model[0..16], @as([*]const f32, @ptrCast(model))[0..16]);
    @memcpy(ubo.view[0..16], @as([*]const f32, @ptrCast(view))[0..16]);
    @memcpy(ubo.proj[0..16], @as([*]const f32, @ptrCast(proj))[0..16]);

    @memcpy(@as([*]u8, @ptrCast(vs.pipelines.simple_uniform_buffer_mapped))[0..@sizeOf(SimpleUniformBufferObject)], @as([*]const u8, @ptrCast(&ubo))[0..@sizeOf(SimpleUniformBufferObject)]);
}

pub export fn vk_render_simple(s: ?*types.VulkanState, commandBufferHandle: c.VkCommandBuffer, pipeline: c.VkPipeline, pipelineLayout: c.VkPipelineLayout) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;
    if (vs.current_scene == null) return;
    const scn = vs.current_scene.?;

    // Use PBR buffers if available
    if (!vs.pipelines.use_pbr_pipeline or !vs.pipelines.pbr_pipeline.initialized) return;
    const pipe = &vs.pipelines.pbr_pipeline;

    if (pipe.vertexBuffer == null or pipe.indexBuffer == null) return;

    const cmd = wrappers.CommandBuffer.init(commandBufferHandle);

    cmd.bindPipeline(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    
    var descriptorSets = [_]c.VkDescriptorSet{vs.pipelines.simple_descriptor_set};
    // Use manager bind function to handle descriptor buffers transparently
    descriptor_mgr.vk_descriptor_manager_bind_sets(vs.pipelines.simple_descriptor_manager, commandBufferHandle, pipelineLayout, 0, 1, &descriptorSets, 0, null);

    var vertexBuffers = [_]c.VkBuffer{pipe.vertexBuffer};
    var offsets = [_]c.VkDeviceSize{0};
    cmd.bindVertexBuffers(0, &vertexBuffers, &offsets);
    
    cmd.bindIndexBuffer(pipe.indexBuffer, 0, c.VK_INDEX_TYPE_UINT32);

    // Render each mesh using offsets
    var indexOffset: u32 = 0;
    var i: u32 = 0;
    while (i < scn.mesh_count) : (i += 1) {
        if (scn.meshes) |meshes| {
            const mesh = &meshes[i];

            if (!mesh.visible) {
                indexOffset += mesh.index_count;
                continue;
            }

            // Prepare push constants
            var pushConstants = std.mem.zeroes(types.PBRPushConstants);
            // Cast to C types for the C function call
            material_utils.vk_material_setup_push_constants(@ptrCast(&pushConstants), @ptrCast(mesh), @ptrCast(scn), @ptrCast(vs.pipelines.pbr_pipeline.textureManager));

            cmd.pushConstants(pipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(types.PBRPushConstants), &pushConstants);

            if (mesh.index_count > 0) {
                cmd.drawIndexed(mesh.index_count, 1, indexOffset, 0, 0);
            } else {
                cmd.draw(mesh.vertex_count, 1, 0, 0);
            }
            indexOffset += mesh.index_count;
        }
    }
}
