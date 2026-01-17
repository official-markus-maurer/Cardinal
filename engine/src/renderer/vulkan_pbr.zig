const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const math = @import("../core/math.zig");
const memory = @import("../core/memory.zig");
const buffer_mgr = @import("vulkan_buffer_manager.zig");
const descriptor_mgr = @import("vulkan_descriptor_manager.zig");
const types = @import("vulkan_types.zig");
const vk_texture_mgr = @import("vulkan_texture_manager.zig");
const vk_sync_mgr = @import("vulkan_sync_manager.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const material_utils = @import("util/vulkan_material_utils.zig");
const shader_utils = @import("util/vulkan_shader_utils.zig");
const texture_utils = @import("util/vulkan_texture_utils.zig");
const vk_utils = @import("vulkan_utils.zig");
const vk_descriptor_indexing = @import("vulkan_descriptor_indexing.zig");
const wrappers = @import("vulkan_wrappers.zig");
const vk_pso = @import("vulkan_pso.zig");
const scene = @import("../assets/scene.zig");
const animation = @import("../core/animation.zig");

const c = @import("vulkan_c.zig").c;

const pbr_log = log.ScopedLogger("PBR");

// Helper functions

fn create_pbr_descriptor_manager(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, vulkan_state: ?*types.VulkanState, bindings_map: *std.AutoHashMap(u32, c.VkDescriptorSetLayoutBinding)) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (ptr == null) {
        pbr_log.err("Failed to allocate memory for descriptor manager", .{});
        return false;
    }
    pipeline.descriptorManager = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(ptr)));

    // Use DescriptorBuilder to configure bindings
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    var builder = descriptor_mgr.DescriptorBuilder.init(renderer_allocator);
    defer builder.deinit();

    var bindings_added = true;
    var it = bindings_map.iterator();
    while (it.next()) |entry| {
        const b = entry.value_ptr.*;
        builder.add_binding(b.binding, b.descriptorType, b.descriptorCount, b.stageFlags) catch {
            bindings_added = false;
            break;
        };
    }

    if (!bindings_added) {
        pbr_log.err("Failed to add bindings to descriptor builder", .{});
        memory.cardinal_free(mem_alloc, pipeline.descriptorManager);
        pipeline.descriptorManager = null;
        return false;
    }

    const prefer_descriptor_buffers = true;
    pbr_log.info("Creating PBR descriptor manager with {d} max sets (prefer buffers: {s})", .{ types.MAX_FRAMES_IN_FLIGHT, if (prefer_descriptor_buffers) "true" else "false" });

    if (!builder.build(pipeline.descriptorManager.?, device, @ptrCast(allocator), @ptrCast(vulkan_state), types.MAX_FRAMES_IN_FLIGHT, prefer_descriptor_buffers)) {
        pbr_log.err("Failed to create descriptor manager!", .{});
        memory.cardinal_free(mem_alloc, pipeline.descriptorManager);
        pipeline.descriptorManager = null;
        return false;
    }

    // Allocate sets immediately
    var sets: [types.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = undefined;
    if (!descriptor_mgr.vk_descriptor_manager_allocate_sets(pipeline.descriptorManager, types.MAX_FRAMES_IN_FLIGHT, &sets)) {
        pbr_log.err("Failed to allocate descriptor sets", .{});
        descriptor_mgr.vk_descriptor_manager_destroy(pipeline.descriptorManager);
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
        pbr_log.err("Failed to allocate texture manager for PBR pipeline", .{});
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
        pbr_log.err("Failed to initialize texture manager for PBR pipeline", .{});
        memory.cardinal_free(mem_alloc, pipeline.textureManager);
        pipeline.textureManager = null;
        return false;
    }
    return true;
}

fn create_pbr_pipeline_layout(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, pushConstantRange: *const c.VkPushConstantRange) bool {
    var descriptorLayouts: [2]c.VkDescriptorSetLayout = undefined;
    descriptorLayouts[0] = descriptor_mgr.vk_descriptor_manager_get_layout(@ptrCast(pipeline.descriptorManager));
    var layoutCount: u32 = 1;

    if (pipeline.textureManager != null) {
        pbr_log.info("Checking bindless pool...", .{});
        // Always try to use bindless layout if pool is valid, even if no textures yet
        const bindlessLayout = vk_descriptor_indexing.vk_bindless_texture_get_layout(&pipeline.textureManager.?.bindless_pool);
        if (bindlessLayout != null) {
            pbr_log.info("Bindless layout found and added to pipeline layout at index 1. Handle: 0x{x}", .{@intFromPtr(bindlessLayout)});
            descriptorLayouts[1] = bindlessLayout;
            layoutCount = 2;
        } else {
            pbr_log.err("Bindless pool exists but layout is NULL!", .{});
        }
    } else {
        pbr_log.err("Texture manager is NULL, cannot add bindless layout!", .{});
    }

    const device_wrapper = wrappers.Device.init(device);
    const setLayouts = descriptorLayouts[0..layoutCount];
    const pushConstantRanges = [_]c.VkPushConstantRange{pushConstantRange.*};

    pipeline.pipelineLayout = device_wrapper.createPipelineLayout(setLayouts, &pushConstantRanges) catch |err| {
        pbr_log.err("Failed to create PBR pipeline layout: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn create_pbr_graphics_pipeline(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, vertShader: c.VkShaderModule, fragShader: c.VkShaderModule, swapchainFormat: c.VkFormat, depthFormat: c.VkFormat, json_path: []const u8, outPipeline: *c.VkPipeline, pipelineCache: c.VkPipelineCache) bool {
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    var builder = vk_pso.PipelineBuilder.init(renderer_allocator, device, pipelineCache);

    var parsed = vk_pso.PipelineBuilder.load_from_json(renderer_allocator, json_path) catch |err| {
        pbr_log.err("Failed to load pipeline JSON '{s}': {s}", .{ json_path, @errorName(err) });
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;

    // Override shader modules with pre-compiled ones
    if (descriptor.vertex_shader) |*vs| {
        vs.module_handle = @intFromPtr(vertShader);
    } else {
        descriptor.vertex_shader = .{
            .path = "internal_pbr_vert",
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module_handle = @intFromPtr(vertShader),
        };
    }
    if (descriptor.fragment_shader) |*fs| {
        fs.module_handle = @intFromPtr(fragShader);
    } else {
        descriptor.fragment_shader = .{
            .path = "internal_pbr_frag",
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module_handle = @intFromPtr(fragShader),
        };
    }

    // Override rendering formats
    var color_formats = [_]c.VkFormat{swapchainFormat};
    descriptor.rendering.color_formats = &color_formats;
    descriptor.rendering.depth_format = depthFormat;

    if (pipeline.descriptorManager) |mgr| {
        if (mgr.useDescriptorBuffers) {
            descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }

    if (pipeline.textureManager) |tm| {
        if (tm.bindless_pool.use_descriptor_buffer) {
            descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }

    builder.build(descriptor, pipeline.pipelineLayout, outPipeline) catch {
        return false;
    };

    return true;
}

fn create_pbr_uniform_buffers(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator) bool {
    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        // UBO
        var uboInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
        uboInfo.size = @sizeOf(types.PBRUniformBufferObject);
        uboInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        uboInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        uboInfo.persistentlyMapped = true;

        var uboBuffer: buffer_mgr.VulkanBuffer = undefined;
        if (!buffer_mgr.vk_buffer_create(&uboBuffer, device, allocator, &uboInfo)) return false;
        pipeline.uniformBuffers[i] = uboBuffer.handle;
        pipeline.uniformBuffersMemory[i] = uboBuffer.memory;
        pipeline.uniformBuffersAllocation[i] = uboBuffer.allocation;
        pipeline.uniformBuffersMapped[i] = uboBuffer.mapped;

        // Lighting
        var lightInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
        lightInfo.size = @sizeOf(types.PBRLightingBuffer);
        lightInfo.usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        lightInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        lightInfo.persistentlyMapped = true;

        var lightBuffer: buffer_mgr.VulkanBuffer = undefined;
        if (!buffer_mgr.vk_buffer_create(&lightBuffer, device, allocator, &lightInfo)) {
            // Cleanup UBO for this frame
            buffer_mgr.vk_buffer_destroy(&uboBuffer, device, allocator, null);
            return false;
        }
        pipeline.lightingBuffers[i] = lightBuffer.handle;
        pipeline.lightingBuffersMemory[i] = lightBuffer.memory;
        pipeline.lightingBuffersAllocation[i] = lightBuffer.allocation;
        pipeline.lightingBuffersMapped[i] = lightBuffer.mapped;

        // Bone matrices
        pipeline.maxBones = 256;
        var boneInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
        boneInfo.size = pipeline.maxBones * 16 * @sizeOf(f32);
        boneInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        boneInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        boneInfo.persistentlyMapped = true;

        var boneBuffer: buffer_mgr.VulkanBuffer = undefined;
        if (!buffer_mgr.vk_buffer_create(&boneBuffer, device, allocator, &boneInfo)) {
            buffer_mgr.vk_buffer_destroy(&lightBuffer, device, allocator, null);
            buffer_mgr.vk_buffer_destroy(&uboBuffer, device, allocator, null);
            return false;
        }
        pipeline.boneMatricesBuffers[i] = boneBuffer.handle;
        pipeline.boneMatricesBuffersMemory[i] = boneBuffer.memory;
        pipeline.boneMatricesBuffersAllocation[i] = boneBuffer.allocation;
        pipeline.boneMatricesBuffersMapped[i] = boneBuffer.mapped;

        // Init bone matrices to identity
        const boneMatrices = @as([*]f32, @ptrCast(@alignCast(pipeline.boneMatricesBuffersMapped[i])));
        var b: u32 = 0;
        while (b < pipeline.maxBones) : (b += 1) {
            @memset(boneMatrices[b * 16 .. (b + 1) * 16], 0);
            boneMatrices[b * 16 + 0] = 1.0;
            boneMatrices[b * 16 + 5] = 1.0;
            boneMatrices[b * 16 + 10] = 1.0;
            boneMatrices[b * 16 + 15] = 1.0;
        }
    }

    return true;
}

fn initialize_pbr_defaults(pipeline: *types.VulkanPBRPipeline, config: *const types.RendererConfig) void {
    var defaultLighting = std.mem.zeroes(types.PBRLightingBuffer);
    defaultLighting.count = 1;
    defaultLighting.lights[0].lightDirection = config.pbr_default_light_direction;
    defaultLighting.lights[0].lightColor = config.pbr_default_light_color;
    defaultLighting.lights[0].params[0] = config.pbr_ambient_color[3]; // Range from config
    // Cones are 0.0 by default (Directional)

    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        if (pipeline.lightingBuffersMapped[i]) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..@sizeOf(types.PBRLightingBuffer)], @as([*]const u8, @ptrCast(&defaultLighting))[0..@sizeOf(types.PBRLightingBuffer)]);
        }
    }
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
        pbr_log.warn("Scene has no vertices", .{});
        return true;
    }

    // Prepare vertex data for upload
    const vertexBufferSize = totalVertices * @sizeOf(scene.CardinalVertex);
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const vertexData = memory.cardinal_alloc(mem_alloc, vertexBufferSize);
    if (vertexData == null) {
        pbr_log.err("Failed to allocate memory for vertex data", .{});
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
    var vertexBufferObj = std.mem.zeroes(buffer_mgr.VulkanBuffer);
    if (!buffer_mgr.vk_buffer_create_device_local(&vertexBufferObj, device, @ptrCast(allocator), commandPool, graphicsQueue, vertexData, vertexBufferSize, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, vulkan_state)) {
        pbr_log.err("Failed to create vertex buffer with staging", .{});
        return false;
    }
    pipeline.vertexBuffer = vertexBufferObj.handle;
    pipeline.vertexBufferMemory = vertexBufferObj.memory;
    pipeline.vertexBufferAllocation = vertexBufferObj.allocation;

    pbr_log.debug("Vertex buffer created with staging: {d} vertices", .{totalVertices});

    // Create index buffer if we have indices
    if (totalIndices > 0) {
        const indexBufferSize = @sizeOf(u32) * totalIndices;

        const indexData = memory.cardinal_alloc(mem_alloc, indexBufferSize);
        if (indexData == null) {
            pbr_log.err("Failed to allocate memory for index data", .{});
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
        var indexBufferObj = std.mem.zeroes(buffer_mgr.VulkanBuffer);
        if (!buffer_mgr.vk_buffer_create_device_local(&indexBufferObj, device, @ptrCast(allocator), commandPool, graphicsQueue, indexData, indexBufferSize, c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, vulkan_state)) {
            pbr_log.err("Failed to create index buffer with staging", .{});
            return false;
        }
        pipeline.indexBuffer = indexBufferObj.handle;
        pipeline.indexBufferMemory = indexBufferObj.memory;
        pipeline.indexBufferAllocation = indexBufferObj.allocation;

        pipeline.totalIndexCount = totalIndices;
        pbr_log.debug("Index buffer created with staging: {d} indices", .{totalIndices});
    }

    return true;
}

fn update_pbr_descriptor_sets(pipeline: *types.VulkanPBRPipeline, vulkan_state: ?*types.VulkanState) bool {
    const dm = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(pipeline.descriptorManager)));

    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        var set: c.VkDescriptorSet = null;
        if (dm.useDescriptorBuffers) {
            // Pseudo-handle for descriptor buffers must be 1-based to avoid NULL handle
            set = @ptrFromInt(i + 1);
        } else if (dm.descriptorSets) |sets| {
            set = sets[i];
        } else {
            return false;
        }

        // Update uniform buffer (binding 0)
        if (!descriptor_mgr.vk_descriptor_manager_update_buffer(dm, set, 0, pipeline.uniformBuffers[i], 0, @sizeOf(types.PBRUniformBufferObject))) {
            pbr_log.err("Failed to update uniform buffer descriptor", .{});
            return false;
        }

        // Update bone matrices buffer (binding 6)
        if (!descriptor_mgr.vk_descriptor_manager_update_buffer(dm, set, 6, pipeline.boneMatricesBuffers[i], 0, @sizeOf(f32) * 16 * pipeline.maxBones)) {
            pbr_log.err("Failed to update bone matrices buffer descriptor", .{});
            return false;
        }

        // Update placeholder textures for fixed bindings 1-5 (Albedo, Normal, MetallicRoughness, AO, Emissive)
        const BINDING_ALBEDO = 1;
        const BINDING_EMISSIVE = 5;
        var b: u32 = BINDING_ALBEDO;
        while (b <= BINDING_EMISSIVE) : (b += 1) {
            const placeholderView = if (pipeline.textureManager.?.textureCount > 0)
                pipeline.textureManager.?.textures.?[0].view
            else
                null;
            const placeholderSampler = if (pipeline.textureManager.?.textureCount > 0)
                pipeline.textureManager.?.textures.?[0].sampler
            else
                pipeline.textureManager.?.defaultSampler;

            if (!descriptor_mgr.vk_descriptor_manager_update_image(dm, set, b, placeholderView, placeholderSampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
                pbr_log.err("Failed to update image descriptor for binding {d}", .{b});
                return false;
            }
        }

        // Update lighting buffer (binding 8)
        if (!descriptor_mgr.vk_descriptor_manager_update_buffer(dm, set, 8, pipeline.lightingBuffers[i], 0, @sizeOf(types.PBRLightingBuffer))) {
            pbr_log.err("Failed to update lighting buffer descriptor", .{});
            return false;
        }

        // Update Shadow Map (Binding 7)
        if (pipeline.shadowMapView != null) {
            if (!descriptor_mgr.vk_descriptor_manager_update_image(dm, set, 7, pipeline.shadowMapView, pipeline.shadowMapSampler, c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL)) {
                pbr_log.err("Failed to update shadow map descriptor", .{});
                return false;
            }
        }

        // Update Shadow UBO (Binding 9)
        // Shadow UBO is per frame now
        const cascade_count = @min(vulkan_state.?.config.shadow_cascade_count, types.MAX_SHADOW_CASCADES);
        const shadowUBOSize = @sizeOf(math.Mat4) * @as(u64, cascade_count) + @sizeOf(f32) * 4;
        if (!descriptor_mgr.vk_descriptor_manager_update_buffer(dm, set, 9, pipeline.shadowUBOs[i], 0, shadowUBOSize)) {
            pbr_log.err("Failed to update shadow UBO descriptor", .{});
            return false;
        }

        // Update SSAO Map (Binding 10)
        var ssaoView: c.VkImageView = null;
        var ssaoSampler: c.VkSampler = pipeline.textureManager.?.defaultSampler;

        if (vulkan_state) |vs| {
            if (vs.pipelines.use_ssao and vs.pipelines.ssao_pipeline.initialized and vs.pipelines.ssao_pipeline.ssao_blur_view[i] != null) {
                ssaoView = vs.pipelines.ssao_pipeline.ssao_blur_view[i];
                if (vs.pipelines.post_process_pipeline.initialized) {
                    ssaoSampler = vs.pipelines.post_process_pipeline.sampler;
                }
            }
        }

        // Fallback to placeholder if SSAO not available
        if (ssaoView == null) {
            if (pipeline.textureManager.?.textureCount > 0) {
                ssaoView = pipeline.textureManager.?.textures.?[0].view;
                if (pipeline.textureManager.?.textures.?[0].sampler) |s| {
                    ssaoSampler = s;
                }
            }
        }

        if (ssaoView != null) {
            if (!descriptor_mgr.vk_descriptor_manager_update_image(dm, set, 10, ssaoView, ssaoSampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
                pbr_log.err("Failed to update SSAO map descriptor", .{});
                return false;
            }
        }
    }

    return true;
}

// Exported functions

pub export fn vk_pbr_load_scene(pipeline: ?*types.VulkanPBRPipeline, device: c.VkDevice, physicalDevice: c.VkPhysicalDevice, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, scene_data: ?*const scene.CardinalScene, allocator: ?*types.VulkanAllocator, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    _ = physicalDevice;

    if (pipeline == null or !pipeline.?.initialized) {
        pbr_log.warn("Pipeline not initialized", .{});
        return true;
    }
    const pipe = pipeline.?;
    const alloc = allocator.?;

    if (scene_data) |scn| {
        pbr_log.info("Loading scene: {d} meshes", .{scn.mesh_count});
    } else {
        pbr_log.info("Clearing scene (null scene)", .{});
    }

    // Clean up previous buffers if they exist (after ensuring GPU idle)
    // We use vkDeviceWaitIdle instead of timeline semaphore wait to avoid issues with
    // timeline resets/overflows during scene loading.
    if (vulkan_state != null and vulkan_state.?.context.device != null) {
        wrappers.Device.init(vulkan_state.?.context.device).waitIdle() catch {};
    }

    if (pipe.vertexBuffer != null or pipe.vertexBufferMemory != null) {
        vk_allocator.free_buffer(alloc, pipe.vertexBuffer, pipe.vertexBufferAllocation);
        pipe.vertexBuffer = null;
        pipe.vertexBufferMemory = null;
        pipe.vertexBufferAllocation = null;
    }
    if (pipe.indexBuffer != null or pipe.indexBufferMemory != null) {
        vk_allocator.free_buffer(alloc, pipe.indexBuffer, pipe.indexBufferAllocation);
        pipe.indexBuffer = null;
        pipe.indexBufferMemory = null;
        pipe.indexBufferAllocation = null;
    }

    if (scene_data == null) {
        return true;
    }
    const scn = scene_data.?;

    if (scn.mesh_count == 0) {
        pbr_log.info("Scene cleared (no meshes)", .{});
        return true;
    }

    // Create vertex and index buffers
    if (!create_pbr_mesh_buffers(pipe, device, alloc, commandPool, graphicsQueue, scn, vulkan_state)) {
        return false;
    }

    // Texture manager handles its own synchronization during cleanup
    pipe.textureManager.?.syncManager = vulkan_state.?.sync_manager;

    // Load scene textures using texture manager
    if (!vk_texture_mgr.vk_texture_manager_load_scene_textures(pipe.textureManager.?, scn)) {
        pbr_log.err("Failed to load scene textures using texture manager", .{});
        return false;
    }

    if (pipe.textureManager != null) {
        pbr_log.info("Loaded {d} textures using texture manager", .{pipe.textureManager.?.textureCount});
    }

    // Reset descriptor pool to reclaim sets from previous scene loads
    if (pipe.descriptorManager != null) {
        descriptor_mgr.vk_descriptor_manager_reset(@as(*types.VulkanDescriptorManager, @ptrCast(pipe.descriptorManager)));
    }

    // Allocate descriptor set using descriptor manager
    const dm = @as(*types.VulkanDescriptorManager, @ptrCast(pipe.descriptorManager));

    if (!descriptor_mgr.vk_descriptor_manager_allocate(dm)) {
        pbr_log.err("Failed to allocate descriptor set", .{});
        return false;
    }

    // Wait for graphics queue to complete before updating descriptor sets
    const result = c.vkQueueWaitIdle(graphicsQueue);
    if (result != c.VK_SUCCESS) {
        pbr_log.warn("Graphics queue wait idle failed before descriptor update: {d}", .{result});
        return false;
    }

    // Update descriptor sets
    if (!update_pbr_descriptor_sets(@ptrCast(pipe), vulkan_state)) {
        return false;
    }

    pbr_log.info("Scene loaded successfully", .{});
    return true;
}

fn create_shadow_resources(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, vulkan_state: ?*types.VulkanState) bool {
    const config = &vulkan_state.?.config;
    const shadow_map_size = config.shadow_map_size;
    const shadow_cascade_count = @min(config.shadow_cascade_count, types.MAX_SHADOW_CASCADES);
    const shadow_format = config.shadow_map_format;

    // Create Shadow Image (2D Array)
    var imageInfo = std.mem.zeroes(c.VkImageCreateInfo);
    imageInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = c.VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = shadow_map_size;
    imageInfo.extent.height = shadow_map_size;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = shadow_cascade_count;
    imageInfo.format = shadow_format;
    imageInfo.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    imageInfo.samples = c.VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    var allocInfo = std.mem.zeroes(c.VmaAllocationCreateInfo);
    allocInfo.usage = c.VMA_MEMORY_USAGE_AUTO;
    allocInfo.flags = c.VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT;

    if (c.vmaCreateImage(allocator.handle, &imageInfo, &allocInfo, &pipeline.shadowMapImage, &pipeline.shadowMapAllocation, null) != c.VK_SUCCESS) {
        pbr_log.err("Failed to create shadow map image", .{});
        return false;
    }

    // Create View
    var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
    viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = pipeline.shadowMapImage;
    viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D_ARRAY;
    viewInfo.format = shadow_format;
    viewInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = shadow_cascade_count;

    if (c.vkCreateImageView(device, &viewInfo, null, &pipeline.shadowMapView) != c.VK_SUCCESS) {
        pbr_log.err("Failed to create shadow map view", .{});
        return false;
    }

    // Create Per-Cascade Views
    var cascade_idx: u32 = 0;
    while (cascade_idx < shadow_cascade_count) : (cascade_idx += 1) {
        viewInfo.subresourceRange.baseArrayLayer = cascade_idx;
        viewInfo.subresourceRange.layerCount = 1;
        if (c.vkCreateImageView(device, &viewInfo, null, &pipeline.shadowCascadeViews[cascade_idx]) != c.VK_SUCCESS) {
            pbr_log.err("Failed to create shadow cascade view {d}", .{cascade_idx});
            return false;
        }
    }

    // Create Sampler (PCF compatible)
    var samplerInfo = std.mem.zeroes(c.VkSamplerCreateInfo);
    samplerInfo.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = c.VK_FILTER_LINEAR;
    samplerInfo.minFilter = c.VK_FILTER_LINEAR;
    samplerInfo.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
    samplerInfo.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    samplerInfo.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    samplerInfo.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    samplerInfo.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE;
    samplerInfo.compareEnable = c.VK_TRUE;
    samplerInfo.compareOp = c.VK_COMPARE_OP_LESS;

    if (c.vkCreateSampler(device, &samplerInfo, null, &pipeline.shadowMapSampler) != c.VK_SUCCESS) {
        pbr_log.err("Failed to create shadow map sampler", .{});
        return false;
    }

    // Create Shadow UBOs
    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        var bufferInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
        bufferInfo.size = @sizeOf(math.Mat4) * @as(u64, shadow_cascade_count) + @sizeOf(f32) * 4; // Matrices + Splits
        bufferInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        bufferInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        bufferInfo.persistentlyMapped = true;

        var shadowBuffer: buffer_mgr.VulkanBuffer = undefined;
        if (!buffer_mgr.vk_buffer_create(&shadowBuffer, device, allocator, &bufferInfo)) return false;

        pipeline.shadowUBOs[i] = shadowBuffer.handle;
        pipeline.shadowUBOsMemory[i] = shadowBuffer.memory;
        pipeline.shadowUBOsAllocation[i] = shadowBuffer.allocation;
        pipeline.shadowUBOsMapped[i] = shadowBuffer.mapped;
    }

    return true;
}

fn create_shadow_pipeline(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, vulkan_state: ?*types.VulkanState) bool {

    // Create Descriptor Manager
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (ptr == null) {
        pbr_log.err("Failed to allocate memory for shadow descriptor manager", .{});
        return false;
    }
    pipeline.shadowDescriptorManager = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(ptr)));

    const renderer_allocator = mem_alloc.as_allocator();
    var desc_builder = descriptor_mgr.DescriptorBuilder.init(renderer_allocator);
    defer desc_builder.deinit();

    // Binding 0: Shadow UBO
    desc_builder.add_binding(0, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, c.VK_SHADER_STAGE_VERTEX_BIT) catch return false;
    // Binding 6: Bone Matrices
    desc_builder.add_binding(6, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, c.VK_SHADER_STAGE_VERTEX_BIT) catch return false;

    if (!desc_builder.build(pipeline.shadowDescriptorManager.?, device, allocator, vulkan_state, types.MAX_FRAMES_IN_FLIGHT, true)) {
        pbr_log.err("Failed to build shadow descriptor manager", .{});
        return false;
    }

    // Allocate Sets
    if (!descriptor_mgr.vk_descriptor_manager_allocate_sets(pipeline.shadowDescriptorManager, types.MAX_FRAMES_IN_FLIGHT, &pipeline.shadowDescriptorSets)) {
        pbr_log.err("Failed to allocate shadow descriptor sets", .{});
        return false;
    }

    // Update Sets
    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        // Binding 0
        const cascade_count = @min(vulkan_state.?.config.shadow_cascade_count, types.MAX_SHADOW_CASCADES);
        const shadowUBOSize = @sizeOf(math.Mat4) * @as(u64, cascade_count) + @sizeOf(f32) * 4;
        if (!descriptor_mgr.vk_descriptor_manager_update_buffer(pipeline.shadowDescriptorManager, pipeline.shadowDescriptorSets[i], 0, pipeline.shadowUBOs[i], 0, shadowUBOSize)) {
            pbr_log.err("Failed to update shadow UBO descriptor", .{});
            return false;
        }

        // Binding 6
        if (!descriptor_mgr.vk_descriptor_manager_update_buffer(pipeline.shadowDescriptorManager, pipeline.shadowDescriptorSets[i], 6, pipeline.boneMatricesBuffers[i], 0, pipeline.maxBones * 16 * @sizeOf(f32))) {
            pbr_log.err("Failed to update bone matrices descriptor", .{});
            return false;
        }
    }

    // Push Constant Range
    var pushConstantRange = std.mem.zeroes(c.VkPushConstantRange);
    pushConstantRange.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    pushConstantRange.offset = 0;
    pushConstantRange.size = 156; // model(64) + padding + hasSkeleton(4) + cascadeIndex(4) -> 156

    // Pipeline Layout
    var pipelineLayoutInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipelineLayoutInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;

    var layouts: [2]c.VkDescriptorSetLayout = undefined;
    layouts[0] = descriptor_mgr.vk_descriptor_manager_get_layout(pipeline.shadowDescriptorManager);
    var layoutCount: u32 = 1;

    if (pipeline.textureManager) |tm| {
        const bindlessLayout = vk_descriptor_indexing.vk_bindless_texture_get_layout(&tm.bindless_pool);
        if (bindlessLayout != null) {
            layouts[1] = bindlessLayout;
            layoutCount = 2;
        }
    }

    pipelineLayoutInfo.setLayoutCount = layoutCount;
    pipelineLayoutInfo.pSetLayouts = &layouts;
    pipelineLayoutInfo.pushConstantRangeCount = 1;
    pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;

    if (c.vkCreatePipelineLayout(device, &pipelineLayoutInfo, null, &pipeline.shadowPipelineLayout) != c.VK_SUCCESS) {
        pbr_log.err("Failed to create shadow pipeline layout", .{});
        return false;
    }

    // Use PipelineBuilder
    var builder = vk_pso.PipelineBuilder.init(renderer_allocator, device, null);

    const pipeline_dir_span = std.mem.span(@as([*:0]const u8, @ptrCast(&vulkan_state.?.config.pipeline_dir)));
    const shadow_path = std.fmt.allocPrint(renderer_allocator, "{s}/shadow.json", .{pipeline_dir_span}) catch return false;
    defer renderer_allocator.free(shadow_path);

    var parsed = vk_pso.PipelineBuilder.load_from_json(renderer_allocator, shadow_path) catch |err| {
        pbr_log.err("Failed to load shadow pipeline JSON: {s}", .{@errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;
    descriptor.rendering.depth_format = vulkan_state.?.config.shadow_map_format;
    descriptor.rendering.color_formats = &.{};

    if (pipeline.shadowDescriptorManager) |mgr| {
        if (mgr.useDescriptorBuffers) {
            descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }
    // Also check texture manager for descriptor buffer bit
    if (pipeline.textureManager) |tm| {
        if (tm.bindless_pool.use_descriptor_buffer) {
            descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }

    builder.build(descriptor, pipeline.shadowPipelineLayout, &pipeline.shadowPipeline) catch |err| {
        pbr_log.err("Failed to build shadow pipeline: {s}", .{@errorName(err)});
        return false;
    };

    // Create Alpha-Tested Shadow Pipeline
    const shadow_alpha_path = std.fmt.allocPrint(renderer_allocator, "{s}/shadow_alpha.json", .{pipeline_dir_span}) catch return false;
    defer renderer_allocator.free(shadow_alpha_path);

    var parsedAlpha = vk_pso.PipelineBuilder.load_from_json(renderer_allocator, shadow_alpha_path) catch |err| {
        pbr_log.err("Failed to load shadow alpha pipeline JSON: {s}", .{@errorName(err)});
        // Don't fail completely, just skip alpha shadows
        return true;
    };
    defer parsedAlpha.deinit();

    var descAlpha = parsedAlpha.value;
    descAlpha.rendering.depth_format = vulkan_state.?.config.shadow_map_format;
    descAlpha.rendering.color_formats = &.{};

    if (pipeline.shadowDescriptorManager) |mgr| {
        if (mgr.useDescriptorBuffers) {
            descAlpha.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }
    if (pipeline.textureManager) |tm| {
        if (tm.bindless_pool.use_descriptor_buffer) {
            descAlpha.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }

    builder.build(descAlpha, pipeline.shadowPipelineLayout, &pipeline.shadowAlphaPipeline) catch |err| {
        pbr_log.err("Failed to build shadow alpha pipeline: {s}", .{@errorName(err)});
        // Don't fail completely
    };

    return true;
}

pub export fn vk_pbr_pipeline_create(pipeline: ?*types.VulkanPBRPipeline, device: c.VkDevice, physicalDevice: c.VkPhysicalDevice, swapchainFormat: c.VkFormat, depthFormat: c.VkFormat, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, allocator: ?*types.VulkanAllocator, vulkan_state: ?*types.VulkanState, pipelineCache: c.VkPipelineCache) callconv(.c) bool {
    _ = physicalDevice;
    if (pipeline == null or allocator == null) return false;
    const pipe = pipeline.?;
    const alloc = allocator.?;

    pbr_log.debug("Starting PBR pipeline creation", .{});

    @memset(@as([*]u8, @ptrCast(pipe))[0..@sizeOf(types.VulkanPBRPipeline)], 0);

    pipe.supportsDescriptorIndexing = true;
    pipe.totalIndexCount = 0;

    pbr_log.info("Descriptor indexing support: enabled", .{});

    // Allocator for reflection data
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    var arena = std.heap.ArenaAllocator.init(renderer_allocator);
    defer arena.deinit();
    const allocator_arena = arena.allocator();

    var set0_bindings = std.AutoHashMap(u32, c.VkDescriptorSetLayoutBinding).init(allocator_arena);

    var pushConstantRange = c.VkPushConstantRange{
        .stageFlags = 0,
        .offset = 0,
        .size = 0,
    };

    var vertShader: c.VkShaderModule = null;
    var fragShader: c.VkShaderModule = null;

    // Load Shaders and Reflect
    const process_shader = struct {
        fn func(dev: c.VkDevice, name: []const u8, stage: c.VkShaderStageFlags, module_out: *c.VkShaderModule, map: *std.AutoHashMap(u32, c.VkDescriptorSetLayoutBinding), pc: *c.VkPushConstantRange, allocator_ref: std.mem.Allocator, shader_dir: []const u8) !bool {
            var path: [512]u8 = undefined;
            var shaders_dir: [*c]const u8 = @ptrCast(c.getenv("CARDINAL_SHADERS_DIR"));
            if (shaders_dir == null or shaders_dir[0] == 0) {
                shaders_dir = @ptrCast(shader_dir.ptr);
            }
            _ = c.snprintf(&path, 512, "%s/%s", shaders_dir, name.ptr);
            const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&path)));

            const code = shader_utils.vk_shader_read_file(allocator_ref, path_slice) catch |err| {
                pbr_log.err("Failed to read shader {s}: {s}", .{ path_slice, @errorName(err) });
                return false;
            };

            if (!shader_utils.vk_shader_create_module_from_code(dev, code.ptr, code.len * 4, module_out)) {
                pbr_log.err("Failed to create shader module for {s}", .{path_slice});
                return false;
            }

            const reflect = shader_utils.reflection.reflect_shader(allocator_ref, code, stage) catch |err| {
                pbr_log.err("Failed to reflect shader {s}: {s}", .{ path_slice, @errorName(err) });
                return false;
            };

            if (reflect.push_constant_size > 0) {
                pc.stageFlags |= reflect.push_constant_stages;
                if (reflect.push_constant_size > pc.size) pc.size = reflect.push_constant_size;
            } else {
                // If reflection fails to find push constants, assume max size needed
                pc.stageFlags |= stage;
                if (@sizeOf(types.PBRPushConstants) > pc.size) pc.size = @sizeOf(types.PBRPushConstants);
            }

            for (reflect.resources.items) |res| {
                if (res.set != 0) continue; // Only process Set 0 for descriptor manager

                const entry = try map.getOrPut(res.binding);
                if (entry.found_existing) {
                    entry.value_ptr.stageFlags |= res.stage_flags;
                } else {
                    entry.value_ptr.* = .{
                        .binding = res.binding,
                        .descriptorType = res.type,
                        .descriptorCount = res.count,
                        .stageFlags = res.stage_flags,
                        .pImmutableSamplers = null,
                    };
                }
            }
            return true;
        }
    }.func;

    const shader_dir_span = std.mem.span(@as([*:0]const u8, @ptrCast(&vulkan_state.?.config.shader_dir)));

    if (process_shader(device, "pbr.vert.spv", c.VK_SHADER_STAGE_VERTEX_BIT, &vertShader, &set0_bindings, &pushConstantRange, allocator_arena, shader_dir_span) catch false) {
        // OK
    } else {
        return false;
    }

    if (process_shader(device, "pbr.frag.spv", c.VK_SHADER_STAGE_FRAGMENT_BIT, &fragShader, &set0_bindings, &pushConstantRange, allocator_arena, shader_dir_span) catch false) {
        // OK
    } else {
        c.vkDestroyShaderModule(device, vertShader, null);
        return false;
    }

    // Ensure push constant size is at least what struct expects (safety check)
    if (pushConstantRange.size < @sizeOf(types.PBRPushConstants)) {
        pushConstantRange.size = @sizeOf(types.PBRPushConstants);
    }
    if (pushConstantRange.stageFlags == 0) {
        pushConstantRange.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    }

    if (!create_pbr_descriptor_manager(pipe, device, alloc, vulkan_state, &set0_bindings)) {
        return false;
    }
    pbr_log.debug("Descriptor manager created successfully", .{});

    // Cache descriptor buffer binding info if using buffers
    pipe.set0_binding_info_valid = false;
    if (pipe.descriptorManager) |dm| {
        if (dm.useDescriptorBuffers) {
            if (descriptor_mgr.vk_descriptor_manager_get_binding_info(dm, &pipe.set0_binding_info)) {
                pipe.set0_binding_info_valid = true;
                pbr_log.debug("Cached Set 0 descriptor buffer binding info", .{});
            }
        }
    }

    if (!create_pbr_texture_manager(pipe, device, alloc, commandPool, graphicsQueue, vulkan_state)) {
        vk_pbr_pipeline_destroy(pipeline, device, allocator);
        return false;
    }
    pbr_log.debug("Texture manager initialized successfully", .{});

    if (!create_pbr_pipeline_layout(pipe, device, &pushConstantRange)) {
        vk_pbr_pipeline_destroy(pipeline, device, allocator);
        return false;
    }

    const dev = wrappers.Device.init(device);

    const pipeline_dir_span = std.mem.span(@as([*:0]const u8, @ptrCast(&vulkan_state.?.config.pipeline_dir)));
    const opaque_path = std.fmt.allocPrint(renderer_allocator, "{s}/pbr_opaque.json", .{pipeline_dir_span}) catch return false;
    defer renderer_allocator.free(opaque_path);

    if (!create_pbr_graphics_pipeline(pipe, device, vertShader, fragShader, swapchainFormat, depthFormat, opaque_path, &pipe.pipeline, pipelineCache)) {
        dev.destroyShaderModule(vertShader);
        dev.destroyShaderModule(fragShader);
        vk_pbr_pipeline_destroy(pipeline, device, allocator);
        return false;
    }

    const transparent_path = std.fmt.allocPrint(renderer_allocator, "{s}/pbr_transparent.json", .{pipeline_dir_span}) catch return false;
    defer renderer_allocator.free(transparent_path);

    if (!create_pbr_graphics_pipeline(pipe, device, vertShader, fragShader, swapchainFormat, depthFormat, transparent_path, &pipe.pipelineBlend, pipelineCache)) {
        dev.destroyShaderModule(vertShader);
        dev.destroyShaderModule(fragShader);
        vk_pbr_pipeline_destroy(pipeline, device, allocator);
        return false;
    }

    dev.destroyShaderModule(vertShader);
    dev.destroyShaderModule(fragShader);

    pbr_log.debug("PBR graphics pipelines created", .{});

    if (!create_pbr_uniform_buffers(pipe, device, alloc)) {
        vk_pbr_pipeline_destroy(pipeline, device, allocator);
        return false;
    }

    // Initialize Shadow Maps
    if (!create_shadow_resources(pipe, device, alloc, vulkan_state)) {
        pbr_log.err("Failed to create shadow resources", .{});
        vk_pbr_pipeline_destroy(pipeline, device, allocator);
        return false;
    }

    if (!create_shadow_pipeline(pipe, device, alloc, vulkan_state)) {
        pbr_log.err("Failed to create shadow pipeline", .{});
        vk_pbr_pipeline_destroy(pipeline, device, allocator);
        return false;
    }

    initialize_pbr_defaults(pipe, &vulkan_state.?.config);

    pipe.initialized = true;
    pbr_log.info("PBR pipeline created successfully", .{});
    return true;
}

pub export fn vk_pbr_pipeline_destroy(pipeline: ?*types.VulkanPBRPipeline, device: c.VkDevice, allocator: ?*types.VulkanAllocator) callconv(.c) void {
    if (pipeline == null) {
        pbr_log.err("vk_pbr_pipeline_destroy called with null pipeline", .{});
        return;
    }
    if (!pipeline.?.initialized) {
        pbr_log.warn("vk_pbr_pipeline_destroy called on uninitialized pipeline (cleaning up partial resources)", .{});
        // Continue cleanup even if not initialized, to handle partial failures
    }
    const pipe = pipeline.?;
    const alloc = allocator.?;

    pbr_log.debug("vk_pbr_pipeline_destroy: start", .{});

    if (pipe.textureManager != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        vk_texture_mgr.vk_texture_manager_destroy(pipe.textureManager.?);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(pipe.textureManager)));
        pipe.textureManager = null;
    }

    if (pipe.vertexBuffer != null or pipe.vertexBufferMemory != null) {
        vk_allocator.free_buffer(alloc, pipe.vertexBuffer, pipe.vertexBufferAllocation);
    }

    if (pipe.indexBuffer != null or pipe.indexBufferMemory != null) {
        vk_allocator.free_buffer(alloc, pipe.indexBuffer, pipe.indexBufferAllocation);
    }

    var frame_idx: u32 = 0;
    while (frame_idx < types.MAX_FRAMES_IN_FLIGHT) : (frame_idx += 1) {
        if (pipe.uniformBuffers[frame_idx] != null or pipe.uniformBuffersMemory[frame_idx] != null) {
            if (pipe.uniformBuffersMapped[frame_idx] != null) {
                pipe.uniformBuffersMapped[frame_idx] = null;
            }
            vk_allocator.free_buffer(alloc, pipe.uniformBuffers[frame_idx], pipe.uniformBuffersAllocation[frame_idx]);
        }

        if (pipe.lightingBuffers[frame_idx] != null or pipe.lightingBuffersMemory[frame_idx] != null) {
            if (pipe.lightingBuffersMapped[frame_idx] != null) {
                pipe.lightingBuffersMapped[frame_idx] = null;
            }
            vk_allocator.free_buffer(alloc, pipe.lightingBuffers[frame_idx], pipe.lightingBuffersAllocation[frame_idx]);
        }

        if (pipe.boneMatricesBuffers[frame_idx] != null or pipe.boneMatricesBuffersMemory[frame_idx] != null) {
            if (pipe.boneMatricesBuffersMapped[frame_idx] != null) {
                pipe.boneMatricesBuffersMapped[frame_idx] = null;
            }
            vk_allocator.free_buffer(alloc, pipe.boneMatricesBuffers[frame_idx], pipe.boneMatricesBuffersAllocation[frame_idx]);
        }

        if (pipe.shadowUBOs[frame_idx] != null or pipe.shadowUBOsMemory[frame_idx] != null) {
            if (pipe.shadowUBOsMapped[frame_idx] != null) {
                pipe.shadowUBOsMapped[frame_idx] = null;
            }
            vk_allocator.free_buffer(alloc, pipe.shadowUBOs[frame_idx], pipe.shadowUBOsAllocation[frame_idx]);
        }
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

    if (pipe.shadowPipeline != null) {
        c.vkDestroyPipeline(device, pipe.shadowPipeline, null);
    }
    if (pipe.shadowAlphaPipeline != null) {
        c.vkDestroyPipeline(device, pipe.shadowAlphaPipeline, null);
    }
    if (pipe.shadowPipelineLayout != null) {
        c.vkDestroyPipelineLayout(device, pipe.shadowPipelineLayout, null);
    }
    if (pipe.shadowDescriptorManager != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        descriptor_mgr.vk_descriptor_manager_destroy(@ptrCast(pipe.shadowDescriptorManager));
        memory.cardinal_free(mem_alloc, pipe.shadowDescriptorManager);
        pipe.shadowDescriptorManager = null;
    }

    var i: u32 = 0;
    while (i < pipe.shadowCascadeViews.len) : (i += 1) {
        if (pipe.shadowCascadeViews[i] != null) {
            c.vkDestroyImageView(device, pipe.shadowCascadeViews[i], null);
        }
    }

    if (pipe.shadowMapView != null) {
        c.vkDestroyImageView(device, pipe.shadowMapView, null);
    }
    if (pipe.shadowMapImage != null) {
        vk_allocator.free_image(alloc, pipe.shadowMapImage, pipe.shadowMapAllocation);
    }
    if (pipe.shadowMapSampler != null) {
        c.vkDestroySampler(device, pipe.shadowMapSampler, null);
    }

    @memset(@as([*]u8, @ptrCast(pipe))[0..@sizeOf(types.VulkanPBRPipeline)], 0);
    pbr_log.info("PBR pipeline destroyed", .{});
}

pub export fn vk_pbr_update_uniforms(pipeline: ?*types.VulkanPBRPipeline, ubo: ?*const types.PBRUniformBufferObject, lighting: ?*const types.PBRLightingBuffer, frame_index: u32) callconv(.c) void {
    if (pipeline == null or !pipeline.?.initialized) return;
    const pipe = pipeline.?;
    const frame = if (frame_index >= types.MAX_FRAMES_IN_FLIGHT) 0 else frame_index;

    if (ubo != null and pipe.uniformBuffersMapped[frame] != null) {
        @memcpy(@as([*]u8, @ptrCast(pipe.uniformBuffersMapped[frame]))[0..@sizeOf(types.PBRUniformBufferObject)], @as([*]const u8, @ptrCast(ubo))[0..@sizeOf(types.PBRUniformBufferObject)]);
    }

    if (lighting != null and pipe.lightingBuffersMapped[frame] != null) {
        @memcpy(@as([*]u8, @ptrCast(pipe.lightingBuffersMapped[frame]))[0..@sizeOf(types.PBRLightingBuffer)], @as([*]const u8, @ptrCast(lighting))[0..@sizeOf(types.PBRLightingBuffer)]);
    }
}

const SortItem = struct {
    index: u32,
    distSq: f32,
    indexOffset: u32,

    pub fn lessThan(context: void, lhs: @This(), rhs: @This()) bool {
        _ = context;
        return lhs.distSq > rhs.distSq; // Far to Near (Descending)
    }
};

pub export fn vk_pbr_create_depth_prepass(vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (vulkan_state == null) return false;
    const s = vulkan_state.?;
    const device = s.context.device;
    const pbr_pipe = &s.pipelines.pbr_pipeline;
    const depth_log = log.ScopedLogger("PBR_DEPTH");

    // 1. Create Pipeline Layout
    var pipelineLayoutInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipelineLayoutInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;

    var layouts: [2]c.VkDescriptorSetLayout = undefined;

    // Use main PBR descriptor manager layout
    if (pbr_pipe.descriptorManager == null) {
        depth_log.err("PBR descriptor manager is null", .{});
        return false;
    }
    layouts[0] = descriptor_mgr.vk_descriptor_manager_get_layout(pbr_pipe.descriptorManager);
    var layoutCount: u32 = 1;

    if (pbr_pipe.textureManager) |tm| {
        const bindlessLayout = vk_descriptor_indexing.vk_bindless_texture_get_layout(&tm.bindless_pool);
        if (bindlessLayout != null) {
            layouts[1] = bindlessLayout;
            layoutCount = 2;
        }
    }

    pipelineLayoutInfo.setLayoutCount = layoutCount;
    pipelineLayoutInfo.pSetLayouts = &layouts;

    // Push constants (same as PBR)
    var pushConstantRange = c.VkPushConstantRange{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(types.PBRPushConstants),
    };
    pipelineLayoutInfo.pushConstantRangeCount = 1;
    pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;

    if (c.vkCreatePipelineLayout(device, &pipelineLayoutInfo, null, &s.pipelines.depth_pipeline_layout) != c.VK_SUCCESS) {
        depth_log.err("Failed to create depth pipeline layout", .{});
        return false;
    }

    // 2. Load Pipeline from JSON (reuse shadow.json but override)
    // Allocator for temporary build data
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    var builder = vk_pso.PipelineBuilder.init(renderer_allocator, device, null);

    const pipeline_dir_span = std.mem.span(@as([*:0]const u8, @ptrCast(&s.config.pipeline_dir)));
    const shadow_path = std.fmt.allocPrint(renderer_allocator, "{s}/shadow.json", .{pipeline_dir_span}) catch return false;
    defer renderer_allocator.free(shadow_path);

    var parsed = vk_pso.PipelineBuilder.load_from_json(renderer_allocator, shadow_path) catch |err| {
        depth_log.err("Failed to load shadow pipeline JSON for depth pass: {s}", .{@errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;

    // 3. Override Descriptor for Main Depth Pass
    descriptor.rendering.depth_format = s.swapchain.depth_format;
    descriptor.rendering.color_formats = &.{}; // No color output

    // Standard Back-face culling for main camera
    descriptor.rasterization.cull_mode = .back;

    // Depth Test/Write should already be true in shadow.json
    // Compare Op should be LESS
    descriptor.depth_stencil.depth_compare_op = .less;

    // Add Descriptor Buffer flags if needed
    if (pbr_pipe.descriptorManager) |mgr| {
        if (mgr.useDescriptorBuffers) {
            descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }
    if (pbr_pipe.textureManager) |tm| {
        if (tm.bindless_pool.use_descriptor_buffer) {
            descriptor.flags |= c.VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
    }

    // 4. Build Pipeline
    builder.build(descriptor, s.pipelines.depth_pipeline_layout, &s.pipelines.depth_pipeline) catch |err| {
        depth_log.err("Failed to build depth pipeline: {s}", .{@errorName(err)});
        return false;
    };

    depth_log.info("Depth pre-pass pipeline created", .{});
    return true;
}

pub export fn vk_pbr_render_depth_prepass(vulkan_state: ?*types.VulkanState, commandBuffer: c.VkCommandBuffer, scene_data: ?*const scene.CardinalScene, frame_index: u32) callconv(.c) void {
    if (vulkan_state == null or scene_data == null) return;
    const s = vulkan_state.?;
    const pipe = &s.pipelines.pbr_pipeline;
    const scn = scene_data.?;
    const cmd = wrappers.CommandBuffer.init(commandBuffer);
    const frame = if (frame_index >= types.MAX_FRAMES_IN_FLIGHT) 0 else frame_index;

    if (pipe.vertexBuffer == null or pipe.indexBuffer == null) return;
    if (s.pipelines.depth_pipeline == null) return;

    // Bind Pipeline
    cmd.bindPipeline(c.VK_PIPELINE_BIND_POINT_GRAPHICS, s.pipelines.depth_pipeline);

    // Bind Vertex/Index Buffers
    const vertexBuffers = [_]c.VkBuffer{pipe.vertexBuffer};
    const offsets = [_]c.VkDeviceSize{0};
    cmd.bindVertexBuffers(0, &vertexBuffers, &offsets);
    cmd.bindIndexBuffer(pipe.indexBuffer, 0, c.VK_INDEX_TYPE_UINT32);

    // Bind Descriptors (Logic copied from vk_pbr_render)
    var descriptorSet: c.VkDescriptorSet = null;
    if (pipe.descriptorManager) |mgr| {
        const dm = @as(*types.VulkanDescriptorManager, @ptrCast(mgr));
        if (dm.useDescriptorBuffers) {
            descriptorSet = @ptrFromInt(frame + 1);
        } else if (dm.descriptorSets != null and dm.descriptorSetCount > frame) {
            descriptorSet = dm.descriptorSets.?[frame];
        }
    }

    var use_buffers = false;
    if (pipe.descriptorManager) |mgr| {
        const dm = @as(*types.VulkanDescriptorManager, @ptrCast(mgr));
        use_buffers = dm.useDescriptorBuffers;
    }
    if (!use_buffers and (descriptorSet == null or @intFromPtr(descriptorSet) == 0)) return;

    // Determine binding method
    var use_buffers_0 = false;
    var use_buffers_1 = false;
    if (pipe.descriptorManager) |mgr| {
        if (descriptor_mgr.vk_descriptor_manager_uses_buffers(mgr)) use_buffers_0 = true;
    }
    if (pipe.textureManager) |tm| {
        if (tm.bindless_pool.use_descriptor_buffer) use_buffers_1 = true;
    }

    // Bind Buffers (EXT)
    if (use_buffers_0 or use_buffers_1) {
        var binding_infos: [2]c.VkDescriptorBufferBindingInfoEXT = undefined;
        var binding_count: u32 = 0;
        var set0_idx: u32 = 0;
        var set1_idx: u32 = 0;

        if (use_buffers_0) {
            set0_idx = binding_count;
            if (pipe.set0_binding_info_valid) {
                binding_infos[binding_count] = pipe.set0_binding_info;
            } else {
                _ = descriptor_mgr.vk_descriptor_manager_get_binding_info(pipe.descriptorManager, &binding_infos[binding_count]);
            }
            binding_count += 1;
        }

        if (use_buffers_1) {
            set1_idx = binding_count;
            const tm = pipe.textureManager.?;
            binding_infos[binding_count] = std.mem.zeroes(c.VkDescriptorBufferBindingInfoEXT);
            binding_infos[binding_count].sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT;
            binding_infos[binding_count].address = tm.bindless_pool.descriptor_buffer_address;
            binding_infos[binding_count].usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT;
            binding_count += 1;
        }

        if (binding_count > 0) {
            var bind_func: c.PFN_vkCmdBindDescriptorBuffersEXT = null;
            if (use_buffers_0) {
                const mgr = pipe.descriptorManager.?;
                if (mgr.vulkan_state) |vs_ptr| {
                    const vs = @as(*types.VulkanState, @ptrCast(@alignCast(vs_ptr)));
                    bind_func = vs.context.vkCmdBindDescriptorBuffersEXT;
                }
            } else if (use_buffers_1) {
                bind_func = pipe.textureManager.?.bindless_pool.vkCmdBindDescriptorBuffersEXT;
            }
            if (bind_func) |f| {
                f(commandBuffer, binding_count, &binding_infos);
            }
        }

        if (use_buffers_0) {
            var sets: ?[*]const c.VkDescriptorSet = null;
            var descriptorSets = [_]c.VkDescriptorSet{descriptorSet};
            if (descriptorSet != null and @intFromPtr(descriptorSet) != 0) {
                sets = &descriptorSets;
            }
            descriptor_mgr.vk_descriptor_manager_set_offsets(pipe.descriptorManager, commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, s.pipelines.depth_pipeline_layout, 0, 1, sets, set0_idx);
        }
        if (use_buffers_1) {
            const tm = pipe.textureManager.?;
            if (tm.bindless_pool.vkCmdSetDescriptorBufferOffsetsEXT) |set_offsets| {
                const buffer_index = set1_idx;
                const offset: c.VkDeviceSize = 0;
                set_offsets(commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, s.pipelines.depth_pipeline_layout, 1, 1, &buffer_index, &offset);
            }
        }
    }

    c.vkCmdSetDepthBias(commandBuffer, 0.0, 0.0, 0.0);

    // Draw Loop
    var indexOffset: u32 = 0;
    var i: u32 = 0;
    while (i < scn.mesh_count) : (i += 1) {
        const mesh = &scn.meshes.?[i];

        // Skip Transparent
        if (mesh.material_index < scn.material_count) {
            const mat = &scn.materials.?[mesh.material_index];
            if (mat.alpha_mode == scene.CardinalAlphaMode.BLEND) {
                indexOffset += mesh.index_count;
                continue;
            }
            if (mat.alpha_mode == scene.CardinalAlphaMode.MASK) {
                c.vkCmdSetDepthBias(commandBuffer, -16.0, 0.0, -8.0);
            } else {
                c.vkCmdSetDepthBias(commandBuffer, 0.0, 0.0, 0.0);
            }
        }

        if (mesh.vertices == null or mesh.vertex_count == 0 or mesh.indices == null or mesh.index_count == 0) {
            // Even if we skip rendering (e.g. no vertices), we MUST increment indexOffset if indices were added to the buffer
            if (mesh.index_count > 0 and mesh.indices != null) {
                indexOffset += mesh.index_count;
            }
            continue;
        }
        if (!mesh.visible) {
            indexOffset += mesh.index_count;
            continue;
        }

        var pushConstants = std.mem.zeroes(types.PBRPushConstants);
        const tm_opaque: ?*const anyopaque = if (pipe.textureManager) |tm| @ptrCast(tm) else null;
        material_utils.vk_material_setup_push_constants(@ptrCast(&pushConstants), @ptrCast(mesh), @ptrCast(scn), @ptrCast(@alignCast(tm_opaque)));

        cmd.pushConstants(s.pipelines.depth_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(types.PBRPushConstants), &pushConstants);

        if (indexOffset + mesh.index_count > pipe.totalIndexCount) break;

        cmd.drawIndexed(mesh.index_count, 1, indexOffset, 0, 0);
        indexOffset += mesh.index_count;
    }
}

pub export fn vk_pbr_render(pipeline: ?*types.VulkanPBRPipeline, commandBuffer: c.VkCommandBuffer, scene_data: ?*const scene.CardinalScene, frame_index: u32) callconv(.c) void {
    if (pipeline == null or !pipeline.?.initialized or scene_data == null) {
        // pbr_log.warn("vk_pbr_render skipped: pipeline or scene null", .{});
        return;
    }
    const pipe = pipeline.?;
    const scn = scene_data.?;
    const cmd = wrappers.CommandBuffer.init(commandBuffer);
    const frame = if (frame_index >= types.MAX_FRAMES_IN_FLIGHT) 0 else frame_index;

    if (pipe.vertexBuffer == null or pipe.indexBuffer == null) {
        pbr_log.warn("vk_pbr_render skipped: vertex/index buffer null", .{});
        return;
    }

    const vertexBuffers = [_]c.VkBuffer{pipe.vertexBuffer};
    const offsets = [_]c.VkDeviceSize{0};
    cmd.bindVertexBuffers(0, &vertexBuffers, &offsets);
    cmd.bindIndexBuffer(pipe.indexBuffer, 0, c.VK_INDEX_TYPE_UINT32);

    var descriptorSet: c.VkDescriptorSet = null;
    if (pipe.descriptorManager != null) {
        const dm = @as(*types.VulkanDescriptorManager, @ptrCast(pipe.descriptorManager));

        if (dm.useDescriptorBuffers) {
            // Pseudo-handle for descriptor buffers must be 1-based to avoid NULL handle
            descriptorSet = @ptrFromInt(frame + 1);
        } else {
            if (dm.descriptorSets != null and dm.descriptorSetCount > frame) {
                descriptorSet = dm.descriptorSets.?[frame];
            } else {
                pbr_log.warn("vk_pbr_render skipped: no descriptor sets", .{});
                return;
            }
        }
    } else {
        pbr_log.warn("vk_pbr_render skipped: no descriptor manager", .{});
        return;
    }

    var use_buffers = false;
    if (pipe.descriptorManager) |mgr| {
        const dm = @as(*types.VulkanDescriptorManager, @ptrCast(mgr));
        use_buffers = dm.useDescriptorBuffers;
    }

    if (!use_buffers and (descriptorSet == null or @intFromPtr(descriptorSet) == 0)) {
        pbr_log.err("vk_pbr_render: descriptorSet is NULL or invalid!", .{});
        return;
    }

    // Pass 1: Opaque
    cmd.bindPipeline(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipeline);

    // Unified Descriptor Binding (Buffers or Sets)
    var use_buffers_0 = false;
    var use_buffers_1 = false;

    if (pipe.descriptorManager) |mgr| {
        if (descriptor_mgr.vk_descriptor_manager_uses_buffers(mgr)) use_buffers_0 = true;
    }
    if (pipe.textureManager) |tm| {
        if (tm.bindless_pool.use_descriptor_buffer) use_buffers_1 = true;
    }

    // pbr_log.debug("vk_pbr_render: buffers_0={s}, buffers_1={s}", .{ if(use_buffers_0) "true" else "false", if(use_buffers_1) "true" else "false" });

    // Buffer Path (if either uses buffers)
    if (use_buffers_0 or use_buffers_1) {
        var binding_infos: [2]c.VkDescriptorBufferBindingInfoEXT = undefined;
        var binding_count: u32 = 0;
        var set0_idx: u32 = 0;
        var set1_idx: u32 = 0;

        if (use_buffers_0) {
            set0_idx = binding_count;
            if (pipe.set0_binding_info_valid) {
                binding_infos[binding_count] = pipe.set0_binding_info;
            } else {
                _ = descriptor_mgr.vk_descriptor_manager_get_binding_info(pipe.descriptorManager, &binding_infos[binding_count]);
            }
            binding_count += 1;
        }

        if (use_buffers_1) {
            set1_idx = binding_count;
            const tm = pipe.textureManager.?;
            binding_infos[binding_count] = std.mem.zeroes(c.VkDescriptorBufferBindingInfoEXT);
            binding_infos[binding_count].sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT;
            binding_infos[binding_count].address = tm.bindless_pool.descriptor_buffer_address;
            binding_infos[binding_count].usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT;
            binding_count += 1;
        }

        if (binding_count > 0) {
            var bind_func: c.PFN_vkCmdBindDescriptorBuffersEXT = null;

            if (use_buffers_0) {
                const mgr = pipe.descriptorManager.?;
                if (mgr.vulkan_state) |vs_ptr| {
                    const vs = @as(*types.VulkanState, @ptrCast(@alignCast(vs_ptr)));
                    bind_func = vs.context.vkCmdBindDescriptorBuffersEXT;
                }
            } else if (use_buffers_1) {
                bind_func = pipe.textureManager.?.bindless_pool.vkCmdBindDescriptorBuffersEXT;
            }

            if (bind_func) |f| {
                f(commandBuffer, binding_count, &binding_infos);
            }
        }

        if (use_buffers_0) {
            var sets: ?[*]const c.VkDescriptorSet = null;
            var descriptorSets = [_]c.VkDescriptorSet{descriptorSet};
            if (descriptorSet != null and @intFromPtr(descriptorSet) != 0) {
                sets = &descriptorSets;
            }
            descriptor_mgr.vk_descriptor_manager_set_offsets(pipe.descriptorManager, commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 0, 1, sets, set0_idx);
        }

        if (use_buffers_1) {
            const tm = pipe.textureManager.?;
            if (tm.bindless_pool.vkCmdSetDescriptorBufferOffsetsEXT) |set_offsets| {
                const buffer_index = set1_idx;
                const offset: c.VkDeviceSize = 0;
                set_offsets(commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 1, 1, &buffer_index, &offset);
            }
        }
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
            if (mesh.index_count > 0 and mesh.indices != null) {
                indexOffset += mesh.index_count;
            }
            continue;
        }

        // Apply depth bias for MASK materials (e.g. decals) to prevent Z-fighting
        if (is_mask) {
            c.vkCmdSetDepthBias(commandBuffer, -16.0, 0.0, -8.0);
        } else {
            c.vkCmdSetDepthBias(commandBuffer, 0.0, 0.0, 0.0);
        }

        if (mesh.vertices == null or mesh.vertex_count == 0 or mesh.indices == null or mesh.index_count == 0 or mesh.index_count > 1000000000) {
            // Even if we skip rendering (e.g. no vertices), we MUST increment indexOffset if indices were added to the buffer
            // to keep alignment with the buffer layout created in create_pbr_mesh_buffers.
            if (mesh.index_count > 0 and mesh.indices != null) {
                indexOffset += mesh.index_count;
            }
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
            const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(scn.skins.?)));

            var skin_idx: u32 = 0;
            while (skin_idx < scn.skin_count) : (skin_idx += 1) {
                const skin = &skins[skin_idx];
                var mesh_idx: u32 = 0;
                while (mesh_idx < skin.mesh_count) : (mesh_idx += 1) {
                    if (skin.mesh_indices.?[mesh_idx] == i) {
                        // Set bit 2 of flags in packedInfo
                        // flags is in upper 16 bits of packedInfo
                        // Bit 2 corresponds to (1 << 2) = 4
                        // Shifted by 16: (4 << 16)
                        pushConstants.packedInfo |= (4 << 16);
                        break;
                    }
                }
                if ((pushConstants.packedInfo & (4 << 16)) != 0) break;
            }
        }

        cmd.pushConstants(pipe.pipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(types.PBRPushConstants), &pushConstants);

        if (indexOffset + mesh.index_count > pipe.totalIndexCount) break;

        cmd.drawIndexed(mesh.index_count, 1, indexOffset, 0, 0);
        drawn_count += 1;
        indexOffset += mesh.index_count;
    }

    // Pass 2: Blend
    cmd.bindPipeline(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineBlend);

    // Re-bind descriptor sets (Unified)
    if (use_buffers_0 or use_buffers_1) {
        var binding_infos: [2]c.VkDescriptorBufferBindingInfoEXT = undefined;
        var binding_count: u32 = 0;
        var set0_idx: u32 = 0;
        var set1_idx: u32 = 0;

        if (use_buffers_0) {
            set0_idx = binding_count;
            if (pipe.set0_binding_info_valid) {
                binding_infos[binding_count] = pipe.set0_binding_info;
            } else {
                _ = descriptor_mgr.vk_descriptor_manager_get_binding_info(pipe.descriptorManager, &binding_infos[binding_count]);
            }
            binding_count += 1;
        }

        if (use_buffers_1) {
            set1_idx = binding_count;
            const tm = pipe.textureManager.?;
            binding_infos[binding_count] = std.mem.zeroes(c.VkDescriptorBufferBindingInfoEXT);
            binding_infos[binding_count].sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT;
            binding_infos[binding_count].address = tm.bindless_pool.descriptor_buffer_address;
            binding_infos[binding_count].usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT;
            binding_count += 1;
        }

        if (binding_count > 0) {
            var bind_func: c.PFN_vkCmdBindDescriptorBuffersEXT = null;

            if (use_buffers_0) {
                const mgr = pipe.descriptorManager.?;
                if (mgr.vulkan_state) |vs_ptr| {
                    const vs = @as(*types.VulkanState, @ptrCast(@alignCast(vs_ptr)));
                    bind_func = vs.context.vkCmdBindDescriptorBuffersEXT;
                }
            } else if (use_buffers_1) {
                bind_func = pipe.textureManager.?.bindless_pool.vkCmdBindDescriptorBuffersEXT;
            }

            if (bind_func) |f| {
                f(commandBuffer, binding_count, &binding_infos);
            }
        }

        if (use_buffers_0) {
            var sets: ?[*]const c.VkDescriptorSet = null;
            var descriptorSets = [_]c.VkDescriptorSet{descriptorSet};
            if (descriptorSet != null and @intFromPtr(descriptorSet) != 0) {
                sets = &descriptorSets;
            }
            descriptor_mgr.vk_descriptor_manager_set_offsets(pipe.descriptorManager, commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 0, 1, sets, set0_idx);
        }

        if (use_buffers_1) {
            const tm = pipe.textureManager.?;
            if (tm.bindless_pool.vkCmdSetDescriptorBufferOffsetsEXT) |set_offsets| {
                const buffer_index = set1_idx;
                const offset: c.VkDeviceSize = 0;
                set_offsets(commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 1, 1, &buffer_index, &offset);
            }
        }
    }

    // Apply depth bias for transparent materials too (to prevent z-fighting with coplanar opaque surfaces)
    c.vkCmdSetDepthBias(commandBuffer, -16.0, 0.0, -8.0);

    // Sort Transparent Meshes (Back-to-Front)
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const allocator = mem_alloc.as_allocator();
    var transparent_meshes = std.ArrayListUnmanaged(SortItem){};
    defer transparent_meshes.deinit(allocator);

    const ubo = @as(*types.PBRUniformBufferObject, @ptrCast(@alignCast(pipe.uniformBuffersMapped[frame])));
    const camPos = math.Vec3.fromArray(ubo.viewPos);

    var currentIndexOffset: u32 = 0;
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

        if (is_blend) {
            if (mesh.vertices != null and mesh.vertex_count > 0 and mesh.indices != null and mesh.index_count > 0 and mesh.visible) {
                // Calculate world space center using bounding box if available, otherwise transform origin
                // AABB is in local space, so transform it to world space
                const min = math.Vec3.fromArray(mesh.bounding_box_min);
                const max = math.Vec3.fromArray(mesh.bounding_box_max);
                const centerLocal = min.add(max).mul(0.5);

                // Transform center to world space
                // Matrix is Column-Major:
                // x = m[0]*v.x + m[4]*v.y + m[8]*v.z + m[12]
                // y = m[1]*v.x + m[5]*v.y + m[9]*v.z + m[13]
                // z = m[2]*v.x + m[6]*v.y + m[10]*v.z + m[14]

                const m = mesh.transform;
                const wx = m[0] * centerLocal.x + m[4] * centerLocal.y + m[8] * centerLocal.z + m[12];
                const wy = m[1] * centerLocal.x + m[5] * centerLocal.y + m[9] * centerLocal.z + m[13];
                const wz = m[2] * centerLocal.x + m[6] * centerLocal.y + m[10] * centerLocal.z + m[14];
                const centerWorld = math.Vec3{ .x = wx, .y = wy, .z = wz };

                const distSq = centerWorld.sub(camPos).lengthSq();
                transparent_meshes.append(allocator, .{ .index = i, .distSq = distSq, .indexOffset = currentIndexOffset }) catch |err| {
                    pbr_log.err("Failed to append transparent mesh: {s}", .{@errorName(err)});
                };
            }
        }

        if (mesh.index_count > 0 and mesh.indices != null) {
            currentIndexOffset += mesh.index_count;
        }
    }

    std.sort.block(SortItem, transparent_meshes.items, {}, SortItem.lessThan);

    for (transparent_meshes.items) |item| {
        const mesh = &scn.meshes.?[item.index];

        var pushConstants = std.mem.zeroes(types.PBRPushConstants);
        const tm_opaque: ?*const anyopaque = if (pipe.textureManager) |tm| @ptrCast(tm) else null;
        material_utils.vk_material_setup_push_constants(@ptrCast(&pushConstants), @ptrCast(mesh), @ptrCast(scn), @ptrCast(@alignCast(tm_opaque)));

        if (scn.animation_system != null and scn.skin_count > 0) {
            const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(scn.skins.?)));

            var skin_idx: u32 = 0;
            while (skin_idx < scn.skin_count) : (skin_idx += 1) {
                const skin = &skins[skin_idx];
                var mesh_idx: u32 = 0;
                while (mesh_idx < skin.mesh_count) : (mesh_idx += 1) {
                    if (skin.mesh_indices.?[mesh_idx] == item.index) {
                        pushConstants.packedInfo |= (4 << 16);
                        break;
                    }
                }
                if ((pushConstants.packedInfo & (4 << 16)) != 0) break;
            }
        }

        cmd.pushConstants(pipe.pipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(types.PBRPushConstants), &pushConstants);

        if (item.indexOffset + mesh.index_count > pipe.totalIndexCount) continue;

        cmd.drawIndexed(mesh.index_count, 1, item.indexOffset, 0, 0);
    }
}
