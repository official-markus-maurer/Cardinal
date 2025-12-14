#ifndef VULKAN_STATE_H
#define VULKAN_STATE_H

#include "cardinal/core/memory.h"
#include "cardinal/renderer/renderer.h"
#include "cardinal/renderer/vulkan_mt.h"
#include "cardinal/renderer/vulkan_pbr.h"
#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

// New modular headers
#include "vulkan_commands_struct.h"
#include "vulkan_context_struct.h"
#include "vulkan_pipelines_struct.h"
#include "vulkan_recovery_struct.h"
#include "vulkan_swapchain_struct.h"
#include "vulkan_sync_struct.h"

// VK_KHR_maintenance8 extension constants
#ifndef VK_DEPENDENCY_QUEUE_FAMILY_OWNERSHIP_TRANSFER_USE_ALL_STAGES_BIT_KHR
#define VK_DEPENDENCY_QUEUE_FAMILY_OWNERSHIP_TRANSFER_USE_ALL_STAGES_BIT_KHR   \
  0x00000008
#endif

#ifdef __cplusplus
extern "C" {
#endif

#include "cardinal/renderer/vulkan_compute.h"
#include "cardinal/renderer/vulkan_mesh_shader.h"
#include "cardinal/renderer/vulkan_sync_manager.h"

// Forward declarations
struct CardinalScene;

typedef struct VulkanAllocator VulkanAllocator;

// Vulkan-specific allocator, uses maintenance4 queries (Vulkan 1.3 required)
// with optional maintenance8 extension support for enhanced features
struct VulkanAllocator {
  VkDevice device;
  VkPhysicalDevice physical_device;
  // Function pointers - maintenance4 (required)
  PFN_vkGetDeviceBufferMemoryRequirements fpGetDeviceBufferMemReq;
  PFN_vkGetDeviceImageMemoryRequirements fpGetDeviceImageMemReq;
  PFN_vkGetBufferDeviceAddress fpGetBufferDeviceAddress;
  // Function pointers - maintenance8
  PFN_vkGetDeviceBufferMemoryRequirementsKHR fpGetDeviceBufferMemReqKHR;
  PFN_vkGetDeviceImageMemoryRequirementsKHR fpGetDeviceImageMemReqKHR;
  bool supports_maintenance8;
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
                       PFN_vkGetBufferDeviceAddress bufDevAddr,
                       PFN_vkGetDeviceBufferMemoryRequirementsKHR bufReqKHR,
                       PFN_vkGetDeviceImageMemoryRequirementsKHR imgReqKHR,
                       bool supports_maintenance8);
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

// Maintenance8 enhanced synchronization utilities
typedef struct VkQueueFamilyOwnershipTransferInfo {
  uint32_t src_queue_family;
  uint32_t dst_queue_family;
  VkPipelineStageFlags2 src_stage_mask;
  VkPipelineStageFlags2 dst_stage_mask;
  VkAccessFlags2 src_access_mask;
  VkAccessFlags2 dst_access_mask;
  bool use_maintenance8_enhancement;
} VkQueueFamilyOwnershipTransferInfo;

// Enhanced queue family ownership transfer functions
bool vk_create_enhanced_image_barrier(
    const VkQueueFamilyOwnershipTransferInfo *transfer_info, VkImage image,
    VkImageLayout old_layout, VkImageLayout new_layout,
    VkImageSubresourceRange subresource_range,
    VkImageMemoryBarrier2 *out_barrier);

bool vk_create_enhanced_buffer_barrier(
    const VkQueueFamilyOwnershipTransferInfo *transfer_info, VkBuffer buffer,
    VkDeviceSize offset, VkDeviceSize size,
    VkBufferMemoryBarrier2 *out_barrier);

bool vk_record_enhanced_ownership_transfer(
    VkCommandBuffer cmd,
    const VkQueueFamilyOwnershipTransferInfo *transfer_info,
    uint32_t image_barrier_count, const VkImageMemoryBarrier2 *image_barriers,
    uint32_t buffer_barrier_count,
    const VkBufferMemoryBarrier2 *buffer_barriers,
    PFN_vkCmdPipelineBarrier2 vkCmdPipelineBarrier2_func);

// Helper function to create queue family ownership transfer info
bool vk_create_queue_family_transfer_info(
    uint32_t src_queue_family, uint32_t dst_queue_family,
    VkPipelineStageFlags2 src_stage_mask, VkPipelineStageFlags2 dst_stage_mask,
    VkAccessFlags2 src_access_mask, VkAccessFlags2 dst_access_mask,
    bool supports_maintenance8,
    VkQueueFamilyOwnershipTransferInfo *out_transfer_info);

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
  // Modular subsystems
  VulkanContext context;
  VulkanSwapchain swapchain;
  VulkanCommands commands;
  VulkanFrameSync sync;
  VulkanPipelines pipelines;
  VulkanRecovery recovery;

  // Unified Vulkan memory allocator
  VulkanAllocator allocator;

  // Centralized synchronization manager
  VulkanSyncManager *sync_manager;

  // UI callback
  void (*ui_record_callback)(VkCommandBuffer cmd);

  // Rendering mode state
  CardinalRenderingMode current_rendering_mode;

  // Scene mesh buffers
  GpuMesh *scene_meshes;
  uint32_t scene_mesh_count;

  // Scene
  const struct CardinalScene *current_scene;
  const struct CardinalScene *pending_scene_upload;
  bool scene_upload_pending;

  // Mesh shader draw data pending cleanup
  MeshShaderDrawData *pending_cleanup_draw_data;
  uint32_t pending_cleanup_count;
  uint32_t pending_cleanup_capacity;

} VulkanState;

// Shared internal functions
void destroy_scene_buffers(VulkanState *s);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_STATE_H
