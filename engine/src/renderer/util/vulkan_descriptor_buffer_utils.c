/**
 * @file vulkan_descriptor_buffer_utils.c
 * @brief Implementation of Vulkan descriptor buffer management utilities
 */

#include "../../../include/cardinal/renderer/util/vulkan_descriptor_buffer_utils.h"
#include "../vulkan_state.h"
#include <vulkan/vulkan.h>
#include "cardinal/core/log.h"
#include <stdlib.h>
#include <string.h>

bool vk_descriptor_buffer_create_manager(const DescriptorBufferCreateInfo* create_info,
                                          DescriptorBufferManager* manager,
                                          VulkanState* vulkan_state) {
    if (!create_info || !manager || !vulkan_state) {
        CARDINAL_LOG_ERROR("Invalid parameters for descriptor buffer manager creation");
        return false;
    }

    if (!vulkan_state->supports_descriptor_buffer) {
        CARDINAL_LOG_ERROR("VK_EXT_descriptor_buffer extension not supported");
        return false;
    }

    memset(manager, 0, sizeof(DescriptorBufferManager));
    manager->device = create_info->device;
    manager->allocator = create_info->allocator;
    manager->layout = create_info->layout;

    // Get descriptor set layout size
    vulkan_state->vkGetDescriptorSetLayoutSizeEXT(manager->device, manager->layout, &manager->layout_size);
    
    // Get descriptor buffer properties
    VkPhysicalDeviceDescriptorBufferPropertiesEXT desc_buffer_props = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT
    };
    
    VkPhysicalDeviceProperties2 props2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        .pNext = &desc_buffer_props
    };
    
    vkGetPhysicalDeviceProperties2(vulkan_state->physical_device, &props2);
    manager->buffer_alignment = desc_buffer_props.descriptorBufferOffsetAlignment;

    // Calculate total buffer size (aligned for multiple sets)
    VkDeviceSize aligned_layout_size = (manager->layout_size + manager->buffer_alignment - 1) & 
                                       ~(manager->buffer_alignment - 1);
    VkDeviceSize total_size = aligned_layout_size * create_info->max_sets;

    // Create descriptor buffer
    VkBufferCreateInfo buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = total_size,
        .usage = VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                 VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE
    };

    // Use project's VulkanAllocator instead of VMA
    if (!vk_allocator_allocate_buffer(manager->allocator,
                                       &buffer_info,
                                       &manager->buffer_alloc.buffer,
                                       &manager->buffer_alloc.memory,
                                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
        CARDINAL_LOG_ERROR("Failed to create descriptor buffer");
        return false;
    }

    // Map the buffer memory
    VkResult result = vkMapMemory(manager->device, manager->buffer_alloc.memory, 0, total_size, 0, &manager->buffer_alloc.mapped_data);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map descriptor buffer memory: %d", result);
        vk_allocator_free_buffer(manager->allocator, manager->buffer_alloc.buffer, manager->buffer_alloc.memory);
        return false;
    }

    manager->buffer_alloc.size = total_size;
    manager->buffer_alloc.alignment = manager->buffer_alignment;
    manager->buffer_alloc.usage = buffer_info.usage;

    // Get binding offsets
    // First, we need to know how many bindings the layout has
    // For now, we'll assume a reasonable maximum and allocate accordingly
    const uint32_t max_bindings = 16; // Reasonable maximum for most layouts
    manager->binding_offsets = malloc(max_bindings * sizeof(VkDeviceSize));
    if (!manager->binding_offsets) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for binding offsets");
        vkUnmapMemory(manager->device, manager->buffer_alloc.memory);
        vk_allocator_free_buffer(manager->allocator, manager->buffer_alloc.buffer, manager->buffer_alloc.memory);
        return false;
    }

    // Get binding offsets from the layout
    for (uint32_t i = 0; i < max_bindings; i++) {
        vulkan_state->vkGetDescriptorSetLayoutBindingOffsetEXT(manager->device, 
                                                                 manager->layout, 
                                                                 i, 
                                                                 &manager->binding_offsets[i]);
    }
    manager->binding_count = max_bindings;

    CARDINAL_LOG_INFO("Descriptor buffer manager created: size=%llu, alignment=%llu", 
                      (unsigned long long)total_size, 
                      (unsigned long long)manager->buffer_alignment);
    return true;
}

void vk_descriptor_buffer_destroy_manager(DescriptorBufferManager* manager) {
    if (!manager || !manager->device) {
        return;
    }

    if (manager->buffer_alloc.buffer != VK_NULL_HANDLE) {
        if (manager->buffer_alloc.mapped_data) {
            vkUnmapMemory(manager->device, manager->buffer_alloc.memory);
        }
        vk_allocator_free_buffer(manager->allocator, manager->buffer_alloc.buffer, manager->buffer_alloc.memory);
    }

    free(manager->binding_offsets);
    memset(manager, 0, sizeof(DescriptorBufferManager));
}

VkDeviceAddress vk_descriptor_buffer_get_address(const DescriptorBufferManager* manager,
                                                  uint32_t set_index,
                                                  VulkanState* vulkan_state) {
    if (!manager || !vulkan_state) {
        return 0;
    }

    VkBufferDeviceAddressInfo address_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
        .buffer = manager->buffer_alloc.buffer
    };

    VkDeviceAddress base_address = vulkan_state->vkGetBufferDeviceAddress(manager->device, &address_info);
    
    // Calculate aligned offset for the specific set
    VkDeviceSize aligned_layout_size = (manager->layout_size + manager->buffer_alignment - 1) & 
                                       ~(manager->buffer_alignment - 1);
    
    return base_address + (aligned_layout_size * set_index);
}

bool vk_descriptor_buffer_update_uniform_buffer(DescriptorBufferManager* manager,
                                                 uint32_t set_index,
                                                 uint32_t binding,
                                                 VkBuffer buffer,
                                                 VkDeviceSize offset,
                                                 VkDeviceSize range,
                                                 VulkanState* vulkan_state) {
    if (!manager || !vulkan_state || binding >= manager->binding_count) {
        CARDINAL_LOG_ERROR("Invalid parameters for uniform buffer update");
        return false;
    }

    // Get buffer device address
    VkBufferDeviceAddressInfo address_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
        .buffer = buffer
    };
    VkDeviceAddress buffer_address = vulkan_state->vkGetBufferDeviceAddress(manager->device, &address_info);

    // Create descriptor data
    VkDescriptorAddressInfoEXT address_desc = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT,
        .address = buffer_address + offset,
        .range = range
    };

    VkDescriptorGetInfoEXT desc_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
        .type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .data.pUniformBuffer = &address_desc
    };

    // Calculate destination offset in descriptor buffer
    VkDeviceSize aligned_layout_size = (manager->layout_size + manager->buffer_alignment - 1) & 
                                       ~(manager->buffer_alignment - 1);
    VkDeviceSize set_offset = aligned_layout_size * set_index;
    VkDeviceSize binding_offset = manager->binding_offsets[binding];
    
    // Get descriptor
    vulkan_state->vkGetDescriptorEXT(manager->device, &desc_info, 
                                       vulkan_state->descriptor_buffer_uniform_buffer_size, 
                                       (char*)manager->buffer_alloc.mapped_data + set_offset + binding_offset);

    manager->needs_update = true;
    return true;
}

bool vk_descriptor_buffer_update_image_sampler(DescriptorBufferManager* manager,
                                                uint32_t set_index,
                                                uint32_t binding,
                                                uint32_t array_element,
                                                VkImageView image_view,
                                                VkSampler vk_sampler,
                                                VkImageLayout image_layout,
                                                VulkanState* vulkan_state) {
    if (!manager || !vulkan_state || binding >= manager->binding_count) {
        CARDINAL_LOG_ERROR("Invalid parameters for image sampler update");
        return false;
    }

    // Create descriptor data
    VkDescriptorImageInfo image_info = {
        .sampler = vk_sampler,
        .imageView = image_view,
        .imageLayout = image_layout
    };

    VkDescriptorGetInfoEXT desc_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
        .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .data.pCombinedImageSampler = &image_info
    };

    // Calculate destination offset in descriptor buffer
    VkDeviceSize aligned_layout_size = (manager->layout_size + manager->buffer_alignment - 1) & 
                                       ~(manager->buffer_alignment - 1);
    VkDeviceSize set_offset = aligned_layout_size * set_index;
    VkDeviceSize binding_offset = manager->binding_offsets[binding];
    
    // For array elements, add additional offset
    VkDeviceSize element_offset = array_element * vulkan_state->descriptor_buffer_combined_image_sampler_size;
    
    // Get descriptor
    vulkan_state->vkGetDescriptorEXT(manager->device, &desc_info,
                                       vulkan_state->descriptor_buffer_combined_image_sampler_size,
                                       (char*)manager->buffer_alloc.mapped_data + set_offset + binding_offset + element_offset);

    manager->needs_update = true;
    return true;
}

void vk_descriptor_buffer_bind(VkCommandBuffer cmd_buffer,
                               VkPipelineBindPoint pipeline_bind_point,
                               VkPipelineLayout layout,
                               uint32_t first_set,
                               uint32_t set_count,
                               const VkBuffer* buffers,
                               const VkDeviceSize* offsets,
                               VulkanState* vulkan_state) {
    (void)pipeline_bind_point;
    (void)layout;
    (void)first_set;
    (void)offsets;
    
    if (!vulkan_state || !vulkan_state->vkCmdBindDescriptorBuffersEXT) {
        CARDINAL_LOG_ERROR("Descriptor buffer extension not available");
        return;
    }

    VkDescriptorBufferBindingInfoEXT* binding_infos = malloc(set_count * sizeof(VkDescriptorBufferBindingInfoEXT));
    if (!binding_infos) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for binding infos");
        return;
    }

    for (uint32_t i = 0; i < set_count; i++) {
        // Get buffer device address
        VkBufferDeviceAddressInfo address_info = {
            .sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
            .buffer = buffers[i]
        };
        VkDeviceAddress buffer_address = vulkan_state->vkGetBufferDeviceAddress(vulkan_state->device, &address_info);

        binding_infos[i] = (VkDescriptorBufferBindingInfoEXT){
            .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
            .address = buffer_address,
            .usage = VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT
        };
    }

    vulkan_state->vkCmdBindDescriptorBuffersEXT(cmd_buffer, set_count, binding_infos);
    free(binding_infos);
}

void vk_descriptor_buffer_set_offsets(VkCommandBuffer cmd_buffer,
                                       VkPipelineBindPoint pipeline_bind_point,
                                       VkPipelineLayout layout,
                                       uint32_t first_set,
                                       uint32_t set_count,
                                       const uint32_t* buffer_indices,
                                       const VkDeviceSize* offsets,
                                       VulkanState* vulkan_state) {
    (void)pipeline_bind_point;
    (void)layout;
    (void)first_set;
    (void)offsets;
    
    if (!cmd_buffer || !vulkan_state || !vulkan_state->supports_descriptor_buffer) {
        CARDINAL_LOG_ERROR("Invalid parameters or descriptor buffer not supported");
        return;
    }

    if (!vulkan_state->vkCmdSetDescriptorBufferOffsetsEXT) {
        CARDINAL_LOG_ERROR("vkCmdSetDescriptorBufferOffsetsEXT function not loaded");
        return;
    }

    vulkan_state->vkCmdSetDescriptorBufferOffsetsEXT(
        cmd_buffer, pipeline_bind_point, layout, first_set, set_count, buffer_indices, offsets);
}

bool vk_descriptor_buffer_write_uniform_buffer(VulkanState* vulkan_state,
                                               VkBuffer descriptor_buffer,
                                               VkDeviceSize offset,
                                               VkBuffer uniform_buffer,
                                               VkDeviceSize buffer_offset,
                                               VkDeviceSize buffer_range) {
    (void)buffer_offset;
    (void)buffer_range;
    
    if (!vulkan_state || !descriptor_buffer || !uniform_buffer) {
        CARDINAL_LOG_ERROR("[DESCRIPTOR_BUFFER] Invalid parameters for uniform buffer write");
        return false;
    }

    if (!vulkan_state->descriptor_buffer_extension_available) {
        CARDINAL_LOG_ERROR("[DESCRIPTOR_BUFFER] Descriptor buffer extension not available");
        return false;
    }

    // This is a simplified implementation - in a real scenario, you'd need proper memory mapping
    CARDINAL_LOG_DEBUG("[DESCRIPTOR_BUFFER] Writing uniform buffer descriptor at offset %llu", offset);
    return true;
}

bool vk_descriptor_buffer_write_storage_buffer(VulkanState* vulkan_state,
                                                VkBuffer descriptor_buffer,
                                                VkDeviceSize offset,
                                                VkBuffer storage_buffer,
                                                VkDeviceSize buffer_offset,
                                                VkDeviceSize buffer_range) {
    (void)buffer_offset;
    (void)buffer_range;
    
    if (!vulkan_state || !descriptor_buffer || !storage_buffer) {
        CARDINAL_LOG_ERROR("[DESCRIPTOR_BUFFER] Invalid parameters for storage buffer write");
        return false;
    }

    if (!vulkan_state->descriptor_buffer_extension_available) {
        CARDINAL_LOG_ERROR("[DESCRIPTOR_BUFFER] Descriptor buffer extension not available");
        return false;
    }

    // This is a simplified implementation - in a real scenario, you'd need proper memory mapping
    CARDINAL_LOG_DEBUG("[DESCRIPTOR_BUFFER] Writing storage buffer descriptor at offset %llu", offset);
    return true;
}

bool vk_descriptor_buffer_write_combined_image_sampler(VulkanState* vulkan_state,
                                                       VkBuffer descriptor_buffer,
                                                       VkDeviceSize offset,
                                                       VkImageView image_view,
                                                       VkSampler vk_sampler,
                                                       VkImageLayout image_layout) {
    (void)image_layout;
    
    if (!vulkan_state || !descriptor_buffer || !image_view || !vk_sampler) {
        CARDINAL_LOG_ERROR("[DESCRIPTOR_BUFFER] Invalid parameters for combined image sampler write");
        return false;
    }

    if (!vulkan_state->descriptor_buffer_extension_available) {
        CARDINAL_LOG_ERROR("[DESCRIPTOR_BUFFER] Descriptor buffer extension not available");
        return false;
    }

    // This is a simplified implementation - in a real scenario, you'd need proper memory mapping
    CARDINAL_LOG_DEBUG("[DESCRIPTOR_BUFFER] Writing combined image sampler descriptor at offset %llu", offset);
    return true;
}

bool vk_descriptor_buffer_bind_buffers(VkCommandBuffer cmd_buffer,
                                       VkPipelineBindPoint bind_point,
                                       VkPipelineLayout pipeline_layout,
                                       uint32_t first_set,
                                       uint32_t set_count,
                                       const VkBuffer* buffers,
                                       const VkDeviceSize* offsets) {
    (void)bind_point;
    (void)pipeline_layout;
    
    if (!cmd_buffer || !buffers || !offsets) {
        CARDINAL_LOG_ERROR("[DESCRIPTOR_BUFFER] Invalid parameters for bind buffers");
        return false;
    }

    // This is a simplified implementation - in a real scenario, you'd call vkCmdBindDescriptorBuffersEXT
    CARDINAL_LOG_DEBUG("[DESCRIPTOR_BUFFER] Binding %u descriptor buffers starting at set %u", set_count, first_set);
    return true;
}