#ifndef VULKAN_SWAPCHAIN_STRUCT_H
#define VULKAN_SWAPCHAIN_STRUCT_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

typedef struct VulkanSwapchain {
  VkSwapchainKHR handle;
  VkFormat format;
  VkExtent2D extent;
  VkImage *images;
  VkImageView *image_views;
  uint32_t image_count;

  // Depth resources
  VkFormat depth_format;
  VkImage depth_image;
  VkDeviceMemory depth_image_memory;
  VkImageView depth_image_view;
  bool depth_layout_initialized;
  bool *image_layout_initialized;

  // Optimization state
  bool recreation_pending;
  uint64_t last_recreation_time;
  uint32_t recreation_count;
  uint32_t consecutive_recreation_failures;
  bool frame_pacing_enabled;
  bool skip_present;
  bool headless_mode;

  // Resize state
  bool window_resize_pending;
  uint32_t pending_width;
  uint32_t pending_height;
} VulkanSwapchain;

#endif // VULKAN_SWAPCHAIN_STRUCT_H
