#include <cardinal/renderer/vulkan_pbr.h>
#include <cardinal/core/log.h>
#include <string.h>
#include <stdlib.h>

// Helper function to find memory type
static uint32_t findMemoryType(VkPhysicalDevice physicalDevice, uint32_t typeFilter, VkMemoryPropertyFlags properties) {
    VkPhysicalDeviceMemoryProperties memProperties;
    vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProperties);
    
    for (uint32_t i = 0; i < memProperties.memoryTypeCount; i++) {
        if ((typeFilter & (1 << i)) && (memProperties.memoryTypes[i].propertyFlags & properties) == properties) {
            return i;
        }
    }
    
    CARDINAL_LOG_ERROR("Failed to find suitable memory type!");
    return UINT32_MAX;
}

// Forward declaration for createBuffer used below
static bool createBuffer(VkDevice device, VkPhysicalDevice physicalDevice, VkDeviceSize size,
                        VkBufferUsageFlags usage, VkMemoryPropertyFlags properties,
                        VkBuffer* buffer, VkDeviceMemory* bufferMemory);

static bool createPlaceholderTexture(VkDevice device, VkPhysicalDevice physicalDevice,
                                   VkCommandPool commandPool, VkQueue graphicsQueue,
                                   VkImage* textureImage, VkDeviceMemory* textureImageMemory,
                                   VkImageView* textureImageView, VkSampler* textureSampler) {
    // Create a 1x1 white texture
    const uint32_t width = 1, height = 1;
    const VkFormat format = VK_FORMAT_R8G8B8A8_SRGB;
    unsigned char whitePixel[4] = {255, 255, 255, 255};
    
    // Create staging buffer
    VkBuffer stagingBuffer;
    VkDeviceMemory stagingBufferMemory;
    VkDeviceSize imageSize = width * height * 4;
    
    if (!createBuffer(device, physicalDevice, imageSize,
                     VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &stagingBuffer, &stagingBufferMemory)) {
        return false;
    }
    
    void* data;
    vkMapMemory(device, stagingBufferMemory, 0, imageSize, 0, &data);
    memcpy(data, whitePixel, (size_t)imageSize);
    vkUnmapMemory(device, stagingBufferMemory);
    
    // Create image
    VkImageCreateInfo imageInfo = {0};
    imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = width;
    imageInfo.extent.height = height;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = format;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    
    if (vkCreateImage(device, &imageInfo, NULL, textureImage) != VK_SUCCESS) {
        vkDestroyBuffer(device, stagingBuffer, NULL);
        vkFreeMemory(device, stagingBufferMemory, NULL);
        return false;
    }
    
    VkMemoryRequirements memRequirements;
    vkGetImageMemoryRequirements(device, *textureImage, &memRequirements);
    
    VkMemoryAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocInfo.allocationSize = memRequirements.size;
    allocInfo.memoryTypeIndex = findMemoryType(physicalDevice, memRequirements.memoryTypeBits,
                                              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    
    if (vkAllocateMemory(device, &allocInfo, NULL, textureImageMemory) != VK_SUCCESS ||
        vkBindImageMemory(device, *textureImage, *textureImageMemory, 0) != VK_SUCCESS) {
        vkDestroyImage(device, *textureImage, NULL);
        vkDestroyBuffer(device, stagingBuffer, NULL);
        vkFreeMemory(device, stagingBufferMemory, NULL);
        return false;
    }
    
    // Copy buffer to image (simplified, without proper layout transitions)
    VkCommandBufferAllocateInfo allocInfo2 = {0};
    allocInfo2.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo2.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo2.commandPool = commandPool;
    allocInfo2.commandBufferCount = 1;
    
    VkCommandBuffer commandBuffer;
    vkAllocateCommandBuffers(device, &allocInfo2, &commandBuffer);
    
    VkCommandBufferBeginInfo beginInfo = {0};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    
    vkBeginCommandBuffer(commandBuffer, &beginInfo);
    
    // Transition to transfer destination
    VkImageMemoryBarrier barrier = {0};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = *textureImage;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    
    vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                        VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    
    VkBufferImageCopy region = {0};
    region.bufferOffset = 0;
    region.bufferRowLength = 0;
    region.bufferImageHeight = 0;
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel = 0;
    region.imageSubresource.baseArrayLayer = 0;
    region.imageSubresource.layerCount = 1;
    region.imageOffset.x = 0;
    region.imageOffset.y = 0;
    region.imageOffset.z = 0;
    region.imageExtent.width = width;
    region.imageExtent.height = height;
    region.imageExtent.depth = 1;
    
    vkCmdCopyBufferToImage(commandBuffer, stagingBuffer, *textureImage,
                          VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    
    // Transition to shader read
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    
    vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    
    vkEndCommandBuffer(commandBuffer);
    
    VkSubmitInfo submitInfo = {0};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &commandBuffer;
    
    vkQueueSubmit(graphicsQueue, 1, &submitInfo, VK_NULL_HANDLE);
    vkQueueWaitIdle(graphicsQueue);
    
    vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
    vkDestroyBuffer(device, stagingBuffer, NULL);
    vkFreeMemory(device, stagingBufferMemory, NULL);
    
    // Create image view
    VkImageViewCreateInfo viewInfo = {0};
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = *textureImage;
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = format;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;
    
    if (vkCreateImageView(device, &viewInfo, NULL, textureImageView) != VK_SUCCESS) {
        return false;
    }
    
    // Create sampler
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
    
    return vkCreateSampler(device, &samplerInfo, NULL, textureSampler) == VK_SUCCESS;
}

// Helper function to create buffer
static bool createBuffer(VkDevice device, VkPhysicalDevice physicalDevice, VkDeviceSize size,
                        VkBufferUsageFlags usage, VkMemoryPropertyFlags properties,
                        VkBuffer* buffer, VkDeviceMemory* bufferMemory) {
    if (size == 0) {
        CARDINAL_LOG_ERROR("Cannot create buffer with size 0");
        return false;
    }
    
    VkBufferCreateInfo bufferInfo = {0};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = size;
    bufferInfo.usage = usage;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    
    VkResult result = vkCreateBuffer(device, &bufferInfo, NULL, buffer);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create buffer: %d", result);
        return false;
    }
    
    VkMemoryRequirements memRequirements;
    vkGetBufferMemoryRequirements(device, *buffer, &memRequirements);
    
    uint32_t memoryTypeIndex = findMemoryType(physicalDevice, memRequirements.memoryTypeBits, properties);
    if (memoryTypeIndex == UINT32_MAX) {
        CARDINAL_LOG_ERROR("Failed to find suitable memory type for buffer");
        vkDestroyBuffer(device, *buffer, NULL);
        *buffer = VK_NULL_HANDLE;
        return false;
    }
    
    VkMemoryAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocInfo.allocationSize = memRequirements.size;
    allocInfo.memoryTypeIndex = memoryTypeIndex;
    
    result = vkAllocateMemory(device, &allocInfo, NULL, bufferMemory);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate buffer memory: %d", result);
        vkDestroyBuffer(device, *buffer, NULL);
        *buffer = VK_NULL_HANDLE;
        return false;
    }
    
    result = vkBindBufferMemory(device, *buffer, *bufferMemory, 0);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to bind buffer memory: %d", result);
        vkFreeMemory(device, *bufferMemory, NULL);
        vkDestroyBuffer(device, *buffer, NULL);
        *buffer = VK_NULL_HANDLE;
        *bufferMemory = VK_NULL_HANDLE;
        return false;
    }
    
    return true;
}

// Helper function to copy buffer
__attribute__((unused))
static void copyBuffer(VkDevice device, VkCommandPool commandPool, VkQueue graphicsQueue,
                      VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size) {
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
    
    VkSubmitInfo submitInfo = {0};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &commandBuffer;
    
    vkQueueSubmit(graphicsQueue, 1, &submitInfo, VK_NULL_HANDLE);
    vkQueueWaitIdle(graphicsQueue);
    
    vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
}

// Helper function to load shader module
static VkShaderModule createShaderModule(VkDevice device, const char* filename) {
    FILE* file = fopen(filename, "rb");
    if (!file) {
        CARDINAL_LOG_ERROR("Failed to open shader file: %s", filename);
        return VK_NULL_HANDLE;
    }
    
    fseek(file, 0, SEEK_END);
    size_t fileSize = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    char* code = malloc(fileSize);
    fread(code, 1, fileSize, file);
    fclose(file);
    
    VkShaderModuleCreateInfo createInfo = {0};
    createInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    createInfo.codeSize = fileSize;
    createInfo.pCode = (const uint32_t*)code;
    
    VkShaderModule shaderModule;
    if (vkCreateShaderModule(device, &createInfo, NULL, &shaderModule) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create shader module!");
        free(code);
        return VK_NULL_HANDLE;
    }
    
    free(code);
    return shaderModule;
}

bool vk_pbr_pipeline_create(VulkanPBRPipeline* pipeline, VkDevice device, VkPhysicalDevice physicalDevice,
                            VkRenderPass renderPass, VkCommandPool commandPool, VkQueue graphicsQueue) {
    // Suppress unused parameter warnings
    (void)commandPool;
    (void)graphicsQueue;
    
    memset(pipeline, 0, sizeof(VulkanPBRPipeline));
    
    // Create descriptor set layout
    VkDescriptorSetLayoutBinding bindings[8] = {0};
    
    // UBO binding
    bindings[0].binding = 0;
    bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[0].descriptorCount = 1;
    bindings[0].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    
    // Texture bindings
    for (int i = 1; i <= 5; i++) {
        bindings[i].binding = i;
        bindings[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[i].descriptorCount = 1;
        bindings[i].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    }
    
    // Material properties binding
    bindings[6].binding = 6;
    bindings[6].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[6].descriptorCount = 1;
    bindings[6].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    
    // Lighting data binding
    bindings[7].binding = 7;
    bindings[7].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[7].descriptorCount = 1;
    bindings[7].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    
    VkDescriptorSetLayoutCreateInfo layoutInfo = {0};
    layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = 8;
    layoutInfo.pBindings = bindings;
    
    if (vkCreateDescriptorSetLayout(device, &layoutInfo, NULL, &pipeline->descriptorSetLayout) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor set layout!");
        return false;
    }
    
    // Create pipeline layout
    VkPipelineLayoutCreateInfo pipelineLayoutInfo = {0};
    pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    pipelineLayoutInfo.pSetLayouts = &pipeline->descriptorSetLayout;
    
    if (vkCreatePipelineLayout(device, &pipelineLayoutInfo, NULL, &pipeline->pipelineLayout) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create pipeline layout!");
        return false;
    }
    
    // Load shaders
    VkShaderModule vertShaderModule = createShaderModule(device, "assets/shaders/pbr.vert.spv");
    VkShaderModule fragShaderModule = createShaderModule(device, "assets/shaders/pbr.frag.spv");
    
    if (vertShaderModule == VK_NULL_HANDLE || fragShaderModule == VK_NULL_HANDLE) {
        CARDINAL_LOG_ERROR("Failed to load PBR shaders!");
        return false;
    }
    
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
    
    VkVertexInputAttributeDescription attributeDescriptions[3] = {0};
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
    
    VkPipelineVertexInputStateCreateInfo vertexInputInfo = {0};
    vertexInputInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertexInputInfo.vertexBindingDescriptionCount = 1;
    vertexInputInfo.pVertexBindingDescriptions = &bindingDescription;
    vertexInputInfo.vertexAttributeDescriptionCount = 3;
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
    rasterizer.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rasterizer.depthBiasEnable = VK_FALSE;
    
    // Multisampling
    VkPipelineMultisampleStateCreateInfo multisampling = {0};
    multisampling.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.sampleShadingEnable = VK_FALSE;
    multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    
    // Depth and stencil testing - DISABLED since render pass has no depth attachment
    VkPipelineDepthStencilStateCreateInfo depthStencil = {0};
    depthStencil.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depthStencil.depthTestEnable = VK_FALSE;  // Must be false - no depth attachment in render pass
    depthStencil.depthWriteEnable = VK_FALSE;
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
    pipelineInfo.renderPass = renderPass;
    pipelineInfo.subpass = 0;
    
    if (vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, NULL, &pipeline->pipeline) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create graphics pipeline!");
        vkDestroyShaderModule(device, vertShaderModule, NULL);
        vkDestroyShaderModule(device, fragShaderModule, NULL);
        return false;
    }
    
    vkDestroyShaderModule(device, vertShaderModule, NULL);
    vkDestroyShaderModule(device, fragShaderModule, NULL);
    
    // Create uniform buffers
    VkDeviceSize uboSize = sizeof(PBRUniformBufferObject);
    if (!createBuffer(device, physicalDevice, uboSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &pipeline->uniformBuffer, &pipeline->uniformBufferMemory)) {
        return false;
    }
    
    VkResult result = vkMapMemory(device, pipeline->uniformBufferMemory, 0, uboSize, 0, &pipeline->uniformBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map uniform buffer memory: %d", result);
        return false;
    }
    
    VkDeviceSize materialSize = sizeof(PBRMaterialProperties);
    if (!createBuffer(device, physicalDevice, materialSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &pipeline->materialBuffer, &pipeline->materialBufferMemory)) {
        return false;
    }
    
    result = vkMapMemory(device, pipeline->materialBufferMemory, 0, materialSize, 0, &pipeline->materialBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map material buffer memory: %d", result);
        return false;
    }
    
    VkDeviceSize lightingSize = sizeof(PBRLightingData);
    if (!createBuffer(device, physicalDevice, lightingSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &pipeline->lightingBuffer, &pipeline->lightingBufferMemory)) {
        return false;
    }
    
    result = vkMapMemory(device, pipeline->lightingBufferMemory, 0, lightingSize, 0, &pipeline->lightingBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map lighting buffer memory: %d", result);
        return false;
    }
    
    // Initialize default material properties
    PBRMaterialProperties defaultMaterial = {0};
    defaultMaterial.albedoFactor[0] = 0.8f;  // Light gray
    defaultMaterial.albedoFactor[1] = 0.8f;
    defaultMaterial.albedoFactor[2] = 0.8f;
    defaultMaterial.metallicFactor = 0.0f;
    defaultMaterial.roughnessFactor = 0.5f;
    defaultMaterial.emissiveFactor[0] = 0.0f;
    defaultMaterial.emissiveFactor[1] = 0.0f;
    defaultMaterial.emissiveFactor[2] = 0.0f;
    defaultMaterial.normalScale = 1.0f;
    defaultMaterial.aoStrength = 1.0f;
    memcpy(pipeline->materialBufferMapped, &defaultMaterial, sizeof(PBRMaterialProperties));
    
    // Initialize default lighting
    PBRLightingData defaultLighting = {0};
    defaultLighting.lightDirection[0] = -0.5f;
    defaultLighting.lightDirection[1] = -1.0f;
    defaultLighting.lightDirection[2] = -0.3f;
    defaultLighting.lightColor[0] = 1.0f;
    defaultLighting.lightColor[1] = 1.0f;
    defaultLighting.lightColor[2] = 1.0f;
    defaultLighting.lightIntensity = 3.0f;
    defaultLighting.ambientColor[0] = 0.1f;
    defaultLighting.ambientColor[1] = 0.1f;
    defaultLighting.ambientColor[2] = 0.1f;
    memcpy(pipeline->lightingBufferMapped, &defaultLighting, sizeof(PBRLightingData));
    
    pipeline->initialized = true;
    CARDINAL_LOG_INFO("PBR pipeline created successfully");
    return true;
}

void vk_pbr_pipeline_destroy(VulkanPBRPipeline* pipeline, VkDevice device) {
    if (!pipeline->initialized) return;
    
    // Destroy textures
    if (pipeline->textureImages) {
        for (uint32_t i = 0; i < pipeline->textureCount; i++) {
            vkDestroyImageView(device, pipeline->textureImageViews[i], NULL);
            vkDestroyImage(device, pipeline->textureImages[i], NULL);
            vkFreeMemory(device, pipeline->textureImageMemories[i], NULL);
        }
        free(pipeline->textureImages);
        free(pipeline->textureImageMemories);
        free(pipeline->textureImageViews);
    }
    
    if (pipeline->textureSampler != VK_NULL_HANDLE) {
        vkDestroySampler(device, pipeline->textureSampler, NULL);
    }
    
    // Destroy vertex and index buffers
    if (pipeline->vertexBuffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(device, pipeline->vertexBuffer, NULL);
        vkFreeMemory(device, pipeline->vertexBufferMemory, NULL);
    }
    
    if (pipeline->indexBuffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(device, pipeline->indexBuffer, NULL);
        vkFreeMemory(device, pipeline->indexBufferMemory, NULL);
    }
    
    // Destroy uniform buffers
    if (pipeline->uniformBuffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(device, pipeline->uniformBuffer, NULL);
        vkFreeMemory(device, pipeline->uniformBufferMemory, NULL);
    }
    
    if (pipeline->materialBuffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(device, pipeline->materialBuffer, NULL);
        vkFreeMemory(device, pipeline->materialBufferMemory, NULL);
    }
    
    if (pipeline->lightingBuffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(device, pipeline->lightingBuffer, NULL);
        vkFreeMemory(device, pipeline->lightingBufferMemory, NULL);
    }
    
    // Free descriptor sets explicitly before destroying pool
    if (pipeline->descriptorSets && pipeline->descriptorPool != VK_NULL_HANDLE) {
        vkFreeDescriptorSets(device, pipeline->descriptorPool, pipeline->descriptorSetCount, pipeline->descriptorSets);
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
    
    memset(pipeline, 0, sizeof(VulkanPBRPipeline));
    CARDINAL_LOG_INFO("PBR pipeline destroyed");
}

void vk_pbr_update_uniforms(VulkanPBRPipeline* pipeline, const PBRUniformBufferObject* ubo,
                            const PBRLightingData* lighting) {
    if (!pipeline->initialized) return;
    
    // Update UBO
    memcpy(pipeline->uniformBufferMapped, ubo, sizeof(PBRUniformBufferObject));
    
    // Update lighting data
    memcpy(pipeline->lightingBufferMapped, lighting, sizeof(PBRLightingData));
}

void vk_pbr_render(VulkanPBRPipeline* pipeline, VkCommandBuffer commandBuffer, const CardinalScene* scene) {
    if (!pipeline->initialized || !scene) return;
    
    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline->pipeline);
    
    VkBuffer vertexBuffers[] = {pipeline->vertexBuffer};
    VkDeviceSize offsets[] = {0};
    vkCmdBindVertexBuffers(commandBuffer, 0, 1, vertexBuffers, offsets);
    vkCmdBindIndexBuffer(commandBuffer, pipeline->indexBuffer, 0, VK_INDEX_TYPE_UINT32);
    
    // Bind a single descriptor set (currently we allocate one set shared for all materials)
    if (pipeline->descriptorSetCount > 0) {
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                pipeline->pipelineLayout, 0, 1,
                                &pipeline->descriptorSets[0], 0, NULL);
    }
    
    // Render each mesh
    uint32_t indexOffset = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* mesh = &scene->meshes[i];
        
        // Update material properties for this mesh
        if (mesh->material_index < scene->material_count) {
            const CardinalMaterial* material = &scene->materials[mesh->material_index];
            
            PBRMaterialProperties matProps = (PBRMaterialProperties){0};
            memcpy(matProps.albedoFactor, material->albedo_factor, sizeof(float) * 3);
            matProps.metallicFactor = material->metallic_factor;
            matProps.roughnessFactor = material->roughness_factor;
            memcpy(matProps.emissiveFactor, material->emissive_factor, sizeof(float) * 3);
            matProps.normalScale = material->normal_scale;
            matProps.aoStrength = material->ao_strength;
            
            memcpy(pipeline->materialBufferMapped, &matProps, sizeof(PBRMaterialProperties));
        }
        
        // Draw the mesh
        vkCmdDrawIndexed(commandBuffer, mesh->index_count, 1, indexOffset, 0, 0);
        indexOffset += mesh->index_count;
    }
}

bool vk_pbr_load_scene(VulkanPBRPipeline* pipeline, VkDevice device, VkPhysicalDevice physicalDevice,
                       VkCommandPool commandPool, VkQueue graphicsQueue, const CardinalScene* scene) {
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
    
    CARDINAL_LOG_INFO("Loading PBR scene: %u meshes, %u vertices, %u indices", 
                     scene->mesh_count, totalVertices, totalIndices);
    
    // Clean up previous buffers if they exist
    if (pipeline->vertexBuffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(device, pipeline->vertexBuffer, NULL);
        vkFreeMemory(device, pipeline->vertexBufferMemory, NULL);
        pipeline->vertexBuffer = VK_NULL_HANDLE;
        pipeline->vertexBufferMemory = VK_NULL_HANDLE;
    }
    
    if (pipeline->indexBuffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(device, pipeline->indexBuffer, NULL);
        vkFreeMemory(device, pipeline->indexBufferMemory, NULL);
        pipeline->indexBuffer = VK_NULL_HANDLE;
        pipeline->indexBufferMemory = VK_NULL_HANDLE;
    }
    
    // Create vertex buffer
    VkDeviceSize vertexBufferSize = totalVertices * sizeof(CardinalVertex);
    if (!createBuffer(device, physicalDevice, vertexBufferSize,
                     VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &pipeline->vertexBuffer, &pipeline->vertexBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create PBR vertex buffer");
        return false;
    }
    
    // Map and upload vertex data
    void* vertexData;
    if (vkMapMemory(device, pipeline->vertexBufferMemory, 0, vertexBufferSize, 0, &vertexData) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map vertex buffer memory");
        return false;
    }
    
    CardinalVertex* mappedVertices = (CardinalVertex*)vertexData;
    uint32_t vertexOffset = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* mesh = &scene->meshes[i];
        memcpy(&mappedVertices[vertexOffset], mesh->vertices, mesh->vertex_count * sizeof(CardinalVertex));
        vertexOffset += mesh->vertex_count;
    }
    vkUnmapMemory(device, pipeline->vertexBufferMemory);
    
    // Create index buffer if we have indices
    if (totalIndices > 0) {
        VkDeviceSize indexBufferSize = totalIndices * sizeof(uint32_t);
        if (!createBuffer(device, physicalDevice, indexBufferSize,
                         VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &pipeline->indexBuffer, &pipeline->indexBufferMemory)) {
            CARDINAL_LOG_ERROR("Failed to create PBR index buffer");
            return false;
        }
        
        void* indexData;
        if (vkMapMemory(device, pipeline->indexBufferMemory, 0, indexBufferSize, 0, &indexData) != VK_SUCCESS) {
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
    
    // Create default white texture for now (1x1 white pixel)
    if (pipeline->textureCount == 0) {
        pipeline->textureCount = 1;
        pipeline->textureImages = (VkImage*)malloc(sizeof(VkImage));
        pipeline->textureImageMemories = (VkDeviceMemory*)malloc(sizeof(VkDeviceMemory));
        pipeline->textureImageViews = (VkImageView*)malloc(sizeof(VkImageView));
        
        // Create 1x1 white texture as placeholder
        if (!createPlaceholderTexture(device, physicalDevice, commandPool, graphicsQueue,
                                     &pipeline->textureImages[0], &pipeline->textureImageMemories[0],
                                     &pipeline->textureImageViews[0], &pipeline->textureSampler)) {
            CARDINAL_LOG_ERROR("Failed to create placeholder texture");
        }
    }
    
    // Create descriptor pool and sets
    VkDescriptorPoolSize poolSizes[3] = {0};
    poolSizes[0].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    poolSizes[0].descriptorCount = 2; // UBO + Material
    poolSizes[1].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSizes[1].descriptorCount = 5; // 5 textures
    poolSizes[2].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    poolSizes[2].descriptorCount = 1; // Lighting
    
    VkDescriptorPoolCreateInfo poolInfo = {0};
    poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    poolInfo.poolSizeCount = 3;
    poolInfo.pPoolSizes = poolSizes;
    poolInfo.maxSets = 1; // One descriptor set for now
    
    if (vkCreateDescriptorPool(device, &poolInfo, NULL, &pipeline->descriptorPool) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor pool");
        return false;
    }
    
    // Allocate descriptor set
    pipeline->descriptorSetCount = 1;
    pipeline->descriptorSets = (VkDescriptorSet*)malloc(sizeof(VkDescriptorSet));
    
    VkDescriptorSetAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool = pipeline->descriptorPool;
    allocInfo.descriptorSetCount = 1;
    allocInfo.pSetLayouts = &pipeline->descriptorSetLayout;
    
    if (vkAllocateDescriptorSets(device, &allocInfo, pipeline->descriptorSets) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate descriptor sets");
        return false;
    }
    
    // Update descriptor sets with uniform buffers and textures
    VkWriteDescriptorSet descriptorWrites[8] = {0};
    
    VkDescriptorBufferInfo bufferInfo = {0};
    bufferInfo.buffer = pipeline->uniformBuffer;
    bufferInfo.offset = 0;
    bufferInfo.range = sizeof(PBRUniformBufferObject);
    
    descriptorWrites[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[0].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[0].dstBinding = 0;
    descriptorWrites[0].dstArrayElement = 0;
    descriptorWrites[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[0].descriptorCount = 1;
    descriptorWrites[0].pBufferInfo = &bufferInfo;
    
    // 5 combined image samplers at bindings 1..5
    VkDescriptorImageInfo imgInfo = {0};
    imgInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    imgInfo.imageView = pipeline->textureImageViews[0];
    imgInfo.sampler = pipeline->textureSampler;
    
    for (uint32_t b = 1; b <= 5; ++b) {
        descriptorWrites[b].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        descriptorWrites[b].dstSet = pipeline->descriptorSets[0];
        descriptorWrites[b].dstBinding = b;
        descriptorWrites[b].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        descriptorWrites[b].descriptorCount = 1;
        descriptorWrites[b].pImageInfo = &imgInfo;
    }
    
    VkDescriptorBufferInfo materialBufferInfo = {0};
    materialBufferInfo.buffer = pipeline->materialBuffer;
    materialBufferInfo.offset = 0;
    materialBufferInfo.range = sizeof(PBRMaterialProperties);
    
    descriptorWrites[6].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[6].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[6].dstBinding = 6;
    descriptorWrites[6].dstArrayElement = 0;
    descriptorWrites[6].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[6].descriptorCount = 1;
    descriptorWrites[6].pBufferInfo = &materialBufferInfo;
    
    VkDescriptorBufferInfo lightingBufferInfo = {0};
    lightingBufferInfo.buffer = pipeline->lightingBuffer;
    lightingBufferInfo.offset = 0;
    lightingBufferInfo.range = sizeof(PBRLightingData);
    
    descriptorWrites[7].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[7].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[7].dstBinding = 7;
    descriptorWrites[7].dstArrayElement = 0;
    descriptorWrites[7].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[7].descriptorCount = 1;
    descriptorWrites[7].pBufferInfo = &lightingBufferInfo;
    
    vkUpdateDescriptorSets(device, 8, descriptorWrites, 0, NULL);
    
    CARDINAL_LOG_INFO("PBR scene loaded successfully");
    return true;
}
