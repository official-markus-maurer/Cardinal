#include "vulkan_resource_manager.h"
#include "cardinal/core/log.h"
#include "cardinal/renderer/vulkan_commands.h"
#include "cardinal/renderer/vulkan_compute.h"
#include "cardinal/renderer/vulkan_mesh_shader.h"
#include "cardinal/renderer/vulkan_pipeline.h"
#include "cardinal/renderer/vulkan_swapchain.h"
#include "cardinal/renderer/vulkan_texture_manager.h"
#include "vulkan_simple_pipelines.h"
#include <stdlib.h>
#include <string.h>

VkResult vulkan_resource_manager_init(VulkanResourceManager* manager, VulkanState* vulkan_state) {
    if (!manager || !vulkan_state) {
        CARDINAL_LOG_ERROR("[RESOURCE_MANAGER] Invalid parameters for initialization");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    memset(manager, 0, sizeof(VulkanResourceManager));
    manager->vulkan_state = vulkan_state;
    manager->initialized = true;

    CARDINAL_LOG_DEBUG("[RESOURCE_MANAGER] Initialized successfully");
    return VK_SUCCESS;
}

void vulkan_resource_manager_destroy(VulkanResourceManager* manager) {
    if (!manager || !manager->initialized) {
        return;
    }

    manager->vulkan_state = NULL;
    manager->initialized = false;

    CARDINAL_LOG_DEBUG("[RESOURCE_MANAGER] Destroyed successfully");
}

void vulkan_resource_manager_destroy_all(VulkanResourceManager* manager) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    VulkanState* s = manager->vulkan_state;

    CARDINAL_LOG_INFO("[RESOURCE_MANAGER] Starting complete resource destruction");

    // Wait for device to be idle before processing cleanup
    vulkan_resource_manager_wait_idle(manager);

    // Process pending mesh shader draw data cleanup
    vulkan_resource_manager_process_mesh_cleanup(manager);

    // Destroy resources in reverse order of creation
    vulkan_resource_manager_destroy_commands_sync(manager);
    vulkan_resource_manager_destroy_scene(manager);

    // Cleanup compute shader support
    if (s->pipelines.compute_shader_initialized) {
        vk_compute_cleanup(s);
    }

    vulkan_resource_manager_destroy_pipelines(manager);
    vulkan_resource_manager_destroy_swapchain_resources(manager);

    CARDINAL_LOG_INFO("[RESOURCE_MANAGER] Complete resource destruction finished");
}

void vulkan_resource_manager_destroy_scene(VulkanResourceManager* manager) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    VulkanState* s = manager->vulkan_state;

    CARDINAL_LOG_DEBUG("[RESOURCE_MANAGER] Destroying scene buffers");

    // Destroy mesh buffers
    for (uint32_t i = 0; i < s->scene_mesh_count; i++) {
        GpuMesh* m = &s->scene_meshes[i];
        if (m->vbuf != VK_NULL_HANDLE) {
            vulkan_resource_manager_destroy_buffer(manager, m->vbuf, m->vmem);
            m->vbuf = VK_NULL_HANDLE;
        }
        if (m->ibuf != VK_NULL_HANDLE) {
            vulkan_resource_manager_destroy_buffer(manager, m->ibuf, m->imem);
            m->ibuf = VK_NULL_HANDLE;
        }
    }

    vulkan_resource_manager_free(s->scene_meshes);
    s->scene_meshes = NULL;
    s->scene_mesh_count = 0;
}

void vulkan_resource_manager_destroy_pipelines(VulkanResourceManager* manager) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    VulkanState* s = manager->vulkan_state;

    CARDINAL_LOG_DEBUG("[RESOURCE_MANAGER] Destroying pipelines");

    // Destroy simple pipelines
    vk_destroy_simple_pipelines(s);

    // Wait for all GPU operations to complete before destroying PBR pipeline
    vulkan_resource_manager_wait_idle(manager);

    // Destroy PBR pipeline
    // Note: PBR pipeline destruction should be handled by the main renderer
    // vk_pbr_pipeline_destroy(&s->pipelines.pbr_pipeline, s->context.device, &s->allocator);

    // Process any remaining pending mesh shader cleanup BEFORE destroying allocator
    vulkan_resource_manager_process_mesh_cleanup(manager);

    // Free pending cleanup list
    if (s->pending_cleanup_draw_data) {
        vulkan_resource_manager_free(s->pending_cleanup_draw_data);
        s->pending_cleanup_draw_data = NULL;
        s->pending_cleanup_count = 0;
        s->pending_cleanup_capacity = 0;
    }

    // Destroy mesh shader pipeline BEFORE destroying allocator
    if (s->context.supports_mesh_shader) {
        // Note: Mesh shader cleanup should be handled by the main renderer
        // vk_mesh_shader_destroy_pipeline(s, &s->pipelines.mesh_shader_pipeline);
        // vk_mesh_shader_cleanup(s);
    }

    vk_destroy_pipeline(s);
}

void vulkan_resource_manager_destroy_swapchain_resources(VulkanResourceManager* manager) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    VulkanState* s = manager->vulkan_state;

    CARDINAL_LOG_DEBUG("[RESOURCE_MANAGER] Destroying swapchain resources");

    vk_destroy_swapchain(s);
}

void vulkan_resource_manager_destroy_commands_sync(VulkanResourceManager* manager) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    VulkanState* s = manager->vulkan_state;

    CARDINAL_LOG_DEBUG("[RESOURCE_MANAGER] Destroying command buffers and synchronization objects");

    vk_destroy_commands_sync(s);
}

void vulkan_resource_manager_destroy_depth_resources(VulkanResourceManager* manager) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    VulkanState* s = manager->vulkan_state;

    CARDINAL_LOG_DEBUG("[RESOURCE_MANAGER] Destroying depth resources");

    // Validate and destroy depth image view
    if (s->swapchain.depth_image_view != VK_NULL_HANDLE) {
        vkDestroyImageView(s->context.device, s->swapchain.depth_image_view, NULL);
        s->swapchain.depth_image_view = VK_NULL_HANDLE;
    }

    // Validate and free image + memory using allocator
    if (s->swapchain.depth_image != VK_NULL_HANDLE) {
        vulkan_resource_manager_destroy_image(manager, s->swapchain.depth_image,
                                              s->swapchain.depth_image_memory);
        s->swapchain.depth_image = VK_NULL_HANDLE;
        s->swapchain.depth_image_memory = VK_NULL_HANDLE;
    }

    // Reset layout tracking when depth resources are destroyed
    // Note: depth_image_layout field doesn't exist in VulkanState
    // Layout tracking should be handled elsewhere if needed
}

void vulkan_resource_manager_destroy_textures(VulkanResourceManager* manager,
                                              VulkanPBRPipeline* pipeline) {
    if (!manager || !manager->initialized || !manager->vulkan_state || !pipeline) {
        return;
    }

    CARDINAL_LOG_DEBUG("[RESOURCE_MANAGER] Destroying texture resources");

    // Wait for all GPU operations to complete before destroying descriptor-bound resources
    vulkan_resource_manager_wait_idle(manager);

    // Destroy texture manager
    if (pipeline->textureManager) {
        vk_texture_manager_destroy(pipeline->textureManager);
        vulkan_resource_manager_free(pipeline->textureManager);
        pipeline->textureManager = NULL;
    }
}

void vulkan_resource_manager_destroy_buffer(VulkanResourceManager* manager, VkBuffer buffer,
                                            VkDeviceMemory memory) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    if (buffer != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(&manager->vulkan_state->allocator, buffer, memory);
    }
}

void vulkan_resource_manager_destroy_image(VulkanResourceManager* manager, VkImage image,
                                           VkDeviceMemory memory) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    if (image != VK_NULL_HANDLE) {
        vk_allocator_free_image(&manager->vulkan_state->allocator, image, memory);
    }
}

void vulkan_resource_manager_destroy_shader_modules(VulkanResourceManager* manager,
                                                    VkShaderModule* shader_modules,
                                                    uint32_t count) {
    if (!manager || !manager->initialized || !manager->vulkan_state || !shader_modules) {
        return;
    }

    VkDevice device = manager->vulkan_state->context.device;

    for (uint32_t i = 0; i < count; i++) {
        if (shader_modules[i] != VK_NULL_HANDLE) {
            vkDestroyShaderModule(device, shader_modules[i], NULL);
            shader_modules[i] = VK_NULL_HANDLE;
        }
    }
}

void vulkan_resource_manager_destroy_descriptors(VulkanResourceManager* manager,
                                                 VkDescriptorPool pool,
                                                 VkDescriptorSetLayout layout) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    VkDevice device = manager->vulkan_state->context.device;

    // Wait for device to be idle before destroying descriptor pool
    vulkan_resource_manager_wait_idle(manager);

    if (pool != VK_NULL_HANDLE) {
        vkDestroyDescriptorPool(device, pool, NULL);
    }

    if (layout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(device, layout, NULL);
    }
}

void vulkan_resource_manager_destroy_pipeline(VulkanResourceManager* manager, VkPipeline pipeline,
                                              VkPipelineLayout layout) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    VkDevice device = manager->vulkan_state->context.device;

    if (pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(device, pipeline, NULL);
    }

    if (layout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(device, layout, NULL);
    }
}

VkResult vulkan_resource_manager_wait_idle(VulkanResourceManager* manager) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    VkResult result = vkDeviceWaitIdle(manager->vulkan_state->context.device);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[RESOURCE_MANAGER] Failed to wait for device idle: %d", result);
    }

    return result;
}

void vulkan_resource_manager_process_mesh_cleanup(VulkanResourceManager* manager) {
    if (!manager || !manager->initialized || !manager->vulkan_state) {
        return;
    }

    VulkanState* s = manager->vulkan_state;

    if (s->context.supports_mesh_shader) {
        // Note: Mesh shader cleanup should be handled by the main renderer
        // vk_mesh_shader_process_pending_cleanup(s);
    }
}

void vulkan_resource_manager_free(void* ptr) {
    if (ptr) {
        free(ptr);
    }
}

void vulkan_resource_manager_destroy_image_views(VulkanResourceManager* manager,
                                                 VkImageView* image_views, uint32_t count) {
    if (!manager || !manager->initialized || !manager->vulkan_state || !image_views) {
        return;
    }

    VkDevice device = manager->vulkan_state->context.device;

    for (uint32_t i = 0; i < count; i++) {
        if (image_views[i] != VK_NULL_HANDLE) {
            vkDestroyImageView(device, image_views[i], NULL);
            image_views[i] = VK_NULL_HANDLE;
        }
    }
}

void vulkan_resource_manager_destroy_command_pools(VulkanResourceManager* manager,
                                                   VkCommandPool* pools, uint32_t count) {
    if (!manager || !manager->initialized || !manager->vulkan_state || !pools) {
        return;
    }

    VkDevice device = manager->vulkan_state->context.device;

    for (uint32_t i = 0; i < count; i++) {
        if (pools[i] != VK_NULL_HANDLE) {
            vkDestroyCommandPool(device, pools[i], NULL);
            pools[i] = VK_NULL_HANDLE;
        }
    }
}
