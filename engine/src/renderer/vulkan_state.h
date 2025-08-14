#ifndef VULKAN_STATE_H
#define VULKAN_STATE_H

#include <vulkan/vulkan.h>
#include <stdbool.h>
#include <stdint.h>
#include "cardinal/core/memory.h"
#include "cardinal/renderer/vulkan_pbr.h"

#ifdef __cplusplus
extern "C" {
#endif

// Forward declare scene for PBR
struct CardinalScene;

typedef struct VulkanAllocator VulkanAllocator;

// Vulkan-specific allocator, integrates maintenance4 queries and tracks device memory
struct VulkanAllocator {
    VkDevice device;
    VkPhysicalDevice physical_device;
    bool use_maintenance4;
    // Function pointers (from Vulkan 1.3 core)
    PFN_vkGetDeviceBufferMemoryRequirements fpGetDeviceBufferMemReq;
    PFN_vkGetDeviceImageMemoryRequirements fpGetDeviceImageMemReq;
    // Stats
    uint64_t total_device_mem_allocated;
    uint64_t total_device_mem_freed;
};

// Create/Destroy allocator
bool vk_allocator_init(VulkanAllocator* alloc, VkPhysicalDevice phys, VkDevice dev, bool maintenance4,
                       PFN_vkGetDeviceBufferMemoryRequirements bufReq,
                       PFN_vkGetDeviceImageMemoryRequirements imgReq);
void vk_allocator_shutdown(VulkanAllocator* alloc);

// Allocation helpers
bool vk_allocator_allocate_image(VulkanAllocator* alloc,
                                 const VkImageCreateInfo* image_ci,
                                 VkImage* out_image,
                                 VkDeviceMemory* out_memory,
                                 VkMemoryPropertyFlags required_props);

bool vk_allocator_allocate_buffer(VulkanAllocator* alloc,
                                  const VkBufferCreateInfo* buffer_ci,
                                  VkBuffer* out_buffer,
                                  VkDeviceMemory* out_memory,
                                  VkMemoryPropertyFlags required_props);

void vk_allocator_free_image(VulkanAllocator* alloc, VkImage image, VkDeviceMemory memory);
void vk_allocator_free_buffer(VulkanAllocator* alloc, VkBuffer buffer, VkDeviceMemory memory);

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
    VkInstance instance;                    /**< Vulkan instance handle. */
    VkPhysicalDevice physical_device;       /**< Selected physical device. */
    VkDevice device;                        /**< Logical device handle. */
    VkQueue graphics_queue;                 /**< Graphics queue. */
    VkQueue present_queue;                  /**< Present queue. */
    uint32_t graphics_queue_family;         /**< Index of the graphics queue family. */
    uint32_t present_queue_family;          /**< Index of the present queue family. */

    // Added fields used by instance/swapchain setup
    VkSurfaceKHR surface;                   /**< Window surface handle. */
    VkDebugUtilsMessengerEXT debug_messenger; /**< Debug messenger for validation layers. */

    VkSwapchainKHR swapchain;               /**< Swapchain handle. */
    VkFormat swapchain_format;              /**< Swapchain image format. */
    VkExtent2D swapchain_extent;            /**< Swapchain extent (width and height). */

    VkImage* swapchain_images;              /**< Array of swapchain images. */
    VkImageView* swapchain_image_views;     /**< Array of swapchain image views. */
    uint32_t swapchain_image_count;         /**< Number of images in the swapchain. */

    VkFormat depth_format;                  /**< Depth image format. */
    VkImage depth_image;                    /**< Depth image handle. */
    VkDeviceMemory depth_image_memory;      /**< Memory for the depth image. */
    VkImageView depth_image_view;           /**< Image view for the depth image. */

    VkCommandPool* command_pools;           /**< Command pools per frame in flight (allocated dynamically). */
    VkCommandBuffer* command_buffers;       /**< Command buffers for each frame. */

    uint32_t max_frames_in_flight;          /**< Maximum number of frames in flight. */
    uint32_t current_frame;                 /**< Index of the current frame. */

    VkSemaphore* image_acquired_semaphores; /**< Semaphores signaled when an image is acquired from the swapchain. */
    VkSemaphore timeline_semaphore;         /**< Timeline semaphore for frame synchronization. */
    uint64_t current_frame_value;           /**< Timeline value for the current frame. */
    uint64_t image_available_value;         /**< Timeline signal value after image acquisition. */
    uint64_t render_complete_value;         /**< Timeline signal value after rendering completes. */

    // Flags indicating supported features
    bool supports_dynamic_rendering;        /**< True when dynamic rendering is available and enabled. */
    bool supports_vulkan_12_features;       /**< True when Vulkan 1.2 features are available and enabled. */
    bool supports_vulkan_13_features;       /**< True when Vulkan 1.3 features are available and enabled. */
    bool supports_maintenance4;             /**< True when Vulkan 1.3 maintenance4 is available and enabled. */

    // Dynamic rendering function pointers (core in Vulkan 1.3)
    PFN_vkCmdBeginRendering vkCmdBeginRendering;     /**< Function pointer for vkCmdBeginRendering. */
    PFN_vkCmdEndRendering vkCmdEndRendering;         /**< Function pointer for vkCmdEndRendering. */

    // Synchronization2 function pointers (Vulkan 1.3 core)
    PFN_vkCmdPipelineBarrier2 vkCmdPipelineBarrier2; /**< Function pointer for vkCmdPipelineBarrier2. */
    PFN_vkQueueSubmit2 vkQueueSubmit2;               /**< Function pointer for vkQueueSubmit2. */

    /** Timeline semaphore function pointers (Vulkan 1.2 core). */
    PFN_vkWaitSemaphores vkWaitSemaphores;           /**< Function pointer for vkWaitSemaphores. */
    PFN_vkSignalSemaphore vkSignalSemaphore;         /**< Function pointer for vkSignalSemaphore. */
    PFN_vkGetSemaphoreCounterValue vkGetSemaphoreCounterValue; /**< Function pointer for vkGetSemaphoreCounterValue. */

    /** Maintenance4 device-level memory requirements queries (Vulkan 1.3 core). */
    PFN_vkGetDeviceBufferMemoryRequirements vkGetDeviceBufferMemoryRequirements;   /**< Function pointer for vkGetDeviceBufferMemoryRequirements. */
    PFN_vkGetDeviceImageMemoryRequirements vkGetDeviceImageMemoryRequirements;     /**< Function pointer for vkGetDeviceImageMemoryRequirements. */

    // Pipeline objects for simple pipeline path (non-PBR)
    VkPipelineLayout pipeline_layout;        /**< Basic pipeline layout. */
    VkPipeline pipeline;                     /**< Basic graphics pipeline. */

    // Image layout tracking
    bool depth_layout_initialized;          /**< Whether depth image layout has been transitioned. */
    bool* swapchain_image_layout_initialized; /**< Whether each swapchain image has an initialized layout. */

    // Unified Vulkan memory allocator
    VulkanAllocator allocator;
    
    // UI callback
    void (*ui_record_callback)(VkCommandBuffer cmd);

    // PBR pipeline state
    bool use_pbr_pipeline;
    VulkanPBRPipeline pbr_pipeline;

    // Scene mesh buffers
    GpuMesh* scene_meshes;
    uint32_t scene_mesh_count;

    // Scene
    const struct CardinalScene* current_scene;
} VulkanState;

#ifdef __cplusplus
}
#endif

#endif // VULKAN_STATE_H
