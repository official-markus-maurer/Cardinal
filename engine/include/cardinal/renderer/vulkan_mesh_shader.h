/**
 * @file vulkan_mesh_shader.h
 * @brief Vulkan mesh shader pipeline management and GPU-driven rendering
 * support
 *
 * This module provides mesh shader pipeline creation, management, and
 * GPU-driven rendering capabilities using VK_EXT_mesh_shader extension.
 */

#ifndef CARDINAL_VULKAN_MESH_SHADER_H
#define CARDINAL_VULKAN_MESH_SHADER_H

#include "cardinal/assets/scene.h"
#include "vulkan_descriptor_manager.h"
#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct VulkanState VulkanState;
typedef struct CardinalScene CardinalScene;

/**
 * @brief Mesh shader pipeline configuration
 */
typedef struct MeshShaderPipelineConfig {
  const char *mesh_shader_path; /**< Path to mesh shader SPIR-V file */
  const char
      *task_shader_path; /**< Path to task shader SPIR-V file (optional) */
  const char *fragment_shader_path; /**< Path to fragment shader SPIR-V file */

  VkPrimitiveTopology topology; /**< Primitive topology for mesh output */
  VkPolygonMode polygon_mode;   /**< Polygon rendering mode */
  VkCullModeFlags cull_mode;    /**< Face culling mode */
  VkFrontFace front_face;       /**< Front face winding order */

  bool depth_test_enable;       /**< Enable depth testing */
  bool depth_write_enable;      /**< Enable depth writing */
  VkCompareOp depth_compare_op; /**< Depth comparison operation */

  bool blend_enable;                    /**< Enable color blending */
  VkBlendFactor src_color_blend_factor; /**< Source color blend factor */
  VkBlendFactor dst_color_blend_factor; /**< Destination color blend factor */
  VkBlendOp color_blend_op;             /**< Color blend operation */

  uint32_t max_vertices_per_meshlet;   /**< Maximum vertices per meshlet */
  uint32_t max_primitives_per_meshlet; /**< Maximum primitives per meshlet */
} MeshShaderPipelineConfig;

/**
 * @brief Mesh shader pipeline object
 */
typedef struct MeshShaderPipeline {
  VkPipeline pipeline;              /**< Vulkan pipeline object */
  VkPipelineLayout pipeline_layout; /**< Pipeline layout */

  // Descriptor management
  VulkanDescriptorManager
      *descriptor_manager; /**< Descriptor manager for this pipeline */

  bool has_task_shader;                /**< Whether pipeline uses task shader */
  uint32_t max_meshlets_per_workgroup; /**< Maximum meshlets per workgroup */
  uint32_t max_vertices_per_meshlet;   /**< Maximum vertices per meshlet */
  uint32_t max_primitives_per_meshlet; /**< Maximum primitives per meshlet */
} MeshShaderPipeline;

/**
 * @brief GPU-driven rendering data structures
 */
typedef struct GpuMeshlet {
  uint32_t vertex_offset;    /**< Offset into vertex buffer */
  uint32_t vertex_count;     /**< Number of vertices in meshlet */
  uint32_t primitive_offset; /**< Offset into primitive indices */
  uint32_t primitive_count;  /**< Number of primitives in meshlet */
} GpuMeshlet;

typedef struct GpuDrawCommand {
  uint32_t meshlet_offset; /**< Offset into meshlet buffer */
  uint32_t meshlet_count;  /**< Number of meshlets to draw */
  uint32_t instance_count; /**< Number of instances */
  uint32_t first_instance; /**< First instance index */
} GpuDrawCommand;

typedef struct MeshShaderDrawData {
  VkBuffer vertex_buffer;             /**< Vertex data buffer */
  VkDeviceMemory vertex_memory;       /**< Vertex buffer memory */
  VkBuffer meshlet_buffer;            /**< Meshlet data buffer */
  VkDeviceMemory meshlet_memory;      /**< Meshlet buffer memory */
  VkBuffer primitive_buffer;          /**< Primitive indices buffer */
  VkDeviceMemory primitive_memory;    /**< Primitive buffer memory */
  VkBuffer draw_command_buffer;       /**< GPU draw commands buffer */
  VkDeviceMemory draw_command_memory; /**< Draw command buffer memory */
  VkBuffer uniform_buffer; /**< Buffer containing mesh shader uniform data */
  VkDeviceMemory uniform_memory; /**< Memory for mesh shader uniform buffer */

  uint32_t meshlet_count;      /**< Total number of meshlets */
  uint32_t draw_command_count; /**< Number of draw commands */
} MeshShaderDrawData;

/**
 * @brief Mesh shader uniform buffer structure (matches shader layout)
 */
typedef struct MeshShaderUniformBuffer {
  float model[16];        /**< Model matrix (mat4) */
  float view[16];         /**< View matrix (mat4) */
  float proj[16];         /**< Projection matrix (mat4) */
  float mvp[16];          /**< Model-view-projection matrix (mat4) */
  uint32_t materialIndex; /**< Material index for bindless textures */
} MeshShaderUniformBuffer;

/**
 * @brief Material structure matching shader layout
 */
typedef struct MeshShaderMaterial {
  float albedoFactor[3];       /**< vec3 albedoFactor */
  float metallicFactor;        /**< float metallicFactor */
  float roughnessFactor;       /**< float roughnessFactor */
  float normalScale;           /**< float normalScale */
  float emissiveFactor[3];     /**< vec3 emissiveFactor */
  uint32_t albedoTextureIndex; /**< uint albedoTextureIndex */
  uint32_t normalTextureIndex; /**< uint normalTextureIndex */
  uint32_t
      metallicRoughnessTextureIndex; /**< uint metallicRoughnessTextureIndex */
  uint32_t aoTextureIndex;           /**< uint aoTextureIndex */
  uint32_t emissiveTextureIndex;     /**< uint emissiveTextureIndex */
  uint32_t supportsDescriptorIndexing; /**< uint supportsDescriptorIndexing */
} MeshShaderMaterial;

/**
 * @brief Material buffer structure matching shader MaterialBuffer
 */
typedef struct MeshShaderMaterialBuffer {
  MeshShaderMaterial materials[256]; /**< Material array matching shader */
} MeshShaderMaterialBuffer;

/**
 * @brief Records mesh shader rendering commands for the current frame
 * 
 * @param vulkan_state The global Vulkan state
 * @param cmd The command buffer to record into
 */
void vk_mesh_shader_record_frame(VulkanState* vulkan_state, VkCommandBuffer cmd);

/**
 * @brief Initialize mesh shader support
 * @param vulkan_state Vulkan state object
 * @return true if initialization successful, false otherwise
 */
bool vk_mesh_shader_init(VulkanState *vulkan_state);

/**
 * @brief Cleanup mesh shader resources
 * @param vulkan_state Vulkan state object
 */
void vk_mesh_shader_cleanup(VulkanState *vulkan_state);

/**
 * @brief Create a mesh shader pipeline
 * @param vulkan_state Vulkan state object
 * @param config Pipeline configuration
 * @param render_pass Render pass (can be VK_NULL_HANDLE for dynamic rendering)
 * @param pipeline Output pipeline object
 * @return true if creation successful, false otherwise
 */
bool vk_mesh_shader_create_pipeline(VulkanState *vulkan_state,
                                    const MeshShaderPipelineConfig *config,
                                    VkFormat swapchain_format,
                                    VkFormat depth_format,
                                    MeshShaderPipeline *pipeline);

/**
 * @brief Destroy a mesh shader pipeline
 * @param vulkan_state Vulkan state object
 * @param pipeline Pipeline to destroy
 */
void vk_mesh_shader_destroy_pipeline(VulkanState *vulkan_state,
                                     MeshShaderPipeline *pipeline);

/**
 * @brief Record mesh shader draw commands
 * @param cmd_buffer Command buffer to record into
 * @param pipeline Mesh shader pipeline
 * @param draw_data GPU draw data
 */
void vk_mesh_shader_draw(VkCommandBuffer cmd_buffer, VulkanState *vulkan_state,
                         const MeshShaderPipeline *pipeline,
                         const MeshShaderDrawData *draw_data);

/**
 * @brief Update descriptor buffers for mesh shader pipeline
 *
 * Updates both mesh shader descriptor buffer (Set 0) and fragment shader
 * descriptor buffer (Set 1) with the provided buffers and textures.
 *
 * @param vulkan_state Vulkan state object
 * @param pipeline Mesh shader pipeline to update
 * @param draw_data Draw data containing mesh buffers
 * @param material_buffer Buffer containing material data
 * @param lighting_buffer Buffer containing lighting data
 * @param texture_views Array of texture image views
 * @param sampler Texture sampler
 * @param texture_count Number of textures in the array
 * @return true if update succeeded, false otherwise
 */
bool vk_mesh_shader_update_descriptor_buffers(
    VulkanState *vulkan_state, MeshShaderPipeline *pipeline,
    const MeshShaderDrawData *draw_data, VkBuffer material_buffer,
    VkBuffer lighting_buffer, VkImageView *texture_views, VkSampler sampler,
    uint32_t texture_count);

/**
 * @brief Create and update mesh shader uniform buffer
 * @param vulkan_state Vulkan state object
 * @param pipeline Mesh shader pipeline
 * @param uniform_data Uniform buffer data
 * @param uniform_buffer Output uniform buffer
 * @param uniform_memory Output uniform buffer memory
 * @return true on success, false on failure
 */
bool vk_mesh_shader_create_uniform_buffer(
    VulkanState *vulkan_state, MeshShaderPipeline *pipeline,
    const MeshShaderUniformBuffer *uniform_data, VkBuffer *uniform_buffer,
    VkDeviceMemory *uniform_memory);

/**
 * @brief Update mesh shader uniform buffer with new data
 * @param vulkan_state Vulkan state object
 * @param uniform_buffer Uniform buffer to update
 * @param uniform_memory Uniform buffer memory
 * @param uniform_data New uniform data
 * @return true on success, false on failure
 */
bool vk_mesh_shader_update_uniform_buffer(
    VulkanState *vulkan_state, VkBuffer uniform_buffer,
    VkDeviceMemory uniform_memory, const MeshShaderUniformBuffer *uniform_data);

/**
 * @brief Convert traditional mesh data to meshlet format
 * @param vertices Vertex data
 * @param vertex_count Number of vertices
 * @param indices Index data
 * @param index_count Number of indices
 * @param max_vertices_per_meshlet Maximum vertices per meshlet
 * @param max_primitives_per_meshlet Maximum primitives per meshlet
 * @param out_meshlets Output meshlet array
 * @param out_meshlet_count Output meshlet count
 * @return true if conversion successful, false otherwise
 */
bool vk_mesh_shader_generate_meshlets(
    const void *vertices, uint32_t vertex_count, const uint32_t *indices,
    uint32_t index_count, uint32_t max_vertices_per_meshlet,
    uint32_t max_primitives_per_meshlet, GpuMeshlet **out_meshlets,
    uint32_t *out_meshlet_count);

/**
 * @brief Convert a Cardinal scene mesh to meshlet format
 * @param mesh Cardinal mesh to convert
 * @param max_vertices_per_meshlet Maximum vertices per meshlet
 * @param max_primitives_per_meshlet Maximum primitives per meshlet
 * @param out_meshlets Output meshlet array
 * @param out_meshlet_count Output meshlet count
 * @return true if conversion successful, false otherwise
 */
bool vk_mesh_shader_convert_scene_mesh(const CardinalMesh *mesh,
                                       uint32_t max_vertices_per_meshlet,
                                       uint32_t max_primitives_per_meshlet,
                                       GpuMeshlet **out_meshlets,
                                       uint32_t *out_meshlet_count);

/**
 * @brief Create GPU buffers for mesh shader rendering
 * @param vulkan_state Vulkan state object
 * @param meshlets Meshlet data
 * @param meshlet_count Number of meshlets
 * @param vertices Vertex data
 * @param vertex_size Size of vertex data in bytes
 * @param primitives Primitive indices
 * @param primitive_count Number of primitive indices
 * @param draw_data Output draw data structure
 * @return true if creation successful, false otherwise
 */
bool vk_mesh_shader_create_draw_data(VulkanState *vulkan_state,
                                     const GpuMeshlet *meshlets,
                                     uint32_t meshlet_count,
                                     const void *vertices, uint32_t vertex_size,
                                     const uint32_t *primitives,
                                     uint32_t primitive_count,
                                     MeshShaderDrawData *draw_data);

/**
 * @brief Destroy mesh shader draw data buffers
 * @param vulkan_state Vulkan state object
 * @param draw_data Draw data to destroy
 */
void vk_mesh_shader_destroy_draw_data(VulkanState *vulkan_state,
                                      MeshShaderDrawData *draw_data);

/**
 * @brief Add mesh shader draw data to pending cleanup list
 * @param vulkan_state Vulkan state object
 * @param draw_data Draw data to add to cleanup list
 * @return true on success, false on failure
 */
bool vk_mesh_shader_add_pending_cleanup(VulkanState *vulkan_state,
                                        const MeshShaderDrawData *draw_data);

/**
 * @brief Process pending mesh shader draw data cleanup after frame submission
 * @param vulkan_state Vulkan state object
 */
void vk_mesh_shader_process_pending_cleanup(VulkanState *vulkan_state);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_VULKAN_MESH_SHADER_H
