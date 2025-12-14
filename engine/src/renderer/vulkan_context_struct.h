#ifndef VULKAN_CONTEXT_STRUCT_H
#define VULKAN_CONTEXT_STRUCT_H

#include <stdbool.h>
#include <vulkan/vulkan.h>

typedef struct VulkanContext {
  VkInstance instance;
  VkPhysicalDevice physical_device;
  VkDevice device;
  VkQueue graphics_queue;
  VkQueue present_queue;
  uint32_t graphics_queue_family;
  uint32_t present_queue_family;
  VkSurfaceKHR surface;
  VkDebugUtilsMessengerEXT debug_messenger;

  // Feature flags
  bool supports_dynamic_rendering;
  bool supports_vulkan_12_features;
  bool supports_vulkan_13_features;
  bool supports_vulkan_14_features;
  bool supports_maintenance4;
  bool supports_maintenance8;
  bool supports_mesh_shader;
  bool supports_descriptor_indexing;
  bool supports_buffer_device_address;
  bool supports_descriptor_buffer;
  bool supports_shader_quad_control;
  bool supports_shader_maximal_reconvergence;

  // Function pointers
  PFN_vkCmdBeginRendering vkCmdBeginRendering;
  PFN_vkCmdEndRendering vkCmdEndRendering;
  PFN_vkCmdPipelineBarrier2 vkCmdPipelineBarrier2;
  PFN_vkQueueSubmit2 vkQueueSubmit2;
  PFN_vkWaitSemaphores vkWaitSemaphores;
  PFN_vkSignalSemaphore vkSignalSemaphore;
  PFN_vkGetSemaphoreCounterValue vkGetSemaphoreCounterValue;
  PFN_vkGetDeviceBufferMemoryRequirements vkGetDeviceBufferMemoryRequirements;
  PFN_vkGetDeviceImageMemoryRequirements vkGetDeviceImageMemoryRequirements;
  PFN_vkGetDeviceBufferMemoryRequirementsKHR
      vkGetDeviceBufferMemoryRequirementsKHR;
  PFN_vkGetDeviceImageMemoryRequirementsKHR
      vkGetDeviceImageMemoryRequirementsKHR;
  PFN_vkGetBufferDeviceAddress vkGetBufferDeviceAddress;

  // Descriptor buffer extension function pointers
  PFN_vkGetDescriptorSetLayoutSizeEXT vkGetDescriptorSetLayoutSizeEXT;
  PFN_vkGetDescriptorSetLayoutBindingOffsetEXT
      vkGetDescriptorSetLayoutBindingOffsetEXT;
  PFN_vkGetDescriptorEXT vkGetDescriptorEXT;
  PFN_vkCmdBindDescriptorBuffersEXT vkCmdBindDescriptorBuffersEXT;
  PFN_vkCmdSetDescriptorBufferOffsetsEXT vkCmdSetDescriptorBufferOffsetsEXT;
  PFN_vkCmdBindDescriptorBufferEmbeddedSamplersEXT
      vkCmdBindDescriptorBufferEmbeddedSamplersEXT;
  PFN_vkGetBufferOpaqueCaptureDescriptorDataEXT
      vkGetBufferOpaqueCaptureDescriptorDataEXT;
  PFN_vkGetImageOpaqueCaptureDescriptorDataEXT
      vkGetImageOpaqueCaptureDescriptorDataEXT;
  PFN_vkGetImageViewOpaqueCaptureDescriptorDataEXT
      vkGetImageViewOpaqueCaptureDescriptorDataEXT;
  PFN_vkGetSamplerOpaqueCaptureDescriptorDataEXT
      vkGetSamplerOpaqueCaptureDescriptorDataEXT;

  // Descriptor buffer properties
  bool descriptor_buffer_extension_available;
  VkDeviceSize descriptor_buffer_uniform_buffer_size;
  VkDeviceSize descriptor_buffer_combined_image_sampler_size;
} VulkanContext;

#endif
