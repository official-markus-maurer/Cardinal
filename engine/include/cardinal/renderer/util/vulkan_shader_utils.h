/**
 * @file vulkan_shader_utils.h
 * @brief Vulkan shader module management utilities for Cardinal Engine
 *
 * This module provides utility functions for loading, creating, and managing
 * Vulkan shader modules from SPIR-V bytecode. It handles both file-based
 * shader loading and direct bytecode compilation into shader modules.
 *
 * Key features:
 * - SPIR-V file loading and validation
 * - Shader module creation from files or bytecode
 * - Error handling and validation for shader compilation
 * - Resource cleanup and management
 * - Support for all shader stages (vertex, fragment, etc.)
 *
 * The utilities abstract the process of converting SPIR-V bytecode into
 * Vulkan shader modules that can be used in graphics pipelines.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_SHADER_UTILS_H
#define VULKAN_SHADER_UTILS_H

#include <stdbool.h>
#include <vulkan/vulkan.h>

/**
 * @brief Creates a Vulkan shader module from a SPIR-V file.
 * @param device Logical device.
 * @param filename Path to the SPIR-V shader file.
 * @param shaderModule Output shader module handle.
 * @return true on success, false on failure.
 */
bool vk_shader_create_module(VkDevice device, const char *filename,
                             VkShaderModule *shaderModule);

/**
 * @brief Creates a Vulkan shader module from SPIR-V bytecode.
 * @param device Logical device.
 * @param code SPIR-V bytecode.
 * @param codeSize Size of the bytecode in bytes.
 * @param shaderModule Output shader module handle.
 * @return true on success, false on failure.
 */
bool vk_shader_create_module_from_code(VkDevice device, const uint32_t *code,
                                       size_t codeSize,
                                       VkShaderModule *shaderModule);

/**
 * @brief Destroys a Vulkan shader module.
 * @param device Logical device.
 * @param shaderModule Shader module to destroy.
 */
void vk_shader_destroy_module(VkDevice device, VkShaderModule shaderModule);

#endif // VULKAN_SHADER_UTILS_H
