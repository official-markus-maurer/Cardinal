#include "cardinal/renderer/vulkan_descriptor_indexing.h"
#include "vulkan_state.h"
#include "cardinal/core/log.h"
#include <string.h>
#include <stdlib.h>

// Helper function to create default sampler
static bool create_default_sampler(VkDevice device, VkSampler* out_sampler) {
    VkSamplerCreateInfo sampler_info = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_LINEAR,
        .minFilter = VK_FILTER_LINEAR,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .anisotropyEnable = VK_TRUE,
        .maxAnisotropy = 16.0f,
        .borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = VK_FALSE,
        .compareEnable = VK_FALSE,
        .compareOp = VK_COMPARE_OP_ALWAYS,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .mipLodBias = 0.0f,
        .minLod = 0.0f,
        .maxLod = VK_LOD_CLAMP_NONE
    };
    
    VkResult result = vkCreateSampler(device, &sampler_info, NULL, out_sampler);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create default sampler: %d", result);
        return false;
    }
    
    return true;
}

// Helper function to create descriptor pool for bindless textures
static bool create_bindless_descriptor_pool(VkDevice device, uint32_t max_textures, VkDescriptorPool* out_pool) {
    VkDescriptorPoolSize pool_sizes[] = {
        {
            .type = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = max_textures
        },
        {
            .type = VK_DESCRIPTOR_TYPE_SAMPLER,
            .descriptorCount = max_textures
        }
    };
    
    VkDescriptorPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT,
        .maxSets = 1,
        .poolSizeCount = 2,
        .pPoolSizes = pool_sizes
    };
    
    VkResult result = vkCreateDescriptorPool(device, &pool_info, NULL, out_pool);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create bindless descriptor pool: %d", result);
        return false;
    }
    
    return true;
}

bool vk_bindless_texture_pool_init(BindlessTexturePool* pool, VulkanState* vulkan_state, uint32_t max_textures) {
    if (!pool || !vulkan_state) {
        CARDINAL_LOG_ERROR("Invalid parameters for bindless texture pool initialization");
        return false;
    }
    
    if (!vk_descriptor_indexing_supported(vulkan_state)) {
        CARDINAL_LOG_ERROR("Descriptor indexing not supported, cannot create bindless texture pool");
        return false;
    }
    
    memset(pool, 0, sizeof(BindlessTexturePool));
    
    pool->device = vulkan_state->device;
    pool->physical_device = vulkan_state->physical_device;
    pool->allocator = &vulkan_state->allocator;
    pool->max_textures = max_textures;
    
    // Allocate texture array
    pool->textures = calloc(max_textures, sizeof(BindlessTexture));
    if (!pool->textures) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for bindless textures");
        return false;
    }
    
    // Initialize free list
    pool->free_indices = malloc(max_textures * sizeof(uint32_t));
    if (!pool->free_indices) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for free indices");
        free(pool->textures);
        return false;
    }
    
    // Initialize all indices as free
    for (uint32_t i = 0; i < max_textures; i++) {
        pool->free_indices[i] = max_textures - 1 - i; // Reverse order for stack behavior
    }
    pool->free_count = max_textures;
    
    // Allocate pending updates array
    pool->pending_updates = malloc(max_textures * sizeof(uint32_t));
    if (!pool->pending_updates) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for pending updates");
        free(pool->textures);
        free(pool->free_indices);
        return false;
    }
    
    // Create default sampler
    if (!create_default_sampler(pool->device, &pool->default_sampler)) {
        free(pool->textures);
        free(pool->free_indices);
        free(pool->pending_updates);
        return false;
    }
    
    // Create descriptor set layout
    VkDescriptorSetLayoutBinding bindings[] = {
        {
            .binding = CARDINAL_BINDLESS_TEXTURE_BINDING,
            .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = max_textures,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_MESH_BIT_EXT,
            .pImmutableSamplers = NULL
        },
        {
            .binding = CARDINAL_BINDLESS_SAMPLER_BINDING,
            .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER,
            .descriptorCount = max_textures,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_MESH_BIT_EXT,
            .pImmutableSamplers = NULL
        }
    };
    
    if (!vk_create_variable_descriptor_layout(pool->device, 2, bindings, 
                                              CARDINAL_BINDLESS_TEXTURE_BINDING, 
                                              max_textures, &pool->descriptor_layout)) {
        vkDestroySampler(pool->device, pool->default_sampler, NULL);
        free(pool->textures);
        free(pool->free_indices);
        free(pool->pending_updates);
        return false;
    }
    
    // Create descriptor pool
    if (!create_bindless_descriptor_pool(pool->device, max_textures, &pool->descriptor_pool)) {
        vkDestroyDescriptorSetLayout(pool->device, pool->descriptor_layout, NULL);
        vkDestroySampler(pool->device, pool->default_sampler, NULL);
        free(pool->textures);
        free(pool->free_indices);
        free(pool->pending_updates);
        return false;
    }
    
    // Allocate descriptor set
    if (!vk_allocate_variable_descriptor_set(pool->device, pool->descriptor_pool, 
                                             pool->descriptor_layout, max_textures, 
                                             &pool->descriptor_set)) {
        vkDestroyDescriptorPool(pool->device, pool->descriptor_pool, NULL);
        vkDestroyDescriptorSetLayout(pool->device, pool->descriptor_layout, NULL);
        vkDestroySampler(pool->device, pool->default_sampler, NULL);
        free(pool->textures);
        free(pool->free_indices);
        free(pool->pending_updates);
        return false;
    }
    
    CARDINAL_LOG_INFO("Bindless texture pool initialized with %u max textures", max_textures);
    return true;
}

void vk_bindless_texture_pool_destroy(BindlessTexturePool* pool) {
    if (!pool || !pool->device) {
        return;
    }
    
    // Free all allocated textures
    for (uint32_t i = 0; i < pool->max_textures; i++) {
        if (pool->textures[i].is_allocated) {
            vk_bindless_texture_free(pool, i);
        }
    }
    
    // Destroy Vulkan objects
    if (pool->descriptor_pool != VK_NULL_HANDLE) {
        vkDestroyDescriptorPool(pool->device, pool->descriptor_pool, NULL);
    }
    
    if (pool->descriptor_layout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(pool->device, pool->descriptor_layout, NULL);
    }
    
    if (pool->default_sampler != VK_NULL_HANDLE) {
        vkDestroySampler(pool->device, pool->default_sampler, NULL);
    }
    
    // Free memory
    free(pool->textures);
    free(pool->free_indices);
    free(pool->pending_updates);
    
    memset(pool, 0, sizeof(BindlessTexturePool));
    
    CARDINAL_LOG_INFO("Bindless texture pool destroyed");
}

bool vk_bindless_texture_allocate(BindlessTexturePool* pool,
                                  const BindlessTextureCreateInfo* create_info,
                                  uint32_t* out_index) {
    if (!pool || !create_info || !out_index) {
        CARDINAL_LOG_ERROR("Invalid parameters for bindless texture allocation");
        return false;
    }
    
    if (pool->free_count == 0) {
        CARDINAL_LOG_ERROR("No free bindless texture slots available");
        return false;
    }
    
    // Get free index
    uint32_t index = pool->free_indices[--pool->free_count];
    BindlessTexture* texture = &pool->textures[index];
    
    // Create image
    VkImageCreateInfo image_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = create_info->format,
        .extent = create_info->extent,
        .mipLevels = create_info->mip_levels,
        .arrayLayers = 1,
        .samples = create_info->samples,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = create_info->usage | VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    };
    
    VkResult result = vkCreateImage(pool->device, &image_info, NULL, &texture->image);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create bindless texture image: %d", result);
        pool->free_indices[pool->free_count++] = index; // Return index to free list
        return false;
    }
    
    // Allocate memory for image
    VkMemoryRequirements mem_requirements;
    vkGetImageMemoryRequirements(pool->device, texture->image, &mem_requirements);
    
    VkMemoryAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = 0 // TODO: Find appropriate memory type
    };
    
    // Find memory type
    VkPhysicalDeviceMemoryProperties mem_properties;
    vkGetPhysicalDeviceMemoryProperties(pool->physical_device, &mem_properties);
    
    uint32_t memory_type_index = UINT32_MAX;
    for (uint32_t i = 0; i < mem_properties.memoryTypeCount; i++) {
        if ((mem_requirements.memoryTypeBits & (1 << i)) &&
            (mem_properties.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
            memory_type_index = i;
            break;
        }
    }
    
    if (memory_type_index == UINT32_MAX) {
        CARDINAL_LOG_ERROR("Failed to find suitable memory type for bindless texture");
        vkDestroyImage(pool->device, texture->image, NULL);
        pool->free_indices[pool->free_count++] = index;
        return false;
    }
    
    alloc_info.memoryTypeIndex = memory_type_index;
    
    result = vkAllocateMemory(pool->device, &alloc_info, NULL, &texture->memory);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for bindless texture: %d", result);
        vkDestroyImage(pool->device, texture->image, NULL);
        pool->free_indices[pool->free_count++] = index;
        return false;
    }
    
    result = vkBindImageMemory(pool->device, texture->image, texture->memory, 0);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to bind memory to bindless texture: %d", result);
        vkFreeMemory(pool->device, texture->memory, NULL);
        vkDestroyImage(pool->device, texture->image, NULL);
        pool->free_indices[pool->free_count++] = index;
        return false;
    }
    
    // Create image view
    VkImageViewCreateInfo view_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = texture->image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = create_info->format,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = create_info->mip_levels,
            .baseArrayLayer = 0,
            .layerCount = 1
        }
    };
    
    result = vkCreateImageView(pool->device, &view_info, NULL, &texture->image_view);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create image view for bindless texture: %d", result);
        vkFreeMemory(pool->device, texture->memory, NULL);
        vkDestroyImage(pool->device, texture->image, NULL);
        pool->free_indices[pool->free_count++] = index;
        return false;
    }
    
    // Set texture properties
    texture->sampler = (create_info->custom_sampler != VK_NULL_HANDLE) ? 
                      create_info->custom_sampler : pool->default_sampler;
    texture->descriptor_index = index;
    texture->is_allocated = true;
    texture->format = create_info->format;
    texture->extent = create_info->extent;
    texture->mip_levels = create_info->mip_levels;
    
    // Mark for descriptor update
    pool->pending_updates[pool->pending_update_count++] = index;
    pool->needs_descriptor_update = true;
    
    pool->allocated_count++;
    *out_index = index;
    
    CARDINAL_LOG_DEBUG("Allocated bindless texture at index %u", index);
    return true;
}

void vk_bindless_texture_free(BindlessTexturePool* pool, uint32_t texture_index) {
    if (!pool || texture_index >= pool->max_textures) {
        CARDINAL_LOG_ERROR("Invalid texture index for bindless texture free: %u", texture_index);
        return;
    }
    
    BindlessTexture* texture = &pool->textures[texture_index];
    if (!texture->is_allocated) {
        CARDINAL_LOG_WARN("Attempting to free already freed bindless texture at index %u", texture_index);
        return;
    }
    
    // Destroy Vulkan objects
    if (texture->image_view != VK_NULL_HANDLE) {
        vkDestroyImageView(pool->device, texture->image_view, NULL);
    }
    
    if (texture->image != VK_NULL_HANDLE) {
        vkDestroyImage(pool->device, texture->image, NULL);
    }
    
    if (texture->memory != VK_NULL_HANDLE) {
        vkFreeMemory(pool->device, texture->memory, NULL);
    }
    
    // Reset texture
    memset(texture, 0, sizeof(BindlessTexture));
    
    // Return index to free list
    pool->free_indices[pool->free_count++] = texture_index;
    pool->allocated_count--;
    
    CARDINAL_LOG_DEBUG("Freed bindless texture at index %u", texture_index);
}

bool vk_bindless_texture_update_data(BindlessTexturePool* pool,
                                     uint32_t texture_index,
                                     const void* data,
                                     VkDeviceSize data_size,
                                     VkCommandBuffer command_buffer) {
    (void)pool; // Suppress unreferenced parameter warning
    (void)texture_index;
    (void)data;
    (void)data_size;
    (void)command_buffer;
    // TODO: Implement texture data upload using staging buffer
    CARDINAL_LOG_WARN("Bindless texture data update not yet implemented");
    return false;
}

VkDescriptorSet vk_bindless_texture_get_descriptor_set(const BindlessTexturePool* pool) {
    return pool ? pool->descriptor_set : VK_NULL_HANDLE;
}

VkDescriptorSetLayout vk_bindless_texture_get_layout(const BindlessTexturePool* pool) {
    return pool ? pool->descriptor_layout : VK_NULL_HANDLE;
}

bool vk_bindless_texture_flush_updates(BindlessTexturePool* pool) {
    if (!pool || !pool->needs_descriptor_update || pool->pending_update_count == 0) {
        return true;
    }
    
    // Prepare descriptor writes for updated textures
    VkWriteDescriptorSet* writes = malloc(pool->pending_update_count * 2 * sizeof(VkWriteDescriptorSet));
    VkDescriptorImageInfo* image_infos = malloc(pool->pending_update_count * sizeof(VkDescriptorImageInfo));
    VkDescriptorImageInfo* sampler_infos = malloc(pool->pending_update_count * sizeof(VkDescriptorImageInfo));
    
    if (!writes || !image_infos || !sampler_infos) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for descriptor updates");
        free(writes);
        free(image_infos);
        free(sampler_infos);
        return false;
    }
    
    uint32_t write_count = 0;
    
    for (uint32_t i = 0; i < pool->pending_update_count; i++) {
        uint32_t texture_index = pool->pending_updates[i];
        const BindlessTexture* texture = &pool->textures[texture_index];
        
        if (!texture->is_allocated) {
            continue;
        }
        
        // Image descriptor write
        image_infos[i] = (VkDescriptorImageInfo){
            .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .imageView = texture->image_view,
            .sampler = VK_NULL_HANDLE
        };
        
        writes[write_count++] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = pool->descriptor_set,
            .dstBinding = CARDINAL_BINDLESS_TEXTURE_BINDING,
            .dstArrayElement = texture_index,
            .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = 1,
            .pImageInfo = &image_infos[i]
        };
        
        // Sampler descriptor write
        sampler_infos[i] = (VkDescriptorImageInfo){
            .imageLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .imageView = VK_NULL_HANDLE,
            .sampler = texture->sampler
        };
        
        writes[write_count++] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = pool->descriptor_set,
            .dstBinding = CARDINAL_BINDLESS_SAMPLER_BINDING,
            .dstArrayElement = texture_index,
            .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER,
            .descriptorCount = 1,
            .pImageInfo = &sampler_infos[i]
        };
    }
    
    // Update descriptor sets
    if (write_count > 0) {
        vkUpdateDescriptorSets(pool->device, write_count, writes, 0, NULL);
        CARDINAL_LOG_DEBUG("Updated %u bindless texture descriptors", write_count / 2);
    }
    
    // Clean up
    free(writes);
    free(image_infos);
    free(sampler_infos);
    
    pool->needs_descriptor_update = false;
    pool->pending_update_count = 0;
    
    return true;
}

const BindlessTexture* vk_bindless_texture_get(const BindlessTexturePool* pool, uint32_t texture_index) {
    if (!pool || texture_index >= pool->max_textures || !pool->textures[texture_index].is_allocated) {
        return NULL;
    }
    
    return &pool->textures[texture_index];
}

bool vk_descriptor_indexing_supported(const VulkanState* vulkan_state) {
    return vulkan_state && vulkan_state->supports_descriptor_indexing;
}

bool vk_create_variable_descriptor_layout(VkDevice device,
                                          uint32_t binding_count,
                                          const VkDescriptorSetLayoutBinding* bindings,
                                          uint32_t variable_binding_index,
                                          uint32_t max_variable_count,
                                          VkDescriptorSetLayout* out_layout) {
    (void)max_variable_count; // Suppress unreferenced parameter warning
    if (!device || !bindings || !out_layout) {
        CARDINAL_LOG_ERROR("Invalid parameters for variable descriptor layout creation");
        return false;
    }
    
    // Create binding flags for variable descriptor count
    VkDescriptorBindingFlags* binding_flags = calloc(binding_count, sizeof(VkDescriptorBindingFlags));
    if (!binding_flags) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for binding flags");
        return false;
    }
    
    // Set flags for variable binding
    binding_flags[variable_binding_index] = 
        VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT |
        VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT |
        VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT;
    
    // Set update-after-bind flag for other bindings if needed
    for (uint32_t i = 0; i < binding_count; i++) {
        if (i != variable_binding_index) {
            binding_flags[i] = VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT;
        }
    }
    
    VkDescriptorSetLayoutBindingFlagsCreateInfo binding_flags_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
        .bindingCount = binding_count,
        .pBindingFlags = binding_flags
    };
    
    VkDescriptorSetLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = &binding_flags_info,
        .flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT,
        .bindingCount = binding_count,
        .pBindings = bindings
    };
    
    VkResult result = vkCreateDescriptorSetLayout(device, &layout_info, NULL, out_layout);
    
    free(binding_flags);
    
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create variable descriptor set layout: %d", result);
        return false;
    }
    
    return true;
}

bool vk_allocate_variable_descriptor_set(VkDevice device,
                                         VkDescriptorPool descriptor_pool,
                                         VkDescriptorSetLayout layout,
                                         uint32_t variable_count,
                                         VkDescriptorSet* out_set) {
    if (!device || !descriptor_pool || !layout || !out_set) {
        CARDINAL_LOG_ERROR("Invalid parameters for variable descriptor set allocation");
        return false;
    }
    
    VkDescriptorSetVariableDescriptorCountAllocateInfo variable_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
        .descriptorSetCount = 1,
        .pDescriptorCounts = &variable_count
    };
    
    VkDescriptorSetAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = &variable_info,
        .descriptorPool = descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &layout
    };
    
    VkResult result = vkAllocateDescriptorSets(device, &alloc_info, out_set);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate variable descriptor set: %d", result);
        return false;
    }
    
    return true;
}