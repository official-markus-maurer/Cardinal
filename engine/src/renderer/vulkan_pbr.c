/**
 * @file vulkan_pbr.c
 * @brief Physically Based Rendering (PBR) pipeline implementation for Cardinal Engine
 *
 * This file implements a complete PBR rendering pipeline using the metallic-roughness
 * workflow. It handles shader loading, descriptor set management, uniform buffer
 * updates, texture binding, and the main rendering loop for PBR materials.
 *
 * Key features:
 * - Metallic-roughness PBR workflow implementation
 * - Dynamic descriptor indexing for texture arrays
 * - Efficient uniform buffer management with per-frame updates
 * - Support for multiple material properties (albedo, metallic, roughness, normal, emissive)
 * - Texture coordinate transformation support
 * - Optimized vertex and index buffer management
 * - Multi-frame synchronization and resource management
 *
 * PBR implementation details:
 * - Cook-Torrance BRDF for specular reflections
 * - Lambert diffuse model
 * - Image-based lighting support preparation
 * - Gamma correction and tone mapping
 * - Normal mapping for surface detail
 *
 * Performance optimizations:
 * - Descriptor indexing to reduce draw calls
 * - Push constants for per-object data
 * - Efficient buffer updates with staging
 * - Vulkan 1.3 synchronization primitives
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include "vulkan_state.h"
#include <cardinal/core/log.h>
#include <cardinal/renderer/util/vulkan_buffer_utils.h>
#include <cardinal/renderer/util/vulkan_descriptor_utils.h>
#include <cardinal/renderer/util/vulkan_shader_utils.h>
#include <cardinal/renderer/util/vulkan_texture_utils.h>
#include <cardinal/renderer/vulkan_pbr.h>
#include <stdlib.h>
#include <string.h>

/**
 * @brief Copies data from one buffer to another.
 * @param device Logical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param srcBuffer Source buffer.
 * @param dstBuffer Destination buffer.
 * @param size Size to copy.
 *
 * @todo Use DMA queues for better performance if available.
 */
static void
copyBuffer(VkDevice device, VkCommandPool commandPool, VkQueue graphicsQueue, VkBuffer srcBuffer,
           VkBuffer dstBuffer, VkDeviceSize size) {
    VkCommandBufferAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandPool = commandPool;
    allocInfo.commandBufferCount = 1;

    VkCommandBuffer commandBuffer;
    vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);

    VkCommandBufferBeginInfo beginInfo = {0};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    vkBeginCommandBuffer(commandBuffer, &beginInfo);

    VkBufferCopy copyRegion = {0};
    copyRegion.size = size;
    vkCmdCopyBuffer(commandBuffer, srcBuffer, dstBuffer, 1, &copyRegion);

    vkEndCommandBuffer(commandBuffer);

    // Vulkan 1.3 requirement: submit using vkQueueSubmit2
    VkCommandBufferSubmitInfo cmdSubmitInfo = {0};
    cmdSubmitInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    cmdSubmitInfo.commandBuffer = commandBuffer;
    cmdSubmitInfo.deviceMask = 0;

    VkSubmitInfo2 submitInfo2 = {0};
    submitInfo2.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    submitInfo2.commandBufferInfoCount = 1;
    submitInfo2.pCommandBufferInfos = &cmdSubmitInfo;

    vkQueueSubmit2(graphicsQueue, 1, &submitInfo2, VK_NULL_HANDLE);
    vkQueueWaitIdle(graphicsQueue);

    vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
}

/**
 * @brief Initializes the PBR rendering pipeline using dynamic rendering.
 * @param pipeline PBR pipeline structure.
 * @param device Logical device.
 * @param physicalDevice Physical device.
 * @param swapchainFormat Color attachment format.
 * @param depthFormat Depth attachment format.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @return true on success, false on failure.
 *
 * @todo Support dynamic state for viewport/scissor.
 * @todo Add push constants for material properties.
 */
bool vk_pbr_pipeline_create(VulkanPBRPipeline* pipeline, VkDevice device,
                            VkPhysicalDevice physicalDevice, VkFormat swapchainFormat,
                            VkFormat depthFormat, VkCommandPool commandPool, VkQueue graphicsQueue,
                            VulkanAllocator* allocator) {
    (void)physicalDevice; // Suppress unused parameter warning
    // Suppress unused parameter warnings
    (void)commandPool;
    (void)graphicsQueue;

    CARDINAL_LOG_DEBUG("Starting PBR pipeline creation");

    memset(pipeline, 0, sizeof(VulkanPBRPipeline));

    // Descriptor indexing is guaranteed in Vulkan 1.3 - no need to query
    pipeline->supportsDescriptorIndexing = true;

    CARDINAL_LOG_DEBUG("Descriptor indexing enabled (Vulkan 1.3 core)");

    CARDINAL_LOG_INFO("[PBR] Descriptor indexing support: enabled");
    CARDINAL_LOG_DEBUG("Creating descriptor set layout with 9 bindings");

    // Create descriptor set layout
    VkDescriptorSetLayoutBinding bindings[10] = {0};

    // UBO binding (vertex shader)
    bindings[0].binding = 0;
    bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[0].descriptorCount = 1;
    bindings[0].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;

    // albedoMap - matches shader binding 1
    bindings[1].binding = 1;
    bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[1].descriptorCount = 1;
    bindings[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    // normalMap - matches shader binding 2
    bindings[2].binding = 2;
    bindings[2].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[2].descriptorCount = 1;
    bindings[2].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    // metallicRoughnessMap - matches shader binding 3
    bindings[3].binding = 3;
    bindings[3].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[3].descriptorCount = 1;
    bindings[3].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    // aoMap - matches shader binding 4
    bindings[4].binding = 4;
    bindings[4].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[4].descriptorCount = 1;
    bindings[4].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    // emissiveMap - matches shader binding 5
    bindings[5].binding = 5;
    bindings[5].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[5].descriptorCount = 1;
    bindings[5].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    // Bone matrices binding (vertex shader) - moved to binding 6
    bindings[6].binding = 6;
    bindings[6].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[6].descriptorCount = 1;
    bindings[6].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;

    // Material properties binding
    bindings[7].binding = 7;
    bindings[7].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[7].descriptorCount = 1;
    bindings[7].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    // Lighting data binding - moved to binding 8
    bindings[8].binding = 8;
    bindings[8].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[8].descriptorCount = 1;
    bindings[8].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    // Texture array binding - matches shader binding 9
    bindings[9].binding = 9;
    bindings[9].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[9].descriptorCount = 1024; // Large array for descriptor indexing
    bindings[9].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    // Setup descriptor set layout create info with descriptor indexing (Vulkan 1.3 core)
    VkDescriptorSetLayoutCreateInfo layoutInfo = {0};
    layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = 10; // Always use 10 bindings with descriptor indexing
    layoutInfo.pBindings = bindings;

    // Enable descriptor indexing flags
    VkDescriptorSetLayoutBindingFlagsCreateInfo bindingFlags = {0};
    VkDescriptorBindingFlags flags[10] = {0};

    // Set flags for binding 9 (texture array) where variable descriptor count is used
    flags[9] = VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT |
               VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT |
               VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT;

    bindingFlags.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
    bindingFlags.bindingCount = 10;
    bindingFlags.pBindingFlags = flags;

    layoutInfo.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT;
    layoutInfo.pNext = &bindingFlags;

    if (vkCreateDescriptorSetLayout(device, &layoutInfo, NULL, &pipeline->descriptorSetLayout) !=
        VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor set layout!");
        return false;
    }
    CARDINAL_LOG_DEBUG("Descriptor set layout created: handle=%p",
                       (void*)(uintptr_t)pipeline->descriptorSetLayout);

    // Create push constant range for model matrix and material properties
    VkPushConstantRange pushConstantRange = {0};
    pushConstantRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
    pushConstantRange.offset = 0;
    pushConstantRange.size = sizeof(PBRPushConstants);

    // Create pipeline layout
    VkPipelineLayoutCreateInfo pipelineLayoutInfo = (VkPipelineLayoutCreateInfo){0};
    pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    pipelineLayoutInfo.pSetLayouts = &pipeline->descriptorSetLayout;
    pipelineLayoutInfo.pushConstantRangeCount = 1;
    pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;

    if (vkCreatePipelineLayout(device, &pipelineLayoutInfo, NULL, &pipeline->pipelineLayout) !=
        VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create pipeline layout!");
        return false;
    }
    CARDINAL_LOG_DEBUG("Pipeline layout created: handle=%p",
                       (void*)(uintptr_t)pipeline->pipelineLayout);

    // Load shaders
    VkShaderModule vertShaderModule = VK_NULL_HANDLE;
    VkShaderModule fragShaderModule = VK_NULL_HANDLE;

    if (!vk_shader_create_module(device, "assets/shaders/pbr.vert.spv", &vertShaderModule) ||
        !vk_shader_create_module(device, "assets/shaders/pbr.frag.spv", &fragShaderModule)) {
        CARDINAL_LOG_ERROR("Failed to load PBR shaders!");
        return false;
    }
    CARDINAL_LOG_DEBUG("Shader modules loaded: vert=%p, frag=%p",
                       (void*)(uintptr_t)vertShaderModule, (void*)(uintptr_t)fragShaderModule);

    VkPipelineShaderStageCreateInfo shaderStages[2] = {0};
    shaderStages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    shaderStages[0].module = vertShaderModule;
    shaderStages[0].pName = "main";

    shaderStages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    shaderStages[1].module = fragShaderModule;
    shaderStages[1].pName = "main";

    // Vertex input
    VkVertexInputBindingDescription bindingDescription = {0};
    bindingDescription.binding = 0;
    bindingDescription.stride = sizeof(CardinalVertex);
    bindingDescription.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

    VkVertexInputAttributeDescription attributeDescriptions[5] = {0};
    // Position
    attributeDescriptions[0].binding = 0;
    attributeDescriptions[0].location = 0;
    attributeDescriptions[0].format = VK_FORMAT_R32G32B32_SFLOAT;
    attributeDescriptions[0].offset = 0;

    // Normal
    attributeDescriptions[1].binding = 0;
    attributeDescriptions[1].location = 1;
    attributeDescriptions[1].format = VK_FORMAT_R32G32B32_SFLOAT;
    attributeDescriptions[1].offset = sizeof(float) * 3;

    // Texture coordinates
    attributeDescriptions[2].binding = 0;
    attributeDescriptions[2].location = 2;
    attributeDescriptions[2].format = VK_FORMAT_R32G32_SFLOAT;
    attributeDescriptions[2].offset = sizeof(float) * 6;

    // Bone weights
    attributeDescriptions[3].binding = 0;
    attributeDescriptions[3].location = 3;
    attributeDescriptions[3].format = VK_FORMAT_R32G32B32A32_SFLOAT;
    attributeDescriptions[3].offset = sizeof(float) * 8;

    // Bone indices
    attributeDescriptions[4].binding = 0;
    attributeDescriptions[4].location = 4;
    attributeDescriptions[4].format = VK_FORMAT_R32G32B32A32_UINT;
    attributeDescriptions[4].offset = sizeof(float) * 12;

    VkPipelineVertexInputStateCreateInfo vertexInputInfo = {0};
    vertexInputInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertexInputInfo.vertexBindingDescriptionCount = 1;
    vertexInputInfo.pVertexBindingDescriptions = &bindingDescription;
    vertexInputInfo.vertexAttributeDescriptionCount = 5;
    vertexInputInfo.pVertexAttributeDescriptions = attributeDescriptions;

    // Input assembly
    VkPipelineInputAssemblyStateCreateInfo inputAssembly = {0};
    inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    inputAssembly.primitiveRestartEnable = VK_FALSE;

    // Viewport and scissor (dynamic)
    VkPipelineViewportStateCreateInfo viewportState = {0};
    viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewportState.viewportCount = 1;
    viewportState.scissorCount = 1;

    // Rasterizer
    VkPipelineRasterizationStateCreateInfo rasterizer = {0};
    rasterizer.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.depthClampEnable = VK_FALSE;
    rasterizer.rasterizerDiscardEnable = VK_FALSE;
    rasterizer.polygonMode = VK_POLYGON_MODE_FILL;
    rasterizer.lineWidth = 1.0f;
    rasterizer.cullMode = VK_CULL_MODE_BACK_BIT;
    rasterizer.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE; // Standard counter-clockwise winding
    rasterizer.depthBiasEnable = VK_FALSE;

    // Multisampling
    VkPipelineMultisampleStateCreateInfo multisampling = {0};
    multisampling.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.sampleShadingEnable = VK_FALSE;
    multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    // Depth and stencil testing - ENABLED now that render pass has a depth attachment
    VkPipelineDepthStencilStateCreateInfo depthStencil = {0};
    depthStencil.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depthStencil.depthTestEnable = VK_TRUE;
    depthStencil.depthWriteEnable = VK_TRUE;
    depthStencil.depthCompareOp = VK_COMPARE_OP_LESS;
    depthStencil.depthBoundsTestEnable = VK_FALSE;
    depthStencil.stencilTestEnable = VK_FALSE;

    // Color blending
    VkPipelineColorBlendAttachmentState colorBlendAttachment = {0};
    colorBlendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                          VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    colorBlendAttachment.blendEnable = VK_FALSE;

    VkPipelineColorBlendStateCreateInfo colorBlending = {0};
    colorBlending.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    colorBlending.logicOpEnable = VK_FALSE;
    colorBlending.attachmentCount = 1;
    colorBlending.pAttachments = &colorBlendAttachment;

    // Dynamic state
    VkDynamicState dynamicStates[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamicState = {0};
    dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicState.dynamicStateCount = 2;
    dynamicState.pDynamicStates = dynamicStates;

    // Create graphics pipeline
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
    pipelineInfo.layout = pipeline->pipelineLayout;

    // Always use dynamic rendering pipeline info
    VkPipelineRenderingCreateInfo pipelineRenderingInfo = {0};
    pipelineRenderingInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    pipelineRenderingInfo.colorAttachmentCount = 1;
    VkFormat colorFormat = swapchainFormat;
    pipelineRenderingInfo.pColorAttachmentFormats = &colorFormat;
    pipelineRenderingInfo.depthAttachmentFormat = depthFormat;
    pipelineRenderingInfo.stencilAttachmentFormat = VK_FORMAT_UNDEFINED;
    pipelineInfo.pNext = &pipelineRenderingInfo;
    pipelineInfo.renderPass = VK_NULL_HANDLE;
    pipelineInfo.subpass = 0;

    if (vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, NULL,
                                  &pipeline->pipeline) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create graphics pipeline!");
        vkDestroyShaderModule(device, vertShaderModule, NULL);
        vkDestroyShaderModule(device, fragShaderModule, NULL);
        return false;
    }
    CARDINAL_LOG_DEBUG("Graphics pipeline created: handle=%p",
                       (void*)(uintptr_t)pipeline->pipeline);

    vkDestroyShaderModule(device, vertShaderModule, NULL);
    vkDestroyShaderModule(device, fragShaderModule, NULL);

    // Create uniform buffers
    VkDeviceSize uboSize = sizeof(PBRUniformBufferObject);
    if (!vk_buffer_create(allocator, uboSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                              VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &pipeline->uniformBuffer, &pipeline->uniformBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create PBR UBO buffer (size=%llu)",
                           (unsigned long long)uboSize);
        return false;
    }
    CARDINAL_LOG_DEBUG("UBO buffer created: buffer=%p, memory=%p",
                       (void*)(uintptr_t)pipeline->uniformBuffer,
                       (void*)(uintptr_t)pipeline->uniformBufferMemory);

    VkResult result = vkMapMemory(device, pipeline->uniformBufferMemory, 0, uboSize, 0,
                                  &pipeline->uniformBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map uniform buffer memory: %d", result);
        return false;
    }
    CARDINAL_LOG_DEBUG("UBO memory mapped at %p", pipeline->uniformBufferMapped);

    VkDeviceSize materialSize = sizeof(PBRMaterialProperties);
    if (!vk_buffer_create(allocator, materialSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                              VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &pipeline->materialBuffer, &pipeline->materialBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create PBR material buffer (size=%llu)",
                           (unsigned long long)materialSize);
        return false;
    }
    CARDINAL_LOG_DEBUG("Material buffer created: buffer=%p, memory=%p",
                       (void*)(uintptr_t)pipeline->materialBuffer,
                       (void*)(uintptr_t)pipeline->materialBufferMemory);

    result = vkMapMemory(device, pipeline->materialBufferMemory, 0, materialSize, 0,
                         &pipeline->materialBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map material buffer memory: %d", result);
        return false;
    }
    CARDINAL_LOG_DEBUG("Material memory mapped at %p", pipeline->materialBufferMapped);

    VkDeviceSize lightingSize = sizeof(PBRLightingData);
    if (!vk_buffer_create(allocator, lightingSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                              VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &pipeline->lightingBuffer, &pipeline->lightingBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create PBR lighting buffer (size=%llu)",
                           (unsigned long long)lightingSize);
        return false;
    }
    CARDINAL_LOG_DEBUG("Lighting buffer created: buffer=%p, memory=%p",
                       (void*)(uintptr_t)pipeline->lightingBuffer,
                       (void*)(uintptr_t)pipeline->lightingBufferMemory);

    result = vkMapMemory(device, pipeline->lightingBufferMemory, 0, lightingSize, 0,
                         &pipeline->lightingBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map lighting buffer memory: %d", result);
        return false;
    }
    CARDINAL_LOG_DEBUG("Lighting memory mapped at %p", pipeline->lightingBufferMapped);

    // Create bone matrices uniform buffer for skeletal animation
    pipeline->maxBones = 256; // Support up to 256 bones
    VkDeviceSize boneMatricesSize = pipeline->maxBones * 16 * sizeof(float); // 256 * mat4
    if (!vk_buffer_create(allocator, boneMatricesSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                              VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &pipeline->boneMatricesBuffer, &pipeline->boneMatricesBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create bone matrices buffer (size=%llu)",
                           (unsigned long long)boneMatricesSize);
        return false;
    }
    CARDINAL_LOG_DEBUG("Bone matrices buffer created: buffer=%p, memory=%p",
                       (void*)(uintptr_t)pipeline->boneMatricesBuffer,
                       (void*)(uintptr_t)pipeline->boneMatricesBufferMemory);

    result = vkMapMemory(device, pipeline->boneMatricesBufferMemory, 0, boneMatricesSize, 0,
                         &pipeline->boneMatricesBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map bone matrices buffer memory: %d", result);
        return false;
    }
    CARDINAL_LOG_DEBUG("Bone matrices memory mapped at %p", pipeline->boneMatricesBufferMapped);

    // Initialize bone matrices to identity
    float* boneMatrices = (float*)pipeline->boneMatricesBufferMapped;
    for (uint32_t i = 0; i < pipeline->maxBones; ++i) {
        // Set identity matrix for each bone
        memset(&boneMatrices[i * 16], 0, 16 * sizeof(float));
        boneMatrices[i * 16 + 0] = 1.0f;  // [0][0]
        boneMatrices[i * 16 + 5] = 1.0f;  // [1][1]
        boneMatrices[i * 16 + 10] = 1.0f; // [2][2]
        boneMatrices[i * 16 + 15] = 1.0f; // [3][3]
    }

    // Initialize default material properties
    PBRMaterialProperties defaultMaterial = {0};
    defaultMaterial.albedoFactor[0] = 0.8f; // Light gray
    defaultMaterial.albedoFactor[1] = 0.8f;
    defaultMaterial.albedoFactor[2] = 0.8f;
    defaultMaterial.metallicFactor = 0.0f;
    defaultMaterial.roughnessFactor = 0.5f;
    defaultMaterial.emissiveFactor[0] = 0.0f;
    defaultMaterial.emissiveFactor[1] = 0.0f;
    defaultMaterial.emissiveFactor[2] = 0.0f;
    defaultMaterial.normalScale = 1.0f;
    defaultMaterial.aoStrength = 1.0f;

    // Initialize texture indices to 0 (placeholder texture)
    defaultMaterial.albedoTextureIndex = 0;
    defaultMaterial.normalTextureIndex = 0;
    defaultMaterial.metallicRoughnessTextureIndex = 0;
    defaultMaterial.aoTextureIndex = 0;
    defaultMaterial.emissiveTextureIndex = 0;
    // Propagate descriptor indexing support to shader side (always enabled in Vulkan 1.3)
    defaultMaterial.supportsDescriptorIndexing = 1u;

    memcpy(pipeline->materialBufferMapped, &defaultMaterial, sizeof(PBRMaterialProperties));

    // Initialize default lighting (TODO: Hook up to ImGui)
    PBRLightingData defaultLighting = {0};
    defaultLighting.lightDirection[0] = -0.5f;
    defaultLighting.lightDirection[1] = -1.0f;
    defaultLighting.lightDirection[2] = -0.3f;
    defaultLighting.lightColor[0] = 1.0f;
    defaultLighting.lightColor[1] = 1.0f;
    defaultLighting.lightColor[2] = 1.0f;
    defaultLighting.lightIntensity = 1.0f;  // Reduced from 3.0f
    defaultLighting.ambientColor[0] = 0.1f; // Increased for better visibility
    defaultLighting.ambientColor[1] = 0.1f;
    defaultLighting.ambientColor[2] = 0.1f;
    memcpy(pipeline->lightingBufferMapped, &defaultLighting, sizeof(PBRLightingData));

    pipeline->initialized = true;
    CARDINAL_LOG_INFO("PBR pipeline created successfully");
    return true;
}

/**
 * @brief Destroys the PBR pipeline and frees all associated resources.
 *
 * @param pipeline Pointer to the VulkanPBRPipeline structure to destroy.
 * @param device The Vulkan logical device.
 *
 * @todo Optimize resource cleanup to handle partial destructions.
 * @todo Add support for Vulkan memory allocator extensions.
 */
void vk_pbr_pipeline_destroy(VulkanPBRPipeline* pipeline, VkDevice device,
                             VulkanAllocator* allocator) {
    if (!pipeline->initialized)
        return;

    // Destroy textures
    if (pipeline->textureImages) {
        for (uint32_t i = 0; i < pipeline->textureCount; i++) {
            if (pipeline->textureImageViews && pipeline->textureImageViews[i] != VK_NULL_HANDLE) {
                vkDestroyImageView(device, pipeline->textureImageViews[i], NULL);
            }
            vk_allocator_free_image(allocator, pipeline->textureImages[i],
                                    pipeline->textureImageMemories
                                        ? pipeline->textureImageMemories[i]
                                        : VK_NULL_HANDLE);
        }
        free(pipeline->textureImages);
        pipeline->textureImages = NULL;

        if (pipeline->textureImageMemories) {
            free(pipeline->textureImageMemories);
            pipeline->textureImageMemories = NULL;
        }

        if (pipeline->textureImageViews) {
            free(pipeline->textureImageViews);
            pipeline->textureImageViews = NULL;
        }
    }

    if (pipeline->textureSampler != VK_NULL_HANDLE) {
        vkDestroySampler(device, pipeline->textureSampler, NULL);
    }

    // Destroy vertex and index buffers
    if (pipeline->vertexBuffer != VK_NULL_HANDLE ||
        pipeline->vertexBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->vertexBuffer, pipeline->vertexBufferMemory);
    }

    if (pipeline->indexBuffer != VK_NULL_HANDLE || pipeline->indexBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->indexBuffer, pipeline->indexBufferMemory);
    }

    // Destroy uniform buffers
    if (pipeline->uniformBuffer != VK_NULL_HANDLE ||
        pipeline->uniformBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->uniformBuffer, pipeline->uniformBufferMemory);
    }

    if (pipeline->materialBuffer != VK_NULL_HANDLE ||
        pipeline->materialBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->materialBuffer,
                                 pipeline->materialBufferMemory);
    }

    if (pipeline->lightingBuffer != VK_NULL_HANDLE ||
        pipeline->lightingBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->lightingBuffer,
                                 pipeline->lightingBufferMemory);
    }

    // Free descriptor sets explicitly before destroying pool
    if (pipeline->descriptorSets && pipeline->descriptorPool != VK_NULL_HANDLE) {
        vkFreeDescriptorSets(device, pipeline->descriptorPool, pipeline->descriptorSetCount,
                             pipeline->descriptorSets);
        free(pipeline->descriptorSets);
        pipeline->descriptorSets = NULL;
    }

    // Destroy descriptor pool
    if (pipeline->descriptorPool != VK_NULL_HANDLE) {
        vkDestroyDescriptorPool(device, pipeline->descriptorPool, NULL);
        pipeline->descriptorPool = VK_NULL_HANDLE;
    }

    // Destroy pipeline and layout
    if (pipeline->pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(device, pipeline->pipeline, NULL);
    }

    if (pipeline->pipelineLayout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(device, pipeline->pipelineLayout, NULL);
    }

    if (pipeline->descriptorSetLayout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(device, pipeline->descriptorSetLayout, NULL);
    }

    // Destroy bone matrices buffer
    if (pipeline->boneMatricesBuffer != VK_NULL_HANDLE ||
        pipeline->boneMatricesBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->boneMatricesBuffer,
                                 pipeline->boneMatricesBufferMemory);
    }

    memset(pipeline, 0, sizeof(VulkanPBRPipeline));
    CARDINAL_LOG_INFO("PBR pipeline destroyed");
}

/**
 * @brief Updates the uniform buffers for the PBR pipeline.
 *
 * @param pipeline Pointer to the VulkanPBRPipeline structure.
 * @param ubo Pointer to the uniform buffer object data.
 * @param lighting Pointer to the lighting data.
 *
 * @todo Implement dynamic uniform buffer updates for real-time changes.
 * @todo Add support for multiple light sources in lighting data.
 */
void vk_pbr_update_uniforms(VulkanPBRPipeline* pipeline, const PBRUniformBufferObject* ubo,
                            const PBRLightingData* lighting) {
    if (!pipeline->initialized)
        return;

    // Update UBO
    memcpy(pipeline->uniformBufferMapped, ubo, sizeof(PBRUniformBufferObject));

    // Update lighting data
    memcpy(pipeline->lightingBufferMapped, lighting, sizeof(PBRLightingData));
}

/**
 * @brief Renders the PBR scene using the pipeline.
 *
 * @param pipeline Pointer to the VulkanPBRPipeline structure.
 * @param commandBuffer The command buffer to record rendering commands into.
 * @param scene Pointer to the scene data to render.
 *
 * @todo Implement multi-pass rendering for advanced effects like shadows.
 * @todo Add support for instanced rendering.
 */
void vk_pbr_render(VulkanPBRPipeline* pipeline, VkCommandBuffer commandBuffer,
                   const CardinalScene* scene) {
    if (!pipeline->initialized || !scene)
        return;

    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline->pipeline);

    VkBuffer vertexBuffers[] = {pipeline->vertexBuffer};
    VkDeviceSize offsets[] = {0};
    vkCmdBindVertexBuffers(commandBuffer, 0, 1, vertexBuffers, offsets);
    vkCmdBindIndexBuffer(commandBuffer, pipeline->indexBuffer, 0, VK_INDEX_TYPE_UINT32);

    // Bind descriptor set once (no longer per-mesh since we use push constants for material data)
    if (pipeline->descriptorSetCount > 0) {
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                pipeline->pipelineLayout, 0, 1, &pipeline->descriptorSets[0], 0,
                                NULL);
    }

    // Render each mesh
    uint32_t indexOffset = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* mesh = &scene->meshes[i];

        // Skip invisible meshes
        if (!mesh->visible) {
            indexOffset += mesh->index_count;
            continue;
        }

        // Prepare push constants with model matrix and material properties
        PBRPushConstants pushConstants = {0};

        // Copy model matrix
        memcpy(pushConstants.modelMatrix, mesh->transform, 16 * sizeof(float));

        // Set material properties for this mesh
        if (mesh->material_index < scene->material_count) {
            const CardinalMaterial* material = &scene->materials[mesh->material_index];

            memcpy(pushConstants.albedoFactor, material->albedo_factor, sizeof(float) * 3);
            pushConstants.metallicFactor = material->metallic_factor;
            memcpy(pushConstants.emissiveFactor, material->emissive_factor, sizeof(float) * 3);
            pushConstants.roughnessFactor = material->roughness_factor;
            pushConstants.normalScale = material->normal_scale;
            pushConstants.aoStrength = material->ao_strength;

            // Set texture indices - preserve UINT32_MAX for missing textures, fallback to 0 only
            // for invalid indices
            pushConstants.albedoTextureIndex = (material->albedo_texture == UINT32_MAX) ? UINT32_MAX
                                               : (material->albedo_texture < pipeline->textureCount)
                                                   ? material->albedo_texture
                                                   : 0;
            pushConstants.normalTextureIndex = (material->normal_texture == UINT32_MAX) ? UINT32_MAX
                                               : (material->normal_texture < pipeline->textureCount)
                                                   ? material->normal_texture
                                                   : 0;
            pushConstants.metallicRoughnessTextureIndex =
                (material->metallic_roughness_texture == UINT32_MAX) ? UINT32_MAX
                : (material->metallic_roughness_texture < pipeline->textureCount)
                    ? material->metallic_roughness_texture
                    : 0;
            pushConstants.aoTextureIndex = (material->ao_texture == UINT32_MAX) ? UINT32_MAX
                                           : (material->ao_texture < pipeline->textureCount)
                                               ? material->ao_texture
                                               : 0;
            pushConstants.emissiveTextureIndex =
                (material->emissive_texture == UINT32_MAX)              ? UINT32_MAX
                : (material->emissive_texture < pipeline->textureCount) ? material->emissive_texture
                                                                        : 0;

            // Set texture transforms using new structure layout
            memcpy(pushConstants.albedoTransform.offset, material->albedo_transform.offset,
                   sizeof(float) * 2);
            memcpy(pushConstants.albedoTransform.scale, material->albedo_transform.scale,
                   sizeof(float) * 2);
            pushConstants.albedoTransform.rotation = material->albedo_transform.rotation;

            memcpy(pushConstants.normalTransform.offset, material->normal_transform.offset,
                   sizeof(float) * 2);
            memcpy(pushConstants.normalTransform.scale, material->normal_transform.scale,
                   sizeof(float) * 2);
            pushConstants.normalTransform.rotation = material->normal_transform.rotation;

            memcpy(pushConstants.metallicRoughnessTransform.offset,
                   material->metallic_roughness_transform.offset, sizeof(float) * 2);
            memcpy(pushConstants.metallicRoughnessTransform.scale,
                   material->metallic_roughness_transform.scale, sizeof(float) * 2);
            pushConstants.metallicRoughnessTransform.rotation =
                material->metallic_roughness_transform.rotation;

            memcpy(pushConstants.aoTransform.offset, material->ao_transform.offset,
                   sizeof(float) * 2);
            memcpy(pushConstants.aoTransform.scale, material->ao_transform.scale,
                   sizeof(float) * 2);
            pushConstants.aoTransform.rotation = material->ao_transform.rotation;

            memcpy(pushConstants.emissiveTransform.offset, material->emissive_transform.offset,
                   sizeof(float) * 2);
            memcpy(pushConstants.emissiveTransform.scale, material->emissive_transform.scale,
                   sizeof(float) * 2);
            pushConstants.emissiveTransform.rotation = material->emissive_transform.rotation;

            // CRITICAL: Set descriptor indexing flag for shader (always enabled in Vulkan 1.3, only
        // if textures are available)
        pushConstants.supportsDescriptorIndexing = (pipeline->textureCount > 0) ? 1u : 0u;
        
        // Check if this mesh uses skeletal animation
        pushConstants.hasSkeleton = 0;
        if (scene->animation_system && scene->skin_count > 0) {
            // Check if this mesh is associated with any skin
            for (uint32_t skin_idx = 0; skin_idx < scene->skin_count; ++skin_idx) {
                const CardinalSkin* skin = &scene->skins[skin_idx];
                for (uint32_t mesh_idx = 0; mesh_idx < skin->mesh_count; ++mesh_idx) {
                    if (skin->mesh_indices[mesh_idx] == i) {
                        pushConstants.hasSkeleton = 1;
                        
                        // Update bone matrices for this skin
                        if (scene->animation_system->bone_matrices) {
                            memcpy(pipeline->boneMatricesBufferMapped, 
                                   scene->animation_system->bone_matrices,
                                   scene->animation_system->bone_matrix_count * sizeof(float));
                        }
                        break;
                    }
                }
                if (pushConstants.hasSkeleton) break;
            }
        }

            // Debug logging for material properties
            CARDINAL_LOG_DEBUG(
                "Material %d: albedo_idx=%u, normal_idx=%u, mr_idx=%u, ao_idx=%u, emissive_idx=%u",
                i, pushConstants.albedoTextureIndex, pushConstants.normalTextureIndex,
                pushConstants.metallicRoughnessTextureIndex, pushConstants.aoTextureIndex,
                pushConstants.emissiveTextureIndex);
            CARDINAL_LOG_DEBUG("Material %d factors: albedo=[%.3f,%.3f,%.3f], "
                               "emissive=[%.3f,%.3f,%.3f], metallic=%.3f, roughness=%.3f",
                               i, pushConstants.albedoFactor[0], pushConstants.albedoFactor[1],
                               pushConstants.albedoFactor[2], pushConstants.emissiveFactor[0],
                               pushConstants.emissiveFactor[1], pushConstants.emissiveFactor[2],
                               pushConstants.metallicFactor, pushConstants.roughnessFactor);
        } else {
            // Use default material properties if no material is assigned
            pushConstants.albedoFactor[0] = pushConstants.albedoFactor[1] =
                pushConstants.albedoFactor[2] = 1.0f;
            pushConstants.metallicFactor = 0.0f;
            pushConstants.emissiveFactor[0] = pushConstants.emissiveFactor[1] =
                pushConstants.emissiveFactor[2] = 0.0f;
            pushConstants.roughnessFactor = 0.5f;
            pushConstants.normalScale = 1.0f;
            pushConstants.aoStrength = 1.0f;
            pushConstants.albedoTextureIndex = UINT32_MAX;
            pushConstants.normalTextureIndex = UINT32_MAX;
            pushConstants.metallicRoughnessTextureIndex = UINT32_MAX;
            pushConstants.aoTextureIndex = UINT32_MAX;
            pushConstants.emissiveTextureIndex = UINT32_MAX;
            pushConstants.supportsDescriptorIndexing = (pipeline->textureCount > 0) ? 1u : 0u;
            
            // Check if this mesh uses skeletal animation
            pushConstants.hasSkeleton = 0;
            if (scene->animation_system && scene->skin_count > 0) {
                // Check if this mesh is associated with any skin
                for (uint32_t skin_idx = 0; skin_idx < scene->skin_count; ++skin_idx) {
                    const CardinalSkin* skin = &scene->skins[skin_idx];
                    for (uint32_t mesh_idx = 0; mesh_idx < skin->mesh_count; ++mesh_idx) {
                        if (skin->mesh_indices[mesh_idx] == i) {
                            pushConstants.hasSkeleton = 1;
                            
                            // Update bone matrices for this skin
                            if (scene->animation_system->bone_matrices) {
                                memcpy(pipeline->boneMatricesBufferMapped, 
                                       scene->animation_system->bone_matrices,
                                       scene->animation_system->bone_matrix_count * sizeof(float));
                            }
                            break;
                        }
                    }
                    if (pushConstants.hasSkeleton) break;
                }
            }
        }

        // Push constants to GPU
        vkCmdPushConstants(commandBuffer, pipeline->pipelineLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0,
                           sizeof(PBRPushConstants), &pushConstants);

        // Draw the mesh
        vkCmdDrawIndexed(commandBuffer, mesh->index_count, 1, indexOffset, 0, 0);
        indexOffset += mesh->index_count;
    }
}

/**
 * @brief Loads scene data into the PBR pipeline buffers.
 *
 * @param pipeline Pointer to the VulkanPBRPipeline structure.
 * @param device The Vulkan logical device.
 * @param physicalDevice The Vulkan physical device.
 * @param commandPool The command pool for temporary commands.
 * @param graphicsQueue The graphics queue for submissions.
 * @param scene Pointer to the scene data to load.
 * @return true if loading was successful, false otherwise.
 *
 * @todo Implement scene streaming for large models.
 * @todo Add support for loading multiple texture sets per material.
 * @todo Integrate image-based lighting (IBL) textures.
 */
bool vk_pbr_load_scene(VulkanPBRPipeline* pipeline, VkDevice device,
                       VkPhysicalDevice physicalDevice, VkCommandPool commandPool,
                       VkQueue graphicsQueue, const CardinalScene* scene,
                       VulkanAllocator* allocator) {
    (void)physicalDevice; // Unused parameter

    if (!pipeline->initialized || !scene || scene->mesh_count == 0) {
        CARDINAL_LOG_WARN("PBR pipeline not initialized or no scene data");
        return true;
    }

    // Count total vertices and indices
    uint32_t totalVertices = 0;
    uint32_t totalIndices = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        totalVertices += scene->meshes[i].vertex_count;
        totalIndices += scene->meshes[i].index_count;
    }

    if (totalVertices == 0) {
        CARDINAL_LOG_WARN("Scene has no vertices");
        return true;
    }

    CARDINAL_LOG_INFO("Loading PBR scene: %u meshes, %u vertices, %u indices", scene->mesh_count,
                      totalVertices, totalIndices);

    // Clean up previous buffers if they exist
    if (pipeline->vertexBuffer != VK_NULL_HANDLE ||
        pipeline->vertexBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->vertexBuffer, pipeline->vertexBufferMemory);
        pipeline->vertexBuffer = VK_NULL_HANDLE;
        pipeline->vertexBufferMemory = VK_NULL_HANDLE;
    }

    if (pipeline->indexBuffer != VK_NULL_HANDLE || pipeline->indexBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->indexBuffer, pipeline->indexBufferMemory);
        pipeline->indexBuffer = VK_NULL_HANDLE;
        pipeline->indexBufferMemory = VK_NULL_HANDLE;
    }

    // Create vertex buffer with device address support
    VkDeviceSize vertexBufferSize = totalVertices * sizeof(CardinalVertex);
    if (!vk_buffer_create(
            allocator, vertexBufferSize,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &pipeline->vertexBuffer, &pipeline->vertexBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create PBR vertex buffer");
        return false;
    }

    // Get vertex buffer device address for potential shader usage
    VkDeviceAddress vertexBufferAddress =
        vk_allocator_get_buffer_device_address(allocator, pipeline->vertexBuffer);
    CARDINAL_LOG_DEBUG("Vertex buffer device address: 0x%llx",
                       (unsigned long long)vertexBufferAddress);
    (void)vertexBufferAddress; // Suppress unused variable warning

    // Map and upload vertex data
    void* vertexData;
    if (vkMapMemory(device, pipeline->vertexBufferMemory, 0, vertexBufferSize, 0, &vertexData) !=
        VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map vertex buffer memory");
        return false;
    }

    CardinalVertex* mappedVertices = (CardinalVertex*)vertexData;
    uint32_t vertexOffset = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* mesh = &scene->meshes[i];
        memcpy(&mappedVertices[vertexOffset], mesh->vertices,
               mesh->vertex_count * sizeof(CardinalVertex));
        vertexOffset += mesh->vertex_count;
    }
    vkUnmapMemory(device, pipeline->vertexBufferMemory);

    // Create index buffer if we have indices
    if (totalIndices > 0) {
        VkDeviceSize indexBufferSize = totalIndices * sizeof(uint32_t);
        if (!vk_buffer_create(
                allocator, indexBufferSize,
                VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                &pipeline->indexBuffer, &pipeline->indexBufferMemory)) {
            CARDINAL_LOG_ERROR("Failed to create PBR index buffer");
            return false;
        }

        // Get index buffer device address for potential shader usage
        VkDeviceAddress indexBufferAddress =
            vk_allocator_get_buffer_device_address(allocator, pipeline->indexBuffer);
        CARDINAL_LOG_DEBUG("Index buffer device address: 0x%llx",
                           (unsigned long long)indexBufferAddress);
        (void)indexBufferAddress; // Suppress unused variable warning

        void* indexData;
        if (vkMapMemory(device, pipeline->indexBufferMemory, 0, indexBufferSize, 0, &indexData) !=
            VK_SUCCESS) {
            CARDINAL_LOG_ERROR("Failed to map index buffer memory");
            return false;
        }

        uint32_t* mappedIndices = (uint32_t*)indexData;
        uint32_t indexOffset = 0;
        uint32_t vertexBaseOffset = 0;
        for (uint32_t i = 0; i < scene->mesh_count; i++) {
            const CardinalMesh* mesh = &scene->meshes[i];
            if (mesh->index_count > 0) {
                for (uint32_t j = 0; j < mesh->index_count; j++) {
                    mappedIndices[indexOffset + j] = mesh->indices[j] + vertexBaseOffset;
                }
                indexOffset += mesh->index_count;
            }
            vertexBaseOffset += mesh->vertex_count;
        }
        vkUnmapMemory(device, pipeline->indexBufferMemory);
    }

    // Clean up existing textures if any
    if (pipeline->textureImages) {
        for (uint32_t i = 0; i < pipeline->textureCount; i++) {
            if (pipeline->textureImageViews && pipeline->textureImageViews[i] != VK_NULL_HANDLE) {
                vkDestroyImageView(device, pipeline->textureImageViews[i], NULL);
            }
            if (pipeline->textureImages[i] != VK_NULL_HANDLE ||
                (pipeline->textureImageMemories &&
                 pipeline->textureImageMemories[i] != VK_NULL_HANDLE)) {
                vk_allocator_free_image(allocator, pipeline->textureImages[i],
                                        pipeline->textureImageMemories[i]);
            }
        }
        free(pipeline->textureImages);
        free(pipeline->textureImageMemories);
        free(pipeline->textureImageViews);
        pipeline->textureImages = NULL;
        pipeline->textureImageMemories = NULL;
        pipeline->textureImageViews = NULL;
    }

    if (pipeline->textureSampler != VK_NULL_HANDLE) {
        vkDestroySampler(device, pipeline->textureSampler, NULL);
        pipeline->textureSampler = VK_NULL_HANDLE;
    }

    // Determine how many textures we need to upload
    uint32_t textureCount = (scene->texture_count > 0) ? scene->texture_count : 1;
    bool hasSceneTextures = (scene->texture_count > 0 && scene->textures != NULL);

    CARDINAL_LOG_INFO("Loading %u textures (%u from scene)", textureCount, scene->texture_count);

    // Allocate texture arrays
    pipeline->textureCount = textureCount;
    pipeline->textureImages = (VkImage*)malloc(textureCount * sizeof(VkImage));
    pipeline->textureImageMemories = (VkDeviceMemory*)malloc(textureCount * sizeof(VkDeviceMemory));
    pipeline->textureImageViews = (VkImageView*)malloc(textureCount * sizeof(VkImageView));

    // Initialize arrays
    for (uint32_t i = 0; i < textureCount; i++) {
        pipeline->textureImages[i] = VK_NULL_HANDLE;
        pipeline->textureImageMemories[i] = VK_NULL_HANDLE;
        pipeline->textureImageViews[i] = VK_NULL_HANDLE;
    }

    // Create texture sampler (shared by all textures)
    VkSamplerCreateInfo samplerInfo = {0};
    samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = VK_FILTER_LINEAR;
    samplerInfo.minFilter = VK_FILTER_LINEAR;
    samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.anisotropyEnable = VK_FALSE;
    samplerInfo.maxAnisotropy = 1.0f;
    samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    samplerInfo.unnormalizedCoordinates = VK_FALSE;
    samplerInfo.compareEnable = VK_FALSE;
    samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
    samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    samplerInfo.mipLodBias = 0.0f;
    samplerInfo.minLod = 0.0f;
    samplerInfo.maxLod = 0.0f;

    if (vkCreateSampler(device, &samplerInfo, NULL, &pipeline->textureSampler) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create texture sampler");
        return false;
    }
    CARDINAL_LOG_DEBUG("Texture sampler created: handle=%p",
                       (void*)(uintptr_t)pipeline->textureSampler);

    // Upload scene textures or create placeholder
    uint32_t successfulUploads = 0;

    if (hasSceneTextures) {
        // Upload real textures from scene
        for (uint32_t i = 0; i < scene->texture_count; i++) {
            const CardinalTexture* texture = &scene->textures[i];

            // Skip invalid textures and create placeholder for them
            if (!texture->data || texture->width == 0 || texture->height == 0) {
                CARDINAL_LOG_WARN("Skipping invalid texture %u (%s) - creating placeholder", i,
                                  texture->path ? texture->path : "unknown");
                // Create fallback placeholder for invalid texture slot
                if (!vk_texture_create_placeholder(allocator, device, commandPool, graphicsQueue,
                                                   &pipeline->textureImages[i],
                                                   &pipeline->textureImageMemories[i],
                                                   &pipeline->textureImageViews[i], NULL)) {
                    CARDINAL_LOG_ERROR("Failed to create fallback texture for slot %u", i);
                    return false;
                }
                continue;
            }

            CARDINAL_LOG_INFO("Uploading texture %u: %ux%u, %d channels (%s)", i, texture->width,
                              texture->height, texture->channels,
                              texture->path ? texture->path : "unknown");

            if (vk_texture_create_from_data(allocator, device, commandPool, graphicsQueue, texture,
                                            &pipeline->textureImages[i],
                                            &pipeline->textureImageMemories[i],
                                            &pipeline->textureImageViews[i])) {
                successfulUploads++;
            } else {
                CARDINAL_LOG_ERROR("Failed to upload texture %u (%s) - creating placeholder", i,
                                   texture->path ? texture->path : "unknown");
                // Create fallback placeholder for this slot to ensure valid image view
                if (!vk_texture_create_placeholder(allocator, device, commandPool, graphicsQueue,
                                                   &pipeline->textureImages[i],
                                                   &pipeline->textureImageMemories[i],
                                                   &pipeline->textureImageViews[i], NULL)) {
                    CARDINAL_LOG_ERROR("Failed to create fallback texture for slot %u", i);
                    return false;
                }
            }
        }

#ifdef _DEBUG
        CARDINAL_LOG_INFO("Successfully uploaded %u/%u textures", successfulUploads,
                          scene->texture_count);
#else
        (void)successfulUploads; // Silence unused variable warning in release builds
#endif

        // Fill remaining slots with placeholders if scene had fewer textures than allocated
        for (uint32_t i = scene->texture_count; i < textureCount; i++) {
            CARDINAL_LOG_DEBUG("Creating placeholder texture for unused slot %u", i);
            if (!vk_texture_create_placeholder(
                    allocator, device, commandPool, graphicsQueue, &pipeline->textureImages[i],
                    &pipeline->textureImageMemories[i], &pipeline->textureImageViews[i], NULL)) {
                CARDINAL_LOG_ERROR("Failed to create placeholder texture for slot %u", i);
                return false;
            }
        }
    }

    // If no scene textures, create a single placeholder
    if (!hasSceneTextures) {
        CARDINAL_LOG_INFO("Creating placeholder texture (no scene textures available)");
        if (!vk_texture_create_placeholder(
                allocator, device, commandPool, graphicsQueue, &pipeline->textureImages[0],
                &pipeline->textureImageMemories[0], &pipeline->textureImageViews[0], NULL)) {
            CARDINAL_LOG_ERROR("Failed to create placeholder texture");
            return false;
        }
        // Ensure we only have one texture slot when using fallback
        pipeline->textureCount = 1;
    }

    // Create descriptor pool and sets
    VkDescriptorPoolSize poolSizes[3] = {0};
    poolSizes[0].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    poolSizes[0].descriptorCount = 4; // UBO + Bone Matrices + Material + Lighting
    poolSizes[1].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    // Allocate descriptors: 5 fixed + 1024 variable for descriptor indexing (Vulkan 1.3 core)
    poolSizes[1].descriptorCount = 5 + 1024; // 5 fixed + 1024 variable
    poolSizes[2].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    poolSizes[2].descriptorCount = 0; // Consolidated into poolSizes[0]

    VkDescriptorPoolCreateInfo poolInfo = {0};
    poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT |
                     VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT;
    poolInfo.poolSizeCount = 3;
    poolInfo.pPoolSizes = poolSizes;
    poolInfo.maxSets = 1; // One descriptor set for now

    if (vkCreateDescriptorPool(device, &poolInfo, NULL, &pipeline->descriptorPool) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor pool");
        return false;
    }
    CARDINAL_LOG_DEBUG(
        "Descriptor pool created: handle=%p, flags=0x%X, counts: UBO=%u, IMG=%u, LIGHT=%u",
        (void*)(uintptr_t)pipeline->descriptorPool, poolInfo.flags, poolSizes[0].descriptorCount,
        poolSizes[1].descriptorCount, poolSizes[2].descriptorCount);

    // Allocate descriptor set
    pipeline->descriptorSetCount = 1;
    pipeline->descriptorSets = (VkDescriptorSet*)malloc(sizeof(VkDescriptorSet));

    VkDescriptorSetAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool = pipeline->descriptorPool;
    allocInfo.descriptorSetCount = 1;
    allocInfo.pSetLayouts = &pipeline->descriptorSetLayout;

    // Handle variable descriptor count for descriptor indexing (binding 8) - Vulkan 1.3 core
    VkDescriptorSetVariableDescriptorCountAllocateInfo variableCountInfo = {0};
    // Use the actual number of textures we will bind for the variable descriptor array
    uint32_t variableDescriptorCount = pipeline->textureCount;

    variableCountInfo.sType =
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO;
    variableCountInfo.descriptorSetCount = 1;
    variableCountInfo.pDescriptorCounts = &variableDescriptorCount;
    allocInfo.pNext = &variableCountInfo;

    if (vkAllocateDescriptorSets(device, &allocInfo, pipeline->descriptorSets) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate descriptor sets");
        return false;
    }
    CARDINAL_LOG_DEBUG(
        "Allocated descriptor set: set=%p, variableCount=%u (descriptor indexing enabled)",
        (void*)(uintptr_t)pipeline->descriptorSets[0], variableDescriptorCount);

    // Update descriptor sets with uniform buffers and textures
    // variable descriptor indexing path can emit up to 9 writes (UBO + 5 textures + variable array
    // + 2 UBOs)
    VkWriteDescriptorSet descriptorWrites[10] = {0};
    uint32_t writeCount = 0;

    VkDescriptorBufferInfo bufferInfo = {0};
    bufferInfo.buffer = pipeline->uniformBuffer;
    bufferInfo.offset = 0;
    bufferInfo.range = sizeof(PBRUniformBufferObject);

    descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[writeCount].dstBinding = 0;
    descriptorWrites[writeCount].dstArrayElement = 0;
    descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[writeCount].descriptorCount = 1;
    descriptorWrites[writeCount].pBufferInfo = &bufferInfo;
    writeCount++;

    // Bone matrices buffer - now at binding 6
    VkDescriptorBufferInfo boneMatricesBufferInfo = {0};
    boneMatricesBufferInfo.buffer = pipeline->boneMatricesBuffer;
    boneMatricesBufferInfo.offset = 0;
    boneMatricesBufferInfo.range = sizeof(float) * 16 * pipeline->maxBones;

    descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[writeCount].dstBinding = 6;
    descriptorWrites[writeCount].dstArrayElement = 0;
    descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[writeCount].descriptorCount = 1;
    descriptorWrites[writeCount].pBufferInfo = &boneMatricesBufferInfo;
    writeCount++;

    // Prepare image infos for material texture slots (albedo, normal, metallicRoughness, ao,
    // emissive)
    VkDescriptorImageInfo imageInfos[5];
    for (uint32_t i = 0; i < 5; ++i) {
        imageInfos[i].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        // With descriptor indexing (Vulkan 1.3 core), fixed bindings 1-5 use placeholder (index 0)
        // to avoid confusion with the variable array.
        uint32_t texIndex = 0;
        imageInfos[i].imageView = pipeline->textureImageViews[texIndex];
        imageInfos[i].sampler = pipeline->textureSampler;
        CARDINAL_LOG_DEBUG("Fixed binding %u uses texture index %u (imageView=%p)", i + 1, texIndex,
                           (void*)(uintptr_t)pipeline->textureImageViews[texIndex]);
    }

    // Bind placeholders for fixed bindings 1-5 (shader will use variable array for actual textures)
    for (uint32_t b = 1; b <= 5; ++b) {
        descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
        descriptorWrites[writeCount].dstBinding = b;
        descriptorWrites[writeCount].dstArrayElement = 0;
        descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        descriptorWrites[writeCount].descriptorCount = 1;
        descriptorWrites[writeCount].pImageInfo = &imageInfos[b - 1];
        writeCount++;
    }
    // Variable descriptor array: bind all available textures (or 1 if only placeholder)
    descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[writeCount].dstBinding = 9; // variable count binding
    descriptorWrites[writeCount].dstArrayElement = 0;
    descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    descriptorWrites[writeCount].descriptorCount = pipeline->textureCount;

    // Build a temporary array of VkDescriptorImageInfo for binding 8
    VkDescriptorImageInfo* varInfos =
        (VkDescriptorImageInfo*)malloc(sizeof(VkDescriptorImageInfo) * pipeline->textureCount);
    if (!varInfos) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for descriptor image infos");
        return false;
    }
    for (uint32_t i = 0; i < pipeline->textureCount; ++i) {
        varInfos[i].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        varInfos[i].imageView = pipeline->textureImageViews[i];
        varInfos[i].sampler = pipeline->textureSampler;
        if (i < 8) {
            CARDINAL_LOG_DEBUG("Variable binding 9, array[%u] -> imageView=%p", i,
                               (void*)(uintptr_t)pipeline->textureImageViews[i]);
        }
    }
    descriptorWrites[writeCount].pImageInfo = varInfos;
    writeCount++;

    // Update descriptor sets with uniform buffers
    VkDescriptorBufferInfo materialBufferInfo = {0};
    materialBufferInfo.buffer = pipeline->materialBuffer;
    materialBufferInfo.offset = 0;
    materialBufferInfo.range = sizeof(PBRMaterialProperties);

    descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[writeCount].dstBinding = 7;
    descriptorWrites[writeCount].dstArrayElement = 0;
    descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[writeCount].descriptorCount = 1;
    descriptorWrites[writeCount].pBufferInfo = &materialBufferInfo;
    writeCount++;

    VkDescriptorBufferInfo lightingBufferInfo = {0};
    lightingBufferInfo.buffer = pipeline->lightingBuffer;
    lightingBufferInfo.offset = 0;
    lightingBufferInfo.range = sizeof(PBRLightingData);

    descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[writeCount].dstBinding = 8;
    descriptorWrites[writeCount].dstArrayElement = 0;
    descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[writeCount].descriptorCount = 1;
    descriptorWrites[writeCount].pBufferInfo = &lightingBufferInfo;
    writeCount++;

    // Apply descriptor writes
    CARDINAL_LOG_DEBUG("Updating descriptor sets (descriptor indexing): writes=%u, sampler=%p, "
                       "ubo=%p, material=%p, lighting=%p",
                       writeCount, (void*)(uintptr_t)pipeline->textureSampler,
                       (void*)(uintptr_t)pipeline->uniformBuffer,
                       (void*)(uintptr_t)pipeline->materialBuffer,
                       (void*)(uintptr_t)pipeline->lightingBuffer);
    vkUpdateDescriptorSets(device, writeCount, descriptorWrites, 0, NULL);
    CARDINAL_LOG_DEBUG("Descriptor sets updated with descriptor indexing");

    // Free temporary allocation
    free(varInfos);

    CARDINAL_LOG_INFO("PBR scene loaded successfully");
    return true;
}
