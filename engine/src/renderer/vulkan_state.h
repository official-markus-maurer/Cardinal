#ifndef VULKAN_STATE_H
#define VULKAN_STATE_H

#include "cardinal/core/memory.h"
#include "cardinal/renderer/renderer.h"
#include "cardinal/renderer/vulkan_pbr.h"
#include "cardinal/renderer/vulkan_mt.h"
#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declare scene for PBR
struct CardinalScene;

typedef struct VulkanAllocator VulkanAllocator;

// Vulkan-specific allocator, uses maintenance4 queries (Vulkan 1.3 required)
struct VulkanAllocator {
  VkDevice device;
  VkPhysicalDevice physical_device;
  // Function pointers (from Vulkan 1.3 core)
  PFN_vkGetDeviceBufferMemoryRequirements fpGetDeviceBufferMemReq;
  PFN_vkGetDeviceImageMemoryRequirements fpGetDeviceImageMemReq;
  PFN_vkGetBufferDeviceAddress fpGetBufferDeviceAddress;
  // Stats
  uint64_t total_device_mem_allocated;
  uint64_t total_device_mem_freed;
  // Thread safety
  cardinal_mutex_t allocation_mutex;
};

// Create/Destroy allocator
bool vk_allocator_init(VulkanAllocator *alloc, VkPhysicalDevice phys,
                       VkDevice dev,
                       PFN_vkGetDeviceBufferMemoryRequirements bufReq,
                       PFN_vkGetDeviceImageMemoryRequirements imgReq,
                       PFN_vkGetBufferDeviceAddress bufDevAddr);
void vk_allocator_shutdown(VulkanAllocator *alloc);

// Allocation helpers
bool vk_allocator_allocate_image(VulkanAllocator *alloc,
                                 const VkImageCreateInfo *image_ci,
                                 VkImage *out_image, VkDeviceMemory *out_memory,
                                 VkMemoryPropertyFlags required_props);

bool vk_allocator_allocate_buffer(VulkanAllocator *alloc,
                                  const VkBufferCreateInfo *buffer_ci,
                                  VkBuffer *out_buffer,
                                  VkDeviceMemory *out_memory,
                                  VkMemoryPropertyFlags required_props);

void vk_allocator_free_image(VulkanAllocator *alloc, VkImage image,
                             VkDeviceMemory memory);
void vk_allocator_free_buffer(VulkanAllocator *alloc, VkBuffer buffer,
                              VkDeviceMemory memory);

// Buffer device address support
VkDeviceAddress vk_allocator_get_buffer_device_address(VulkanAllocator *alloc,
                                                       VkBuffer buffer);

// Mesh representation for scene uploads
typedef struct GpuMesh {
  VkBuffer vbuf;
  VkDeviceMemory vmem;
  VkBuffer ibuf;
  VkDeviceMemory imem;
  uint32_t vtx_count;
  uint32_t idx_count;
  uint32_t vtx_stride;
} GpuMesh;

// Renderer state

typedef struct VulkanState {
  VkInstance instance;              /**< Vulkan instance handle. */
  VkPhysicalDevice physical_device; /**< Selected physical device. */
  VkDevice device;                  /**< Logical device handle. */
  VkQueue graphics_queue;           /**< Graphics queue. */
  VkQueue present_queue;            /**< Present queue. */
  uint32_t graphics_queue_family;   /**< Index of the graphics queue family. */
  uint32_t present_queue_family;    /**< Index of the present queue family. */

  // Added fields used by instance/swapchain setup
  VkSurfaceKHR surface; /**< Window surface handle. */
  VkDebugUtilsMessengerEXT
      debug_messenger; /**< Debug messenger for validation layers. */

  VkSwapchainKHR swapchain;    /**< Swapchain handle. */
  VkFormat swapchain_format;   /**< Swapchain image format. */
  VkExtent2D swapchain_extent; /**< Swapchain extent (width and height). */

  VkImage *swapchain_images;          /**< Array of swapchain images. */
  VkImageView *swapchain_image_views; /**< Array of swapchain image views. */
  uint32_t swapchain_image_count;     /**< Number of images in the swapchain. */

  VkFormat depth_format;             /**< Depth image format. */
  VkImage depth_image;               /**< Depth image handle. */
  VkDeviceMemory depth_image_memory; /**< Memory for the depth image. */
  VkImageView depth_image_view;      /**< Image view for the depth image. */

  VkCommandPool *command_pools;     /**< Command pools per frame in flight
                                       (allocated dynamically). */
  VkCommandBuffer *command_buffers; /**< Primary command buffers for each frame. */
  VkCommandBuffer *secondary_command_buffers; /**< Secondary command buffers for double buffering. */
  uint32_t current_command_buffer_index; /**< Index for double buffering (0 or 1). */

  uint32_t max_frames_in_flight; /**< Maximum number of frames in flight. */
  uint32_t current_frame;        /**< Index of the current frame. */

  VkSemaphore *image_acquired_semaphores; /**< Semaphores signaled when an image
                                             is acquired from the swapchain. */
  VkSemaphore *render_finished_semaphores; /**< Binary semaphores signaled when
                                              rendering completes. */
  VkFence *in_flight_fences; /**< Fences for CPU-GPU synchronization per frame. */
  VkSemaphore
      timeline_semaphore; /**< Timeline semaphore for frame synchronization. */
  uint64_t current_frame_value;   /**< Timeline value for the current frame. */
  uint64_t image_available_value; /**< Timeline signal value after image
                                     acquisition. */
  uint64_t render_complete_value; /**< Timeline signal value after rendering
                                     completes. */

  // Flags indicating supported features
  bool supports_dynamic_rendering; /**< True when dynamic rendering is available
                                      and enabled. */
  bool supports_vulkan_12_features;    /**< True when Vulkan 1.2 features are
                                        * available and enabled.
                                        */
  bool supports_vulkan_13_features;    /**< True when Vulkan 1.3 features are
                                        * available and enabled.
                                        */
  bool supports_vulkan_14_features;    /**< True when Vulkan 1.4 features are
                                        * available and enabled.
                                        */
  bool supports_maintenance4;          /**< True when Vulkan 1.3 maintenance4 is
                                          available and enabled. */
  bool supports_buffer_device_address; /**< True when buffer device address is
                                          available and enabled. */

  // Dynamic rendering function pointers (core in Vulkan 1.3)
  PFN_vkCmdBeginRendering
      vkCmdBeginRendering; /**< Function pointer for vkCmdBeginRendering. */
  PFN_vkCmdEndRendering
      vkCmdEndRendering; /**< Function pointer for vkCmdEndRendering. */

  // Synchronization2 function pointers (Vulkan 1.3 core)
  PFN_vkCmdPipelineBarrier2
      vkCmdPipelineBarrier2; /**< Function pointer for vkCmdPipelineBarrier2. */
  PFN_vkQueueSubmit2
      vkQueueSubmit2; /**< Function pointer for vkQueueSubmit2. */

  /** Timeline semaphore function pointers (Vulkan 1.2 core). */
  PFN_vkWaitSemaphores
      vkWaitSemaphores; /**< Function pointer for vkWaitSemaphores. */
  PFN_vkSignalSemaphore
      vkSignalSemaphore; /**< Function pointer for vkSignalSemaphore. */
  PFN_vkGetSemaphoreCounterValue
      vkGetSemaphoreCounterValue; /**< Function pointer for
                                     vkGetSemaphoreCounterValue. */

  /** Maintenance4 device-level memory requirements queries (Vulkan 1.3 core).
   */
  PFN_vkGetDeviceBufferMemoryRequirements
      vkGetDeviceBufferMemoryRequirements; /**< Function pointer for
                                              vkGetDeviceBufferMemoryRequirements.
                                            */
  PFN_vkGetDeviceImageMemoryRequirements
      vkGetDeviceImageMemoryRequirements; /**< Function pointer for
                                             vkGetDeviceImageMemoryRequirements.
                                           */

  /** Buffer device address function pointers (Vulkan 1.2 core, required
   * in 1.3). */
  PFN_vkGetBufferDeviceAddress
      vkGetBufferDeviceAddress; /**< Function pointer for
                                   vkGetBufferDeviceAddress. */

  // Simple pipeline removed - PBR is the only rendering path

  // Image layout tracking
  bool depth_layout_initialized; /**< Whether depth image layout has been
                                    transitioned. */
  bool *swapchain_image_layout_initialized; /**< Whether each swapchain image
                                               has an initialized layout. */

  // Unified Vulkan memory allocator
  VulkanAllocator allocator;

  // UI callback
  void (*ui_record_callback)(VkCommandBuffer cmd);

  // Rendering mode state
  CardinalRenderingMode current_rendering_mode;

  // Pipeline states for different rendering modes
  bool use_pbr_pipeline;
  VulkanPBRPipeline pbr_pipeline;

  // UV and wireframe pipelines (simplified versions)
  VkPipeline uv_pipeline;
  VkPipelineLayout uv_pipeline_layout;
  VkPipeline wireframe_pipeline;
  VkPipelineLayout wireframe_pipeline_layout;

  // Shared descriptor set layout for simple pipelines
  VkDescriptorSetLayout simple_descriptor_layout;
  VkDescriptorPool simple_descriptor_pool;
  VkDescriptorSet simple_descriptor_set;

  // Shared uniform buffer for simple pipelines
  VkBuffer simple_uniform_buffer;
  VkDeviceMemory simple_uniform_buffer_memory;
  void *simple_uniform_buffer_mapped;

  // Scene mesh buffers
  GpuMesh *scene_meshes;
  uint32_t scene_mesh_count;

  // Scene
  const struct CardinalScene *current_scene;

  // Device loss recovery state
  bool device_lost;                    /**< True when device loss has been detected. */
  bool recovery_in_progress;           /**< True when recovery is currently being attempted. */
  uint32_t recovery_attempt_count;     /**< Number of recovery attempts made. */
  uint32_t max_recovery_attempts;      /**< Maximum number of recovery attempts before giving up. */
  struct CardinalWindow* window;       /**< Window reference for recovery operations. */
  
  // Recovery callbacks
  void (*device_loss_callback)(void* user_data);     /**< Called when device loss is detected. */
  void (*recovery_complete_callback)(void* user_data, bool success); /**< Called when recovery completes. */
  void* recovery_callback_user_data;   /**< User data for recovery callbacks. */
  
  // Swapchain optimization state
  bool swapchain_recreation_pending;   /**< True when swapchain recreation is needed on next frame. */
  uint64_t last_swapchain_recreation_time; /**< Timestamp of last swapchain recreation (in milliseconds). */
  uint32_t swapchain_recreation_count; /**< Number of swapchain recreations performed. */
  uint32_t consecutive_recreation_failures; /**< Number of consecutive recreation failures. */
  bool frame_pacing_enabled;           /**< True when frame pacing is enabled to reduce recreation frequency. */
} VulkanState;

#ifdef __cplusplus
}
#endif

#endif // VULKAN_STATE_H
