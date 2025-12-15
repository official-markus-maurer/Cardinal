const std = @import("std");
const builtin = @import("builtin");
const log = @import("../../core/log.zig");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("cardinal/renderer/util/vulkan_descriptor_utils.h");
});

pub export fn vk_descriptor_create_pbr_layout(device: c.VkDevice, descriptorSetLayout: ?*c.VkDescriptorSetLayout) callconv(.c) bool {
    if (device == null or descriptorSetLayout == null) {
        log.cardinal_log_error("Invalid parameters for descriptor set layout creation", .{});
        return false;
    }

    // Descriptor set layout bindings
    const bindings = [_]c.VkDescriptorSetLayoutBinding{
        // Binding 0: Camera UBO (Vertex + Fragment)
        .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 1: Albedo Map (Fragment)
        .{
            .binding = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 2: Normal Map (Fragment)
        .{
            .binding = 2,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 3: Metallic-Roughness Map (Fragment)
        .{
            .binding = 3,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 4: AO Map (Fragment)
        .{
            .binding = 4,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 5: Emissive Map (Fragment)
        .{
            .binding = 5,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 6: Bone Matrices (Vertex)
        .{
            .binding = 6,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 8: Lighting Data (Fragment)
        .{
            .binding = 8,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        // Binding 9: Texture Array (Fragment)
        .{
            .binding = 9,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 5000, // Increased for bindless
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
    };

    // Enable descriptor indexing for the last binding (Binding 9)
    const bindingFlags = [_]c.VkDescriptorBindingFlags{
        0, // 0: UBO
        0, // 1: Albedo
        0, // 2: Normal
        0, // 3: MR
        0, // 4: AO
        0, // 5: Emissive
        0, // 6: Bones
        0, // 8: Lighting
        c.VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT | c.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT, // 9: Array
    };

    var bindingFlagsInfo = std.mem.zeroes(c.VkDescriptorSetLayoutBindingFlagsCreateInfo);
    bindingFlagsInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
    bindingFlagsInfo.bindingCount = bindingFlags.len;
    bindingFlagsInfo.pBindingFlags = &bindingFlags;

    var layoutInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layoutInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.pNext = &bindingFlagsInfo;
    layoutInfo.bindingCount = bindings.len;
    layoutInfo.pBindings = &bindings;

    const result = c.vkCreateDescriptorSetLayout(device, &layoutInfo, null, descriptorSetLayout.?);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create descriptor set layout: {d}", .{result});
        return false;
    }

    return true;
}

pub export fn vk_descriptor_create_pool(device: c.VkDevice, maxSets: u32, maxTextures: u32,
                               descriptorPool: ?*c.VkDescriptorPool) callconv(.c) bool {
    if (device == null or descriptorPool == null) {
        log.cardinal_log_error("Invalid parameters for descriptor pool creation", .{});
        return false;
    }

    const poolSizes = [_]c.VkDescriptorPoolSize{
        .{
            .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = maxSets * 2, // UBO + Lighting UBO
        },
        .{
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = maxSets * (6 + maxTextures), // Fixed textures + variable array
        },
    };

    var poolInfo = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    poolInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.flags = c.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT;
    poolInfo.poolSizeCount = poolSizes.len;
    poolInfo.pPoolSizes = &poolSizes;
    poolInfo.maxSets = maxSets;

    const result = c.vkCreateDescriptorPool(device, &poolInfo, null, descriptorPool.?);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to create descriptor pool: {d}", .{result});
        return false;
    }

    return true;
}

pub export fn vk_descriptor_allocate_sets(device: c.VkDevice, descriptorPool: c.VkDescriptorPool,
                                 descriptorSetLayout: c.VkDescriptorSetLayout, setCount: u32,
                                 variableDescriptorCount: u32,
                                 descriptorSets: ?*c.VkDescriptorSet) callconv(.c) bool {
    if (device == null or descriptorPool == null or descriptorSetLayout == null or descriptorSets == null) {
        log.cardinal_log_error("Invalid parameters for descriptor set allocation", .{});
        return false;
    }

    const layouts = c.malloc(setCount * @sizeOf(c.VkDescriptorSetLayout));
    if (layouts == null) {
        log.cardinal_log_error("Failed to allocate memory for descriptor set layouts", .{});
        return false;
    }
    defer c.free(layouts);

    const layoutsPtr = @as([*]c.VkDescriptorSetLayout, @ptrCast(@alignCast(layouts)));
    var i: u32 = 0;
    while (i < setCount) : (i += 1) {
        layoutsPtr[i] = descriptorSetLayout;
    }

    const variableCounts = c.malloc(setCount * @sizeOf(u32));
    if (variableCounts == null) {
        log.cardinal_log_error("Failed to allocate memory for variable descriptor counts", .{});
        return false;
    }
    defer c.free(variableCounts);

    const variableCountsPtr = @as([*]u32, @ptrCast(@alignCast(variableCounts)));
    i = 0;
    while (i < setCount) : (i += 1) {
        variableCountsPtr[i] = variableDescriptorCount;
    }

    var variableCountInfo = std.mem.zeroes(c.VkDescriptorSetVariableDescriptorCountAllocateInfo);
    variableCountInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO;
    variableCountInfo.descriptorSetCount = setCount;
    variableCountInfo.pDescriptorCounts = variableCountsPtr;

    var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.pNext = &variableCountInfo;
    allocInfo.descriptorPool = descriptorPool;
    allocInfo.descriptorSetCount = setCount;
    allocInfo.pSetLayouts = layoutsPtr;

    const result = c.vkAllocateDescriptorSets(device, &allocInfo, descriptorSets.?);

    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to allocate descriptor sets: {d}", .{result});
        return false;
    }

    return true;
}

pub export fn vk_descriptor_update_sets(device: c.VkDevice, descriptorSet: c.VkDescriptorSet,
                               uniformBuffer: c.VkBuffer, uniformBufferSize: c.VkDeviceSize,
                               lightingBuffer: c.VkBuffer, lightingBufferSize: c.VkDeviceSize,
                               imageViews: ?[*]c.VkImageView, sampler: c.VkSampler, imageCount: u32) callconv(.c) void {
    if (device == null or descriptorSet == null) {
        log.cardinal_log_error("Invalid parameters for descriptor set update", .{});
        return;
    }

    const writesPtr = c.malloc((2 + imageCount) * @sizeOf(c.VkWriteDescriptorSet));
    const bufferInfosPtr = c.malloc(2 * @sizeOf(c.VkDescriptorBufferInfo));
    const imageInfosPtr = c.malloc(imageCount * @sizeOf(c.VkDescriptorImageInfo));

    if (writesPtr == null or bufferInfosPtr == null or imageInfosPtr == null) {
        log.cardinal_log_error("Failed to allocate memory for descriptor updates", .{});
        if (writesPtr != null) c.free(writesPtr);
        if (bufferInfosPtr != null) c.free(bufferInfosPtr);
        if (imageInfosPtr != null) c.free(imageInfosPtr);
        return;
    }
    defer c.free(writesPtr);
    defer c.free(bufferInfosPtr);
    defer c.free(imageInfosPtr);

    const writes = @as([*]c.VkWriteDescriptorSet, @ptrCast(@alignCast(writesPtr)));
    const bufferInfos = @as([*]c.VkDescriptorBufferInfo, @ptrCast(@alignCast(bufferInfosPtr)));
    const imageInfos = @as([*]c.VkDescriptorImageInfo, @ptrCast(@alignCast(imageInfosPtr)));

    var writeCount: u32 = 0;

    // UBO
    if (uniformBuffer != null) {
        bufferInfos[0] = .{
            .buffer = uniformBuffer,
            .offset = 0,
            .range = uniformBufferSize,
        };

        writes[writeCount] = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &bufferInfos[0],
            .pNext = null,
            .pTexelBufferView = null,
            .pImageInfo = null,
        };
        writeCount += 1;
    }

    // Lighting UBO
    if (lightingBuffer != null) {
        bufferInfos[1] = .{
            .buffer = lightingBuffer,
            .offset = 0,
            .range = lightingBufferSize,
        };

        writes[writeCount] = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &bufferInfos[1],
            .pNext = null,
            .pTexelBufferView = null,
            .pImageInfo = null,
        };
        writeCount += 1;
    }

    // Images
    if (imageViews != null and imageCount > 0) {
        var i: u32 = 0;
        while (i < imageCount) : (i += 1) {
            imageInfos[i] = .{
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .imageView = imageViews.?[i],
                .sampler = sampler,
            };
        }

        writes[writeCount] = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet,
            .dstBinding = 7, // Variable descriptor array binding
            .dstArrayElement = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = imageCount,
            .pImageInfo = imageInfos,
            .pNext = null,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        writeCount += 1;
    }

    c.vkUpdateDescriptorSets(device, writeCount, writes, 0, null);
}

pub export fn vk_descriptor_destroy_pool(device: c.VkDevice, descriptorPool: c.VkDescriptorPool) callconv(.c) void {
    if (device != null and descriptorPool != null) {
        // Reset the descriptor pool to free all allocated descriptor sets
        _ = c.vkResetDescriptorPool(device, descriptorPool, 0);
        c.vkDestroyDescriptorPool(device, descriptorPool, null);
    }
}

pub export fn vk_descriptor_destroy_layout(device: c.VkDevice, descriptorSetLayout: c.VkDescriptorSetLayout) callconv(.c) void {
    if (device != null and descriptorSetLayout != null) {
        c.vkDestroyDescriptorSetLayout(device, descriptorSetLayout, null);
    }
}
