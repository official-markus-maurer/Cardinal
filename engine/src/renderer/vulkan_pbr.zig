const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const buffer_mgr = @import("vulkan_buffer_manager.zig");
const descriptor_mgr = @import("vulkan_descriptor_manager.zig");
const types = @import("vulkan_types.zig");
const vk_texture_mgr = @import("vulkan_texture_manager.zig");
const vk_sync_mgr = @import("vulkan_sync_manager.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const buffer_utils = @import("util/vulkan_buffer_utils.zig");
const descriptor_utils = @import("util/vulkan_descriptor_utils.zig");
const material_utils = @import("util/vulkan_material_utils.zig");
const shader_utils = @import("util/vulkan_shader_utils.zig");
const texture_utils = @import("util/vulkan_texture_utils.zig");
const vk_utils = @import("vulkan_utils.zig");
const vk_descriptor_indexing = @import("vulkan_descriptor_indexing.zig");
const wrappers = @import("vulkan_wrappers.zig");
const scene = @import("../assets/scene.zig");
const animation = @import("../core/animation.zig");

const c = @import("vulkan_c.zig").c;

// Helper functions

fn create_pbr_descriptor_manager(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, vulkan_state: ?*types.VulkanState) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for descriptor manager", .{});
        return false;
    }
    pipeline.descriptorManager = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(ptr)));

    // Use DescriptorBuilder to configure bindings
    var builder = descriptor_mgr.DescriptorBuilder.init(std.heap.page_allocator);
    defer builder.deinit();

    const bindings_added = blk: {
        builder.add_binding(0, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT) catch break :blk false;
        builder.add_binding(1, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch break :blk false;
        builder.add_binding(2, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch break :blk false;
        builder.add_binding(3, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch break :blk false;
        builder.add_binding(4, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch break :blk false;
        builder.add_binding(5, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch break :blk false;
        builder.add_binding(6, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, c.VK_SHADER_STAGE_VERTEX_BIT) catch break :blk false;
        // Binding 7 removed
        builder.add_binding(8, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, c.VK_SHADER_STAGE_FRAGMENT_BIT) catch break :blk false;
        break :blk true;
    };

    if (!bindings_added) {
        log.cardinal_log_error("Failed to add bindings to descriptor builder", .{});
        memory.cardinal_free(mem_alloc, pipeline.descriptorManager);
        pipeline.descriptorManager = null;
        return false;
    }

    const prefer_descriptor_buffers = false;
    log.cardinal_log_info("Creating PBR descriptor manager with {d} max sets (prefer buffers: {s})", .{ 1000, if (prefer_descriptor_buffers) "true" else "false" });

    if (!builder.build(pipeline.descriptorManager.?, device, @ptrCast(allocator), @ptrCast(vulkan_state), 1000, prefer_descriptor_buffers)) {
        log.cardinal_log_error("Failed to create descriptor manager!", .{});
        memory.cardinal_free(mem_alloc, pipeline.descriptorManager);
        pipeline.descriptorManager = null;
        return false;
    }
    return true;
}

fn create_pbr_texture_manager(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, vulkan_state: ?*types.VulkanState) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanTextureManager));
    if (ptr == null) {
        log.cardinal_log_error("Failed to allocate texture manager for PBR pipeline", .{});
        return false;
    }
    pipeline.textureManager = @as(*types.VulkanTextureManager, @ptrCast(@alignCast(ptr)));

    var textureConfig = std.mem.zeroes(types.VulkanTextureManagerConfig);
    textureConfig.device = device;
    textureConfig.allocator = allocator;
    textureConfig.commandPool = commandPool;
    textureConfig.graphicsQueue = graphicsQueue;
    textureConfig.syncManager = null;

    if (vulkan_state != null and vulkan_state.?.sync_manager != null and
        vulkan_state.?.sync_manager.?.timeline_semaphore != null)
    {
        textureConfig.syncManager = vulkan_state.?.sync_manager;
    }

    textureConfig.vulkan_state = vulkan_state;
    textureConfig.initialCapacity = 16;

    if (!vk_texture_mgr.vk_texture_manager_init(pipeline.textureManager.?, &textureConfig)) {
        log.cardinal_log_error("Failed to initialize texture manager for PBR pipeline", .{});
        memory.cardinal_free(mem_alloc, pipeline.textureManager);
        pipeline.textureManager = null;
        return false;
    }
    return true;
}

fn create_pbr_pipeline_layout(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice) bool {
    const pushConstantRange = c.VkPushConstantRange{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(types.PBRPushConstants),
    };

    var descriptorLayouts: [2]c.VkDescriptorSetLayout = undefined;
    descriptorLayouts[0] = descriptor_mgr.vk_descriptor_manager_get_layout(@ptrCast(pipeline.descriptorManager));
    var layoutCount: u32 = 1;

    if (pipeline.textureManager != null) {
        const bindlessLayout = vk_descriptor_indexing.vk_bindless_texture_get_layout(&pipeline.textureManager.?.bindless_pool);
        if (bindlessLayout != null) {
            descriptorLayouts[1] = bindlessLayout;
            layoutCount = 2;
        }
    }

    const device_wrapper = wrappers.Device.init(device);
    const setLayouts = descriptorLayouts[0..layoutCount];
    const pushConstantRanges = [_]c.VkPushConstantRange{pushConstantRange};

    pipeline.pipelineLayout = device_wrapper.createPipelineLayout(setLayouts, &pushConstantRanges) catch |err| {
        log.cardinal_log_error("Failed to create PBR pipeline layout: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn load_pbr_shaders(device: c.VkDevice, vertShaderModule: *c.VkShaderModule, fragShaderModule: *c.VkShaderModule) bool {
    var vert_path: [512]u8 = undefined;
    var frag_path: [512]u8 = undefined;

    var shaders_dir: [*c]const u8 = @ptrCast(c.getenv("CARDINAL_SHADERS_DIR"));
    if (shaders_dir == null or shaders_dir[0] == 0) {
        shaders_dir = "assets/shaders";
    }

    _ = c.snprintf(&vert_path, 512, "%s/pbr.vert.spv", shaders_dir);
    _ = c.snprintf(&frag_path, 512, "%s/pbr.frag.spv", shaders_dir);

    const vert_path_ptr = @as([*:0]const u8, @ptrCast(&vert_path));
    const frag_path_ptr = @as([*:0]const u8, @ptrCast(&frag_path));

    // log.cardinal_log_debug("Using shader paths: vert={s}, frag={s}", .{std.mem.span(vert_path_ptr), std.mem.span(frag_path_ptr)});

    if (!shader_utils.vk_shader_create_module(device, vert_path_ptr, vertShaderModule)) {
        log.cardinal_log_error("Failed to create vertex shader module!", .{});
        return false;
    }

    if (!shader_utils.vk_shader_create_module(device, frag_path_ptr, fragShaderModule)) {
        log.cardinal_log_error("Failed to create fragment shader module!", .{});
        wrappers.Device.init(device).destroyShaderModule(vertShaderModule.*);
        return false;
    }
    return true;
}

fn configure_shader_stages(stages: []c.VkPipelineShaderStageCreateInfo, vertShader: c.VkShaderModule, fragShader: c.VkShaderModule) void {
    stages[0].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = c.VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vertShader;
    stages[0].pName = "main";
    stages[0].pNext = null;
    stages[0].flags = 0;
    stages[0].pSpecializationInfo = null;

    stages[1].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fragShader;
    stages[1].pName = "main";
    stages[1].pNext = null;
    stages[1].flags = 0;
    stages[1].pSpecializationInfo = null;
}

fn configure_vertex_input(info: *c.VkPipelineVertexInputStateCreateInfo, binding: *c.VkVertexInputBindingDescription, attributes: []c.VkVertexInputAttributeDescription) void {
    binding.* = .{ .binding = 0, .stride = @sizeOf(scene.CardinalVertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };

    attributes[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 };
    attributes[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @sizeOf(f32) * 3 };
    attributes[2] = .{ .binding = 0, .location = 2, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @sizeOf(f32) * 6 };
    attributes[3] = .{ .binding = 0, .location = 3, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(scene.CardinalVertex, "bone_weights") };
    attributes[4] = .{ .binding = 0, .location = 4, .format = c.VK_FORMAT_R32G32B32A32_UINT, .offset = @offsetOf(scene.CardinalVertex, "bone_indices") };
    attributes[5] = .{ .binding = 0, .location = 5, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(scene.CardinalVertex, "u1") };

    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    info.vertexBindingDescriptionCount = 1;
    info.pVertexBindingDescriptions = binding;
    info.vertexAttributeDescriptionCount = 6;
    info.pVertexAttributeDescriptions = attributes.ptr;
    info.pNext = null;
    info.flags = 0;
}

fn configure_input_assembly(info: *c.VkPipelineInputAssemblyStateCreateInfo) void {
    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    info.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    info.primitiveRestartEnable = c.VK_FALSE;
    info.pNext = null;
    info.flags = 0;
}

fn configure_viewport_state(info: *c.VkPipelineViewportStateCreateInfo) void {
    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    info.viewportCount = 1;
    info.scissorCount = 1;
    info.pNext = null;
    info.flags = 0;
}

fn configure_rasterization(info: *c.VkPipelineRasterizationStateCreateInfo) void {
    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    info.depthClampEnable = c.VK_FALSE;
    info.rasterizerDiscardEnable = c.VK_FALSE;
    info.polygonMode = c.VK_POLYGON_MODE_FILL;
    info.lineWidth = 1.0;
    info.cullMode = c.VK_CULL_MODE_NONE;
    info.frontFace = c.VK_FRONT_FACE_CLOCKWISE;
    info.depthBiasEnable = c.VK_FALSE;
    info.pNext = null;
    info.flags = 0;
}

fn configure_multisampling(info: *c.VkPipelineMultisampleStateCreateInfo) void {
    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    info.sampleShadingEnable = c.VK_FALSE;
    info.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
    info.minSampleShading = 1.0;
    info.pSampleMask = null;
    info.alphaToCoverageEnable = c.VK_FALSE;
    info.alphaToOneEnable = c.VK_FALSE;
    info.pNext = null;
    info.flags = 0;
}

fn configure_depth_stencil(info: *c.VkPipelineDepthStencilStateCreateInfo, depthWriteEnable: bool) void {
    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    info.depthTestEnable = c.VK_TRUE;
    info.depthWriteEnable = if (depthWriteEnable) c.VK_TRUE else c.VK_FALSE;
    info.depthCompareOp = c.VK_COMPARE_OP_LESS_OR_EQUAL;
    info.depthBoundsTestEnable = c.VK_FALSE;
    info.stencilTestEnable = c.VK_FALSE;
    info.pNext = null;
    info.flags = 0;
}

fn configure_color_blending(info: *c.VkPipelineColorBlendStateCreateInfo, attachment: *c.VkPipelineColorBlendAttachmentState, blendEnable: bool) void {
    attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    attachment.blendEnable = if (blendEnable) c.VK_TRUE else c.VK_FALSE;

    if (blendEnable) {
        attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
        attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
        attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
        attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
    }

    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    info.logicOpEnable = c.VK_FALSE;
    info.logicOp = c.VK_LOGIC_OP_COPY;
    info.attachmentCount = 1;
    info.pAttachments = attachment;
    info.blendConstants[0] = 0.0;
    info.blendConstants[1] = 0.0;
    info.blendConstants[2] = 0.0;
    info.blendConstants[3] = 0.0;
    info.pNext = null;
    info.flags = 0;
}

fn configure_dynamic_state(info: *c.VkPipelineDynamicStateCreateInfo, states: []c.VkDynamicState) void {
    states[0] = c.VK_DYNAMIC_STATE_VIEWPORT;
    states[1] = c.VK_DYNAMIC_STATE_SCISSOR;
    states[2] = c.VK_DYNAMIC_STATE_DEPTH_BIAS;

    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    info.dynamicStateCount = 3;
    info.pDynamicStates = states.ptr;
    info.pNext = null;
    info.flags = 0;
}

fn configure_rendering_info(info: *c.VkPipelineRenderingCreateInfo, colorFormat: *c.VkFormat, depthFormat: c.VkFormat) void {
    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    info.viewMask = 0;
    info.colorAttachmentCount = 1;
    info.pColorAttachmentFormats = colorFormat;
    info.depthAttachmentFormat = depthFormat;
    info.stencilAttachmentFormat = c.VK_FORMAT_UNDEFINED;
    info.pNext = null;
}

fn create_pbr_graphics_pipeline(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, vertShader: c.VkShaderModule, fragShader: c.VkShaderModule, swapchainFormat: c.VkFormat, depthFormat: c.VkFormat, enableBlending: bool, enableDepthWrite: bool, outPipeline: *c.VkPipeline) bool {
    var shaderStages: [2]c.VkPipelineShaderStageCreateInfo = undefined;
    configure_shader_stages(&shaderStages, vertShader, fragShader);

    var bindingDescription: c.VkVertexInputBindingDescription = undefined;
    var attributeDescriptions: [6]c.VkVertexInputAttributeDescription = undefined;
    var vertexInputInfo: c.VkPipelineVertexInputStateCreateInfo = undefined;
    configure_vertex_input(&vertexInputInfo, &bindingDescription, &attributeDescriptions);

    var inputAssembly: c.VkPipelineInputAssemblyStateCreateInfo = undefined;
    configure_input_assembly(&inputAssembly);

    var viewportState: c.VkPipelineViewportStateCreateInfo = undefined;
    configure_viewport_state(&viewportState);

    var rasterizer: c.VkPipelineRasterizationStateCreateInfo = undefined;
    configure_rasterization(&rasterizer);
    rasterizer.depthBiasEnable = c.VK_TRUE;

    var multisampling: c.VkPipelineMultisampleStateCreateInfo = undefined;
    configure_multisampling(&multisampling);

    var depthStencil: c.VkPipelineDepthStencilStateCreateInfo = undefined;
    configure_depth_stencil(&depthStencil, enableDepthWrite);

    var colorBlendAttachment: c.VkPipelineColorBlendAttachmentState = undefined;
    var colorBlending: c.VkPipelineColorBlendStateCreateInfo = undefined;
    configure_color_blending(&colorBlending, &colorBlendAttachment, enableBlending);

    var dynamicStates: [3]c.VkDynamicState = undefined;
    var dynamicState: c.VkPipelineDynamicStateCreateInfo = undefined;
    configure_dynamic_state(&dynamicState, &dynamicStates);

    var pipelineInfo = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    pipelineInfo.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipelineInfo.stageCount = 2;
    pipelineInfo.pStages = &shaderStages;
    pipelineInfo.pVertexInputState = &vertexInputInfo;
    pipelineInfo.pInputAssemblyState = &inputAssembly;
    pipelineInfo.pViewportState = &viewportState;
    pipelineInfo.pRasterizationState = &rasterizer;
    pipelineInfo.pMultisampleState = &multisampling;
    pipelineInfo.pDepthStencilState = &depthStencil;
    pipelineInfo.pColorBlendState = &colorBlending;
    pipelineInfo.pDynamicState = &dynamicState;
    pipelineInfo.layout = pipeline.pipelineLayout;
    pipelineInfo.renderPass = null;
    pipelineInfo.subpass = 0;

    var pipelineRenderingInfo: c.VkPipelineRenderingCreateInfo = undefined;
    var colorFmt = swapchainFormat;
    configure_rendering_info(&pipelineRenderingInfo, &colorFmt, depthFormat);
    pipelineInfo.pNext = &pipelineRenderingInfo;

    const result = c.vkCreateGraphicsPipelines(device, null, 1, &pipelineInfo, null, outPipeline);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create PBR graphics pipeline: {d}", .{result});
        return false;
    }
    return true;
}

fn create_pbr_uniform_buffers(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator) bool {
    // UBO
    var uboInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
    uboInfo.size = @sizeOf(types.PBRUniformBufferObject);
    uboInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    uboInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uboInfo.persistentlyMapped = true;

    var uboBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (!buffer_mgr.vk_buffer_create(&uboBuffer, device, allocator, &uboInfo)) return false;
    pipeline.uniformBuffer = uboBuffer.handle;
    pipeline.uniformBufferMemory = uboBuffer.memory;
    pipeline.uniformBufferAllocation = uboBuffer.allocation;
    pipeline.uniformBufferMapped = uboBuffer.mapped;

    // Material
    var matInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
    matInfo.size = @sizeOf(types.PBRMaterialProperties);
    matInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    matInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    matInfo.persistentlyMapped = true;

    var matBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (!buffer_mgr.vk_buffer_create(&matBuffer, device, allocator, &matInfo)) return false;
    pipeline.materialBuffer = matBuffer.handle;
    pipeline.materialBufferMemory = matBuffer.memory;
    pipeline.materialBufferAllocation = matBuffer.allocation;
    pipeline.materialBufferMapped = matBuffer.mapped;

    // Lighting
    var lightInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
    lightInfo.size = @sizeOf(types.PBRLightingBuffer);
    lightInfo.usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    lightInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    lightInfo.persistentlyMapped = true;

    var lightBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (!buffer_mgr.vk_buffer_create(&lightBuffer, device, allocator, &lightInfo)) return false;
    pipeline.lightingBuffer = lightBuffer.handle;
    pipeline.lightingBufferMemory = lightBuffer.memory;
    pipeline.lightingBufferAllocation = lightBuffer.allocation;
    pipeline.lightingBufferMapped = lightBuffer.mapped;

    // Bone matrices
    pipeline.maxBones = 256;
    var boneInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
    boneInfo.size = pipeline.maxBones * 16 * @sizeOf(f32);
    boneInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    boneInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    boneInfo.persistentlyMapped = true;

    var boneBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (!buffer_mgr.vk_buffer_create(&boneBuffer, device, allocator, &boneInfo)) return false;
    pipeline.boneMatricesBuffer = boneBuffer.handle;
    pipeline.boneMatricesBufferMemory = boneBuffer.memory;
    pipeline.boneMatricesBufferAllocation = boneBuffer.allocation;
    pipeline.boneMatricesBufferMapped = boneBuffer.mapped;

    // Init bone matrices to identity
    const boneMatrices = @as([*]f32, @ptrCast(@alignCast(pipeline.boneMatricesBufferMapped)));
    var i: u32 = 0;
    while (i < pipeline.maxBones) : (i += 1) {
        @memset(boneMatrices[i * 16 .. (i + 1) * 16], 0);
        boneMatrices[i * 16 + 0] = 1.0;
        boneMatrices[i * 16 + 5] = 1.0;
        boneMatrices[i * 16 + 10] = 1.0;
        boneMatrices[i * 16 + 15] = 1.0;
    }

    return true;
}

fn initialize_pbr_defaults(pipeline: *types.VulkanPBRPipeline) void {
    var defaultMaterial = std.mem.zeroes(types.PBRMaterialProperties);
    defaultMaterial.albedoFactor[0] = 0.8;
    defaultMaterial.albedoFactor[1] = 0.8;
    defaultMaterial.albedoFactor[2] = 0.8;
    defaultMaterial.metallicFactor = 0.0;
    defaultMaterial.roughnessFactor = 0.5;
    defaultMaterial.emissiveFactor[0] = 0.0;
    defaultMaterial.emissiveFactor[1] = 0.0;
    defaultMaterial.emissiveFactor[2] = 0.0;
    defaultMaterial.normalScale = 1.0;
    defaultMaterial.aoStrength = 1.0;
    defaultMaterial.albedoTextureIndex = 0;
    defaultMaterial.normalTextureIndex = 0;
    defaultMaterial.metallicRoughnessTextureIndex = 0;
    defaultMaterial.aoTextureIndex = 0;
    defaultMaterial.emissiveTextureIndex = 0;
    defaultMaterial.supportsDescriptorIndexing = 1;

    @memcpy(@as([*]u8, @ptrCast(pipeline.materialBufferMapped))[0..@sizeOf(types.PBRMaterialProperties)], @as([*]const u8, @ptrCast(&defaultMaterial))[0..@sizeOf(types.PBRMaterialProperties)]);

    var defaultLighting = std.mem.zeroes(types.PBRLightingBuffer);
    defaultLighting.count = 1;
    defaultLighting.lights[0].lightDirection[0] = -0.5;
    defaultLighting.lights[0].lightDirection[1] = -1.0;
    defaultLighting.lights[0].lightDirection[2] = -0.3;
    defaultLighting.lights[0].lightDirection[3] = 0.0; // Directional
    defaultLighting.lights[0].lightColor[0] = 1.0;
    defaultLighting.lights[0].lightColor[1] = 1.0;
    defaultLighting.lights[0].lightColor[2] = 1.0;
    defaultLighting.lights[0].lightColor[3] = 2.5; // Intensity
    defaultLighting.lights[0].ambientColor[0] = 0.2;
    defaultLighting.lights[0].ambientColor[1] = 0.2;
    defaultLighting.lights[0].ambientColor[2] = 0.2;
    defaultLighting.lights[0].ambientColor[3] = 100.0; // Range

    @memcpy(@as([*]u8, @ptrCast(pipeline.lightingBufferMapped))[0..@sizeOf(types.PBRLightingBuffer)], @as([*]const u8, @ptrCast(&defaultLighting))[0..@sizeOf(types.PBRLightingBuffer)]);
}

fn create_pbr_mesh_buffers(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, scene_data: *const scene.CardinalScene, vulkan_state: ?*types.VulkanState) bool {
    var totalVertices: u32 = 0;
    var totalIndices: u32 = 0;

    var i: u32 = 0;
    while (i < scene_data.mesh_count) : (i += 1) {
        totalVertices += scene_data.meshes.?[i].vertex_count;
        totalIndices += scene_data.meshes.?[i].index_count;
    }

    if (totalVertices == 0) {
        log.cardinal_log_warn("Scene has no vertices", .{});
        return true;
    }

    // Prepare vertex data for upload
    const vertexBufferSize = totalVertices * @sizeOf(scene.CardinalVertex);
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const vertexData = memory.cardinal_alloc(mem_alloc, vertexBufferSize);
    if (vertexData == null) {
        log.cardinal_log_error("Failed to allocate memory for vertex data", .{});
        return false;
    }
    defer memory.cardinal_free(mem_alloc, vertexData);
    const vertices = @as([*]scene.CardinalVertex, @ptrCast(@alignCast(vertexData)));

    // Copy all vertex data into contiguous buffer
    var vertexOffset: u32 = 0;
    i = 0;
    while (i < scene_data.mesh_count) : (i += 1) {
        const mesh = &scene_data.meshes.?[i];
        if (mesh.vertices != null) {
            @memcpy(vertices[vertexOffset .. vertexOffset + mesh.vertex_count], mesh.vertices.?[0..mesh.vertex_count]);
        }
        vertexOffset += mesh.vertex_count;
    }

    // Create vertex buffer using staging buffer
    if (!buffer_utils.vk_buffer_create_with_staging(allocator, device, commandPool, graphicsQueue, vertexData, vertexBufferSize, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &pipeline.vertexBuffer, &pipeline.vertexBufferMemory, &pipeline.vertexBufferAllocation, vulkan_state)) {
        log.cardinal_log_error("Failed to create PBR vertex buffer with staging", .{});
        return false;
    }

    log.cardinal_log_debug("Vertex buffer created with staging: {d} vertices", .{totalVertices});

    // Create index buffer if we have indices
    if (totalIndices > 0) {
        const indexBufferSize = @sizeOf(u32) * totalIndices;

        const indexData = memory.cardinal_alloc(mem_alloc, indexBufferSize);
        if (indexData == null) {
            log.cardinal_log_error("Failed to allocate memory for index data", .{});
            return false;
        }
        defer memory.cardinal_free(mem_alloc, indexData);
        const indices = @as([*]u32, @ptrCast(@alignCast(indexData)));

        // Copy all index data into contiguous buffer with vertex base offset adjustment
        var indexOffset: u32 = 0;
        var vertexBaseOffset: u32 = 0;
        i = 0;
        while (i < scene_data.mesh_count) : (i += 1) {
            const mesh = &scene_data.meshes.?[i];
            if (mesh.index_count > 0 and mesh.indices != null) {
                var j: u32 = 0;
                while (j < mesh.index_count) : (j += 1) {
                    indices[indexOffset + j] = mesh.indices.?[j] + vertexBaseOffset;
                }
                indexOffset += mesh.index_count;
            }
            vertexBaseOffset += mesh.vertex_count;
        }

        // Create index buffer using staging buffer
        if (!buffer_utils.vk_buffer_create_with_staging(allocator, device, commandPool, graphicsQueue, indexData, indexBufferSize, c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, &pipeline.indexBuffer, &pipeline.indexBufferMemory, &pipeline.indexBufferAllocation, vulkan_state)) {
            log.cardinal_log_error("Failed to create PBR index buffer with staging", .{});
            return false;
        }

        pipeline.totalIndexCount = totalIndices;
        log.cardinal_log_debug("Index buffer created with staging: {d} indices", .{totalIndices});
    }

    return true;
}

fn update_pbr_descriptor_sets(pipeline: *types.VulkanPBRPipeline) bool {
    const dm = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(pipeline.descriptorManager)));
    const setIndex = if (dm.descriptorSetCount > 0)
        dm.descriptorSetCount - 1
    else
        0;

    // Update uniform buffer (binding 0)
    if (!descriptor_mgr.vk_descriptor_manager_update_buffer(dm, setIndex, 0, pipeline.uniformBuffer, 0, @sizeOf(types.PBRUniformBufferObject))) {
        log.cardinal_log_error("Failed to update uniform buffer descriptor", .{});
        return false;
    }

    // Update bone matrices buffer (binding 6)
    if (!descriptor_mgr.vk_descriptor_manager_update_buffer(dm, setIndex, 6, pipeline.boneMatricesBuffer, 0, @sizeOf(f32) * 16 * pipeline.maxBones)) {
        log.cardinal_log_error("Failed to update bone matrices buffer descriptor", .{});
        return false;
    }

    // Update placeholder textures for fixed bindings 1-5
    var b: u32 = 1;
    while (b <= 5) : (b += 1) {
        const placeholderView = if (pipeline.textureManager.?.textureCount > 0)
            pipeline.textureManager.?.textures.?[0].view
        else
            null;
        const placeholderSampler = if (pipeline.textureManager.?.textureCount > 0)
            pipeline.textureManager.?.textures.?[0].sampler
        else
            pipeline.textureManager.?.defaultSampler;

        if (!descriptor_mgr.vk_descriptor_manager_update_image(dm, setIndex, b, placeholderView, placeholderSampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
            log.cardinal_log_error("Failed to update image descriptor for binding {d}", .{b});
            return false;
        }
    }

    // Note: Material data is passed via Push Constants, so no binding 7 update needed.
    // Binding 9 (Texture Array) is now handled via bindless descriptor set (Set 1), managed by BindlessTexturePool.

    // Update lighting buffer (binding 8)
    if (!descriptor_mgr.vk_descriptor_manager_update_buffer(dm, setIndex, 8, pipeline.lightingBuffer, 0, @sizeOf(types.PBRLightingBuffer))) {
        log.cardinal_log_error("Failed to update lighting buffer descriptor", .{});
        return false;
    }

    return true;
}

// Exported functions

pub export fn vk_pbr_load_scene(pipeline: ?*types.VulkanPBRPipeline, device: c.VkDevice, physicalDevice: c.VkPhysicalDevice, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, scene_data: ?*const scene.CardinalScene, allocator: ?*types.VulkanAllocator, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    _ = physicalDevice;

    if (pipeline == null or !pipeline.?.initialized or scene_data == null or scene_data.?.mesh_count == 0) {
        log.cardinal_log_warn("PBR pipeline not initialized or no scene data", .{});
        return true;
    }
    const pipe = pipeline.?;
    const scn = scene_data.?;
    const alloc = allocator.?;

    log.cardinal_log_info("Loading PBR scene: {d} meshes", .{scn.mesh_count});

    // Clean up previous buffers if they exist (after ensuring GPU idle)
    // We use vkDeviceWaitIdle instead of timeline semaphore wait to avoid issues with
    // timeline resets/overflows during scene loading.
    if (vulkan_state != null and vulkan_state.?.context.device != null) {
        wrappers.Device.init(vulkan_state.?.context.device).waitIdle() catch {};
    }

    if (pipe.vertexBuffer != null or pipe.vertexBufferMemory != null) {
        vk_allocator.vk_allocator_free_buffer(alloc, pipe.vertexBuffer, pipe.vertexBufferAllocation);
        pipe.vertexBuffer = null;
        pipe.vertexBufferMemory = null;
        pipe.vertexBufferAllocation = null;
    }
    if (pipe.indexBuffer != null or pipe.indexBufferMemory != null) {
        vk_allocator.vk_allocator_free_buffer(alloc, pipe.indexBuffer, pipe.indexBufferAllocation);
        pipe.indexBuffer = null;
        pipe.indexBufferMemory = null;
        pipe.indexBufferAllocation = null;
    }

    // Create vertex and index buffers
    if (!create_pbr_mesh_buffers(pipe, device, alloc, commandPool, graphicsQueue, scn, vulkan_state)) {
        return false;
    }

    // Texture manager handles its own synchronization during cleanup
    pipe.textureManager.?.syncManager = vulkan_state.?.sync_manager;

    // Load scene textures using texture manager
    if (!vk_texture_mgr.vk_texture_manager_load_scene_textures(pipe.textureManager.?, scn)) {
        log.cardinal_log_error("Failed to load scene textures using texture manager", .{});
        return false;
    }

    if (pipe.textureManager != null) {
        log.cardinal_log_info("Loaded {d} textures using texture manager", .{pipe.textureManager.?.textureCount});
    }

    // Reset descriptor pool to reclaim sets from previous scene loads
    if (pipe.descriptorManager != null) {
        const dm = @as(*types.VulkanDescriptorManager, @ptrCast(pipe.descriptorManager));
        if (dm.descriptorPool != null) {
            _ = c.vkResetDescriptorPool(dm.device, dm.descriptorPool, 0);
            dm.descriptorSetCount = 0;
        }
    }

    // Allocate descriptor set using descriptor manager
    const dm = @as(*types.VulkanDescriptorManager, @ptrCast(pipe.descriptorManager));

    if (!descriptor_mgr.vk_descriptor_manager_allocate(dm)) {
        log.cardinal_log_error("Failed to allocate descriptor set", .{});
        return false;
    }

    // Wait for graphics queue to complete before updating descriptor sets
    const result = c.vkQueueWaitIdle(graphicsQueue);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_warn("Graphics queue wait idle failed before descriptor update: {d}", .{result});
        return false;
    }

    // Update descriptor sets
    if (!update_pbr_descriptor_sets(@ptrCast(pipe))) {
        return false;
    }

    log.cardinal_log_info("PBR scene loaded successfully", .{});
    return true;
}

pub export fn vk_pbr_pipeline_create(pipeline: ?*types.VulkanPBRPipeline, device: c.VkDevice, physicalDevice: c.VkPhysicalDevice, swapchainFormat: c.VkFormat, depthFormat: c.VkFormat, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, allocator: ?*types.VulkanAllocator, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    _ = physicalDevice;
    if (pipeline == null or allocator == null) return false;
    const pipe = pipeline.?;
    const alloc = allocator.?;

    log.cardinal_log_debug("Starting PBR pipeline creation", .{});

    @memset(@as([*]u8, @ptrCast(pipe))[0..@sizeOf(types.VulkanPBRPipeline)], 0);

    pipe.supportsDescriptorIndexing = true;
    pipe.totalIndexCount = 0;

    log.cardinal_log_info("[PBR] Descriptor indexing support: enabled", .{});

    if (!create_pbr_descriptor_manager(pipe, device, alloc, vulkan_state)) {
        return false;
    }
    log.cardinal_log_debug("Descriptor manager created successfully", .{});

    if (!create_pbr_texture_manager(pipe, device, alloc, commandPool, graphicsQueue, vulkan_state)) {
        descriptor_mgr.vk_descriptor_manager_destroy(@ptrCast(pipe.descriptorManager));
        c.free(pipe.descriptorManager);
        return false;
    }
    log.cardinal_log_debug("Texture manager initialized successfully", .{});

    if (!create_pbr_pipeline_layout(pipe, device)) {
        vk_texture_mgr.vk_texture_manager_destroy(pipe.textureManager.?);
        c.free(@as(?*anyopaque, @ptrCast(pipe.textureManager)));
        descriptor_mgr.vk_descriptor_manager_destroy(@ptrCast(pipe.descriptorManager));
        c.free(pipe.descriptorManager);
        return false;
    }

    var vertShader: c.VkShaderModule = null;
    var fragShader: c.VkShaderModule = null;
    if (!load_pbr_shaders(device, &vertShader, &fragShader)) {
        return false;
    }

    const dev = wrappers.Device.init(device);

    if (!create_pbr_graphics_pipeline(pipe, device, vertShader, fragShader, swapchainFormat, depthFormat, false, true, &pipe.pipeline)) {
        dev.destroyShaderModule(vertShader);
        dev.destroyShaderModule(fragShader);
        return false;
    }

    if (!create_pbr_graphics_pipeline(pipe, device, vertShader, fragShader, swapchainFormat, depthFormat, true, false, &pipe.pipelineBlend)) {
        dev.destroyShaderModule(vertShader);
        dev.destroyShaderModule(fragShader);
        return false;
    }

    dev.destroyShaderModule(vertShader);
    dev.destroyShaderModule(fragShader);

    log.cardinal_log_debug("PBR graphics pipelines created", .{});

    if (!create_pbr_uniform_buffers(pipe, device, alloc)) {
        return false;
    }

    initialize_pbr_defaults(pipe);

    pipe.initialized = true;
    log.cardinal_log_info("PBR pipeline created successfully", .{});
    return true;
}

pub export fn vk_pbr_pipeline_destroy(pipeline: ?*types.VulkanPBRPipeline, device: c.VkDevice, allocator: ?*types.VulkanAllocator) callconv(.c) void {
    if (pipeline == null) {
        log.cardinal_log_error("vk_pbr_pipeline_destroy called with null pipeline", .{});
        return;
    }
    if (!pipeline.?.initialized) {
        log.cardinal_log_warn("vk_pbr_pipeline_destroy called on uninitialized pipeline", .{});
        return;
    }
    const pipe = pipeline.?;
    const alloc = allocator.?;

    log.cardinal_log_debug("vk_pbr_pipeline_destroy: start", .{});

    if (pipe.textureManager != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        vk_texture_mgr.vk_texture_manager_destroy(pipe.textureManager.?);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(pipe.textureManager)));
        pipe.textureManager = null;
    }

    if (pipe.vertexBuffer != null or pipe.vertexBufferMemory != null) {
        vk_allocator.vk_allocator_free_buffer(alloc, pipe.vertexBuffer, pipe.vertexBufferAllocation);
    }

    if (pipe.indexBuffer != null or pipe.indexBufferMemory != null) {
        vk_allocator.vk_allocator_free_buffer(alloc, pipe.indexBuffer, pipe.indexBufferAllocation);
    }

    if (pipe.uniformBuffer != null or pipe.uniformBufferMemory != null) {
        if (pipe.uniformBufferMapped != null) {
            vk_allocator.vk_allocator_unmap_memory(alloc, pipe.uniformBufferAllocation);
            pipe.uniformBufferMapped = null;
        }
        vk_allocator.vk_allocator_free_buffer(alloc, pipe.uniformBuffer, pipe.uniformBufferAllocation);
    }

    if (pipe.materialBuffer != null or pipe.materialBufferMemory != null) {
        if (pipe.materialBufferMapped != null) {
            vk_allocator.vk_allocator_unmap_memory(alloc, pipe.materialBufferAllocation);
            pipe.materialBufferMapped = null;
        }
        vk_allocator.vk_allocator_free_buffer(alloc, pipe.materialBuffer, pipe.materialBufferAllocation);
    }

    if (pipe.lightingBuffer != null or pipe.lightingBufferMemory != null) {
        if (pipe.lightingBufferMapped != null) {
            vk_allocator.vk_allocator_unmap_memory(alloc, pipe.lightingBufferAllocation);
            pipe.lightingBufferMapped = null;
        }
        vk_allocator.vk_allocator_free_buffer(alloc, pipe.lightingBuffer, pipe.lightingBufferAllocation);
    }

    if (pipe.textureManager != null) {
        vk_texture_mgr.vk_texture_manager_destroy(pipe.textureManager.?);
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, pipe.textureManager);
        pipe.textureManager = null;
    }

    if (pipe.descriptorManager != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        descriptor_mgr.vk_descriptor_manager_destroy(@ptrCast(pipe.descriptorManager));
        memory.cardinal_free(mem_alloc, pipe.descriptorManager);
        pipe.descriptorManager = null;
    }

    if (pipe.pipeline != null) {
        c.vkDestroyPipeline(device, pipe.pipeline, null);
    }
    if (pipe.pipelineBlend != null) {
        c.vkDestroyPipeline(device, pipe.pipelineBlend, null);
    }

    if (pipe.pipelineLayout != null) {
        wrappers.Device.init(device).destroyPipelineLayout(pipe.pipelineLayout);
    }

    if (pipe.boneMatricesBuffer != null or pipe.boneMatricesBufferMemory != null) {
        if (pipe.boneMatricesBufferMapped != null) {
            vk_allocator.vk_allocator_unmap_memory(alloc, pipe.boneMatricesBufferAllocation);
            pipe.boneMatricesBufferMapped = null;
        }
        vk_allocator.vk_allocator_free_buffer(alloc, pipe.boneMatricesBuffer, pipe.boneMatricesBufferAllocation);
    }

    @memset(@as([*]u8, @ptrCast(pipe))[0..@sizeOf(types.VulkanPBRPipeline)], 0);
    log.cardinal_log_info("PBR pipeline destroyed", .{});
}

pub export fn vk_pbr_update_uniforms(pipeline: ?*types.VulkanPBRPipeline, ubo: ?*const types.PBRUniformBufferObject, lighting: ?*const types.PBRLightingBuffer) callconv(.c) void {
    if (pipeline == null or !pipeline.?.initialized) return;
    const pipe = pipeline.?;

    if (ubo != null) {
        @memcpy(@as([*]u8, @ptrCast(pipe.uniformBufferMapped))[0..@sizeOf(types.PBRUniformBufferObject)], @as([*]const u8, @ptrCast(ubo))[0..@sizeOf(types.PBRUniformBufferObject)]);
    }

    if (lighting != null) {
        @memcpy(@as([*]u8, @ptrCast(pipe.lightingBufferMapped))[0..@sizeOf(types.PBRLightingBuffer)], @as([*]const u8, @ptrCast(lighting))[0..@sizeOf(types.PBRLightingBuffer)]);
    }
}

pub export fn vk_pbr_render(pipeline: ?*types.VulkanPBRPipeline, commandBuffer: c.VkCommandBuffer, scene_data: ?*const scene.CardinalScene) callconv(.c) void {
    if (pipeline == null or !pipeline.?.initialized or scene_data == null) {
        // log.cardinal_log_warn("vk_pbr_render skipped: pipeline or scene null", .{});
        return;
    }
    const pipe = pipeline.?;
    const scn = scene_data.?;
    const cmd = wrappers.CommandBuffer.init(commandBuffer);

    if (pipe.vertexBuffer == null or pipe.indexBuffer == null) {
        log.cardinal_log_warn("vk_pbr_render skipped: vertex/index buffer null", .{});
        return;
    }

    const vertexBuffers = [_]c.VkBuffer{pipe.vertexBuffer};
    const offsets = [_]c.VkDeviceSize{0};
    cmd.bindVertexBuffers(0, &vertexBuffers, &offsets);
    cmd.bindIndexBuffer(pipe.indexBuffer, 0, c.VK_INDEX_TYPE_UINT32);

    var descriptorSet: c.VkDescriptorSet = null;
    if (pipe.descriptorManager != null) {
        const dm = @as(*types.VulkanDescriptorManager, @ptrCast(pipe.descriptorManager));
        if (dm.descriptorSets != null and dm.descriptorSetCount > 0) {
            const setIndex = dm.descriptorSetCount - 1;
            descriptorSet = dm.descriptorSets.?[setIndex];
        } else {
            log.cardinal_log_warn("vk_pbr_render skipped: no descriptor sets", .{});
            return;
        }
    } else {
        log.cardinal_log_warn("vk_pbr_render skipped: no descriptor manager", .{});
        return;
    }

    // Pass 1: Opaque
    cmd.bindPipeline(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipeline);
    const descriptorSets = [_]c.VkDescriptorSet{descriptorSet};
    cmd.bindDescriptorSets(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 0, &descriptorSets, &[_]u32{});

    if (pipe.textureManager != null and pipe.textureManager.?.bindless_pool.descriptor_set != null) {
        const bindlessSet = pipe.textureManager.?.bindless_pool.descriptor_set;
        const bindlessSets = [_]c.VkDescriptorSet{bindlessSet};
        cmd.bindDescriptorSets(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 1, &bindlessSets, &[_]u32{});
    }

    c.vkCmdSetDepthBias(commandBuffer, 0.0, 0.0, 0.0);

    var indexOffset: u32 = 0;
    var i: u32 = 0;
    var drawn_count: u32 = 0;
    while (i < scn.mesh_count) : (i += 1) {
        const mesh = &scn.meshes.?[i];
        var is_blend = false;
        var is_mask = false;

        if (mesh.material_index < scn.material_count) {
            const mat = &scn.materials.?[mesh.material_index];
            if (mat.alpha_mode == scene.CardinalAlphaMode.BLEND) {
                is_blend = true;
            } else if (mat.alpha_mode == scene.CardinalAlphaMode.MASK) {
                is_mask = true;
            }
        }

        if (is_blend) {
            indexOffset += mesh.index_count;
            continue;
        }

        // Apply depth bias for MASK materials (e.g. decals) to prevent Z-fighting
        if (is_mask) {
            c.vkCmdSetDepthBias(commandBuffer, -16.0, 0.0, -8.0);
        } else {
            c.vkCmdSetDepthBias(commandBuffer, 0.0, 0.0, 0.0);
        }

        if (mesh.vertices == null or mesh.vertex_count == 0 or mesh.indices == null or mesh.index_count == 0 or mesh.index_count > 1000000000) {
            continue;
        }
        if (!mesh.visible) {
            indexOffset += mesh.index_count;
            continue;
        }

        var pushConstants = std.mem.zeroes(types.PBRPushConstants);
        const tm_opaque: ?*const anyopaque = if (pipe.textureManager) |tm| @ptrCast(tm) else null;
        material_utils.vk_material_setup_push_constants(@ptrCast(&pushConstants), @ptrCast(mesh), @ptrCast(scn), @ptrCast(@alignCast(tm_opaque)));

        if (scn.animation_system != null and scn.skin_count > 0) {
            const anim_system = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(scn.animation_system.?)));
            const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(scn.skins.?)));

            var skin_idx: u32 = 0;
            while (skin_idx < scn.skin_count) : (skin_idx += 1) {
                const skin = &skins[skin_idx];
                var mesh_idx: u32 = 0;
                while (mesh_idx < skin.mesh_count) : (mesh_idx += 1) {
                    if (skin.mesh_indices.?[mesh_idx] == i) {
                        pushConstants.flags |= 4;
                        if (anim_system.bone_matrices != null) {
                            @memcpy(@as([*]u8, @ptrCast(pipe.boneMatricesBufferMapped))[0 .. anim_system.bone_matrix_count * 16 * @sizeOf(f32)], @as([*]const u8, @ptrCast(anim_system.bone_matrices))[0 .. anim_system.bone_matrix_count * 16 * @sizeOf(f32)]);
                        }
                        break;
                    }
                }
                if ((pushConstants.flags & 4) != 0) break;
            }
        }

        cmd.pushConstants(pipe.pipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(types.PBRPushConstants), &pushConstants);

        if (indexOffset + mesh.index_count > pipe.totalIndexCount) break;

        cmd.drawIndexed(mesh.index_count, 1, indexOffset, 0, 0);
        drawn_count += 1;
        indexOffset += mesh.index_count;
    }

    // if (drawn_count > 0) log.cardinal_log_debug("PBR Render: Drawn {d} opaque meshes", .{drawn_count});

    // Pass 2: Blend
    cmd.bindPipeline(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineBlend);
    cmd.bindDescriptorSets(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 0, &descriptorSets, &[_]u32{});

    if (pipe.textureManager != null and pipe.textureManager.?.bindless_pool.descriptor_set != null) {
        const bindlessSet = pipe.textureManager.?.bindless_pool.descriptor_set;
        const bindlessSets = [_]c.VkDescriptorSet{bindlessSet};
        cmd.bindDescriptorSets(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 1, &bindlessSets, &[_]u32{});
    }

    // Apply depth bias for transparent materials too (to prevent z-fighting with coplanar opaque surfaces)
    c.vkCmdSetDepthBias(commandBuffer, -16.0, 0.0, -8.0);

    indexOffset = 0;
    i = 0;
    while (i < scn.mesh_count) : (i += 1) {
        const mesh = &scn.meshes.?[i];
        var is_blend = false;

        if (mesh.material_index < scn.material_count) {
            const mat = &scn.materials.?[mesh.material_index];
            if (mat.alpha_mode == scene.CardinalAlphaMode.BLEND) {
                is_blend = true;
            }
        }

        if (!is_blend) {
            indexOffset += mesh.index_count;
            continue;
        }

        if (mesh.vertices == null or mesh.vertex_count == 0 or mesh.indices == null or mesh.index_count == 0 or mesh.index_count > 1000000000) {
            continue;
        }
        if (!mesh.visible) {
            indexOffset += mesh.index_count;
            continue;
        }

        var pushConstants = std.mem.zeroes(types.PBRPushConstants);
        const tm_opaque: ?*const anyopaque = if (pipe.textureManager) |tm| @ptrCast(tm) else null;
        material_utils.vk_material_setup_push_constants(@ptrCast(&pushConstants), @ptrCast(mesh), @ptrCast(scn), @ptrCast(@alignCast(tm_opaque)));

        if (scn.animation_system != null and scn.skin_count > 0) {
            const anim_system = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(scn.animation_system.?)));
            const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(scn.skins.?)));

            var skin_idx: u32 = 0;
            while (skin_idx < scn.skin_count) : (skin_idx += 1) {
                const skin = &skins[skin_idx];
                var mesh_idx: u32 = 0;
                while (mesh_idx < skin.mesh_count) : (mesh_idx += 1) {
                    if (skin.mesh_indices.?[mesh_idx] == i) {
                        pushConstants.flags |= 4;
                        if (anim_system.bone_matrices != null) {
                            @memcpy(@as([*]u8, @ptrCast(pipe.boneMatricesBufferMapped))[0 .. anim_system.bone_matrix_count * 16 * @sizeOf(f32)], @as([*]const u8, @ptrCast(anim_system.bone_matrices))[0 .. anim_system.bone_matrix_count * 16 * @sizeOf(f32)]);
                        }
                        break;
                    }
                }
                if ((pushConstants.flags & 4) != 0) break;
            }
        }

        cmd.pushConstants(pipe.pipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(types.PBRPushConstants), &pushConstants);

        if (indexOffset + mesh.index_count > pipe.totalIndexCount) break;

        cmd.drawIndexed(mesh.index_count, 1, indexOffset, 0, 0);
        indexOffset += mesh.index_count;
    }
}
