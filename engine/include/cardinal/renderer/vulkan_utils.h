/**
 * @file vulkan_utils.h
 * @brief Common Vulkan utility functions and error handling
 *
 * This module provides centralized utility functions for common Vulkan
 * operations to reduce code duplication across renderer modules. It includes
 * standardized error handling, resource creation helpers, and common validation
 * patterns.
 *
 * Key features:
 * - Standardized error handling with logging
 * - Common Vulkan resource creation patterns
 * - Memory allocation helpers
 * - Validation and debugging utilities
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef VULKAN_UTILS_H
#define VULKAN_UTILS_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

// =============================================================================
// Error Handling Macros
// =============================================================================

/**
 * @brief Check VkResult and log error with context
 * @param result VkResult to check
 * @param operation Description of the operation that failed
 * @return true if VK_SUCCESS, false otherwise
 */
#define VK_CHECK_RESULT(result, operation)                                     \
  vk_utils_check_result((result), (operation), __FILE__, __LINE__)

/**
 * @brief Check VkResult and return false on failure
 * @param result VkResult to check
 * @param operation Description of the operation that failed
 */
#define VK_CHECK_RETURN(result, operation)                                     \
  do {                                                                         \
    if (!VK_CHECK_RESULT((result), (operation))) {                             \
      return false;                                                            \
    }                                                                          \
  } while (0)

/**
 * @brief Check VkResult and goto cleanup label on failure
 * @param result VkResult to check
 * @param operation Description of the operation that failed
 * @param label Cleanup label to jump to
 */
#define VK_CHECK_GOTO(result, operation, label)                                \
  do {                                                                         \
    if (!VK_CHECK_RESULT((result), (operation))) {                             \
      goto label;                                                              \
    }                                                                          \
  } while (0)

// =============================================================================
// Core Utility Functions
// =============================================================================

/**
 * @brief Check VkResult and log detailed error information
 * @param result VkResult to check
 * @param operation Description of the operation
 * @param file Source file name
 * @param line Source line number
 * @return true if VK_SUCCESS, false otherwise
 */
bool vk_utils_check_result(VkResult result, const char *operation,
                           const char *file, int line);

/**
 * @brief Get human-readable string for VkResult
 * @param result VkResult value
 * @return String representation of the result
 */
const char *vk_utils_result_string(VkResult result);

// =============================================================================
// Resource Creation Helpers
// =============================================================================

/**
 * @brief Create a Vulkan semaphore with error handling
 * @param device Vulkan device
 * @param semaphore Pointer to store created semaphore
 * @param operation_name Name for error logging
 * @return true on success, false on failure
 */
bool vk_utils_create_semaphore(VkDevice device, VkSemaphore *semaphore,
                               const char *operation_name);

/**
 * @brief Create a Vulkan fence with error handling
 * @param device Vulkan device
 * @param fence Pointer to store created fence
 * @param signaled Whether fence should start signaled
 * @param operation_name Name for error logging
 * @return true on success, false on failure
 */
bool vk_utils_create_fence(VkDevice device, VkFence *fence, bool signaled,
                           const char *operation_name);

/**
 * @brief Create a Vulkan command pool with error handling
 * @param device Vulkan device
 * @param queue_family_index Queue family index
 * @param flags Command pool creation flags
 * @param command_pool Pointer to store created command pool
 * @param operation_name Name for error logging
 * @return true on success, false on failure
 */
bool vk_utils_create_command_pool(VkDevice device, uint32_t queue_family_index,
                                  VkCommandPoolCreateFlags flags,
                                  VkCommandPool *command_pool,
                                  const char *operation_name);

/**
 * @brief Create a Vulkan descriptor pool with error handling
 * @param device Vulkan device
 * @param pool_info Descriptor pool create info
 * @param descriptor_pool Pointer to store created descriptor pool
 * @param operation_name Name for error logging
 * @return true on success, false on failure
 */
bool vk_utils_create_descriptor_pool(
    VkDevice device, const VkDescriptorPoolCreateInfo *pool_info,
    VkDescriptorPool *descriptor_pool, const char *operation_name);

/**
 * @brief Create a Vulkan pipeline layout with error handling
 * @param device Vulkan device
 * @param layout_info Pipeline layout create info
 * @param pipeline_layout Pointer to store created pipeline layout
 * @param operation_name Name for error logging
 * @return true on success, false on failure
 */
bool vk_utils_create_pipeline_layout(
    VkDevice device, const VkPipelineLayoutCreateInfo *layout_info,
    VkPipelineLayout *pipeline_layout, const char *operation_name);

/**
 * @brief Create a Vulkan sampler with error handling
 * @param device Vulkan device
 * @param sampler_info Sampler create info
 * @param sampler Pointer to store created sampler
 * @param operation_name Name for error logging
 * @return true on success, false on failure
 */
bool vk_utils_create_sampler(VkDevice device,
                             const VkSamplerCreateInfo *sampler_info,
                             VkSampler *sampler, const char *operation_name);

// =============================================================================
// Memory and Allocation Helpers
// =============================================================================

/**
 * @brief Safe memory allocation with error logging
 * @param size Size to allocate
 * @param operation_name Name for error logging
 * @return Allocated pointer or NULL on failure
 */
void *vk_utils_allocate(size_t size, const char *operation_name);

/**
 * @brief Safe memory reallocation with error logging
 * @param ptr Existing pointer (can be NULL)
 * @param size New size
 * @param operation_name Name for error logging
 * @return Reallocated pointer or NULL on failure
 */
void *vk_utils_reallocate(void *ptr, size_t size, const char *operation_name);

// =============================================================================
// Validation and Debugging
// =============================================================================

/**
 * @brief Validate that a pointer is not NULL
 * @param ptr Pointer to validate
 * @param name Name of the pointer for error logging
 * @return true if valid, false if NULL
 */
bool vk_utils_validate_pointer(const void *ptr, const char *name);

/**
 * @brief Validate that a handle is not VK_NULL_HANDLE
 * @param handle Vulkan handle to validate
 * @param name Name of the handle for error logging
 * @return true if valid, false if VK_NULL_HANDLE
 */
bool vk_utils_validate_handle(const void *handle, const char *name);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_UTILS_H
