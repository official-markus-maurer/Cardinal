/**
 * @file vulkan_pipeline_manager.h
 * @brief Vulkan pipeline management interface
 *
 * This module provides a unified interface for managing all types of Vulkan
 * pipelines including graphics pipelines, compute pipelines, and specialized
 * rendering pipelines.
 */

#ifndef VULKAN_PIPELINE_MANAGER_H
#define VULKAN_PIPELINE_MANAGER_H

#include <stdbool.h>
#include <vulkan/vulkan.h>

// Forward declarations
typedef struct VulkanState VulkanState;
typedef struct VulkanPBRPipeline VulkanPBRPipeline;
typedef struct MeshShaderPipeline MeshShaderPipeline;
typedef struct MeshShaderPipelineConfig MeshShaderPipelineConfig;

/**
 * @brief Pipeline types supported by the manager
 */
typedef enum {
  VULKAN_PIPELINE_TYPE_GRAPHICS,
  VULKAN_PIPELINE_TYPE_COMPUTE,
  VULKAN_PIPELINE_TYPE_PBR,
  VULKAN_PIPELINE_TYPE_MESH_SHADER,
  VULKAN_PIPELINE_TYPE_SIMPLE_UV,
  VULKAN_PIPELINE_TYPE_SIMPLE_WIREFRAME
} VulkanPipelineType;

/**
 * @brief Pipeline state information
 */
typedef struct {
  VkPipeline pipeline;
  VkPipelineLayout layout;
  VulkanPipelineType type;
  bool is_active;
  bool needs_recreation;
} VulkanPipelineInfo;

/**
 * @brief Graphics pipeline creation parameters
 */
typedef struct {
  const char *vertex_shader_path;
  const char *fragment_shader_path;
  const char *geometry_shader_path; // Optional
  VkFormat color_format;
  VkFormat depth_format;
  bool enable_wireframe;
  bool enable_depth_test;
  bool enable_depth_write;
  VkCullModeFlags cull_mode;
  VkFrontFace front_face;
  uint32_t descriptor_set_layout_count;
  VkDescriptorSetLayout *descriptor_set_layouts;
  uint32_t push_constant_range_count;
  VkPushConstantRange *push_constant_ranges;
} VulkanGraphicsPipelineCreateInfo;

/**
 * @brief Compute pipeline creation parameters
 */
typedef struct {
  const char *compute_shader_path;
  uint32_t descriptor_set_layout_count;
  VkDescriptorSetLayout *descriptor_set_layouts;
  uint32_t push_constant_range_count;
  VkPushConstantRange *push_constant_ranges;
} VulkanComputePipelineCreateInfo;

/**
 * @brief Pipeline manager structure
 */
typedef struct {
  VulkanState *vulkan_state;

  // Pipeline tracking
  VulkanPipelineInfo *pipelines;
  uint32_t pipeline_count;
  uint32_t pipeline_capacity;

  // Specialized pipeline states
  bool pbr_pipeline_enabled;
  bool mesh_shader_pipeline_enabled;
  bool simple_pipelines_enabled;

  // Pipeline cache for faster recreation
  VkPipelineCache pipeline_cache;

  // Shader module cache
  VkShaderModule *shader_modules;
  char **shader_paths;
  uint32_t shader_module_count;
  uint32_t shader_module_capacity;
} VulkanPipelineManager;

// Core pipeline manager functions

/**
 * @brief Initialize the pipeline manager
 * @param manager Pipeline manager to initialize
 * @param vulkan_state Vulkan state
 * @return true on success, false on failure
 */
bool vulkan_pipeline_manager_init(VulkanPipelineManager *manager,
                                  VulkanState *vulkan_state);

/**
 * @brief Destroy the pipeline manager and all managed pipelines
 * @param manager Pipeline manager to destroy
 */
void vulkan_pipeline_manager_destroy(VulkanPipelineManager *manager);

/**
 * @brief Recreate all pipelines (e.g., after swapchain recreation)
 * @param manager Pipeline manager
 * @param new_color_format New color format
 * @param new_depth_format New depth format
 * @return true on success, false on failure
 */
bool vulkan_pipeline_manager_recreate_all(VulkanPipelineManager *manager,
                                          VkFormat new_color_format,
                                          VkFormat new_depth_format);

// Graphics pipeline functions

/**
 * @brief Create a graphics pipeline
 * @param manager Pipeline manager
 * @param create_info Pipeline creation parameters
 * @param pipeline_info Output pipeline information
 * @return true on success, false on failure
 */
bool vulkan_pipeline_manager_create_graphics(
    VulkanPipelineManager *manager,
    const VulkanGraphicsPipelineCreateInfo *create_info,
    VulkanPipelineInfo *pipeline_info);

/**
 * @brief Create a compute pipeline
 * @param manager Pipeline manager
 * @param create_info Pipeline creation parameters
 * @param pipeline_info Output pipeline information
 * @return true on success, false on failure
 */
bool vulkan_pipeline_manager_create_compute(
    VulkanPipelineManager *manager,
    const VulkanComputePipelineCreateInfo *create_info,
    VulkanPipelineInfo *pipeline_info);

// Specialized pipeline functions

/**
 * @brief Create and enable PBR pipeline
 * @param manager Pipeline manager
 * @param color_format Color format
 * @param depth_format Depth format
 * @return true on success, false on failure
 */
bool vulkan_pipeline_manager_enable_pbr(VulkanPipelineManager *manager,
                                        VkFormat color_format,
                                        VkFormat depth_format);

/**
 * @brief Disable and destroy PBR pipeline
 * @param manager Pipeline manager
 */
void vulkan_pipeline_manager_disable_pbr(VulkanPipelineManager *manager);

/**
 * @brief Create and enable mesh shader pipeline
 * @param manager Pipeline manager
 * @param config Mesh shader configuration
 * @param color_format Color format
 * @param depth_format Depth format
 * @return true on success, false on failure
 */
bool vulkan_pipeline_manager_enable_mesh_shader(
    VulkanPipelineManager *manager, const MeshShaderPipelineConfig *config,
    VkFormat color_format, VkFormat depth_format);

/**
 * @brief Disable and destroy mesh shader pipeline
 * @param manager Pipeline manager
 */
void vulkan_pipeline_manager_disable_mesh_shader(
    VulkanPipelineManager *manager);

/**
 * @brief Create simple pipelines (UV and wireframe)
 * @param manager Pipeline manager
 * @param color_format Color format
 * @param depth_format Depth format
 * @return true on success, false on failure
 */
bool vulkan_pipeline_manager_create_simple_pipelines(
    VulkanPipelineManager *manager);

/**
 * @brief Destroy simple pipelines
 * @param manager Pipeline manager
 */
void vulkan_pipeline_manager_destroy_simple_pipelines(
    VulkanPipelineManager *manager);

// Pipeline utility functions

/**
 * @brief Get pipeline by type
 * @param manager Pipeline manager
 * @param type Pipeline type
 * @return Pipeline info or NULL if not found
 */
VulkanPipelineInfo *
vulkan_pipeline_manager_get_pipeline(VulkanPipelineManager *manager,
                                     VulkanPipelineType type);

/**
 * @brief Destroy a specific pipeline
 * @param manager Pipeline manager
 * @param type Pipeline type to destroy
 */
void vulkan_pipeline_manager_destroy_pipeline(VulkanPipelineManager *manager,
                                              VulkanPipelineType type);

/**
 * @brief Check if a pipeline type is supported
 * @param manager Pipeline manager
 * @param type Pipeline type
 * @return true if supported, false otherwise
 */
bool vulkan_pipeline_manager_is_supported(VulkanPipelineManager *manager,
                                          VulkanPipelineType type);

// Shader management functions

/**
 * @brief Load and cache a shader module
 * @param manager Pipeline manager
 * @param shader_path Path to shader file
 * @param shader_module Output shader module
 * @return true on success, false on failure
 */
bool vulkan_pipeline_manager_load_shader(VulkanPipelineManager *manager,
                                         const char *shader_path,
                                         VkShaderModule *shader_module);

/**
 * @brief Get cached shader module
 * @param manager Pipeline manager
 * @param shader_path Path to shader file
 * @return Shader module or VK_NULL_HANDLE if not cached
 */
VkShaderModule
vulkan_pipeline_manager_get_cached_shader(VulkanPipelineManager *manager,
                                          const char *shader_path);

/**
 * @brief Clear shader cache
 * @param manager Pipeline manager
 */
void vulkan_pipeline_manager_clear_shader_cache(VulkanPipelineManager *manager);

// Pipeline state queries

/**
 * @brief Check if PBR pipeline is enabled
 * @param manager Pipeline manager
 * @return true if enabled, false otherwise
 */
bool vulkan_pipeline_manager_is_pbr_enabled(VulkanPipelineManager *manager);

/**
 * @brief Check if mesh shader pipeline is enabled
 * @param manager Pipeline manager
 * @return true if enabled, false otherwise
 */
bool vulkan_pipeline_manager_is_mesh_shader_enabled(
    VulkanPipelineManager *manager);

/**
 * @brief Check if simple pipelines are enabled
 * @param manager Pipeline manager
 * @return true if enabled, false otherwise
 */
bool vulkan_pipeline_manager_is_simple_pipelines_enabled(
    VulkanPipelineManager *manager);

#endif // VULKAN_PIPELINE_MANAGER_H
