#ifndef VULKAN_PIPELINE_H
#define VULKAN_PIPELINE_H

#include <stdbool.h>
#include "vulkan_state.h"

bool vk_create_renderpass_pipeline(VulkanState* s);
void vk_destroy_renderpass_pipeline(VulkanState* s);

#endif // VULKAN_PIPELINE_H
