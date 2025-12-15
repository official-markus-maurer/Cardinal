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

#include "vulkan_buffer_manager.h"
#include "vulkan_descriptor_manager.h"
#include "vulkan_state.h"
#include <cardinal/core/log.h>
#include <cardinal/renderer/util/vulkan_buffer_utils.h>
#include <cardinal/renderer/util/vulkan_descriptor_utils.h>
#include <cardinal/renderer/util/vulkan_material_utils.h>
#include <cardinal/renderer/util/vulkan_shader_utils.h>
#include <cardinal/renderer/util/vulkan_texture_utils.h>
#include <cardinal/renderer/vulkan_pbr.h>
#include <cardinal/renderer/vulkan_sync_manager.h>
#include <cardinal/renderer/vulkan_texture_manager.h>
#include <cardinal/renderer/vulkan_utils.h>
#include <stdlib.h>
#include <string.h>

/**
 * @brief Creates the descriptor manager for the PBR pipeline.
 */
static bool create_pbr_descriptor_manager(VulkanPBRPipeline* pipeline, VkDevice device,
                                          VulkanAllocator* allocator, VulkanState* vulkan_state) {
    pipeline->descriptorManager = (VulkanDescriptorManager*)malloc(sizeof(VulkanDescriptorManager));
    if (!pipeline->descriptorManager) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for descriptor manager");
        return false;
    }

    VulkanDescriptorBinding bindings[9] = {
        {0,         VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,    1,
         VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, NULL                       },
        {1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,    1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL},
        {2, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,    1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL},
        {3, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,    1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL},
        {4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,    1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL},
        {5, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,    1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL},
        {6,         VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,    1,   VK_SHADER_STAGE_VERTEX_BIT, NULL},
        // Binding 7 removed (Material passed via Push Constants)
        {8,         VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,    1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL},
        {9, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 5000, VK_SHADER_STAGE_FRAGMENT_BIT, NULL}
    };

    // Disable descriptor buffers for PBR pipeline for now as we use vkCmdBindDescriptorSets
    bool prefer_descriptor_buffers = false;
    // (vulkan_state && vulkan_state->context.descriptor_buffer_extension_available);

    VulkanDescriptorManagerCreateInfo createInfo = {
        .bindings = bindings,
        .bindingCount = 9,
        .maxSets = 1000,
        .preferDescriptorBuffers = prefer_descriptor_buffers,
        .poolFlags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT |
                     VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT};

    CARDINAL_LOG_INFO("Creating PBR descriptor manager with %u max sets (prefer buffers: %s)",
                      createInfo.maxSets, prefer_descriptor_buffers ? "true" : "false");

    if (!vk_descriptor_manager_create(pipeline->descriptorManager, device, allocator, &createInfo,
                                      vulkan_state)) {
        CARDINAL_LOG_ERROR("Failed to create descriptor manager!");
        free(pipeline->descriptorManager);
        pipeline->descriptorManager = NULL;
        return false;
    }
    return true;
}

/**
 * @brief Creates the texture manager for the PBR pipeline.
 */
static bool create_pbr_texture_manager(VulkanPBRPipeline* pipeline, VkDevice device,
                                       VulkanAllocator* allocator, VkCommandPool commandPool,
                                       VkQueue graphicsQueue) {
    pipeline->textureManager = (VulkanTextureManager*)malloc(sizeof(VulkanTextureManager));
    if (!pipeline->textureManager) {
        CARDINAL_LOG_ERROR("Failed to allocate texture manager for PBR pipeline");
        return false;
    }

    VulkanTextureManagerConfig textureConfig = {
        .device = device,
        .allocator = allocator,
        .commandPool = commandPool,
        .graphicsQueue = graphicsQueue,
        .syncManager = NULL, // Will be set when VulkanState is available
        .initialCapacity = 16};

    if (!vk_texture_manager_init(pipeline->textureManager, &textureConfig)) {
        CARDINAL_LOG_ERROR("Failed to initialize texture manager for PBR pipeline");
        free(pipeline->textureManager);
        pipeline->textureManager = NULL;
        return false;
    }
    return true;
}

/**
 * @brief Creates the pipeline layout.
 */
static bool create_pbr_pipeline_layout(VulkanPBRPipeline* pipeline, VkDevice device) {
    VkPushConstantRange pushConstantRange = {.stageFlags = VK_SHADER_STAGE_VERTEX_BIT |
                                                           VK_SHADER_STAGE_FRAGMENT_BIT,
                                             .offset = 0,
                                             .size = sizeof(PBRPushConstants)};

    VkDescriptorSetLayout descriptorLayout =
        vk_descriptor_manager_get_layout(pipeline->descriptorManager);
    VkPipelineLayoutCreateInfo pipelineLayoutInfo = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &descriptorLayout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &pushConstantRange};

    return vk_utils_create_pipeline_layout(device, &pipelineLayoutInfo, &pipeline->pipelineLayout,
                                           "PBR pipeline layout");
}

/**
 * @brief Configures shader stages for the pipeline.
 */
static void configure_shader_stages(VkPipelineShaderStageCreateInfo* stages,
                                    VkShaderModule vertShader, VkShaderModule fragShader) {
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vertShader;
    stages[0].pName = "main";
    stages[0].pNext = NULL;
    stages[0].flags = 0;
    stages[0].pSpecializationInfo = NULL;

    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fragShader;
    stages[1].pName = "main";
    stages[1].pNext = NULL;
    stages[1].flags = 0;
    stages[1].pSpecializationInfo = NULL;
}

/**
 * @brief Configures vertex input state.
 */
static void configure_vertex_input(VkPipelineVertexInputStateCreateInfo* info,
                                   VkVertexInputBindingDescription* binding,
                                   VkVertexInputAttributeDescription* attributes) {
    *binding = (VkVertexInputBindingDescription){
        .binding = 0, .stride = sizeof(CardinalVertex), .inputRate = VK_VERTEX_INPUT_RATE_VERTEX};

    attributes[0] = (VkVertexInputAttributeDescription){
        .binding = 0, .location = 0, .format = VK_FORMAT_R32G32B32_SFLOAT, .offset = 0};
    attributes[1] = (VkVertexInputAttributeDescription){.binding = 0,
                                                        .location = 1,
                                                        .format = VK_FORMAT_R32G32B32_SFLOAT,
                                                        .offset = sizeof(float) * 3};
    attributes[2] = (VkVertexInputAttributeDescription){.binding = 0,
                                                        .location = 2,
                                                        .format = VK_FORMAT_R32G32_SFLOAT,
                                                        .offset = sizeof(float) * 6};
    attributes[3] =
        (VkVertexInputAttributeDescription){.binding = 0,
                                            .location = 3,
                                            .format = VK_FORMAT_R32G32B32A32_SFLOAT,
                                            .offset = offsetof(CardinalVertex, bone_weights)};
    attributes[4] =
        (VkVertexInputAttributeDescription){.binding = 0,
                                            .location = 4,
                                            .format = VK_FORMAT_R32G32B32A32_UINT,
                                            .offset = offsetof(CardinalVertex, bone_indices)};

    info->sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    info->vertexBindingDescriptionCount = 1;
    info->pVertexBindingDescriptions = binding;
    info->vertexAttributeDescriptionCount = 5;
    info->pVertexAttributeDescriptions = attributes;
    info->pNext = NULL;
    info->flags = 0;
}

/**
 * @brief Configures input assembly state.
 */
static void configure_input_assembly(VkPipelineInputAssemblyStateCreateInfo* info) {
    info->sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    info->topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    info->primitiveRestartEnable = VK_FALSE;
    info->pNext = NULL;
    info->flags = 0;
}

/**
 * @brief Configures viewport state.
 */
static void configure_viewport_state(VkPipelineViewportStateCreateInfo* info) {
    info->sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    info->viewportCount = 1;
    info->scissorCount = 1;
    info->pNext = NULL;
    info->flags = 0;
}

/**
 * @brief Configures rasterization state.
 */
static void configure_rasterization(VkPipelineRasterizationStateCreateInfo* info) {
    info->sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    info->depthClampEnable = VK_FALSE;
    info->rasterizerDiscardEnable = VK_FALSE;
    info->polygonMode = VK_POLYGON_MODE_FILL;
    info->lineWidth = 1.0f;
    info->cullMode = VK_CULL_MODE_NONE; // Disable culling for troubleshooting
    info->frontFace = VK_FRONT_FACE_CLOCKWISE;
    info->depthBiasEnable = VK_FALSE;
    info->pNext = NULL;
    info->flags = 0;
}

/**
 * @brief Configures multisample state.
 */
static void configure_multisampling(VkPipelineMultisampleStateCreateInfo* info) {
    info->sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    info->sampleShadingEnable = VK_FALSE;
    info->rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    info->minSampleShading = 1.0f; // Optional
    info->pSampleMask = NULL;      // Optional
    info->alphaToCoverageEnable = VK_FALSE;
    info->alphaToOneEnable = VK_FALSE;
    info->pNext = NULL;
    info->flags = 0;
}

/**
 * @brief Configures depth stencil state.
 */
static void configure_depth_stencil(VkPipelineDepthStencilStateCreateInfo* info,
                                    bool depthWriteEnable) {
    info->sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    info->depthTestEnable = VK_TRUE;
    info->depthWriteEnable = depthWriteEnable ? VK_TRUE : VK_FALSE;
    info->depthCompareOp = VK_COMPARE_OP_LESS;
    info->depthBoundsTestEnable = VK_FALSE;
    info->stencilTestEnable = VK_FALSE;
    info->pNext = NULL;
    info->flags = 0;
}

/**
 * @brief Configures color blending state.
 */
static void configure_color_blending(VkPipelineColorBlendStateCreateInfo* info,
                                     VkPipelineColorBlendAttachmentState* attachment,
                                     bool blendEnable) {
    attachment->colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                 VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    attachment->blendEnable = blendEnable ? VK_TRUE : VK_FALSE;

    if (blendEnable) {
        attachment->srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        attachment->dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        attachment->colorBlendOp = VK_BLEND_OP_ADD;
        attachment->srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        attachment->dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
        attachment->alphaBlendOp = VK_BLEND_OP_ADD;
    }

    info->sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    info->logicOpEnable = VK_FALSE;
    info->logicOp = VK_LOGIC_OP_COPY;
    info->attachmentCount = 1;
    info->pAttachments = attachment;
    info->blendConstants[0] = 0.0f;
    info->blendConstants[1] = 0.0f;
    info->blendConstants[2] = 0.0f;
    info->blendConstants[3] = 0.0f;
    info->pNext = NULL;
    info->flags = 0;
}

/**
 * @brief Configures dynamic state.
 */
static void configure_dynamic_state(VkPipelineDynamicStateCreateInfo* info,
                                    VkDynamicState* states) {
    states[0] = VK_DYNAMIC_STATE_VIEWPORT;
    states[1] = VK_DYNAMIC_STATE_SCISSOR;
    states[2] = VK_DYNAMIC_STATE_DEPTH_BIAS;

    info->sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    info->dynamicStateCount = 3;
    info->pDynamicStates = states;
    info->pNext = NULL;
    info->flags = 0;
}

/**
 * @brief Configures dynamic rendering info.
 */
static void configure_rendering_info(VkPipelineRenderingCreateInfo* info, VkFormat* colorFormat,
                                     VkFormat depthFormat) {
    info->sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    info->viewMask = 0;
    info->colorAttachmentCount = 1;
    info->pColorAttachmentFormats = colorFormat;
    info->depthAttachmentFormat = depthFormat;
    info->stencilAttachmentFormat = VK_FORMAT_UNDEFINED;
    info->pNext = NULL;
}

/**
 * @brief Creates the graphics pipeline.
 */
static bool create_pbr_graphics_pipeline(VulkanPBRPipeline* pipeline, VkDevice device,
                                         VkShaderModule vertShader, VkShaderModule fragShader,
                                         VkFormat swapchainFormat, VkFormat depthFormat,
                                         bool enableBlending, bool enableDepthWrite,
                                         VkPipeline* outPipeline) {
    VkPipelineShaderStageCreateInfo shaderStages[2];
    configure_shader_stages(shaderStages, vertShader, fragShader);

    VkVertexInputBindingDescription bindingDescription;
    VkVertexInputAttributeDescription attributeDescriptions[5];
    VkPipelineVertexInputStateCreateInfo vertexInputInfo;
    configure_vertex_input(&vertexInputInfo, &bindingDescription, attributeDescriptions);

    VkPipelineInputAssemblyStateCreateInfo inputAssembly;
    configure_input_assembly(&inputAssembly);

    VkPipelineViewportStateCreateInfo viewportState;
    configure_viewport_state(&viewportState);

    VkPipelineRasterizationStateCreateInfo rasterizer;
    configure_rasterization(&rasterizer);
    // Enable depth bias in rasterizer state (it's dynamic but needs to be enabled here too mostly for
    // structure, but dynamic state overrides values)
    rasterizer.depthBiasEnable = VK_TRUE;

    VkPipelineMultisampleStateCreateInfo multisampling;
    configure_multisampling(&multisampling);

    VkPipelineDepthStencilStateCreateInfo depthStencil;
    configure_depth_stencil(&depthStencil, enableDepthWrite);

    VkPipelineColorBlendAttachmentState colorBlendAttachment;
    VkPipelineColorBlendStateCreateInfo colorBlending;
    configure_color_blending(&colorBlending, &colorBlendAttachment, enableBlending);

    VkDynamicState dynamicStates[3];
    VkPipelineDynamicStateCreateInfo dynamicState;
    configure_dynamic_state(&dynamicState, dynamicStates);

    VkGraphicsPipelineCreateInfo pipelineInfo = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = shaderStages,
        .pVertexInputState = &vertexInputInfo,
        .pInputAssemblyState = &inputAssembly,
        .pViewportState = &viewportState,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &depthStencil,
        .pColorBlendState = &colorBlending,
        .pDynamicState = &dynamicState,
        .layout = pipeline->pipelineLayout,
        .renderPass = VK_NULL_HANDLE,
        .subpass = 0};

    VkPipelineRenderingCreateInfo pipelineRenderingInfo;
    configure_rendering_info(&pipelineRenderingInfo, &swapchainFormat, depthFormat);
    pipelineInfo.pNext = &pipelineRenderingInfo;

    VkResult result =
        vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, NULL, outPipeline);
    return VK_CHECK_RESULT(result, "create PBR graphics pipeline");
}

/**
 * @brief Creates uniform buffers for the PBR pipeline.
 */
static bool create_pbr_uniform_buffers(VulkanPBRPipeline* pipeline, VkDevice device,
                                       VulkanAllocator* allocator) {
    // UBO
    VulkanBufferCreateInfo uboInfo = {.size = sizeof(PBRUniformBufferObject),
                                      .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                                      .properties = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                      .persistentlyMapped = true};
    VulkanBuffer uboBuffer;
    if (!vk_buffer_create(&uboBuffer, device, allocator, &uboInfo))
        return false;
    pipeline->uniformBuffer = uboBuffer.handle;
    pipeline->uniformBufferMemory = uboBuffer.memory;
    pipeline->uniformBufferMapped = uboBuffer.mapped;

    // Material
    VulkanBufferCreateInfo matInfo = {.size = sizeof(PBRMaterialProperties),
                                      .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                                      .properties = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                      .persistentlyMapped = true};
    VulkanBuffer matBuffer;
    if (!vk_buffer_create(&matBuffer, device, allocator, &matInfo))
        return false;
    pipeline->materialBuffer = matBuffer.handle;
    pipeline->materialBufferMemory = matBuffer.memory;
    pipeline->materialBufferMapped = matBuffer.mapped;

    // Lighting
    VulkanBufferCreateInfo lightInfo = {.size = sizeof(PBRLightingData),
                                        .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                                        .properties = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                      VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                        .persistentlyMapped = true};
    VulkanBuffer lightBuffer;
    if (!vk_buffer_create(&lightBuffer, device, allocator, &lightInfo))
        return false;
    pipeline->lightingBuffer = lightBuffer.handle;
    pipeline->lightingBufferMemory = lightBuffer.memory;
    pipeline->lightingBufferMapped = lightBuffer.mapped;

    // Bone matrices
    pipeline->maxBones = 256;
    VulkanBufferCreateInfo boneInfo = {.size = pipeline->maxBones * 16 * sizeof(float),
                                       .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                                       .properties = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                     VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                       .persistentlyMapped = true};
    VulkanBuffer boneBuffer;
    if (!vk_buffer_create(&boneBuffer, device, allocator, &boneInfo))
        return false;
    pipeline->boneMatricesBuffer = boneBuffer.handle;
    pipeline->boneMatricesBufferMemory = boneBuffer.memory;
    pipeline->boneMatricesBufferMapped = boneBuffer.mapped;

    // Init bone matrices to identity
    float* boneMatrices = (float*)pipeline->boneMatricesBufferMapped;
    for (uint32_t i = 0; i < pipeline->maxBones; ++i) {
        memset(&boneMatrices[i * 16], 0, 16 * sizeof(float));
        boneMatrices[i * 16 + 0] = 1.0f;
        boneMatrices[i * 16 + 5] = 1.0f;
        boneMatrices[i * 16 + 10] = 1.0f;
        boneMatrices[i * 16 + 15] = 1.0f;
    }

    return true;
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
/**
 * @brief Loads PBR shader modules.
 */
static bool load_pbr_shaders(VkDevice device, VkShaderModule* vertShaderModule,
                             VkShaderModule* fragShaderModule) {
    char vert_path[512], frag_path[512];
    const char* shaders_dir = getenv("CARDINAL_SHADERS_DIR");
    if (!shaders_dir || !shaders_dir[0])
        shaders_dir = "assets/shaders";
    snprintf(vert_path, sizeof(vert_path), "%s/pbr.vert.spv", shaders_dir);
    snprintf(frag_path, sizeof(frag_path), "%s/pbr.frag.spv", shaders_dir);

    CARDINAL_LOG_DEBUG("Using shader paths: vert=%s, frag=%s", vert_path, frag_path);

    if (!vk_shader_create_module(device, vert_path, vertShaderModule)) {
        CARDINAL_LOG_ERROR("Failed to create vertex shader module!");
        return false;
    }
    if (!vk_shader_create_module(device, frag_path, fragShaderModule)) {
        CARDINAL_LOG_ERROR("Failed to create fragment shader module!");
        vkDestroyShaderModule(device, *vertShaderModule, NULL);
        return false;
    }
    return true;
}

/**
 * @brief Initializes default material and lighting properties.
 */
static void initialize_pbr_defaults(VulkanPBRPipeline* pipeline) {
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

    // Initialize default lighting
    PBRLightingData defaultLighting = {0};
    defaultLighting.lightDirection[0] = -0.5f;
    defaultLighting.lightDirection[1] = -1.0f;
    defaultLighting.lightDirection[2] = -0.3f;
    defaultLighting.lightColor[0] = 1.0f;
    defaultLighting.lightColor[1] = 1.0f;
    defaultLighting.lightColor[2] = 1.0f;
    defaultLighting.lightIntensity = 2.5f;  // Increased for better illumination
    defaultLighting.ambientColor[0] = 0.2f; // Increased ambient for better visibility
    defaultLighting.ambientColor[1] = 0.2f;
    defaultLighting.ambientColor[2] = 0.2f;
    memcpy(pipeline->lightingBufferMapped, &defaultLighting, sizeof(PBRLightingData));
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
 */
bool vk_pbr_pipeline_create(VulkanPBRPipeline* pipeline, VkDevice device,
                            VkPhysicalDevice physicalDevice, VkFormat swapchainFormat,
                            VkFormat depthFormat, VkCommandPool commandPool, VkQueue graphicsQueue,
                            VulkanAllocator* allocator, VulkanState* vulkan_state) {
    (void)physicalDevice; // Suppress unused parameter warning

    CARDINAL_LOG_DEBUG("Starting PBR pipeline creation");

    memset(pipeline, 0, sizeof(VulkanPBRPipeline));

    // Descriptor indexing is guaranteed in Vulkan 1.3
    pipeline->supportsDescriptorIndexing = true;
    pipeline->totalIndexCount = 0;

    CARDINAL_LOG_INFO("[PBR] Descriptor indexing support: enabled");

    // 1. Create Descriptor Manager
    if (!create_pbr_descriptor_manager(pipeline, device, allocator, vulkan_state)) {
        return false;
    }
    CARDINAL_LOG_DEBUG("Descriptor manager created successfully");

    // 2. Create Texture Manager
    if (!create_pbr_texture_manager(pipeline, device, allocator, commandPool, graphicsQueue)) {
        vk_descriptor_manager_destroy(pipeline->descriptorManager);
        free(pipeline->descriptorManager);
        return false;
    }
    CARDINAL_LOG_DEBUG("Texture manager initialized successfully");

    // 3. Create Pipeline Layout
    if (!create_pbr_pipeline_layout(pipeline, device)) {
        vk_texture_manager_destroy(pipeline->textureManager);
        free(pipeline->textureManager);
        vk_descriptor_manager_destroy(pipeline->descriptorManager);
        free(pipeline->descriptorManager);
        return false;
    }

    // 4. Load Shaders
    VkShaderModule vertShaderModule, fragShaderModule;
    if (!load_pbr_shaders(device, &vertShaderModule, &fragShaderModule)) {
        return false;
    }

    // 5. Create Graphics Pipelines
    
    // Opaque pipeline: No blending, Depth Write ON
    if (!create_pbr_graphics_pipeline(pipeline, device, vertShaderModule, fragShaderModule,
                                      swapchainFormat, depthFormat, false, true,
                                      &pipeline->pipeline)) {
        vkDestroyShaderModule(device, vertShaderModule, NULL);
        vkDestroyShaderModule(device, fragShaderModule, NULL);
        return false;
    }

    // Blend pipeline: Blending ON, Depth Write OFF
    if (!create_pbr_graphics_pipeline(pipeline, device, vertShaderModule, fragShaderModule,
                                      swapchainFormat, depthFormat, true, false,
                                      &pipeline->pipelineBlend)) {
        vkDestroyShaderModule(device, vertShaderModule, NULL);
        vkDestroyShaderModule(device, fragShaderModule, NULL);
        return false;
    }

    // Clean up shader modules
    vkDestroyShaderModule(device, vertShaderModule, NULL);
    vkDestroyShaderModule(device, fragShaderModule, NULL);

    CARDINAL_LOG_DEBUG("PBR graphics pipelines created: opaque=%p, blend=%p",
                       (void*)(uintptr_t)pipeline->pipeline,
                       (void*)(uintptr_t)pipeline->pipelineBlend);

    // 6. Create Uniform Buffers
    if (!create_pbr_uniform_buffers(pipeline, device, allocator)) {
        return false;
    }

    // 7. Initialize default material properties and lighting
    initialize_pbr_defaults(pipeline);

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

    // Destroy texture manager
    if (pipeline->textureManager) {
        vk_texture_manager_destroy(pipeline->textureManager);
        free(pipeline->textureManager);
        pipeline->textureManager = NULL;
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

    // Destroy descriptor manager
    if (pipeline->descriptorManager) {
        vk_descriptor_manager_destroy(pipeline->descriptorManager);
        free(pipeline->descriptorManager);
        pipeline->descriptorManager = NULL;
    }

    // Destroy pipeline and layout
    if (pipeline->pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(device, pipeline->pipeline, NULL);
    }
    if (pipeline->pipelineBlend != VK_NULL_HANDLE) {
        vkDestroyPipeline(device, pipeline->pipelineBlend, NULL);
    }

    if (pipeline->pipelineLayout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(device, pipeline->pipelineLayout, NULL);
    }

    // Descriptor set layout is now managed by descriptor manager

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

    if (pipeline->vertexBuffer == VK_NULL_HANDLE || pipeline->indexBuffer == VK_NULL_HANDLE) {
        // Buffers not ready or scene empty
        return;
    }

    VkBuffer vertexBuffers[] = {pipeline->vertexBuffer};
    VkDeviceSize offsets[] = {0};
    vkCmdBindVertexBuffers(commandBuffer, 0, 1, vertexBuffers, offsets);
    vkCmdBindIndexBuffer(commandBuffer, pipeline->indexBuffer, 0, VK_INDEX_TYPE_UINT32);

    // Bind descriptor set using descriptor manager
    VkDescriptorSet descriptorSet = VK_NULL_HANDLE;
    if (pipeline->descriptorManager && pipeline->descriptorManager->descriptorSets &&
        pipeline->descriptorManager->descriptorSetCount > 0) {
        // Always use the latest allocated descriptor set (assuming one active set per scene)
        uint32_t setIndex = pipeline->descriptorManager->descriptorSetCount - 1;
        descriptorSet = pipeline->descriptorManager->descriptorSets[setIndex];
    } else {
        // No descriptor set available - might be an error or initialization state
        return;
    }

    // --- Render Passes ---
    // Pass 1: Opaque and Masked materials
    // Pass 2: Blended materials (sorted back-to-front if we had a camera, but for now just render
    // last)

    // Bind Opaque Pipeline first
    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline->pipeline);
    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                            pipeline->pipelineLayout, 0, 1, &descriptorSet, 0, NULL);

    // Reset depth bias
    vkCmdSetDepthBias(commandBuffer, 0.0f, 0.0f, 0.0f);

    uint32_t indexOffset = 0;
    // Pass 1: Opaque/Mask
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* mesh = &scene->meshes[i];
        bool is_blend = false;

        // Check material alpha mode
        if (mesh->material_index < scene->material_count) {
            const CardinalMaterial* mat = &scene->materials[mesh->material_index];
            if (mat->alpha_mode == CARDINAL_ALPHA_MODE_BLEND) {
                is_blend = true;
            }
        }

        if (is_blend) {
            indexOffset += mesh->index_count;
            continue; // Skip blend meshes in first pass
        }

        // Validate and Draw (same logic as before)
        if (!mesh->vertices || mesh->vertex_count == 0 || !mesh->indices ||
            mesh->index_count == 0 || mesh->index_count > 1000000000) {
            continue;
        }
        if (!mesh->visible) {
            indexOffset += mesh->index_count;
            continue;
        }

        // Prepare push constants
        PBRPushConstants pushConstants = {0};
        vk_material_setup_push_constants(&pushConstants, mesh, scene, pipeline->textureManager);

        // Skeleton logic...
        // Note: hasSkeleton flag (bit 2) is already cleared in setup (flags=0)
        // We only set it if we find a skeleton
        if (scene->animation_system && scene->skin_count > 0) {
            for (uint32_t skin_idx = 0; skin_idx < scene->skin_count; ++skin_idx) {
                const CardinalSkin* skin = &scene->skins[skin_idx];
                for (uint32_t mesh_idx = 0; mesh_idx < skin->mesh_count; ++mesh_idx) {
                    if (skin->mesh_indices[mesh_idx] == i) {
                        pushConstants.flags |= 4u; // Set hasSkeleton bit (bit 2)
                        if (scene->animation_system->bone_matrices) {
                            memcpy(pipeline->boneMatricesBufferMapped,
                                   scene->animation_system->bone_matrices,
                                   scene->animation_system->bone_matrix_count * 16 * sizeof(float));
                        }
                        break;
                    }
                }
                if (pushConstants.flags & 4u)
                    break;
            }
        }

        vkCmdPushConstants(commandBuffer, pipeline->pipelineLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0,
                           sizeof(PBRPushConstants), &pushConstants);

        if (indexOffset + mesh->index_count > pipeline->totalIndexCount) {
            break;
        }

        vkCmdDrawIndexed(commandBuffer, mesh->index_count, 1, indexOffset, 0, 0);
        indexOffset += mesh->index_count;
    }

    // Pass 2: Blended materials
    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline->pipelineBlend);
    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                            pipeline->pipelineLayout, 0, 1, &descriptorSet, 0, NULL);

    // Reset index offset for second pass
    indexOffset = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* mesh = &scene->meshes[i];
        bool is_blend = false;

        if (mesh->material_index < scene->material_count) {
            const CardinalMaterial* mat = &scene->materials[mesh->material_index];
            if (mat->alpha_mode == CARDINAL_ALPHA_MODE_BLEND) {
                is_blend = true;
            }
        }

        if (!is_blend) {
            indexOffset += mesh->index_count;
            continue; // Skip opaque meshes in second pass
        }

        // Apply depth bias for blended materials (decals)
        // Values: constantFactor, clamp, slopeFactor
        // Negative bias moves geometry closer to camera in Vulkan
        vkCmdSetDepthBias(commandBuffer, -2.0f, 0.0f, -2.0f);

        // Validate and Draw
        if (!mesh->vertices || mesh->vertex_count == 0 || !mesh->indices ||
            mesh->index_count == 0 || mesh->index_count > 1000000000) {
            continue;
        }
        if (!mesh->visible) {
            indexOffset += mesh->index_count;
            continue;
        }

        PBRPushConstants pushConstants = {0};
        vk_material_setup_push_constants(&pushConstants, mesh, scene, pipeline->textureManager);

        // Skeleton logic...
        // Note: hasSkeleton flag (bit 2) is already cleared in setup (flags=0)
        // We only set it if we find a skeleton
        if (scene->animation_system && scene->skin_count > 0) {
            for (uint32_t skin_idx = 0; skin_idx < scene->skin_count; ++skin_idx) {
                const CardinalSkin* skin = &scene->skins[skin_idx];
                for (uint32_t mesh_idx = 0; mesh_idx < skin->mesh_count; ++mesh_idx) {
                    if (skin->mesh_indices[mesh_idx] == i) {
                        pushConstants.flags |= 4u; // Set hasSkeleton bit (bit 2)
                        if (scene->animation_system->bone_matrices) {
                            memcpy(pipeline->boneMatricesBufferMapped,
                                   scene->animation_system->bone_matrices,
                                   scene->animation_system->bone_matrix_count * 16 * sizeof(float));
                        }
                        break;
                    }
                }
                if (pushConstants.flags & 4u)
                    break;
            }
        }

        vkCmdPushConstants(commandBuffer, pipeline->pipelineLayout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0,
                           sizeof(PBRPushConstants), &pushConstants);

        if (indexOffset + mesh->index_count > pipeline->totalIndexCount) {
            break;
        }

        vkCmdDrawIndexed(commandBuffer, mesh->index_count, 1, indexOffset, 0, 0);
        indexOffset += mesh->index_count;
    }
}

/**
 * @brief Creates vertex and index buffers for the PBR pipeline.
 */
static bool create_pbr_mesh_buffers(VulkanPBRPipeline* pipeline, VkDevice device,
                                    VulkanAllocator* allocator, VkCommandPool commandPool,
                                    VkQueue graphicsQueue, const CardinalScene* scene,
                                    VulkanState* vulkan_state) {
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

    // Prepare vertex data for upload
    VkDeviceSize vertexBufferSize = totalVertices * sizeof(CardinalVertex);
    CardinalVertex* vertexData = (CardinalVertex*)malloc(vertexBufferSize);
    if (!vertexData) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for vertex data");
        return false;
    }

    // Copy all vertex data into contiguous buffer
    uint32_t vertexOffset = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* mesh = &scene->meshes[i];
        memcpy(&vertexData[vertexOffset], mesh->vertices,
               mesh->vertex_count * sizeof(CardinalVertex));
        vertexOffset += mesh->vertex_count;
    }

    // Create vertex buffer using staging buffer
    if (!vk_buffer_create_with_staging(
            allocator, device, commandPool, graphicsQueue, vertexData, vertexBufferSize,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            &pipeline->vertexBuffer, &pipeline->vertexBufferMemory, vulkan_state)) {
        CARDINAL_LOG_ERROR("Failed to create PBR vertex buffer with staging");
        free(vertexData);
        return false;
    }

    free(vertexData);
    CARDINAL_LOG_DEBUG("Vertex buffer created with staging: %u vertices", totalVertices);

    // Create index buffer if we have indices
    if (totalIndices > 0) {
        VkDeviceSize indexBufferSize = totalIndices * sizeof(uint32_t);
        uint32_t* indexData = (uint32_t*)malloc(indexBufferSize);
        if (!indexData) {
            CARDINAL_LOG_ERROR("Failed to allocate memory for index data");
            return false;
        }

        // Copy all index data into contiguous buffer with vertex base offset adjustment
        uint32_t indexOffset = 0;
        uint32_t vertexBaseOffset = 0;
        for (uint32_t i = 0; i < scene->mesh_count; i++) {
            const CardinalMesh* mesh = &scene->meshes[i];
            if (mesh->index_count > 0) {
                for (uint32_t j = 0; j < mesh->index_count; j++) {
                    indexData[indexOffset + j] = mesh->indices[j] + vertexBaseOffset;
                }
                indexOffset += mesh->index_count;
            }
            vertexBaseOffset += mesh->vertex_count;
        }

        // Create index buffer using staging buffer
        if (!vk_buffer_create_with_staging(
                allocator, device, commandPool, graphicsQueue, indexData, indexBufferSize,
                VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                &pipeline->indexBuffer, &pipeline->indexBufferMemory, vulkan_state)) {
            CARDINAL_LOG_ERROR("Failed to create PBR index buffer with staging");
            free(indexData);
            return false;
        }

        free(indexData);
        pipeline->totalIndexCount = totalIndices;
        CARDINAL_LOG_DEBUG("Index buffer created with staging: %u indices", totalIndices);
    }

    return true;
}

/**
 * @brief Updates descriptor sets for the PBR pipeline.
 */
static bool update_pbr_descriptor_sets(VulkanPBRPipeline* pipeline) {
    uint32_t setIndex = pipeline->descriptorManager->descriptorSetCount > 0
                            ? pipeline->descriptorManager->descriptorSetCount - 1
                            : 0;

    // Update uniform buffer (binding 0)
    if (!vk_descriptor_manager_update_buffer(pipeline->descriptorManager, setIndex, 0,
                                             pipeline->uniformBuffer, 0,
                                             sizeof(PBRUniformBufferObject))) {
        CARDINAL_LOG_ERROR("Failed to update uniform buffer descriptor");
        return false;
    }

    // Update bone matrices buffer (binding 6)
    if (!vk_descriptor_manager_update_buffer(pipeline->descriptorManager, setIndex, 6,
                                             pipeline->boneMatricesBuffer, 0,
                                             sizeof(float) * 16 * pipeline->maxBones)) {
        CARDINAL_LOG_ERROR("Failed to update bone matrices buffer descriptor");
        return false;
    }

    // Update placeholder textures for fixed bindings 1-5
    for (uint32_t b = 1; b <= 5; ++b) {
        VkImageView placeholderView = (pipeline->textureManager->textureCount > 0)
                                          ? pipeline->textureManager->textures[0].view
                                          : VK_NULL_HANDLE;
        VkSampler placeholderSampler = (pipeline->textureManager->textureCount > 0)
                                           ? pipeline->textureManager->textures[0].sampler
                                           : pipeline->textureManager->defaultSampler;

        if (!vk_descriptor_manager_update_image(pipeline->descriptorManager, setIndex, b,
                                                placeholderView,
                                                placeholderSampler,
                                                VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)) {
            CARDINAL_LOG_ERROR("Failed to update image descriptor for binding %u", b);
            return false;
        }
    }

    // Update variable descriptor array (binding 9)
    uint32_t texCount = pipeline->textureManager->textureCount;
    if (texCount > 0) {
        VkImageView* views = (VkImageView*)malloc(sizeof(VkImageView) * texCount);
        VkSampler* samplers = (VkSampler*)malloc(sizeof(VkSampler) * texCount);

        if (!views || !samplers) {
            CARDINAL_LOG_ERROR("Failed to allocate arrays for descriptor update");
            if (views) free(views);
            if (samplers) free(samplers);
            return false;
        }

        for (uint32_t i = 0; i < texCount; ++i) {
            views[i] = pipeline->textureManager->textures[i].view;
            samplers[i] = pipeline->textureManager->textures[i].sampler;
        }

        if (!vk_descriptor_manager_update_textures_with_samplers(pipeline->descriptorManager, setIndex, 9, views,
                                                   samplers,
                                                   VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                                   texCount)) {
            CARDINAL_LOG_ERROR("Failed to update variable texture array (binding 9)");
            free(views);
            free(samplers);
            return false;
        }
        free(views);
        free(samplers);
    }

    // Note: Material data is passed via Push Constants, so no binding 7 update needed.

    // Update lighting buffer (binding 8)
    if (!vk_descriptor_manager_update_buffer(pipeline->descriptorManager, setIndex, 8,
                                             pipeline->lightingBuffer, 0,
                                             sizeof(PBRLightingData))) {
        CARDINAL_LOG_ERROR("Failed to update lighting buffer descriptor");
        return false;
    }

    return true;
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
                       VulkanAllocator* allocator, VulkanState* vulkan_state) {
    (void)physicalDevice; // Unused parameter

    if (!pipeline->initialized || !scene || scene->mesh_count == 0) {
        CARDINAL_LOG_WARN("PBR pipeline not initialized or no scene data");
        return true;
    }

    CARDINAL_LOG_INFO("Loading PBR scene: %u meshes", scene->mesh_count);

    // Clean up previous buffers if they exist (after ensuring GPU idle/timeline reached)
    if (vulkan_state && vulkan_state->sync_manager &&
        vulkan_state->sync_manager->timeline_semaphore != VK_NULL_HANDLE) {
        VkResult wait_res = vulkan_sync_manager_wait_timeline(
            vulkan_state->sync_manager, vulkan_state->sync.current_frame_value, UINT64_MAX);
        if (wait_res != VK_SUCCESS && vulkan_state->context.device) {
            vkDeviceWaitIdle(vulkan_state->context.device);
        }
    } else if (vulkan_state && vulkan_state->context.device) {
        vkDeviceWaitIdle(vulkan_state->context.device);
    }

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

    // Create vertex and index buffers
    if (!create_pbr_mesh_buffers(pipeline, device, allocator, commandPool, graphicsQueue, scene,
                                 vulkan_state)) {
        return false;
    }

    // Texture manager handles its own synchronization during cleanup
    pipeline->textureManager->syncManager = vulkan_state->sync_manager;

    // Load scene textures using texture manager
    if (!vk_texture_manager_load_scene_textures(pipeline->textureManager, scene)) {
        CARDINAL_LOG_ERROR("Failed to load scene textures using texture manager");
        return false;
    }

    CARDINAL_LOG_INFO("Loaded %u textures using texture manager",
                      pipeline->textureManager->textureCount);

    // Reset descriptor pool to reclaim sets from previous scene loads
    if (pipeline->descriptorManager &&
        pipeline->descriptorManager->descriptorPool != VK_NULL_HANDLE) {
        vkResetDescriptorPool(pipeline->descriptorManager->device,
                              pipeline->descriptorManager->descriptorPool, 0);
        pipeline->descriptorManager->descriptorSetCount = 0;
    }

    // Allocate descriptor set using descriptor manager
    VkDescriptorSet descriptorSet = VK_NULL_HANDLE;
    uint32_t variableDescriptorCount = pipeline->textureManager->textureCount;

    // Allocate with variable descriptor count to satisfy binding 9 array size
    if (!vk_descriptor_allocate_sets(
            pipeline->descriptorManager->device, pipeline->descriptorManager->descriptorPool,
            pipeline->descriptorManager->layout, 1, variableDescriptorCount, &descriptorSet)) {
        CARDINAL_LOG_ERROR(
            "Failed to allocate descriptor set with variable count using descriptor manager");
        return false;
    }

    // Track the allocated set in the manager
    if (pipeline->descriptorManager->descriptorSetCount < 1000 &&
        pipeline->descriptorManager->descriptorSets) {
        pipeline->descriptorManager
            ->descriptorSets[pipeline->descriptorManager->descriptorSetCount++] = descriptorSet;
    }

    // Wait for graphics queue to complete before updating descriptor sets
    VkResult result = vkQueueWaitIdle(graphicsQueue);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_WARN("Graphics queue wait idle failed before descriptor update: %d", result);
    }

    // Update descriptor sets
    if (!update_pbr_descriptor_sets(pipeline)) {
        return false;
    }

    CARDINAL_LOG_INFO("PBR scene loaded successfully");
    return true;
}
