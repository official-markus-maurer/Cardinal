#ifndef VULKAN_STATE_H
#define VULKAN_STATE_H

#include <stdint.h>
#include <GLFW/glfw3.h>
#include <vulkan/vulkan.h>

// Forward declarations
struct CardinalWindow;
typedef struct CardinalWindow CardinalWindow;

// Shared Vulkan state structure
typedef struct VulkanState {
    // Instance and device
    VkInstance instance;
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
    VkSemaphore image_available;
    VkSemaphore render_finished;
    VkFence in_flight;

    // Optional callback to record UI draw commands per-frame between render pass begin/end
    void (*ui_record_callback)(VkCommandBuffer cmd);
} VulkanState;

#endif // VULKAN_STATE_H
