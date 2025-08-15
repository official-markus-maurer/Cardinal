/**
 * @file vulkan_simple_pipelines.c
 * @brief Simple pipeline implementations for UV and wireframe rendering modes
 * 
 * This file contains the implementation of simplified rendering pipelines for
 * UV visualization and wireframe rendering modes. These pipelines use basic
 * vertex/fragment shaders and simplified descriptor sets compared to the full PBR pipeline.
 * 
 * @author Markus Maurer
 * @version 1.0
 */

#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "vulkan_state.h"
#include "cardinal/core/log.h"
#include <cardinal/renderer/util/vulkan_shader_utils.h>
#include <cardinal/renderer/util/vulkan_descriptor_utils.h>
#include <cardinal/renderer/util/vulkan_buffer_utils.h>
#include <cardinal/renderer/vulkan_pbr.h>

/**
 * @brief Simple uniform buffer object for UV and wireframe pipelines
 */
typedef struct SimpleUniformBufferObject {
    float model[16];     // mat4
    float view[16];      // mat4
    float proj[16];      // mat4
} SimpleUniformBufferObject;

/**
 * @brief Creates the shared descriptor set layout for simple pipelines
 * @param s Vulkan state
 * @return true on success, false on failure
 */
static bool create_simple_descriptor_layout(VulkanState* s) {
    VkDescriptorSetLayoutBinding uboLayoutBinding = {0};
    uboLayoutBinding.binding = 0;
    uboLayoutBinding.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    uboLayoutBinding.descriptorCount = 1;
    uboLayoutBinding.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    uboLayoutBinding.pImmutableSamplers = NULL;

    VkDescriptorSetLayoutCreateInfo layoutInfo = {0};
    layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = 1;
    layoutInfo.pBindings = &uboLayoutBinding;

    if (vkCreateDescriptorSetLayout(s->device, &layoutInfo, NULL, &s->simple_descriptor_layout) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create simple descriptor set layout!");
        return false;
    }

    return true;
}

/**
 * @brief Creates the shared uniform buffer for simple pipelines
 * @param s Vulkan state
 * @return true on success, false on failure
 */
static bool create_simple_uniform_buffer(VulkanState* s) {
    VkDeviceSize bufferSize = sizeof(SimpleUniformBufferObject);

    if (!vk_buffer_create(&s->allocator, bufferSize,
                         VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &s->simple_uniform_buffer, &s->simple_uniform_buffer_memory)) {
        CARDINAL_LOG_ERROR("Failed to create simple uniform buffer!");
        return false;
    }

    // Map the buffer memory
    if (vkMapMemory(s->device, s->simple_uniform_buffer_memory, 0, bufferSize, 0, &s->simple_uniform_buffer_mapped) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map simple uniform buffer memory!");
        return false;
    }

    return true;
}

/**
 * @brief Creates the descriptor pool and sets for simple pipelines
 * @param s Vulkan state
 * @return true on success, false on failure
 */
static bool create_simple_descriptor_pool(VulkanState* s) {
    VkDescriptorPoolSize poolSize = {0};
    poolSize.type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    poolSize.descriptorCount = 1;

    VkDescriptorPoolCreateInfo poolInfo = {0};
    poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.poolSizeCount = 1;
    poolInfo.pPoolSizes = &poolSize;
    poolInfo.maxSets = 1;

    if (vkCreateDescriptorPool(s->device, &poolInfo, NULL, &s->simple_descriptor_pool) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create simple descriptor pool!");
        return false;
    }

    VkDescriptorSetAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool = s->simple_descriptor_pool;
    allocInfo.descriptorSetCount = 1;
    allocInfo.pSetLayouts = &s->simple_descriptor_layout;

    if (vkAllocateDescriptorSets(s->device, &allocInfo, &s->simple_descriptor_set) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate simple descriptor set!");
        return false;
    }

    VkDescriptorBufferInfo bufferInfo = {0};
    bufferInfo.buffer = s->simple_uniform_buffer;
    bufferInfo.offset = 0;
    bufferInfo.range = sizeof(SimpleUniformBufferObject);

    VkWriteDescriptorSet descriptorWrite = {0};
    descriptorWrite.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrite.dstSet = s->simple_descriptor_set;
    descriptorWrite.dstBinding = 0;
    descriptorWrite.dstArrayElement = 0;
    descriptorWrite.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrite.descriptorCount = 1;
    descriptorWrite.pBufferInfo = &bufferInfo;

    vkUpdateDescriptorSets(s->device, 1, &descriptorWrite, 0, NULL);

    return true;
}

/**
 * @brief Creates a simple graphics pipeline
 * @param s Vulkan state
 * @param vertShaderPath Path to vertex shader SPIR-V file
 * @param fragShaderPath Path to fragment shader SPIR-V file
 * @param pipeline Output pipeline handle
 * @param pipelineLayout Output pipeline layout handle
 * @param wireframe Whether to enable wireframe mode
 * @return true on success, false on failure
 */
static bool create_simple_pipeline(VulkanState* s, const char* vertShaderPath, const char* fragShaderPath,
                                  VkPipeline* pipeline, VkPipelineLayout* pipelineLayout, bool wireframe) {
    // Load shaders
    VkShaderModule vertShaderModule = VK_NULL_HANDLE;
    VkShaderModule fragShaderModule = VK_NULL_HANDLE;
    
    if (!vk_shader_create_module(s->device, vertShaderPath, &vertShaderModule) ||
        !vk_shader_create_module(s->device, fragShaderPath, &fragShaderModule)) {
        CARDINAL_LOG_ERROR("Failed to load simple pipeline shaders");
        if (vertShaderModule != VK_NULL_HANDLE) vkDestroyShaderModule(s->device, vertShaderModule, NULL);
        if (fragShaderModule != VK_NULL_HANDLE) vkDestroyShaderModule(s->device, fragShaderModule, NULL);
        return false;
    }

    VkPipelineShaderStageCreateInfo vertShaderStageInfo = {0};
    vertShaderStageInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    vertShaderStageInfo.stage = VK_SHADER_STAGE_VERTEX_BIT;
    vertShaderStageInfo.module = vertShaderModule;
    vertShaderStageInfo.pName = "main";

    VkPipelineShaderStageCreateInfo fragShaderStageInfo = {0};
    fragShaderStageInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    fragShaderStageInfo.stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    fragShaderStageInfo.module = fragShaderModule;
    fragShaderStageInfo.pName = "main";

    VkPipelineShaderStageCreateInfo shaderStages[] = {vertShaderStageInfo, fragShaderStageInfo};

    // Vertex input (same as PBR pipeline)
    VkVertexInputBindingDescription bindingDescription = {0};
    bindingDescription.binding = 0;
    bindingDescription.stride = sizeof(CardinalVertex);
    bindingDescription.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

    VkVertexInputAttributeDescription attributeDescriptions[3] = {0};
    // Position
    attributeDescriptions[0].binding = 0;
    attributeDescriptions[0].location = 0;
    attributeDescriptions[0].format = VK_FORMAT_R32G32B32_SFLOAT;
    attributeDescriptions[0].offset = offsetof(CardinalVertex, px);
    // Normal
    attributeDescriptions[1].binding = 0;
    attributeDescriptions[1].location = 1;
    attributeDescriptions[1].format = VK_FORMAT_R32G32B32_SFLOAT;
    attributeDescriptions[1].offset = offsetof(CardinalVertex, nx);
    // UV
    attributeDescriptions[2].binding = 0;
    attributeDescriptions[2].location = 2;
    attributeDescriptions[2].format = VK_FORMAT_R32G32_SFLOAT;
    attributeDescriptions[2].offset = offsetof(CardinalVertex, u);

    VkPipelineVertexInputStateCreateInfo vertexInputInfo = {0};
    vertexInputInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertexInputInfo.vertexBindingDescriptionCount = 1;
    vertexInputInfo.pVertexBindingDescriptions = &bindingDescription;
    vertexInputInfo.vertexAttributeDescriptionCount = 3;
    vertexInputInfo.pVertexAttributeDescriptions = attributeDescriptions;

    VkPipelineInputAssemblyStateCreateInfo inputAssembly = {0};
    inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    inputAssembly.primitiveRestartEnable = VK_FALSE;

    VkPipelineViewportStateCreateInfo viewportState = {0};
    viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewportState.viewportCount = 1;
    viewportState.scissorCount = 1;

    VkPipelineRasterizationStateCreateInfo rasterizer = {0};
    rasterizer.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.depthClampEnable = VK_FALSE;
    rasterizer.rasterizerDiscardEnable = VK_FALSE;
    rasterizer.polygonMode = wireframe ? VK_POLYGON_MODE_LINE : VK_POLYGON_MODE_FILL;
    rasterizer.lineWidth = 1.0f;
    rasterizer.cullMode = VK_CULL_MODE_NONE;
    rasterizer.frontFace = VK_FRONT_FACE_CLOCKWISE;
    rasterizer.depthBiasEnable = VK_FALSE;

    VkPipelineMultisampleStateCreateInfo multisampling = {0};
    multisampling.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.sampleShadingEnable = VK_FALSE;
    multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    VkPipelineDepthStencilStateCreateInfo depthStencil = {0};
    depthStencil.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depthStencil.depthTestEnable = VK_TRUE;
    depthStencil.depthWriteEnable = VK_TRUE;
    depthStencil.depthCompareOp = VK_COMPARE_OP_LESS;
    depthStencil.depthBoundsTestEnable = VK_FALSE;
    depthStencil.stencilTestEnable = VK_FALSE;

    VkPipelineColorBlendAttachmentState colorBlendAttachment = {0};
    colorBlendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    colorBlendAttachment.blendEnable = VK_FALSE;

    VkPipelineColorBlendStateCreateInfo colorBlending = {0};
    colorBlending.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    colorBlending.logicOpEnable = VK_FALSE;
    colorBlending.attachmentCount = 1;
    colorBlending.pAttachments = &colorBlendAttachment;

    VkDynamicState dynamicStates[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamicState = {0};
    dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicState.dynamicStateCount = 2;
    dynamicState.pDynamicStates = dynamicStates;

    // Create pipeline layout with push constants
    VkPushConstantRange pushConstantRange = {0};
    pushConstantRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
    pushConstantRange.offset = 0;
    pushConstantRange.size = sizeof(PBRPushConstants); // Size of full material data including texture transforms

    VkPipelineLayoutCreateInfo pipelineLayoutInfo = {0};
    pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    pipelineLayoutInfo.pSetLayouts = &s->simple_descriptor_layout;
    pipelineLayoutInfo.pushConstantRangeCount = 1;
    pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;

    if (vkCreatePipelineLayout(s->device, &pipelineLayoutInfo, NULL, pipelineLayout) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create simple pipeline layout!");
        vkDestroyShaderModule(s->device, vertShaderModule, NULL);
        vkDestroyShaderModule(s->device, fragShaderModule, NULL);
        return false;
    }

    VkGraphicsPipelineCreateInfo pipelineInfo = {0};
    pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipelineInfo.stageCount = 2;
    pipelineInfo.pStages = shaderStages;
    pipelineInfo.pVertexInputState = &vertexInputInfo;
    pipelineInfo.pInputAssemblyState = &inputAssembly;
    pipelineInfo.pViewportState = &viewportState;
    pipelineInfo.pRasterizationState = &rasterizer;
    pipelineInfo.pMultisampleState = &multisampling;
    pipelineInfo.pDepthStencilState = &depthStencil;
    pipelineInfo.pColorBlendState = &colorBlending;
    pipelineInfo.pDynamicState = &dynamicState;
    pipelineInfo.layout = *pipelineLayout;

    // Use dynamic rendering
    VkPipelineRenderingCreateInfo pipelineRenderingInfo = {0};
    pipelineRenderingInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    pipelineRenderingInfo.colorAttachmentCount = 1;
    VkFormat colorFormat = s->swapchain_format;
    pipelineRenderingInfo.pColorAttachmentFormats = &colorFormat;
    pipelineRenderingInfo.depthAttachmentFormat = s->depth_format;
    pipelineRenderingInfo.stencilAttachmentFormat = VK_FORMAT_UNDEFINED;
    pipelineInfo.pNext = &pipelineRenderingInfo;
    pipelineInfo.renderPass = VK_NULL_HANDLE;
    pipelineInfo.subpass = 0;

    if (vkCreateGraphicsPipelines(s->device, VK_NULL_HANDLE, 1, &pipelineInfo, NULL, pipeline) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create simple graphics pipeline!");
        vkDestroyPipelineLayout(s->device, *pipelineLayout, NULL);
        vkDestroyShaderModule(s->device, vertShaderModule, NULL);
        vkDestroyShaderModule(s->device, fragShaderModule, NULL);
        return false;
    }

    vkDestroyShaderModule(s->device, vertShaderModule, NULL);
    vkDestroyShaderModule(s->device, fragShaderModule, NULL);

    return true;
}

/**
 * @brief Creates UV and wireframe pipelines
 * @param s Vulkan state
 * @return true on success, false on failure
 */
bool vk_create_simple_pipelines(VulkanState* s) {
    // Create shared descriptor layout
    if (!create_simple_descriptor_layout(s)) {
        return false;
    }

    // Create shared uniform buffer
    if (!create_simple_uniform_buffer(s)) {
        return false;
    }

    // Create descriptor pool and sets
    if (!create_simple_descriptor_pool(s)) {
        return false;
    }

    // Create UV pipeline
    if (!create_simple_pipeline(s, "assets/shaders/uv.vert.spv", "assets/shaders/uv.frag.spv",
                               &s->uv_pipeline, &s->uv_pipeline_layout, false)) {
        CARDINAL_LOG_ERROR("Failed to create UV pipeline");
        return false;
    }

    // Create wireframe pipeline
    if (!create_simple_pipeline(s, "assets/shaders/wireframe.vert.spv", "assets/shaders/wireframe.frag.spv",
                               &s->wireframe_pipeline, &s->wireframe_pipeline_layout, true)) {
        CARDINAL_LOG_ERROR("Failed to create wireframe pipeline");
        return false;
    }

    CARDINAL_LOG_INFO("Simple pipelines created successfully");
    return true;
}

/**
 * @brief Destroys UV and wireframe pipelines
 * @param s Vulkan state
 */
void vk_destroy_simple_pipelines(VulkanState* s) {
    if (s->simple_uniform_buffer_mapped) {
        vkUnmapMemory(s->device, s->simple_uniform_buffer_memory);
        s->simple_uniform_buffer_mapped = NULL;
    }

    // Use allocator to properly free buffer and track memory
    if (s->simple_uniform_buffer != VK_NULL_HANDLE || s->simple_uniform_buffer_memory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(&s->allocator, s->simple_uniform_buffer, s->simple_uniform_buffer_memory);
        s->simple_uniform_buffer = VK_NULL_HANDLE;
        s->simple_uniform_buffer_memory = VK_NULL_HANDLE;
    }

    if (s->simple_descriptor_pool != VK_NULL_HANDLE) {
        vkDestroyDescriptorPool(s->device, s->simple_descriptor_pool, NULL);
        s->simple_descriptor_pool = VK_NULL_HANDLE;
    }

    if (s->simple_descriptor_layout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(s->device, s->simple_descriptor_layout, NULL);
        s->simple_descriptor_layout = VK_NULL_HANDLE;
    }

    if (s->uv_pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(s->device, s->uv_pipeline, NULL);
        s->uv_pipeline = VK_NULL_HANDLE;
    }

    if (s->uv_pipeline_layout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(s->device, s->uv_pipeline_layout, NULL);
        s->uv_pipeline_layout = VK_NULL_HANDLE;
    }

    if (s->wireframe_pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(s->device, s->wireframe_pipeline, NULL);
        s->wireframe_pipeline = VK_NULL_HANDLE;
    }

    if (s->wireframe_pipeline_layout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(s->device, s->wireframe_pipeline_layout, NULL);
        s->wireframe_pipeline_layout = VK_NULL_HANDLE;
    }
}

/**
 * @brief Updates the simple uniform buffer with current matrices
 * @param s Vulkan state
 * @param model Model matrix
 * @param view View matrix
 * @param proj Projection matrix
 */
void vk_update_simple_uniforms(VulkanState* s, const float* model, const float* view, const float* proj) {
    if (!s->simple_uniform_buffer_mapped) return;

    SimpleUniformBufferObject ubo;
    memcpy(ubo.model, model, sizeof(float) * 16);
    memcpy(ubo.view, view, sizeof(float) * 16);
    memcpy(ubo.proj, proj, sizeof(float) * 16);

    memcpy(s->simple_uniform_buffer_mapped, &ubo, sizeof(ubo));
}

/**
 * @brief Renders scene using a simple pipeline (UV or wireframe)
 * @param s Vulkan state
 * @param commandBuffer Command buffer to record into
 * @param pipeline Pipeline to use
 * @param pipelineLayout Pipeline layout to use
 */
void vk_render_simple(VulkanState* s, VkCommandBuffer commandBuffer, VkPipeline pipeline, VkPipelineLayout pipelineLayout) {
    if (!s->current_scene || !s->scene_meshes) return;

    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                           pipelineLayout, 0, 1, &s->simple_descriptor_set, 0, NULL);

    // Render each mesh
    for (uint32_t i = 0; i < s->scene_mesh_count; i++) {
        const GpuMesh* mesh = &s->scene_meshes[i];
        if (mesh->vbuf == VK_NULL_HANDLE) continue;

        // Prepare push constants with model matrix and material properties (same as PBR pipeline)
        if (i < s->current_scene->mesh_count) {
            const CardinalMesh* sceneMesh = &s->current_scene->meshes[i];
            PBRPushConstants pushConstants = {0};
            
            // Copy model matrix
            memcpy(pushConstants.modelMatrix, sceneMesh->transform, 16 * sizeof(float));
            
            // Set material properties for this mesh
            if (sceneMesh->material_index < s->current_scene->material_count) {
                const CardinalMaterial* material = &s->current_scene->materials[sceneMesh->material_index];
                
                memcpy(pushConstants.albedoFactor, material->albedo_factor, sizeof(float) * 3);
                pushConstants.metallicFactor = material->metallic_factor;
                memcpy(pushConstants.emissiveFactor, material->emissive_factor, sizeof(float) * 3);
                pushConstants.roughnessFactor = material->roughness_factor;
                pushConstants.normalScale = material->normal_scale;
                pushConstants.aoStrength = material->ao_strength;
                
                // Set texture transforms (only albedo transform is used in UV shader)
                memcpy(pushConstants.albedoTransform.offset, material->albedo_transform.offset, sizeof(float) * 2);
                memcpy(pushConstants.albedoTransform.scale, material->albedo_transform.scale, sizeof(float) * 2);
                pushConstants.albedoTransform.rotation = material->albedo_transform.rotation;
                
                // Set other transforms for completeness
                memcpy(pushConstants.normalTransform.offset, material->normal_transform.offset, sizeof(float) * 2);
                memcpy(pushConstants.normalTransform.scale, material->normal_transform.scale, sizeof(float) * 2);
                pushConstants.normalTransform.rotation = material->normal_transform.rotation;
                
                memcpy(pushConstants.metallicRoughnessTransform.offset, material->metallic_roughness_transform.offset, sizeof(float) * 2);
                memcpy(pushConstants.metallicRoughnessTransform.scale, material->metallic_roughness_transform.scale, sizeof(float) * 2);
                pushConstants.metallicRoughnessTransform.rotation = material->metallic_roughness_transform.rotation;
                
                memcpy(pushConstants.aoTransform.offset, material->ao_transform.offset, sizeof(float) * 2);
                memcpy(pushConstants.aoTransform.scale, material->ao_transform.scale, sizeof(float) * 2);
                pushConstants.aoTransform.rotation = material->ao_transform.rotation;
                
                memcpy(pushConstants.emissiveTransform.offset, material->emissive_transform.offset, sizeof(float) * 2);
                memcpy(pushConstants.emissiveTransform.scale, material->emissive_transform.scale, sizeof(float) * 2);
                pushConstants.emissiveTransform.rotation = material->emissive_transform.rotation;
            } else {
                // Use default material properties if no material is assigned
                pushConstants.albedoFactor[0] = pushConstants.albedoFactor[1] = pushConstants.albedoFactor[2] = 1.0f;
                pushConstants.metallicFactor = 0.0f;
                pushConstants.emissiveFactor[0] = pushConstants.emissiveFactor[1] = pushConstants.emissiveFactor[2] = 0.0f;
                pushConstants.roughnessFactor = 0.5f;
                pushConstants.normalScale = 1.0f;
                pushConstants.aoStrength = 1.0f;
                
                // Default texture transforms (identity)
                pushConstants.albedoTransform.scale[0] = pushConstants.albedoTransform.scale[1] = 1.0f;
                pushConstants.normalTransform.scale[0] = pushConstants.normalTransform.scale[1] = 1.0f;
                pushConstants.metallicRoughnessTransform.scale[0] = pushConstants.metallicRoughnessTransform.scale[1] = 1.0f;
                pushConstants.aoTransform.scale[0] = pushConstants.aoTransform.scale[1] = 1.0f;
                pushConstants.emissiveTransform.scale[0] = pushConstants.emissiveTransform.scale[1] = 1.0f;
                
                // Set default offsets and rotations to zero
                pushConstants.albedoTransform.offset[0] = pushConstants.albedoTransform.offset[1] = 0.0f;
                pushConstants.normalTransform.offset[0] = pushConstants.normalTransform.offset[1] = 0.0f;
                pushConstants.metallicRoughnessTransform.offset[0] = pushConstants.metallicRoughnessTransform.offset[1] = 0.0f;
                pushConstants.aoTransform.offset[0] = pushConstants.aoTransform.offset[1] = 0.0f;
                pushConstants.emissiveTransform.offset[0] = pushConstants.emissiveTransform.offset[1] = 0.0f;
                
                pushConstants.albedoTransform.rotation = 0.0f;
                pushConstants.normalTransform.rotation = 0.0f;
                pushConstants.metallicRoughnessTransform.rotation = 0.0f;
                pushConstants.aoTransform.rotation = 0.0f;
                pushConstants.emissiveTransform.rotation = 0.0f;
            }
            
            // Push constants to GPU
            vkCmdPushConstants(commandBuffer, pipelineLayout, 
                              VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                              0, sizeof(PBRPushConstants), &pushConstants);
        }

        VkBuffer vertexBuffers[] = {mesh->vbuf};
        VkDeviceSize offsets[] = {0};
        vkCmdBindVertexBuffers(commandBuffer, 0, 1, vertexBuffers, offsets);

        if (mesh->ibuf != VK_NULL_HANDLE && mesh->idx_count > 0) {
            vkCmdBindIndexBuffer(commandBuffer, mesh->ibuf, 0, VK_INDEX_TYPE_UINT32);
            vkCmdDrawIndexed(commandBuffer, mesh->idx_count, 1, 0, 0, 0);
        } else {
            vkCmdDraw(commandBuffer, mesh->vtx_count, 1, 0, 0);
        }
    }
}
