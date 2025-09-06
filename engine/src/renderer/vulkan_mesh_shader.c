/**
 * @file vulkan_mesh_shader.c
 * @brief Implementation of Vulkan mesh shader pipeline management
 */

#include "cardinal/renderer/vulkan_mesh_shader.h"
#include "vulkan_state.h"
#include "cardinal/renderer/util/vulkan_shader_utils.h"
#include "cardinal/renderer/util/vulkan_buffer_utils.h"
#include <vulkan/vulkan.h>
#include "cardinal/renderer/util/vulkan_descriptor_buffer_utils.h"
#include "cardinal/core/log.h"

#include <stdlib.h>
#include <string.h>
#include <assert.h>

// Mesh shader extension function pointers
static PFN_vkCmdDrawMeshTasksEXT vkCmdDrawMeshTasksEXT_func = NULL;

bool vk_mesh_shader_init(VulkanState* vulkan_state) {
    if (!vulkan_state) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Invalid VulkanState pointer");
        return false;
    }
    
    if (!vulkan_state->supports_mesh_shader) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] VK_EXT_mesh_shader extension not available");
        return false;
    }
    
    // Load mesh shader extension function pointers
    vkCmdDrawMeshTasksEXT_func = (PFN_vkCmdDrawMeshTasksEXT)
        vkGetDeviceProcAddr(vulkan_state->device, "vkCmdDrawMeshTasksEXT");
    
    if (!vkCmdDrawMeshTasksEXT_func) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to load vkCmdDrawMeshTasksEXT function");
        return false;
    }
    
    CARDINAL_LOG_INFO("[MESH_SHADER] Mesh shader support initialized successfully");
    return true;
}

void vk_mesh_shader_cleanup(VulkanState* vulkan_state) {
    if (!vulkan_state) {
        return;
    }
    
    // Reset function pointers
    vkCmdDrawMeshTasksEXT_func = NULL;
    
    CARDINAL_LOG_INFO("[MESH_SHADER] Mesh shader support cleaned up");
}

bool vk_mesh_shader_create_pipeline(VulkanState* vulkan_state,
                                     const MeshShaderPipelineConfig* config,
                                     VkFormat swapchain_format,
                                     VkFormat depth_format,
                                     MeshShaderPipeline* pipeline) {
    if (!vulkan_state || !config || !pipeline) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Invalid parameters for pipeline creation");
        return false;
    }
    
    if (!vulkan_state->supports_mesh_shader) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Mesh shader extension not supported");
        return false;
    }
    
    // Initialize pipeline structure
    memset(pipeline, 0, sizeof(MeshShaderPipeline));
    
    VkResult result;
    
    // Create descriptor set layouts that match shader expectations
    // Even with descriptor buffers, we need layouts for pipeline validation
    
    // Set 0: Mesh shader descriptors (storage buffers + uniform buffer)
    VkDescriptorSetLayoutBinding mesh_bindings[] = {
        {
            .binding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_TASK_BIT_EXT | VK_SHADER_STAGE_MESH_BIT_EXT,
            .pImmutableSamplers = NULL
        },
        {
            .binding = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_TASK_BIT_EXT | VK_SHADER_STAGE_MESH_BIT_EXT,
            .pImmutableSamplers = NULL
        },
        {
            .binding = 3,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_MESH_BIT_EXT,
            .pImmutableSamplers = NULL
        },
        {
            .binding = 4,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_MESH_BIT_EXT,
            .pImmutableSamplers = NULL
        }
    };
    
    VkDescriptorSetLayoutCreateInfo mesh_layout_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT,
        .bindingCount = 4,
        .pBindings = mesh_bindings
    };
    
    VkDescriptorSetLayout mesh_descriptor_layout;
    result = vkCreateDescriptorSetLayout(vulkan_state->device, &mesh_layout_info, NULL, &mesh_descriptor_layout);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create mesh descriptor set layout: %d", result);
        return false;
    }
    
    // Set 1: Fragment shader descriptors (uniform buffers + bindless textures)
    VkDescriptorSetLayoutBinding fragment_bindings[] = {
        {
            .binding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = NULL
        },
        {
            .binding = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = NULL
        },
        {
            .binding = 2,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = NULL
        },
        {
            .binding = 3,
            .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1024,
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = NULL
        }
    };
    
    VkDescriptorSetLayoutCreateInfo fragment_layout_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT,
        .bindingCount = 4,
        .pBindings = fragment_bindings
    };
    
    VkDescriptorSetLayout fragment_descriptor_layout;
    result = vkCreateDescriptorSetLayout(vulkan_state->device, &fragment_layout_info, NULL, &fragment_descriptor_layout);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create fragment descriptor set layout: %d", result);
        vkDestroyDescriptorSetLayout(vulkan_state->device, mesh_descriptor_layout, NULL);
        return false;
    }
    
    // Create pipeline layout with descriptor set layouts
    VkDescriptorSetLayout set_layouts[] = { mesh_descriptor_layout, fragment_descriptor_layout };
    VkPipelineLayoutCreateInfo pipeline_layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 2,
        .pSetLayouts = set_layouts,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = NULL
    };
    
    // Store descriptor set layouts in pipeline for cleanup
    pipeline->descriptor_layout = mesh_descriptor_layout;
    pipeline->fragment_descriptor_layout = fragment_descriptor_layout;
    
    result = vkCreatePipelineLayout(vulkan_state->device, &pipeline_layout_info, NULL, &pipeline->pipeline_layout);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create pipeline layout: %d", result);
        return false;
    }
    {
        // Calculate descriptor buffer sizes
        VkDeviceSize mesh_buffer_size = 
            5 * vulkan_state->descriptor_buffer_uniform_buffer_size +  // 5 uniform/storage buffers
            0 * vulkan_state->descriptor_buffer_combined_image_sampler_size; // No samplers in Set 0
        
        VkDeviceSize fragment_buffer_size = 
            3 * vulkan_state->descriptor_buffer_uniform_buffer_size +  // 3 uniform buffers
            1024 * vulkan_state->descriptor_buffer_combined_image_sampler_size; // 1024 bindless textures
        
        // Create mesh descriptor buffer (Set 0) using VulkanAllocator
        VkBufferCreateInfo mesh_buffer_info = {
            .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = mesh_buffer_size,
            .usage = VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE
        };
        
        if (!vk_allocator_allocate_buffer(&vulkan_state->allocator, &mesh_buffer_info, 
                                           &pipeline->mesh_descriptor_buffer, &pipeline->mesh_descriptor_memory,
                                           VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
            CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create mesh descriptor buffer");
            vkDestroyPipelineLayout(vulkan_state->device, pipeline->pipeline_layout, NULL);
            return false;
        }
        
        // Create fragment descriptor buffer (Set 1) using VulkanAllocator
        VkBufferCreateInfo fragment_buffer_info = {
            .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = fragment_buffer_size,
            .usage = VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE
        };
        
        if (!vk_allocator_allocate_buffer(&vulkan_state->allocator, &fragment_buffer_info, 
                                           &pipeline->fragment_descriptor_buffer, &pipeline->fragment_descriptor_memory,
                                           VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
            CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create fragment descriptor buffer");
            vk_allocator_free_buffer(&vulkan_state->allocator, pipeline->mesh_descriptor_buffer, pipeline->mesh_descriptor_memory);
            vkDestroyPipelineLayout(vulkan_state->device, pipeline->pipeline_layout, NULL);
            return false;
        }
        
        pipeline->mesh_descriptor_offset = 0;
        pipeline->fragment_descriptor_offset = 0;
        
        CARDINAL_LOG_DEBUG("[MESH_SHADER] Created descriptor buffers (mesh: %llu bytes, fragment: %llu bytes)", 
                          mesh_buffer_size, fragment_buffer_size);
    }
    
    // Create minimal placeholder resources for validation compliance
    VkBuffer placeholder_buffer = VK_NULL_HANDLE;
    VkDeviceMemory placeholder_buffer_memory = VK_NULL_HANDLE;
    
    // Create a small placeholder buffer (1KB)
    VkBufferCreateInfo buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = 1024,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE
    };
    
    if (vkCreateBuffer(vulkan_state->device, &buffer_info, NULL, &placeholder_buffer) == VK_SUCCESS) {
        VkMemoryRequirements mem_requirements;
        vkGetBufferMemoryRequirements(vulkan_state->device, placeholder_buffer, &mem_requirements);
        
        VkMemoryAllocateInfo mem_alloc_info = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = vk_buffer_find_memory_type(vulkan_state->physical_device, mem_requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
        };
        
        if (vkAllocateMemory(vulkan_state->device, &mem_alloc_info, NULL, &placeholder_buffer_memory) == VK_SUCCESS) {
            vkBindBufferMemory(vulkan_state->device, placeholder_buffer, placeholder_buffer_memory, 0);
        }
    }
    
    pipeline->placeholder_buffer = placeholder_buffer;
    pipeline->placeholder_buffer_memory = placeholder_buffer_memory;
    
    // Store placeholder resources for cleanup
    pipeline->placeholder_buffer = placeholder_buffer;
    pipeline->placeholder_buffer_memory = placeholder_buffer_memory;
    
    CARDINAL_LOG_DEBUG("[MESH_SHADER] Created descriptor buffers for mesh shader pipeline");
    
    // Load shaders
    VkShaderModule mesh_shader = VK_NULL_HANDLE;
    VkShaderModule task_shader = VK_NULL_HANDLE;
    VkShaderModule frag_shader = VK_NULL_HANDLE;
    
    if (!vk_shader_create_module(vulkan_state->device, config->mesh_shader_path, &mesh_shader)) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to load mesh shader: %s", config->mesh_shader_path);
        goto cleanup_pipeline_layout;
    }
    
    if (config->task_shader_path && strlen(config->task_shader_path) > 0) {
        if (!vk_shader_create_module(vulkan_state->device, config->task_shader_path, &task_shader)) {
            CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to load task shader: %s", config->task_shader_path);
            goto cleanup_shaders;
        }
        pipeline->has_task_shader = true;
    }
    
    if (!vk_shader_create_module(vulkan_state->device, config->fragment_shader_path, &frag_shader)) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to load fragment shader: %s", config->fragment_shader_path);
        goto cleanup_shaders;
    }
    
    // Create shader stages
    VkPipelineShaderStageCreateInfo shader_stages[3];
    uint32_t stage_count = 0;
    
    if (pipeline->has_task_shader) {
        shader_stages[stage_count++] = (VkPipelineShaderStageCreateInfo){
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_TASK_BIT_EXT,
            .module = task_shader,
            .pName = "main"
        };
    }
    
    shader_stages[stage_count++] = (VkPipelineShaderStageCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_MESH_BIT_EXT,
        .module = mesh_shader,
        .pName = "main"
    };
    
    shader_stages[stage_count++] = (VkPipelineShaderStageCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = frag_shader,
        .pName = "main"
    };
    
    // Rasterization state
    VkPipelineRasterizationStateCreateInfo rasterizer = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = VK_FALSE,
        .rasterizerDiscardEnable = VK_FALSE,
        .polygonMode = config->polygon_mode,
        .lineWidth = 1.0f,
        .cullMode = config->cull_mode,
        .frontFace = config->front_face,
        .depthBiasEnable = VK_FALSE
    };
    
    // Multisampling state
    VkPipelineMultisampleStateCreateInfo multisampling = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = VK_FALSE,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
    };
    
    // Depth stencil state
    VkPipelineDepthStencilStateCreateInfo depth_stencil = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = config->depth_test_enable ? VK_TRUE : VK_FALSE,
        .depthWriteEnable = config->depth_write_enable ? VK_TRUE : VK_FALSE,
        .depthCompareOp = config->depth_compare_op,
        .depthBoundsTestEnable = VK_FALSE,
        .stencilTestEnable = VK_FALSE
    };
    
    // Color blend attachment
    VkPipelineColorBlendAttachmentState color_blend_attachment = {
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | 
                         VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = config->blend_enable ? VK_TRUE : VK_FALSE,
        .srcColorBlendFactor = config->src_color_blend_factor,
        .dstColorBlendFactor = config->dst_color_blend_factor,
        .colorBlendOp = config->color_blend_op,
        .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = VK_BLEND_OP_ADD
    };
    
    VkPipelineColorBlendStateCreateInfo color_blending = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = VK_FALSE,
        .logicOp = VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = {0.0f, 0.0f, 0.0f, 0.0f}
    };
    
    // Viewport state (dynamic)
    VkPipelineViewportStateCreateInfo viewport_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1
    };
    
    // Dynamic state
    VkDynamicState dynamic_states[] = {
        VK_DYNAMIC_STATE_VIEWPORT,
        VK_DYNAMIC_STATE_SCISSOR
    };
    
    VkPipelineDynamicStateCreateInfo dynamic_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = sizeof(dynamic_states) / sizeof(dynamic_states[0]),
        .pDynamicStates = dynamic_states
    };
    
    // Create graphics pipeline
    // Dynamic rendering info
    VkPipelineRenderingCreateInfo pipeline_rendering_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &swapchain_format,
        .depthAttachmentFormat = depth_format,
        .stencilAttachmentFormat = VK_FORMAT_UNDEFINED
    };
    
    VkGraphicsPipelineCreateInfo pipeline_info = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &pipeline_rendering_info,
        .flags = VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT,
        .stageCount = stage_count,
        .pStages = shader_stages,
        .pVertexInputState = NULL, // No vertex input for mesh shaders
        .pInputAssemblyState = NULL, // No input assembly for mesh shaders
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = pipeline->pipeline_layout,
        .renderPass = VK_NULL_HANDLE,
        .subpass = 0,
        .basePipelineHandle = VK_NULL_HANDLE
    };
    
    result = vkCreateGraphicsPipelines(vulkan_state->device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &pipeline->pipeline);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create graphics pipeline: %d", result);
        goto cleanup_shaders;
    }
    
    // Set pipeline properties
    pipeline->max_meshlets_per_workgroup = 32; // Conservative default
    pipeline->max_vertices_per_meshlet = 64;
    pipeline->max_primitives_per_meshlet = 126;
    
    // Cleanup shader modules
    vkDestroyShaderModule(vulkan_state->device, mesh_shader, NULL);
    if (task_shader != VK_NULL_HANDLE) {
        vkDestroyShaderModule(vulkan_state->device, task_shader, NULL);
    }
    vkDestroyShaderModule(vulkan_state->device, frag_shader, NULL);
    
    CARDINAL_LOG_INFO("[MESH_SHADER] Pipeline created successfully (task shader: %s)", 
                      pipeline->has_task_shader ? "enabled" : "disabled");
    return true;
    
cleanup_shaders:
    if (mesh_shader != VK_NULL_HANDLE) {
        vkDestroyShaderModule(vulkan_state->device, mesh_shader, NULL);
    }
    if (task_shader != VK_NULL_HANDLE) {
        vkDestroyShaderModule(vulkan_state->device, task_shader, NULL);
    }
    if (frag_shader != VK_NULL_HANDLE) {
        vkDestroyShaderModule(vulkan_state->device, frag_shader, NULL);
    }
    
cleanup_pipeline_layout:
    vkDestroyPipelineLayout(vulkan_state->device, pipeline->pipeline_layout, NULL);
    return false;
}

void vk_mesh_shader_destroy_pipeline(VulkanState* vulkan_state, MeshShaderPipeline* pipeline) {
    if (!vulkan_state || !pipeline) {
        return;
    }
    
    // Clean up descriptor buffers using VulkanAllocator
    if (pipeline->mesh_descriptor_buffer != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(&vulkan_state->allocator, pipeline->mesh_descriptor_buffer, pipeline->mesh_descriptor_memory);
        pipeline->mesh_descriptor_buffer = VK_NULL_HANDLE;
        pipeline->mesh_descriptor_memory = VK_NULL_HANDLE;
    }
    if (pipeline->fragment_descriptor_buffer != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(&vulkan_state->allocator, pipeline->fragment_descriptor_buffer, pipeline->fragment_descriptor_memory);
        pipeline->fragment_descriptor_buffer = VK_NULL_HANDLE;
        pipeline->fragment_descriptor_memory = VK_NULL_HANDLE;
    }
    CARDINAL_LOG_DEBUG("[MESH_SHADER] Destroyed descriptor buffers");
    
    if (pipeline->pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(vulkan_state->device, pipeline->pipeline, NULL);
    }
    if (pipeline->pipeline_layout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(vulkan_state->device, pipeline->pipeline_layout, NULL);
    }
    
    // Clean up descriptor set layouts
    if (pipeline->descriptor_layout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(vulkan_state->device, pipeline->descriptor_layout, NULL);
    }
    if (pipeline->fragment_descriptor_layout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(vulkan_state->device, pipeline->fragment_descriptor_layout, NULL);
    }
    
    // Clean up placeholder resources
    if (pipeline->placeholder_buffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(vulkan_state->device, pipeline->placeholder_buffer, NULL);
    }
    if (pipeline->placeholder_buffer_memory != VK_NULL_HANDLE) {
        vkFreeMemory(vulkan_state->device, pipeline->placeholder_buffer_memory, NULL);
    }
    
    memset(pipeline, 0, sizeof(MeshShaderPipeline));
    
    CARDINAL_LOG_INFO("[MESH_SHADER] Pipeline destroyed");
}

bool vk_mesh_shader_update_descriptor_buffers(VulkanState* vulkan_state,
                                               MeshShaderPipeline* pipeline,
                                               const MeshShaderDrawData* draw_data,
                                               VkBuffer material_buffer,
                                               VkBuffer lighting_buffer,
                                               VkImageView* texture_views,
                                               VkSampler sampler,
                                               uint32_t texture_count) {
    if (!vulkan_state || !pipeline) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Invalid parameters for descriptor buffer update");
        return false;
    }
    
    // Always use descriptor buffers - no fallback to descriptor sets
    
    VkDeviceSize current_offset = 0;
    
    // Update mesh descriptor buffer (Set 0) - only if draw_data is provided
    if (draw_data && pipeline->mesh_descriptor_buffer != VK_NULL_HANDLE) {
        current_offset = 0;
        
        // Binding 0: Meshlet buffer
        if (draw_data->meshlet_buffer != VK_NULL_HANDLE) {
            if (!vk_descriptor_buffer_write_storage_buffer(vulkan_state, pipeline->mesh_descriptor_buffer,
                                                           current_offset, draw_data->meshlet_buffer, 0, VK_WHOLE_SIZE)) {
                CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to write meshlet buffer to descriptor buffer");
                return false;
            }
            current_offset += vulkan_state->descriptor_buffer_uniform_buffer_size;
        }
        
        // Binding 1: Vertex buffer
        if (draw_data->vertex_buffer != VK_NULL_HANDLE) {
            if (!vk_descriptor_buffer_write_storage_buffer(vulkan_state, pipeline->mesh_descriptor_buffer,
                                                           current_offset, draw_data->vertex_buffer, 0, VK_WHOLE_SIZE)) {
                CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to write vertex buffer to descriptor buffer");
                return false;
            }
            current_offset += vulkan_state->descriptor_buffer_uniform_buffer_size;
        }
        
        // Skip binding 2 (transform buffer) for now
        current_offset += vulkan_state->descriptor_buffer_uniform_buffer_size;
        
        // Binding 3: Primitive buffer
        if (draw_data->primitive_buffer != VK_NULL_HANDLE) {
            if (!vk_descriptor_buffer_write_storage_buffer(vulkan_state, pipeline->mesh_descriptor_buffer,
                                                           current_offset, draw_data->primitive_buffer, 0, VK_WHOLE_SIZE)) {
                CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to write primitive buffer to descriptor buffer");
                return false;
            }
        }
    }
    
    // Update fragment descriptor buffer (Set 1)
    if (pipeline->fragment_descriptor_buffer != VK_NULL_HANDLE) {
        current_offset = 0;
        
        // Binding 0: Material buffer
        if (material_buffer != VK_NULL_HANDLE) {
            if (!vk_descriptor_buffer_write_uniform_buffer(vulkan_state, pipeline->fragment_descriptor_buffer,
                                                           current_offset, material_buffer, 0, VK_WHOLE_SIZE)) {
                CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to write material buffer to descriptor buffer");
                return false;
            }
            current_offset += vulkan_state->descriptor_buffer_uniform_buffer_size;
        }
        
        // Binding 1: Lighting buffer
        if (lighting_buffer != VK_NULL_HANDLE) {
            if (!vk_descriptor_buffer_write_uniform_buffer(vulkan_state, pipeline->fragment_descriptor_buffer,
                                                           current_offset, lighting_buffer, 0, VK_WHOLE_SIZE)) {
                CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to write lighting buffer to descriptor buffer");
                return false;
            }
            current_offset += vulkan_state->descriptor_buffer_uniform_buffer_size;
        }
        
        // Skip binding 2 (material buffer for bindless)
        current_offset += vulkan_state->descriptor_buffer_uniform_buffer_size;
        
        // Bindings 3-7: Texture samplers
        if (texture_views && sampler != VK_NULL_HANDLE && texture_count > 0) {
            uint32_t tex_count = texture_count < 5 ? texture_count : 5;
            for (uint32_t i = 0; i < tex_count; i++) {
                if (!vk_descriptor_buffer_write_combined_image_sampler(vulkan_state, pipeline->fragment_descriptor_buffer,
                                                                       current_offset, texture_views[i], sampler, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
                    CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to write texture %u to descriptor buffer", i);
                    return false;
                }
                current_offset += vulkan_state->descriptor_buffer_combined_image_sampler_size;
            }
        }
    }
    
    CARDINAL_LOG_DEBUG("[MESH_SHADER] Updated descriptor buffers");
    return true;
}

void vk_mesh_shader_draw(VkCommandBuffer cmd_buffer,
                          VulkanState* vulkan_state,
                          const MeshShaderPipeline* pipeline,
                          const MeshShaderDrawData* draw_data) {
    if (!cmd_buffer || !vulkan_state || !pipeline || !draw_data || !vkCmdDrawMeshTasksEXT_func) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Invalid parameters for draw command");
        return;
    }
    
    // Bind pipeline
    vkCmdBindPipeline(cmd_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline->pipeline);
    
    // Bind descriptor buffers if extension is available
    if (vulkan_state->descriptor_buffer_extension_available) {
        VkBuffer descriptor_buffers[2] = {
            pipeline->mesh_descriptor_buffer,
            pipeline->fragment_descriptor_buffer
        };
        VkDeviceSize buffer_offsets[2] = {
            pipeline->mesh_descriptor_offset,
            pipeline->fragment_descriptor_offset
        };
        
        if (descriptor_buffers[0] != VK_NULL_HANDLE || descriptor_buffers[1] != VK_NULL_HANDLE) {
            // First bind the descriptor buffers
            vk_descriptor_buffer_bind(cmd_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                     pipeline->pipeline_layout, 0, 2,
                                     descriptor_buffers, buffer_offsets, vulkan_state);
            
            // Then set the descriptor buffer offsets for each set
            uint32_t buffer_indices[2] = {0, 1}; // Buffer indices for sets 0 and 1
            vk_descriptor_buffer_set_offsets(cmd_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                            pipeline->pipeline_layout, 0, 2,
                                            buffer_indices, buffer_offsets, vulkan_state);
        }
    }
    
    // Draw mesh tasks
    uint32_t task_count = (draw_data->meshlet_count + pipeline->max_meshlets_per_workgroup - 1) / 
                         pipeline->max_meshlets_per_workgroup;
    
    vkCmdDrawMeshTasksEXT_func(cmd_buffer, task_count, 1, 1);
}

bool vk_mesh_shader_generate_meshlets(const void* vertices,
                                       uint32_t vertex_count,
                                       const uint32_t* indices,
                                       uint32_t index_count,
                                       uint32_t max_vertices_per_meshlet,
                                       uint32_t max_primitives_per_meshlet,
                                       GpuMeshlet** out_meshlets,
                                       uint32_t* out_meshlet_count) {
    (void)max_vertices_per_meshlet; // Suppress unused parameter warning
    if (!vertices || !indices || !out_meshlets || !out_meshlet_count) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Invalid parameters for meshlet generation");
        return false;
    }
    
    // Simple meshlet generation - divide triangles into groups
    uint32_t triangle_count = index_count / 3;
    uint32_t triangles_per_meshlet = max_primitives_per_meshlet;
    uint32_t meshlet_count = (triangle_count + triangles_per_meshlet - 1) / triangles_per_meshlet;
    
    *out_meshlets = (GpuMeshlet*)malloc(sizeof(GpuMeshlet) * meshlet_count);
    if (!*out_meshlets) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to allocate memory for meshlets");
        return false;
    }
    
    for (uint32_t i = 0; i < meshlet_count; i++) {
        uint32_t start_triangle = i * triangles_per_meshlet;
        uint32_t end_triangle = (start_triangle + triangles_per_meshlet < triangle_count) ? 
                               start_triangle + triangles_per_meshlet : triangle_count;
        
        (*out_meshlets)[i].primitive_offset = start_triangle * 3;
        (*out_meshlets)[i].primitive_count = (end_triangle - start_triangle) * 3;
        (*out_meshlets)[i].vertex_offset = 0; // Simplified - use global vertex buffer
        (*out_meshlets)[i].vertex_count = vertex_count; // Simplified - reference all vertices
    }
    
    *out_meshlet_count = meshlet_count;
    CARDINAL_LOG_INFO("[MESH_SHADER] Generated %u meshlets from %u triangles", meshlet_count, triangle_count);
    return true;
}

bool vk_mesh_shader_create_draw_data(VulkanState* vulkan_state,
                                      const GpuMeshlet* meshlets,
                                      uint32_t meshlet_count,
                                      const void* vertices,
                                      uint32_t vertex_size,
                                      const uint32_t* primitives,
                                      uint32_t primitive_count,
                                      MeshShaderDrawData* draw_data) {
    if (!vulkan_state || !meshlets || !vertices || !primitives || !draw_data) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Invalid parameters for draw data creation");
        return false;
    }
    
    memset(draw_data, 0, sizeof(MeshShaderDrawData));
    
    // Initialize memory handles and counts
    draw_data->vertex_memory = VK_NULL_HANDLE;
    draw_data->meshlet_memory = VK_NULL_HANDLE;
    draw_data->primitive_memory = VK_NULL_HANDLE;
    draw_data->draw_command_memory = VK_NULL_HANDLE;
    draw_data->meshlet_count = meshlet_count;
    draw_data->draw_command_count = 1; // Single draw command for now
    
    // Create vertex buffer
    if (!vk_buffer_create(&vulkan_state->allocator, vertex_size, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &draw_data->vertex_buffer, &draw_data->vertex_memory)) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create vertex buffer");
        return false;
    }
    
    // Create meshlet buffer
    uint32_t meshlet_buffer_size = sizeof(GpuMeshlet) * meshlet_count;
    if (!vk_buffer_create(&vulkan_state->allocator, meshlet_buffer_size, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &draw_data->meshlet_buffer, &draw_data->meshlet_memory)) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create meshlet buffer");
        goto cleanup_vertex;
    }
    
    // Create primitive buffer
    uint32_t primitive_buffer_size = sizeof(uint32_t) * primitive_count;
    if (!vk_buffer_create(&vulkan_state->allocator, primitive_buffer_size, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &draw_data->primitive_buffer, &draw_data->primitive_memory)) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create primitive buffer");
        goto cleanup_meshlet;
    }
    
    // Create draw command buffer
    uint32_t draw_command_size = sizeof(GpuDrawCommand) * draw_data->draw_command_count;
    if (!vk_buffer_create(&vulkan_state->allocator, draw_command_size, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &draw_data->draw_command_buffer, &draw_data->draw_command_memory)) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to create draw command buffer");
        goto cleanup_primitive;
    }
    
    // TODO: Upload data to buffers (requires buffer mapping functionality)
    
    CARDINAL_LOG_INFO("[MESH_SHADER] Draw data created successfully");
    return true;
    
cleanup_primitive:
    vk_allocator_free_buffer(&vulkan_state->allocator, draw_data->primitive_buffer, draw_data->primitive_memory);
cleanup_meshlet:
    vk_allocator_free_buffer(&vulkan_state->allocator, draw_data->meshlet_buffer, draw_data->meshlet_memory);
cleanup_vertex:
    vk_allocator_free_buffer(&vulkan_state->allocator, draw_data->vertex_buffer, draw_data->vertex_memory);
    return false;
}

void vk_mesh_shader_destroy_draw_data(VulkanState* vulkan_state, MeshShaderDrawData* draw_data) {
    if (!vulkan_state || !draw_data) {
        return;
    }
    
    // Clean up buffers using allocator with proper memory handles
    if (draw_data->vertex_buffer != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(&vulkan_state->allocator, draw_data->vertex_buffer, draw_data->vertex_memory);
        draw_data->vertex_buffer = VK_NULL_HANDLE;
        draw_data->vertex_memory = VK_NULL_HANDLE;
    }
    
    if (draw_data->meshlet_buffer != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(&vulkan_state->allocator, draw_data->meshlet_buffer, draw_data->meshlet_memory);
        draw_data->meshlet_buffer = VK_NULL_HANDLE;
        draw_data->meshlet_memory = VK_NULL_HANDLE;
    }
    
    if (draw_data->primitive_buffer != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(&vulkan_state->allocator, draw_data->primitive_buffer, draw_data->primitive_memory);
        draw_data->primitive_buffer = VK_NULL_HANDLE;
        draw_data->primitive_memory = VK_NULL_HANDLE;
    }
    
    if (draw_data->draw_command_buffer != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(&vulkan_state->allocator, draw_data->draw_command_buffer, draw_data->draw_command_memory);
        draw_data->draw_command_buffer = VK_NULL_HANDLE;
        draw_data->draw_command_memory = VK_NULL_HANDLE;
    }
    
    memset(draw_data, 0, sizeof(MeshShaderDrawData));
    CARDINAL_LOG_INFO("[MESH_SHADER] Draw data destroyed");
}

bool vk_mesh_shader_add_pending_cleanup(VulkanState* vulkan_state,
                                         const MeshShaderDrawData* draw_data) {
    if (!vulkan_state || !draw_data) {
        return false;
    }
    
    // Initialize pending cleanup list if needed
    if (vulkan_state->pending_cleanup_draw_data == NULL) {
        vulkan_state->pending_cleanup_capacity = 16;
        vulkan_state->pending_cleanup_draw_data = malloc(sizeof(MeshShaderDrawData) * vulkan_state->pending_cleanup_capacity);
        if (!vulkan_state->pending_cleanup_draw_data) {
            CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to allocate pending cleanup list");
            return false;
        }
        vulkan_state->pending_cleanup_count = 0;
    }
    
    // Resize if needed
    if (vulkan_state->pending_cleanup_count >= vulkan_state->pending_cleanup_capacity) {
        uint32_t new_capacity = vulkan_state->pending_cleanup_capacity * 2;
        MeshShaderDrawData* new_list = realloc(vulkan_state->pending_cleanup_draw_data, 
                                               sizeof(MeshShaderDrawData) * new_capacity);
        if (!new_list) {
            CARDINAL_LOG_ERROR("[MESH_SHADER] Failed to resize pending cleanup list");
            return false;
        }
        vulkan_state->pending_cleanup_draw_data = new_list;
        vulkan_state->pending_cleanup_capacity = new_capacity;
    }
    
    // Add to pending cleanup list
    vulkan_state->pending_cleanup_draw_data[vulkan_state->pending_cleanup_count] = *draw_data;
    vulkan_state->pending_cleanup_count++;
    
    CARDINAL_LOG_DEBUG("[MESH_SHADER] Added draw data to pending cleanup list (count: %u)", 
                       vulkan_state->pending_cleanup_count);
    return true;
}

void vk_mesh_shader_process_pending_cleanup(VulkanState* vulkan_state) {
    if (!vulkan_state || !vulkan_state->pending_cleanup_draw_data || vulkan_state->pending_cleanup_count == 0) {
        return;
    }
    
    CARDINAL_LOG_DEBUG("[MESH_SHADER] Processing %u pending draw data cleanups", 
                       vulkan_state->pending_cleanup_count);
    
    // Clean up all pending draw data
    for (uint32_t i = 0; i < vulkan_state->pending_cleanup_count; i++) {
        vk_mesh_shader_destroy_draw_data(vulkan_state, &vulkan_state->pending_cleanup_draw_data[i]);
    }
    
    // Reset the list
    vulkan_state->pending_cleanup_count = 0;
    
    CARDINAL_LOG_DEBUG("[MESH_SHADER] Completed pending draw data cleanup");
}

bool vk_mesh_shader_convert_scene_mesh(const CardinalMesh* mesh,
                                        uint32_t max_vertices_per_meshlet,
                                        uint32_t max_primitives_per_meshlet,
                                        GpuMeshlet** out_meshlets,
                                        uint32_t* out_meshlet_count) {
    if (!mesh || !out_meshlets || !out_meshlet_count) {
        CARDINAL_LOG_ERROR("[MESH_SHADER] Invalid parameters for scene mesh conversion");
        return false;
    }
    
    return vk_mesh_shader_generate_meshlets(mesh->vertices, mesh->vertex_count,
                                             mesh->indices, mesh->index_count,
                                             max_vertices_per_meshlet, max_primitives_per_meshlet,
                                             out_meshlets, out_meshlet_count);
}