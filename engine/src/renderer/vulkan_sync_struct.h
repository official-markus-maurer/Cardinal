#ifndef VULKAN_SYNC_STRUCT_H
#define VULKAN_SYNC_STRUCT_H

#include "cardinal/renderer/vulkan_sync_manager.h"
#include <stdint.h>
#include <vulkan/vulkan.h>

typedef struct VulkanFrameSync {
  VkSemaphore *image_acquired_semaphores;
  VkSemaphore *render_finished_semaphores;
  VkFence *in_flight_fences;

  VkSemaphore timeline_semaphore;
  uint64_t current_frame_value;
  uint64_t image_available_value;
  uint64_t render_complete_value;

  uint32_t max_frames_in_flight;
  uint32_t current_frame;

  VulkanSyncManager *manager;
} VulkanFrameSync;

#endif
