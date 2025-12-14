#ifndef VULKAN_COMPUTE_H
#define VULKAN_COMPUTE_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct VulkanState VulkanState;

/**
 * @brief Configuration for creating a compute pipeline
 */
typedef struct ComputePipelineConfig {
  const char *compute_shader_path; /**< Path to compute shader SPIR-V file */
  uint32_t push_constant_size;     /**< Size of push constants in bytes */
  VkShaderStageFlags
      push_constant_stages;      /**< Shader stages that use push constants */
  uint32_t descriptor_set_count; /**< Number of descriptor sets */
  VkDescriptorSetLayout
      *descriptor_layouts; /**< Array of descriptor set layouts */
  uint32_t local_size_x;   /**< Local workgroup size X (for validation) */
  uint32_t local_size_y;   /**< Local workgroup size Y (for validation) */
  uint32_t local_size_z;   /**< Local workgroup size Z (for validation) */
} ComputePipelineConfig;

/**
 * @brief Compute pipeline object
 */
typedef struct ComputePipeline {
  VkPipeline pipeline;                       /**< Vulkan compute pipeline */
  VkPipelineLayout pipeline_layout;          /**< Pipeline layout */
  VkDescriptorSetLayout *descriptor_layouts; /**< Descriptor set layouts */
  uint32_t descriptor_set_count;             /**< Number of descriptor sets */
  uint32_t push_constant_size;               /**< Size of push constants */
  VkShaderStageFlags push_constant_stages;   /**< Push constant stages */
  uint32_t local_size_x;                     /**< Local workgroup size X */
  uint32_t local_size_y;                     /**< Local workgroup size Y */
  uint32_t local_size_z;                     /**< Local workgroup size Z */
  bool initialized; /**< Whether pipeline is initialized */
} ComputePipeline;

/**
 * @brief Compute dispatch parameters
 */
typedef struct ComputeDispatchInfo {
  uint32_t group_count_x;           /**< Number of workgroups in X dimension */
  uint32_t group_count_y;           /**< Number of workgroups in Y dimension */
  uint32_t group_count_z;           /**< Number of workgroups in Z dimension */
  VkDescriptorSet *descriptor_sets; /**< Array of descriptor sets to bind */
  uint32_t descriptor_set_count;    /**< Number of descriptor sets */
  const void *push_constants;       /**< Push constant data */
  uint32_t push_constant_size;      /**< Size of push constant data */
} ComputeDispatchInfo;

/**
 * @brief Memory barrier configuration for compute operations
 */
typedef struct ComputeMemoryBarrier {
  VkPipelineStageFlags src_stage_mask; /**< Source pipeline stage */
  VkPipelineStageFlags dst_stage_mask; /**< Destination pipeline stage */
  VkAccessFlags src_access_mask;       /**< Source access mask */
  VkAccessFlags dst_access_mask;       /**< Destination access mask */
} ComputeMemoryBarrier;

/**
 * @brief Initialize compute shader support
 * @param vulkan_state Vulkan state object
 * @return true if initialization successful, false otherwise
 */
bool vk_compute_init(VulkanState *vulkan_state);

/**
 * @brief Cleanup compute shader support
 * @param vulkan_state Vulkan state object
 */
void vk_compute_cleanup(VulkanState *vulkan_state);

/**
 * @brief Create a compute pipeline
 * @param vulkan_state Vulkan state object
 * @param config Pipeline configuration
 * @param pipeline Output pipeline object
 * @return true if creation successful, false otherwise
 */
bool vk_compute_create_pipeline(VulkanState *vulkan_state,
                                const ComputePipelineConfig *config,
                                ComputePipeline *pipeline);

/**
 * @brief Destroy a compute pipeline
 * @param vulkan_state Vulkan state object
 * @param pipeline Pipeline to destroy
 */
void vk_compute_destroy_pipeline(VulkanState *vulkan_state,
                                 ComputePipeline *pipeline);

/**
 * @brief Dispatch compute work
 * @param cmd_buffer Command buffer to record into
 * @param pipeline Compute pipeline to use
 * @param dispatch_info Dispatch parameters
 */
void vk_compute_dispatch(VkCommandBuffer cmd_buffer,
                         const ComputePipeline *pipeline,
                         const ComputeDispatchInfo *dispatch_info);

/**
 * @brief Insert memory barrier for compute operations
 * @param cmd_buffer Command buffer to record into
 * @param barrier Barrier configuration
 */
void vk_compute_memory_barrier(VkCommandBuffer cmd_buffer,
                               const ComputeMemoryBarrier *barrier);

/**
 * @brief Create a simple descriptor set layout for compute shaders
 * @param vulkan_state Vulkan state object
 * @param bindings Array of descriptor set layout bindings
 * @param binding_count Number of bindings
 * @param layout Output descriptor set layout
 * @return true if creation successful, false otherwise
 */
bool vk_compute_create_descriptor_layout(
    VulkanState *vulkan_state, const VkDescriptorSetLayoutBinding *bindings,
    uint32_t binding_count, VkDescriptorSetLayout *layout);

/**
 * @brief Helper function to calculate optimal workgroup dispatch counts
 * @param total_work_items Total number of work items
 * @param local_size Local workgroup size
 * @return Number of workgroups needed
 */
uint32_t vk_compute_calculate_workgroups(uint32_t total_work_items,
                                         uint32_t local_size);

/**
 * @brief Validate compute pipeline configuration
 * @param vulkan_state Vulkan state object
 * @param config Configuration to validate
 * @return true if configuration is valid, false otherwise
 */
bool vk_compute_validate_config(VulkanState *vulkan_state,
                                const ComputePipelineConfig *config);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_COMPUTE_H
