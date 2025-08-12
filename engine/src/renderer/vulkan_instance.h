#ifndef VULKAN_INSTANCE_H
#define VULKAN_INSTANCE_H

#include <stdbool.h>
#include "vulkan_state.h"

struct CardinalWindow;

bool vk_create_instance(VulkanState* s);
bool vk_pick_physical_device(VulkanState* s);
bool vk_create_device(VulkanState* s);
bool vk_create_surface(VulkanState* s, struct CardinalWindow* window);
void vk_destroy_device_objects(VulkanState* s);

#endif // VULKAN_INSTANCE_H
