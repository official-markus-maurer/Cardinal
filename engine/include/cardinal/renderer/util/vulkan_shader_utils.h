#ifndef VULKAN_SHADER_UTILS_H
#define VULKAN_SHADER_UTILS_H

#include <vulkan/vulkan.h>
#include <stdbool.h>

/**
 * @brief Creates a Vulkan shader module from a SPIR-V file.
 * @param device Logical device.
 * @param filename Path to the SPIR-V shader file.
 * @param shaderModule Output shader module handle.
 * @return true on success, false on failure.
 */
bool vk_shader_create_module(VkDevice device, const char* filename, VkShaderModule* shaderModule);

/**
 * @brief Creates a Vulkan shader module from SPIR-V bytecode.
 * @param device Logical device.
 * @param code SPIR-V bytecode.
 * @param codeSize Size of the bytecode in bytes.
 * @param shaderModule Output shader module handle.
 * @return true on success, false on failure.
 */
bool vk_shader_create_module_from_code(VkDevice device, const uint32_t* code, size_t codeSize, VkShaderModule* shaderModule);

/**
 * @brief Destroys a Vulkan shader module.
 * @param device Logical device.
 * @param shaderModule Shader module to destroy.
 */
void vk_shader_destroy_module(VkDevice device, VkShaderModule shaderModule);

#endif // VULKAN_SHADER_UTILS_H
