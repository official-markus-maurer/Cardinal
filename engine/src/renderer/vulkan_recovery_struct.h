#ifndef VULKAN_RECOVERY_STRUCT_H
#define VULKAN_RECOVERY_STRUCT_H

#include <stdbool.h>
#include <stdint.h>

// Forward declaration
struct CardinalWindow;

typedef struct VulkanRecovery {
  bool device_lost;
  bool recovery_in_progress;
  uint32_t attempt_count;
  uint32_t max_attempts;
  struct CardinalWindow *window;

  // Callbacks
  void (*device_loss_callback)(void *user_data);
  void (*recovery_complete_callback)(void *user_data, bool success);
  void *callback_user_data;
} VulkanRecovery;

#endif
