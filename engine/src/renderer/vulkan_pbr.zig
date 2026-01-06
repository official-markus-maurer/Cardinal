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
const buffer_utils = @import("util/vulkan_buffer_utils.zig");
const descriptor_utils = @import("util/vulkan_descriptor_utils.zig");
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

// Helper functions

fn create_pbr_descriptor_manager(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator, vulkan_state: ?*types.VulkanState, bindings_map: *std.AutoHashMap(u32, c.VkDescriptorSetLayoutBinding)) bool {
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

fn create_pbr_pipeline_layout(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, pushConstantRange: *const c.VkPushConstantRange) bool {
    var descriptorLayouts: [2]c.VkDescriptorSetLayout = undefined;
    descriptorLayouts[0] = descriptor_mgr.vk_descriptor_manager_get_layout(@ptrCast(pipeline.descriptorManager));
    var layoutCount: u32 = 1;

    if (pipeline.textureManager != null) {
        log.cardinal_log_info("PBR: Checking bindless pool...", .{});
        // Always try to use bindless layout if pool is valid, even if no textures yet
        const bindlessLayout = vk_descriptor_indexing.vk_bindless_texture_get_layout(&pipeline.textureManager.?.bindless_pool);
        if (bindlessLayout != null) {
            log.cardinal_log_info("PBR: Bindless layout found and added to pipeline layout at index 1. Handle: 0x{x}", .{@intFromPtr(bindlessLayout)});
            descriptorLayouts[1] = bindlessLayout;
            layoutCount = 2;
        } else {
            log.cardinal_log_error("PBR: Bindless pool exists but layout is NULL!", .{});
        }
    } else {
        log.cardinal_log_error("PBR: Texture manager is NULL, cannot add bindless layout!", .{});
    }

    const device_wrapper = wrappers.Device.init(device);
    const setLayouts = descriptorLayouts[0..layoutCount];
    const pushConstantRanges = [_]c.VkPushConstantRange{pushConstantRange.*};

    pipeline.pipelineLayout = device_wrapper.createPipelineLayout(setLayouts, &pushConstantRanges) catch |err| {
        log.cardinal_log_error("Failed to create PBR pipeline layout: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn create_pbr_graphics_pipeline(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, vertShader: c.VkShaderModule, fragShader: c.VkShaderModule, swapchainFormat: c.VkFormat, depthFormat: c.VkFormat, json_path: []const u8, outPipeline: *c.VkPipeline, pipelineCache: c.VkPipelineCache) bool {
    var builder = vk_pso.PipelineBuilder.init(std.heap.page_allocator, device, pipelineCache);

    var parsed = vk_pso.PipelineBuilder.load_from_json(std.heap.page_allocator, json_path) catch |err| {
        log.cardinal_log_error("Failed to load pipeline JSON '{s}': {s}", .{json_path, @errorName(err)});
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
    descriptor.fragment_shader.module_handle = @intFromPtr(fragShader);

    // Override rendering formats
    var color_formats = [_]c.VkFormat{swapchainFormat};
    descriptor.rendering.color_formats = &color_formats;
    descriptor.rendering.depth_format = depthFormat;

    builder.build(descriptor, pipeline.pipelineLayout, outPipeline) catch {
        return false;
    };
    
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

    // Update Shadow Map (Binding 7)
    if (pipeline.shadowMapView != null) {
        if (!descriptor_mgr.vk_descriptor_manager_update_image(dm, setIndex, 7, pipeline.shadowMapView, pipeline.shadowMapSampler, c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL)) {
             log.cardinal_log_error("Failed to update shadow map descriptor", .{});
             return false;
        }
    }

    // Update Shadow UBO (Binding 9)
    if (pipeline.shadowUBO != null) {
        const shadowUBOSize = @sizeOf(math.Mat4) * SHADOW_CASCADE_COUNT + @sizeOf(f32) * 4;
        if (!descriptor_mgr.vk_descriptor_manager_update_buffer(dm, setIndex, 9, pipeline.shadowUBO, 0, shadowUBOSize)) {
             log.cardinal_log_error("Failed to update shadow UBO descriptor", .{});
             return false;
        }
    }

    return true;
}

// Exported functions

pub export fn vk_pbr_load_scene(pipeline: ?*types.VulkanPBRPipeline, device: c.VkDevice, physicalDevice: c.VkPhysicalDevice, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, scene_data: ?*const scene.CardinalScene, allocator: ?*types.VulkanAllocator, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    _ = physicalDevice;

    if (pipeline == null or !pipeline.?.initialized) {
        log.cardinal_log_warn("PBR pipeline not initialized", .{});
        return true;
    }
    const pipe = pipeline.?;
    const alloc = allocator.?;

    if (scene_data) |scn| {
        log.cardinal_log_info("Loading PBR scene: {d} meshes", .{scn.mesh_count});
    } else {
        log.cardinal_log_info("Clearing PBR scene (null scene)", .{});
    }

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

    if (scene_data == null) {
        return true;
    }
    const scn = scene_data.?;

    if (scn.mesh_count == 0) {
        log.cardinal_log_info("PBR scene cleared (no meshes)", .{});
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
            // Clear the tracking array to avoid stale references
            // The descriptor sets are implicitly freed by reset, so we just clear our CPU-side tracking
            // Use memset on the pointer value, not the pointer itself (which is on stack if not careful)
            // dm.descriptorSets is ?[*]VkDescriptorSet
            if (dm.descriptorSets) |ptr| {
                @memset(ptr[0..dm.maxSets], null);
            }
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

const SHADOW_MAP_SIZE: u32 = 2048;
const SHADOW_CASCADE_COUNT: u32 = 4;
const SHADOW_FORMAT = c.VK_FORMAT_D32_SFLOAT;

fn create_shadow_resources(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator) bool {
    // Create Shadow Image (2D Array)
    var imageInfo = std.mem.zeroes(c.VkImageCreateInfo);
    imageInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = c.VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = SHADOW_MAP_SIZE;
    imageInfo.extent.height = SHADOW_MAP_SIZE;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = SHADOW_CASCADE_COUNT;
    imageInfo.format = SHADOW_FORMAT;
    imageInfo.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    imageInfo.samples = c.VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    
    var allocInfo = std.mem.zeroes(c.VmaAllocationCreateInfo);
    allocInfo.usage = c.VMA_MEMORY_USAGE_AUTO;
    allocInfo.flags = c.VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT;
    
    if (c.vmaCreateImage(allocator.handle, &imageInfo, &allocInfo, &pipeline.shadowMapImage, &pipeline.shadowMapAllocation, null) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create shadow map image", .{});
        return false;
    }
    
    // Create View
    var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
    viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = pipeline.shadowMapImage;
    viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D_ARRAY;
    viewInfo.format = SHADOW_FORMAT;
    viewInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = SHADOW_CASCADE_COUNT;
    
    if (c.vkCreateImageView(device, &viewInfo, null, &pipeline.shadowMapView) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create shadow map view", .{});
        return false;
    }

    // Create Per-Cascade Views
    var i: u32 = 0;
    while (i < SHADOW_CASCADE_COUNT) : (i += 1) {
        viewInfo.subresourceRange.baseArrayLayer = i;
        viewInfo.subresourceRange.layerCount = 1;
        if (c.vkCreateImageView(device, &viewInfo, null, &pipeline.shadowCascadeViews[i]) != c.VK_SUCCESS) {
             log.cardinal_log_error("Failed to create shadow cascade view {d}", .{i});
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
        log.cardinal_log_error("Failed to create shadow map sampler", .{});
        return false;
    }
    
    // Create Shadow UBO
    var bufferInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
    bufferInfo.size = @sizeOf(math.Mat4) * SHADOW_CASCADE_COUNT + @sizeOf(f32) * 4; // Matrices + Splits
    bufferInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    bufferInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    bufferInfo.persistentlyMapped = true;
    
    var shadowBuffer: buffer_mgr.VulkanBuffer = undefined;
    if (!buffer_mgr.vk_buffer_create(&shadowBuffer, device, allocator, &bufferInfo)) return false;
    
    pipeline.shadowUBO = shadowBuffer.handle;
    pipeline.shadowUBOMemory = shadowBuffer.memory;
    pipeline.shadowUBOAllocation = shadowBuffer.allocation;
    pipeline.shadowUBOMapped = shadowBuffer.mapped;
    
    return true;
}

fn create_shadow_pipeline(pipeline: *types.VulkanPBRPipeline, device: c.VkDevice, allocator: *types.VulkanAllocator) bool {
    _ = allocator;
    // Descriptor Set Layout
    var bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 6,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        }
    };
    
    var layoutInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layoutInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = bindings.len;
    layoutInfo.pBindings = &bindings;
    
    if (c.vkCreateDescriptorSetLayout(device, &layoutInfo, null, &pipeline.shadowDescriptorSetLayout) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create shadow descriptor set layout", .{});
        return false;
    }
    
    // Create Descriptor Pool
    var poolSizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 2 },
    };
    
    var poolInfo = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    poolInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.poolSizeCount = poolSizes.len;
    poolInfo.pPoolSizes = &poolSizes;
    poolInfo.maxSets = 1;
    
    if (c.vkCreateDescriptorPool(device, &poolInfo, null, &pipeline.shadowDescriptorPool) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create shadow descriptor pool", .{});
        return false;
    }
    
    // Allocate Set
    var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool = pipeline.shadowDescriptorPool;
    allocInfo.descriptorSetCount = 1;
    allocInfo.pSetLayouts = &pipeline.shadowDescriptorSetLayout;
    
    if (c.vkAllocateDescriptorSets(device, &allocInfo, &pipeline.shadowDescriptorSet) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to allocate shadow descriptor set", .{});
        return false;
    }
    
    // Update Set
    var bufferInfo0 = std.mem.zeroes(c.VkDescriptorBufferInfo);
    bufferInfo0.buffer = pipeline.shadowUBO;
    bufferInfo0.offset = 0;
    bufferInfo0.range = c.VK_WHOLE_SIZE;
    
    var write0 = std.mem.zeroes(c.VkWriteDescriptorSet);
    write0.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write0.dstSet = pipeline.shadowDescriptorSet;
    write0.dstBinding = 0;
    write0.descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    write0.descriptorCount = 1;
    write0.pBufferInfo = &bufferInfo0;
    
    var bufferInfo6 = std.mem.zeroes(c.VkDescriptorBufferInfo);
    bufferInfo6.buffer = pipeline.boneMatricesBuffer;
    bufferInfo6.offset = 0;
    bufferInfo6.range = c.VK_WHOLE_SIZE;
    
    var write6 = std.mem.zeroes(c.VkWriteDescriptorSet);
    write6.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write6.dstSet = pipeline.shadowDescriptorSet;
    write6.dstBinding = 6;
    write6.descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    write6.descriptorCount = 1;
    write6.pBufferInfo = &bufferInfo6;
    
    const writes = [_]c.VkWriteDescriptorSet{write0, write6};
    c.vkUpdateDescriptorSets(device, writes.len, &writes, 0, null);
    
    // Push Constant Range
    var pushConstantRange = std.mem.zeroes(c.VkPushConstantRange);
    pushConstantRange.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT;
    pushConstantRange.offset = 0;
    pushConstantRange.size = 156; // model(64) + padding + hasSkeleton(4) + cascadeIndex(4) -> 156
    
    // Pipeline Layout
    var pipelineLayoutInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipelineLayoutInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    pipelineLayoutInfo.pSetLayouts = &pipeline.shadowDescriptorSetLayout;
    pipelineLayoutInfo.pushConstantRangeCount = 1;
    pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;
    
    if (c.vkCreatePipelineLayout(device, &pipelineLayoutInfo, null, &pipeline.shadowPipelineLayout) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create shadow pipeline layout", .{});
        return false;
    }
    
    // Use PipelineBuilder
    var builder = vk_pso.PipelineBuilder.init(std.heap.page_allocator, device, null);

    var parsed = vk_pso.PipelineBuilder.load_from_json(std.heap.page_allocator, "assets/pipelines/shadow.json") catch |err| {
        log.cardinal_log_error("Failed to load shadow pipeline JSON: {s}", .{@errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;
    descriptor.rendering.depth_format = SHADOW_FORMAT;
    descriptor.rendering.color_formats = &.{}; 

    builder.build(descriptor, pipeline.shadowPipelineLayout, &pipeline.shadowPipeline) catch |err| {
        log.cardinal_log_error("Failed to build shadow pipeline: {s}", .{@errorName(err)});
        return false;
    };
    
    return true;
}

pub export fn vk_pbr_pipeline_create(pipeline: ?*types.VulkanPBRPipeline, device: c.VkDevice, physicalDevice: c.VkPhysicalDevice, swapchainFormat: c.VkFormat, depthFormat: c.VkFormat, commandPool: c.VkCommandPool, graphicsQueue: c.VkQueue, allocator: ?*types.VulkanAllocator, vulkan_state: ?*types.VulkanState, pipelineCache: c.VkPipelineCache) callconv(.c) bool {
    _ = physicalDevice;
    if (pipeline == null or allocator == null) return false;
    const pipe = pipeline.?;
    const alloc = allocator.?;

    log.cardinal_log_debug("Starting PBR pipeline creation", .{});

    @memset(@as([*]u8, @ptrCast(pipe))[0..@sizeOf(types.VulkanPBRPipeline)], 0);

    pipe.supportsDescriptorIndexing = true;
    pipe.totalIndexCount = 0;

    log.cardinal_log_info("[PBR] Descriptor indexing support: enabled", .{});

    // Allocator for reflection data
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
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
        fn func(dev: c.VkDevice, name: []const u8, stage: c.VkShaderStageFlags, module_out: *c.VkShaderModule,
               map: *std.AutoHashMap(u32, c.VkDescriptorSetLayoutBinding), pc: *c.VkPushConstantRange, allocator_ref: std.mem.Allocator) !bool {
             
             var path: [512]u8 = undefined;
             var shaders_dir: [*c]const u8 = @ptrCast(c.getenv("CARDINAL_SHADERS_DIR"));
             if (shaders_dir == null or shaders_dir[0] == 0) {
                 shaders_dir = "assets/shaders";
             }
             _ = c.snprintf(&path, 512, "%s/%s", shaders_dir, name.ptr);
             const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&path)));
             
             const code = shader_utils.vk_shader_read_file(allocator_ref, path_slice) catch |err| {
                 log.cardinal_log_error("Failed to read shader {s}: {s}", .{path_slice, @errorName(err)});
                 return false;
             };
             
             if (!shader_utils.vk_shader_create_module_from_code(dev, code.ptr, code.len * 4, module_out)) {
                 log.cardinal_log_error("Failed to create shader module for {s}", .{path_slice});
                 return false;
             }
             
             const reflect = shader_utils.reflection.reflect_shader(allocator_ref, code, stage) catch |err| {
                 log.cardinal_log_error("Failed to reflect shader {s}: {s}", .{path_slice, @errorName(err)});
                 return false;
             };
             
             if (reflect.push_constant_size > 0) {
                 pc.stageFlags |= reflect.push_constant_stages;
                 if (reflect.push_constant_size > pc.size) pc.size = reflect.push_constant_size;
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

    if (process_shader(device, "pbr.vert.spv", c.VK_SHADER_STAGE_VERTEX_BIT, &vertShader, &set0_bindings, &pushConstantRange, allocator_arena) catch false) {
        // OK
    } else {
        return false;
    }

    if (process_shader(device, "pbr.frag.spv", c.VK_SHADER_STAGE_FRAGMENT_BIT, &fragShader, &set0_bindings, &pushConstantRange, allocator_arena) catch false) {
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
    log.cardinal_log_debug("Descriptor manager created successfully", .{});

    if (!create_pbr_texture_manager(pipe, device, alloc, commandPool, graphicsQueue, vulkan_state)) {
        descriptor_mgr.vk_descriptor_manager_destroy(@ptrCast(pipe.descriptorManager));
        c.free(pipe.descriptorManager);
        return false;
    }
    log.cardinal_log_debug("Texture manager initialized successfully", .{});

    if (!create_pbr_pipeline_layout(pipe, device, &pushConstantRange)) {
        vk_texture_mgr.vk_texture_manager_destroy(pipe.textureManager.?);
        c.free(@as(?*anyopaque, @ptrCast(pipe.textureManager)));
        descriptor_mgr.vk_descriptor_manager_destroy(@ptrCast(pipe.descriptorManager));
        c.free(pipe.descriptorManager);
        return false;
    }

    const dev = wrappers.Device.init(device);

    if (!create_pbr_graphics_pipeline(pipe, device, vertShader, fragShader, swapchainFormat, depthFormat, "assets/pipelines/pbr_opaque.json", &pipe.pipeline, pipelineCache)) {
        dev.destroyShaderModule(vertShader);
        dev.destroyShaderModule(fragShader);
        return false;
    }

    if (!create_pbr_graphics_pipeline(pipe, device, vertShader, fragShader, swapchainFormat, depthFormat, "assets/pipelines/pbr_transparent.json", &pipe.pipelineBlend, pipelineCache)) {
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

    // Initialize Shadow Maps
    if (!create_shadow_resources(pipe, device, alloc)) {
        log.cardinal_log_error("Failed to create shadow resources", .{});
        return false;
    }

    if (!create_shadow_pipeline(pipe, device, alloc)) {
        log.cardinal_log_error("Failed to create shadow pipeline", .{});
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

    if (pipe.shadowPipeline != null) {
        c.vkDestroyPipeline(device, pipe.shadowPipeline, null);
    }
    if (pipe.shadowPipelineLayout != null) {
        c.vkDestroyPipelineLayout(device, pipe.shadowPipelineLayout, null);
    }
    if (pipe.shadowDescriptorPool != null) {
        c.vkDestroyDescriptorPool(device, pipe.shadowDescriptorPool, null);
    }
    if (pipe.shadowDescriptorSetLayout != null) {
        c.vkDestroyDescriptorSetLayout(device, pipe.shadowDescriptorSetLayout, null);
    }
    
    var i: u32 = 0;
    while (i < SHADOW_CASCADE_COUNT) : (i += 1) {
        if (pipe.shadowCascadeViews[i] != null) {
            c.vkDestroyImageView(device, pipe.shadowCascadeViews[i], null);
        }
    }
    
    if (pipe.shadowMapView != null) {
        c.vkDestroyImageView(device, pipe.shadowMapView, null);
    }
    if (pipe.shadowMapImage != null) {
        vk_allocator.vk_allocator_free_image(alloc, pipe.shadowMapImage, pipe.shadowMapAllocation);
    }
    if (pipe.shadowMapSampler != null) {
        c.vkDestroySampler(device, pipe.shadowMapSampler, null);
    }
    
    if (pipe.shadowUBO != null or pipe.shadowUBOMemory != null) {
        if (pipe.shadowUBOMapped != null) {
            vk_allocator.vk_allocator_unmap_memory(alloc, pipe.shadowUBOAllocation);
            pipe.shadowUBOMapped = null;
        }
        vk_allocator.vk_allocator_free_buffer(alloc, pipe.shadowUBO, pipe.shadowUBOAllocation);
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
    
    // Re-bind descriptor sets for new pipeline if needed (though layout compatibility usually allows inheritance, 
    // it's safer to rebind or rely on compatibility. Here we rebind for clarity and safety)
    cmd.bindDescriptorSets(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 0, &descriptorSets, &[_]u32{});

    if (pipe.textureManager != null) {
        if (pipe.textureManager.?.bindless_pool.descriptor_set) |bindlessSet| {
            const bindlessSets = [_]c.VkDescriptorSet{bindlessSet};
            cmd.bindDescriptorSets(c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.pipelineLayout, 1, &bindlessSets, &[_]u32{});
        }
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
