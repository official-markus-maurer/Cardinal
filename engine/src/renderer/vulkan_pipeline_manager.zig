const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;

const vk_pbr = @import("vulkan_pbr.zig");
const vk_mesh_shader = @import("vulkan_mesh_shader.zig");
const vk_simple_pipelines = @import("vulkan_simple_pipelines.zig");
const shader_utils = @import("util/vulkan_shader_utils.zig");

pub const VulkanPipelineType = enum(c_int) {
    VULKAN_PIPELINE_TYPE_GRAPHICS = 0,
    VULKAN_PIPELINE_TYPE_COMPUTE = 1,
    VULKAN_PIPELINE_TYPE_PBR = 2,
    VULKAN_PIPELINE_TYPE_MESH_SHADER = 3,
    VULKAN_PIPELINE_TYPE_SIMPLE_UV = 4,
    VULKAN_PIPELINE_TYPE_SIMPLE_WIREFRAME = 5,
};

pub const VulkanPipelineInfo = extern struct {
    pipeline: c.VkPipeline,
    layout: c.VkPipelineLayout,
    type: VulkanPipelineType,
    is_active: bool,
    needs_recreation: bool,
};

pub const VulkanGraphicsPipelineCreateInfo = extern struct {
    vertex_shader_path: ?[*:0]const u8,
    fragment_shader_path: ?[*:0]const u8,
    geometry_shader_path: ?[*:0]const u8,
    color_format: c.VkFormat,
    depth_format: c.VkFormat,
    enable_wireframe: bool,
    enable_depth_test: bool,
    enable_depth_write: bool,
    cull_mode: c.VkCullModeFlags,
    front_face: c.VkFrontFace,
    descriptor_set_layout_count: u32,
    descriptor_set_layouts: ?[*]c.VkDescriptorSetLayout,
    push_constant_range_count: u32,
    push_constant_ranges: ?[*]c.VkPushConstantRange,
};

pub const VulkanComputePipelineCreateInfo = extern struct {
    compute_shader_path: ?[*:0]const u8,
    descriptor_set_layout_count: u32,
    descriptor_set_layouts: ?[*]c.VkDescriptorSetLayout,
    push_constant_range_count: u32,
    push_constant_ranges: ?[*]c.VkPushConstantRange,
};

pub const VulkanPipelineManager = extern struct {
    vulkan_state: ?*types.VulkanState,

    // Pipeline tracking
    pipelines: ?[*]VulkanPipelineInfo,
    pipeline_count: u32,
    pipeline_capacity: u32,

    // Specialized pipeline states
    pbr_pipeline_enabled: bool,
    mesh_shader_pipeline_enabled: bool,
    simple_pipelines_enabled: bool,

    // Pipeline cache for faster recreation
    pipeline_cache: c.VkPipelineCache,

    // Shader module cache
    shader_modules: ?[*]c.VkShaderModule,
    shader_paths: ?[*][*c]u8, // char**
    shader_module_count: u32,
    shader_module_capacity: u32,
};

// Helper to cast VulkanState
fn get_state(manager: *VulkanPipelineManager) *types.VulkanState {
    return manager.vulkan_state.?;
}

// Internal helper functions
fn create_pipeline_cache(manager: *VulkanPipelineManager) bool {
    var cache_info = std.mem.zeroes(c.VkPipelineCacheCreateInfo);
    cache_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO;

    const s = get_state(manager);

    // Try to load cache
    var file_buffer: []u8 = &[_]u8{};
    const file = std.fs.cwd().openFile("pipeline_cache.bin", .{}) catch null;
    if (file) |f| {
        defer f.close();
        if (f.stat()) |stat| {
            if (stat.size > 0) {
                const alloc = std.heap.c_allocator;
                if (alloc.alloc(u8, stat.size)) |buf| {
                    if (f.readAll(buf)) |read_bytes| {
                        if (read_bytes == stat.size) {
                            cache_info.initialDataSize = stat.size;
                            cache_info.pInitialData = buf.ptr;
                            file_buffer = buf;
                            log.cardinal_log_info("[PIPELINE_MANAGER] Loading pipeline cache ({d} bytes)", .{stat.size});
                        }
                    } else |_| {}
                } else |_| {}
            }
        } else |_| {}
    }
    defer if (file_buffer.len > 0) std.heap.c_allocator.free(file_buffer);

    if (c.vkCreatePipelineCache(s.context.device, &cache_info, null, &manager.pipeline_cache) != c.VK_SUCCESS) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to create pipeline cache", .{});
        return false;
    }
    return true;
}

fn destroy_pipeline_cache(manager: *VulkanPipelineManager) void {
    if (manager.pipeline_cache != null) {
        const s = get_state(manager);

        // Save cache
        var size: usize = 0;
        if (c.vkGetPipelineCacheData(s.context.device, manager.pipeline_cache, &size, null) == c.VK_SUCCESS) {
             if (size > 0) {
                 const alloc = std.heap.c_allocator;
                 if (alloc.alloc(u8, size)) |buf| {
                     defer alloc.free(buf);
                     if (c.vkGetPipelineCacheData(s.context.device, manager.pipeline_cache, &size, buf.ptr) == c.VK_SUCCESS) {
                         if (std.fs.cwd().createFile("pipeline_cache.bin", .{})) |file| {
                             defer file.close();
                             _ = file.writeAll(buf) catch {};
                             log.cardinal_log_info("[PIPELINE_MANAGER] Saved pipeline cache ({d} bytes)", .{size});
                         } else |_| {
                             log.cardinal_log_warn("[PIPELINE_MANAGER] Failed to create cache file", .{});
                         }
                     }
                 } else |_| {}
             }
        }

        c.vkDestroyPipelineCache(s.context.device, manager.pipeline_cache, null);
        manager.pipeline_cache = null;
    }
}

fn ensure_pipeline_capacity(manager: *VulkanPipelineManager) bool {
    if (manager.pipeline_count >= manager.pipeline_capacity) {
        const new_capacity = manager.pipeline_capacity * 2;
        const new_pipelines = c.realloc(@as(?*anyopaque, @ptrCast(manager.pipelines)), @sizeOf(VulkanPipelineInfo) * new_capacity);
        if (new_pipelines == null) {
            log.cardinal_log_error("[PIPELINE_MANAGER] Failed to expand pipeline array", .{});
            return false;
        }
        manager.pipelines = @ptrCast(@alignCast(new_pipelines));
        manager.pipeline_capacity = new_capacity;
    }
    return true;
}

fn add_pipeline_to_manager(manager: *VulkanPipelineManager, info: *const VulkanPipelineInfo) bool {
    if (!ensure_pipeline_capacity(manager)) {
        return false;
    }
    manager.pipelines.?[manager.pipeline_count] = info.*;
    manager.pipeline_count += 1;
    return true;
}

fn remove_pipeline_from_manager(manager: *VulkanPipelineManager, type_val: VulkanPipelineType) void {
    var i: u32 = 0;
    while (i < manager.pipeline_count) : (i += 1) {
        if (manager.pipelines.?[i].type == type_val) {
            if (i < manager.pipeline_count - 1) {
                manager.pipelines.?[i] = manager.pipelines.?[manager.pipeline_count - 1];
            }
            manager.pipeline_count -= 1;
            break;
        }
    }
}

fn ensure_shader_capacity(manager: *VulkanPipelineManager) bool {
    if (manager.shader_module_count >= manager.shader_module_capacity) {
        const new_capacity = manager.shader_module_capacity * 2;
        const new_modules = c.realloc(@as(?*anyopaque, @ptrCast(manager.shader_modules)), @sizeOf(c.VkShaderModule) * new_capacity);
        const new_paths = c.realloc(@as(?*anyopaque, @ptrCast(manager.shader_paths)), @sizeOf([*c]u8) * new_capacity);

        if (new_modules == null or new_paths == null) {
            log.cardinal_log_error("[PIPELINE_MANAGER] Failed to expand shader cache", .{});
            return false;
        }
        manager.shader_modules = @ptrCast(@alignCast(new_modules));
        manager.shader_paths = @ptrCast(@alignCast(new_paths));
        manager.shader_module_capacity = new_capacity;
    }
    return true;
}

fn find_shader_index(manager: *VulkanPipelineManager, shader_path: [*c]const u8) i32 {
    var i: u32 = 0;
    while (i < manager.shader_module_count) : (i += 1) {
        if (manager.shader_paths.?[i] != null and c.strcmp(manager.shader_paths.?[i], shader_path) == 0) {
            return @intCast(i);
        }
    }
    return -1;
}

// Core pipeline manager functions

export fn vulkan_pipeline_manager_init(manager: ?*VulkanPipelineManager, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (manager == null or vulkan_state == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Invalid parameters for initialization", .{});
        return false;
    }
    const m = manager.?;
    const s = vulkan_state.?;

    @memset(@as([*]u8, @ptrCast(m))[0..@sizeOf(VulkanPipelineManager)], 0);
    m.vulkan_state = s;

    m.pipeline_capacity = 16;
    m.pipelines = @ptrCast(@alignCast(c.malloc(@sizeOf(VulkanPipelineInfo) * m.pipeline_capacity)));
    if (m.pipelines == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to allocate pipeline array", .{});
        return false;
    }

    m.shader_module_capacity = 32;
    m.shader_modules = @ptrCast(@alignCast(c.malloc(@sizeOf(c.VkShaderModule) * m.shader_module_capacity)));
    m.shader_paths = @ptrCast(@alignCast(c.malloc(@sizeOf([*c]u8) * m.shader_module_capacity)));

    if (m.shader_modules == null or m.shader_paths == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to allocate shader cache", .{});
        c.free(@as(?*anyopaque, @ptrCast(m.pipelines)));
        if (m.shader_modules != null) c.free(@as(?*anyopaque, @ptrCast(m.shader_modules)));
        if (m.shader_paths != null) c.free(@as(?*anyopaque, @ptrCast(m.shader_paths)));
        return false;
    }

    if (!create_pipeline_cache(m)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to create pipeline cache", .{});
        c.free(@as(?*anyopaque, @ptrCast(m.pipelines)));
        c.free(@as(?*anyopaque, @ptrCast(m.shader_modules)));
        c.free(@as(?*anyopaque, @ptrCast(m.shader_paths)));
        return false;
    }

    log.cardinal_log_info("[PIPELINE_MANAGER] Initialized successfully", .{});
    return true;
}

export fn vulkan_pipeline_manager_destroy(manager: ?*VulkanPipelineManager) callconv(.c) void {
    if (manager == null or manager.?.vulkan_state == null) {
        return;
    }
    const m = manager.?;
    const s = get_state(m);

    _ = c.vkDeviceWaitIdle(s.context.device);

    var i: u32 = 0;
    while (i < m.pipeline_count) : (i += 1) {
        const info = &m.pipelines.?[i];
        if (info.pipeline != null) {
            c.vkDestroyPipeline(s.context.device, info.pipeline, null);
        }
        if (info.layout != null) {
            c.vkDestroyPipelineLayout(s.context.device, info.layout, null);
        }
    }

    vulkan_pipeline_manager_clear_shader_cache(m);
    destroy_pipeline_cache(m);

    c.free(@as(?*anyopaque, @ptrCast(m.pipelines)));
    c.free(@as(?*anyopaque, @ptrCast(m.shader_modules)));
    c.free(@as(?*anyopaque, @ptrCast(m.shader_paths)));

    @memset(@as([*]u8, @ptrCast(m))[0..@sizeOf(VulkanPipelineManager)], 0);
    log.cardinal_log_info("[PIPELINE_MANAGER] Destroyed successfully", .{});
}

export fn vulkan_pipeline_manager_recreate_all(manager: ?*VulkanPipelineManager, new_color_format: c.VkFormat, new_depth_format: c.VkFormat) callconv(.c) bool {
    if (manager == null or manager.?.vulkan_state == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Invalid parameters for recreation", .{});
        return false;
    }
    const m = manager.?;
    const s = get_state(m);

    _ = c.vkDeviceWaitIdle(s.context.device);

    var i: u32 = 0;
    while (i < m.pipeline_count) : (i += 1) {
        m.pipelines.?[i].needs_recreation = true;
    }

    var success = true;

    if (m.pbr_pipeline_enabled) {
        vulkan_pipeline_manager_disable_pbr(m);
        if (!vulkan_pipeline_manager_enable_pbr(m, new_color_format, new_depth_format)) {
            log.cardinal_log_error("[PIPELINE_MANAGER] Failed to recreate PBR pipeline", .{});
            success = false;
        }
    }

    if (m.mesh_shader_pipeline_enabled and s.context.supports_mesh_shader) {
        var config = std.mem.zeroes(types.MeshShaderPipelineConfig);
        config.task_shader_path = "shaders/mesh_task.spv";
        config.mesh_shader_path = "shaders/mesh.spv";
        config.fragment_shader_path = "shaders/mesh_frag.spv";
        config.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        config.polygon_mode = c.VK_POLYGON_MODE_FILL;
        config.cull_mode = c.VK_CULL_MODE_BACK_BIT;
        config.front_face = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        config.depth_test_enable = true;
        config.depth_write_enable = true;
        config.depth_compare_op = c.VK_COMPARE_OP_LESS;
        config.blend_enable = false;
        config.max_vertices_per_meshlet = 64;
        config.max_primitives_per_meshlet = 126;

        vulkan_pipeline_manager_disable_mesh_shader(m);
        if (!vulkan_pipeline_manager_enable_mesh_shader(m, &config, new_color_format, new_depth_format)) {
            log.cardinal_log_error("[PIPELINE_MANAGER] Failed to recreate mesh shader pipeline", .{});
            success = false;
        }
    }

    if (m.simple_pipelines_enabled) {
        vulkan_pipeline_manager_destroy_simple_pipelines(m);
        if (!vulkan_pipeline_manager_create_simple_pipelines(m)) {
            log.cardinal_log_error("[PIPELINE_MANAGER] Failed to recreate simple pipelines", .{});
            success = false;
        }
    }

    if (success) {
        log.cardinal_log_info("[PIPELINE_MANAGER] All pipelines recreated successfully", .{});
    }

    return success;
}

export fn vulkan_pipeline_manager_create_graphics(manager: ?*VulkanPipelineManager, create_info: ?*const VulkanGraphicsPipelineCreateInfo, pipeline_info: ?*VulkanPipelineInfo) callconv(.c) bool {
    if (manager == null or create_info == null or pipeline_info == null or manager.?.vulkan_state == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Invalid parameters for graphics pipeline creation", .{});
        return false;
    }
    const m = manager.?;
    const ci = create_info.?;
    const pi = pipeline_info.?;
    const s = get_state(m);
    const device = s.context.device;

    var vert_shader: c.VkShaderModule = null;
    var frag_shader: c.VkShaderModule = null;
    var geom_shader: c.VkShaderModule = null;

    if (!vulkan_pipeline_manager_load_shader(m, ci.vertex_shader_path, &vert_shader)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to load vertex shader: {s}", .{if (ci.vertex_shader_path) |p| std.mem.span(p) else "null"});
        return false;
    }

    if (!vulkan_pipeline_manager_load_shader(m, ci.fragment_shader_path, &frag_shader)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to load fragment shader: {s}", .{if (ci.fragment_shader_path) |p| std.mem.span(p) else "null"});
        return false;
    }

    if (ci.geometry_shader_path != null) {
        if (!vulkan_pipeline_manager_load_shader(m, ci.geometry_shader_path, &geom_shader)) {
            log.cardinal_log_error("[PIPELINE_MANAGER] Failed to load geometry shader: {s}", .{if (ci.geometry_shader_path) |p| std.mem.span(p) else "null"});
            return false;
        }
    }

    var shader_stages: [3]c.VkPipelineShaderStageCreateInfo = undefined;
    var stage_count: u32 = 0;

    shader_stages[stage_count] = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
    shader_stages[stage_count].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shader_stages[stage_count].stage = c.VK_SHADER_STAGE_VERTEX_BIT;
    shader_stages[stage_count].module = vert_shader;
    shader_stages[stage_count].pName = "main";
    stage_count += 1;

    if (geom_shader != null) {
        shader_stages[stage_count] = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        shader_stages[stage_count].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        shader_stages[stage_count].stage = c.VK_SHADER_STAGE_GEOMETRY_BIT;
        shader_stages[stage_count].module = geom_shader;
        shader_stages[stage_count].pName = "main";
        stage_count += 1;
    }

    shader_stages[stage_count] = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
    shader_stages[stage_count].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shader_stages[stage_count].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
    shader_stages[stage_count].module = frag_shader;
    shader_stages[stage_count].pName = "main";
    stage_count += 1;

    var layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layout_info.setLayoutCount = ci.descriptor_set_layout_count;
    layout_info.pSetLayouts = ci.descriptor_set_layouts;
    layout_info.pushConstantRangeCount = ci.push_constant_range_count;
    layout_info.pPushConstantRanges = ci.push_constant_ranges;

    var pipeline_layout: c.VkPipelineLayout = null;
    var result = c.vkCreatePipelineLayout(device, &layout_info, null, &pipeline_layout);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to create pipeline layout: {d}", .{result});
        return false;
    }

    var vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

    var input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
    input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
    viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;

    var rasterizer = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
    rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.polygonMode = if (ci.enable_wireframe) c.VK_POLYGON_MODE_LINE else c.VK_POLYGON_MODE_FILL;
    rasterizer.lineWidth = 1.0;
    rasterizer.cullMode = ci.cull_mode;
    rasterizer.frontFace = ci.front_face;

    var multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
    depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depth_stencil.depthTestEnable = if (ci.enable_depth_test) c.VK_TRUE else c.VK_FALSE;
    depth_stencil.depthWriteEnable = if (ci.enable_depth_write) c.VK_TRUE else c.VK_FALSE;
    depth_stencil.depthCompareOp = c.VK_COMPARE_OP_LESS;

    var color_blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    color_blend_attachment.blendEnable = c.VK_FALSE;

    var color_blending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    color_blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    color_blending.attachmentCount = 1;
    color_blending.pAttachments = &color_blend_attachment;

    var dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    var dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
    dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic_state.dynamicStateCount = 2;
    dynamic_state.pDynamicStates = &dynamic_states;

    var pipeline_rendering = std.mem.zeroes(c.VkPipelineRenderingCreateInfo);
    pipeline_rendering.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    pipeline_rendering.colorAttachmentCount = 1;
    pipeline_rendering.pColorAttachmentFormats = @constCast(&ci.color_format);
    pipeline_rendering.depthAttachmentFormat = ci.depth_format;

    var pipeline_create_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    pipeline_create_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipeline_create_info.pNext = &pipeline_rendering;
    pipeline_create_info.stageCount = stage_count;
    pipeline_create_info.pStages = &shader_stages;
    pipeline_create_info.pVertexInputState = &vertex_input;
    pipeline_create_info.pInputAssemblyState = &input_assembly;
    pipeline_create_info.pViewportState = &viewport_state;
    pipeline_create_info.pRasterizationState = &rasterizer;
    pipeline_create_info.pMultisampleState = &multisampling;
    pipeline_create_info.pDepthStencilState = &depth_stencil;
    pipeline_create_info.pColorBlendState = &color_blending;
    pipeline_create_info.pDynamicState = &dynamic_state;
    pipeline_create_info.layout = pipeline_layout;

    var pipeline: c.VkPipeline = null;
    result = c.vkCreateGraphicsPipelines(device, m.pipeline_cache, 1, &pipeline_create_info, null, &pipeline);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to create graphics pipeline: {d}", .{result});
        c.vkDestroyPipelineLayout(device, pipeline_layout, null);
        return false;
    }

    pi.pipeline = pipeline;
    pi.layout = pipeline_layout;
    pi.type = .VULKAN_PIPELINE_TYPE_GRAPHICS;
    pi.is_active = true;
    pi.needs_recreation = false;

    if (!add_pipeline_to_manager(m, pi)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to add pipeline to manager", .{});
        c.vkDestroyPipeline(device, pipeline, null);
        c.vkDestroyPipelineLayout(device, pipeline_layout, null);
        return false;
    }

    log.cardinal_log_info("[PIPELINE_MANAGER] Graphics pipeline created successfully", .{});
    return true;
}

export fn vulkan_pipeline_manager_create_compute(manager: ?*VulkanPipelineManager, create_info: ?*const VulkanComputePipelineCreateInfo, pipeline_info: ?*VulkanPipelineInfo) callconv(.c) bool {
    if (manager == null or create_info == null or pipeline_info == null or manager.?.vulkan_state == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Invalid parameters for compute pipeline creation", .{});
        return false;
    }
    const m = manager.?;
    const ci = create_info.?;
    const pi = pipeline_info.?;
    const s = get_state(m);
    const device = s.context.device;

    var compute_shader: c.VkShaderModule = null;
    if (!vulkan_pipeline_manager_load_shader(m, ci.compute_shader_path, &compute_shader)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to load compute shader: {s}", .{if (ci.compute_shader_path) |p| std.mem.span(p) else "null"});
        return false;
    }

    var layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layout_info.setLayoutCount = ci.descriptor_set_layout_count;
    layout_info.pSetLayouts = ci.descriptor_set_layouts;
    layout_info.pushConstantRangeCount = ci.push_constant_range_count;
    layout_info.pPushConstantRanges = ci.push_constant_ranges;

    var pipeline_layout: c.VkPipelineLayout = null;
    var result = c.vkCreatePipelineLayout(device, &layout_info, null, &pipeline_layout);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to create compute pipeline layout: {d}", .{result});
        return false;
    }

    var pipeline_create_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
    pipeline_create_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    pipeline_create_info.stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    pipeline_create_info.stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
    pipeline_create_info.stage.module = compute_shader;
    pipeline_create_info.stage.pName = "main";
    pipeline_create_info.layout = pipeline_layout;

    var pipeline: c.VkPipeline = null;
    result = c.vkCreateComputePipelines(device, m.pipeline_cache, 1, &pipeline_create_info, null, &pipeline);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to create compute pipeline: {d}", .{result});
        c.vkDestroyPipelineLayout(device, pipeline_layout, null);
        return false;
    }

    pi.pipeline = pipeline;
    pi.layout = pipeline_layout;
    pi.type = .VULKAN_PIPELINE_TYPE_COMPUTE;
    pi.is_active = true;
    pi.needs_recreation = false;

    if (!add_pipeline_to_manager(m, pi)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to add compute pipeline to manager", .{});
        c.vkDestroyPipeline(device, pipeline, null);
        c.vkDestroyPipelineLayout(device, pipeline_layout, null);
        return false;
    }

    log.cardinal_log_info("[PIPELINE_MANAGER] Compute pipeline created successfully", .{});
    return true;
}

export fn vulkan_pipeline_manager_enable_pbr(manager: ?*VulkanPipelineManager, color_format: c.VkFormat, depth_format: c.VkFormat) callconv(.c) bool {
    if (manager == null or manager.?.vulkan_state == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Invalid parameters for PBR pipeline", .{});
        return false;
    }
    const m = manager.?;
    if (m.pbr_pipeline_enabled) {
        log.cardinal_log_warn("[PIPELINE_MANAGER] PBR pipeline already enabled", .{});
        return true;
    }

    const s = get_state(m);

    if (!vk_pbr.vk_pbr_pipeline_create(&s.pipelines.pbr_pipeline, s.context.device, s.context.physical_device, color_format, depth_format, s.commands.pools.?[0], s.context.graphics_queue, &s.allocator, s, m.pipeline_cache)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to create PBR pipeline", .{});
        return false;
    }

    m.pbr_pipeline_enabled = true;
    s.pipelines.use_pbr_pipeline = true;

    log.cardinal_log_info("[PIPELINE_MANAGER] PBR pipeline enabled successfully", .{});
    return true;
}

export fn vulkan_pipeline_manager_disable_pbr(manager: ?*VulkanPipelineManager) callconv(.c) void {
    if (manager == null or manager.?.vulkan_state == null or !manager.?.pbr_pipeline_enabled) {
        return;
    }
    const m = manager.?;
    const s = get_state(m);

    _ = c.vkDeviceWaitIdle(s.context.device);

    vk_pbr.vk_pbr_pipeline_destroy(&s.pipelines.pbr_pipeline, s.context.device, &s.allocator);

    m.pbr_pipeline_enabled = false;
    s.pipelines.use_pbr_pipeline = false;

    log.cardinal_log_info("[PIPELINE_MANAGER] PBR pipeline disabled", .{});
}

export fn vulkan_pipeline_manager_enable_mesh_shader(manager: ?*VulkanPipelineManager, config: ?*const types.MeshShaderPipelineConfig, color_format: c.VkFormat, depth_format: c.VkFormat) callconv(.c) bool {
    if (manager == null or manager.?.vulkan_state == null or config == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Invalid parameters for mesh shader pipeline", .{});
        return false;
    }
    const m = manager.?;
    const s = get_state(m);

    if (!s.context.supports_mesh_shader) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Mesh shader not supported on this device", .{});
        return false;
    }

    if (m.mesh_shader_pipeline_enabled) {
        log.cardinal_log_warn("[PIPELINE_MANAGER] Mesh shader pipeline already enabled", .{});
        return true;
    }

    if (!vk_mesh_shader.vk_mesh_shader_create_pipeline(s, config, color_format, depth_format, &s.pipelines.mesh_shader_pipeline, m.pipeline_cache)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to create mesh shader pipeline", .{});
        return false;
    }

    m.mesh_shader_pipeline_enabled = true;
    s.pipelines.use_mesh_shader_pipeline = true;

    log.cardinal_log_info("[PIPELINE_MANAGER] Mesh shader pipeline enabled successfully", .{});
    return true;
}

export fn vulkan_pipeline_manager_disable_mesh_shader(manager: ?*VulkanPipelineManager) callconv(.c) void {
    if (manager == null or manager.?.vulkan_state == null or !manager.?.mesh_shader_pipeline_enabled) {
        return;
    }
    const m = manager.?;
    const s = get_state(m);

    _ = c.vkDeviceWaitIdle(s.context.device);

    vk_mesh_shader.vk_mesh_shader_destroy_pipeline(s, &s.pipelines.mesh_shader_pipeline);

    m.mesh_shader_pipeline_enabled = false;
    s.pipelines.use_mesh_shader_pipeline = false;

    log.cardinal_log_info("[PIPELINE_MANAGER] Mesh shader pipeline disabled", .{});
}

export fn vulkan_pipeline_manager_create_simple_pipelines(manager: ?*VulkanPipelineManager) callconv(.c) bool {
    if (manager == null or manager.?.vulkan_state == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Invalid parameters for simple pipelines", .{});
        return false;
    }
    const m = manager.?;
    if (m.simple_pipelines_enabled) {
        log.cardinal_log_warn("[PIPELINE_MANAGER] Simple pipelines already enabled", .{});
        return true;
    }

    const s = get_state(m);

    if (!vk_simple_pipelines.vk_create_simple_pipelines(s, m.pipeline_cache)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to create simple pipelines", .{});
        return false;
    }

    m.simple_pipelines_enabled = true;

    log.cardinal_log_info("[PIPELINE_MANAGER] Simple pipelines created successfully", .{});
    return true;
}

export fn vulkan_pipeline_manager_destroy_simple_pipelines(manager: ?*VulkanPipelineManager) callconv(.c) void {
    if (manager == null or manager.?.vulkan_state == null or !manager.?.simple_pipelines_enabled) {
        return;
    }
    const m = manager.?;
    const s = get_state(m);

    vk_simple_pipelines.vk_destroy_simple_pipelines(s);

    m.simple_pipelines_enabled = false;

    log.cardinal_log_info("[PIPELINE_MANAGER] Simple pipelines destroyed", .{});
}

export fn vulkan_pipeline_manager_get_pipeline(manager: ?*VulkanPipelineManager, type_val: VulkanPipelineType) callconv(.c) ?*VulkanPipelineInfo {
    if (manager == null) {
        return null;
    }
    const m = manager.?;
    var i: u32 = 0;
    while (i < m.pipeline_count) : (i += 1) {
        if (m.pipelines.?[i].type == type_val and m.pipelines.?[i].is_active) {
            return &m.pipelines.?[i];
        }
    }
    return null;
}

export fn vulkan_pipeline_manager_destroy_pipeline(manager: ?*VulkanPipelineManager, type_val: VulkanPipelineType) callconv(.c) void {
    if (manager == null or manager.?.vulkan_state == null) {
        return;
    }
    const m = manager.?;
    const s = get_state(m);

    var i: u32 = 0;
    while (i < m.pipeline_count) : (i += 1) {
        const info = &m.pipelines.?[i];
        if (info.type == type_val and info.is_active) {
            if (info.pipeline != null) {
                c.vkDestroyPipeline(s.context.device, info.pipeline, null);
                info.pipeline = null;
            }
            if (info.layout != null) {
                c.vkDestroyPipelineLayout(s.context.device, info.layout, null);
                info.layout = null;
            }
            info.is_active = false;
            break;
        }
    }

    remove_pipeline_from_manager(m, type_val);
}

export fn vulkan_pipeline_manager_is_supported(manager: ?*VulkanPipelineManager, type_val: VulkanPipelineType) callconv(.c) bool {
    if (manager == null or manager.?.vulkan_state == null) {
        return false;
    }
    const m = manager.?;
    const s = get_state(m);

    switch (type_val) {
        .VULKAN_PIPELINE_TYPE_MESH_SHADER => return s.context.supports_mesh_shader,
        .VULKAN_PIPELINE_TYPE_GRAPHICS, .VULKAN_PIPELINE_TYPE_COMPUTE, .VULKAN_PIPELINE_TYPE_PBR, .VULKAN_PIPELINE_TYPE_SIMPLE_UV, .VULKAN_PIPELINE_TYPE_SIMPLE_WIREFRAME => return true,
    }
}

export fn vulkan_pipeline_manager_load_shader(manager: ?*VulkanPipelineManager, shader_path: [*c]const u8, shader_module: ?*c.VkShaderModule) callconv(.c) bool {
    if (manager == null or shader_path == null or shader_module == null or manager.?.vulkan_state == null) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Invalid parameters for shader loading", .{});
        return false;
    }
    const m = manager.?;
    const s = get_state(m);

    const cached = vulkan_pipeline_manager_get_cached_shader(m, shader_path);
    if (cached != null) {
        shader_module.?.* = cached;
        return true;
    }

    if (!shader_utils.vk_shader_create_module(s.context.device, shader_path, shader_module.?)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to load shader: {s}", .{if (shader_path) |p| std.mem.span(p) else "null"});
        return false;
    }

    if (!ensure_shader_capacity(m)) {
        log.cardinal_log_error("[PIPELINE_MANAGER] Failed to expand shader cache", .{});
        c.vkDestroyShaderModule(s.context.device, shader_module.?.*, null);
        return false;
    }

    const index = m.shader_module_count;
    m.shader_module_count += 1;
    m.shader_modules.?[index] = shader_module.?.*;
    m.shader_paths.?[index] = @ptrCast(c.malloc(c.strlen(shader_path) + 1));
    if (m.shader_paths.?[index] != null) {
        _ = c.strcpy(m.shader_paths.?[index], shader_path);
    }

    return true;
}

export fn vulkan_pipeline_manager_get_cached_shader(manager: ?*VulkanPipelineManager, shader_path: [*c]const u8) callconv(.c) c.VkShaderModule {
    if (manager == null or shader_path == null) {
        return null;
    }
    const m = manager.?;
    const index = find_shader_index(m, shader_path);
    if (index >= 0) {
        return m.shader_modules.?[@intCast(index)];
    }
    return null;
}

export fn vulkan_pipeline_manager_clear_shader_cache(manager: ?*VulkanPipelineManager) callconv(.c) void {
    if (manager == null or manager.?.vulkan_state == null) {
        return;
    }
    const m = manager.?;
    const s = get_state(m);
    const device = s.context.device;

    var i: u32 = 0;
    while (i < m.shader_module_count) : (i += 1) {
        if (m.shader_modules.?[i] != null) {
            c.vkDestroyShaderModule(device, m.shader_modules.?[i], null);
        }
        if (m.shader_paths.?[i] != null) {
            c.free(@as(?*anyopaque, @ptrCast(m.shader_paths.?[i])));
        }
    }

    m.shader_module_count = 0;
}

export fn vulkan_pipeline_manager_is_pbr_enabled(manager: ?*VulkanPipelineManager) callconv(.c) bool {
    return if (manager) |m| m.pbr_pipeline_enabled else false;
}

export fn vulkan_pipeline_manager_is_mesh_shader_enabled(manager: ?*VulkanPipelineManager) callconv(.c) bool {
    return if (manager) |m| m.mesh_shader_pipeline_enabled else false;
}

export fn vulkan_pipeline_manager_is_simple_pipelines_enabled(manager: ?*VulkanPipelineManager) callconv(.c) bool {
    return if (manager) |m| m.simple_pipelines_enabled else false;
}
