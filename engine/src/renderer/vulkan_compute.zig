const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;
const shader_utils = @import("util/vulkan_shader_utils.zig");

const compute_log = log.ScopedLogger("COMPUTE");

pub fn vk_compute_init(vulkan_state: ?*types.VulkanState) bool {
    if (vulkan_state == null) {
        compute_log.err("Invalid vulkan state for compute initialization", .{});
        return false;
    }
    const vs = vulkan_state.?;

    // Create Descriptor Pool
    var pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 100 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 100 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 100 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 100 },
    };

    var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.poolSizeCount = pool_sizes.len;
    pool_info.pPoolSizes = &pool_sizes;
    pool_info.maxSets = 100;

    if (c.vkCreateDescriptorPool(vs.context.device, &pool_info, null, &vs.pipelines.compute_descriptor_pool) != c.VK_SUCCESS) {
        compute_log.err("Failed to create compute descriptor pool", .{});
        return false;
    }

    compute_log.info("Compute shader support initialized", .{});
    return true;
}

pub fn vk_compute_cleanup(vulkan_state: ?*types.VulkanState) void {
    if (vulkan_state == null) {
        return;
    }
    const vs = vulkan_state.?;

    if (vs.pipelines.compute_descriptor_pool != null) {
        c.vkDestroyDescriptorPool(vs.context.device, vs.pipelines.compute_descriptor_pool, null);
        vs.pipelines.compute_descriptor_pool = null;
    }

    compute_log.info("Compute shader support cleaned up", .{});
}

pub fn vk_compute_validate_config(vulkan_state: ?*types.VulkanState, config: ?*const types.ComputePipelineConfig) bool {
    if (vulkan_state == null or config == null) {
        compute_log.err("Invalid parameters for config validation", .{});
        return false;
    }
    const cfg = config.?;
    const vs = vulkan_state.?;

    if (cfg.compute_shader_path == null or c.strlen(cfg.compute_shader_path) == 0) {
        compute_log.err("Compute shader path is required", .{});
        return false;
    }

    // Validate local workgroup sizes
    if (cfg.local_size_x == 0 or cfg.local_size_y == 0 or cfg.local_size_z == 0) {
        compute_log.err("Local workgroup sizes must be greater than 0", .{});
        return false;
    }

    // Check device limits
    var properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(vs.context.physical_device, &properties);

    if (cfg.local_size_x > properties.limits.maxComputeWorkGroupSize[0] or
        cfg.local_size_y > properties.limits.maxComputeWorkGroupSize[1] or
        cfg.local_size_z > properties.limits.maxComputeWorkGroupSize[2])
    {
        compute_log.err("Local workgroup sizes exceed device limits", .{});
        return false;
    }

    const total_invocations = cfg.local_size_x * cfg.local_size_y * cfg.local_size_z;
    if (total_invocations > properties.limits.maxComputeWorkGroupInvocations) {
        compute_log.err("Total workgroup invocations ({d}) exceed device limit ({d})", .{ total_invocations, properties.limits.maxComputeWorkGroupInvocations });
        return false;
    }

    return true;
}

pub fn vk_compute_create_descriptor_layout(vulkan_state: ?*types.VulkanState, bindings: ?*const c.VkDescriptorSetLayoutBinding, binding_count: u32, layout: ?*c.VkDescriptorSetLayout) bool {
    if (vulkan_state == null or bindings == null or binding_count == 0 or layout == null) {
        compute_log.err("Invalid parameters for descriptor layout creation", .{});
        return false;
    }
    const vs = vulkan_state.?;

    var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_info.bindingCount = binding_count;
    layout_info.pBindings = bindings;

    const result = c.vkCreateDescriptorSetLayout(vs.context.device, &layout_info, null, layout);
    if (result != c.VK_SUCCESS) {
        compute_log.err("Failed to create descriptor set layout: {d}", .{result});
        return false;
    }

    return true;
}

pub fn vk_compute_create_pipeline(vulkan_state: ?*types.VulkanState, config: ?*const types.ComputePipelineConfig, pipeline: ?*types.ComputePipeline) bool {
    if (vulkan_state == null or config == null or pipeline == null) {
        compute_log.err("Invalid parameters for compute pipeline creation", .{});
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
    @memset(@as([*]u8, @ptrCast(pipe))[0..@sizeOf(types.ComputePipeline)], 0);

    // Load compute shader and reflect
    var compute_shader: c.VkShaderModule = null;
    var reflected_layouts: ?[*]c.VkDescriptorSetLayout = null;
    var reflected_layout_count: u32 = 0;
    var push_constant_range = std.mem.zeroes(c.VkPushConstantRange);

    {
        const alloc = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
        const path_ptr = cfg.compute_shader_path orelse {
            compute_log.err("Compute shader path is null", .{});
            return false;
        };
        const code = shader_utils.vk_shader_read_file(alloc, std.mem.span(path_ptr)) catch |err| {
            compute_log.err("Failed to read shader file: {s}", .{@errorName(err)});
            return false;
        };
        defer alloc.free(code);

        if (!shader_utils.vk_shader_create_module_from_code(vs.context.device, code.ptr, code.len * 4, &compute_shader)) {
            compute_log.err("Failed to create shader module", .{});
            return false;
        }

        const reflect = shader_utils.reflection.reflect_shader(alloc, code, c.VK_SHADER_STAGE_COMPUTE_BIT) catch |err| {
            compute_log.err("Failed to reflect shader: {s}", .{@errorName(err)});
            c.vkDestroyShaderModule(vs.context.device, compute_shader, null);
            return false;
        };
        var r = reflect; // Mutable copy to deinit
        defer r.deinit();

        // Handle Push Constants
        if (r.push_constant_size > 0) {
            push_constant_range.stageFlags = r.push_constant_stages;
            push_constant_range.size = r.push_constant_size;
            // Override config if reflection found constants
            if (cfg.push_constant_size > 0 and cfg.push_constant_size > r.push_constant_size) {
                push_constant_range.size = cfg.push_constant_size;
            }
        } else if (cfg.push_constant_size > 0) {
            push_constant_range.stageFlags = cfg.push_constant_stages;
            push_constant_range.size = cfg.push_constant_size;
        }

        // Handle Descriptor Sets
        if (cfg.descriptor_set_count == 0) {
            // Generate from reflection
            var sets = std.AutoHashMap(u32, std.ArrayListUnmanaged(c.VkDescriptorSetLayoutBinding)).init(alloc);
            defer {
                var it = sets.iterator();
                while (it.next()) |entry| entry.value_ptr.deinit(alloc);
                sets.deinit();
            }

            for (r.resources.items) |res| {
                const entry = sets.getOrPut(res.set) catch {
                    compute_log.err("Failed to allocate memory for set reflection", .{});
                    return false;
                };
                if (!entry.found_existing) {
                    entry.value_ptr.* = std.ArrayListUnmanaged(c.VkDescriptorSetLayoutBinding){};
                }
                entry.value_ptr.append(alloc, .{
                    .binding = res.binding,
                    .descriptorType = res.type,
                    .descriptorCount = res.count,
                    .stageFlags = res.stage_flags,
                    .pImmutableSamplers = null,
                }) catch {
                    compute_log.err("Failed to append binding from reflection", .{});
                    return false;
                };
            }

            if (sets.count() > 0) {
                // Find max set index
                var max_set: u32 = 0;
                var it = sets.keyIterator();
                while (it.next()) |k| {
                    if (k.* > max_set) max_set = k.*;
                }

                reflected_layout_count = max_set + 1;
                const layouts_ptr = memory.cardinal_alloc(memory.cardinal_get_allocator_for_category(.RENDERER), reflected_layout_count * @sizeOf(c.VkDescriptorSetLayout));
                if (layouts_ptr == null) return false;
                reflected_layouts = @as([*]c.VkDescriptorSetLayout, @ptrCast(@alignCast(layouts_ptr)));
                @memset(reflected_layouts.?[0..reflected_layout_count], null);

                var sit = sets.iterator();
                while (sit.next()) |entry| {
                    const set_idx = entry.key_ptr.*;
                    const bindings = entry.value_ptr.*;

                    var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
                    layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
                    layout_info.bindingCount = @intCast(bindings.items.len);
                    layout_info.pBindings = bindings.items.ptr;

                    if (c.vkCreateDescriptorSetLayout(vs.context.device, &layout_info, null, &reflected_layouts.?[set_idx]) != c.VK_SUCCESS) {
                        compute_log.err("Failed to create descriptor set layout for set {d}", .{set_idx});
                        return false;
                    }
                }
            }
        }
    }

    // Create pipeline layout
    var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;

    if (reflected_layouts != null) {
        pipeline_layout_info.setLayoutCount = reflected_layout_count;
        pipeline_layout_info.pSetLayouts = reflected_layouts;
        pipe.descriptor_layouts = reflected_layouts;
        pipe.descriptor_set_count = reflected_layout_count;
        pipe.owns_layouts = true;
    } else {
        pipeline_layout_info.setLayoutCount = cfg.descriptor_set_count;
        pipeline_layout_info.pSetLayouts = cfg.descriptor_layouts;

        // Copy config layouts to pipe
        if (cfg.descriptor_set_count > 0 and cfg.descriptor_layouts != null) {
            const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
            const layouts = memory.cardinal_alloc(mem_alloc, cfg.descriptor_set_count * @sizeOf(c.VkDescriptorSetLayout));
            if (layouts != null) {
                pipe.descriptor_layouts = @as([*]c.VkDescriptorSetLayout, @ptrCast(@alignCast(layouts)));
                @memcpy(pipe.descriptor_layouts.?[0..cfg.descriptor_set_count], cfg.descriptor_layouts.?[0..cfg.descriptor_set_count]);
                pipe.descriptor_set_count = cfg.descriptor_set_count;
            }
        }
    }

    pipeline_layout_info.pushConstantRangeCount = 0;
    pipeline_layout_info.pPushConstantRanges = null;

    // Add push constants if specified (or reflected)
    if (push_constant_range.size > 0) {
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &push_constant_range;
        pipe.push_constant_size = push_constant_range.size;
        pipe.push_constant_stages = push_constant_range.stageFlags;
    }

    var result = c.vkCreatePipelineLayout(vs.context.device, &pipeline_layout_info, null, &pipe.pipeline_layout);
    if (result != c.VK_SUCCESS) {
        compute_log.err("Failed to create pipeline layout: {d}", .{result});
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

    if (vs.context.supports_descriptor_buffer) {
        pipeline_info.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
    }

    result = c.vkCreateComputePipelines(vs.context.device, null, 1, &pipeline_info, null, &pipe.pipeline);
    if (result != c.VK_SUCCESS) {
        compute_log.err("Failed to create compute pipeline: {d}", .{result});
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

    compute_log.info("Created compute pipeline with local size ({d}, {d}, {d})", .{ cfg.local_size_x, cfg.local_size_y, cfg.local_size_z });

    return true;
}

pub fn vk_compute_destroy_pipeline(vulkan_state: ?*types.VulkanState, pipeline: ?*types.ComputePipeline) void {
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
        if (pipe.owns_layouts) {
            var i: u32 = 0;
            while (i < pipe.descriptor_set_count) : (i += 1) {
                if (pipe.descriptor_layouts.?[i] != null) {
                    c.vkDestroyDescriptorSetLayout(vs.context.device, pipe.descriptor_layouts.?[i], null);
                }
            }
        }
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(pipe.descriptor_layouts)));
        pipe.descriptor_layouts = null;
    }

    pipe.initialized = false;

    compute_log.debug("Destroyed compute pipeline", .{});
}

pub fn vk_compute_dispatch(cmd_buffer: c.VkCommandBuffer, pipeline: ?*const types.ComputePipeline, dispatch_info: ?*const types.ComputeDispatchInfo) void {
    if (cmd_buffer == null or pipeline == null or dispatch_info == null or !pipeline.?.initialized) {
        compute_log.err("Invalid parameters for compute dispatch", .{});
        return;
    }
    const pipe = pipeline.?;
    const info = dispatch_info.?;

    // Bind compute pipeline
    c.vkCmdBindPipeline(cmd_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipe.pipeline);

    // Bind descriptor sets if provided
    if (info.descriptor_sets != null and info.descriptor_set_count > 0) {
        c.vkCmdBindDescriptorSets(cmd_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipe.pipeline_layout, 0, info.descriptor_set_count, info.descriptor_sets, 0, null);
    }

    // Push constants if provided
    if (info.push_constants != null and info.push_constant_size > 0) {
        c.vkCmdPushConstants(cmd_buffer, pipe.pipeline_layout, pipe.push_constant_stages, 0, info.push_constant_size, info.push_constants);
    }

    // Dispatch compute work
    c.vkCmdDispatch(cmd_buffer, info.group_count_x, info.group_count_y, info.group_count_z);
}

pub fn vk_compute_memory_barrier(cmd_buffer: c.VkCommandBuffer, barrier: ?*const types.ComputeMemoryBarrier) void {
    if (cmd_buffer == null or barrier == null) {
        compute_log.err("Invalid parameters for memory barrier", .{});
        return;
    }
    const b = barrier.?;

    var memory_barrier = std.mem.zeroes(c.VkMemoryBarrier2);
    memory_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2;
    memory_barrier.srcAccessMask = b.src_access_mask;
    memory_barrier.dstAccessMask = b.dst_access_mask;
    memory_barrier.srcStageMask = b.src_stage_mask;
    memory_barrier.dstStageMask = b.dst_stage_mask;

    var dep_info = std.mem.zeroes(c.VkDependencyInfo);
    dep_info.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep_info.memoryBarrierCount = 1;
    dep_info.pMemoryBarriers = &memory_barrier;

    c.vkCmdPipelineBarrier2(cmd_buffer, &dep_info);
}

pub fn vk_compute_calculate_workgroups(total_work_items: u32, local_size: u32) u32 {
    if (local_size == 0) {
        compute_log.err("Local size cannot be zero", .{});
        return 0;
    }

    return (total_work_items + local_size - 1) / local_size;
}
