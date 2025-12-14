/**
 * @file mesh_shader_bindless_example.c
 * @brief Example demonstrating mesh shader integration with bindless texture system
 * 
 * This example shows how to:
 * 1. Set up mesh shader pipeline with bindless texture support
 * 2. Create and update uniform buffers for transformation matrices
 * 3. Manage material buffers for bindless texture indexing
 * 4. Render meshes using the integrated bindless system
 */

#include "cardinal/renderer/vulkan_mesh_shader.h"
#include "cardinal/renderer/vulkan_bindless.h"
#include "cardinal/core/logging.h"
#include <string.h>

/**
 * @brief Example function demonstrating mesh shader bindless rendering setup
 */
bool mesh_shader_bindless_example(VulkanState* vulkan_state) {
    // 1. Create mesh shader pipeline with bindless support
    MeshShaderPipelineConfig config = {
        .task_shader_path = "shaders/task.spv",
        .mesh_shader_path = "shaders/mesh.spv",
        .fragment_shader_path = "shaders/mesh.frag.spv",
        .cull_mode = VK_CULL_MODE_BACK_BIT,
        .front_face = VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .polygon_mode = VK_POLYGON_MODE_FILL,
        .blend_enable = false,
        .max_vertices_per_meshlet = 64,
        .max_primitives_per_meshlet = 126
    };

    MeshShaderPipeline pipeline;
    if (!vk_mesh_shader_create_pipeline(vulkan_state, &config, 
                                         VK_FORMAT_B8G8R8A8_SRGB, // swapchain format
                                         VK_FORMAT_D32_SFLOAT,     // depth format
                                         &pipeline)) {
        CARDINAL_LOG_ERROR("Failed to create mesh shader pipeline");
        return false;
    }

    // 2. Set up uniform buffer data
    MeshShaderUniformBuffer uniform_data = {
        .model = {
            {1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 1.0f, 0.0f},
            {0.0f, 0.0f, 0.0f, 1.0f}
        },
        .view = {
            {1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 1.0f, -5.0f},
            {0.0f, 0.0f, 0.0f, 1.0f}
        },
        .projection = {
            {1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 1.0f, 0.0f},
            {0.0f, 0.0f, 0.0f, 1.0f}
        },
        .materialIndex = 0  // Index into the material buffer
    };

    // 3. Create uniform buffer
    VkBuffer uniform_buffer;
    VkDeviceMemory uniform_memory;
    if (!vk_mesh_shader_create_uniform_buffer(vulkan_state, &pipeline, &uniform_data,
                                               &uniform_buffer, &uniform_memory)) {
        CARDINAL_LOG_ERROR("Failed to create mesh shader uniform buffer");
        return false;
    }

    // 4. Set up material buffer for bindless textures
    MeshShaderMaterialBuffer material_buffer_data = {0};
    
    // Example: Set up first material with texture indices
    material_buffer_data.materials[0] = (MeshShaderMaterial){
        .baseColorTextureIndex = 0,    // Index into bindless texture array
        .normalTextureIndex = 1,       // Index into bindless texture array
        .metallicRoughnessTextureIndex = 2,
        .emissiveTextureIndex = 3,
        .baseColorFactor = {1.0f, 1.0f, 1.0f, 1.0f},
        .metallicFactor = 1.0f,
        .roughnessFactor = 0.5f,
        .emissiveFactor = {0.0f, 0.0f, 0.0f}
    };

    // Create material buffer
    VkBuffer material_buffer;
    VkDeviceMemory material_memory;
    // Note: This would use a similar buffer creation function
    // vk_create_buffer(vulkan_state, sizeof(MeshShaderMaterialBuffer), 
    //                  VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, &material_buffer, &material_memory);

    // 5. Set up bindless texture array (example with 4 textures)
    VkImageView texture_views[4] = {0}; // These would be loaded textures
    VkSampler sampler = VK_NULL_HANDLE; // This would be a created sampler
    uint32_t texture_count = 4;

    // 6. Set up draw data
    MeshShaderDrawData draw_data = {
        .meshlet_buffer = VK_NULL_HANDLE,     // Would contain actual meshlet data
        .vertex_buffer = VK_NULL_HANDLE,      // Would contain vertex data
        .index_buffer = VK_NULL_HANDLE,       // Would contain index data
        .primitive_buffer = VK_NULL_HANDLE,   // Would contain primitive data
        .draw_command_buffer = VK_NULL_HANDLE, // Would contain draw commands
        .uniform_buffer = uniform_buffer,
        .uniform_memory = uniform_memory,
        .meshlet_count = 100,                 // Example meshlet count
        .vertex_count = 1000,
        .index_count = 3000,
        .primitive_count = 1000,
        .draw_command_count = 100
    };

    // 7. Render using descriptor buffers (no descriptor sets)
    VkCommandBuffer command_buffer = VK_NULL_HANDLE; // Would be from command pool
    VkBuffer lighting_buffer = VK_NULL_HANDLE;       // Would contain lighting data

    // Update descriptor buffers
    if (!vk_mesh_shader_update_descriptor_buffers(vulkan_state, &pipeline, &draw_data,
                                                   material_buffer, lighting_buffer,
                                                   texture_views, sampler, texture_count)) {
        CARDINAL_LOG_ERROR("Failed to update mesh shader descriptor buffers");
        return false;
    }
    
    // Draw mesh shader
    vk_mesh_shader_draw(command_buffer, vulkan_state, &pipeline, &draw_data);
    
    CARDINAL_LOG_INFO("Mesh shader descriptor buffer rendering completed successfully");
    
    // Cleanup would go here...
    // vkDestroyBuffer(vulkan_state->device, uniform_buffer, NULL);
    // vkFreeMemory(vulkan_state->device, uniform_memory, NULL);
    
    return true;
}

/**
 * @brief Example of updating uniform buffer during rendering loop
 */
bool update_mesh_shader_uniforms_example(VulkanState* vulkan_state,
                                          const MeshShaderDrawData* draw_data,
                                          float time) {
    // Create updated uniform data with animated transformation
    MeshShaderUniformBuffer uniform_data = {
        .model = {
            {cosf(time), 0.0f, sinf(time), 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
            {-sinf(time), 0.0f, cosf(time), 0.0f},
            {0.0f, 0.0f, 0.0f, 1.0f}
        },
        .view = {
            {1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 1.0f, -5.0f},
            {0.0f, 0.0f, 0.0f, 1.0f}
        },
        .projection = {
            {1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 1.0f, 0.0f},
            {0.0f, 0.0f, 0.0f, 1.0f}
        },
        .materialIndex = (uint32_t)(time * 10) % 256  // Cycle through materials
    };

    // Update the uniform buffer
    return vk_mesh_shader_update_uniform_buffer(vulkan_state,
                                                 draw_data->uniform_buffer,
                                                 draw_data->uniform_memory,
                                                 &uniform_data);
}
