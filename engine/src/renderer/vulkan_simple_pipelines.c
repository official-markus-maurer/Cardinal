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

#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include "cardinal/core/log.h"
#include "vulkan_buffer_manager.h"
#include "vulkan_state.h"
#include <cardinal/renderer/util/vulkan_descriptor_utils.h>
#include <cardinal/renderer/util/vulkan_material_utils.h>
#include <cardinal/renderer/util/vulkan_shader_utils.h>
#include <cardinal/renderer/vulkan_pbr.h>

/**
 * @brief Simple uniform buffer object for UV and wireframe pipelines
 */
typedef struct SimpleUniformBufferObject {
    float model[16]; // mat4
    float view[16];  // mat4
    float proj[16];  // mat4
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

    if (vkCreateDescriptorSetLayout(s->context.device, &layoutInfo, NULL,
                                    &s->pipelines.simple_descriptor_layout) != VK_SUCCESS) {
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

    VulkanBuffer simpleBuffer = {0};
    VulkanBufferCreateInfo createInfo = {.size = bufferSize,
                                         .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                                         .properties = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                       VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                         .persistentlyMapped = true};

    if (!vk_buffer_create(&simpleBuffer, s->context.device, &s->allocator, &createInfo)) {
        CARDINAL_LOG_ERROR("Failed to create simple uniform buffer!");
        return false;
    }

    // Store buffer handles for compatibility with existing code
    s->pipelines.simple_uniform_buffer = simpleBuffer.handle;
    s->pipelines.simple_uniform_buffer_memory = simpleBuffer.memory;
    s->pipelines.simple_uniform_buffer_mapped = simpleBuffer.mapped;

    if (!s->pipelines.simple_uniform_buffer_mapped) {
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

    if (vkCreateDescriptorPool(s->context.device, &poolInfo, NULL,
                               &s->pipelines.simple_descriptor_pool) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create simple descriptor pool!");
        return false;
    }

    VkDescriptorSetAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool = s->pipelines.simple_descriptor_pool;
    allocInfo.descriptorSetCount = 1;
    allocInfo.pSetLayouts = &s->pipelines.simple_descriptor_layout;

    if (vkAllocateDescriptorSets(s->context.device, &allocInfo,
                                 &s->pipelines.simple_descriptor_set) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate simple descriptor set!");
        return false;
    }

    VkDescriptorBufferInfo bufferInfo = {0};
    bufferInfo.buffer = s->pipelines.simple_uniform_buffer;
    bufferInfo.offset = 0;
    bufferInfo.range = sizeof(SimpleUniformBufferObject);

    VkWriteDescriptorSet descriptorWrite = {0};
    descriptorWrite.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrite.dstSet = s->pipelines.simple_descriptor_set;
    descriptorWrite.dstBinding = 0;
    descriptorWrite.dstArrayElement = 0;
    descriptorWrite.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrite.descriptorCount = 1;
    descriptorWrite.pBufferInfo = &bufferInfo;

    vkUpdateDescriptorSets(s->context.device, 1, &descriptorWrite, 0, NULL);

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
static bool create_simple_pipeline(VulkanState* s, const char* vertShaderPath,
                                   const char* fragShaderPath, VkPipeline* pipeline,
                                   VkPipelineLayout* pipelineLayout, bool wireframe) {
    // Load shaders
    VkShaderModule vertShaderModule = VK_NULL_HANDLE;
    VkShaderModule fragShaderModule = VK_NULL_HANDLE;

    if (!vk_shader_create_module(s->context.device, vertShaderPath, &vertShaderModule) ||
        !vk_shader_create_module(s->context.device, fragShaderPath, &fragShaderModule)) {
        CARDINAL_LOG_ERROR("Failed to load simple pipeline shaders");
        if (vertShaderModule != VK_NULL_HANDLE)
            vkDestroyShaderModule(s->context.device, vertShaderModule, NULL);
        if (fragShaderModule != VK_NULL_HANDLE)
            vkDestroyShaderModule(s->context.device, fragShaderModule, NULL);
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
    colorBlendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                          VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
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
    pushConstantRange.size =
        sizeof(PBRPushConstants); // Size of full material data including texture transforms

    VkPipelineLayoutCreateInfo pipelineLayoutInfo = {0};
    pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    pipelineLayoutInfo.pSetLayouts = &s->pipelines.simple_descriptor_layout;
    pipelineLayoutInfo.pushConstantRangeCount = 1;
    pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;

    if (vkCreatePipelineLayout(s->context.device, &pipelineLayoutInfo, NULL, pipelineLayout) !=
        VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create simple pipeline layout!");
        vkDestroyShaderModule(s->context.device, vertShaderModule, NULL);
        vkDestroyShaderModule(s->context.device, fragShaderModule, NULL);
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
    VkFormat colorFormat = s->swapchain.format;
    pipelineRenderingInfo.pColorAttachmentFormats = &colorFormat;
    pipelineRenderingInfo.depthAttachmentFormat = s->swapchain.depth_format;
    pipelineRenderingInfo.stencilAttachmentFormat = VK_FORMAT_UNDEFINED;
    pipelineInfo.pNext = &pipelineRenderingInfo;
    pipelineInfo.renderPass = VK_NULL_HANDLE;
    pipelineInfo.subpass = 0;

    if (vkCreateGraphicsPipelines(s->context.device, VK_NULL_HANDLE, 1, &pipelineInfo, NULL,
                                  pipeline) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create simple graphics pipeline!");
        vkDestroyPipelineLayout(s->context.device, *pipelineLayout, NULL);
        vkDestroyShaderModule(s->context.device, vertShaderModule, NULL);
        vkDestroyShaderModule(s->context.device, fragShaderModule, NULL);
        return false;
    }

    vkDestroyShaderModule(s->context.device, vertShaderModule, NULL);
    vkDestroyShaderModule(s->context.device, fragShaderModule, NULL);

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
    // Build UV shader paths from env or project-relative directory
    char uv_vert_path[512], uv_frag_path[512];
    const char* shaders_dir = getenv("CARDINAL_SHADERS_DIR");
    if (!shaders_dir || !shaders_dir[0])
        shaders_dir = "assets/shaders";
    snprintf(uv_vert_path, sizeof(uv_vert_path), "%s/uv.vert.spv", shaders_dir);
    snprintf(uv_frag_path, sizeof(uv_frag_path), "%s/uv.frag.spv", shaders_dir);

    if (!create_simple_pipeline(s, uv_vert_path, uv_frag_path, &s->pipelines.uv_pipeline,
                                &s->pipelines.uv_pipeline_layout, false)) {
        CARDINAL_LOG_ERROR("Failed to create UV pipeline");
        return false;
    }

    // Create wireframe pipeline
    // Build wireframe shader paths from env or project-relative directory
    char wireframe_vert_path[512], wireframe_frag_path[512];
    snprintf(wireframe_vert_path, sizeof(wireframe_vert_path), "%s/wireframe.vert.spv",
             shaders_dir);
    snprintf(wireframe_frag_path, sizeof(wireframe_frag_path), "%s/wireframe.frag.spv",
             shaders_dir);

    if (!create_simple_pipeline(s, wireframe_vert_path, wireframe_frag_path,
                                &s->pipelines.wireframe_pipeline,
                                &s->pipelines.wireframe_pipeline_layout, true)) {
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
    if (s->pipelines.simple_uniform_buffer_mapped) {
        vkUnmapMemory(s->context.device, s->pipelines.simple_uniform_buffer_memory);
        s->pipelines.simple_uniform_buffer_mapped = NULL;
    }

    // Use allocator to properly free buffer and track memory
    if (s->pipelines.simple_uniform_buffer != VK_NULL_HANDLE ||
        s->pipelines.simple_uniform_buffer_memory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(&s->allocator, s->pipelines.simple_uniform_buffer,
                                 s->pipelines.simple_uniform_buffer_memory);
        s->pipelines.simple_uniform_buffer = VK_NULL_HANDLE;
        s->pipelines.simple_uniform_buffer_memory = VK_NULL_HANDLE;
    }

    if (s->pipelines.simple_descriptor_pool != VK_NULL_HANDLE) {
        // Wait for device to be idle before resetting descriptor pool to prevent validation errors
        VkResult waitResult = vkDeviceWaitIdle(s->context.device);
        if (waitResult != VK_SUCCESS) {
            CARDINAL_LOG_WARN("vkDeviceWaitIdle failed before resetting simple descriptor pool: %d",
                              waitResult);
        }

        // Reset the descriptor pool to free all allocated descriptor sets
        vkResetDescriptorPool(s->context.device, s->pipelines.simple_descriptor_pool, 0);
        vkDestroyDescriptorPool(s->context.device, s->pipelines.simple_descriptor_pool, NULL);
        s->pipelines.simple_descriptor_pool = VK_NULL_HANDLE;
    }

    if (s->pipelines.simple_descriptor_layout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(s->context.device, s->pipelines.simple_descriptor_layout,
                                     NULL);
        s->pipelines.simple_descriptor_layout = VK_NULL_HANDLE;
    }

    if (s->pipelines.uv_pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(s->context.device, s->pipelines.uv_pipeline, NULL);
        s->pipelines.uv_pipeline = VK_NULL_HANDLE;
    }

    if (s->pipelines.uv_pipeline_layout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(s->context.device, s->pipelines.uv_pipeline_layout, NULL);
        s->pipelines.uv_pipeline_layout = VK_NULL_HANDLE;
    }

    if (s->pipelines.wireframe_pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(s->context.device, s->pipelines.wireframe_pipeline, NULL);
        s->pipelines.wireframe_pipeline = VK_NULL_HANDLE;
    }

    if (s->pipelines.wireframe_pipeline_layout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(s->context.device, s->pipelines.wireframe_pipeline_layout, NULL);
        s->pipelines.wireframe_pipeline_layout = VK_NULL_HANDLE;
    }
}

/**
 * @brief Updates the simple uniform buffer with current matrices
 * @param s Vulkan state
 * @param model Model matrix
 * @param view View matrix
 * @param proj Projection matrix
 */
void vk_update_simple_uniforms(VulkanState* s, const float* model, const float* view,
                               const float* proj) {
    if (!s->pipelines.simple_uniform_buffer_mapped)
        return;

    SimpleUniformBufferObject ubo;
    memcpy(ubo.model, model, sizeof(float) * 16);
    memcpy(ubo.view, view, sizeof(float) * 16);
    memcpy(ubo.proj, proj, sizeof(float) * 16);

    memcpy(s->pipelines.simple_uniform_buffer_mapped, &ubo, sizeof(ubo));
}

/**
 * @brief Renders scene using a simple pipeline (UV or wireframe)
 * @param s Vulkan state
 * @param commandBuffer Command buffer to record into
 * @param pipeline Pipeline to use
 * @param pipelineLayout Pipeline layout to use
 */
void vk_render_simple(VulkanState* s, VkCommandBuffer commandBuffer, VkPipeline pipeline,
                      VkPipelineLayout pipelineLayout) {
    if (!s->current_scene || !s->scene_meshes)
        return;

    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1,
                            &s->pipelines.simple_descriptor_set, 0, NULL);

    // Render each mesh
    for (uint32_t i = 0; i < s->scene_mesh_count; i++) {
        const GpuMesh* mesh = &s->scene_meshes[i];
        if (mesh->vbuf == VK_NULL_HANDLE)
            continue;

        // Prepare push constants with model matrix and material properties (same as PBR pipeline)
        if (i < s->current_scene->mesh_count) {
            const CardinalMesh* sceneMesh = &s->current_scene->meshes[i];

            // Skip invisible meshes
            if (!sceneMesh->visible)
                continue;
            PBRPushConstants pushConstants = {0};
            vk_material_setup_push_constants(&pushConstants, sceneMesh, s->current_scene,
                                             s->pipelines.pbr_pipeline.textureManager);

            // Push constants to GPU
            vkCmdPushConstants(commandBuffer, pipelineLayout,
                               VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0,
                               sizeof(PBRPushConstants), &pushConstants);
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
