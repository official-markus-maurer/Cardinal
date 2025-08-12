#ifndef VULKAN_COMMANDS_H
#define VULKAN_COMMANDS_H

#include <stdbool.h>
#include "vulkan_state.h"

bool vk_create_commands_sync(VulkanState* s);
bool vk_recreate_images_in_flight(VulkanState* s);
void vk_destroy_commands_sync(VulkanState* s);
void vk_record_cmd(VulkanState* s, uint32_t image_index);

#endif // VULKAN_COMMANDS_H
