#ifndef VULKAN_STATE_H
#define VULKAN_STATE_H

#include <stdint.h>
#include <GLFW/glfw3.h>
#include <vulkan/vulkan.h>
#include <cardinal/renderer/vulkan_pbr.h>

// Forward declarations
struct CardinalWindow;
typedef struct CardinalWindow CardinalWindow;

/**
 * @brief GPU mesh buffers for a loaded scene.
 */
typedef struct GpuMesh {
    VkBuffer vbuf;          /**< Vertex buffer. */
    VkDeviceMemory vmem;    /**< Vertex memory. */
    VkBuffer ibuf;          /**< Index buffer. */
    VkDeviceMemory imem;    /**< Index memory. */
    uint32_t vtx_count;     /**< Vertex count. */
    uint32_t idx_count;     /**< Index count. */
    VkDeviceSize vtx_stride;/**< Vertex stride. */
} GpuMesh;

/**
 * @brief Shared Vulkan state structure.
 * 
 * @todo Add support for multiple swapchains.
 */
typedef struct VulkanState {
    // Instance and device
    VkInstance instance;                    /**< Vulkan instance. */
    VkDebugUtilsMessengerEXT debug_messenger; /**< Debug messenger. */
    VkPhysicalDevice physical_device;       /**< Physical device. */
    VkDevice device;                        /**< Logical device. */
    uint32_t graphics_queue_family;         /**< Graphics queue family index. */
    VkQueue graphics_queue;                 /**< Graphics queue. */
    // Present queue (may be same as graphics)
    uint32_t present_queue_family;          /**< Present queue family index. */
    VkQueue present_queue;                  /**< Present queue. */
    
    // Surface and swapchain
    VkSurfaceKHR surface;                   /**< Window surface. */
    VkSwapchainKHR swapchain;               /**< Swapchain. */
    VkFormat swapchain_format;              /**< Swapchain format. */
    VkExtent2D swapchain_extent;            /**< Swapchain extent. */
    VkImage* swapchain_images;              /**< Swapchain images. */
    uint32_t swapchain_image_count;         /**< Number of swapchain images. */
    VkImageView* swapchain_image_views;     /**< Swapchain image views. */
    
    // Pipeline and rendering
    VkRenderPass render_pass;               /**< Render pass. */
    VkPipelineLayout pipeline_layout;       /**< Pipeline layout. */
    VkPipeline pipeline;                    /**< Graphics pipeline. */
    VkFramebuffer* framebuffers;            /**< Framebuffers. */
    
    // Depth buffer
    VkImage depth_image;                    /**< Depth image. */
    VkDeviceMemory depth_image_memory;      /**< Depth image memory. */
    VkImageView depth_image_view;           /**< Depth image view. */
    VkFormat depth_format;                  /**< Depth format. */
    
    // Commands and synchronization
    VkCommandPool* command_pools;           /**< Command pools [max_frames_in_flight]. */
    VkCommandBuffer* command_buffers;       /**< Command buffers. */

    // Frames-in-flight synchronization
    uint32_t max_frames_in_flight;          /**< Max frames in flight (typically 2). */
    uint32_t current_frame;                 /**< Current frame index. */
    VkSemaphore* image_available_semaphores;/**< Image available semaphores [max_frames_in_flight]. */
    VkSemaphore* render_finished_semaphores;/**< Render finished semaphores [max_frames_in_flight]. */
    VkFence* in_flight_fences;              /**< In-flight fences [max_frames_in_flight]. */
    VkFence* images_in_flight;              /**< Images in flight fences [swapchain_image_count]. */

    // Optional callback to record UI draw commands per-frame between render pass begin/end
    void (*ui_record_callback)(VkCommandBuffer cmd); /**< UI record callback. */

    // Loaded scene GPU buffers
    GpuMesh* scene_meshes;                  /**< Scene meshes. */
    uint32_t scene_mesh_count;              /**< Scene mesh count. */
    
    // Current scene data for PBR rendering
    const CardinalScene* current_scene;     /**< Current scene. */
    
    // PBR pipeline
    VulkanPBRPipeline pbr_pipeline;         /**< PBR pipeline. */
    bool use_pbr_pipeline;                  /**< Flag for using PBR pipeline. */
} VulkanState;

#endif // VULKAN_STATE_H
