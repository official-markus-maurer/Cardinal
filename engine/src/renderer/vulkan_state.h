#ifndef VULKAN_STATE_H
#define VULKAN_STATE_H

#include <stdint.h>
#include <GLFW/glfw3.h>
#include <vulkan/vulkan.h>

// Forward declarations
struct CardinalWindow;
typedef struct CardinalWindow CardinalWindow;

// GPU mesh buffers for a loaded scene
typedef struct GpuMesh {
    VkBuffer vbuf;
    VkDeviceMemory vmem;
    VkBuffer ibuf;
    VkDeviceMemory imem;
    uint32_t vtx_count;
    uint32_t idx_count;
    VkDeviceSize vtx_stride;
} GpuMesh;

// Shared Vulkan state structure
typedef struct VulkanState {
    // Instance and device
    VkInstance instance;
    VkDebugUtilsMessengerEXT debug_messenger;
    VkPhysicalDevice physical_device;
    VkDevice device;
    uint32_t graphics_queue_family;
    VkQueue graphics_queue;
    
    // Surface and swapchain
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat swapchain_format;
    VkExtent2D swapchain_extent;
    VkImage* swapchain_images;
    uint32_t swapchain_image_count;
    VkImageView* swapchain_image_views;
    
    // Pipeline and rendering
    VkRenderPass render_pass;
    VkPipelineLayout pipeline_layout;
    VkPipeline pipeline;
    VkFramebuffer* framebuffers;
    
    // Commands and synchronization
    VkCommandPool command_pool;
    VkCommandBuffer* command_buffers;

    // Frames-in-flight synchronization
    uint32_t max_frames_in_flight;       // typically 2
    uint32_t current_frame;              // rotating index [0..max_frames_in_flight)
    VkSemaphore* image_available_semaphores; // [max_frames_in_flight]
    VkSemaphore* render_finished_semaphores; // [max_frames_in_flight]
    VkFence* in_flight_fences;               // [max_frames_in_flight]
    VkFence* images_in_flight;               // [swapchain_image_count] fence tracking per acquired image

    // Optional callback to record UI draw commands per-frame between render pass begin/end
    void (*ui_record_callback)(VkCommandBuffer cmd);

    // Loaded scene GPU buffers
    GpuMesh* scene_meshes;
    uint32_t scene_mesh_count;
} VulkanState;

#endif // VULKAN_STATE_H
