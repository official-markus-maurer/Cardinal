#ifndef VULKAN_DESCRIPTOR_BUFFER_UTILS_MINIMAL_H
#define VULKAN_DESCRIPTOR_BUFFER_UTILS_MINIMAL_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct DescriptorBufferManager DescriptorBufferManager;

// Essential function declarations
bool vk_descriptor_buffer_write_storage_buffer(
    void *vulkan_state, void *descriptor_buffer, VkDeviceSize offset,
    VkBuffer buffer, VkDeviceSize buffer_offset, VkDeviceSize range);

bool vk_descriptor_buffer_write_uniform_buffer(
    void *vulkan_state, void *descriptor_buffer, VkDeviceSize offset,
    VkBuffer buffer, VkDeviceSize buffer_offset, VkDeviceSize range);

bool vk_descriptor_buffer_write_combined_image_sampler(
    void *vulkan_state, void *descriptor_buffer, VkDeviceSize offset,
    VkImageView image_view, VkSampler sampler, VkImageLayout image_layout);

void vk_descriptor_buffer_bind_buffers(VkCommandBuffer cmd_buffer,
                                       VkPipelineBindPoint bind_point,
                                       VkPipelineLayout pipeline_layout,
                                       uint32_t first_set, uint32_t set_count,
                                       const VkBuffer *buffers,
                                       const VkDeviceSize *offsets);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_DESCRIPTOR_BUFFER_UTILS_MINIMAL_H
