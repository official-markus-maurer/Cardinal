#include <cardinal/core/log.h>
#include <cardinal/renderer/util/vulkan_descriptor_utils.h>
#include <stdlib.h>

bool vk_descriptor_create_pbr_layout(VkDevice device, VkDescriptorSetLayout* descriptorSetLayout) {
    if (!device || !descriptorSetLayout) {
        CARDINAL_LOG_ERROR("Invalid parameters for descriptor set layout creation");
        return false;
    }

    // Descriptor set layout bindings
    VkDescriptorSetLayoutBinding bindings[] = {
        // Binding 0: Camera UBO (Vertex + Fragment)
        {
         .binding = 0,
         .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
         .pImmutableSamplers = NULL,
         },
        // Binding 1: Albedo Map (Fragment)
        {
         .binding = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
         .pImmutableSamplers = NULL,
         },
        // Binding 2: Normal Map (Fragment)
        {
         .binding = 2,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
         .pImmutableSamplers = NULL,
         },
        // Binding 3: Metallic-Roughness Map (Fragment)
        {
         .binding = 3,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
         .pImmutableSamplers = NULL,
         },
        // Binding 4: AO Map (Fragment)
        {
         .binding = 4,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
         .pImmutableSamplers = NULL,
         },
        // Binding 5: Emissive Map (Fragment)
        {
         .binding = 5,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
         .pImmutableSamplers = NULL,
         },
        // Binding 6: Bone Matrices (Vertex)
        {
         .binding = 6,
         .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
         .pImmutableSamplers = NULL,
         },
        // Binding 8: Lighting Data (Fragment)
        {
         .binding = 8,
         .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
         .pImmutableSamplers = NULL,
         },
        // Binding 9: Texture Array (Fragment)
        {
         .binding = 9,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 5000, // Increased for bindless
 .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
         .pImmutableSamplers = NULL,
         }
    };

    // Enable descriptor indexing for the last binding (Binding 9)
    VkDescriptorBindingFlags bindingFlags[] = {
        0, // 0: UBO
        0, // 1: Albedo
        0, // 2: Normal
        0, // 3: MR
        0, // 4: AO
        0, // 5: Emissive
        0, // 6: Bones
        0, // 8: Lighting (Note: We skipped 7, so we need to be careful with array indexing if
           // pBindings is compact)
        VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT |
            VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT // 9: Array
    };

    // Note: pBindings array above has 9 elements, but bindings are sparse (missing 7).
    // The bindingFlags array must correspond to pBindings array elements 1:1.
    // So the above bindingFlags array is correct (9 elements).

    VkDescriptorSetLayoutBindingFlagsCreateInfo bindingFlagsInfo = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
        .bindingCount = sizeof(bindingFlags) / sizeof(bindingFlags[0]),
        .pBindingFlags = bindingFlags,
    };

    VkDescriptorSetLayoutCreateInfo layoutInfo = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = &bindingFlagsInfo,
        .bindingCount = sizeof(bindings) / sizeof(bindings[0]),
        .pBindings = bindings,
    };

    VkResult result = vkCreateDescriptorSetLayout(device, &layoutInfo, NULL, descriptorSetLayout);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor set layout: %d", result);
        return false;
    }

    return true;
}

bool vk_descriptor_create_pool(VkDevice device, uint32_t maxSets, uint32_t maxTextures,
                               VkDescriptorPool* descriptorPool) {
    if (!device || !descriptorPool) {
        CARDINAL_LOG_ERROR("Invalid parameters for descriptor pool creation");
        return false;
    }

    VkDescriptorPoolSize poolSizes[] = {
        {
         .type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
         .descriptorCount = maxSets * 2,// UBO + Lighting UBO
        },
        {
         .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = maxSets * (6 + maxTextures), // Fixed textures + variable array
        }
    };

    VkDescriptorPoolCreateInfo poolInfo = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT,
        .poolSizeCount = sizeof(poolSizes) / sizeof(poolSizes[0]),
        .pPoolSizes = poolSizes,
        .maxSets = maxSets,
    };

    VkResult result = vkCreateDescriptorPool(device, &poolInfo, NULL, descriptorPool);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor pool: %d", result);
        return false;
    }

    return true;
}

bool vk_descriptor_allocate_sets(VkDevice device, VkDescriptorPool descriptorPool,
                                 VkDescriptorSetLayout descriptorSetLayout, uint32_t setCount,
                                 uint32_t variableDescriptorCount,
                                 VkDescriptorSet* descriptorSets) {
    if (!device || !descriptorPool || !descriptorSetLayout || !descriptorSets) {
        CARDINAL_LOG_ERROR("Invalid parameters for descriptor set allocation");
        return false;
    }

    VkDescriptorSetLayout* layouts = malloc(setCount * sizeof(VkDescriptorSetLayout));
    if (!layouts) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for descriptor set layouts");
        return false;
    }

    for (uint32_t i = 0; i < setCount; i++) {
        layouts[i] = descriptorSetLayout;
    }

    uint32_t* variableCounts = malloc(setCount * sizeof(uint32_t));
    if (!variableCounts) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for variable descriptor counts");
        free(layouts);
        return false;
    }

    for (uint32_t i = 0; i < setCount; i++) {
        variableCounts[i] = variableDescriptorCount;
    }

    VkDescriptorSetVariableDescriptorCountAllocateInfo variableCountInfo = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
        .descriptorSetCount = setCount,
        .pDescriptorCounts = variableCounts,
    };

    VkDescriptorSetAllocateInfo allocInfo = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = &variableCountInfo,
        .descriptorPool = descriptorPool,
        .descriptorSetCount = setCount,
        .pSetLayouts = layouts,
    };

    VkResult result = vkAllocateDescriptorSets(device, &allocInfo, descriptorSets);

    free(layouts);
    free(variableCounts);

    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate descriptor sets: %d", result);
        return false;
    }

    return true;
}

void vk_descriptor_update_sets(VkDevice device, VkDescriptorSet descriptorSet,
                               VkBuffer uniformBuffer, VkDeviceSize uniformBufferSize,
                               VkBuffer lightingBuffer, VkDeviceSize lightingBufferSize,
                               VkImageView* imageViews, VkSampler sampler, uint32_t imageCount) {
    if (!device || !descriptorSet) {
        CARDINAL_LOG_ERROR("Invalid parameters for descriptor set update");
        return;
    }

    VkWriteDescriptorSet* writes = malloc((2 + imageCount) * sizeof(VkWriteDescriptorSet));
    VkDescriptorBufferInfo* bufferInfos = malloc(2 * sizeof(VkDescriptorBufferInfo));
    VkDescriptorImageInfo* imageInfos = malloc(imageCount * sizeof(VkDescriptorImageInfo));

    if (!writes || !bufferInfos || !imageInfos) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for descriptor updates");
        free(writes);
        free(bufferInfos);
        free(imageInfos);
        return;
    }

    uint32_t writeCount = 0;

    // UBO
    if (uniformBuffer != VK_NULL_HANDLE) {
        bufferInfos[0] = (VkDescriptorBufferInfo){
            .buffer = uniformBuffer,
            .offset = 0,
            .range = uniformBufferSize,
        };

        writes[writeCount++] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &bufferInfos[0],
        };
    }

    // Lighting UBO
    if (lightingBuffer != VK_NULL_HANDLE) {
        bufferInfos[1] = (VkDescriptorBufferInfo){
            .buffer = lightingBuffer,
            .offset = 0,
            .range = lightingBufferSize,
        };

        writes[writeCount++] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &bufferInfos[1],
        };
    }

    // Images
    if (imageViews && imageCount > 0) {
        for (uint32_t i = 0; i < imageCount; i++) {
            imageInfos[i] = (VkDescriptorImageInfo){
                .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .imageView = imageViews[i],
                .sampler = sampler,
            };
        }

        writes[writeCount++] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet,
            .dstBinding = 7, // Variable descriptor array binding
            .dstArrayElement = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = imageCount,
            .pImageInfo = imageInfos,
        };
    }

    vkUpdateDescriptorSets(device, writeCount, writes, 0, NULL);

    free(writes);
    free(bufferInfos);
    free(imageInfos);
}

void vk_descriptor_destroy_pool(VkDevice device, VkDescriptorPool descriptorPool) {
    if (device && descriptorPool != VK_NULL_HANDLE) {
        // Reset the descriptor pool to free all allocated descriptor sets
        vkResetDescriptorPool(device, descriptorPool, 0);
        vkDestroyDescriptorPool(device, descriptorPool, NULL);
    }
}

void vk_descriptor_destroy_layout(VkDevice device, VkDescriptorSetLayout descriptorSetLayout) {
    if (device && descriptorSetLayout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(device, descriptorSetLayout, NULL);
    }
}
