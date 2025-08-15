/**
 * @file renderer_internal.h
 * @brief Internal renderer API for Cardinal Engine
 * 
 * This module provides internal access to the Vulkan renderer state for
 * advanced use cases such as editor integration, UI rendering, and direct
 * Vulkan resource access. These functions expose low-level Vulkan objects
 * and should be used with caution.
 * 
 * Key features:
 * - Direct access to Vulkan objects (device, queues, command buffers)
 * - ImGui/UI integration support
 * - Immediate command buffer submission
 * - Swapchain and surface format queries
 * - Scene upload and management utilities
 * 
 * @warning This is an internal API intended for advanced users and editor
 *          integration. Direct manipulation of Vulkan objects can cause
 *          rendering issues if not handled properly.
 * 
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_RENDERER_INTERNAL_H
#define CARDINAL_RENDERER_INTERNAL_H

#include <vulkan/vulkan.h>
#include "renderer.h"
#include "../assets/scene.h"

#ifdef __cplusplus
extern "C" {
#endif

// Internal API for editor ImGui integration - minimal exposure
VkCommandBuffer cardinal_renderer_internal_current_cmd(CardinalRenderer* renderer, uint32_t image_index);
VkDevice cardinal_renderer_internal_device(CardinalRenderer* renderer);
VkPhysicalDevice cardinal_renderer_internal_physical_device(CardinalRenderer* renderer);
VkQueue cardinal_renderer_internal_graphics_queue(CardinalRenderer* renderer);
uint32_t cardinal_renderer_internal_graphics_queue_family(CardinalRenderer* renderer);
VkInstance cardinal_renderer_internal_instance(CardinalRenderer* renderer);
uint32_t cardinal_renderer_internal_swapchain_image_count(CardinalRenderer* renderer);
VkFormat cardinal_renderer_internal_swapchain_format(CardinalRenderer* renderer);
VkFormat cardinal_renderer_internal_depth_format(CardinalRenderer* renderer);
VkExtent2D cardinal_renderer_internal_swapchain_extent(CardinalRenderer* renderer);

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
