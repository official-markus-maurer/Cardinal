#ifndef VULKAN_COMMANDS_STRUCT_H
#define VULKAN_COMMANDS_STRUCT_H

#include <stdint.h>
#include <vulkan/vulkan.h>

typedef struct VulkanCommands {
  VkCommandPool *pools;               // Per frame
  VkCommandBuffer *buffers;           // Per frame
  VkCommandBuffer *secondary_buffers; // Per frame (double buffering)
  uint32_t current_buffer_index;
} VulkanCommands;

#endif
