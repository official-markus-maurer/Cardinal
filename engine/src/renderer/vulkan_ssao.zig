const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const math = @import("../core/math.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_types.zig");
const vk_compute = @import("vulkan_compute.zig");
const buffer_mgr = @import("vulkan_buffer_manager.zig");
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");
const vk_descriptor_manager = @import("vulkan_descriptor_manager.zig");
const vk_allocator = @import("vulkan_allocator.zig");
const wrappers = @import("vulkan_wrappers.zig");

const c = @import("vulkan_c.zig").c;

const ssao_log = log.ScopedLogger("SSAO");

const SSAOKernel = extern struct {
    projection: math.Mat4,
    inverseProjection: math.Mat4,
    view: math.Mat4,
    samples: [64][4]f32,
    radius: f32,
    bias: f32,
    power: f32,
    resolutionScale: f32,
};

pub fn vk_ssao_init(s: *types.VulkanState) bool {
    s.pipelines.use_ssao = false;

    // 1. Create Resources (Images)
    if (!create_resources(s)) {
        ssao_log.err("Failed to create SSAO resources", .{});
        vk_ssao_destroy(s);
        return false;
    }

    // 2. Create Noise Texture & Kernel
    if (!create_noise_and_kernel(s)) {
        ssao_log.err("Failed to create SSAO noise/kernel", .{});
        vk_ssao_destroy(s);
        return false;
    }

    // 3. Create Descriptor Managers
    if (!create_descriptor_managers(s)) {
        ssao_log.err("Failed to create SSAO descriptor managers", .{});
        vk_ssao_destroy(s);
        return false;
    }

    // 4. Create Pipelines
    if (!create_pipelines(s)) {
        ssao_log.err("Failed to create SSAO pipelines", .{});
        vk_ssao_destroy(s);
        return false;
    }

    // 5. Update Descriptors
    if (!update_descriptors(s)) {
        ssao_log.err("Failed to update SSAO descriptors", .{});
        vk_ssao_destroy(s);
        return false;
    }

    s.pipelines.use_ssao = true;
    s.pipelines.ssao_pipeline.initialized = true;
    ssao_log.info("SSAO initialized successfully", .{});
    return true;
}

pub fn vk_ssao_destroy(s: *types.VulkanState) void {
    // Always attempt cleanup, even if not fully initialized
    const device = s.context.device;
    const allocator = &s.allocator;

    // Destroy Resources
    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        if (s.pipelines.ssao_pipeline.ssao_view[i] != null) {
            c.vkDestroyImageView(device, s.pipelines.ssao_pipeline.ssao_view[i], null);
            s.pipelines.ssao_pipeline.ssao_view[i] = null;
        }
        if (s.pipelines.ssao_pipeline.ssao_image[i] != null) {
            vk_allocator.free_image(allocator, s.pipelines.ssao_pipeline.ssao_image[i], s.pipelines.ssao_pipeline.ssao_allocation[i]);
            s.pipelines.ssao_pipeline.ssao_image[i] = null;
            s.pipelines.ssao_pipeline.ssao_allocation[i] = null;
        }

        if (s.pipelines.ssao_pipeline.ssao_blur_view[i] != null) {
            c.vkDestroyImageView(device, s.pipelines.ssao_pipeline.ssao_blur_view[i], null);
            s.pipelines.ssao_pipeline.ssao_blur_view[i] = null;
        }
        if (s.pipelines.ssao_pipeline.ssao_blur_image[i] != null) {
            vk_allocator.free_image(allocator, s.pipelines.ssao_pipeline.ssao_blur_image[i], s.pipelines.ssao_pipeline.ssao_blur_allocation[i]);
            s.pipelines.ssao_pipeline.ssao_blur_image[i] = null;
            s.pipelines.ssao_pipeline.ssao_blur_allocation[i] = null;
        }
    }

    // Destroy Descriptor Managers
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    if (s.pipelines.ssao_pipeline.descriptorManager) |mgr| {
        vk_descriptor_manager.vk_descriptor_manager_destroy(mgr);
        memory.cardinal_free(mem_alloc, mgr);
        s.pipelines.ssao_pipeline.descriptorManager = null;
    }
    if (s.pipelines.ssao_pipeline.blurDescriptorManager) |mgr| {
        vk_descriptor_manager.vk_descriptor_manager_destroy(mgr);
        memory.cardinal_free(mem_alloc, mgr);
        s.pipelines.ssao_pipeline.blurDescriptorManager = null;
    }

    // Destroy Noise & Kernel
    if (s.pipelines.ssao_pipeline.noise_texture.view != null) {
        c.vkDestroyImageView(device, s.pipelines.ssao_pipeline.noise_texture.view, null);
        s.pipelines.ssao_pipeline.noise_texture.view = null;
    }
    if (s.pipelines.ssao_pipeline.noise_texture.sampler != null) {
        c.vkDestroySampler(device, s.pipelines.ssao_pipeline.noise_texture.sampler, null);
        s.pipelines.ssao_pipeline.noise_texture.sampler = null;
    }
    if (s.pipelines.ssao_pipeline.noise_texture.image != null) {
        vk_allocator.free_image(allocator, s.pipelines.ssao_pipeline.noise_texture.image, s.pipelines.ssao_pipeline.noise_texture.allocation);
        s.pipelines.ssao_pipeline.noise_texture.image = null;
        s.pipelines.ssao_pipeline.noise_texture.allocation = null;
    }
    if (s.pipelines.ssao_pipeline.kernel_buffer != null) {
        vk_allocator.free_buffer(allocator, s.pipelines.ssao_pipeline.kernel_buffer, s.pipelines.ssao_pipeline.kernel_allocation);
        s.pipelines.ssao_pipeline.kernel_buffer = null;
        s.pipelines.ssao_pipeline.kernel_allocation = null;
    }

    // Destroy Kernel Buffer
    if (s.pipelines.ssao_pipeline.kernel_buffer != null) {
        var temp_buffer = std.mem.zeroes(buffer_mgr.VulkanBuffer);
        temp_buffer.handle = s.pipelines.ssao_pipeline.kernel_buffer;
        temp_buffer.memory = s.pipelines.ssao_pipeline.kernel_memory;
        temp_buffer.allocation = s.pipelines.ssao_pipeline.kernel_allocation;

        buffer_mgr.vk_buffer_destroy(&temp_buffer, device, allocator, s);
        s.pipelines.ssao_pipeline.kernel_buffer = null;
    }

    // Destroy Noise Texture
    if (s.pipelines.ssao_pipeline.noise_texture.image != null) {
        if (s.pipelines.ssao_pipeline.noise_texture.view != null) {
            c.vkDestroyImageView(device, s.pipelines.ssao_pipeline.noise_texture.view, null);
            s.pipelines.ssao_pipeline.noise_texture.view = null;
        }
        if (s.pipelines.ssao_pipeline.noise_texture.sampler != null) {
            c.vkDestroySampler(device, s.pipelines.ssao_pipeline.noise_texture.sampler, null);
            s.pipelines.ssao_pipeline.noise_texture.sampler = null;
        }
        vk_allocator.free_image(allocator, s.pipelines.ssao_pipeline.noise_texture.image, s.pipelines.ssao_pipeline.noise_texture.allocation);
        s.pipelines.ssao_pipeline.noise_texture.image = null;
    }

    // Destroy Pipelines
    if (s.pipelines.ssao_pipeline.pipeline.pipeline != null) {
        vk_compute.vk_compute_destroy_pipeline(s, &s.pipelines.ssao_pipeline.pipeline);
    }
    if (s.pipelines.ssao_pipeline.blur_pipeline.pipeline != null) {
        vk_compute.vk_compute_destroy_pipeline(s, &s.pipelines.ssao_pipeline.blur_pipeline);
    }

    s.pipelines.ssao_pipeline.initialized = false;
    s.pipelines.use_ssao = false;
}

pub fn vk_ssao_resize(s: *types.VulkanState, width: u32, height: u32) bool {
    _ = width;
    _ = height;
    if (!s.pipelines.ssao_pipeline.initialized) return false;

    const device = s.context.device;
    const allocator = &s.allocator;

    // Destroy old images
    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        if (s.pipelines.ssao_pipeline.ssao_view[i] != null) c.vkDestroyImageView(device, s.pipelines.ssao_pipeline.ssao_view[i], null);
        if (s.pipelines.ssao_pipeline.ssao_image[i] != null) vk_allocator.free_image(allocator, s.pipelines.ssao_pipeline.ssao_image[i], s.pipelines.ssao_pipeline.ssao_allocation[i]);

        if (s.pipelines.ssao_pipeline.ssao_blur_view[i] != null) c.vkDestroyImageView(device, s.pipelines.ssao_pipeline.ssao_blur_view[i], null);
        if (s.pipelines.ssao_pipeline.ssao_blur_image[i] != null) vk_allocator.free_image(allocator, s.pipelines.ssao_pipeline.ssao_blur_image[i], s.pipelines.ssao_pipeline.ssao_blur_allocation[i]);
    }

    // Recreate
    if (!create_resources(s)) return false;

    // Update Descriptors (since image views changed)
    return update_descriptors(s);
}

pub fn vk_ssao_compute(s: *types.VulkanState, cmd: c.VkCommandBuffer, frame_index: u32) void {
    if (!s.pipelines.use_ssao) return;

    const ssao = &s.pipelines.ssao_pipeline;
    const width = s.swapchain.extent.width;
    const height = s.swapchain.extent.height;

    // 1. Update Kernel Uniforms (Projection/View matrices might change)
    // We should map and update the kernel buffer here with current camera matrices.
    // Optimization: Only update matrices, kernel samples are static.
    if (s.pipelines.ssao_pipeline.kernel_allocation != null) {
        var data: ?*anyopaque = null;
        if (vk_allocator.map_memory(&s.allocator, s.pipelines.ssao_pipeline.kernel_allocation, &data) == c.VK_SUCCESS) {
            const ptr = @as(*SSAOKernel, @ptrCast(@alignCast(data)));

            const pbr_ubo = s.pipelines.pbr_pipeline.current_ubo;

            // Convert array to matrix
            const proj = math.Mat4.fromArray(pbr_ubo.proj);
            const view = math.Mat4.fromArray(pbr_ubo.view);
            const invProj = proj.invert() orelse math.Mat4.identity();

            ptr.projection = proj;
            ptr.view = view;
            ptr.inverseProjection = invProj;

            // Other params
            ptr.radius = 0.5; // Default radius
            ptr.bias = 0.025;
            ptr.power = 1.0;

            vk_allocator.unmap_memory(&s.allocator, s.pipelines.ssao_pipeline.kernel_allocation);
        }
    }

    // 2. Dispatch SSAO
    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, ssao.pipeline.pipeline);
    var sets = [_]c.VkDescriptorSet{ssao.descriptor_sets[frame_index]};
    vk_descriptor_manager.vk_descriptor_manager_bind_sets(ssao.descriptorManager, cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, ssao.pipeline.pipeline_layout, 0, 1, &sets, 0, null);

    const group_x = (width + 15) / 16;
    const group_y = (height + 15) / 16;
    c.vkCmdDispatch(cmd, group_x, group_y, 1);

    // Barrier: Wait for SSAO write before Blur read
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    barrier.srcAccessMask = c.VK_ACCESS_2_SHADER_WRITE_BIT;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_SHADER_READ_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_GENERAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
    barrier.image = ssao.ssao_image[frame_index];
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;

    var dep = std.mem.zeroes(c.VkDependencyInfo);
    dep.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &barrier;

    c.vkCmdPipelineBarrier2(cmd, &dep);

    // 3. Dispatch Blur
    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, ssao.blur_pipeline.pipeline);
    var blur_sets = [_]c.VkDescriptorSet{ssao.blur_descriptor_sets[frame_index]};
    vk_descriptor_manager.vk_descriptor_manager_bind_sets(ssao.blurDescriptorManager, cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, ssao.blur_pipeline.pipeline_layout, 0, 1, &blur_sets, 0, null);

    c.vkCmdDispatch(cmd, group_x, group_y, 1);

    // Barrier: Wait for Blur write before PBR read
    barrier.image = ssao.ssao_blur_image[frame_index];
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_SHADER_READ_BIT;
    // PBR reads as shader read only optimal usually, but General is fine if we transition.
    // For now keep as General.

    c.vkCmdPipelineBarrier2(cmd, &dep);
}

// Internal Helpers

fn create_resources(s: *types.VulkanState) bool {
    const width = s.swapchain.extent.width;
    const height = s.swapchain.extent.height;

    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.extent.width = width;
    image_info.extent.height = height;
    image_info.extent.depth = 1;
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.format = c.VK_FORMAT_R8_UNORM;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    image_info.usage = c.VK_IMAGE_USAGE_STORAGE_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        // SSAO Raw Image (R8 UNORM)
        if (!vk_allocator.allocate_image(&s.allocator, &image_info, &s.pipelines.ssao_pipeline.ssao_image[i], &s.pipelines.ssao_pipeline.ssao_memory[i], &s.pipelines.ssao_pipeline.ssao_allocation[i], c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) return false;

        if (!vk_texture_utils.create_texture_image_view(s.context.device, s.pipelines.ssao_pipeline.ssao_image[i], &s.pipelines.ssao_pipeline.ssao_view[i], c.VK_FORMAT_R8_UNORM)) return false;

        // SSAO Blur Image (R8 UNORM)
        if (!vk_allocator.allocate_image(&s.allocator, &image_info, &s.pipelines.ssao_pipeline.ssao_blur_image[i], &s.pipelines.ssao_pipeline.ssao_blur_memory[i], &s.pipelines.ssao_pipeline.ssao_blur_allocation[i], c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) return false;

        if (!vk_texture_utils.create_texture_image_view(s.context.device, s.pipelines.ssao_pipeline.ssao_blur_image[i], &s.pipelines.ssao_pipeline.ssao_blur_view[i], c.VK_FORMAT_R8_UNORM)) return false;

        // Transition layouts to General for Storage usage
        vk_texture_utils.transition_image_layout(s.context.device, s.context.graphics_queue, s.commands.pools.?[0], s.pipelines.ssao_pipeline.ssao_image[i], c.VK_FORMAT_R8_UNORM, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);

        vk_texture_utils.transition_image_layout(s.context.device, s.context.graphics_queue, s.commands.pools.?[0], s.pipelines.ssao_pipeline.ssao_blur_image[i], c.VK_FORMAT_R8_UNORM, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
    }

    return true;
}

fn create_noise_and_kernel(s: *types.VulkanState) bool {
    // 1. Kernel
    var kernel: SSAOKernel = undefined;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (0..64) |i| {
        var sample_vec = math.Vec3{ .x = random.float(f32) * 2.0 - 1.0, .y = random.float(f32) * 2.0 - 1.0, .z = random.float(f32) };
        sample_vec = sample_vec.normalize();

        var scale = @as(f32, @floatFromInt(i)) / 64.0;
        scale = math.lerp(0.1, 1.0, scale * scale);

        sample_vec = sample_vec.mul(scale);

        kernel.samples[i][0] = sample_vec.x;
        kernel.samples[i][1] = sample_vec.y;
        kernel.samples[i][2] = sample_vec.z;
        kernel.samples[i][3] = 0.0;
    }

    // Create Buffer
    var kernelBufferObj = std.mem.zeroes(buffer_mgr.VulkanBuffer);
    var kernelInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
    kernelInfo.size = @sizeOf(SSAOKernel);
    kernelInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    kernelInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

    if (!buffer_mgr.vk_buffer_create(&kernelBufferObj, s.context.device, @ptrCast(&s.allocator), &kernelInfo)) return false;

    s.pipelines.ssao_pipeline.kernel_buffer = kernelBufferObj.handle;
    s.pipelines.ssao_pipeline.kernel_memory = kernelBufferObj.memory;
    s.pipelines.ssao_pipeline.kernel_allocation = kernelBufferObj.allocation;

    // Upload Kernel (Initial)
    var data: ?*anyopaque = null;
    if (vk_allocator.map_memory(&s.allocator, s.pipelines.ssao_pipeline.kernel_allocation, &data) == c.VK_SUCCESS) {
        const ptr = @as(*SSAOKernel, @ptrCast(@alignCast(data)));
        ptr.* = kernel;
        vk_allocator.unmap_memory(&s.allocator, s.pipelines.ssao_pipeline.kernel_allocation);
    }

    // 2. Noise Texture
    var noise_data: [16]math.Vec4 = undefined;
    for (0..16) |i| {
        var noise_vec = math.Vec3{ .x = random.float(f32) * 2.0 - 1.0, .y = random.float(f32) * 2.0 - 1.0, .z = 0.0 };
        noise_vec = noise_vec.normalize();
        noise_data[i] = math.Vec4{ .x = noise_vec.x, .y = noise_vec.y, .z = noise_vec.z, .w = 0.0 };
    }

    // Create Noise Texture
    const noise_size = 16 * @sizeOf(math.Vec4);

    // Create Staging Buffer
    var stagingBufferObj = std.mem.zeroes(buffer_mgr.VulkanBuffer);
    var stagingInfo = std.mem.zeroes(buffer_mgr.VulkanBufferCreateInfo);
    stagingInfo.size = noise_size;
    stagingInfo.usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    stagingInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

    if (!buffer_mgr.vk_buffer_create(&stagingBufferObj, s.context.device, @ptrCast(&s.allocator), &stagingInfo)) {
        vk_allocator.free_buffer(&s.allocator, s.pipelines.ssao_pipeline.kernel_buffer, s.pipelines.ssao_pipeline.kernel_allocation);
        return false;
    }

    const staging_buffer = stagingBufferObj.handle;
    const staging_alloc = stagingBufferObj.allocation;

    if (vk_allocator.map_memory(&s.allocator, staging_alloc, &data) == c.VK_SUCCESS) {
        @memcpy(@as([*]u8, @ptrCast(data))[0..noise_size], @as([*]u8, @ptrCast(&noise_data))[0..noise_size]);
        vk_allocator.unmap_memory(&s.allocator, staging_alloc);
    }

    // Create Image
    if (!vk_texture_utils.create_image_and_memory(&s.allocator, s.context.device, 4, 4, c.VK_FORMAT_R32G32B32A32_SFLOAT, &s.pipelines.ssao_pipeline.noise_texture.image, &s.pipelines.ssao_pipeline.noise_texture.memory, &s.pipelines.ssao_pipeline.noise_texture.allocation)) {
        vk_allocator.free_buffer(&s.allocator, staging_buffer, staging_alloc);
        vk_allocator.free_buffer(&s.allocator, s.pipelines.ssao_pipeline.kernel_buffer, s.pipelines.ssao_pipeline.kernel_allocation);
        return false;
    }

    if (!vk_texture_utils.create_texture_image_view(s.context.device, s.pipelines.ssao_pipeline.noise_texture.image, &s.pipelines.ssao_pipeline.noise_texture.view, c.VK_FORMAT_R32G32B32A32_SFLOAT)) {
        vk_allocator.free_buffer(&s.allocator, staging_buffer, staging_alloc);
        vk_allocator.free_buffer(&s.allocator, s.pipelines.ssao_pipeline.kernel_buffer, s.pipelines.ssao_pipeline.kernel_allocation);
        vk_allocator.free_image(&s.allocator, s.pipelines.ssao_pipeline.noise_texture.image, s.pipelines.ssao_pipeline.noise_texture.allocation);
        return false;
    }

    // Transition and Copy
    vk_texture_utils.transition_image_layout(s.context.device, s.context.graphics_queue, s.commands.pools.?[0], s.pipelines.ssao_pipeline.noise_texture.image, c.VK_FORMAT_R32G32B32A32_SFLOAT, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    vk_texture_utils.copy_buffer_to_image(s.context.device, s.context.graphics_queue, s.commands.pools.?[0], staging_buffer, s.pipelines.ssao_pipeline.noise_texture.image, 4, 4);
    vk_texture_utils.transition_image_layout(s.context.device, s.context.graphics_queue, s.commands.pools.?[0], s.pipelines.ssao_pipeline.noise_texture.image, c.VK_FORMAT_R32G32B32A32_SFLOAT, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

    // Cleanup Staging
    buffer_mgr.vk_buffer_destroy(&stagingBufferObj, s.context.device, @ptrCast(&s.allocator), s);

    // Create Sampler (Repeat, Nearest)
    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_info.magFilter = c.VK_FILTER_NEAREST;
    sampler_info.minFilter = c.VK_FILTER_NEAREST;
    sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;

    if (c.vkCreateSampler(s.context.device, &sampler_info, null, &s.pipelines.ssao_pipeline.noise_texture.sampler) != c.VK_SUCCESS) {
        vk_allocator.free_buffer(&s.allocator, s.pipelines.ssao_pipeline.kernel_buffer, s.pipelines.ssao_pipeline.kernel_allocation);
        vk_allocator.free_image(&s.allocator, s.pipelines.ssao_pipeline.noise_texture.image, s.pipelines.ssao_pipeline.noise_texture.allocation);
        c.vkDestroyImageView(s.context.device, s.pipelines.ssao_pipeline.noise_texture.view, null);
        return false;
    }

    return true;
}

fn create_descriptor_managers(s: *types.VulkanState) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);

    // --- SSAO Manager ---
    const ssao_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (ssao_ptr == null) return false;
    s.pipelines.ssao_pipeline.descriptorManager = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(ssao_ptr)));

    var ssao_builder = vk_descriptor_manager.DescriptorBuilder.init(std.heap.page_allocator);
    defer ssao_builder.deinit();

    // Binding 0: Storage Image (Write)
    ssao_builder.add_binding(0, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, c.VK_SHADER_STAGE_COMPUTE_BIT) catch return false;
    // Binding 1: Depth (Sampler)
    ssao_builder.add_binding(1, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_COMPUTE_BIT) catch return false;
    // Binding 2: Noise (Sampler)
    ssao_builder.add_binding(2, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_COMPUTE_BIT) catch return false;
    // Binding 3: Kernel (UBO)
    ssao_builder.add_binding(3, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, c.VK_SHADER_STAGE_COMPUTE_BIT) catch return false;

    if (!ssao_builder.build(s.pipelines.ssao_pipeline.descriptorManager.?, s.context.device, @as(*types.VulkanAllocator, @ptrCast(&s.allocator)), s, types.MAX_FRAMES_IN_FLIGHT, true)) {
        return false;
    }

    // Allocate SSAO Sets
    if (!vk_descriptor_manager.vk_descriptor_manager_allocate_sets(s.pipelines.ssao_pipeline.descriptorManager, types.MAX_FRAMES_IN_FLIGHT, @as([*]c.VkDescriptorSet, @ptrCast(&s.pipelines.ssao_pipeline.descriptor_sets)))) {
        return false;
    }

    // --- Blur Manager ---
    const blur_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (blur_ptr == null) return false;
    s.pipelines.ssao_pipeline.blurDescriptorManager = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(blur_ptr)));

    var blur_builder = vk_descriptor_manager.DescriptorBuilder.init(std.heap.page_allocator);
    defer blur_builder.deinit();

    // Binding 0: Storage Image (Write)
    blur_builder.add_binding(0, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, c.VK_SHADER_STAGE_COMPUTE_BIT) catch return false;
    // Binding 1: SSAO Input (Sampler)
    blur_builder.add_binding(1, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, c.VK_SHADER_STAGE_COMPUTE_BIT) catch return false;

    if (!blur_builder.build(s.pipelines.ssao_pipeline.blurDescriptorManager.?, s.context.device, @as(*types.VulkanAllocator, @ptrCast(&s.allocator)), s, types.MAX_FRAMES_IN_FLIGHT, true)) {
        return false;
    }

    // Allocate Blur Sets
    if (!vk_descriptor_manager.vk_descriptor_manager_allocate_sets(s.pipelines.ssao_pipeline.blurDescriptorManager, types.MAX_FRAMES_IN_FLIGHT, @as([*]c.VkDescriptorSet, @ptrCast(&s.pipelines.ssao_pipeline.blur_descriptor_sets)))) {
        return false;
    }

    return true;
}

fn create_pipelines(s: *types.VulkanState) bool {
    const shaders_dir = std.mem.span(@as([*:0]const u8, @ptrCast(&s.config.shader_dir)));
    const renderer_allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();

    // SSAO Pipeline
    {
        var config = std.mem.zeroes(types.ComputePipelineConfig);
        const path_slice = std.fmt.allocPrint(renderer_allocator, "{s}/ssao.comp.spv\x00", .{shaders_dir}) catch return false;
        const path = path_slice[0 .. path_slice.len - 1 :0];
        defer renderer_allocator.free(path_slice);

        config.compute_shader_path = path;
        config.local_size_x = 16;
        config.local_size_y = 16;
        config.local_size_z = 1;

        // Use Descriptor Manager Layout
        var layouts = [_]c.VkDescriptorSetLayout{vk_descriptor_manager.vk_descriptor_manager_get_layout(s.pipelines.ssao_pipeline.descriptorManager)};
        config.descriptor_set_count = 1;
        config.descriptor_layouts = &layouts;

        if (!vk_compute.vk_compute_create_pipeline(s, &config, &s.pipelines.ssao_pipeline.pipeline)) {
            return false;
        }
    }

    // Blur Pipeline
    {
        var config = std.mem.zeroes(types.ComputePipelineConfig);
        const path_slice = std.fmt.allocPrint(renderer_allocator, "{s}/ssao_blur.comp.spv\x00", .{shaders_dir}) catch return false;
        const path = path_slice[0 .. path_slice.len - 1 :0];
        defer renderer_allocator.free(path_slice);

        config.compute_shader_path = path;
        config.local_size_x = 16;
        config.local_size_y = 16;
        config.local_size_z = 1;

        // Use Descriptor Manager Layout
        var layouts = [_]c.VkDescriptorSetLayout{vk_descriptor_manager.vk_descriptor_manager_get_layout(s.pipelines.ssao_pipeline.blurDescriptorManager)};
        config.descriptor_set_count = 1;
        config.descriptor_layouts = &layouts;

        if (!vk_compute.vk_compute_create_pipeline(s, &config, &s.pipelines.ssao_pipeline.blur_pipeline)) {
            return false;
        }
    }

    return true;
}

fn update_descriptors(s: *types.VulkanState) bool {
    const ssao = &s.pipelines.ssao_pipeline;

    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        // 1. SSAO Descriptors
        const set = ssao.descriptor_sets[i];

        // Binding 0: Image Write (SSAO Image)
        if (!vk_descriptor_manager.vk_descriptor_manager_update_image(ssao.descriptorManager, set, 0, ssao.ssao_view[i], null, c.VK_IMAGE_LAYOUT_GENERAL)) return false;

        // Binding 1: Depth Map (Sampler)
        if (!vk_descriptor_manager.vk_descriptor_manager_update_image(ssao.descriptorManager, set, 1, s.swapchain.depth_image_view, s.pipelines.post_process_pipeline.sampler, c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL)) return false;

        // Binding 2: Noise Map
        if (!vk_descriptor_manager.vk_descriptor_manager_update_image(ssao.descriptorManager, set, 2, ssao.noise_texture.view, ssao.noise_texture.sampler, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) return false;

        // Binding 3: Kernel UBO
        if (!vk_descriptor_manager.vk_descriptor_manager_update_buffer(ssao.descriptorManager, set, 3, ssao.kernel_buffer, 0, @sizeOf(SSAOKernel))) return false;

        // 2. Blur Descriptors
        const blur_set = ssao.blur_descriptor_sets[i];

        // Binding 0: Image Write (Blur Output)
        if (!vk_descriptor_manager.vk_descriptor_manager_update_image(ssao.blurDescriptorManager, blur_set, 0, ssao.ssao_blur_view[i], null, c.VK_IMAGE_LAYOUT_GENERAL)) return false;

        // Binding 1: SSAO Input
        if (!vk_descriptor_manager.vk_descriptor_manager_update_image(ssao.blurDescriptorManager, blur_set, 1, ssao.ssao_view[i], s.pipelines.post_process_pipeline.sampler, c.VK_IMAGE_LAYOUT_GENERAL)) return false;
    }

    return true;
}
