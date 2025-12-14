/**
 * @file vulkan_pipeline_manager.c
 * @brief Vulkan pipeline management implementation
 *
 * This module provides a unified implementation for managing all types of Vulkan pipelines
 * including graphics pipelines, compute pipelines, and specialized rendering pipelines.
 */

#include "vulkan_pipeline_manager.h"
#include "cardinal/core/log.h"
#include "cardinal/renderer/util/vulkan_shader_utils.h"
#include "cardinal/renderer/vulkan_commands.h"
#include "cardinal/renderer/vulkan_compute.h"
#include "cardinal/renderer/vulkan_mesh_shader.h"
#include "cardinal/renderer/vulkan_pbr.h"
#include "cardinal/renderer/vulkan_pipeline.h"
#include "cardinal/renderer/vulkan_swapchain.h"
#include "vulkan_simple_pipelines.h"
#include "vulkan_state.h"
#include <stdlib.h>
#include <string.h>

// Internal helper functions
static bool create_pipeline_cache(VulkanPipelineManager* manager);
static void destroy_pipeline_cache(VulkanPipelineManager* manager);
static bool add_pipeline_to_manager(VulkanPipelineManager* manager, const VulkanPipelineInfo* info);
static void remove_pipeline_from_manager(VulkanPipelineManager* manager, VulkanPipelineType type);
static bool ensure_pipeline_capacity(VulkanPipelineManager* manager);
static bool ensure_shader_capacity(VulkanPipelineManager* manager);
static int find_shader_index(VulkanPipelineManager* manager, const char* shader_path);

// Core pipeline manager functions

bool vulkan_pipeline_manager_init(VulkanPipelineManager* manager, VulkanState* vulkan_state) {
    if (!manager || !vulkan_state) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Invalid parameters for initialization");
        return false;
    }

    memset(manager, 0, sizeof(VulkanPipelineManager));
    manager->vulkan_state = vulkan_state;

    // Initialize pipeline tracking
    manager->pipeline_capacity = 16;
    manager->pipelines = malloc(sizeof(VulkanPipelineInfo) * manager->pipeline_capacity);
    if (!manager->pipelines) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to allocate pipeline array");
        return false;
    }

    // Initialize shader cache
    manager->shader_module_capacity = 32;
    manager->shader_modules = malloc(sizeof(VkShaderModule) * manager->shader_module_capacity);
    manager->shader_paths = malloc(sizeof(char*) * manager->shader_module_capacity);
    if (!manager->shader_modules || !manager->shader_paths) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to allocate shader cache");
        free(manager->pipelines);
        free(manager->shader_modules);
        free(manager->shader_paths);
        return false;
    }

    // Create pipeline cache
    if (!create_pipeline_cache(manager)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to create pipeline cache");
        free(manager->pipelines);
        free(manager->shader_modules);
        free(manager->shader_paths);
        return false;
    }

    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] Initialized successfully");
    return true;
}

void vulkan_pipeline_manager_destroy(VulkanPipelineManager* manager) {
    if (!manager || !manager->vulkan_state) {
        return;
    }

    VulkanState* state = manager->vulkan_state;

    // Wait for device to be idle
    vkDeviceWaitIdle(state->context.device);

    // Destroy all managed pipelines
    for (uint32_t i = 0; i < manager->pipeline_count; i++) {
        VulkanPipelineInfo* info = &manager->pipelines[i];
        if (info->pipeline != VK_NULL_HANDLE) {
            vkDestroyPipeline(state->context.device, info->pipeline, NULL);
        }
        if (info->layout != VK_NULL_HANDLE) {
            vkDestroyPipelineLayout(state->context.device, info->layout, NULL);
        }
    }

    // Clear shader cache
    vulkan_pipeline_manager_clear_shader_cache(manager);

    // Destroy pipeline cache
    destroy_pipeline_cache(manager);

    // Free memory
    free(manager->pipelines);
    free(manager->shader_modules);
    free(manager->shader_paths);

    memset(manager, 0, sizeof(VulkanPipelineManager));
    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] Destroyed successfully");
}

bool vulkan_pipeline_manager_recreate_all(VulkanPipelineManager* manager, VkFormat new_color_format,
                                          VkFormat new_depth_format) {
    if (!manager || !manager->vulkan_state) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Invalid parameters for recreation");
        return false;
    }

    VulkanState* state = manager->vulkan_state;

    // Wait for device to be idle
    vkDeviceWaitIdle(state->context.device);

    // Mark all pipelines for recreation
    for (uint32_t i = 0; i < manager->pipeline_count; i++) {
        manager->pipelines[i].needs_recreation = true;
    }

    // Recreate specialized pipelines if they were enabled
    bool success = true;

    if (manager->pbr_pipeline_enabled) {
        vulkan_pipeline_manager_disable_pbr(manager);
        if (!vulkan_pipeline_manager_enable_pbr(manager, new_color_format, new_depth_format)) {
            CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to recreate PBR pipeline");
            success = false;
        }
    }

    if (manager->mesh_shader_pipeline_enabled && state->context.supports_mesh_shader) {
        // Create default mesh shader configuration
        MeshShaderPipelineConfig config = {.task_shader_path = "shaders/mesh_task.spv",
                                           .mesh_shader_path = "shaders/mesh.spv",
                                           .fragment_shader_path = "shaders/mesh_frag.spv",
                                           .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                                           .polygon_mode = VK_POLYGON_MODE_FILL,
                                           .cull_mode = VK_CULL_MODE_BACK_BIT,
                                           .front_face = VK_FRONT_FACE_COUNTER_CLOCKWISE,
                                           .depth_test_enable = true,
                                           .depth_write_enable = true,
                                           .depth_compare_op = VK_COMPARE_OP_LESS,
                                           .blend_enable = false,
                                           .max_vertices_per_meshlet = 64,
                                           .max_primitives_per_meshlet = 126};

        vulkan_pipeline_manager_disable_mesh_shader(manager);
        if (!vulkan_pipeline_manager_enable_mesh_shader(manager, &config, new_color_format,
                                                        new_depth_format)) {
            CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to recreate mesh shader pipeline");
            success = false;
        }
    }

    if (manager->simple_pipelines_enabled) {
        vulkan_pipeline_manager_destroy_simple_pipelines(manager);
        if (!vulkan_pipeline_manager_create_simple_pipelines(manager)) {
            CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to recreate simple pipelines");
            success = false;
        }
    }

    if (success) {
        CARDINAL_LOG_INFO("[PIPELINE_MANAGER] All pipelines recreated successfully");
    }

    return success;
}

// Graphics pipeline functions

bool vulkan_pipeline_manager_create_graphics(VulkanPipelineManager* manager,
                                             const VulkanGraphicsPipelineCreateInfo* create_info,
                                             VulkanPipelineInfo* pipeline_info) {
    if (!manager || !create_info || !pipeline_info || !manager->vulkan_state) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Invalid parameters for graphics pipeline creation");
        return false;
    }

    VulkanState* state = manager->vulkan_state;
    VkDevice device = state->context.device;

    // Load shaders
    VkShaderModule vert_shader = VK_NULL_HANDLE;
    VkShaderModule frag_shader = VK_NULL_HANDLE;
    VkShaderModule geom_shader = VK_NULL_HANDLE;

    if (!vulkan_pipeline_manager_load_shader(manager, create_info->vertex_shader_path,
                                             &vert_shader)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to load vertex shader: %s",
                           create_info->vertex_shader_path);
        return false;
    }

    if (!vulkan_pipeline_manager_load_shader(manager, create_info->fragment_shader_path,
                                             &frag_shader)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to load fragment shader: %s",
                           create_info->fragment_shader_path);
        return false;
    }

    if (create_info->geometry_shader_path) {
        if (!vulkan_pipeline_manager_load_shader(manager, create_info->geometry_shader_path,
                                                 &geom_shader)) {
            CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to load geometry shader: %s",
                               create_info->geometry_shader_path);
            return false;
        }
    }

    // Create shader stages
    VkPipelineShaderStageCreateInfo shader_stages[3];
    uint32_t stage_count = 0;

    shader_stages[stage_count++] = (VkPipelineShaderStageCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_VERTEX_BIT,
        .module = vert_shader,
        .pName = "main"};

    if (geom_shader != VK_NULL_HANDLE) {
        shader_stages[stage_count++] = (VkPipelineShaderStageCreateInfo){
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_GEOMETRY_BIT,
            .module = geom_shader,
            .pName = "main"};
    }

    shader_stages[stage_count++] = (VkPipelineShaderStageCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = frag_shader,
        .pName = "main"};

    // Create pipeline layout
    VkPipelineLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = create_info->descriptor_set_layout_count,
        .pSetLayouts = create_info->descriptor_set_layouts,
        .pushConstantRangeCount = create_info->push_constant_range_count,
        .pPushConstantRanges = create_info->push_constant_ranges};

    VkPipelineLayout pipeline_layout;
    VkResult result = vkCreatePipelineLayout(device, &layout_info, NULL, &pipeline_layout);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to create pipeline layout: %d", result);
        return false;
    }

    // Configure pipeline state
    VkPipelineVertexInputStateCreateInfo vertex_input = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 0,
        .vertexAttributeDescriptionCount = 0};

    VkPipelineInputAssemblyStateCreateInfo input_assembly = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = VK_FALSE};

    VkPipelineViewportStateCreateInfo viewport_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1};

    VkPipelineRasterizationStateCreateInfo rasterizer = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = VK_FALSE,
        .rasterizerDiscardEnable = VK_FALSE,
        .polygonMode = create_info->enable_wireframe ? VK_POLYGON_MODE_LINE : VK_POLYGON_MODE_FILL,
        .lineWidth = 1.0f,
        .cullMode = create_info->cull_mode,
        .frontFace = create_info->front_face,
        .depthBiasEnable = VK_FALSE};

    VkPipelineMultisampleStateCreateInfo multisampling = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = VK_FALSE,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};

    VkPipelineDepthStencilStateCreateInfo depth_stencil = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = create_info->enable_depth_test ? VK_TRUE : VK_FALSE,
        .depthWriteEnable = create_info->enable_depth_write ? VK_TRUE : VK_FALSE,
        .depthCompareOp = VK_COMPARE_OP_LESS,
        .depthBoundsTestEnable = VK_FALSE,
        .stencilTestEnable = VK_FALSE};

    VkPipelineColorBlendAttachmentState color_blend_attachment = {
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                          VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = VK_FALSE};

    VkPipelineColorBlendStateCreateInfo color_blending = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = VK_FALSE,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment};

    VkDynamicState dynamic_states[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2,
        .pDynamicStates = dynamic_states};

    // Create pipeline rendering info for dynamic rendering
    VkPipelineRenderingCreateInfo pipeline_rendering = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &create_info->color_format,
        .depthAttachmentFormat = create_info->depth_format};

    // Create graphics pipeline
    VkGraphicsPipelineCreateInfo pipeline_create_info = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &pipeline_rendering,
        .stageCount = stage_count,
        .pStages = shader_stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = pipeline_layout,
        .renderPass = VK_NULL_HANDLE,
        .subpass = 0,
        .basePipelineHandle = VK_NULL_HANDLE};

    VkPipeline pipeline;
    result = vkCreateGraphicsPipelines(device, manager->pipeline_cache, 1, &pipeline_create_info,
                                       NULL, &pipeline);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to create graphics pipeline: %d", result);
        vkDestroyPipelineLayout(device, pipeline_layout, NULL);
        return false;
    }

    // Fill pipeline info
    pipeline_info->pipeline = pipeline;
    pipeline_info->layout = pipeline_layout;
    pipeline_info->type = VULKAN_PIPELINE_TYPE_GRAPHICS;
    pipeline_info->is_active = true;
    pipeline_info->needs_recreation = false;

    // Add to manager
    if (!add_pipeline_to_manager(manager, pipeline_info)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to add pipeline to manager");
        vkDestroyPipeline(device, pipeline, NULL);
        vkDestroyPipelineLayout(device, pipeline_layout, NULL);
        return false;
    }

    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] Graphics pipeline created successfully");
    return true;
}

bool vulkan_pipeline_manager_create_compute(VulkanPipelineManager* manager,
                                            const VulkanComputePipelineCreateInfo* create_info,
                                            VulkanPipelineInfo* pipeline_info) {
    if (!manager || !create_info || !pipeline_info || !manager->vulkan_state) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Invalid parameters for compute pipeline creation");
        return false;
    }

    VulkanState* state = manager->vulkan_state;
    VkDevice device = state->context.device;

    // Load compute shader
    VkShaderModule compute_shader = VK_NULL_HANDLE;
    if (!vulkan_pipeline_manager_load_shader(manager, create_info->compute_shader_path,
                                             &compute_shader)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to load compute shader: %s",
                           create_info->compute_shader_path);
        return false;
    }

    // Create pipeline layout
    VkPipelineLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = create_info->descriptor_set_layout_count,
        .pSetLayouts = create_info->descriptor_set_layouts,
        .pushConstantRangeCount = create_info->push_constant_range_count,
        .pPushConstantRanges = create_info->push_constant_ranges};

    VkPipelineLayout pipeline_layout;
    VkResult result = vkCreatePipelineLayout(device, &layout_info, NULL, &pipeline_layout);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to create compute pipeline layout: %d",
                           result);
        return false;
    }

    // Create compute pipeline
    VkComputePipelineCreateInfo pipeline_create_info = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                  .stage = VK_SHADER_STAGE_COMPUTE_BIT,
                  .module = compute_shader,
                  .pName = "main"},
        .layout = pipeline_layout,
        .basePipelineHandle = VK_NULL_HANDLE
    };

    VkPipeline pipeline;
    result = vkCreateComputePipelines(device, manager->pipeline_cache, 1, &pipeline_create_info,
                                      NULL, &pipeline);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to create compute pipeline: %d", result);
        vkDestroyPipelineLayout(device, pipeline_layout, NULL);
        return false;
    }

    // Fill pipeline info
    pipeline_info->pipeline = pipeline;
    pipeline_info->layout = pipeline_layout;
    pipeline_info->type = VULKAN_PIPELINE_TYPE_COMPUTE;
    pipeline_info->is_active = true;
    pipeline_info->needs_recreation = false;

    // Add to manager
    if (!add_pipeline_to_manager(manager, pipeline_info)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to add compute pipeline to manager");
        vkDestroyPipeline(device, pipeline, NULL);
        vkDestroyPipelineLayout(device, pipeline_layout, NULL);
        return false;
    }

    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] Compute pipeline created successfully");
    return true;
}

// Specialized pipeline functions

bool vulkan_pipeline_manager_enable_pbr(VulkanPipelineManager* manager, VkFormat color_format,
                                        VkFormat depth_format) {
    if (!manager || !manager->vulkan_state) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Invalid parameters for PBR pipeline");
        return false;
    }

    if (manager->pbr_pipeline_enabled) {
        CARDINAL_LOG_WARN("[PIPELINE_MANAGER] PBR pipeline already enabled");
        return true;
    }

    VulkanState* state = manager->vulkan_state;

    // Create PBR pipeline using existing function
    if (!vk_pbr_pipeline_create(&state->pipelines.pbr_pipeline, state->context.device,
                                state->context.physical_device, color_format, depth_format,
                                state->commands.pools[0], state->context.graphics_queue,
                                &state->allocator, state)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to create PBR pipeline");
        return false;
    }

    manager->pbr_pipeline_enabled = true;
    state->pipelines.use_pbr_pipeline = true;

    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] PBR pipeline enabled successfully");
    return true;
}

void vulkan_pipeline_manager_disable_pbr(VulkanPipelineManager* manager) {
    if (!manager || !manager->vulkan_state || !manager->pbr_pipeline_enabled) {
        return;
    }

    VulkanState* state = manager->vulkan_state;

    // Wait for device to be idle
    vkDeviceWaitIdle(state->context.device);

    // Destroy PBR pipeline using existing function
    vk_pbr_pipeline_destroy(&state->pipelines.pbr_pipeline, state->context.device,
                            &state->allocator);

    manager->pbr_pipeline_enabled = false;
    state->pipelines.use_pbr_pipeline = false;

    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] PBR pipeline disabled");
}

bool vulkan_pipeline_manager_enable_mesh_shader(VulkanPipelineManager* manager,
                                                const MeshShaderPipelineConfig* config,
                                                VkFormat color_format, VkFormat depth_format) {
    if (!manager || !manager->vulkan_state || !config) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Invalid parameters for mesh shader pipeline");
        return false;
    }

    VulkanState* state = manager->vulkan_state;

    if (!state->context.supports_mesh_shader) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Mesh shader not supported on this device");
        return false;
    }

    if (manager->mesh_shader_pipeline_enabled) {
        CARDINAL_LOG_WARN("[PIPELINE_MANAGER] Mesh shader pipeline already enabled");
        return true;
    }

    // Create mesh shader pipeline using existing function
    if (!vk_mesh_shader_create_pipeline(state, config, color_format, depth_format,
                                        &state->pipelines.mesh_shader_pipeline)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to create mesh shader pipeline");
        return false;
    }

    manager->mesh_shader_pipeline_enabled = true;
    state->pipelines.use_mesh_shader_pipeline = true;

    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] Mesh shader pipeline enabled successfully");
    return true;
}

void vulkan_pipeline_manager_disable_mesh_shader(VulkanPipelineManager* manager) {
    if (!manager || !manager->vulkan_state || !manager->mesh_shader_pipeline_enabled) {
        return;
    }

    VulkanState* state = manager->vulkan_state;

    // Wait for device to be idle
    vkDeviceWaitIdle(state->context.device);

    // Destroy mesh shader pipeline using existing function
    vk_mesh_shader_destroy_pipeline(state, &state->pipelines.mesh_shader_pipeline);

    manager->mesh_shader_pipeline_enabled = false;
    state->pipelines.use_mesh_shader_pipeline = false;

    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] Mesh shader pipeline disabled");
}

bool vulkan_pipeline_manager_create_simple_pipelines(VulkanPipelineManager* manager) {
    if (!manager || !manager->vulkan_state) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Invalid parameters for simple pipelines");
        return false;
    }

    if (manager->simple_pipelines_enabled) {
        CARDINAL_LOG_WARN("[PIPELINE_MANAGER] Simple pipelines already enabled");
        return true;
    }

    VulkanState* state = manager->vulkan_state;

    // Create simple pipelines using existing function
    if (!vk_create_simple_pipelines(state)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to create simple pipelines");
        return false;
    }

    manager->simple_pipelines_enabled = true;

    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] Simple pipelines created successfully");
    return true;
}

void vulkan_pipeline_manager_destroy_simple_pipelines(VulkanPipelineManager* manager) {
    if (!manager || !manager->vulkan_state || !manager->simple_pipelines_enabled) {
        return;
    }

    VulkanState* state = manager->vulkan_state;

    // Destroy simple pipelines using existing function
    vk_destroy_simple_pipelines(state);

    manager->simple_pipelines_enabled = false;

    CARDINAL_LOG_INFO("[PIPELINE_MANAGER] Simple pipelines destroyed");
}

// Pipeline utility functions

VulkanPipelineInfo* vulkan_pipeline_manager_get_pipeline(VulkanPipelineManager* manager,
                                                         VulkanPipelineType type) {
    if (!manager) {
        return NULL;
    }

    for (uint32_t i = 0; i < manager->pipeline_count; i++) {
        if (manager->pipelines[i].type == type && manager->pipelines[i].is_active) {
            return &manager->pipelines[i];
        }
    }

    return NULL;
}

void vulkan_pipeline_manager_destroy_pipeline(VulkanPipelineManager* manager,
                                              VulkanPipelineType type) {
    if (!manager || !manager->vulkan_state) {
        return;
    }

    VulkanState* state = manager->vulkan_state;

    for (uint32_t i = 0; i < manager->pipeline_count; i++) {
        VulkanPipelineInfo* info = &manager->pipelines[i];
        if (info->type == type && info->is_active) {
            if (info->pipeline != VK_NULL_HANDLE) {
                vkDestroyPipeline(state->context.device, info->pipeline, NULL);
                info->pipeline = VK_NULL_HANDLE;
            }
            if (info->layout != VK_NULL_HANDLE) {
                vkDestroyPipelineLayout(state->context.device, info->layout, NULL);
                info->layout = VK_NULL_HANDLE;
            }
            info->is_active = false;
            break;
        }
    }

    remove_pipeline_from_manager(manager, type);
}

bool vulkan_pipeline_manager_is_supported(VulkanPipelineManager* manager, VulkanPipelineType type) {
    if (!manager || !manager->vulkan_state) {
        return false;
    }

    VulkanState* state = manager->vulkan_state;

    switch (type) {
        case VULKAN_PIPELINE_TYPE_MESH_SHADER:
            return state->context.supports_mesh_shader;
        case VULKAN_PIPELINE_TYPE_GRAPHICS:
        case VULKAN_PIPELINE_TYPE_COMPUTE:
        case VULKAN_PIPELINE_TYPE_PBR:
        case VULKAN_PIPELINE_TYPE_SIMPLE_UV:
        case VULKAN_PIPELINE_TYPE_SIMPLE_WIREFRAME:
            return true;
        default:
            return false;
    }
}

// Shader management functions

bool vulkan_pipeline_manager_load_shader(VulkanPipelineManager* manager, const char* shader_path,
                                         VkShaderModule* shader_module) {
    if (!manager || !shader_path || !shader_module || !manager->vulkan_state) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Invalid parameters for shader loading");
        return false;
    }

    // Check if shader is already cached
    VkShaderModule cached = vulkan_pipeline_manager_get_cached_shader(manager, shader_path);
    if (cached != VK_NULL_HANDLE) {
        *shader_module = cached;
        return true;
    }

    // Load shader using existing utility function
    if (!vk_shader_create_module(manager->vulkan_state->context.device, shader_path,
                                 shader_module)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to load shader: %s", shader_path);
        return false;
    }

    // Cache the shader
    if (!ensure_shader_capacity(manager)) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to expand shader cache");
        vkDestroyShaderModule(manager->vulkan_state->context.device, *shader_module, NULL);
        return false;
    }

    uint32_t index = manager->shader_module_count++;
    manager->shader_modules[index] = *shader_module;
    manager->shader_paths[index] = malloc(strlen(shader_path) + 1);
    if (manager->shader_paths[index]) {
        strcpy(manager->shader_paths[index], shader_path);
    }

    return true;
}

VkShaderModule vulkan_pipeline_manager_get_cached_shader(VulkanPipelineManager* manager,
                                                         const char* shader_path) {
    if (!manager || !shader_path) {
        return VK_NULL_HANDLE;
    }

    int index = find_shader_index(manager, shader_path);
    if (index >= 0) {
        return manager->shader_modules[index];
    }

    return VK_NULL_HANDLE;
}

void vulkan_pipeline_manager_clear_shader_cache(VulkanPipelineManager* manager) {
    if (!manager || !manager->vulkan_state) {
        return;
    }

    VkDevice device = manager->vulkan_state->context.device;

    for (uint32_t i = 0; i < manager->shader_module_count; i++) {
        if (manager->shader_modules[i] != VK_NULL_HANDLE) {
            vkDestroyShaderModule(device, manager->shader_modules[i], NULL);
        }
        free(manager->shader_paths[i]);
    }

    manager->shader_module_count = 0;
}

// Pipeline state queries

bool vulkan_pipeline_manager_is_pbr_enabled(VulkanPipelineManager* manager) {
    return manager ? manager->pbr_pipeline_enabled : false;
}

bool vulkan_pipeline_manager_is_mesh_shader_enabled(VulkanPipelineManager* manager) {
    return manager ? manager->mesh_shader_pipeline_enabled : false;
}

bool vulkan_pipeline_manager_is_simple_pipelines_enabled(VulkanPipelineManager* manager) {
    return manager ? manager->simple_pipelines_enabled : false;
}

// Internal helper functions

static bool create_pipeline_cache(VulkanPipelineManager* manager) {
    VkPipelineCacheCreateInfo cache_info = {.sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
                                            .initialDataSize = 0,
                                            .pInitialData = NULL};

    VkResult result = vkCreatePipelineCache(manager->vulkan_state->context.device, &cache_info,
                                            NULL, &manager->pipeline_cache);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to create pipeline cache: %d", result);
        return false;
    }

    return true;
}

static void destroy_pipeline_cache(VulkanPipelineManager* manager) {
    if (manager->pipeline_cache != VK_NULL_HANDLE) {
        vkDestroyPipelineCache(manager->vulkan_state->context.device, manager->pipeline_cache,
                               NULL);
        manager->pipeline_cache = VK_NULL_HANDLE;
    }
}

static bool add_pipeline_to_manager(VulkanPipelineManager* manager,
                                    const VulkanPipelineInfo* info) {
    if (!ensure_pipeline_capacity(manager)) {
        return false;
    }

    manager->pipelines[manager->pipeline_count++] = *info;
    return true;
}

static void remove_pipeline_from_manager(VulkanPipelineManager* manager, VulkanPipelineType type) {
    for (uint32_t i = 0; i < manager->pipeline_count; i++) {
        if (manager->pipelines[i].type == type) {
            // Move last element to this position
            if (i < manager->pipeline_count - 1) {
                manager->pipelines[i] = manager->pipelines[manager->pipeline_count - 1];
            }
            manager->pipeline_count--;
            break;
        }
    }
}

static bool ensure_pipeline_capacity(VulkanPipelineManager* manager) {
    if (manager->pipeline_count >= manager->pipeline_capacity) {
        uint32_t new_capacity = manager->pipeline_capacity * 2;
        VulkanPipelineInfo* new_pipelines =
            realloc(manager->pipelines, sizeof(VulkanPipelineInfo) * new_capacity);
        if (!new_pipelines) {
            CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to expand pipeline array");
            return false;
        }
        manager->pipelines = new_pipelines;
        manager->pipeline_capacity = new_capacity;
    }
    return true;
}

static bool ensure_shader_capacity(VulkanPipelineManager* manager) {
    if (manager->shader_module_count >= manager->shader_module_capacity) {
        uint32_t new_capacity = manager->shader_module_capacity * 2;
        VkShaderModule* new_modules =
            realloc(manager->shader_modules, sizeof(VkShaderModule) * new_capacity);
        char** new_paths = realloc(manager->shader_paths, sizeof(char*) * new_capacity);
        if (!new_modules || !new_paths) {
            CARDINAL_LOG_ERROR("[PIPELINE_MANAGER] Failed to expand shader cache");
            return false;
        }
        manager->shader_modules = new_modules;
        manager->shader_paths = new_paths;
        manager->shader_module_capacity = new_capacity;
    }
    return true;
}

static int find_shader_index(VulkanPipelineManager* manager, const char* shader_path) {
    for (uint32_t i = 0; i < manager->shader_module_count; i++) {
        if (manager->shader_paths[i] && strcmp(manager->shader_paths[i], shader_path) == 0) {
            return (int)i;
        }
    }
    return -1;
}
