/**
 * @file vulkan_utils.c
 * @brief Implementation of common Vulkan utility functions
 *
 * This module implements centralized utility functions for common Vulkan operations
 * to reduce code duplication across renderer modules.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include "cardinal/renderer/vulkan_utils.h"
#include "cardinal/core/log.h"
#include <stdlib.h>
#include <string.h>

// =============================================================================
// Error Handling Implementation
// =============================================================================

bool vk_utils_check_result(VkResult result, const char* operation, const char* file, int line) {
    if (result == VK_SUCCESS) {
        return true;
    }

    const char* result_string = vk_utils_result_string(result);
    CARDINAL_LOG_ERROR("Vulkan operation failed: %s\n"
                       "  Result: %s (%d)\n"
                       "  Location: %s:%d",
                       operation ? operation : "Unknown operation", result_string, result,
                       file ? file : "Unknown file", line);
    return false;
}

const char* vk_utils_result_string(VkResult result) {
    switch (result) {
        case VK_SUCCESS:
            return "VK_SUCCESS";
        case VK_NOT_READY:
            return "VK_NOT_READY";
        case VK_TIMEOUT:
            return "VK_TIMEOUT";
        case VK_EVENT_SET:
            return "VK_EVENT_SET";
        case VK_EVENT_RESET:
            return "VK_EVENT_RESET";
        case VK_INCOMPLETE:
            return "VK_INCOMPLETE";
        case VK_ERROR_OUT_OF_HOST_MEMORY:
            return "VK_ERROR_OUT_OF_HOST_MEMORY";
        case VK_ERROR_OUT_OF_DEVICE_MEMORY:
            return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
        case VK_ERROR_INITIALIZATION_FAILED:
            return "VK_ERROR_INITIALIZATION_FAILED";
        case VK_ERROR_DEVICE_LOST:
            return "VK_ERROR_DEVICE_LOST";
        case VK_ERROR_MEMORY_MAP_FAILED:
            return "VK_ERROR_MEMORY_MAP_FAILED";
        case VK_ERROR_LAYER_NOT_PRESENT:
            return "VK_ERROR_LAYER_NOT_PRESENT";
        case VK_ERROR_EXTENSION_NOT_PRESENT:
            return "VK_ERROR_EXTENSION_NOT_PRESENT";
        case VK_ERROR_FEATURE_NOT_PRESENT:
            return "VK_ERROR_FEATURE_NOT_PRESENT";
        case VK_ERROR_INCOMPATIBLE_DRIVER:
            return "VK_ERROR_INCOMPATIBLE_DRIVER";
        case VK_ERROR_TOO_MANY_OBJECTS:
            return "VK_ERROR_TOO_MANY_OBJECTS";
        case VK_ERROR_FORMAT_NOT_SUPPORTED:
            return "VK_ERROR_FORMAT_NOT_SUPPORTED";
        case VK_ERROR_FRAGMENTED_POOL:
            return "VK_ERROR_FRAGMENTED_POOL";
        case VK_ERROR_UNKNOWN:
            return "VK_ERROR_UNKNOWN";
        case VK_ERROR_OUT_OF_POOL_MEMORY:
            return "VK_ERROR_OUT_OF_POOL_MEMORY";
        case VK_ERROR_INVALID_EXTERNAL_HANDLE:
            return "VK_ERROR_INVALID_EXTERNAL_HANDLE";
        case VK_ERROR_FRAGMENTATION:
            return "VK_ERROR_FRAGMENTATION";
        case VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS:
            return "VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS";
        case VK_ERROR_SURFACE_LOST_KHR:
            return "VK_ERROR_SURFACE_LOST_KHR";
        case VK_ERROR_NATIVE_WINDOW_IN_USE_KHR:
            return "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR";
        case VK_SUBOPTIMAL_KHR:
            return "VK_SUBOPTIMAL_KHR";
        case VK_ERROR_OUT_OF_DATE_KHR:
            return "VK_ERROR_OUT_OF_DATE_KHR";
        case VK_ERROR_INCOMPATIBLE_DISPLAY_KHR:
            return "VK_ERROR_INCOMPATIBLE_DISPLAY_KHR";
        case VK_ERROR_VALIDATION_FAILED_EXT:
            return "VK_ERROR_VALIDATION_FAILED_EXT";
        case VK_ERROR_INVALID_SHADER_NV:
            return "VK_ERROR_INVALID_SHADER_NV";
        default:
            return "Unknown VkResult";
    }
}

// =============================================================================
// Resource Creation Helpers
// =============================================================================

bool vk_utils_create_semaphore(VkDevice device, VkSemaphore* semaphore,
                               const char* operation_name) {
    if (!vk_utils_validate_pointer(device, "device") ||
        !vk_utils_validate_pointer(semaphore, "semaphore")) {
        return false;
    }

    VkSemaphoreCreateInfo semaphore_info = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = NULL, .flags = 0};

    VkResult result = vkCreateSemaphore(device, &semaphore_info, NULL, semaphore);
    return VK_CHECK_RESULT(result, operation_name ? operation_name : "create semaphore");
}

bool vk_utils_create_fence(VkDevice device, VkFence* fence, bool signaled,
                           const char* operation_name) {
    if (!vk_utils_validate_pointer(device, "device") ||
        !vk_utils_validate_pointer(fence, "fence")) {
        return false;
    }

    VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                                    .pNext = NULL,
                                    .flags = signaled ? VK_FENCE_CREATE_SIGNALED_BIT : 0};

    VkResult result = vkCreateFence(device, &fence_info, NULL, fence);
    return VK_CHECK_RESULT(result, operation_name ? operation_name : "create fence");
}

bool vk_utils_create_command_pool(VkDevice device, uint32_t queue_family_index,
                                  VkCommandPoolCreateFlags flags, VkCommandPool* command_pool,
                                  const char* operation_name) {
    if (!vk_utils_validate_pointer(device, "device") ||
        !vk_utils_validate_pointer(command_pool, "command_pool")) {
        return false;
    }

    VkCommandPoolCreateInfo pool_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                         .pNext = NULL,
                                         .flags = flags,
                                         .queueFamilyIndex = queue_family_index};

    VkResult result = vkCreateCommandPool(device, &pool_info, NULL, command_pool);
    return VK_CHECK_RESULT(result, operation_name ? operation_name : "create command pool");
}

bool vk_utils_create_descriptor_pool(VkDevice device, const VkDescriptorPoolCreateInfo* pool_info,
                                     VkDescriptorPool* descriptor_pool,
                                     const char* operation_name) {
    if (!vk_utils_validate_pointer(device, "device") ||
        !vk_utils_validate_pointer(pool_info, "pool_info") ||
        !vk_utils_validate_pointer(descriptor_pool, "descriptor_pool")) {
        return false;
    }

    VkResult result = vkCreateDescriptorPool(device, pool_info, NULL, descriptor_pool);
    return VK_CHECK_RESULT(result, operation_name ? operation_name : "create descriptor pool");
}

bool vk_utils_create_pipeline_layout(VkDevice device, const VkPipelineLayoutCreateInfo* layout_info,
                                     VkPipelineLayout* pipeline_layout,
                                     const char* operation_name) {
    if (!vk_utils_validate_pointer(device, "device") ||
        !vk_utils_validate_pointer(layout_info, "layout_info") ||
        !vk_utils_validate_pointer(pipeline_layout, "pipeline_layout")) {
        return false;
    }

    VkResult result = vkCreatePipelineLayout(device, layout_info, NULL, pipeline_layout);
    return VK_CHECK_RESULT(result, operation_name ? operation_name : "create pipeline layout");
}

bool vk_utils_create_sampler(VkDevice device, const VkSamplerCreateInfo* sampler_info,
                             VkSampler* sampler, const char* operation_name) {
    if (!vk_utils_validate_pointer(device, "device") ||
        !vk_utils_validate_pointer(sampler_info, "sampler_info") ||
        !vk_utils_validate_pointer(sampler, "sampler")) {
        return false;
    }

    VkResult result = vkCreateSampler(device, sampler_info, NULL, sampler);
    return VK_CHECK_RESULT(result, operation_name ? operation_name : "create sampler");
}

// =============================================================================
// Memory and Allocation Helpers
// =============================================================================

void* vk_utils_allocate(size_t size, const char* operation_name) {
    if (size == 0) {
        CARDINAL_LOG_WARN("Attempted to allocate 0 bytes for operation: %s",
                          operation_name ? operation_name : "unknown");
        return NULL;
    }

    void* ptr = malloc(size);
    if (!ptr) {
        CARDINAL_LOG_ERROR("Failed to allocate %zu bytes for operation: %s", size,
                           operation_name ? operation_name : "unknown");
        return NULL;
    }

    // Initialize to zero for safety
    memset(ptr, 0, size);
    return ptr;
}

void* vk_utils_reallocate(void* ptr, size_t size, const char* operation_name) {
    if (size == 0) {
        CARDINAL_LOG_WARN("Attempted to reallocate to 0 bytes for operation: %s",
                          operation_name ? operation_name : "unknown");
        free(ptr);
        return NULL;
    }

    void* new_ptr = realloc(ptr, size);
    if (!new_ptr) {
        CARDINAL_LOG_ERROR("Failed to reallocate to %zu bytes for operation: %s", size,
                           operation_name ? operation_name : "unknown");
        return NULL;
    }

    return new_ptr;
}

// =============================================================================
// Validation and Debugging
// =============================================================================

bool vk_utils_validate_pointer(const void* ptr, const char* name) {
    if (!ptr) {
        CARDINAL_LOG_ERROR("Null pointer validation failed: %s", name ? name : "unknown");
        return false;
    }
    return true;
}

bool vk_utils_validate_handle(const void* handle, const char* name) {
    if (handle == VK_NULL_HANDLE) {
        CARDINAL_LOG_ERROR("Null handle validation failed: %s", name ? name : "unknown");
        return false;
    }
    return true;
}
