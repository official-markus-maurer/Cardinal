#ifndef VULKAN_SWAPCHAIN_H
#define VULKAN_SWAPCHAIN_H

#include <stdbool.h>
#include "vulkan_state.h"

bool vk_create_swapchain(VulkanState* s);
void vk_destroy_swapchain(VulkanState* s);
bool vk_recreate_swapchain(VulkanState* s);

#endif // VULKAN_SWAPCHAIN_H

