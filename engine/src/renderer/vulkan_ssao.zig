const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const math = @import("../core/math.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_types.zig");
const vk_compute = @import("vulkan_compute.zig");
const vk_texture_utils = @import("util/vulkan_texture_utils.zig");
const vk_buffer_utils = @import("util/vulkan_buffer_utils.zig");
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
        return false;
    }

    // 2. Create Noise Texture & Kernel
    if (!create_noise_and_kernel(s)) {
        ssao_log.err("Failed to create SSAO noise/kernel", .{});
        return false;
    }

    // 3. Create Pipelines
    if (!create_pipelines(s)) {
        ssao_log.err("Failed to create SSAO pipelines", .{});
        return false;
    }

    // 4. Update Descriptors
    if (!update_descriptors(s)) {
        ssao_log.err("Failed to update SSAO descriptors", .{});
        return false;
    }

    s.pipelines.use_ssao = true;
    s.pipelines.ssao_pipeline.initialized = true;
    ssao_log.info("SSAO initialized successfully", .{});
    return true;
}

pub fn vk_ssao_destroy(s: *types.VulkanState) void {
    if (!s.pipelines.ssao_pipeline.initialized) return;

    const device = s.context.device;
    const allocator = &s.allocator;

    // Destroy Resources
    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        if (s.pipelines.ssao_pipeline.ssao_view[i] != null) c.vkDestroyImageView(device, s.pipelines.ssao_pipeline.ssao_view[i], null);
        if (s.pipelines.ssao_pipeline.ssao_image[i] != null) vk_allocator.free_image(allocator, s.pipelines.ssao_pipeline.ssao_image[i], s.pipelines.ssao_pipeline.ssao_allocation[i]);

        if (s.pipelines.ssao_pipeline.ssao_blur_view[i] != null) c.vkDestroyImageView(device, s.pipelines.ssao_pipeline.ssao_blur_view[i], null);
        if (s.pipelines.ssao_pipeline.ssao_blur_image[i] != null) vk_allocator.free_image(allocator, s.pipelines.ssao_pipeline.ssao_blur_image[i], s.pipelines.ssao_pipeline.ssao_blur_allocation[i]);
    }

    // Destroy Noise & Kernel
    if (s.pipelines.ssao_pipeline.noise_texture.view != null) c.vkDestroyImageView(device, s.pipelines.ssao_pipeline.noise_texture.view, null);
    if (s.pipelines.ssao_pipeline.noise_texture.sampler != null) c.vkDestroySampler(device, s.pipelines.ssao_pipeline.noise_texture.sampler, null);
    vk_allocator.free_image(allocator, s.pipelines.ssao_pipeline.noise_texture.image, s.pipelines.ssao_pipeline.noise_texture.allocation);
    vk_allocator.free_buffer(allocator, s.pipelines.ssao_pipeline.kernel_buffer, s.pipelines.ssao_pipeline.kernel_allocation);

    // Destroy Pipelines
    vk_compute.vk_compute_destroy_pipeline(s, &s.pipelines.ssao_pipeline.pipeline);
    vk_compute.vk_compute_destroy_pipeline(s, &s.pipelines.ssao_pipeline.blur_pipeline);

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
    c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, ssao.pipeline.pipeline_layout, 0, 1, &ssao.descriptor_sets[frame_index], 0, null);

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
    c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, ssao.blur_pipeline.pipeline_layout, 0, 1, &ssao.blur_descriptor_sets[frame_index], 0, null);

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
    if (!vk_buffer_utils.create_buffer(&s.allocator, @sizeOf(SSAOKernel), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &s.pipelines.ssao_pipeline.kernel_buffer, &s.pipelines.ssao_pipeline.kernel_memory, &s.pipelines.ssao_pipeline.kernel_allocation)) return false;

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
    var staging_buffer: c.VkBuffer = null;
    var staging_memory: c.VkDeviceMemory = null;
    var staging_alloc: c.VmaAllocation = null;

    if (!vk_buffer_utils.create_buffer(&s.allocator, noise_size, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &staging_buffer, &staging_memory, &staging_alloc)) return false;

    if (vk_allocator.map_memory(&s.allocator, staging_alloc, &data) == c.VK_SUCCESS) {
        @memcpy(@as([*]u8, @ptrCast(data))[0..noise_size], @as([*]u8, @ptrCast(&noise_data))[0..noise_size]);
        vk_allocator.unmap_memory(&s.allocator, staging_alloc);
    }

    // Create Image
    if (!vk_texture_utils.create_image_and_memory(&s.allocator, s.context.device, 4, 4, c.VK_FORMAT_R32G32B32A32_SFLOAT, &s.pipelines.ssao_pipeline.noise_texture.image, &s.pipelines.ssao_pipeline.noise_texture.memory, &s.pipelines.ssao_pipeline.noise_texture.allocation)) return false;

    if (!vk_texture_utils.create_texture_image_view(s.context.device, s.pipelines.ssao_pipeline.noise_texture.image, &s.pipelines.ssao_pipeline.noise_texture.view, c.VK_FORMAT_R32G32B32A32_SFLOAT)) return false;

    // Transition and Copy
    vk_texture_utils.transition_image_layout(s.context.device, s.context.graphics_queue, s.commands.pools.?[0], s.pipelines.ssao_pipeline.noise_texture.image, c.VK_FORMAT_R32G32B32A32_SFLOAT, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    vk_texture_utils.copy_buffer_to_image(s.context.device, s.context.graphics_queue, s.commands.pools.?[0], staging_buffer, s.pipelines.ssao_pipeline.noise_texture.image, 4, 4);
    vk_texture_utils.transition_image_layout(s.context.device, s.context.graphics_queue, s.commands.pools.?[0], s.pipelines.ssao_pipeline.noise_texture.image, c.VK_FORMAT_R32G32B32A32_SFLOAT, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

    // Cleanup Staging
    vk_allocator.free_buffer(&s.allocator, staging_buffer, staging_alloc);

    // Create Sampler (Repeat, Nearest)
    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_info.magFilter = c.VK_FILTER_NEAREST;
    sampler_info.minFilter = c.VK_FILTER_NEAREST;
    sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;

    if (c.vkCreateSampler(s.context.device, &sampler_info, null, &s.pipelines.ssao_pipeline.noise_texture.sampler) != c.VK_SUCCESS) {
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

        if (!vk_compute.vk_compute_create_pipeline(s, &config, &s.pipelines.ssao_pipeline.blur_pipeline)) {
            return false;
        }
    }

    return true;
}

fn update_descriptors(s: *types.VulkanState) bool {
    const ssao = &s.pipelines.ssao_pipeline;
    const device = s.context.device;

    var i: u32 = 0;
    while (i < types.MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        // 1. SSAO Descriptors

        // Allocate SSAO Set
        if (ssao.descriptor_sets[i] == null) {
            var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            alloc_info.descriptorPool = s.pipelines.compute_descriptor_pool;
            alloc_info.descriptorSetCount = 1;
            alloc_info.pSetLayouts = &ssao.pipeline.descriptor_layouts.?[0]; // Set 0

            if (c.vkAllocateDescriptorSets(device, &alloc_info, &ssao.descriptor_sets[i]) != c.VK_SUCCESS) {
                ssao_log.err("Failed to allocate SSAO descriptor set for frame {d}", .{i});
                return false;
            }
        }

        // Update SSAO Set
        // Binding 0: Image Write (SSAO Image)
        var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        image_info.imageLayout = c.VK_IMAGE_LAYOUT_GENERAL;
        image_info.imageView = ssao.ssao_view[i]; // Use per-frame view

        var write0 = std.mem.zeroes(c.VkWriteDescriptorSet);
        write0.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write0.dstSet = ssao.descriptor_sets[i];
        write0.dstBinding = 0;
        write0.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
        write0.descriptorCount = 1;
        write0.pImageInfo = &image_info;

        // Binding 1: Depth Map (Sampler)
        var depth_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        depth_info.imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
        depth_info.imageView = s.swapchain.depth_image_view;
        depth_info.sampler = s.pipelines.post_process_pipeline.sampler; // Linear clamp

        var write1 = std.mem.zeroes(c.VkWriteDescriptorSet);
        write1.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write1.dstSet = ssao.descriptor_sets[i];
        write1.dstBinding = 1;
        write1.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write1.descriptorCount = 1;
        write1.pImageInfo = &depth_info;

        // Binding 2: Noise Map
        var noise_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        noise_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        noise_info.imageView = ssao.noise_texture.view;
        noise_info.sampler = ssao.noise_texture.sampler;

        var write2 = std.mem.zeroes(c.VkWriteDescriptorSet);
        write2.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write2.dstSet = ssao.descriptor_sets[i];
        write2.dstBinding = 2;
        write2.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write2.descriptorCount = 1;
        write2.pImageInfo = &noise_info;

        // Binding 3: Kernel UBO
        var buffer_info = std.mem.zeroes(c.VkDescriptorBufferInfo);
        buffer_info.buffer = ssao.kernel_buffer;
        buffer_info.offset = 0;
        buffer_info.range = @sizeOf(SSAOKernel);

        var write3 = std.mem.zeroes(c.VkWriteDescriptorSet);
        write3.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write3.dstSet = ssao.descriptor_sets[i];
        write3.dstBinding = 3;
        write3.descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        write3.descriptorCount = 1;
        write3.pBufferInfo = &buffer_info;

        const writes = [_]c.VkWriteDescriptorSet{ write0, write1, write2, write3 };
        c.vkUpdateDescriptorSets(device, 4, &writes, 0, null);

        // 2. Blur Descriptors
        if (ssao.blur_descriptor_sets[i] == null) {
            var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            alloc_info.descriptorPool = s.pipelines.compute_descriptor_pool;
            alloc_info.descriptorSetCount = 1;
            alloc_info.pSetLayouts = &ssao.blur_pipeline.descriptor_layouts.?[0];

            if (c.vkAllocateDescriptorSets(device, &alloc_info, &ssao.blur_descriptor_sets[i]) != c.VK_SUCCESS) {
                ssao_log.err("Failed to allocate Blur descriptor set for frame {d}", .{i});
                return false;
            }
        }

        // Binding 0: Image Write (Blur Output)
        var blur_out_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        blur_out_info.imageLayout = c.VK_IMAGE_LAYOUT_GENERAL;
        blur_out_info.imageView = ssao.ssao_blur_view[i]; // Use per-frame view

        var b_write0 = std.mem.zeroes(c.VkWriteDescriptorSet);
        b_write0.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        b_write0.dstSet = ssao.blur_descriptor_sets[i];
        b_write0.dstBinding = 0;
        b_write0.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
        b_write0.descriptorCount = 1;
        b_write0.pImageInfo = &blur_out_info;

        // Binding 1: SSAO Input
        var ssao_in_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        ssao_in_info.imageLayout = c.VK_IMAGE_LAYOUT_GENERAL;
        ssao_in_info.imageView = ssao.ssao_view[i]; // Use per-frame view
        ssao_in_info.sampler = s.pipelines.post_process_pipeline.sampler; // Linear sampler

        var b_write1 = std.mem.zeroes(c.VkWriteDescriptorSet);
        b_write1.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        b_write1.dstSet = ssao.blur_descriptor_sets[i];
        b_write1.dstBinding = 1;
        b_write1.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        b_write1.descriptorCount = 1;
        b_write1.pImageInfo = &ssao_in_info;

        const b_writes = [_]c.VkWriteDescriptorSet{ b_write0, b_write1 };
        c.vkUpdateDescriptorSets(device, 2, &b_writes, 0, null);
    }

    return true;
}
