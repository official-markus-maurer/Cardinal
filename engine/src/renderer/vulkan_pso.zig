const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const log = @import("../core/log.zig");
const pso_log = log.ScopedLogger("PSO");
const shader_utils = @import("util/vulkan_shader_utils.zig");
const wrappers = @import("vulkan_wrappers.zig");

// Shader Cache
var g_shader_cache: std.StringHashMap(c.VkShaderModule) = undefined;
var g_shader_cache_mutex: std.Thread.Mutex = .{};
var g_shader_cache_initialized: bool = false;

fn get_or_load_shader_module(device: c.VkDevice, path: []const u8) !c.VkShaderModule {
    g_shader_cache_mutex.lock();
    defer g_shader_cache_mutex.unlock();

    const allocator = @import("../core/memory.zig").cardinal_get_allocator_for_category(.SHADERS).as_allocator();

    if (!g_shader_cache_initialized) {
        g_shader_cache = std.StringHashMap(c.VkShaderModule).init(allocator);
        g_shader_cache_initialized = true;
    }

    if (g_shader_cache.get(path)) |module| {
        return module;
    }

    // Not in cache, load it
    // We need a null-terminated string for the C API
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var module: c.VkShaderModule = undefined;
    if (!shader_utils.vk_shader_create_module(device, path_z, &module)) {
        pso_log.err("Failed to create shader module from path: '{s}'", .{path_z});
        return error.ShaderLoadFailed;
    }

    // Store in cache (dup key for persistence)
    const key = try allocator.dupe(u8, path);
    errdefer allocator.free(key);

    try g_shader_cache.put(key, module);

    pso_log.info("Loaded and cached shader: {s}", .{path});
    return module;
}

pub fn vk_pso_cleanup_shader_cache(device: c.VkDevice) void {
    g_shader_cache_mutex.lock();
    defer g_shader_cache_mutex.unlock();

    if (!g_shader_cache_initialized) return;

    pso_log.info("Cleaning up shader cache ({d} modules)", .{g_shader_cache.count()});
    const allocator = @import("../core/memory.zig").cardinal_get_allocator_for_category(.SHADERS).as_allocator();

    var it = g_shader_cache.iterator();
    while (it.next()) |entry| {
        wrappers.Device.init(device).destroyShaderModule(entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    g_shader_cache.deinit();
    g_shader_cache_initialized = false;
}

// Enums
pub const Topology = enum {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
    triangle_fan,

    pub fn to_vk(self: Topology) c.VkPrimitiveTopology {
        return switch (self) {
            .point_list => c.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
            .line_list => c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
            .line_strip => c.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
            .triangle_list => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .triangle_strip => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
            .triangle_fan => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,
        };
    }
};

pub const PolygonMode = enum {
    fill,
    line,
    point,

    pub fn to_vk(self: PolygonMode) c.VkPolygonMode {
        return switch (self) {
            .fill => c.VK_POLYGON_MODE_FILL,
            .line => c.VK_POLYGON_MODE_LINE,
            .point => c.VK_POLYGON_MODE_POINT,
        };
    }
};

pub const CullMode = enum {
    none,
    front,
    back,
    front_and_back,

    pub fn to_vk(self: CullMode) c.VkCullModeFlags {
        return switch (self) {
            .none => c.VK_CULL_MODE_NONE,
            .front => c.VK_CULL_MODE_FRONT_BIT,
            .back => c.VK_CULL_MODE_BACK_BIT,
            .front_and_back => c.VK_CULL_MODE_FRONT_AND_BACK,
        };
    }
};

pub const FrontFace = enum {
    counter_clockwise,
    clockwise,

    pub fn to_vk(self: FrontFace) c.VkFrontFace {
        return switch (self) {
            .counter_clockwise => c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .clockwise => c.VK_FRONT_FACE_CLOCKWISE,
        };
    }
};

pub const CompareOp = enum {
    never,
    less,
    equal,
    less_or_equal,
    greater,
    not_equal,
    greater_or_equal,
    always,

    pub fn to_vk(self: CompareOp) c.VkCompareOp {
        return switch (self) {
            .never => c.VK_COMPARE_OP_NEVER,
            .less => c.VK_COMPARE_OP_LESS,
            .equal => c.VK_COMPARE_OP_EQUAL,
            .less_or_equal => c.VK_COMPARE_OP_LESS_OR_EQUAL,
            .greater => c.VK_COMPARE_OP_GREATER,
            .not_equal => c.VK_COMPARE_OP_NOT_EQUAL,
            .greater_or_equal => c.VK_COMPARE_OP_GREATER_OR_EQUAL,
            .always => c.VK_COMPARE_OP_ALWAYS,
        };
    }
};

pub const BlendFactor = enum {
    zero,
    one,
    src_color,
    one_minus_src_color,
    dst_color,
    one_minus_dst_color,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,

    pub fn to_vk(self: BlendFactor) c.VkBlendFactor {
        return switch (self) {
            .zero => c.VK_BLEND_FACTOR_ZERO,
            .one => c.VK_BLEND_FACTOR_ONE,
            .src_color => c.VK_BLEND_FACTOR_SRC_COLOR,
            .one_minus_src_color => c.VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
            .dst_color => c.VK_BLEND_FACTOR_DST_COLOR,
            .one_minus_dst_color => c.VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR,
            .src_alpha => c.VK_BLEND_FACTOR_SRC_ALPHA,
            .one_minus_src_alpha => c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .dst_alpha => c.VK_BLEND_FACTOR_DST_ALPHA,
            .one_minus_dst_alpha => c.VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
        };
    }
};

pub const BlendOp = enum {
    add,
    subtract,
    reverse_subtract,
    min,
    max,

    pub fn to_vk(self: BlendOp) c.VkBlendOp {
        return switch (self) {
            .add => c.VK_BLEND_OP_ADD,
            .subtract => c.VK_BLEND_OP_SUBTRACT,
            .reverse_subtract => c.VK_BLEND_OP_REVERSE_SUBTRACT,
            .min => c.VK_BLEND_OP_MIN,
            .max => c.VK_BLEND_OP_MAX,
        };
    }
};

pub const LogicOp = enum {
    clear,
    and_op,
    and_reverse,
    copy,
    and_inverted,
    no_op,
    xor,
    op_or,
    nor,
    equivalent,
    invert,
    or_reverse,
    copy_inverted,
    or_inverted,
    nand,
    set,

    pub fn to_vk(self: LogicOp) c.VkLogicOp {
        return switch (self) {
            .clear => c.VK_LOGIC_OP_CLEAR,
            .and_op => c.VK_LOGIC_OP_AND,
            .and_reverse => c.VK_LOGIC_OP_AND_REVERSE,
            .copy => c.VK_LOGIC_OP_COPY,
            .and_inverted => c.VK_LOGIC_OP_AND_INVERTED,
            .no_op => c.VK_LOGIC_OP_NO_OP,
            .xor => c.VK_LOGIC_OP_XOR,
            .op_or => c.VK_LOGIC_OP_OR,
            .nor => c.VK_LOGIC_OP_NOR,
            .equivalent => c.VK_LOGIC_OP_EQUIVALENT,
            .invert => c.VK_LOGIC_OP_INVERT,
            .or_reverse => c.VK_LOGIC_OP_OR_REVERSE,
            .copy_inverted => c.VK_LOGIC_OP_COPY_INVERTED,
            .or_inverted => c.VK_LOGIC_OP_OR_INVERTED,
            .nand => c.VK_LOGIC_OP_NAND,
            .set => c.VK_LOGIC_OP_SET,
        };
    }
};

// PSO Descriptor Structures
pub const ShaderStageDescriptor = struct {
    path: []const u8,
    stage: c.VkShaderStageFlagBits = c.VK_SHADER_STAGE_ALL,
    entry_point: []const u8 = "main",
    // Store handle as u64 to avoid std.json issues with opaque pointers
    module_handle: ?u64 = null,
};

pub const VertexInputBindingDescriptor = struct {
    binding: u32,
    stride: u32,
    input_rate: c.VkVertexInputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
};

pub const VertexInputAttributeDescriptor = struct {
    location: u32,
    binding: u32,
    format: c.VkFormat,
    offset: u32,
};

pub const VertexInputDescriptor = struct {
    use_standard_layout: bool = true,
    // If using standard layout, how many attributes to use (starting from 0)
    // 0 = Px, 1 = Nx, 2 = UV, 3 = Weights, 4 = Indices, 5 = U1
    standard_layout_attribute_count: u32 = 6,

    // Custom layout (used if use_standard_layout is false)
    bindings: []const VertexInputBindingDescriptor = &.{},
    attributes: []const VertexInputAttributeDescriptor = &.{},
};

pub const InputAssemblyDescriptor = struct {
    topology: Topology = .triangle_list,
    primitive_restart_enable: bool = false,
};

pub const RasterizationDescriptor = struct {
    depth_clamp_enable: bool = false,
    rasterizer_discard_enable: bool = false,
    polygon_mode: PolygonMode = .fill,
    cull_mode: CullMode = .back,
    front_face: FrontFace = .counter_clockwise,
    depth_bias_enable: bool = false,
    depth_bias_constant_factor: f32 = 0.0,
    depth_bias_clamp: f32 = 0.0,
    depth_bias_slope_factor: f32 = 0.0,
    line_width: f32 = 1.0,
};

pub const MultisampleDescriptor = struct {
    rasterization_samples: c.VkSampleCountFlagBits = c.VK_SAMPLE_COUNT_1_BIT,
    sample_shading_enable: bool = false,
    min_sample_shading: f32 = 1.0,
    alpha_to_coverage_enable: bool = false,
    alpha_to_one_enable: bool = false,
};

pub const DepthStencilDescriptor = struct {
    depth_test_enable: bool = true,
    depth_write_enable: bool = true,
    depth_compare_op: CompareOp = .less_or_equal,
    depth_bounds_test_enable: bool = false,
    stencil_test_enable: bool = false,
    min_depth_bounds: f32 = 0.0,
    max_depth_bounds: f32 = 1.0,
};

pub const ColorBlendAttachmentDescriptor = struct {
    blend_enable: bool = false,
    src_color_blend_factor: BlendFactor = .src_alpha,
    dst_color_blend_factor: BlendFactor = .one_minus_src_alpha,
    color_blend_op: BlendOp = .add,
    src_alpha_blend_factor: BlendFactor = .one,
    dst_alpha_blend_factor: BlendFactor = .zero,
    alpha_blend_op: BlendOp = .add,
    color_write_mask: c.VkColorComponentFlags = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
};

pub const ColorBlendDescriptor = struct {
    logic_op_enable: bool = false,
    logic_op: LogicOp = .copy,
    attachments: []const ColorBlendAttachmentDescriptor,
    blend_constants: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
};

pub const RenderingDescriptor = struct {
    color_formats: []const c.VkFormat,
    depth_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    stencil_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
};

pub const PipelineDescriptor = struct {
    name: []const u8,
    vertex_shader: ?ShaderStageDescriptor = null,
    fragment_shader: ?ShaderStageDescriptor = null,
    mesh_shader: ?ShaderStageDescriptor = null,
    task_shader: ?ShaderStageDescriptor = null,
    vertex_input: VertexInputDescriptor = .{},
    input_assembly: InputAssemblyDescriptor = .{},
    rasterization: RasterizationDescriptor = .{},
    multisampling: MultisampleDescriptor = .{},
    depth_stencil: DepthStencilDescriptor = .{},
    color_blend: ColorBlendDescriptor,
    dynamic_states: []const c.VkDynamicState = &.{
        c.VK_DYNAMIC_STATE_VIEWPORT,
        c.VK_DYNAMIC_STATE_SCISSOR,
    },
    rendering: RenderingDescriptor,
    flags: c.VkPipelineCreateFlags = 0,
};

// Builder
pub const PipelineBuilder = struct {
    allocator: std.mem.Allocator,
    device: c.VkDevice,
    pipeline_cache: c.VkPipelineCache,

    pub fn init(allocator: std.mem.Allocator, device: c.VkDevice, pipeline_cache: c.VkPipelineCache) PipelineBuilder {
        return .{
            .allocator = allocator,
            .device = device,
            .pipeline_cache = pipeline_cache,
        };
    }

    pub fn load_from_json(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(PipelineDescriptor) {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        // defer allocator.free(content); // Keep content alive in case strings point to it

        return std.json.parseFromSlice(PipelineDescriptor, allocator, content, .{ .ignore_unknown_fields = true });
    }

    pub fn build(self: *PipelineBuilder, descriptor: PipelineDescriptor, pipeline_layout: c.VkPipelineLayout, out_pipeline: *c.VkPipeline) !void {
        // 1. Shaders
        pso_log.info("Building pipeline '{s}'", .{descriptor.name});

        var shader_stages = std.ArrayListUnmanaged(c.VkPipelineShaderStageCreateInfo){};
        defer shader_stages.deinit(self.allocator);

        // Helper to load shader
        const load_shader = struct {
            fn load(b: *PipelineBuilder, stage_desc: ShaderStageDescriptor, stage_bit: c.VkShaderStageFlagBits, stages: *std.ArrayListUnmanaged(c.VkPipelineShaderStageCreateInfo)) !void {
                var module: c.VkShaderModule = undefined;
                if (stage_desc.module_handle) |h| {
                    module = @ptrFromInt(h);
                } else {
                    // Use cached shader module
                    module = get_or_load_shader_module(b.device, stage_desc.path) catch |err| {
                        pso_log.err("Failed to load shader module from path: '{s}' (err={any})", .{ stage_desc.path, err });
                        return error.ShaderLoadFailed;
                    };
                }

                try stages.append(b.allocator, .{
                    .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                    .stage = stage_bit,
                    .module = module,
                    .pName = "main",
                    .pNext = null,
                    .flags = 0,
                    .pSpecializationInfo = null,
                });
            }
        }.load;

        if (descriptor.vertex_shader) |vs| {
            try load_shader(self, vs, c.VK_SHADER_STAGE_VERTEX_BIT, &shader_stages);
        }

        if (descriptor.mesh_shader) |ms| {
            try load_shader(self, ms, c.VK_SHADER_STAGE_MESH_BIT_EXT, &shader_stages);
        }

        if (descriptor.task_shader) |ts| {
            try load_shader(self, ts, c.VK_SHADER_STAGE_TASK_BIT_EXT, &shader_stages);
        }

        if (descriptor.fragment_shader) |fs| {
            try load_shader(self, fs, c.VK_SHADER_STAGE_FRAGMENT_BIT, &shader_stages);
        }

        // 2. Vertex Input
        var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

        // Keep these alive during the function scope
        var binding_desc: c.VkVertexInputBindingDescription = undefined;
        var attribute_descs: [6]c.VkVertexInputAttributeDescription = undefined;

        // For custom layout
        var custom_bindings: []c.VkVertexInputBindingDescription = &.{};
        var custom_attributes: []c.VkVertexInputAttributeDescription = &.{};
        defer if (!descriptor.vertex_input.use_standard_layout) {
            self.allocator.free(custom_bindings);
            self.allocator.free(custom_attributes);
        };

        if (descriptor.vertex_input.use_standard_layout) {
            const scene_import = @import("../assets/scene.zig");
            binding_desc = c.VkVertexInputBindingDescription{
                .binding = 0,
                .stride = @sizeOf(scene_import.CardinalVertex),
                .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
            };

            attribute_descs = [_]c.VkVertexInputAttributeDescription{
                .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 },
                .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @sizeOf(f32) * 3 },
                .{ .binding = 0, .location = 2, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @sizeOf(f32) * 6 },
                .{ .binding = 0, .location = 3, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(scene_import.CardinalVertex, "bone_weights") },
                .{ .binding = 0, .location = 4, .format = c.VK_FORMAT_R32G32B32A32_UINT, .offset = @offsetOf(scene_import.CardinalVertex, "bone_indices") },
                .{ .binding = 0, .location = 5, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(scene_import.CardinalVertex, "u1") },
            };

            vertex_input_info.vertexBindingDescriptionCount = 1;
            vertex_input_info.pVertexBindingDescriptions = &binding_desc;
            vertex_input_info.vertexAttributeDescriptionCount = descriptor.vertex_input.standard_layout_attribute_count;
            vertex_input_info.pVertexAttributeDescriptions = &attribute_descs;
        } else {
            // Custom layout
            custom_bindings = try self.allocator.alloc(c.VkVertexInputBindingDescription, descriptor.vertex_input.bindings.len);
            for (descriptor.vertex_input.bindings, 0..) |b, i| {
                custom_bindings[i] = .{
                    .binding = b.binding,
                    .stride = b.stride,
                    .inputRate = b.input_rate,
                };
            }

            custom_attributes = try self.allocator.alloc(c.VkVertexInputAttributeDescription, descriptor.vertex_input.attributes.len);
            for (descriptor.vertex_input.attributes, 0..) |a, i| {
                custom_attributes[i] = .{
                    .location = a.location,
                    .binding = a.binding,
                    .format = a.format,
                    .offset = a.offset,
                };
            }

            vertex_input_info.vertexBindingDescriptionCount = @intCast(custom_bindings.len);
            vertex_input_info.pVertexBindingDescriptions = custom_bindings.ptr;
            vertex_input_info.vertexAttributeDescriptionCount = @intCast(custom_attributes.len);
            vertex_input_info.pVertexAttributeDescriptions = custom_attributes.ptr;
        }

        // 3. Input Assembly
        var input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = descriptor.input_assembly.topology.to_vk(),
            .primitiveRestartEnable = if (descriptor.input_assembly.primitive_restart_enable) c.VK_TRUE else c.VK_FALSE,
            .pNext = null,
            .flags = 0,
        };

        // 4. Viewport State (Dynamic)
        var viewport_state = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
            .pNext = null,
            .flags = 0,
        };

        // 5. Rasterization
        var rasterizer = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = if (descriptor.rasterization.depth_clamp_enable) c.VK_TRUE else c.VK_FALSE,
            .rasterizerDiscardEnable = if (descriptor.rasterization.rasterizer_discard_enable) c.VK_TRUE else c.VK_FALSE,
            .polygonMode = descriptor.rasterization.polygon_mode.to_vk(),
            .lineWidth = descriptor.rasterization.line_width,
            .cullMode = descriptor.rasterization.cull_mode.to_vk(),
            .frontFace = descriptor.rasterization.front_face.to_vk(),
            .depthBiasEnable = if (descriptor.rasterization.depth_bias_enable) c.VK_TRUE else c.VK_FALSE,
            .depthBiasConstantFactor = descriptor.rasterization.depth_bias_constant_factor,
            .depthBiasClamp = descriptor.rasterization.depth_bias_clamp,
            .depthBiasSlopeFactor = descriptor.rasterization.depth_bias_slope_factor,
            .pNext = null,
            .flags = 0,
        };

        // 6. Multisampling
        var multisampling = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .sampleShadingEnable = if (descriptor.multisampling.sample_shading_enable) c.VK_TRUE else c.VK_FALSE,
            .rasterizationSamples = descriptor.multisampling.rasterization_samples,
            .minSampleShading = descriptor.multisampling.min_sample_shading,
            .pSampleMask = null,
            .alphaToCoverageEnable = if (descriptor.multisampling.alpha_to_coverage_enable) c.VK_TRUE else c.VK_FALSE,
            .alphaToOneEnable = if (descriptor.multisampling.alpha_to_one_enable) c.VK_TRUE else c.VK_FALSE,
            .pNext = null,
            .flags = 0,
        };

        // 7. Depth Stencil
        var depth_stencil = c.VkPipelineDepthStencilStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .depthTestEnable = if (descriptor.depth_stencil.depth_test_enable) c.VK_TRUE else c.VK_FALSE,
            .depthWriteEnable = if (descriptor.depth_stencil.depth_write_enable) c.VK_TRUE else c.VK_FALSE,
            .depthCompareOp = descriptor.depth_stencil.depth_compare_op.to_vk(),
            .depthBoundsTestEnable = if (descriptor.depth_stencil.depth_bounds_test_enable) c.VK_TRUE else c.VK_FALSE,
            .stencilTestEnable = if (descriptor.depth_stencil.stencil_test_enable) c.VK_TRUE else c.VK_FALSE,
            .minDepthBounds = descriptor.depth_stencil.min_depth_bounds,
            .maxDepthBounds = descriptor.depth_stencil.max_depth_bounds,
            .pNext = null,
            .flags = 0,
        };

        // 8. Color Blending
        if (descriptor.color_blend.attachments.len != descriptor.rendering.color_formats.len) {
            pso_log.err("Color blend attachment count ({d}) does not match rendering color format count ({d}) for pipeline '{s}'", .{
                descriptor.color_blend.attachments.len,
                descriptor.rendering.color_formats.len,
                descriptor.name,
            });
            return error.PipelineCreationError;
        }

        var color_blend_attachments = try self.allocator.alloc(c.VkPipelineColorBlendAttachmentState, descriptor.color_blend.attachments.len);
        defer self.allocator.free(color_blend_attachments);

        for (descriptor.color_blend.attachments, 0..) |att, i| {
            color_blend_attachments[i] = .{
                .blendEnable = if (att.blend_enable) c.VK_TRUE else c.VK_FALSE,
                .srcColorBlendFactor = att.src_color_blend_factor.to_vk(),
                .dstColorBlendFactor = att.dst_color_blend_factor.to_vk(),
                .colorBlendOp = att.color_blend_op.to_vk(),
                .srcAlphaBlendFactor = att.src_alpha_blend_factor.to_vk(),
                .dstAlphaBlendFactor = att.dst_alpha_blend_factor.to_vk(),
                .alphaBlendOp = att.alpha_blend_op.to_vk(),
                .colorWriteMask = att.color_write_mask,
            };
        }

        var color_blending = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = if (descriptor.color_blend.logic_op_enable) c.VK_TRUE else c.VK_FALSE,
            .logicOp = descriptor.color_blend.logic_op.to_vk(),
            .attachmentCount = @intCast(color_blend_attachments.len),
            .pAttachments = color_blend_attachments.ptr,
            .blendConstants = descriptor.color_blend.blend_constants,
            .pNext = null,
            .flags = 0,
        };

        // 9. Dynamic State
        var dynamic_state = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = @intCast(descriptor.dynamic_states.len),
            .pDynamicStates = descriptor.dynamic_states.ptr,
            .pNext = null,
            .flags = 0,
        };

        // 10. Dynamic Rendering Info
        var rendering_info = c.VkPipelineRenderingCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .viewMask = 0,
            .colorAttachmentCount = @intCast(descriptor.rendering.color_formats.len),
            .pColorAttachmentFormats = descriptor.rendering.color_formats.ptr,
            .depthAttachmentFormat = descriptor.rendering.depth_format,
            .stencilAttachmentFormat = descriptor.rendering.stencil_format,
            .pNext = null,
        };

        // Combine into Graphics Pipeline
        var pipeline_info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = @intCast(shader_stages.items.len),
            .pStages = shader_stages.items.ptr,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .pNext = &rendering_info,
            .flags = descriptor.flags,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        const result = c.vkCreateGraphicsPipelines(self.device, self.pipeline_cache, 1, &pipeline_info, null, out_pipeline);
        if (result != c.VK_SUCCESS) {
            pso_log.err("Failed to create graphics pipeline '{s}': {d}", .{ descriptor.name, result });
            return error.PipelineCreationError;
        }
    }
};
