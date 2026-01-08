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

const vk_pso = @import("vulkan_pso.zig");
const vk_desc_mgr = @import("vulkan_descriptor_manager.zig");

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

fn invalidate_pending_sets(vs: *types.VulkanState) void {
    if (vs.pending_cleanup_lists != null) {
        const frames = if (vs.sync.max_frames_in_flight > 0) vs.sync.max_frames_in_flight else 3;
        log.cardinal_log_debug("Invalidating pending descriptor sets", .{});
        var f: u32 = 0;
        var cleared_count: u32 = 0;
        while (f < frames) : (f += 1) {
            if (vs.pending_cleanup_lists.?[f] != null) {
                var i: u32 = 0;
                while (i < vs.pending_cleanup_counts.?[f]) : (i += 1) {
                    if ((vs.pending_cleanup_lists.?[f].?)[i].descriptor_set != null) {
                        (vs.pending_cleanup_lists.?[f].?)[i].descriptor_set = null;
                        cleared_count += 1;
                    }
                }
            }
        }
        log.cardinal_log_debug("Invalidated {d} sets", .{cleared_count});
    }
}

pub export fn vk_mesh_shader_cleanup(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null) return;
    const vs = s.?;
    log.cardinal_log_debug("vk_mesh_shader_cleanup: Starting", .{});

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

    // Allocator for reflection data
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    var arena = std.heap.ArenaAllocator.init(renderer_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Helper map for merging bindings
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

    // Load PSO JSON
    var builder = vk_pso.PipelineBuilder.init(allocator, vs.context.device, pipeline_cache);
    
    var parsed = vk_pso.PipelineBuilder.load_from_json(allocator, "assets/pipelines/mesh_shader.json") catch |err| {
        log.cardinal_log_error("Failed to load mesh pipeline JSON: {s}", .{@errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;

    // Override paths
    if (cfg.mesh_shader_path) |path| descriptor.mesh_shader = .{ .path = std.mem.span(path), .stage = c.VK_SHADER_STAGE_MESH_BIT_EXT };
    if (cfg.fragment_shader_path) |path| descriptor.fragment_shader = .{ .path = std.mem.span(path), .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT };
    if (cfg.task_shader_path) |path| descriptor.task_shader = .{ .path = std.mem.span(path), .stage = c.VK_SHADER_STAGE_TASK_BIT_EXT };

    // Process shaders (reflect + load modules)
    if (process_shader(vs.context.device, cfg.mesh_shader_path, c.VK_SHADER_STAGE_MESH_BIT_EXT, &meshShaderModule, &set0_bindings, &set1_bindings, &pushConstantRange, allocator) catch false) {
        if (descriptor.mesh_shader) |*ms| ms.module_handle = @intFromPtr(meshShaderModule);
    } else {
        return false;
    }
    
    if (cfg.fragment_shader_path != null) {
        if (process_shader(vs.context.device, cfg.fragment_shader_path, c.VK_SHADER_STAGE_FRAGMENT_BIT, &fragShaderModule, &set0_bindings, &set1_bindings, &pushConstantRange, allocator) catch false) {
            if (descriptor.fragment_shader) |*fs| fs.module_handle = @intFromPtr(fragShaderModule);
        } else {
            c.vkDestroyShaderModule(vs.context.device, meshShaderModule, null);
            return false;
        }
    } else {
        descriptor.fragment_shader = null;
    }
    
    if (cfg.task_shader_path != null) {
        if (process_shader(vs.context.device, cfg.task_shader_path, c.VK_SHADER_STAGE_TASK_BIT_EXT, &taskShaderModule, &set0_bindings, &set1_bindings, &pushConstantRange, allocator) catch false) {
            pipe.has_task_shader = true;
            if (descriptor.task_shader) |*ts| ts.module_handle = @intFromPtr(taskShaderModule);
        } else {
             c.vkDestroyShaderModule(vs.context.device, meshShaderModule, null);
             c.vkDestroyShaderModule(vs.context.device, fragShaderModule, null);
             return false;
        }
    } else {
        pipe.has_task_shader = false;
        descriptor.task_shader = null;
    }

    // Create Managers
    const create_manager = struct {
        fn f(alloc: std.mem.Allocator, map: *std.AutoHashMap(u32, BindingInfo), out_manager: *?*types.VulkanDescriptorManager, vulkan_state: *types.VulkanState, max_sets: u32) bool {
             // Allocate manager struct
             const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
             const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
             if (ptr == null) return false;
             const mgr = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(ptr)));
             @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(types.VulkanDescriptorManager)], 0);
             
             out_manager.* = mgr;

             var desc_builder = vk_desc_mgr.DescriptorBuilder.init(alloc);
             defer desc_builder.deinit();

             var keys = std.ArrayListUnmanaged(u32){};
             var kit = map.keyIterator();
             while (kit.next()) |k| keys.append(alloc, k.*) catch return false;
             std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
             defer keys.deinit(alloc);

             for (keys.items) |k| {
                 const entry = map.get(k).?;
                 desc_builder.add_binding(entry.binding.binding, entry.binding.descriptorType, entry.binding.descriptorCount, entry.binding.stageFlags) catch return false;
             }
             
             // Prefer descriptor buffers if supported
             return desc_builder.build(mgr, vulkan_state.context.device, &vulkan_state.allocator, vulkan_state, max_sets, true);
        }
    }.f;

    // Cleanup existing managers if any
    if (pipe.set0_manager != null or pipe.set1_manager != null) {
        // Invalidate pending sets that might reference the old managers
        invalidate_pending_sets(vs);

        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        if (pipe.set0_manager != null) {
            vk_desc_mgr.vk_descriptor_manager_destroy(pipe.set0_manager);
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(pipe.set0_manager)));
            pipe.set0_manager = null;
        }
        if (pipe.set1_manager != null) {
            vk_desc_mgr.vk_descriptor_manager_destroy(pipe.set1_manager);
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(pipe.set1_manager)));
            pipe.set1_manager = null;
        }
    }

    if (!create_manager(allocator, &set0_bindings, &pipe.set0_manager, vs, 1000)) return false;
    if (!create_manager(allocator, &set1_bindings, &pipe.set1_manager, vs, 1000)) return false;

    pipe.global_descriptor_set = null;
    
    // Default Material Buffer (Existing logic)
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
        pipe.defaultMaterialBuffer = defaultMatBuffer;
    } else {
        log.cardinal_log_error("Failed to create default material buffer", .{});
        // Cleanup managers
        if (pipe.set0_manager != null) vk_desc_mgr.vk_descriptor_manager_destroy(pipe.set0_manager);
        if (pipe.set1_manager != null) vk_desc_mgr.vk_descriptor_manager_destroy(pipe.set1_manager);
        return false;
    }

    var setLayouts: [2]c.VkDescriptorSetLayout = undefined;
    setLayouts[0] = vk_desc_mgr.vk_descriptor_manager_get_layout(pipe.set0_manager);
    setLayouts[1] = vk_desc_mgr.vk_descriptor_manager_get_layout(pipe.set1_manager);

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

    // Override State in Descriptor
    descriptor.rasterization.polygon_mode = switch (cfg.polygon_mode) {
        c.VK_POLYGON_MODE_LINE => .line,
        c.VK_POLYGON_MODE_POINT => .point,
        else => .fill,
    };
    descriptor.rasterization.cull_mode = switch (cfg.cull_mode) {
        c.VK_CULL_MODE_NONE => .none,
        c.VK_CULL_MODE_FRONT_BIT => .front,
        c.VK_CULL_MODE_BACK_BIT => .back,
        c.VK_CULL_MODE_FRONT_AND_BACK => .front_and_back,
        else => .back,
    };
    descriptor.rasterization.front_face = if (cfg.front_face == c.VK_FRONT_FACE_CLOCKWISE) .clockwise else .counter_clockwise;
    
    descriptor.depth_stencil.depth_test_enable = cfg.depth_test_enable;
    descriptor.depth_stencil.depth_write_enable = cfg.depth_write_enable;
    descriptor.depth_stencil.depth_compare_op = switch (cfg.depth_compare_op) {
         c.VK_COMPARE_OP_NEVER => .never,
         c.VK_COMPARE_OP_LESS => .less,
         c.VK_COMPARE_OP_EQUAL => .equal,
         c.VK_COMPARE_OP_LESS_OR_EQUAL => .less_or_equal,
         c.VK_COMPARE_OP_GREATER => .greater,
         c.VK_COMPARE_OP_NOT_EQUAL => .not_equal,
         c.VK_COMPARE_OP_GREATER_OR_EQUAL => .greater_or_equal,
         c.VK_COMPARE_OP_ALWAYS => .always,
         else => .less,
    };

    // Color Blend
    if (descriptor.color_blend.attachments.len > 0) {
        // Allocate new slice to hold modified attachments
        const new_atts = builder.allocator.alloc(vk_pso.ColorBlendAttachmentDescriptor, descriptor.color_blend.attachments.len) catch return false;
        
        const map_blend_factor = struct {
             fn f(bf: c.VkBlendFactor) vk_pso.BlendFactor {
                 return switch (bf) {
                     c.VK_BLEND_FACTOR_ZERO => .zero,
                     c.VK_BLEND_FACTOR_ONE => .one,
                     c.VK_BLEND_FACTOR_SRC_COLOR => .src_color,
                     c.VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR => .one_minus_src_color,
                     c.VK_BLEND_FACTOR_DST_COLOR => .dst_color,
                     c.VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR => .one_minus_dst_color,
                     c.VK_BLEND_FACTOR_SRC_ALPHA => .src_alpha,
                     c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA => .one_minus_src_alpha,
                     c.VK_BLEND_FACTOR_DST_ALPHA => .dst_alpha,
                     c.VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA => .one_minus_dst_alpha,
                     else => .zero, // Fallback
                 };
             }
        }.f;

        for (descriptor.color_blend.attachments, 0..) |old_att, i| {
            var att = old_att;
            att.blend_enable = cfg.blend_enable;
            if (att.blend_enable) {
                 att.src_color_blend_factor = map_blend_factor(cfg.src_color_blend_factor);
                 att.dst_color_blend_factor = map_blend_factor(cfg.dst_color_blend_factor);
            }
            new_atts[i] = att;
        }
        descriptor.color_blend.attachments = new_atts;
    }

    // Rendering
    if (descriptor.color_blend.attachments.len > 0) {
        const new_formats = builder.allocator.alloc(c.VkFormat, descriptor.color_blend.attachments.len) catch return false;
        for (0..descriptor.color_blend.attachments.len) |i| {
            if (i == 0) {
                new_formats[i] = swapchain_format;
            } else if (i < descriptor.rendering.color_formats.len) {
                new_formats[i] = descriptor.rendering.color_formats[i];
            } else {
                new_formats[i] = swapchain_format; // Fallback
            }
        }
        descriptor.rendering.color_formats = new_formats;
    } else {
        descriptor.rendering.color_formats = &.{swapchain_format};
    }
    descriptor.rendering.depth_format = depth_format;

    // Check descriptor buffers
    var use_buffers = false;
    if (pipe.set0_manager) |mgr| {
        if (mgr.useDescriptorBuffers) use_buffers = true;
    }
    if (pipe.set1_manager) |mgr| {
        if (mgr.useDescriptorBuffers) use_buffers = true;
    }
    if (use_buffers) {
        descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
    }

    // Build Pipeline
    builder.build(descriptor, pipe.pipeline_layout, &pipe.pipeline) catch |err| {
        log.cardinal_log_error("Failed to build mesh pipeline: {s}", .{@errorName(err)});
        c.vkDestroyPipelineLayout(vs.context.device, pipe.pipeline_layout, null);
        c.vkDestroyShaderModule(vs.context.device, meshShaderModule, null);
        c.vkDestroyShaderModule(vs.context.device, fragShaderModule, null);
        if (taskShaderModule != null) c.vkDestroyShaderModule(vs.context.device, taskShaderModule, null);
        
        // Cleanup managers and buffer
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        if (pipe.set0_manager != null) {
            vk_desc_mgr.vk_descriptor_manager_destroy(pipe.set0_manager);
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(pipe.set0_manager)));
            pipe.set0_manager = null;
        }
        if (pipe.set1_manager != null) {
            vk_desc_mgr.vk_descriptor_manager_destroy(pipe.set1_manager);
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(pipe.set1_manager)));
            pipe.set1_manager = null;
        }
        if (pipe.defaultMaterialBuffer.handle != null) {
            buffer_mgr.vk_buffer_destroy(&pipe.defaultMaterialBuffer, vs.context.device, @ptrCast(&vs.allocator), vs);
        }
        
        return false;
    };

    // Cleanup shader modules (builder didn't own them because we passed handles)
    c.vkDestroyShaderModule(vs.context.device, meshShaderModule, null);
    c.vkDestroyShaderModule(vs.context.device, fragShaderModule, null);
    if (taskShaderModule != null) c.vkDestroyShaderModule(vs.context.device, taskShaderModule, null);

    return true;
}

pub export fn vk_mesh_shader_destroy_pipeline(s: ?*types.VulkanState, pipeline: ?*types.MeshShaderPipeline) callconv(.c) void {
    if (s == null or pipeline == null) return;
    const vs = s.?;
    const pipe = pipeline.?;

    // Invalidate pending descriptor sets associated with this pipeline's pool
    // This prevents VUID-vkFreeDescriptorSets-pDescriptorSets-parent when pending cleanups
    // are processed after the pool has been destroyed and recreated.
    invalidate_pending_sets(vs);

    if (pipe.pipeline != null) {
        c.vkDestroyPipeline(vs.context.device, pipe.pipeline, null);
        pipe.pipeline = null;
    }

    if (pipe.pipeline_layout != null) {
        c.vkDestroyPipelineLayout(vs.context.device, pipe.pipeline_layout, null);
        pipe.pipeline_layout = null;
    }

    if (pipe.set0_manager != null) {
        vk_desc_mgr.vk_descriptor_manager_destroy(pipe.set0_manager);
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(pipe.set0_manager)));
        pipe.set0_manager = null;
    }

    if (pipe.set1_manager != null) {
        vk_desc_mgr.vk_descriptor_manager_destroy(pipe.set1_manager);
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(pipe.set1_manager)));
        pipe.set1_manager = null;
    }

    if (pipe.defaultMaterialBuffer.handle != null) {
        buffer_mgr.vk_buffer_destroy(&pipe.defaultMaterialBuffer, vs.context.device, @ptrCast(&vs.allocator), vs);
        pipe.defaultMaterialBuffer.handle = null;
        pipe.defaultMaterialBuffer.allocation = null;
        pipe.defaultMaterialBuffer.memory = null;
    }
}

pub export fn vk_mesh_shader_draw(cmd_buffer: c.VkCommandBuffer, s: ?*types.VulkanState, pipeline: ?*const types.MeshShaderPipeline, draw_data: ?*const types.MeshShaderDrawData) callconv(.c) void {
    if (cmd_buffer == null or s == null or pipeline == null or draw_data == null) return;
    const vs = s.?;
    const pipe = pipeline.?;
    const data = draw_data.?;

    c.vkCmdBindPipeline(cmd_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipeline);

    var use_buffers_0 = false;
    if (pipe.set0_manager) |mgr| {
        use_buffers_0 = mgr.useDescriptorBuffers;
    }

    if (use_buffers_0 or (data.descriptor_set != null and @intFromPtr(data.descriptor_set) != 0)) {
        const sets = [_]c.VkDescriptorSet{data.descriptor_set};
        vk_desc_mgr.vk_descriptor_manager_bind_sets(pipe.set0_manager, cmd_buffer, pipe.pipeline_layout, 0, 1, &sets, 0, null);
    }

    var use_buffers_1 = false;
    if (pipe.set1_manager) |mgr| {
        use_buffers_1 = mgr.useDescriptorBuffers;
    }

    if (use_buffers_1 or (pipe.global_descriptor_set != null and @intFromPtr(pipe.global_descriptor_set) != 0)) {
        const sets = [_]c.VkDescriptorSet{pipe.global_descriptor_set};
        vk_desc_mgr.vk_descriptor_manager_bind_sets(pipe.set1_manager, cmd_buffer, pipe.pipeline_layout, 1, 1, &sets, 0, null);
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
    if (data.descriptor_set != null) {
        if (vs.pipelines.mesh_shader_pipeline.set0_manager != null) {
            // log.cardinal_log_debug("vk_mesh_shader_destroy_draw_data: Freeing descriptor set {any}", .{data.descriptor_set});
            vk_desc_mgr.vk_descriptor_manager_free_set(vs.pipelines.mesh_shader_pipeline.set0_manager, data.descriptor_set);
        } else {
             log.cardinal_log_warn("vk_mesh_shader_destroy_draw_data: Descriptor set {any} not freed because manager is null (pool likely destroyed)", .{data.descriptor_set});
        }
        data.descriptor_set = null;
    }

    if (data.vertex_buffer != null) {
        // log.cardinal_log_debug("vk_mesh_shader_destroy_draw_data: Freeing vertex buffer {any}", .{data.vertex_buffer});
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
        data.meshlet_buffer_size = meshletBufferSize;
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
        data.vertex_buffer_size = vertex_size;
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
        data.primitive_buffer_size = primitiveBufferSize;
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
    const drawCmdSize = @sizeOf(GpuDrawCommand);

    var drawCmdBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (buffer_mgr.vk_buffer_create_device_local(&drawCmdBuffer, vs.context.device, &vs.allocator, vs.commands.pools.?[0], vs.context.graphics_queue, &drawCmd, drawCmdSize, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, vs)) {
        data.draw_command_buffer = drawCmdBuffer.handle;
        data.draw_command_memory = drawCmdBuffer.memory;
        data.draw_command_allocation = drawCmdBuffer.allocation;
        data.draw_command_buffer_size = drawCmdSize;
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
        data.uniform_buffer_size = uboSize;

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
    lighting_buffer: c.VkBuffer,
    texture_views: ?[*]c.VkImageView,
    samplers: ?[*]c.VkSampler,
    texture_count: u32,
) callconv(.c) bool {
    if (s == null or pipeline == null) return false;
    const pipe = pipeline.?;

    // 1. Update Global Descriptor Set (Set 1) if needed
    if (pipe.global_descriptor_set == null) {
        if (!vk_desc_mgr.vk_descriptor_manager_allocate_sets(pipe.set1_manager, 1, @as([*]c.VkDescriptorSet, @ptrCast(&pipe.global_descriptor_set)))) {
            log.cardinal_log_error("Failed to allocate global descriptor set for mesh shader", .{});
            return false;
        }
    }

    // Update Set 1
    if (lighting_buffer != null) {
        _ = vk_desc_mgr.vk_descriptor_manager_update_buffer(pipe.set1_manager, pipe.global_descriptor_set, 1, lighting_buffer, 0, @sizeOf(types.PBRLightingBuffer));
    }

    if (texture_count > 0 and texture_views != null and samplers != null) {
        _ = vk_desc_mgr.vk_descriptor_manager_update_textures_with_samplers(pipe.set1_manager, pipe.global_descriptor_set, 3, texture_views, samplers, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, texture_count);
    }

    // 2. Allocate and Update Set 0 (Mesh Data)
    if (draw_data) |d| {
        // Need mutable access to draw_data to set descriptor_set
        const mutable_draw_data = @as(*types.MeshShaderDrawData, @constCast(d));

        if (mutable_draw_data.descriptor_set == null) {
            if (!vk_desc_mgr.vk_descriptor_manager_allocate_sets(pipe.set0_manager, 1, @as([*]c.VkDescriptorSet, @ptrCast(&mutable_draw_data.descriptor_set)))) {
                log.cardinal_log_error("Failed to allocate mesh draw descriptor set", .{});
                return false;
            }
        }

        const set = mutable_draw_data.descriptor_set;
        const mgr = pipe.set0_manager;

        // 0: DrawCmd (Storage Buffer)
        _ = vk_desc_mgr.vk_descriptor_manager_update_buffer(mgr, set, 0, d.draw_command_buffer, 0, d.draw_command_buffer_size);
        
        // 1: Meshlet (Storage Buffer)
        _ = vk_desc_mgr.vk_descriptor_manager_update_buffer(mgr, set, 1, d.meshlet_buffer, 0, d.meshlet_buffer_size);
        
        // 2: Culling (Uniform Buffer) -> d.uniform_buffer
        _ = vk_desc_mgr.vk_descriptor_manager_update_buffer(mgr, set, 2, d.uniform_buffer, 0, d.uniform_buffer_size);
        
        // 3: Vertex (Storage Buffer)
        _ = vk_desc_mgr.vk_descriptor_manager_update_buffer(mgr, set, 3, d.vertex_buffer, 0, d.vertex_buffer_size);
        
        // 4: Primitive (Storage Buffer)
        _ = vk_desc_mgr.vk_descriptor_manager_update_buffer(mgr, set, 4, d.primitive_buffer, 0, d.primitive_buffer_size);
        
        // 5: Uniform (Uniform Buffer) -> d.uniform_buffer
        _ = vk_desc_mgr.vk_descriptor_manager_update_buffer(mgr, set, 5, d.uniform_buffer, 0, d.uniform_buffer_size);
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
                    // const material_buffer = if (vs.pipelines.use_pbr_pipeline) vs.pipelines.pbr_pipeline.materialBuffer else null;
                    // const material_buffer: c.VkBuffer = null; // Removed from pipeline
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

                    if (vk_mesh_shader_update_descriptor_buffers(vs, &vs.pipelines.mesh_shader_pipeline, &draw_data, lighting_buffer, texture_views, samplers, texture_count)) {
                        vk_mesh_shader_draw(cmd, vs, &vs.pipelines.mesh_shader_pipeline, &draw_data);
                    }

                    // Schedule cleanup
                    vk_mesh_shader_add_pending_cleanup_internal(vs, &draw_data);
                }
            }
        }
    }
}
