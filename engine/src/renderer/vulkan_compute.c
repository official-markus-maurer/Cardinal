#include "cardinal/renderer/vulkan_compute.h"
#include "vulkan_state.h"
#include "cardinal/renderer/util/vulkan_shader_utils.h"
#include "cardinal/core/log.h"
#include <string.h>
#include <stdlib.h>

bool vk_compute_init(VulkanState* vulkan_state) {
    if (!vulkan_state) {
        CARDINAL_LOG_ERROR("[COMPUTE] Invalid vulkan state for compute initialization");
        return false;
    }
    
    CARDINAL_LOG_INFO("[COMPUTE] Compute shader support initialized");
    return true;
}

void vk_compute_cleanup(VulkanState* vulkan_state) {
    if (!vulkan_state) {
        return;
    }
    
    CARDINAL_LOG_INFO("[COMPUTE] Compute shader support cleaned up");
}

bool vk_compute_validate_config(VulkanState* vulkan_state,
                                 const ComputePipelineConfig* config) {
    if (!vulkan_state || !config) {
        CARDINAL_LOG_ERROR("[COMPUTE] Invalid parameters for config validation");
        return false;
    }
    
    if (!config->compute_shader_path || strlen(config->compute_shader_path) == 0) {
        CARDINAL_LOG_ERROR("[COMPUTE] Compute shader path is required");
        return false;
    }
    
    // Validate local workgroup sizes
    if (config->local_size_x == 0 || config->local_size_y == 0 || config->local_size_z == 0) {
        CARDINAL_LOG_ERROR("[COMPUTE] Local workgroup sizes must be greater than 0");
        return false;
    }
    
    // Check device limits
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(vulkan_state->physical_device, &properties);
    
    if (config->local_size_x > properties.limits.maxComputeWorkGroupSize[0] ||
        config->local_size_y > properties.limits.maxComputeWorkGroupSize[1] ||
        config->local_size_z > properties.limits.maxComputeWorkGroupSize[2]) {
        CARDINAL_LOG_ERROR("[COMPUTE] Local workgroup sizes exceed device limits");
        return false;
    }
    
    uint32_t total_invocations = config->local_size_x * config->local_size_y * config->local_size_z;
    if (total_invocations > properties.limits.maxComputeWorkGroupInvocations) {
        CARDINAL_LOG_ERROR("[COMPUTE] Total workgroup invocations (%u) exceed device limit (%u)",
                          total_invocations, properties.limits.maxComputeWorkGroupInvocations);
        return false;
    }
    
    return true;
}

bool vk_compute_create_descriptor_layout(VulkanState* vulkan_state,
                                          const VkDescriptorSetLayoutBinding* bindings,
                                          uint32_t binding_count,
                                          VkDescriptorSetLayout* layout) {
    if (!vulkan_state || !bindings || binding_count == 0 || !layout) {
        CARDINAL_LOG_ERROR("[COMPUTE] Invalid parameters for descriptor layout creation");
        return false;
    }
    
    VkDescriptorSetLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = binding_count,
        .pBindings = bindings
    };
    
    VkResult result = vkCreateDescriptorSetLayout(vulkan_state->device, &layout_info, NULL, layout);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[COMPUTE] Failed to create descriptor set layout: %d", result);
        return false;
    }
    
    return true;
}

bool vk_compute_create_pipeline(VulkanState* vulkan_state,
                                 const ComputePipelineConfig* config,
                                 ComputePipeline* pipeline) {
    if (!vulkan_state || !config || !pipeline) {
        CARDINAL_LOG_ERROR("[COMPUTE] Invalid parameters for compute pipeline creation");
        return false;
    }
    
    // Validate configuration
    if (!vk_compute_validate_config(vulkan_state, config)) {
        return false;
    }
    
    // Initialize pipeline structure
    memset(pipeline, 0, sizeof(ComputePipeline));
    
    VkResult result;
    
    // Load compute shader
    VkShaderModule compute_shader = VK_NULL_HANDLE;
    if (!vk_shader_create_module(vulkan_state->device, config->compute_shader_path, &compute_shader)) {
        CARDINAL_LOG_ERROR("[COMPUTE] Failed to load compute shader: %s", config->compute_shader_path);
        return false;
    }
    
    // Create pipeline layout
    VkPushConstantRange push_constant_range = {0};
    VkPipelineLayoutCreateInfo pipeline_layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = config->descriptor_set_count,
        .pSetLayouts = config->descriptor_layouts,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = NULL
    };
    
    // Add push constants if specified
    if (config->push_constant_size > 0) {
        push_constant_range.stageFlags = config->push_constant_stages;
        push_constant_range.offset = 0;
        push_constant_range.size = config->push_constant_size;
        
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &push_constant_range;
    }
    
    result = vkCreatePipelineLayout(vulkan_state->device, &pipeline_layout_info, NULL, &pipeline->pipeline_layout);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[COMPUTE] Failed to create pipeline layout: %d", result);
        vkDestroyShaderModule(vulkan_state->device, compute_shader, NULL);
        return false;
    }
    
    // Create compute pipeline
    VkPipelineShaderStageCreateInfo shader_stage = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_COMPUTE_BIT,
        .module = compute_shader,
        .pName = "main"
    };
    
    VkComputePipelineCreateInfo pipeline_info = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = shader_stage,
        .layout = pipeline->pipeline_layout,
        .basePipelineHandle = VK_NULL_HANDLE,
        .basePipelineIndex = -1
    };
    
    result = vkCreateComputePipelines(vulkan_state->device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &pipeline->pipeline);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[COMPUTE] Failed to create compute pipeline: %d", result);
        vkDestroyPipelineLayout(vulkan_state->device, pipeline->pipeline_layout, NULL);
        vkDestroyShaderModule(vulkan_state->device, compute_shader, NULL);
        return false;
    }
    
    // Clean up shader module
    vkDestroyShaderModule(vulkan_state->device, compute_shader, NULL);
    
    // Store pipeline configuration
    pipeline->descriptor_set_count = config->descriptor_set_count;
    pipeline->push_constant_size = config->push_constant_size;
    pipeline->push_constant_stages = config->push_constant_stages;
    pipeline->local_size_x = config->local_size_x;
    pipeline->local_size_y = config->local_size_y;
    pipeline->local_size_z = config->local_size_z;
    pipeline->initialized = true;
    
    // Copy descriptor layouts if provided
    if (config->descriptor_set_count > 0 && config->descriptor_layouts) {
        pipeline->descriptor_layouts = malloc(config->descriptor_set_count * sizeof(VkDescriptorSetLayout));
        if (pipeline->descriptor_layouts) {
            memcpy(pipeline->descriptor_layouts, config->descriptor_layouts,
                   config->descriptor_set_count * sizeof(VkDescriptorSetLayout));
        }
    }
    
    CARDINAL_LOG_INFO("[COMPUTE] Created compute pipeline with local size (%u, %u, %u)",
                     config->local_size_x, config->local_size_y, config->local_size_z);
    
    return true;
}

void vk_compute_destroy_pipeline(VulkanState* vulkan_state,
                                  ComputePipeline* pipeline) {
    if (!vulkan_state || !pipeline || !pipeline->initialized) {
        return;
    }
    
    if (pipeline->pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(vulkan_state->device, pipeline->pipeline, NULL);
        pipeline->pipeline = VK_NULL_HANDLE;
    }
    
    if (pipeline->pipeline_layout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(vulkan_state->device, pipeline->pipeline_layout, NULL);
        pipeline->pipeline_layout = VK_NULL_HANDLE;
    }
    
    if (pipeline->descriptor_layouts) {
        free(pipeline->descriptor_layouts);
        pipeline->descriptor_layouts = NULL;
    }
    
    pipeline->initialized = false;
    
    CARDINAL_LOG_DEBUG("[COMPUTE] Destroyed compute pipeline");
}

void vk_compute_dispatch(VkCommandBuffer cmd_buffer,
                          const ComputePipeline* pipeline,
                          const ComputeDispatchInfo* dispatch_info) {
    if (!cmd_buffer || !pipeline || !dispatch_info || !pipeline->initialized) {
        CARDINAL_LOG_ERROR("[COMPUTE] Invalid parameters for compute dispatch");
        return;
    }
    
    // Bind compute pipeline
    vkCmdBindPipeline(cmd_buffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline->pipeline);
    
    // Bind descriptor sets if provided
    if (dispatch_info->descriptor_sets && dispatch_info->descriptor_set_count > 0) {
        vkCmdBindDescriptorSets(cmd_buffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                               pipeline->pipeline_layout, 0,
                               dispatch_info->descriptor_set_count,
                               dispatch_info->descriptor_sets, 0, NULL);
    }
    
    // Push constants if provided
    if (dispatch_info->push_constants && dispatch_info->push_constant_size > 0) {
        vkCmdPushConstants(cmd_buffer, pipeline->pipeline_layout,
                          pipeline->push_constant_stages, 0,
                          dispatch_info->push_constant_size,
                          dispatch_info->push_constants);
    }
    
    // Dispatch compute work
    vkCmdDispatch(cmd_buffer, dispatch_info->group_count_x,
                  dispatch_info->group_count_y, dispatch_info->group_count_z);
}

void vk_compute_memory_barrier(VkCommandBuffer cmd_buffer,
                                const ComputeMemoryBarrier* barrier) {
    if (!cmd_buffer || !barrier) {
        CARDINAL_LOG_ERROR("[COMPUTE] Invalid parameters for memory barrier");
        return;
    }
    
    VkMemoryBarrier memory_barrier = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = barrier->src_access_mask,
        .dstAccessMask = barrier->dst_access_mask
    };
    
    vkCmdPipelineBarrier(cmd_buffer,
                        barrier->src_stage_mask, barrier->dst_stage_mask,
                        0, 1, &memory_barrier, 0, NULL, 0, NULL);
}

uint32_t vk_compute_calculate_workgroups(uint32_t total_work_items, uint32_t local_size) {
    if (local_size == 0) {
        CARDINAL_LOG_ERROR("[COMPUTE] Local size cannot be zero");
        return 0;
    }
    
    return (total_work_items + local_size - 1) / local_size;
}