const std = @import("std");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;

pub export fn vk_compute_init(vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (vulkan_state == null) {
        log.cardinal_log_error("[COMPUTE] Invalid vulkan state for compute initialization", .{});
        return false;
    }

    log.cardinal_log_info("[COMPUTE] Compute shader support initialized", .{});
    return true;
}

pub export fn vk_compute_cleanup(vulkan_state: ?*types.VulkanState) callconv(.c) void {
    if (vulkan_state == null) {
        return;
    }

    log.cardinal_log_info("[COMPUTE] Compute shader support cleaned up", .{});
}

pub export fn vk_compute_validate_config(vulkan_state: ?*types.VulkanState, config: ?*const c.ComputePipelineConfig) callconv(.c) bool {
    if (vulkan_state == null or config == null) {
        log.cardinal_log_error("[COMPUTE] Invalid parameters for config validation", .{});
        return false;
    }
    const cfg = config.?;
    const vs = vulkan_state.?;

    if (cfg.compute_shader_path == null or c.strlen(cfg.compute_shader_path) == 0) {
        log.cardinal_log_error("[COMPUTE] Compute shader path is required", .{});
        return false;
    }

    // Validate local workgroup sizes
    if (cfg.local_size_x == 0 or cfg.local_size_y == 0 or cfg.local_size_z == 0) {
        log.cardinal_log_error("[COMPUTE] Local workgroup sizes must be greater than 0", .{});
        return false;
    }

    // Check device limits
    var properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(vs.context.physical_device, &properties);

    if (cfg.local_size_x > properties.limits.maxComputeWorkGroupSize[0] or
        cfg.local_size_y > properties.limits.maxComputeWorkGroupSize[1] or
        cfg.local_size_z > properties.limits.maxComputeWorkGroupSize[2]) {
        log.cardinal_log_error("[COMPUTE] Local workgroup sizes exceed device limits", .{});
        return false;
    }

    const total_invocations = cfg.local_size_x * cfg.local_size_y * cfg.local_size_z;
    if (total_invocations > properties.limits.maxComputeWorkGroupInvocations) {
        log.cardinal_log_error("[COMPUTE] Total workgroup invocations ({d}) exceed device limit ({d})", .{total_invocations, properties.limits.maxComputeWorkGroupInvocations});
        return false;
    }

    return true;
}

pub export fn vk_compute_create_descriptor_layout(
    vulkan_state: ?*types.VulkanState,
    bindings: ?*const c.VkDescriptorSetLayoutBinding,
    binding_count: u32,
    layout: ?*c.VkDescriptorSetLayout
) callconv(.c) bool {
    if (vulkan_state == null or bindings == null or binding_count == 0 or layout == null) {
        log.cardinal_log_error("[COMPUTE] Invalid parameters for descriptor layout creation", .{});
        return false;
    }
    const vs = vulkan_state.?;

    var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_info.bindingCount = binding_count;
    layout_info.pBindings = bindings;

    const result = c.vkCreateDescriptorSetLayout(vs.context.device, &layout_info, null, layout);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[COMPUTE] Failed to create descriptor set layout: {d}", .{result});
        return false;
    }

    return true;
}

pub export fn vk_compute_create_pipeline(
    vulkan_state: ?*types.VulkanState,
    config: ?*const c.ComputePipelineConfig,
    pipeline: ?*c.ComputePipeline
) callconv(.c) bool {
    if (vulkan_state == null or config == null or pipeline == null) {
        log.cardinal_log_error("[COMPUTE] Invalid parameters for compute pipeline creation", .{});
        return false;
    }
    const vs = vulkan_state.?;
    const cfg = config.?;
    const pipe = pipeline.?;

    // Validate configuration
    if (!vk_compute_validate_config(vulkan_state, config)) {
        return false;
    }

    // Initialize pipeline structure
    @memset(@as([*]u8, @ptrCast(pipe))[0..@sizeOf(c.ComputePipeline)], 0);

    // Load compute shader
    var compute_shader: c.VkShaderModule = null;
    if (!c.vk_shader_create_module(vs.context.device, cfg.compute_shader_path, &compute_shader)) {
        log.cardinal_log_error("[COMPUTE] Failed to load compute shader: {s}", .{if (cfg.compute_shader_path != null) std.mem.span(cfg.compute_shader_path) else "null"});
        return false;
    }

    // Create pipeline layout
    var push_constant_range = std.mem.zeroes(c.VkPushConstantRange);
    var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeline_layout_info.setLayoutCount = cfg.descriptor_set_count;
    pipeline_layout_info.pSetLayouts = cfg.descriptor_layouts;
    pipeline_layout_info.pushConstantRangeCount = 0;
    pipeline_layout_info.pPushConstantRanges = null;

    // Add push constants if specified
    if (cfg.push_constant_size > 0) {
        push_constant_range.stageFlags = cfg.push_constant_stages;
        push_constant_range.offset = 0;
        push_constant_range.size = cfg.push_constant_size;

        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &push_constant_range;
    }

    var result = c.vkCreatePipelineLayout(vs.context.device, &pipeline_layout_info, null, &pipe.pipeline_layout);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[COMPUTE] Failed to create pipeline layout: {d}", .{result});
        c.vkDestroyShaderModule(vs.context.device, compute_shader, null);
        return false;
    }

    // Create compute pipeline
    var shader_stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
    shader_stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shader_stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
    shader_stage.module = compute_shader;
    shader_stage.pName = "main";

    var pipeline_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
    pipeline_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    pipeline_info.stage = shader_stage;
    pipeline_info.layout = pipe.pipeline_layout;
    pipeline_info.basePipelineHandle = null;
    pipeline_info.basePipelineIndex = -1;

    result = c.vkCreateComputePipelines(vs.context.device, null, 1, &pipeline_info, null, &pipe.pipeline);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[COMPUTE] Failed to create compute pipeline: {d}", .{result});
        c.vkDestroyPipelineLayout(vs.context.device, pipe.pipeline_layout, null);
        c.vkDestroyShaderModule(vs.context.device, compute_shader, null);
        return false;
    }

    // Clean up shader module
    c.vkDestroyShaderModule(vs.context.device, compute_shader, null);

    // Store pipeline configuration
    pipe.descriptor_set_count = cfg.descriptor_set_count;
    pipe.push_constant_size = cfg.push_constant_size;
    pipe.push_constant_stages = cfg.push_constant_stages;
    pipe.local_size_x = cfg.local_size_x;
    pipe.local_size_y = cfg.local_size_y;
    pipe.local_size_z = cfg.local_size_z;
    pipe.initialized = true;

    // Copy descriptor layouts if provided
    if (cfg.descriptor_set_count > 0 and cfg.descriptor_layouts != null) {
        const layouts = c.malloc(cfg.descriptor_set_count * @sizeOf(c.VkDescriptorSetLayout));
        if (layouts != null) {
            pipe.descriptor_layouts = @as([*]c.VkDescriptorSetLayout, @ptrCast(@alignCast(layouts)));
            @memcpy(@as([*]u8, @ptrCast(pipe.descriptor_layouts))[0..(cfg.descriptor_set_count * @sizeOf(c.VkDescriptorSetLayout))],
                    @as([*]const u8, @ptrCast(cfg.descriptor_layouts))[0..(cfg.descriptor_set_count * @sizeOf(c.VkDescriptorSetLayout))]);
        }
    }

    log.cardinal_log_info("[COMPUTE] Created compute pipeline with local size ({d}, {d}, {d})", .{cfg.local_size_x, cfg.local_size_y, cfg.local_size_z});

    return true;
}

pub export fn vk_compute_destroy_pipeline(vulkan_state: ?*types.VulkanState, pipeline: ?*c.ComputePipeline) callconv(.c) void {
    if (vulkan_state == null or pipeline == null or !pipeline.?.initialized) {
        return;
    }
    const vs = vulkan_state.?;
    const pipe = pipeline.?;

    if (pipe.pipeline != null) {
        c.vkDestroyPipeline(vs.context.device, pipe.pipeline, null);
        pipe.pipeline = null;
    }

    if (pipe.pipeline_layout != null) {
        c.vkDestroyPipelineLayout(vs.context.device, pipe.pipeline_layout, null);
        pipe.pipeline_layout = null;
    }

    if (pipe.descriptor_layouts != null) {
        c.free(@as(?*anyopaque, @ptrCast(pipe.descriptor_layouts)));
        pipe.descriptor_layouts = null;
    }

    pipe.initialized = false;

    log.cardinal_log_debug("[COMPUTE] Destroyed compute pipeline", .{});
}

pub export fn vk_compute_dispatch(
    cmd_buffer: c.VkCommandBuffer,
    pipeline: ?*const c.ComputePipeline,
    dispatch_info: ?*const c.ComputeDispatchInfo
) callconv(.c) void {
    if (cmd_buffer == null or pipeline == null or dispatch_info == null or !pipeline.?.initialized) {
        log.cardinal_log_error("[COMPUTE] Invalid parameters for compute dispatch", .{});
        return;
    }
    const pipe = pipeline.?;
    const info = dispatch_info.?;

    // Bind compute pipeline
    c.vkCmdBindPipeline(cmd_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipe.pipeline);

    // Bind descriptor sets if provided
    if (info.descriptor_sets != null and info.descriptor_set_count > 0) {
        c.vkCmdBindDescriptorSets(cmd_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE,
                                pipe.pipeline_layout, 0, info.descriptor_set_count,
                                info.descriptor_sets, 0, null);
    }

    // Push constants if provided
    if (info.push_constants != null and info.push_constant_size > 0) {
        c.vkCmdPushConstants(cmd_buffer, pipe.pipeline_layout, pipe.push_constant_stages, 0,
                           info.push_constant_size, info.push_constants);
    }

    // Dispatch compute work
    c.vkCmdDispatch(cmd_buffer, info.group_count_x, info.group_count_y, info.group_count_z);
}

pub export fn vk_compute_memory_barrier(cmd_buffer: c.VkCommandBuffer, barrier: ?*const c.ComputeMemoryBarrier) callconv(.c) void {
    if (cmd_buffer == null or barrier == null) {
        log.cardinal_log_error("[COMPUTE] Invalid parameters for memory barrier", .{});
        return;
    }
    const b = barrier.?;

    var memory_barrier = std.mem.zeroes(c.VkMemoryBarrier);
    memory_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    memory_barrier.srcAccessMask = b.src_access_mask;
    memory_barrier.dstAccessMask = b.dst_access_mask;

    c.vkCmdPipelineBarrier(cmd_buffer, b.src_stage_mask, b.dst_stage_mask, 0, 1, &memory_barrier, 0, null, 0, null);
}

pub export fn vk_compute_calculate_workgroups(total_work_items: u32, local_size: u32) callconv(.c) u32 {
    if (local_size == 0) {
        log.cardinal_log_error("[COMPUTE] Local size cannot be zero", .{});
        return 0;
    }

    return (total_work_items + local_size - 1) / local_size;
}
