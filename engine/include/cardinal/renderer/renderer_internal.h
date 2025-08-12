#ifndef CARDINAL_RENDERER_INTERNAL_H
#define CARDINAL_RENDERER_INTERNAL_H

#include <vulkan/vulkan.h>
#include "renderer.h"
#include "../assets/scene.h"

#ifdef __cplusplus
extern "C" {
#endif

// Internal API for editor ImGui integration - minimal exposure
VkRenderPass cardinal_renderer_internal_render_pass(CardinalRenderer* renderer);
VkCommandBuffer cardinal_renderer_internal_current_cmd(CardinalRenderer* renderer, uint32_t image_index);
VkDevice cardinal_renderer_internal_device(CardinalRenderer* renderer);
VkPhysicalDevice cardinal_renderer_internal_physical_device(CardinalRenderer* renderer);
VkQueue cardinal_renderer_internal_graphics_queue(CardinalRenderer* renderer);
uint32_t cardinal_renderer_internal_graphics_queue_family(CardinalRenderer* renderer);
VkInstance cardinal_renderer_internal_instance(CardinalRenderer* renderer);
uint32_t cardinal_renderer_internal_swapchain_image_count(CardinalRenderer* renderer);

// UI integration
void cardinal_renderer_set_ui_callback(CardinalRenderer* renderer, void (*callback)(VkCommandBuffer cmd));

// Execute a one-time command buffer immediately on the graphics queue
void cardinal_renderer_immediate_submit(CardinalRenderer* renderer, void (*record)(VkCommandBuffer cmd));

// Upload a loaded CPU scene to GPU buffers for basic drawing
void cardinal_renderer_upload_scene(CardinalRenderer* renderer, const CardinalScene* scene);
// Clear current GPU scene resources
void cardinal_renderer_clear_scene(CardinalRenderer* renderer);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_RENDERER_INTERNAL_H
