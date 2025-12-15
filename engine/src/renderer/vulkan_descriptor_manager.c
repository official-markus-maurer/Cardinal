#include "vulkan_descriptor_manager.h"
#include "cardinal/core/log.h"
#include "vulkan_state.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#ifdef _MSC_VER
    #include <malloc.h>
    #define alloca _alloca
#endif

static VkDescriptorType get_binding_descriptor_type(const VulkanDescriptorManager* manager,
                                                    uint32_t binding) {
    if (!manager || !manager->bindings || manager->bindingCount == 0) {
        return VK_DESCRIPTOR_TYPE_MAX_ENUM;
    }
    for (uint32_t i = 0; i < manager->bindingCount; ++i) {
        if (manager->bindings[i].binding == binding) {
            return manager->bindings[i].descriptorType;
        }
    }
    return VK_DESCRIPTOR_TYPE_MAX_ENUM;
}

static VkDeviceSize get_descriptor_size_for_type(const VulkanState* state, VkDescriptorType type) {
    if (!state)
        return 0;
    switch (type) {
        case VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER:
            return state->context.descriptor_buffer_uniform_buffer_size;
        case VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER:
            return state->context.descriptor_buffer_combined_image_sampler_size;
        default:
            return 0;
    }
}

/**
 * @brief Helper function to create descriptor pool.
 */
static bool create_descriptor_pool(VulkanDescriptorManager* manager, uint32_t maxSets,
                                   VkDescriptorPoolCreateFlags flags) {
    // Count descriptor types
    VkDescriptorPoolSize poolSizes[16] = {0}; // Support up to 16 different types
    uint32_t poolSizeCount = 0;

    for (uint32_t i = 0; i < manager->bindingCount; i++) {
        VkDescriptorType type = manager->bindings[i].descriptorType;

        // Find existing pool size or create new one
        bool found = false;
        for (uint32_t j = 0; j < poolSizeCount; j++) {
            if (poolSizes[j].type == type) {
                poolSizes[j].descriptorCount += manager->bindings[i].descriptorCount * maxSets;
                found = true;
                break;
            }
        }

        if (!found && poolSizeCount < 16) {
            poolSizes[poolSizeCount].type = type;
            poolSizes[poolSizeCount].descriptorCount =
                manager->bindings[i].descriptorCount * maxSets;
            poolSizeCount++;
        }
    }

    if (poolSizeCount == 0) {
        CARDINAL_LOG_ERROR("No descriptor types found for pool creation");
        return false;
    }

    VkDescriptorPoolCreateInfo poolInfo = {0};
    poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.flags = flags;
    poolInfo.maxSets = maxSets;
    poolInfo.poolSizeCount = poolSizeCount;
    poolInfo.pPoolSizes = poolSizes;

    if (vkCreateDescriptorPool(manager->device, &poolInfo, NULL, &manager->descriptorPool) !=
        VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor pool");
        return false;
    }

    CARDINAL_LOG_DEBUG("Created descriptor pool with %u sets and %u pool sizes", maxSets,
                       poolSizeCount);
    return true;
}

/**
 * @brief Helper function to create descriptor set layout.
 */
static bool create_descriptor_set_layout(VulkanDescriptorManager* manager) {
    VkDescriptorSetLayoutBinding* layoutBindings =
        malloc(manager->bindingCount * sizeof(VkDescriptorSetLayoutBinding));
    if (!layoutBindings) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for layout bindings");
        return false;
    }

    for (uint32_t i = 0; i < manager->bindingCount; i++) {
        layoutBindings[i].binding = manager->bindings[i].binding;
        layoutBindings[i].descriptorType = manager->bindings[i].descriptorType;
        layoutBindings[i].descriptorCount = manager->bindings[i].descriptorCount;
        layoutBindings[i].stageFlags = manager->bindings[i].stageFlags;
        layoutBindings[i].pImmutableSamplers = manager->bindings[i].pImmutableSamplers;
    }

    VkDescriptorSetLayoutCreateInfo layoutInfo = {0};
    layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = manager->bindingCount;
    layoutInfo.pBindings = layoutBindings;

    // Add descriptor indexing flags for variable-count image sampler arrays
    VkDescriptorBindingFlags* bindingFlags =
        (VkDescriptorBindingFlags*)calloc(manager->bindingCount, sizeof(VkDescriptorBindingFlags));
    bool hasUpdateAfterBind = false;
    if (bindingFlags) {
        for (uint32_t i = 0; i < manager->bindingCount; ++i) {
            if (manager->bindings[i].descriptorType == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER &&
                manager->bindings[i].descriptorCount > 1) {
                // Variable descriptor arrays
                bindingFlags[i] = VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT |
                                  VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT;
                if (!manager->useDescriptorBuffers) {
                    bindingFlags[i] |= VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT;
                    hasUpdateAfterBind = true;
                }
            } else {
                bindingFlags[i] = 0;
            }
        }
        VkDescriptorSetLayoutBindingFlagsCreateInfo flagsInfo = {0};
        flagsInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
        flagsInfo.bindingCount = manager->bindingCount;
        flagsInfo.pBindingFlags = bindingFlags;
        layoutInfo.pNext = &flagsInfo;
    }

    // Add descriptor buffer flag if using descriptor buffers
    if (manager->useDescriptorBuffers) {
        layoutInfo.flags |= VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        // Spec forbids combining UPDATE_AFTER_BIND_POOL with DESCRIPTOR_BUFFER_BIT_EXT
        // So we deliberately do NOT set UPDATE_AFTER_BIND_POOL here.
    } else if (hasUpdateAfterBind) {
        // Only set UPDATE_AFTER_BIND_POOL when not using descriptor buffers
        layoutInfo.flags |= VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT;
    }

    VkResult result =
        vkCreateDescriptorSetLayout(manager->device, &layoutInfo, NULL, &manager->layout);
    if (bindingFlags) {
        free(bindingFlags);
    }
    free(layoutBindings);

    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor set layout");
        return false;
    }

    CARDINAL_LOG_DEBUG("Created descriptor set layout with %u bindings", manager->bindingCount);
    return true;
}

/**
 * @brief Helper function to setup descriptor buffer.
 */
static bool setup_descriptor_buffer(VulkanDescriptorManager* manager, uint32_t maxSets,
                                    VulkanState* vulkan_state) {
    // Check Vulkan state for function pointers
    if (!vulkan_state || !vulkan_state->context.vkGetDescriptorSetLayoutSizeEXT) {
        CARDINAL_LOG_ERROR("Descriptor buffer extension not available");
        return false;
    }

    // Get descriptor set size
    vulkan_state->context.vkGetDescriptorSetLayoutSizeEXT(manager->device, manager->layout,
                                                          &manager->descriptorSetSize);

    // Align descriptor set size
    VkPhysicalDeviceDescriptorBufferPropertiesEXT descriptorBufferProps = {0};
    descriptorBufferProps.sType =
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT;

    VkPhysicalDeviceProperties2 deviceProps = {0};
    deviceProps.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    deviceProps.pNext = &descriptorBufferProps;

    vkGetPhysicalDeviceProperties2(vulkan_state->context.physical_device, &deviceProps);

    VkDeviceSize alignment = descriptorBufferProps.descriptorBufferOffsetAlignment;
    manager->descriptorSetSize = (manager->descriptorSetSize + alignment - 1) & ~(alignment - 1);

    // Calculate total buffer size
    manager->descriptorBufferSize = manager->descriptorSetSize * maxSets;

    // Create descriptor buffer with device address capability
    VkBufferCreateInfo bufferInfo = {0};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = manager->descriptorBufferSize;
    bufferInfo.usage = VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                       VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    // Allocate buffer and memory using allocator (allocator already binds memory)
    if (!vk_allocator_allocate_buffer(manager->allocator, &bufferInfo, &manager->descriptorBuffer,
                                      &manager->descriptorBufferMemory,
                                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                          VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
        CARDINAL_LOG_ERROR("Failed to create and allocate descriptor buffer");
        return false;
    }

    // Map descriptor buffer memory
    if (vkMapMemory(manager->device, manager->descriptorBufferMemory, 0,
                    manager->descriptorBufferSize, 0,
                    &manager->descriptorBufferMapped) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map descriptor buffer memory");
        vk_allocator_free_buffer(manager->allocator, manager->descriptorBuffer,
                                 manager->descriptorBufferMemory);
        return false;
    }

    // Compute binding offsets for fast access
    uint32_t max_binding = 0;
    for (uint32_t i = 0; i < manager->bindingCount; ++i) {
        if (manager->bindings[i].binding > max_binding) {
            max_binding = manager->bindings[i].binding;
        }
    }
    manager->bindingOffsetCount = max_binding + 1;
    manager->bindingOffsets =
        (VkDeviceSize*)calloc(manager->bindingOffsetCount, sizeof(VkDeviceSize));
    if (!manager->bindingOffsets) {
        CARDINAL_LOG_ERROR("Failed to allocate binding offsets array");
        vkUnmapMemory(manager->device, manager->descriptorBufferMemory);
        vk_allocator_free_buffer(manager->allocator, manager->descriptorBuffer,
                                 manager->descriptorBufferMemory);
        manager->descriptorBuffer = VK_NULL_HANDLE;
        manager->descriptorBufferMemory = VK_NULL_HANDLE;
        return false;
    }

    if (!vulkan_state->context.vkGetDescriptorSetLayoutBindingOffsetEXT) {
        CARDINAL_LOG_ERROR("vkGetDescriptorSetLayoutBindingOffsetEXT not loaded");
        return false;
    }

    for (uint32_t i = 0; i < manager->bindingCount; ++i) {
        uint32_t b = manager->bindings[i].binding;
        VkDeviceSize offset = 0;
        vulkan_state->context.vkGetDescriptorSetLayoutBindingOffsetEXT(manager->device,
                                                                       manager->layout, b, &offset);
        manager->bindingOffsets[b] = offset;
    }

    CARDINAL_LOG_DEBUG("Created descriptor buffer: size=%llu, set_size=%llu, max_sets=%u",
                       (unsigned long long)manager->descriptorBufferSize,
                       (unsigned long long)manager->descriptorSetSize, maxSets);
    return true;
}

bool vk_descriptor_manager_create(VulkanDescriptorManager* manager, VkDevice device,
                                  VulkanAllocator* allocator,
                                  const VulkanDescriptorManagerCreateInfo* createInfo,
                                  VulkanState* vulkan_state) {
    if (!manager || !device || !allocator || !createInfo || !createInfo->bindings ||
        createInfo->bindingCount == 0) {
        CARDINAL_LOG_ERROR("Invalid parameters for descriptor manager creation");
        return false;
    }

    memset(manager, 0, sizeof(VulkanDescriptorManager));

    manager->device = device;
    manager->allocator = allocator;
    manager->bindingCount = createInfo->bindingCount;
    manager->vulkan_state = vulkan_state;

    // Copy bindings
    manager->bindings = malloc(createInfo->bindingCount * sizeof(VulkanDescriptorBinding));
    if (!manager->bindings) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for descriptor bindings");
        return false;
    }
    memcpy(manager->bindings, createInfo->bindings,
           createInfo->bindingCount * sizeof(VulkanDescriptorBinding));

    // Check if descriptor buffers are available and preferred
    // Disable descriptor buffers if vulkan_state is NULL
    manager->useDescriptorBuffers = createInfo->preferDescriptorBuffers && vulkan_state &&
                                    vulkan_state->context.vkGetDescriptorSetLayoutSizeEXT;

    // Create descriptor set layout
    if (!create_descriptor_set_layout(manager)) {
        free(manager->bindings);
        return false;
    }

    if (manager->useDescriptorBuffers) {
        // Setup descriptor buffer
        if (!setup_descriptor_buffer(manager, createInfo->maxSets, vulkan_state)) {
            CARDINAL_LOG_WARN(
                "Failed to setup descriptor buffer, falling back to traditional descriptor sets");
            manager->useDescriptorBuffers = false;
        }
    }

    if (!manager->useDescriptorBuffers) {
        // Create traditional descriptor pool
        if (!create_descriptor_pool(manager, createInfo->maxSets, createInfo->poolFlags)) {
            vkDestroyDescriptorSetLayout(manager->device, manager->layout, NULL);
            free(manager->bindings);
            return false;
        }

        // Allocate descriptor sets array
        manager->descriptorSets = malloc(createInfo->maxSets * sizeof(VkDescriptorSet));
        if (!manager->descriptorSets) {
            CARDINAL_LOG_ERROR("Failed to allocate memory for descriptor sets");
            vkDestroyDescriptorPool(manager->device, manager->descriptorPool, NULL);
            vkDestroyDescriptorSetLayout(manager->device, manager->layout, NULL);
            free(manager->bindings);
            return false;
        }
        manager->descriptorSetCount = 0;
    }

    manager->initialized = true;

    CARDINAL_LOG_INFO("Created descriptor manager: %s, %u bindings, max %u sets",
                      manager->useDescriptorBuffers ? "descriptor buffers" : "traditional sets",
                      manager->bindingCount, createInfo->maxSets);
    return true;
}

void vk_descriptor_manager_destroy(VulkanDescriptorManager* manager) {
    if (!manager || !manager->initialized) {
        return;
    }

    if (manager->useDescriptorBuffers) {
        if (manager->descriptorBufferMapped) {
            vkUnmapMemory(manager->device, manager->descriptorBufferMemory);
        }
        if (manager->descriptorBuffer != VK_NULL_HANDLE) {
            vk_allocator_free_buffer(manager->allocator, manager->descriptorBuffer,
                                     manager->descriptorBufferMemory);
        }
        if (manager->bindingOffsets) {
            free(manager->bindingOffsets);
            manager->bindingOffsets = NULL;
            manager->bindingOffsetCount = 0;
        }
    } else {
        if (manager->descriptorSets) {
            free(manager->descriptorSets);
        }
        if (manager->descriptorPool != VK_NULL_HANDLE) {
            vkDestroyDescriptorPool(manager->device, manager->descriptorPool, NULL);
        }
    }

    if (manager->layout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(manager->device, manager->layout, NULL);
    }

    if (manager->bindings) {
        free(manager->bindings);
    }

    memset(manager, 0, sizeof(VulkanDescriptorManager));
}

bool vk_descriptor_manager_allocate_sets(VulkanDescriptorManager* manager, uint32_t setCount,
                                         VkDescriptorSet* pDescriptorSets) {
    if (!manager || !manager->initialized || manager->useDescriptorBuffers) {
        CARDINAL_LOG_ERROR("Invalid manager or using descriptor buffers");
        return false;
    }
    if (manager->device == VK_NULL_HANDLE || manager->descriptorPool == VK_NULL_HANDLE) {
        CARDINAL_LOG_ERROR("Invalid device or descriptor pool for allocation");
        return false;
    }

    VkDescriptorSetLayout* layouts = malloc(setCount * sizeof(VkDescriptorSetLayout));
    if (!layouts) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for descriptor set layouts");
        return false;
    }

    for (uint32_t i = 0; i < setCount; i++) {
        layouts[i] = manager->layout;
    }

    VkDescriptorSetAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool = manager->descriptorPool;
    allocInfo.descriptorSetCount = setCount;
    allocInfo.pSetLayouts = layouts;

    VkResult result = vkAllocateDescriptorSets(manager->device, &allocInfo, pDescriptorSets);
    free(layouts);

    if (result != VK_SUCCESS) {
        if (result == VK_ERROR_OUT_OF_DEVICE_MEMORY) {
            CARDINAL_LOG_ERROR("Failed to allocate descriptor sets: OUT OF DEVICE MEMORY");
        } else if (result == VK_ERROR_OUT_OF_HOST_MEMORY) {
            CARDINAL_LOG_ERROR("Failed to allocate descriptor sets: OUT OF HOST MEMORY");
        } else if (result == VK_ERROR_OUT_OF_POOL_MEMORY) {
            CARDINAL_LOG_ERROR("Failed to allocate descriptor sets: OUT OF POOL MEMORY (descriptor "
                               "pool exhausted)");
        } else {
            CARDINAL_LOG_ERROR("Failed to allocate descriptor sets: error %d", result);
        }
        return false;
    }

    // Store allocated sets
    for (uint32_t i = 0; i < setCount; i++) {
        if (manager->descriptorSetCount < 1000) { // Reasonable limit
            manager->descriptorSets[manager->descriptorSetCount++] = pDescriptorSets[i];
        }
    }

    CARDINAL_LOG_DEBUG("Allocated %u descriptor sets", setCount);
    return true;
}

/**
 * @brief Updates a buffer descriptor using descriptor buffers.
 */
static bool update_buffer_descriptor_buffer(VulkanDescriptorManager* manager, uint32_t setIndex,
                                            uint32_t binding, VkBuffer buffer, VkDeviceSize offset,
                                            VkDeviceSize range) {
    if (!manager->vulkan_state || !manager->vulkan_state->context.vkGetDescriptorEXT) {
        CARDINAL_LOG_ERROR("Descriptor buffer extension not available for updates");
        return false;
    }

    // Get device address of the source buffer
    VkBufferDeviceAddressInfo addrInfo = {0};
    addrInfo.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
    addrInfo.buffer = buffer;
    VkDeviceAddress bufferAddress =
        manager->vulkan_state->context.vkGetBufferDeviceAddress(manager->device, &addrInfo);

    VkDescriptorAddressInfoEXT addressDesc = {0};
    addressDesc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT;
    addressDesc.address = bufferAddress + offset;
    addressDesc.range = range;

    VkDescriptorGetInfoEXT getInfo = {0};
    getInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
    getInfo.type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    getInfo.data.pUniformBuffer = &addressDesc;

    // Compute destination pointer in descriptor buffer
    VkDeviceSize setOffset = manager->descriptorSetSize * setIndex;
    VkDeviceSize bindingOffset =
        (binding < manager->bindingOffsetCount) ? manager->bindingOffsets[binding] : 0;
    VkDeviceSize dstOffset = setOffset + bindingOffset;

    VkDeviceSize descSize =
        get_descriptor_size_for_type(manager->vulkan_state, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER);
    if (descSize == 0) {
        CARDINAL_LOG_ERROR("Uniform buffer descriptor size not available");
        return false;
    }

    manager->vulkan_state->context.vkGetDescriptorEXT(
        manager->device, &getInfo, descSize, (char*)manager->descriptorBufferMapped + dstOffset);

    return true;
}

/**
 * @brief Updates a buffer descriptor using standard descriptor sets.
 */
static bool update_buffer_descriptor_set(VulkanDescriptorManager* manager, uint32_t setIndex,
                                         uint32_t binding, VkBuffer buffer, VkDeviceSize offset,
                                         VkDeviceSize range, VkDescriptorType dtype) {
    if (setIndex >= manager->descriptorSetCount) {
        CARDINAL_LOG_ERROR("Invalid descriptor set index: %u", setIndex);
        return false;
    }

    VkDescriptorBufferInfo bufferInfo = {0};
    bufferInfo.buffer = buffer;
    bufferInfo.offset = offset;
    bufferInfo.range = range;

    VkWriteDescriptorSet descriptorWrite = {0};
    descriptorWrite.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrite.dstSet = manager->descriptorSets[setIndex];
    descriptorWrite.dstBinding = binding;
    descriptorWrite.dstArrayElement = 0;
    descriptorWrite.descriptorType = dtype;
    descriptorWrite.descriptorCount = 1;
    descriptorWrite.pBufferInfo = &bufferInfo;

    vkUpdateDescriptorSets(manager->device, 1, &descriptorWrite, 0, NULL);
    return true;
}

bool vk_descriptor_manager_update_buffer(VulkanDescriptorManager* manager, uint32_t setIndex,
                                         uint32_t binding, VkBuffer buffer, VkDeviceSize offset,
                                         VkDeviceSize range) {
    if (!manager || !manager->initialized) {
        CARDINAL_LOG_ERROR("Invalid descriptor manager");
        return false;
    }

    VkDescriptorType dtype = get_binding_descriptor_type(manager, binding);
    if (dtype == VK_DESCRIPTOR_TYPE_MAX_ENUM) {
        CARDINAL_LOG_ERROR("Unknown descriptor type for binding %u", binding);
        return false;
    }

    if (manager->useDescriptorBuffers) {
        if (dtype != VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            CARDINAL_LOG_WARN("Descriptor buffer update only implemented for UNIFORM_BUFFER");
            return false;
        }
        return update_buffer_descriptor_buffer(manager, setIndex, binding, buffer, offset, range);
    } else {
        return update_buffer_descriptor_set(manager, setIndex, binding, buffer, offset, range,
                                            dtype);
    }
}

/**
 * @brief Updates an image descriptor using descriptor buffers.
 */
static bool update_image_descriptor_buffer(VulkanDescriptorManager* manager, uint32_t setIndex,
                                           uint32_t binding, VkImageView imageView,
                                           VkSampler sampler, VkImageLayout imageLayout) {
    if (!manager->vulkan_state || !manager->vulkan_state->context.vkGetDescriptorEXT) {
        CARDINAL_LOG_ERROR("Descriptor buffer extension not available for updates");
        return false;
    }

    VkDescriptorImageInfo imageInfo = {0};
    imageInfo.imageLayout = imageLayout;
    imageInfo.imageView = imageView;
    imageInfo.sampler = sampler;

    VkDescriptorGetInfoEXT getInfo = {0};
    getInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
    getInfo.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    getInfo.data.pCombinedImageSampler = &imageInfo;

    VkDeviceSize setOffset = manager->descriptorSetSize * setIndex;
    VkDeviceSize bindingOffset =
        (binding < manager->bindingOffsetCount) ? manager->bindingOffsets[binding] : 0;
    VkDeviceSize dstOffset = setOffset + bindingOffset;
    VkDeviceSize descSize = get_descriptor_size_for_type(manager->vulkan_state,
                                                         VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
    if (descSize == 0) {
        CARDINAL_LOG_ERROR("Combined image sampler descriptor size not available");
        return false;
    }

    manager->vulkan_state->context.vkGetDescriptorEXT(
        manager->device, &getInfo, descSize, (char*)manager->descriptorBufferMapped + dstOffset);

    return true;
}

/**
 * @brief Updates an image descriptor using standard descriptor sets.
 */
static bool update_image_descriptor_set(VulkanDescriptorManager* manager, uint32_t setIndex,
                                        uint32_t binding, VkImageView imageView, VkSampler sampler,
                                        VkImageLayout imageLayout, VkDescriptorType dtype) {
    if (setIndex >= manager->descriptorSetCount) {
        CARDINAL_LOG_ERROR("Invalid descriptor set index: %u", setIndex);
        return false;
    }

    VkDescriptorImageInfo imageInfo = {0};
    imageInfo.imageLayout = imageLayout;
    imageInfo.imageView = imageView;
    imageInfo.sampler = sampler;

    VkWriteDescriptorSet descriptorWrite = {0};
    descriptorWrite.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrite.dstSet = manager->descriptorSets[setIndex];
    descriptorWrite.dstBinding = binding;
    descriptorWrite.dstArrayElement = 0;
    descriptorWrite.descriptorType = dtype;
    descriptorWrite.descriptorCount = 1;
    descriptorWrite.pImageInfo = &imageInfo;

    vkUpdateDescriptorSets(manager->device, 1, &descriptorWrite, 0, NULL);
    return true;
}

bool vk_descriptor_manager_update_image(VulkanDescriptorManager* manager, uint32_t setIndex,
                                        uint32_t binding, VkImageView imageView, VkSampler sampler,
                                        VkImageLayout imageLayout) {
    if (!manager || !manager->initialized) {
        CARDINAL_LOG_ERROR("Invalid descriptor manager");
        return false;
    }

    VkDescriptorType dtype = get_binding_descriptor_type(manager, binding);
    if (dtype == VK_DESCRIPTOR_TYPE_MAX_ENUM) {
        CARDINAL_LOG_ERROR("Unknown descriptor type for binding %u", binding);
        return false;
    }

    if (manager->useDescriptorBuffers) {
        if (dtype != VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
            CARDINAL_LOG_WARN("Descriptor buffer image update only for COMBINED_IMAGE_SAMPLER");
            return false;
        }
        return update_image_descriptor_buffer(manager, setIndex, binding, imageView, sampler,
                                              imageLayout);
    } else {
        return update_image_descriptor_set(manager, setIndex, binding, imageView, sampler,
                                           imageLayout, dtype);
    }
}

/**
 * @brief Updates a texture array descriptor using descriptor buffers.
 */
static bool update_textures_descriptor_buffer(VulkanDescriptorManager* manager, uint32_t setIndex,
                                              uint32_t binding, VkImageView* imageViews,
                                              VkSampler* samplers, VkSampler singleSampler,
                                              VkImageLayout imageLayout,
                                              uint32_t count) {
    if (!manager->vulkan_state || !manager->vulkan_state->context.vkGetDescriptorEXT) {
        CARDINAL_LOG_ERROR("Descriptor buffer extension not available for updates");
        return false;
    }

    VkDeviceSize setOffset = manager->descriptorSetSize * setIndex;
    VkDeviceSize bindingOffset =
        (binding < manager->bindingOffsetCount) ? manager->bindingOffsets[binding] : 0;
    VkDeviceSize descSize = get_descriptor_size_for_type(manager->vulkan_state,
                                                         VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);

    if (descSize == 0) {
        CARDINAL_LOG_ERROR("Combined image sampler descriptor size not available");
        return false;
    }

    for (uint32_t i = 0; i < count; ++i) {
        VkDescriptorImageInfo imageInfo = {0};
        imageInfo.imageLayout = imageLayout;
        imageInfo.imageView = imageViews[i];
        imageInfo.sampler = samplers ? samplers[i] : singleSampler;

        VkDescriptorGetInfoEXT getInfo = {0};
        getInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
        getInfo.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        getInfo.data.pCombinedImageSampler = &imageInfo;

        VkDeviceSize elementOffset = i * descSize;
        VkDeviceSize dstOffset = setOffset + bindingOffset + elementOffset;

        manager->vulkan_state->context.vkGetDescriptorEXT(manager->device, &getInfo, descSize,
                                                          (char*)manager->descriptorBufferMapped +
                                                              dstOffset);
    }

    CARDINAL_LOG_DEBUG("Updated %u textures in descriptor buffer set %u, binding %u", count,
                       setIndex, binding);
    return true;
}

/**
 * @brief Updates a texture array descriptor using standard descriptor sets.
 */
static bool update_textures_descriptor_set(VulkanDescriptorManager* manager, uint32_t setIndex,
                                           uint32_t binding, VkImageView* imageViews,
                                           VkSampler* samplers, VkSampler singleSampler,
                                           VkImageLayout imageLayout,
                                           uint32_t count, VkDescriptorType dtype) {
    if (setIndex >= manager->descriptorSetCount) {
        CARDINAL_LOG_ERROR("Invalid descriptor set index: %u", setIndex);
        return false;
    }

    VkDescriptorImageInfo* imageInfos = malloc(count * sizeof(VkDescriptorImageInfo));
    if (!imageInfos) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for image infos");
        return false;
    }

    for (uint32_t i = 0; i < count; i++) {
        imageInfos[i].imageLayout = imageLayout;
        imageInfos[i].imageView = imageViews[i];
        imageInfos[i].sampler = samplers ? samplers[i] : singleSampler;
    }

    VkWriteDescriptorSet descriptorWrite = {0};
    descriptorWrite.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrite.dstSet = manager->descriptorSets[setIndex];
    descriptorWrite.dstBinding = binding;
    descriptorWrite.dstArrayElement = 0;
    descriptorWrite.descriptorType = dtype;
    descriptorWrite.descriptorCount = count;
    descriptorWrite.pImageInfo = imageInfos;

    vkUpdateDescriptorSets(manager->device, 1, &descriptorWrite, 0, NULL);
    free(imageInfos);

    CARDINAL_LOG_DEBUG("Updated %u textures in descriptor set %u, binding %u", count, setIndex,
                       binding);
    return true;
}

bool vk_descriptor_manager_update_textures(VulkanDescriptorManager* manager, uint32_t setIndex,
                                           uint32_t binding, VkImageView* imageViews,
                                           VkSampler sampler, VkImageLayout imageLayout,
                                           uint32_t count) {
    if (!manager || !manager->initialized || !imageViews || count == 0) {
        CARDINAL_LOG_ERROR("Invalid parameters for texture update");
        return false;
    }

    VkDescriptorType dtype = get_binding_descriptor_type(manager, binding);
    if (dtype == VK_DESCRIPTOR_TYPE_MAX_ENUM) {
        CARDINAL_LOG_ERROR("Unknown descriptor type for binding %u", binding);
        return false;
    }

    if (manager->useDescriptorBuffers) {
        if (dtype != VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
            CARDINAL_LOG_WARN("Texture array update only implemented for COMBINED_IMAGE_SAMPLER");
            return false;
        }
        return update_textures_descriptor_buffer(manager, setIndex, binding, imageViews, NULL, sampler,
                                                 imageLayout, count);
    } else {
        return update_textures_descriptor_set(manager, setIndex, binding, imageViews, NULL, sampler,
                                              imageLayout, count, dtype);
    }
}

bool vk_descriptor_manager_update_textures_with_samplers(VulkanDescriptorManager* manager, uint32_t setIndex,
                                           uint32_t binding, VkImageView* imageViews,
                                           VkSampler* samplers, VkImageLayout imageLayout,
                                           uint32_t count) {
    if (!manager || !manager->initialized || !imageViews || !samplers || count == 0) {
        CARDINAL_LOG_ERROR("Invalid parameters for texture update with samplers");
        return false;
    }

    VkDescriptorType dtype = get_binding_descriptor_type(manager, binding);
    if (dtype == VK_DESCRIPTOR_TYPE_MAX_ENUM) {
        CARDINAL_LOG_ERROR("Unknown descriptor type for binding %u", binding);
        return false;
    }

    if (manager->useDescriptorBuffers) {
        if (dtype != VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
            CARDINAL_LOG_WARN("Texture array update only implemented for COMBINED_IMAGE_SAMPLER");
            return false;
        }
        return update_textures_descriptor_buffer(manager, setIndex, binding, imageViews, samplers, VK_NULL_HANDLE,
                                                 imageLayout, count);
    } else {
        return update_textures_descriptor_set(manager, setIndex, binding, imageViews, samplers, VK_NULL_HANDLE,
                                              imageLayout, count, dtype);
    }
}

static void bind_descriptor_buffers(VulkanDescriptorManager* manager, VkCommandBuffer commandBuffer,
                                    VkPipelineLayout pipelineLayout, uint32_t firstSet,
                                    uint32_t setCount) {
    if (!manager->vulkan_state || !manager->vulkan_state->context.vkCmdBindDescriptorBuffersEXT ||
        !manager->vulkan_state->context.vkCmdSetDescriptorBufferOffsetsEXT) {
        CARDINAL_LOG_ERROR("Descriptor buffer binding functions not available");
        return;
    }

    // Bind the single descriptor buffer
    VkBufferDeviceAddressInfo addressInfo = {0};
    addressInfo.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
    addressInfo.buffer = manager->descriptorBuffer;
    VkDeviceAddress baseAddress =
        manager->vulkan_state->context.vkGetBufferDeviceAddress(manager->device, &addressInfo);

    VkDescriptorBufferBindingInfoEXT bindingInfo = {0};
    bindingInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT;
    bindingInfo.address = baseAddress;
    bindingInfo.usage = VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT;

    manager->vulkan_state->context.vkCmdBindDescriptorBuffersEXT(commandBuffer, 1, &bindingInfo);

    // Set descriptor buffer offsets for the requested sets
    // All sets refer to the same buffer index 0
    uint32_t* bufferIndices = (uint32_t*)alloca(sizeof(uint32_t) * setCount);
    VkDeviceSize* offsets = (VkDeviceSize*)alloca(sizeof(VkDeviceSize) * setCount);
    for (uint32_t i = 0; i < setCount; ++i) {
        bufferIndices[i] = 0; // the single bound descriptor buffer
        offsets[i] = manager->descriptorSetSize * (firstSet + i);
    }

    manager->vulkan_state->context.vkCmdSetDescriptorBufferOffsetsEXT(
        commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, firstSet, setCount,
        bufferIndices, offsets);
}

void vk_descriptor_manager_bind_sets(VulkanDescriptorManager* manager,
                                     VkCommandBuffer commandBuffer, VkPipelineLayout pipelineLayout,
                                     uint32_t firstSet, uint32_t setCount,
                                     const VkDescriptorSet* pDescriptorSets,
                                     uint32_t dynamicOffsetCount, const uint32_t* pDynamicOffsets) {
    if (!manager || !manager->initialized) {
        return;
    }
    if (setCount == 0) {
        return;
    }

    if (manager->useDescriptorBuffers) {
        bind_descriptor_buffers(manager, commandBuffer, pipelineLayout, firstSet, setCount);
    } else {
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout,
                                firstSet, setCount, pDescriptorSets, dynamicOffsetCount,
                                pDynamicOffsets);
    }
}

VkDescriptorSetLayout vk_descriptor_manager_get_layout(const VulkanDescriptorManager* manager) {
    return manager ? manager->layout : VK_NULL_HANDLE;
}

bool vk_descriptor_manager_uses_buffers(const VulkanDescriptorManager* manager) {
    return manager ? manager->useDescriptorBuffers : false;
}

VkDeviceSize vk_descriptor_manager_get_set_size(const VulkanDescriptorManager* manager) {
    return manager ? manager->descriptorSetSize : 0;
}

void* vk_descriptor_manager_get_set_data(VulkanDescriptorManager* manager, uint32_t setIndex) {
    if (!manager || !manager->useDescriptorBuffers || !manager->descriptorBufferMapped) {
        return NULL;
    }

    return (char*)manager->descriptorBufferMapped + (setIndex * manager->descriptorSetSize);
}
