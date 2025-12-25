const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const buffer_mgr = @import("vulkan_buffer_manager.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;
const shader_utils = @import("util/vulkan_shader_utils.zig");
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");
const scene = @import("../assets/scene.zig");
const vk_allocator = @import("vulkan_allocator.zig");

// Helper Functions

fn load_shader_module(device: c.VkDevice, path: [*:0]const u8, out_module: *c.VkShaderModule) bool {
    // Using vk_shader_create_module from vulkan_shader_utils.zig
    return shader_utils.vk_shader_create_module(device, path, out_module);
}

// Implementation

pub export fn vk_mesh_shader_init(s: ?*types.VulkanState) callconv(.c) bool {
    if (s == null) return false;
    const vs = s.?;

    const frames = if (vs.sync.max_frames_in_flight > 0) vs.sync.max_frames_in_flight else 3;

    // Allocate arrays for per-frame lists
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const lists_ptr = memory.cardinal_calloc(mem_alloc, frames, @sizeOf([*]types.MeshShaderDrawData));
    const counts_ptr = memory.cardinal_calloc(mem_alloc, frames, @sizeOf(u32));
    const capacities_ptr = memory.cardinal_calloc(mem_alloc, frames, @sizeOf(u32));

    if (lists_ptr == null or counts_ptr == null or capacities_ptr == null) {
        if (lists_ptr) |p| memory.cardinal_free(mem_alloc, p);
        if (counts_ptr) |p| memory.cardinal_free(mem_alloc, p);
        if (capacities_ptr) |p| memory.cardinal_free(mem_alloc, p);
        return false;
    }

    vs.pending_cleanup_lists = @as(?[*]?[*]types.MeshShaderDrawData, @ptrCast(@alignCast(lists_ptr)));
    vs.pending_cleanup_counts = @as([*]u32, @ptrCast(@alignCast(counts_ptr)));
    vs.pending_cleanup_capacities = @as([*]u32, @ptrCast(@alignCast(capacities_ptr)));

    return true;
}

pub export fn vk_mesh_shader_cleanup(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    vk_mesh_shader_destroy_pipeline(vs, &vs.pipelines.mesh_shader_pipeline);

    // Process all pending cleanups
    if (vs.pending_cleanup_lists != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        var f: u32 = 0;
        const frames = if (vs.sync.max_frames_in_flight > 0) vs.sync.max_frames_in_flight else 3;
        while (f < frames) : (f += 1) {
            if (vs.pending_cleanup_lists.?[f] != null) {
                var i: u32 = 0;
                while (i < vs.pending_cleanup_counts.?[f]) : (i += 1) {
                    vk_mesh_shader_destroy_draw_data(vs, &(vs.pending_cleanup_lists.?[f].?)[i]);
                }
                memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.pending_cleanup_lists.?[f])));
            }
        }
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.pending_cleanup_lists)));
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.pending_cleanup_counts)));
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(vs.pending_cleanup_capacities)));
        vs.pending_cleanup_lists = null;
        vs.pending_cleanup_counts = null;
        vs.pending_cleanup_capacities = null;
    }
}

pub export fn vk_mesh_shader_create_pipeline(s: ?*types.VulkanState, config: ?*const types.MeshShaderPipelineConfig, swapchain_format: c.VkFormat, depth_format: c.VkFormat, pipeline: ?*types.MeshShaderPipeline, pipeline_cache: c.VkPipelineCache) callconv(.c) bool {
    if (s == null or config == null or pipeline == null) return false;
    const vs = s.?;
    const cfg = config.?;
    const pipe = pipeline.?;

    pipe.max_meshlets_per_workgroup = 32;
    pipe.max_vertices_per_meshlet = cfg.max_vertices_per_meshlet;
    // pipe.max_primitives_per_meshlet = cfg.max_primitives_per_meshlet; // Struct definition might differ, check if field exists

    // Allocator for reflection data
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Helper map for merging bindings: binding_index -> BindingInfo
    const BindingInfo = struct {
        binding: c.VkDescriptorSetLayoutBinding,
        is_runtime_array: bool,
    };
    var set0_bindings = std.AutoHashMap(u32, BindingInfo).init(allocator);
    var set1_bindings = std.AutoHashMap(u32, BindingInfo).init(allocator);

    var pushConstantRange = std.mem.zeroes(c.VkPushConstantRange);
    pushConstantRange.offset = 0;
    pushConstantRange.size = 0;

    var meshShaderModule: c.VkShaderModule = null;
    var fragShaderModule: c.VkShaderModule = null;
    var taskShaderModule: c.VkShaderModule = null;

    // Load Shaders and Reflect
    const process_shader = struct {
        fn func(device: c.VkDevice, path_c: ?[*:0]const u8, stage: c.VkShaderStageFlags, module_out: *c.VkShaderModule,
               s0: *std.AutoHashMap(u32, BindingInfo), s1: *std.AutoHashMap(u32, BindingInfo), pc: *c.VkPushConstantRange, alloc: std.mem.Allocator) !bool {
             if (path_c == null) return false;
             const path = std.mem.span(path_c.?);
             
             const code = shader_utils.vk_shader_read_file(alloc, path) catch |err| {
                 log.cardinal_log_error("Failed to read shader {s}: {s}", .{path, @errorName(err)});
                 return false;
             };
             
             if (!shader_utils.vk_shader_create_module_from_code(device, code.ptr, code.len * 4, module_out)) {
                 log.cardinal_log_error("Failed to create shader module for {s}", .{path});
                 return false;
             }
             
             const reflect = shader_utils.reflection.reflect_shader(alloc, code, stage) catch |err| {
                 log.cardinal_log_error("Failed to reflect shader {s}: {s}", .{path, @errorName(err)});
                 return false;
             };
             // defer reflect.deinit(); // Allocated in arena
             
             if (reflect.push_constant_size > 0) {
                 pc.stageFlags |= reflect.push_constant_stages;
                 if (reflect.push_constant_size > pc.size) pc.size = reflect.push_constant_size;
             }
             
             for (reflect.resources.items) |res| {
                 var target_map: *std.AutoHashMap(u32, BindingInfo) = undefined;
                 if (res.set == 0) {
                     target_map = s0;
                 } else if (res.set == 1) {
                     target_map = s1;
                 } else {
                     continue;
                 }
                 
                 const entry = try target_map.getOrPut(res.binding);
                 if (entry.found_existing) {
                     entry.value_ptr.binding.stageFlags |= res.stage_flags;
                 } else {
                     entry.value_ptr.* = BindingInfo{
                         .binding = .{
                             .binding = res.binding,
                             .descriptorType = res.type,
                             .descriptorCount = res.count,
                             .stageFlags = res.stage_flags,
                             .pImmutableSamplers = null,
                         },
                         .is_runtime_array = res.is_runtime_array,
                     };
                 }
             }
             return true;
        }
    }.func;

    if (process_shader(vs.context.device, cfg.mesh_shader_path, c.VK_SHADER_STAGE_MESH_BIT_EXT, &meshShaderModule, &set0_bindings, &set1_bindings, &pushConstantRange, allocator) catch false) {
        // OK
    } else {
        return false;
    }
    
    if (process_shader(vs.context.device, cfg.fragment_shader_path, c.VK_SHADER_STAGE_FRAGMENT_BIT, &fragShaderModule, &set0_bindings, &set1_bindings, &pushConstantRange, allocator) catch false) {
        // OK
    } else {
        c.vkDestroyShaderModule(vs.context.device, meshShaderModule, null);
        return false;
    }
    
    if (cfg.task_shader_path != null) {
        if (process_shader(vs.context.device, cfg.task_shader_path, c.VK_SHADER_STAGE_TASK_BIT_EXT, &taskShaderModule, &set0_bindings, &set1_bindings, &pushConstantRange, allocator) catch false) {
            pipe.has_task_shader = true;
        } else {
             c.vkDestroyShaderModule(vs.context.device, meshShaderModule, null);
             c.vkDestroyShaderModule(vs.context.device, fragShaderModule, null);
             return false;
        }
    } else {
        pipe.has_task_shader = false;
    }

    // Build ShaderStages array
    var shaderStages: [3]c.VkPipelineShaderStageCreateInfo = undefined;
    var stageCount: u32 = 0;
    
    if (pipe.has_task_shader) {
        shaderStages[stageCount] = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        shaderStages[stageCount].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        shaderStages[stageCount].stage = c.VK_SHADER_STAGE_TASK_BIT_EXT;
        shaderStages[stageCount].module = taskShaderModule;
        shaderStages[stageCount].pName = "main";
        stageCount += 1;
    }
    
    shaderStages[stageCount] = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
    shaderStages[stageCount].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStages[stageCount].stage = c.VK_SHADER_STAGE_MESH_BIT_EXT;
    shaderStages[stageCount].module = meshShaderModule;
    shaderStages[stageCount].pName = "main";
    stageCount += 1;
    
    shaderStages[stageCount] = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
    shaderStages[stageCount].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStages[stageCount].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
    shaderStages[stageCount].module = fragShaderModule;
    shaderStages[stageCount].pName = "main";
    stageCount += 1;

    // Create Layouts
    const create_layout = struct {
        fn f(dev: c.VkDevice, map: *std.AutoHashMap(u32, BindingInfo), out_layout: *c.VkDescriptorSetLayout, alloc: std.mem.Allocator) bool {
             var bindings = std.ArrayListUnmanaged(c.VkDescriptorSetLayoutBinding){};
             var flags = std.ArrayListUnmanaged(c.VkDescriptorBindingFlags){};
             var has_flags = false;
             
             // Sort bindings by index
             var keys = std.ArrayListUnmanaged(u32){};
             var kit = map.keyIterator();
             while (kit.next()) |k| keys.append(alloc, k.*) catch return false;
             std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
             
             for (keys.items) |k| {
                 const entry = map.get(k).?;
                 bindings.append(alloc, entry.binding) catch return false;
                 if (entry.is_runtime_array) {
                     flags.append(alloc, c.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT | c.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT) catch return false;
                     has_flags = true;
                 } else {
                     flags.append(alloc, 0) catch return false;
                 }
             }
             
             var layoutInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
             layoutInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
             layoutInfo.bindingCount = @intCast(bindings.items.len);
             layoutInfo.pBindings = bindings.items.ptr;
             
             var flagsInfo = std.mem.zeroes(c.VkDescriptorSetLayoutBindingFlagsCreateInfo);
             if (has_flags) {
                 layoutInfo.flags = c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT;
                 flagsInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
                 flagsInfo.bindingCount = @intCast(flags.items.len);
                 flagsInfo.pBindingFlags = flags.items.ptr;
                 layoutInfo.pNext = &flagsInfo;
             }
             
             return c.vkCreateDescriptorSetLayout(dev, &layoutInfo, null, out_layout) == c.VK_SUCCESS;
        }
    }.f;

    var setLayouts: [2]c.VkDescriptorSetLayout = undefined;
    if (!create_layout(vs.context.device, &set0_bindings, &setLayouts[0], allocator)) return false;
    if (!create_layout(vs.context.device, &set1_bindings, &setLayouts[1], allocator)) return false;

    pipe.set0_layout = setLayouts[0];
    pipe.set1_layout = setLayouts[1];
    pipe.global_descriptor_set = null;

    // Descriptor Pool
    const poolSizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1000 * 4 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1000 * 5 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1000 * 4096 },
    };

    var poolInfo = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    poolInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.poolSizeCount = 3;
    poolInfo.pPoolSizes = &poolSizes;
    poolInfo.maxSets = 1000;
    poolInfo.flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT | c.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT;

    if (c.vkCreateDescriptorPool(vs.context.device, &poolInfo, null, &pipe.descriptor_pool) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create mesh shader descriptor pool", .{});
        return false;
    }

    // Default Material Buffer
    const DefaultMaterialData = extern struct {
        albedo: [3]f32,
        pad0: f32,
        metallic: f32,
        roughness: f32,
        ao: f32,
        pad1: f32,
        emissive: [3]f32,
        pad2: f32,
        alpha: f32,
        pad3: [3]f32,
    };

    const defaultMat = DefaultMaterialData{
        .albedo = .{ 1.0, 1.0, 1.0 },
        .pad0 = 0,
        .metallic = 0.0,
        .roughness = 0.5,
        .ao = 1.0,
        .pad1 = 0,
        .emissive = .{ 0.0, 0.0, 0.0 },
        .pad2 = 0,
        .alpha = 1.0,
        .pad3 = .{ 0, 0, 0 },
    };

    var defaultMatBuffer: types.VulkanBuffer = undefined;
    if (buffer_mgr.vk_buffer_create_device_local(@ptrCast(&defaultMatBuffer), vs.context.device, &vs.allocator, vs.commands.pools.?[0], vs.context.graphics_queue, &defaultMat, @sizeOf(DefaultMaterialData), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, vs)) {
        pipe.default_material_buffer = defaultMatBuffer.handle;
        pipe.default_material_memory = defaultMatBuffer.memory;
        pipe.default_material_allocation = defaultMatBuffer.allocation;
    } else {
        log.cardinal_log_error("Failed to create default material buffer", .{});
        // Cleanup descriptor pool if buffer creation fails
        c.vkDestroyDescriptorPool(vs.context.device, pipe.descriptor_pool, null);
        return false;
    }

    var pipelineLayoutInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipelineLayoutInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 2;
    pipelineLayoutInfo.pSetLayouts = &setLayouts;
    if (pushConstantRange.size > 0) {
        pipelineLayoutInfo.pushConstantRangeCount = 1;
        pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;
    }

    if (c.vkCreatePipelineLayout(vs.context.device, &pipelineLayoutInfo, null, &pipe.pipeline_layout) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create mesh shader pipeline layout!", .{});
        c.vkDestroyShaderModule(vs.context.device, meshShaderModule, null);
        c.vkDestroyShaderModule(vs.context.device, fragShaderModule, null);
        if (taskShaderModule != null) c.vkDestroyShaderModule(vs.context.device, taskShaderModule, null);
        return false;
    }

    // Graphics Pipeline
    var viewportState = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
    viewportState.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewportState.viewportCount = 1;
    viewportState.scissorCount = 1;

    var rasterizer = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
    rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.depthClampEnable = c.VK_FALSE;
    rasterizer.rasterizerDiscardEnable = c.VK_FALSE;
    rasterizer.polygonMode = cfg.polygon_mode;
    rasterizer.lineWidth = 1.0;
    rasterizer.cullMode = cfg.cull_mode;
    rasterizer.frontFace = cfg.front_face;
    rasterizer.depthBiasEnable = c.VK_FALSE;

    var multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.sampleShadingEnable = c.VK_FALSE;
    multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var depthStencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
    depthStencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depthStencil.depthTestEnable = if (cfg.depth_test_enable) c.VK_TRUE else c.VK_FALSE;
    depthStencil.depthWriteEnable = if (cfg.depth_write_enable) c.VK_TRUE else c.VK_FALSE;
    depthStencil.depthCompareOp = cfg.depth_compare_op;
    depthStencil.depthBoundsTestEnable = c.VK_FALSE;
    depthStencil.stencilTestEnable = c.VK_FALSE;

    var colorBlendAttachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    colorBlendAttachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    colorBlendAttachment.blendEnable = if (cfg.blend_enable) c.VK_TRUE else c.VK_FALSE;
    if (cfg.blend_enable) {
        colorBlendAttachment.srcColorBlendFactor = cfg.src_color_blend_factor;
        colorBlendAttachment.dstColorBlendFactor = cfg.dst_color_blend_factor;
        colorBlendAttachment.colorBlendOp = cfg.color_blend_op;
        colorBlendAttachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        colorBlendAttachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
        colorBlendAttachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
    }

    var colorBlending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    colorBlending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    colorBlending.logicOpEnable = c.VK_FALSE;
    colorBlending.attachmentCount = 1;
    colorBlending.pAttachments = &colorBlendAttachment;

    const dynamicStates = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    var dynamicState = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
    dynamicState.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicState.dynamicStateCount = 2;
    dynamicState.pDynamicStates = &dynamicStates;

    var renderingInfo = std.mem.zeroes(c.VkPipelineRenderingCreateInfo);
    renderingInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    renderingInfo.colorAttachmentCount = 1;
    renderingInfo.pColorAttachmentFormats = &swapchain_format;
    renderingInfo.depthAttachmentFormat = depth_format;

    var pipelineInfo = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    pipelineInfo.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipelineInfo.pNext = &renderingInfo;
    pipelineInfo.stageCount = stageCount;
    pipelineInfo.pStages = &shaderStages;
    pipelineInfo.pVertexInputState = null;
    pipelineInfo.pInputAssemblyState = null;
    pipelineInfo.pViewportState = &viewportState;
    pipelineInfo.pRasterizationState = &rasterizer;
    pipelineInfo.pMultisampleState = &multisampling;
    pipelineInfo.pDepthStencilState = &depthStencil;
    pipelineInfo.pColorBlendState = &colorBlending;
    pipelineInfo.pDynamicState = &dynamicState;
    pipelineInfo.layout = pipe.pipeline_layout;
    pipelineInfo.renderPass = null;
    pipelineInfo.subpass = 0;
    pipelineInfo.basePipelineHandle = null;

    if (c.vkCreateGraphicsPipelines(vs.context.device, pipeline_cache, 1, &pipelineInfo, null, &pipe.pipeline) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create mesh shader graphics pipeline!", .{});
        c.vkDestroyPipelineLayout(vs.context.device, pipe.pipeline_layout, null);
        c.vkDestroyShaderModule(vs.context.device, meshShaderModule, null);
        c.vkDestroyShaderModule(vs.context.device, fragShaderModule, null);
        if (taskShaderModule != null) c.vkDestroyShaderModule(vs.context.device, taskShaderModule, null);
        return false;
    }

    c.vkDestroyShaderModule(vs.context.device, meshShaderModule, null);
    c.vkDestroyShaderModule(vs.context.device, fragShaderModule, null);
    if (taskShaderModule != null) c.vkDestroyShaderModule(vs.context.device, taskShaderModule, null);

    return true;
}

pub export fn vk_mesh_shader_destroy_pipeline(s: ?*types.VulkanState, pipeline: ?*types.MeshShaderPipeline) callconv(.c) void {
    if (s == null or pipeline == null) return;
    const vs = s.?;
    const pipe = pipeline.?;

    if (pipe.pipeline != null) {
        c.vkDestroyPipeline(vs.context.device, pipe.pipeline, null);
        pipe.pipeline = null;
    }

    if (pipe.pipeline_layout != null) {
        c.vkDestroyPipelineLayout(vs.context.device, pipe.pipeline_layout, null);
        pipe.pipeline_layout = null;
    }

    if (pipe.set0_layout != null) {
        c.vkDestroyDescriptorSetLayout(vs.context.device, pipe.set0_layout, null);
        pipe.set0_layout = null;
    }

    if (pipe.set1_layout != null) {
        c.vkDestroyDescriptorSetLayout(vs.context.device, pipe.set1_layout, null);
        pipe.set1_layout = null;
    }

    if (pipe.descriptor_pool != null) {
        c.vkDestroyDescriptorPool(vs.context.device, pipe.descriptor_pool, null);
        pipe.descriptor_pool = null;
    }

    if (pipe.default_material_buffer != null) {
        vk_allocator.vk_allocator_free_buffer(@ptrCast(&vs.allocator), pipe.default_material_buffer, pipe.default_material_allocation);
        pipe.default_material_buffer = null;
        pipe.default_material_memory = null;
        pipe.default_material_allocation = null;
    }
}

pub export fn vk_mesh_shader_draw(cmd_buffer: c.VkCommandBuffer, s: ?*types.VulkanState, pipeline: ?*const types.MeshShaderPipeline, draw_data: ?*const types.MeshShaderDrawData) callconv(.c) void {
    if (cmd_buffer == null or s == null or pipeline == null or draw_data == null) return;
    const vs = s.?;
    const pipe = pipeline.?;
    const data = draw_data.?;

    c.vkCmdBindPipeline(cmd_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipeline);

    if (data.descriptor_set != null) {
        c.vkCmdBindDescriptorSets(cmd_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipeline_layout, 0, 1, &data.descriptor_set, 0, null);
    }

    if (pipe.global_descriptor_set != null) {
        c.vkCmdBindDescriptorSets(cmd_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipeline_layout, 1, 1, &pipe.global_descriptor_set, 0, null);
    }

    // PFN_vkCmdDrawMeshTasksEXT loading and calling
    const func_name = "vkCmdDrawMeshTasksEXT";
    const pfn = c.vkGetDeviceProcAddr(vs.context.device, func_name);
    if (pfn) |func| {
        const cmdDrawMeshTasksEXT = @as(c.PFN_vkCmdDrawMeshTasksEXT, @ptrCast(func));
        cmdDrawMeshTasksEXT.?(cmd_buffer, data.meshlet_count, 1, 0);
    } else {
        log.cardinal_log_error("vkCmdDrawMeshTasksEXT not found!", .{});
    }
}

pub export fn vk_mesh_shader_destroy_draw_data(s: ?*types.VulkanState, draw_data: ?*types.MeshShaderDrawData) callconv(.c) void {
    if (s == null or draw_data == null) return;
    const vs = s.?;
    const data = draw_data.?;

    // Free descriptor set
    if (data.descriptor_set != null and vs.pipelines.mesh_shader_pipeline.descriptor_pool != null) {
        _ = c.vkFreeDescriptorSets(vs.context.device, vs.pipelines.mesh_shader_pipeline.descriptor_pool, 1, &data.descriptor_set);
        data.descriptor_set = null;
    }

    if (data.vertex_buffer != null) {
        vk_allocator.vk_allocator_free_buffer(@ptrCast(&vs.allocator), data.vertex_buffer, data.vertex_allocation);
        data.vertex_buffer = null;
        data.vertex_memory = null;
        data.vertex_allocation = null;
    }

    if (data.meshlet_buffer != null) {
        vk_allocator.vk_allocator_free_buffer(@ptrCast(&vs.allocator), data.meshlet_buffer, data.meshlet_allocation);
        data.meshlet_buffer = null;
        data.meshlet_memory = null;
        data.meshlet_allocation = null;
    }

    if (data.primitive_buffer != null) {
        vk_allocator.vk_allocator_free_buffer(@ptrCast(&vs.allocator), data.primitive_buffer, data.primitive_allocation);
        data.primitive_buffer = null;
        data.primitive_memory = null;
        data.primitive_allocation = null;
    }

    if (data.draw_command_buffer != null) {
        vk_allocator.vk_allocator_free_buffer(@ptrCast(&vs.allocator), data.draw_command_buffer, data.draw_command_allocation);
        data.draw_command_buffer = null;
        data.draw_command_memory = null;
        data.draw_command_allocation = null;
    }

    if (data.uniform_buffer != null) {
        if (data.uniform_mapped != null) {
            vk_allocator.vk_allocator_unmap_memory(@ptrCast(&vs.allocator), data.uniform_allocation);
            data.uniform_mapped = null;
        }
        vk_allocator.vk_allocator_free_buffer(@ptrCast(&vs.allocator), data.uniform_buffer, data.uniform_allocation);
        data.uniform_buffer = null;
        data.uniform_memory = null;
        data.uniform_allocation = null;
    }
    data.uniform_mapped = null;

    // Zero out the struct
    @memset(@as([*]u8, @ptrCast(data))[0..@sizeOf(types.MeshShaderDrawData)], 0);
}

pub export fn vk_mesh_shader_add_pending_cleanup_internal(s: ?*types.VulkanState, draw_data: ?*types.MeshShaderDrawData) callconv(.c) void {
    if (s == null or draw_data == null) return;
    const vs = s.?;
    const data = draw_data.?;
    const frame = vs.sync.current_frame;

    if (vs.pending_cleanup_lists == null) return;

    if (vs.pending_cleanup_counts.?[frame] >= vs.pending_cleanup_capacities.?[frame]) {
        const new_capacity = if (vs.pending_cleanup_capacities.?[frame] == 0) 16 else vs.pending_cleanup_capacities.?[frame] * 2;
        const new_ptr = c.realloc(vs.pending_cleanup_lists.?[frame], new_capacity * @sizeOf(types.MeshShaderDrawData));
        if (new_ptr == null) {
            log.cardinal_log_error("Failed to expand pending cleanup list for frame {d}", .{frame});
            vk_mesh_shader_destroy_draw_data(vs, data);
            return;
        }
        vs.pending_cleanup_lists.?[frame] = @as(?[*]types.MeshShaderDrawData, @ptrCast(@alignCast(new_ptr)));
        vs.pending_cleanup_capacities.?[frame] = new_capacity;
    }

    (vs.pending_cleanup_lists.?[frame].?)[vs.pending_cleanup_counts.?[frame]] = data.*;
    vs.pending_cleanup_counts.?[frame] += 1;
}

pub export fn vk_mesh_shader_process_pending_cleanup(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null or s.?.pending_cleanup_lists == null) return;
    const vs = s.?;
    const frame = vs.sync.current_frame;

    if (vs.pending_cleanup_lists.?[frame] == null) return;

    var i: u32 = 0;
    while (i < vs.pending_cleanup_counts.?[frame]) : (i += 1) {
        vk_mesh_shader_destroy_draw_data(vs, &vs.pending_cleanup_lists.?[frame].?[i]);
    }
    vs.pending_cleanup_counts.?[frame] = 0;
}

pub export fn vk_mesh_shader_generate_meshlets(vertices: ?*const anyopaque, vertex_count: u32, indices: ?*const u32, index_count: u32, max_vertices_per_meshlet_in: u32, max_primitives_per_meshlet_in: u32, out_meshlets: ?*?[*]types.GpuMeshlet, out_meshlet_count: ?*u32) callconv(.c) bool {
    if (vertices == null or indices == null or out_meshlets == null or out_meshlet_count == null) return false;

    var max_vertices = max_vertices_per_meshlet_in;
    if (max_vertices == 0) max_vertices = 64;

    var max_primitives = max_primitives_per_meshlet_in;
    if (max_primitives == 0) max_primitives = 126;

    const triangles_count = index_count / 3;
    const meshlets_capacity = (triangles_count + max_primitives - 1) / max_primitives;

    const meshlets_ptr = c.malloc(meshlets_capacity * @sizeOf(types.GpuMeshlet));
    if (meshlets_ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for meshlets", .{});
        return false;
    }
    const meshlets = @as([*]types.GpuMeshlet, @ptrCast(@alignCast(meshlets_ptr)));

    var current_meshlet: u32 = 0;
    var current_index: u32 = 0;

    while (current_index < index_count) {
        const remaining_indices = index_count - current_index;
        var indices_to_process = remaining_indices;
        if (indices_to_process > max_primitives * 3) {
            indices_to_process = max_primitives * 3;
        }

        var meshlet = &meshlets[current_meshlet];
        meshlet.vertex_offset = 0;
        meshlet.vertex_count = vertex_count;
        meshlet.primitive_offset = current_index;
        meshlet.primitive_count = indices_to_process / 3;

        current_index += indices_to_process;
        current_meshlet += 1;
    }

    out_meshlets.?.* = meshlets;
    out_meshlet_count.?.* = current_meshlet;

    return true;
}

pub export fn vk_mesh_shader_convert_scene_mesh(mesh: ?*const types.CardinalMesh, max_vertices_per_meshlet: u32, max_primitives_per_meshlet: u32, out_meshlets: ?*?[*]types.GpuMeshlet, out_meshlet_count: ?*u32) callconv(.c) bool {
    if (mesh == null) return false;
    const m = mesh.?;
    return vk_mesh_shader_generate_meshlets(m.vertices, m.vertex_count, @ptrCast(m.indices), m.index_count, max_vertices_per_meshlet, max_primitives_per_meshlet, out_meshlets, out_meshlet_count);
}

pub export fn vk_mesh_shader_create_draw_data(s: ?*types.VulkanState, meshlets: ?[*]const types.GpuMeshlet, meshlet_count: u32, vertices: ?*const anyopaque, vertex_size: u32, primitives: ?*const u32, primitive_count: u32, draw_data: ?*types.MeshShaderDrawData) callconv(.c) bool {
    if (s == null or draw_data == null or meshlets == null or vertices == null or primitives == null) return false;
    const vs = s.?;
    const data = draw_data.?;

    @memset(@as([*]u8, @ptrCast(data))[0..@sizeOf(types.MeshShaderDrawData)], 0);
    data.meshlet_count = meshlet_count;

    // 1. Meshlet Buffer
    const meshletBufferSize = meshlet_count * @sizeOf(types.GpuMeshlet);
    var meshletBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (buffer_mgr.vk_buffer_create_device_local(&meshletBuffer, vs.context.device, &vs.allocator, vs.commands.pools.?[0], vs.context.graphics_queue, meshlets, meshletBufferSize, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, vs)) {
        data.meshlet_buffer = meshletBuffer.handle;
        data.meshlet_memory = meshletBuffer.memory;
        data.meshlet_allocation = meshletBuffer.allocation;
    } else {
        log.cardinal_log_error("Failed to create meshlet buffer", .{});
        return false;
    }

    // 2. Vertex Buffer
    var vertexBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (buffer_mgr.vk_buffer_create_device_local(&vertexBuffer, vs.context.device, &vs.allocator, vs.commands.pools.?[0], vs.context.graphics_queue, vertices, vertex_size, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, vs)) {
        data.vertex_buffer = vertexBuffer.handle;
        data.vertex_memory = vertexBuffer.memory;
        data.vertex_allocation = vertexBuffer.allocation;
    } else {
        log.cardinal_log_error("Failed to create vertex buffer for mesh shader", .{});
        vk_mesh_shader_destroy_draw_data(vs, data);
        return false;
    }

    // 3. Primitive Buffer
    const primitiveBufferSize = primitive_count * @sizeOf(u32);
    var primitiveBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (buffer_mgr.vk_buffer_create_device_local(&primitiveBuffer, vs.context.device, &vs.allocator, vs.commands.pools.?[0], vs.context.graphics_queue, primitives, primitiveBufferSize, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, vs)) {
        data.primitive_buffer = primitiveBuffer.handle;
        data.primitive_memory = primitiveBuffer.memory;
        data.primitive_allocation = primitiveBuffer.allocation;
    } else {
        log.cardinal_log_error("Failed to create primitive buffer", .{});
        vk_mesh_shader_destroy_draw_data(vs, data);
        return false;
    }

    // 4. Draw Command Buffer
    const GpuDrawCommand = extern struct {
        meshlet_offset: u32,
        meshlet_count: u32,
        instance_count: u32,
        first_instance: u32,
    };
    const drawCmd = GpuDrawCommand{
        .meshlet_offset = 0,
        .meshlet_count = meshlet_count,
        .instance_count = 1,
        .first_instance = 0,
    };
    data.draw_command_count = 1;

    var drawCmdBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (buffer_mgr.vk_buffer_create_device_local(&drawCmdBuffer, vs.context.device, &vs.allocator, vs.commands.pools.?[0], vs.context.graphics_queue, &drawCmd, @sizeOf(GpuDrawCommand), c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, vs)) {
        data.draw_command_buffer = drawCmdBuffer.handle;
        data.draw_command_memory = drawCmdBuffer.memory;
        data.draw_command_allocation = drawCmdBuffer.allocation;
    } else {
        log.cardinal_log_error("Failed to create draw command buffer", .{});
        vk_mesh_shader_destroy_draw_data(vs, data);
        return false;
    }

    // 5. Uniform Buffer
    const uboSize = @sizeOf(types.MeshShaderUniformBuffer);
    var uboInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
    uboInfo.size = uboSize;
    uboInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    uboInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uboInfo.persistentlyMapped = true;

    var ubo: buffer_mgr.VulkanBuffer = undefined;
    if (buffer_mgr.vk_buffer_create(&ubo, vs.context.device, &vs.allocator, &uboInfo)) {
        data.uniform_buffer = ubo.handle;
        data.uniform_memory = ubo.memory;
        data.uniform_allocation = ubo.allocation;
        data.uniform_mapped = ubo.mapped;

        // Initialize UBO with zeroes
        if (ubo.mapped) |mapped| {
            @memset(@as([*]u8, @ptrCast(mapped))[0..uboSize], 0);
        }
    } else {
        log.cardinal_log_error("Failed to create mesh shader uniform buffer", .{});
        vk_mesh_shader_destroy_draw_data(vs, data);
        return false;
    }

    return true;
}

pub export fn vk_mesh_shader_update_descriptor_buffers(
    s: ?*types.VulkanState,
    pipeline: ?*types.MeshShaderPipeline,
    draw_data: ?*const types.MeshShaderDrawData,
    material_buffer: c.VkBuffer,
    lighting_buffer: c.VkBuffer,
    texture_views: ?[*]c.VkImageView,
    samplers: ?[*]c.VkSampler,
    texture_count: u32,
) callconv(.c) bool {
    if (s == null or pipeline == null) return false;
    const vs = s.?;
    const pipe = pipeline.?;

    // 1. Update Global Descriptor Set (Set 1) if needed
    if (pipe.global_descriptor_set == null) {
        if (pipe.descriptor_pool == null) {
            log.cardinal_log_error("Mesh shader descriptor pool is null", .{});
            return false;
        }
        var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocInfo.descriptorPool = pipe.descriptor_pool;
        allocInfo.descriptorSetCount = 1;
        allocInfo.pSetLayouts = &pipe.set1_layout;

        if (c.vkAllocateDescriptorSets(vs.context.device, &allocInfo, &pipe.global_descriptor_set) != c.VK_SUCCESS) {
            log.cardinal_log_error("Failed to allocate global descriptor set for mesh shader", .{});
            return false;
        }
    }

    // Update Set 1
    {
        var writes: [4]c.VkWriteDescriptorSet = undefined;
        var w: u32 = 0;

        var defaultMatInfo = c.VkDescriptorBufferInfo{
            .buffer = pipe.default_material_buffer,
            .offset = 0,
            .range = c.VK_WHOLE_SIZE,
        };
        var matInfo = c.VkDescriptorBufferInfo{
            .buffer = material_buffer,
            .offset = 0,
            .range = c.VK_WHOLE_SIZE,
        };
        var lightInfo = c.VkDescriptorBufferInfo{
            .buffer = lighting_buffer,
            .offset = 0,
            .range = c.VK_WHOLE_SIZE,
        };

        var imageInfos: ?[*]c.VkDescriptorImageInfo = null;
        if (texture_count > 0 and texture_views != null and samplers != null) {
            const ptr = c.malloc(texture_count * @sizeOf(c.VkDescriptorImageInfo));
            if (ptr) |p| {
                imageInfos = @as([*]c.VkDescriptorImageInfo, @ptrCast(@alignCast(p)));
                var i: u32 = 0;
                while (i < texture_count) : (i += 1) {
                    imageInfos.?[i].sampler = samplers.?[i];
                    imageInfos.?[i].imageView = texture_views.?[i];
                    imageInfos.?[i].imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                }
            }
        }
        defer if (imageInfos) |ptr| c.free(ptr);

        if (pipe.default_material_buffer != null) {
            writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[w].dstSet = pipe.global_descriptor_set;
            writes[w].dstBinding = 0;
            writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            writes[w].descriptorCount = 1;
            writes[w].pBufferInfo = &defaultMatInfo;
            w += 1;
        }

        if (lighting_buffer != null) {
            writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[w].dstSet = pipe.global_descriptor_set;
            writes[w].dstBinding = 1;
            writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            writes[w].descriptorCount = 1;
            writes[w].pBufferInfo = &lightInfo;
            w += 1;
        }

        if (material_buffer != null) {
            writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[w].dstSet = pipe.global_descriptor_set;
            writes[w].dstBinding = 2;
            writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            writes[w].descriptorCount = 1;
            writes[w].pBufferInfo = &matInfo;
            w += 1;
        }

        if (texture_count > 0 and imageInfos != null) {
            writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[w].dstSet = pipe.global_descriptor_set;
            writes[w].dstBinding = 3;
            writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[w].descriptorCount = texture_count;
            writes[w].pImageInfo = imageInfos;
            w += 1;
        }

        if (w > 0) {
            c.vkUpdateDescriptorSets(vs.context.device, w, &writes, 0, null);
        }
    }

    // 2. Allocate and Update Set 0 (Mesh Data)
    if (draw_data) |d| {
        // Need mutable access to draw_data to set descriptor_set
        // But the input is const. The C code casts away const: (MeshShaderDrawData*)draw_data
        const mutable_draw_data = @as(*types.MeshShaderDrawData, @constCast(d));

        if (mutable_draw_data.descriptor_set == null) {
            if (pipe.descriptor_pool == null) return false;

            var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            allocInfo.descriptorPool = pipe.descriptor_pool;
            allocInfo.descriptorSetCount = 1;
            allocInfo.pSetLayouts = &pipe.set0_layout;

            if (c.vkAllocateDescriptorSets(vs.context.device, &allocInfo, &mutable_draw_data.descriptor_set) != c.VK_SUCCESS) {
                log.cardinal_log_error("Failed to allocate mesh draw descriptor set", .{});
                return false;
            }
        }

        var bufferInfos: [6]c.VkDescriptorBufferInfo = undefined;
        var writes: [6]c.VkWriteDescriptorSet = undefined;
        var w: u32 = 0;

        // 0: DrawCmd
        bufferInfos[0] = .{ .buffer = d.draw_command_buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
        writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[w].dstSet = mutable_draw_data.descriptor_set;
        writes[w].dstBinding = 0;
        writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[w].descriptorCount = 1;
        writes[w].pBufferInfo = &bufferInfos[0];
        w += 1;

        // 1: Meshlet
        bufferInfos[1] = .{ .buffer = d.meshlet_buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
        writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[w].dstSet = mutable_draw_data.descriptor_set;
        writes[w].dstBinding = 1;
        writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[w].descriptorCount = 1;
        writes[w].pBufferInfo = &bufferInfos[1];
        w += 1;

        // 2: Culling (Use uniform buffer placeholder)
        bufferInfos[2] = .{ .buffer = d.uniform_buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
        writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[w].dstSet = mutable_draw_data.descriptor_set;
        writes[w].dstBinding = 2;
        writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        writes[w].descriptorCount = 1;
        writes[w].pBufferInfo = &bufferInfos[2];
        w += 1;

        // 3: Vertex
        bufferInfos[3] = .{ .buffer = d.vertex_buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
        writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[w].dstSet = mutable_draw_data.descriptor_set;
        writes[w].dstBinding = 3;
        writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[w].descriptorCount = 1;
        writes[w].pBufferInfo = &bufferInfos[3];
        w += 1;

        // 4: Primitive
        bufferInfos[4] = .{ .buffer = d.primitive_buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
        writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[w].dstSet = mutable_draw_data.descriptor_set;
        writes[w].dstBinding = 4;
        writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[w].descriptorCount = 1;
        writes[w].pBufferInfo = &bufferInfos[4];
        w += 1;

        // 5: Uniform
        bufferInfos[5] = .{ .buffer = d.uniform_buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
        writes[w] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[w].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[w].dstSet = mutable_draw_data.descriptor_set;
        writes[w].dstBinding = 5;
        writes[w].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        writes[w].descriptorCount = 1;
        writes[w].pBufferInfo = &bufferInfos[5];
        w += 1;

        c.vkUpdateDescriptorSets(vs.context.device, w, &writes, 0, null);
    }

    return true;
}

pub export fn vk_mesh_shader_record_frame(s: ?*types.VulkanState, cmd: c.VkCommandBuffer) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;

    if (vs.pipelines.use_mesh_shader_pipeline and vs.pipelines.mesh_shader_pipeline.pipeline != null and vs.current_scene != null) {
        const current_scene = vs.current_scene.?;
        var i: u32 = 0;
        while (i < current_scene.mesh_count) : (i += 1) {
            const mesh = &current_scene.meshes.?[i];
            if (!mesh.visible) continue;

            var meshlets: ?[*]types.GpuMeshlet = null;
            var meshlet_count: u32 = 0;

            if (vk_mesh_shader_convert_scene_mesh(mesh, 64, 126, &meshlets, &meshlet_count)) {
                defer if (meshlets) |ptr| c.free(ptr);

                var draw_data = std.mem.zeroes(types.MeshShaderDrawData);

                if (vk_mesh_shader_create_draw_data(vs, meshlets, meshlet_count, mesh.vertices, mesh.vertex_count * @sizeOf(scene.CardinalVertex), @ptrCast(mesh.indices), mesh.index_count, &draw_data)) {

                    // Update Uniform Buffer
                    if (vs.pipelines.use_pbr_pipeline and vs.pipelines.pbr_pipeline.uniformBufferMapped != null) {
                        const pbrUbo = @as(*types.PBRUniformBufferObject, @ptrCast(@alignCast(vs.pipelines.pbr_pipeline.uniformBufferMapped)));
                        var meshUbo = std.mem.zeroes(types.MeshShaderUniformBuffer);

                        @memcpy(meshUbo.model[0..16], mesh.transform[0..16]);
                        @memcpy(meshUbo.view[0..16], pbrUbo.view[0..16]);
                        @memcpy(meshUbo.proj[0..16], pbrUbo.proj[0..16]);
                        meshUbo.materialIndex = mesh.material_index;

                        if (draw_data.uniform_mapped != null) {
                            @memcpy(@as([*]u8, @ptrCast(draw_data.uniform_mapped))[0..@sizeOf(types.MeshShaderUniformBuffer)], @as([*]const u8, @ptrCast(&meshUbo))[0..@sizeOf(types.MeshShaderUniformBuffer)]);
                        }
                    }

                    // Update descriptors
                    const material_buffer = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.materialBuffer else null;
                    const lighting_buffer = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.lightingBuffer else null;

                    var texture_views: ?[*]c.VkImageView = null;
                    var samplers: ?[*]c.VkSampler = null;
                    var texture_count: u32 = 0;

                    if (vs.pipelines.use_pbr_pipeline and vs.pipelines.pbr_pipeline.textureManager != null) {
                        const tm = vs.pipelines.pbr_pipeline.textureManager;
                        texture_count = tm.?.textureCount;
                        if (texture_count > 0) {
                            const views_ptr = c.malloc(texture_count * @sizeOf(c.VkImageView));
                            const samplers_ptr = c.malloc(texture_count * @sizeOf(c.VkSampler));

                            if (views_ptr != null and samplers_ptr != null) {
                                texture_views = @as([*]c.VkImageView, @ptrCast(@alignCast(views_ptr)));
                                samplers = @as([*]c.VkSampler, @ptrCast(@alignCast(samplers_ptr)));

                                var t: u32 = 0;
                                while (t < texture_count) : (t += 1) {
                                    texture_views.?[t] = tm.?.textures.?[t].view;
                                    const texSampler = tm.?.textures.?[t].sampler;
                                    samplers.?[t] = if (texSampler != null) texSampler else tm.?.defaultSampler;
                                }
                            }
                        }
                    }
                    defer {
                        if (texture_views) |ptr| c.free(@as(?*anyopaque, @ptrCast(ptr)));
                        if (samplers) |ptr| c.free(@as(?*anyopaque, @ptrCast(ptr)));
                    }

                    if (vk_mesh_shader_update_descriptor_buffers(vs, &vs.pipelines.mesh_shader_pipeline, &draw_data, material_buffer, lighting_buffer, texture_views, samplers, texture_count)) {
                        vk_mesh_shader_draw(cmd, vs, &vs.pipelines.mesh_shader_pipeline, &draw_data);
                    }

                    // Schedule cleanup
                    vk_mesh_shader_add_pending_cleanup_internal(vs, &draw_data);
                }
            }
        }
    }
}
