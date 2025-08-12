#include <stdlib.h>
#include <vulkan/vulkan.h>
#include <string.h>
#include <stdio.h>
#include "vulkan_state.h"
#include "vulkan_pipeline.h"
#include "cardinal/core/log.h"

/**
 * @brief Reads a SPIR-V shader file into memory.
 *
 * @param path Path to the SPIR-V file.
 * @param out_data Pointer to store the loaded data.
 * @param out_size Pointer to store the data size.
 * @return true if successful, false otherwise.
 *
 * @todo Implement shader caching to avoid repeated file reads.
 * @todo Add support for compressed shader files.
 */
static bool read_spv_file(const char* path, uint8_t** out_data, size_t* out_size) {
    FILE* f = fopen(path, "rb");
    if (!f) { LOG_ERROR("pipeline: failed to open SPV file"); return false; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    if (sz <= 0) { fclose(f); LOG_ERROR("pipeline: SPV file size invalid"); return false; }
    fseek(f, 0, SEEK_SET);
    uint8_t* data = (uint8_t*)malloc((size_t)sz);
    if (!data) { fclose(f); LOG_ERROR("pipeline: SPV malloc failed"); return false; }
    size_t rd = fread(data, 1, (size_t)sz, f);
    fclose(f);
    if (rd != (size_t)sz) { free(data); LOG_ERROR("pipeline: SPV read failed"); return false; }
    *out_data = data;
    *out_size = (size_t)sz;
    return true;
}

/**
 * @brief Creates depth resources for the Vulkan state.
 *
 * @param s Pointer to the VulkanState structure.
 * @return true if successful, false otherwise.
 *
 * @todo Support configurable depth formats and multisampling.
 * @todo Integrate with Vulkan dynamic rendering extensions.
 */
static bool create_depth_resources(VulkanState* s) {
    // Find a suitable depth format
    VkFormat candidates[] = {VK_FORMAT_D32_SFLOAT, VK_FORMAT_D32_SFLOAT_S8_UINT, VK_FORMAT_D24_UNORM_S8_UINT};
    s->depth_format = VK_FORMAT_UNDEFINED;
    
    for (int i = 0; i < 3; i++) {
        VkFormatProperties props;
        vkGetPhysicalDeviceFormatProperties(s->physical_device, candidates[i], &props);
        if (props.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) {
            s->depth_format = candidates[i];
            break;
        }
    }
    
    if (s->depth_format == VK_FORMAT_UNDEFINED) {
        LOG_ERROR("pipeline: failed to find suitable depth format");
        return false;
    }
    
    // Create depth image
    VkImageCreateInfo imageInfo = {0};
    imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = s->swapchain_extent.width;
    imageInfo.extent.height = s->swapchain_extent.height;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = s->depth_format;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    
    if (vkCreateImage(s->device, &imageInfo, NULL, &s->depth_image) != VK_SUCCESS) {
        LOG_ERROR("pipeline: failed to create depth image");
        return false;
    }
    
    // Allocate memory for depth image
    VkMemoryRequirements memRequirements;
    vkGetImageMemoryRequirements(s->device, s->depth_image, &memRequirements);
    
    VkPhysicalDeviceMemoryProperties memProperties;
    vkGetPhysicalDeviceMemoryProperties(s->physical_device, &memProperties);
    
    uint32_t memoryTypeIndex = UINT32_MAX;
    for (uint32_t i = 0; i < memProperties.memoryTypeCount; i++) {
        if ((memRequirements.memoryTypeBits & (1 << i)) &&
            (memProperties.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
            memoryTypeIndex = i;
            break;
        }
    }
    
    if (memoryTypeIndex == UINT32_MAX) {
        LOG_ERROR("pipeline: failed to find suitable memory type for depth image");
        return false;
    }
    
    VkMemoryAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocInfo.allocationSize = memRequirements.size;
    allocInfo.memoryTypeIndex = memoryTypeIndex;
    
    if (vkAllocateMemory(s->device, &allocInfo, NULL, &s->depth_image_memory) != VK_SUCCESS) {
        LOG_ERROR("pipeline: failed to allocate depth image memory");
        return false;
    }
    
    vkBindImageMemory(s->device, s->depth_image, s->depth_image_memory, 0);
    
    // Create depth image view
    VkImageViewCreateInfo viewInfo = {0};
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = s->depth_image;
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = s->depth_format;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;
    
    if (vkCreateImageView(s->device, &viewInfo, NULL, &s->depth_image_view) != VK_SUCCESS) {
        LOG_ERROR("pipeline: failed to create depth image view");
        return false;
    }
    
    LOG_INFO("pipeline: depth resources created");
    return true;
}

/**
 * @brief Destroys depth resources associated with the Vulkan state.
 *
 * @param s Pointer to the VulkanState structure.
 *
 * @todo Add checks for valid resource handles before destruction.
 */
static void destroy_depth_resources(VulkanState* s) {
    if (s->depth_image_view) {
        vkDestroyImageView(s->device, s->depth_image_view, NULL);
        s->depth_image_view = VK_NULL_HANDLE;
    }
    if (s->depth_image) {
        vkDestroyImage(s->device, s->depth_image, NULL);
        s->depth_image = VK_NULL_HANDLE;
    }
    if (s->depth_image_memory) {
        vkFreeMemory(s->device, s->depth_image_memory, NULL);
        s->depth_image_memory = VK_NULL_HANDLE;
    }
}

/**
 * @brief Creates the render pass and graphics pipeline for the Vulkan state.
 *
 * @param s Pointer to the VulkanState structure.
 * @return true if successful, false otherwise.
 *
 * @todo Support multiple render passes for advanced rendering techniques.
 * @todo Implement pipeline caching for faster recreation.
 */
bool vk_create_renderpass_pipeline(VulkanState* s) {
    LOG_INFO("pipeline: create depth resources");
    if (!create_depth_resources(s)) {
        return false;
    }
    
    LOG_INFO("pipeline: create render pass");
    VkAttachmentDescription attachments[2] = {0};
    
    // Color attachment
    attachments[0].format = s->swapchain_format;
    attachments[0].samples = VK_SAMPLE_COUNT_1_BIT;
    attachments[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachments[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachments[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachments[0].finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    // Depth attachment
    attachments[1].format = s->depth_format;
    attachments[1].samples = VK_SAMPLE_COUNT_1_BIT;
    attachments[1].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachments[1].storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachments[1].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachments[1].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachments[1].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachments[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    VkAttachmentReference color_ref = {0};
    color_ref.attachment = 0;
    color_ref.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    
    VkAttachmentReference depth_ref = {0};
    depth_ref.attachment = 1;
    depth_ref.layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass = {0};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &color_ref;
    subpass.pDepthStencilAttachment = &depth_ref;

    VkRenderPassCreateInfo rpci = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rpci.attachmentCount = 2;
    rpci.pAttachments = attachments;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &subpass;

    if (vkCreateRenderPass(s->device, &rpci, NULL, &s->render_pass) != VK_SUCCESS) { 
        LOG_ERROR("pipeline: vkCreateRenderPass failed"); 
        return false; 
    }
    LOG_INFO("pipeline: render pass created");

    // Create shaders from SPIR-V files
    uint8_t* vs_data = NULL; size_t vs_size = 0;
    if (!read_spv_file("assets/shaders/simple.vert.spv", &vs_data, &vs_size)) { 
        LOG_ERROR("pipeline: read simple.vert.spv failed"); 
        return false; 
    }
    VkShaderModuleCreateInfo vs_ci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    vs_ci.codeSize = vs_size;
    vs_ci.pCode = (const uint32_t*)vs_data;
    VkShaderModule vs_module;
    if (vkCreateShaderModule(s->device, &vs_ci, NULL, &vs_module) != VK_SUCCESS) { 
        LOG_ERROR("pipeline: vkCreateShaderModule vs failed"); 
        free(vs_data); 
        return false; 
    }
    LOG_INFO("pipeline: vertex shader module created");

    uint8_t* fs_data = NULL; size_t fs_size = 0;
    if (!read_spv_file("assets/shaders/simple.frag.spv", &fs_data, &fs_size)) { 
        LOG_ERROR("pipeline: read simple.frag.spv failed"); 
        vkDestroyShaderModule(s->device, vs_module, NULL); 
        free(vs_data); 
        return false; 
    }
    VkShaderModuleCreateInfo fs_ci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    fs_ci.codeSize = fs_size;
    fs_ci.pCode = (const uint32_t*)fs_data;
    VkShaderModule fs_module;
    if (vkCreateShaderModule(s->device, &fs_ci, NULL, &fs_module) != VK_SUCCESS) { 
        LOG_ERROR("pipeline: vkCreateShaderModule fs failed"); 
        vkDestroyShaderModule(s->device, vs_module, NULL); 
        free(vs_data); 
        free(fs_data); 
        return false; 
    }
    LOG_INFO("pipeline: fragment shader module created");

    // Pipeline layout
    VkPipelineLayoutCreateInfo pl_ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    if (vkCreatePipelineLayout(s->device, &pl_ci, NULL, &s->pipeline_layout) != VK_SUCCESS) { 
        LOG_ERROR("pipeline: vkCreatePipelineLayout failed"); 
        vkDestroyShaderModule(s->device, vs_module, NULL); 
        vkDestroyShaderModule(s->device, fs_module, NULL); 
        free(vs_data); 
        free(fs_data); 
        return false; 
    }
    LOG_INFO("pipeline: layout created");

    // Vertex input: none (using gl_VertexIndex in shader)
    VkPipelineVertexInputStateCreateInfo vi_ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    vi_ci.vertexBindingDescriptionCount = 0;
    vi_ci.pVertexBindingDescriptions = NULL;
    vi_ci.vertexAttributeDescriptionCount = 0;
    vi_ci.pVertexAttributeDescriptions = NULL;

    VkPipelineInputAssemblyStateCreateInfo ia_ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    ia_ci.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    VkViewport viewport = {0};
    viewport.width = (float)s->swapchain_extent.width;
    viewport.height = (float)s->swapchain_extent.height;
    viewport.maxDepth = 1.0f;

    VkRect2D scissor = {0};
    scissor.extent = s->swapchain_extent;

    VkPipelineViewportStateCreateInfo vp_ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
    vp_ci.viewportCount = 1;
    vp_ci.pViewports = &viewport;
    vp_ci.scissorCount = 1;
    vp_ci.pScissors = &scissor;

    VkPipelineRasterizationStateCreateInfo rs_ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    rs_ci.polygonMode = VK_POLYGON_MODE_FILL;
    rs_ci.cullMode = VK_CULL_MODE_NONE; // TODO: Temporarily disable culling, activate once we render.
    rs_ci.frontFace = VK_FRONT_FACE_CLOCKWISE;
    rs_ci.lineWidth = 1.0f;

    VkPipelineMultisampleStateCreateInfo ms_ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    ms_ci.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    VkPipelineColorBlendAttachmentState cb_attachment = {0};
    cb_attachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

    VkPipelineColorBlendStateCreateInfo cb_ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
    cb_ci.attachmentCount = 1;
    cb_ci.pAttachments = &cb_attachment;

    // Depth-stencil (required because subpass uses a depth attachment)
    VkPipelineDepthStencilStateCreateInfo ds_ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
    ds_ci.depthTestEnable = VK_TRUE;
    ds_ci.depthWriteEnable = VK_TRUE;
    ds_ci.depthCompareOp = VK_COMPARE_OP_LESS;
    ds_ci.depthBoundsTestEnable = VK_FALSE;
    ds_ci.stencilTestEnable = VK_FALSE;

    // Dynamic state (to match command buffer expectations)
    VkDynamicState dynamicStates[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamicState = {0};
    dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicState.dynamicStateCount = 2;
    dynamicState.pDynamicStates = dynamicStates;

    VkPipelineShaderStageCreateInfo stages[2] = {0};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vs_module;
    stages[0].pName = "main";

    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fs_module;
    stages[1].pName = "main";

    VkGraphicsPipelineCreateInfo pipeline_ci = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    pipeline_ci.stageCount = 2;
    pipeline_ci.pStages = stages;
    pipeline_ci.pVertexInputState = &vi_ci;
    pipeline_ci.pInputAssemblyState = &ia_ci;
    pipeline_ci.pViewportState = &vp_ci;
    pipeline_ci.pRasterizationState = &rs_ci;
    pipeline_ci.pMultisampleState = &ms_ci;
    pipeline_ci.pDepthStencilState = &ds_ci;
    pipeline_ci.pColorBlendState = &cb_ci;
    pipeline_ci.pDynamicState = &dynamicState;
    pipeline_ci.layout = s->pipeline_layout;
    pipeline_ci.renderPass = s->render_pass;
    pipeline_ci.subpass = 0;

    LOG_INFO("pipeline: calling vkCreateGraphicsPipelines");
    if (vkCreateGraphicsPipelines(s->device, VK_NULL_HANDLE, 1, &pipeline_ci, NULL, &s->pipeline) != VK_SUCCESS) { 
        LOG_ERROR("pipeline: vkCreateGraphicsPipelines failed"); 
        vkDestroyShaderModule(s->device, vs_module, NULL); 
        vkDestroyShaderModule(s->device, fs_module, NULL); 
        free(vs_data); 
        free(fs_data); 
        return false; 
    }
    LOG_INFO("pipeline: graphics pipeline created");

    vkDestroyShaderModule(s->device, vs_module, NULL);
    vkDestroyShaderModule(s->device, fs_module, NULL);
    free(vs_data);
    free(fs_data);

    // Framebuffers
    LOG_INFO("pipeline: creating framebuffers");
    s->framebuffers = (VkFramebuffer*)malloc(sizeof(VkFramebuffer)*s->swapchain_image_count);
    for (uint32_t i=0;i<s->swapchain_image_count;i++) {
        VkImageView attachments[] = { s->swapchain_image_views[i], s->depth_image_view };
        VkFramebufferCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        fci.renderPass = s->render_pass;
        fci.attachmentCount = 2;
        fci.pAttachments = attachments;
        fci.width = s->swapchain_extent.width;
        fci.height = s->swapchain_extent.height;
        fci.layers = 1;
        if (vkCreateFramebuffer(s->device, &fci, NULL, &s->framebuffers[i]) != VK_SUCCESS) { 
            LOG_ERROR("pipeline: vkCreateFramebuffer failed"); 
            return false; 
        }
    }
    LOG_INFO("pipeline: framebuffers created");

    return true;
}

/**
 * @brief Destroys the render pass and graphics pipeline.
 *
 * @param s Pointer to the VulkanState structure.
 *
 * @todo Ensure thread-safe destruction of resources.
 * @todo Add logging for destruction events.
 */
void vk_destroy_renderpass_pipeline(VulkanState* s) {
    if (!s) return;
    if (s->framebuffers) {
        for (uint32_t i=0;i<s->swapchain_image_count;i++) {
            vkDestroyFramebuffer(s->device, s->framebuffers[i], NULL);
        }
        free(s->framebuffers);
        s->framebuffers = NULL;
    }
    if (s->pipeline) { vkDestroyPipeline(s->device, s->pipeline, NULL); s->pipeline = VK_NULL_HANDLE; }
    if (s->pipeline_layout) { vkDestroyPipelineLayout(s->device, s->pipeline_layout, NULL); s->pipeline_layout = VK_NULL_HANDLE; }
    if (s->render_pass) { vkDestroyRenderPass(s->device, s->render_pass, NULL); s->render_pass = VK_NULL_HANDLE; }
    destroy_depth_resources(s);
}
