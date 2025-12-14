#ifndef VULKAN_RESOURCE_MANAGER_H
#define VULKAN_RESOURCE_MANAGER_H

#include "cardinal/renderer/vulkan_mesh_shader.h"
#include "cardinal/renderer/vulkan_pbr.h"
#include "vulkan_state.h"
#include <stdbool.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif
/**
 * @brief Resource cleanup and destruction manager for Vulkan resources
 *
 * This module centralizes all resource cleanup operations to ensure proper
 * destruction order and prevent resource leaks.
 */

typedef struct VulkanResourceManager {
  VulkanState *vulkan_state;
  bool initialized;
} VulkanResourceManager;

/**
 * @brief Initialize the resource manager
 * @param manager Resource manager to initialize
 * @param vulkan_state Vulkan state containing resources to manage
 * @return VK_SUCCESS on success, error code otherwise
 */
VkResult vulkan_resource_manager_init(VulkanResourceManager *manager,
                                      VulkanState *vulkan_state);

/**
 * @brief Destroy the resource manager
 * @param manager Resource manager to destroy
 */
void vulkan_resource_manager_destroy(VulkanResourceManager *manager);

/**
 * @brief Destroy all renderer resources in proper order
 * @param manager Resource manager
 */
void vulkan_resource_manager_destroy_all(VulkanResourceManager *manager);

/**
 * @brief Destroy scene-specific resources (meshes, buffers)
 * @param manager Resource manager
 */
void vulkan_resource_manager_destroy_scene(VulkanResourceManager *manager);

/**
 * @brief Destroy pipeline resources
 * @param manager Resource manager
 */
void vulkan_resource_manager_destroy_pipelines(VulkanResourceManager *manager);

/**
 * @brief Destroy swapchain-dependent resources
 * @param manager Resource manager
 */
void vulkan_resource_manager_destroy_swapchain_resources(
    VulkanResourceManager *manager);

/**
 * @brief Destroy command buffers and synchronization objects
 * @param manager Resource manager
 */
void vulkan_resource_manager_destroy_commands_sync(
    VulkanResourceManager *manager);

/**
 * @brief Destroy depth resources (image, view, memory)
 * @param manager Resource manager
 */
void vulkan_resource_manager_destroy_depth_resources(
    VulkanResourceManager *manager);

/**
 * @brief Destroy texture resources (images, views, samplers)
 * @param manager Resource manager
 * @param pipeline PBR pipeline containing texture resources
 */
void vulkan_resource_manager_destroy_textures(VulkanResourceManager *manager,
                                              VulkanPBRPipeline *pipeline);

/**
 * @brief Destroy buffer resources using allocator
 * @param manager Resource manager
 * @param buffer Buffer to destroy
 * @param memory Memory associated with buffer
 */
void vulkan_resource_manager_destroy_buffer(VulkanResourceManager *manager,
                                            VkBuffer buffer,
                                            VkDeviceMemory memory);

/**
 * @brief Destroy image resources using allocator
 * @param manager Resource manager
 * @param image Image to destroy
 * @param memory Memory associated with image
 */
void vulkan_resource_manager_destroy_image(VulkanResourceManager *manager,
                                           VkImage image,
                                           VkDeviceMemory memory);

/**
 * @brief Destroy shader modules
 * @param manager Resource manager
 * @param shader_modules Array of shader modules to destroy
 * @param count Number of shader modules
 */
void vulkan_resource_manager_destroy_shader_modules(
    VulkanResourceManager *manager, VkShaderModule *shader_modules,
    uint32_t count);

/**
 * @brief Destroy descriptor resources (pools, layouts, sets)
 * @param manager Resource manager
 * @param pool Descriptor pool to destroy
 * @param layout Descriptor set layout to destroy
 */
void vulkan_resource_manager_destroy_descriptors(VulkanResourceManager *manager,
                                                 VkDescriptorPool pool,
                                                 VkDescriptorSetLayout layout);

/**
 * @brief Destroy pipeline and layout
 * @param manager Resource manager
 * @param pipeline Pipeline to destroy
 * @param layout Pipeline layout to destroy
 */
void vulkan_resource_manager_destroy_pipeline(VulkanResourceManager *manager,
                                              VkPipeline pipeline,
                                              VkPipelineLayout layout);

/**
 * @brief Wait for device idle before cleanup operations
 * @param manager Resource manager
 * @return VK_SUCCESS on success, error code otherwise
 */
VkResult vulkan_resource_manager_wait_idle(VulkanResourceManager *manager);

/**
 * @brief Process pending mesh shader cleanup
 * @param manager Resource manager
 */
void vulkan_resource_manager_process_mesh_cleanup(
    VulkanResourceManager *manager);

/**
 * @brief Free memory allocation
 * @param ptr Pointer to free
 */
void vulkan_resource_manager_free(void *ptr);

/**
 * @brief Destroy image views array
 * @param manager Resource manager
 * @param image_views Array of image views to destroy
 * @param count Number of image views
 */
void vulkan_resource_manager_destroy_image_views(VulkanResourceManager *manager,
                                                 VkImageView *image_views,
                                                 uint32_t count);

/**
 * @brief Destroy command pools
 * @param manager Resource manager
 * @param pools Array of command pools to destroy
 * @param count Number of command pools
 */
void vulkan_resource_manager_destroy_command_pools(
    VulkanResourceManager *manager, VkCommandPool *pools, uint32_t count);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_RESOURCE_MANAGER_H
