#ifndef VULKAN_PIPELINES_STRUCT_H
#define VULKAN_PIPELINES_STRUCT_H

#include "cardinal/renderer/vulkan_mesh_shader.h"
#include "cardinal/renderer/vulkan_pbr.h"
#include <stdbool.h>
#include <vulkan/vulkan.h>

typedef struct VulkanPipelines {
  // PBR Pipeline
  bool use_pbr_pipeline;
  VulkanPBRPipeline pbr_pipeline;

  // Mesh Shader Pipeline
  bool use_mesh_shader_pipeline;
  MeshShaderPipeline mesh_shader_pipeline;

  // Compute Shader
  bool compute_shader_initialized;
  VkDescriptorPool compute_descriptor_pool;
  VkCommandPool compute_command_pool;
  VkCommandBuffer compute_command_buffer;

  // UV and Wireframe (Simple pipelines)
  VkPipeline uv_pipeline;
  VkPipelineLayout uv_pipeline_layout;
  VkPipeline wireframe_pipeline;
  VkPipelineLayout wireframe_pipeline_layout;

  // Shared Resources for Simple Pipelines
  VkDescriptorSetLayout simple_descriptor_layout;
  VkDescriptorPool simple_descriptor_pool;
  VkDescriptorSet simple_descriptor_set;
  VkBuffer simple_uniform_buffer;
  VkDeviceMemory simple_uniform_buffer_memory;
  void *simple_uniform_buffer_mapped;
} VulkanPipelines;

#endif
