/**
 * @file vulkan_sync_manager.c
 * @brief Vulkan synchronization primitive management implementation
 *
 * This file implements centralized management of Vulkan synchronization primitives
 * including semaphores, fences, and timeline semaphores. It provides a clean API
 * for frame-in-flight tracking and proper CPU-GPU synchronization.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include <cardinal/core/log.h>
#include <cardinal/renderer/vulkan_sync_manager.h>
#include <malloc.h>
#include <stdlib.h>
#include <string.h>

// Core sync manager functions

bool vulkan_sync_manager_init(VulkanSyncManager* sync_manager, VkDevice device,
                              VkQueue graphics_queue, uint32_t max_frames_in_flight) {
    if (!sync_manager || !device || max_frames_in_flight == 0) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Invalid parameters for initialization");
        return false;
    }

    memset(sync_manager, 0, sizeof(VulkanSyncManager));
    sync_manager->device = device;
    sync_manager->graphics_queue = graphics_queue;
    sync_manager->max_frames_in_flight = max_frames_in_flight;
    sync_manager->current_frame = 0;

    // Allocate per-frame semaphore arrays
    sync_manager->image_acquired_semaphores =
        (VkSemaphore*)calloc(max_frames_in_flight, sizeof(VkSemaphore));
    if (!sync_manager->image_acquired_semaphores) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Failed to allocate image acquired semaphores");
        return false;
    }

    sync_manager->render_finished_semaphores =
        (VkSemaphore*)calloc(max_frames_in_flight, sizeof(VkSemaphore));
    if (!sync_manager->render_finished_semaphores) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Failed to allocate render finished semaphores");
        free(sync_manager->image_acquired_semaphores);
        return false;
    }

    sync_manager->in_flight_fences = (VkFence*)calloc(max_frames_in_flight, sizeof(VkFence));
    if (!sync_manager->in_flight_fences) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Failed to allocate in-flight fences");
        free(sync_manager->image_acquired_semaphores);
        free(sync_manager->render_finished_semaphores);
        return false;
    }

    // Create per-frame image acquired semaphores
    for (uint32_t i = 0; i < max_frames_in_flight; ++i) {
        VkSemaphoreCreateInfo semaphore_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};

        if (vkCreateSemaphore(device, &semaphore_info, NULL,
                              &sync_manager->image_acquired_semaphores[i]) != VK_SUCCESS) {
            CARDINAL_LOG_ERROR(
                "[SYNC_MANAGER] Failed to create image acquired semaphore for frame %u", i);
            vulkan_sync_manager_destroy(sync_manager);
            return false;
        }
    }

    // Create per-frame render finished semaphores
    for (uint32_t i = 0; i < max_frames_in_flight; ++i) {
        VkSemaphoreCreateInfo semaphore_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};

        if (vkCreateSemaphore(device, &semaphore_info, NULL,
                              &sync_manager->render_finished_semaphores[i]) != VK_SUCCESS) {
            CARDINAL_LOG_ERROR(
                "[SYNC_MANAGER] Failed to create render finished semaphore for frame %u", i);
            vulkan_sync_manager_destroy(sync_manager);
            return false;
        }
    }

    // Create per-frame in-flight fences (start signaled for first frame)
    for (uint32_t i = 0; i < max_frames_in_flight; ++i) {
        VkFenceCreateInfo fence_info = {
            .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = VK_FENCE_CREATE_SIGNALED_BIT // Start signaled
        };

        if (vkCreateFence(device, &fence_info, NULL, &sync_manager->in_flight_fences[i]) !=
            VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[SYNC_MANAGER] Failed to create in-flight fence for frame %u", i);
            vulkan_sync_manager_destroy(sync_manager);
            return false;
        }
    }

    // Create timeline semaphore
    VkSemaphoreTypeCreateInfo timeline_type_info = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
        .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
        .initialValue = 0};

    VkSemaphoreCreateInfo timeline_semaphore_info = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &timeline_type_info};

    if (vkCreateSemaphore(device, &timeline_semaphore_info, NULL,
                          &sync_manager->timeline_semaphore) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Failed to create timeline semaphore");
        vulkan_sync_manager_destroy(sync_manager);
        return false;
    }

    // Initialize timeline values with atomic operations
    atomic_store(&sync_manager->current_frame_value, 0);
    atomic_store(&sync_manager->image_available_value, 1);
    atomic_store(&sync_manager->render_complete_value, 2);
    atomic_store(&sync_manager->global_timeline_counter, 3);

    // Initialize performance statistics
    atomic_store(&sync_manager->timeline_wait_count, 0);
    atomic_store(&sync_manager->timeline_signal_count, 0);

    // Initialize timeline value strategy
    vulkan_sync_manager_init_value_strategy(sync_manager, 1, true);

    sync_manager->initialized = true;
    CARDINAL_LOG_INFO("[SYNC_MANAGER] Initialized with %u frames in flight", max_frames_in_flight);

    return true;
}

void vulkan_sync_manager_destroy(VulkanSyncManager* sync_manager) {
    if (!sync_manager || !sync_manager->device) {
        return;
    }

    // Wait for device to be idle before destroying sync objects
    vkDeviceWaitIdle(sync_manager->device);

    // Destroy timeline semaphore
    if (sync_manager->timeline_semaphore != VK_NULL_HANDLE) {
        vkDestroySemaphore(sync_manager->device, sync_manager->timeline_semaphore, NULL);
        sync_manager->timeline_semaphore = VK_NULL_HANDLE;
    }

    // Destroy per-frame semaphores and fences
    if (sync_manager->image_acquired_semaphores) {
        for (uint32_t i = 0; i < sync_manager->max_frames_in_flight; ++i) {
            if (sync_manager->image_acquired_semaphores[i] != VK_NULL_HANDLE) {
                vkDestroySemaphore(sync_manager->device, sync_manager->image_acquired_semaphores[i],
                                   NULL);
            }
        }
        free(sync_manager->image_acquired_semaphores);
        sync_manager->image_acquired_semaphores = NULL;
    }

    if (sync_manager->render_finished_semaphores) {
        for (uint32_t i = 0; i < sync_manager->max_frames_in_flight; ++i) {
            if (sync_manager->render_finished_semaphores[i] != VK_NULL_HANDLE) {
                vkDestroySemaphore(sync_manager->device,
                                   sync_manager->render_finished_semaphores[i], NULL);
            }
        }
        free(sync_manager->render_finished_semaphores);
        sync_manager->render_finished_semaphores = NULL;
    }

    if (sync_manager->in_flight_fences) {
        for (uint32_t i = 0; i < sync_manager->max_frames_in_flight; ++i) {
            if (sync_manager->in_flight_fences[i] != VK_NULL_HANDLE) {
                vkDestroyFence(sync_manager->device, sync_manager->in_flight_fences[i], NULL);
            }
        }
        free(sync_manager->in_flight_fences);
        sync_manager->in_flight_fences = NULL;
    }

    // Clean up timeline value strategy (no explicit cleanup needed for the struct)

    sync_manager->initialized = false;
    CARDINAL_LOG_INFO("[SYNC_MANAGER] Destroyed");
}

VkResult vulkan_sync_manager_wait_for_frame(VulkanSyncManager* sync_manager, uint64_t timeout_ns) {
    if (!sync_manager || !sync_manager->initialized) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    VkFence current_fence = sync_manager->in_flight_fences[sync_manager->current_frame];

    // Check fence status first to avoid unnecessary waits
    VkResult fence_status = vkGetFenceStatus(sync_manager->device, current_fence);
    if (fence_status == VK_SUCCESS) {
        // Already signaled, no wait needed
        return VK_SUCCESS;
    } else if (fence_status != VK_NOT_READY) {
        // Error occurred
        return fence_status;
    }

    // Need to wait for fence
    return vkWaitForFences(sync_manager->device, 1, &current_fence, VK_TRUE, timeout_ns);
}

VkResult vulkan_sync_manager_reset_frame_fence(VulkanSyncManager* sync_manager) {
    if (!sync_manager || !sync_manager->initialized) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    VkFence current_fence = sync_manager->in_flight_fences[sync_manager->current_frame];
    return vkResetFences(sync_manager->device, 1, &current_fence);
}

void vulkan_sync_manager_advance_frame(VulkanSyncManager* sync_manager) {
    if (!sync_manager || !sync_manager->initialized) {
        return;
    }

    sync_manager->current_frame =
        (sync_manager->current_frame + 1) % sync_manager->max_frames_in_flight;

    // Atomically advance timeline values for thread safety
    uint64_t new_frame_value = atomic_fetch_add(&sync_manager->current_frame_value, 3) + 3;
    atomic_store(&sync_manager->image_available_value, new_frame_value + 1);
    atomic_store(&sync_manager->render_complete_value, new_frame_value + 2);
}

// Semaphore management

void vulkan_sync_manager_get_frame_sync_info(VulkanSyncManager* sync_manager,
                                             VulkanFrameSyncInfo* sync_info) {
    if (!sync_manager || !sync_info || !sync_manager->initialized) {
        return;
    }

    uint32_t frame = sync_manager->current_frame;

    sync_info->wait_semaphore = sync_manager->image_acquired_semaphores[frame];
    sync_info->signal_semaphore = sync_manager->render_finished_semaphores[frame];
    sync_info->fence = sync_manager->in_flight_fences[frame];
    sync_info->timeline_value = atomic_load(&sync_manager->render_complete_value);
    sync_info->wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
}

bool vulkan_sync_manager_create_semaphore(VulkanSyncManager* sync_manager, VkSemaphore* semaphore) {
    if (!sync_manager || !semaphore || !sync_manager->initialized) {
        return false;
    }

    VkSemaphoreCreateInfo semaphore_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};

    return vkCreateSemaphore(sync_manager->device, &semaphore_info, NULL, semaphore) == VK_SUCCESS;
}

bool vulkan_sync_manager_create_fence(VulkanSyncManager* sync_manager, bool signaled,
                                      VkFence* fence) {
    if (!sync_manager || !fence || !sync_manager->initialized) {
        return false;
    }

    VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                                    .flags = signaled ? VK_FENCE_CREATE_SIGNALED_BIT : 0};

    return vkCreateFence(sync_manager->device, &fence_info, NULL, fence) == VK_SUCCESS;
}

void vulkan_sync_manager_destroy_semaphore(VulkanSyncManager* sync_manager, VkSemaphore semaphore) {
    if (!sync_manager || !sync_manager->initialized || semaphore == VK_NULL_HANDLE) {
        return;
    }

    vkDestroySemaphore(sync_manager->device, semaphore, NULL);
}

void vulkan_sync_manager_destroy_fence(VulkanSyncManager* sync_manager, VkFence fence) {
    if (!sync_manager || !sync_manager->initialized || fence == VK_NULL_HANDLE) {
        return;
    }

    vkDestroyFence(sync_manager->device, fence, NULL);
}

// Timeline semaphore functions

VkResult vulkan_sync_manager_wait_timeline(VulkanSyncManager* sync_manager, uint64_t value,
                                           uint64_t timeout_ns) {
    if (!sync_manager || !sync_manager->initialized) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    // Wait for the exact requested value (no optimization)
    VkSemaphoreWaitInfo wait_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                                     .semaphoreCount = 1,
                                     .pSemaphores = &sync_manager->timeline_semaphore,
                                     .pValues = &value};

    VkResult result = vkWaitSemaphores(sync_manager->device, &wait_info, timeout_ns);
    if (result == VK_SUCCESS) {
        atomic_fetch_add(&sync_manager->timeline_wait_count, 1);
    }

    return result;
}

VkResult vulkan_sync_manager_signal_timeline(VulkanSyncManager* sync_manager, uint64_t value) {
    if (!sync_manager || !sync_manager->initialized) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    // Get optimized value if needed
    uint64_t optimized_value = vulkan_sync_manager_get_optimized_next_value(sync_manager, value);

    VkTimelineSemaphoreSubmitInfo timeline_info = {
        .sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
        .signalSemaphoreValueCount = 1,
        .pSignalSemaphoreValues = &optimized_value};

    VkSubmitInfo submit_info = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                                .pNext = &timeline_info,
                                .signalSemaphoreCount = 1,
                                .pSignalSemaphores = &sync_manager->timeline_semaphore};

    VkResult result = vkQueueSubmit(sync_manager->graphics_queue, 1, &submit_info, VK_NULL_HANDLE);
    if (result == VK_SUCCESS) {
        atomic_fetch_add(&sync_manager->timeline_signal_count, 1);
    }

    return result;
}

VkResult vulkan_sync_manager_get_timeline_value(VulkanSyncManager* sync_manager, uint64_t* value) {
    if (!sync_manager || !value || !sync_manager->initialized) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    return vkGetSemaphoreCounterValue(sync_manager->device, sync_manager->timeline_semaphore,
                                      value);
}

uint64_t vulkan_sync_manager_get_next_timeline_value(VulkanSyncManager* sync_manager) {
    if (!sync_manager || !sync_manager->initialized) {
        return 0;
    }

    // Use atomic counter for thread-safe unique value generation
    return atomic_fetch_add(&sync_manager->global_timeline_counter, 1);
}

// Utility functions

bool vulkan_sync_manager_is_frame_ready(VulkanSyncManager* sync_manager) {
    if (!sync_manager || !sync_manager->initialized) {
        return false;
    }

    VkFence current_fence = sync_manager->in_flight_fences[sync_manager->current_frame];
    return vkGetFenceStatus(sync_manager->device, current_fence) == VK_SUCCESS;
}

uint32_t vulkan_sync_manager_get_current_frame(VulkanSyncManager* sync_manager) {
    if (!sync_manager || !sync_manager->initialized) {
        return 0;
    }

    return sync_manager->current_frame;
}

uint32_t vulkan_sync_manager_get_max_frames(VulkanSyncManager* sync_manager) {
    if (!sync_manager || !sync_manager->initialized) {
        return 0;
    }

    return sync_manager->max_frames_in_flight;
}

// Enhanced timeline semaphore functions

VkResult vulkan_sync_manager_wait_timeline_batch(VulkanSyncManager* sync_manager,
                                                 const uint64_t* values, uint32_t count,
                                                 uint64_t timeout_ns) {
    if (!sync_manager || !sync_manager->initialized || !values || count == 0) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    // Create array of semaphores (all the same timeline semaphore)
    VkSemaphore* semaphores = (VkSemaphore*)malloc(count * sizeof(VkSemaphore));
    if (!semaphores) {
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }

    for (uint32_t i = 0; i < count; i++) {
        semaphores[i] = sync_manager->timeline_semaphore;
    }

    VkSemaphoreWaitInfo wait_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                                     .semaphoreCount = count,
                                     .pSemaphores = semaphores,
                                     .pValues = values};

    VkResult result = vkWaitSemaphores(sync_manager->device, &wait_info, timeout_ns);
    if (result == VK_SUCCESS) {
        atomic_fetch_add(&sync_manager->timeline_wait_count, count);
    }

    free(semaphores);
    return result;
}

VkResult vulkan_sync_manager_signal_timeline_batch(VulkanSyncManager* sync_manager,
                                                   const uint64_t* values, uint32_t count) {
    if (!sync_manager || !sync_manager->initialized || !values || count == 0) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    // Signal each value individually (Vulkan doesn't support batch signaling)
    for (uint32_t i = 0; i < count; i++) {
        VkSemaphoreSignalInfo signal_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
                                             .semaphore = sync_manager->timeline_semaphore,
                                             .value = values[i]};

        VkResult result = vkSignalSemaphore(sync_manager->device, &signal_info);
        if (result != VK_SUCCESS) {
            return result;
        }

        atomic_fetch_add(&sync_manager->timeline_signal_count, 1);
    }

    return VK_SUCCESS;
}

// Error handling and recovery implementations
const char* vulkan_timeline_error_to_string(VulkanTimelineError error) {
    switch (error) {
        case VULKAN_TIMELINE_ERROR_NONE:
            return "No error";
        case VULKAN_TIMELINE_ERROR_TIMEOUT:
            return "Timeline semaphore wait timeout";
        case VULKAN_TIMELINE_ERROR_DEVICE_LOST:
            return "Vulkan device lost";
        case VULKAN_TIMELINE_ERROR_OUT_OF_MEMORY:
            return "Out of memory";
        case VULKAN_TIMELINE_ERROR_INVALID_VALUE:
            return "Invalid timeline value";
        case VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID:
            return "Timeline semaphore is invalid";
        case VULKAN_TIMELINE_ERROR_UNKNOWN:
        default:
            return "Unknown error";
    }
}

static VulkanTimelineError vulkan_result_to_timeline_error(VkResult result) {
    switch (result) {
        case VK_SUCCESS:
            return VULKAN_TIMELINE_ERROR_NONE;
        case VK_TIMEOUT:
            return VULKAN_TIMELINE_ERROR_TIMEOUT;
        case VK_ERROR_DEVICE_LOST:
            return VULKAN_TIMELINE_ERROR_DEVICE_LOST;
        case VK_ERROR_OUT_OF_HOST_MEMORY:
        case VK_ERROR_OUT_OF_DEVICE_MEMORY:
            return VULKAN_TIMELINE_ERROR_OUT_OF_MEMORY;
        default:
            return VULKAN_TIMELINE_ERROR_UNKNOWN;
    }
}

VulkanTimelineError vulkan_sync_manager_wait_timeline_safe(VulkanSyncManager* sync_manager,
                                                           uint64_t value, uint64_t timeout_ns,
                                                           VulkanTimelineErrorInfo* error_info) {
    if (!sync_manager || !sync_manager->timeline_semaphore) {
        if (error_info) {
            error_info->error_type = VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
            error_info->vulkan_result = VK_ERROR_UNKNOWN;
            error_info->timeline_value = value;
            error_info->timeout_ns = timeout_ns;
            snprintf(error_info->error_message, sizeof(error_info->error_message),
                     "Invalid sync manager or timeline semaphore");
        }
        return VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
    }

    // Validate timeline value
    uint64_t current_value = atomic_load(&sync_manager->global_timeline_counter);
    if (value > current_value + 1000000) { // Prevent waiting for values too far in the future
        if (error_info) {
            error_info->error_type = VULKAN_TIMELINE_ERROR_INVALID_VALUE;
            error_info->vulkan_result = VK_ERROR_UNKNOWN;
            error_info->timeline_value = value;
            error_info->timeout_ns = timeout_ns;
            snprintf(error_info->error_message, sizeof(error_info->error_message),
                     "Timeline value %llu is too far in the future (current: %llu)", value,
                     current_value);
        }
        return VULKAN_TIMELINE_ERROR_INVALID_VALUE;
    }

    VkSemaphoreWaitInfo wait_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                                     .semaphoreCount = 1,
                                     .pSemaphores = &sync_manager->timeline_semaphore,
                                     .pValues = &value};

    VkResult result = vkWaitSemaphores(sync_manager->device, &wait_info, timeout_ns);
    VulkanTimelineError timeline_error = vulkan_result_to_timeline_error(result);

    if (error_info) {
        error_info->error_type = timeline_error;
        error_info->vulkan_result = result;
        error_info->timeline_value = value;
        error_info->timeout_ns = timeout_ns;

        if (timeline_error != VULKAN_TIMELINE_ERROR_NONE) {
            snprintf(error_info->error_message, sizeof(error_info->error_message),
                     "Timeline wait failed: %s (VkResult: %d)",
                     vulkan_timeline_error_to_string(timeline_error), result);
        } else {
            snprintf(error_info->error_message, sizeof(error_info->error_message),
                     "Timeline wait successful");
        }
    }

    if (result == VK_SUCCESS) {
        atomic_fetch_add(&sync_manager->timeline_wait_count, 1);
    }

    return timeline_error;
}

VulkanTimelineError vulkan_sync_manager_signal_timeline_safe(VulkanSyncManager* sync_manager,
                                                             uint64_t value,
                                                             VulkanTimelineErrorInfo* error_info) {
    if (!sync_manager || !sync_manager->timeline_semaphore) {
        if (error_info) {
            error_info->error_type = VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
            error_info->vulkan_result = VK_ERROR_UNKNOWN;
            error_info->timeline_value = value;
            error_info->timeout_ns = 0;
            snprintf(error_info->error_message, sizeof(error_info->error_message),
                     "Invalid sync manager or timeline semaphore");
        }
        return VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
    }

    // Validate timeline value (must be greater than current)
    uint64_t current_value;
    VkResult get_result = vkGetSemaphoreCounterValue(
        sync_manager->device, sync_manager->timeline_semaphore, &current_value);
    if (get_result != VK_SUCCESS) {
        VulkanTimelineError timeline_error = vulkan_result_to_timeline_error(get_result);
        if (error_info) {
            error_info->error_type = timeline_error;
            error_info->vulkan_result = get_result;
            error_info->timeline_value = value;
            error_info->timeout_ns = 0;
            snprintf(error_info->error_message, sizeof(error_info->error_message),
                     "Failed to get current timeline value: %s (VkResult: %d)",
                     vulkan_timeline_error_to_string(timeline_error), get_result);
        }
        return timeline_error;
    }

    if (value <= current_value) {
        if (error_info) {
            error_info->error_type = VULKAN_TIMELINE_ERROR_INVALID_VALUE;
            error_info->vulkan_result = VK_ERROR_UNKNOWN;
            error_info->timeline_value = value;
            error_info->timeout_ns = 0;
            snprintf(error_info->error_message, sizeof(error_info->error_message),
                     "Timeline value %llu must be greater than current value %llu", value,
                     current_value);
        }
        return VULKAN_TIMELINE_ERROR_INVALID_VALUE;
    }

    VkSemaphoreSignalInfo signal_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
                                         .semaphore = sync_manager->timeline_semaphore,
                                         .value = value};

    VkResult result = vkSignalSemaphore(sync_manager->device, &signal_info);
    VulkanTimelineError timeline_error = vulkan_result_to_timeline_error(result);

    if (error_info) {
        error_info->error_type = timeline_error;
        error_info->vulkan_result = result;
        error_info->timeline_value = value;
        error_info->timeout_ns = 0;

        if (timeline_error != VULKAN_TIMELINE_ERROR_NONE) {
            snprintf(error_info->error_message, sizeof(error_info->error_message),
                     "Timeline signal failed: %s (VkResult: %d)",
                     vulkan_timeline_error_to_string(timeline_error), result);
        } else {
            snprintf(error_info->error_message, sizeof(error_info->error_message),
                     "Timeline signal successful");
        }
    }

    if (result == VK_SUCCESS) {
        atomic_fetch_add(&sync_manager->timeline_signal_count, 1);
    }

    return timeline_error;
}

bool vulkan_sync_manager_validate_timeline_state(VulkanSyncManager* sync_manager) {
    if (!sync_manager || !sync_manager->timeline_semaphore) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Invalid sync manager or timeline semaphore");
        return false;
    }

    // Check if semaphore is still valid
    uint64_t current_value;
    VkResult result = vkGetSemaphoreCounterValue(sync_manager->device,
                                                 sync_manager->timeline_semaphore, &current_value);

    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Timeline semaphore validation failed: %d", result);
        return false;
    }

    // Check for reasonable timeline values
    uint64_t atomic_value = atomic_load(&sync_manager->global_timeline_counter);
    if (current_value > atomic_value + 1000000) {
        CARDINAL_LOG_WARN(
            "[SYNC_MANAGER] Timeline value inconsistency: semaphore=%llu, atomic=%llu",
            current_value, atomic_value);
    }

    return true;
}

bool vulkan_sync_manager_recover_timeline_semaphore(VulkanSyncManager* sync_manager,
                                                    VulkanTimelineErrorInfo* error_info) {
    if (!sync_manager) {
        return false;
    }

    CARDINAL_LOG_WARN("[SYNC_MANAGER] Attempting timeline semaphore recovery");

    // For device lost errors, we can't recover - need full device recreation
    if (error_info && error_info->error_type == VULKAN_TIMELINE_ERROR_DEVICE_LOST) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Cannot recover from device lost error");
        return false;
    }

    // Try to recreate the timeline semaphore
    if (sync_manager->timeline_semaphore != VK_NULL_HANDLE) {
        vkDestroySemaphore(sync_manager->device, sync_manager->timeline_semaphore, NULL);
        sync_manager->timeline_semaphore = VK_NULL_HANDLE;
    }

    VkSemaphoreTypeCreateInfo timeline_info = {.sType =
                                                   VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
                                               .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
                                               .initialValue = 0};

    VkSemaphoreCreateInfo create_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                                         .pNext = &timeline_info};

    VkResult result = vkCreateSemaphore(sync_manager->device, &create_info, NULL,
                                        &sync_manager->timeline_semaphore);

    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Failed to recreate timeline semaphore: %d", result);
        return false;
    }

    // Reset atomic counters
    atomic_store(&sync_manager->global_timeline_counter, 0);
    atomic_store(&sync_manager->current_frame_value, 0);
    atomic_store(&sync_manager->image_available_value, 0);
    atomic_store(&sync_manager->render_complete_value, 0);

    CARDINAL_LOG_INFO("[SYNC_MANAGER] Timeline semaphore recovery successful");
    return true;
}

// Timeline value optimization implementations
bool vulkan_sync_manager_init_value_strategy(VulkanSyncManager* sync_manager,
                                             uint64_t increment_step, bool auto_reset_enabled) {
    if (!sync_manager) {
        return false;
    }

    sync_manager->value_strategy.base_value = 0;
    sync_manager->value_strategy.increment_step = increment_step > 0 ? increment_step : 1;
    sync_manager->value_strategy.max_safe_value = UINT64_MAX / 2; // Use half of max to be safe
    sync_manager->value_strategy.overflow_threshold =
        sync_manager->value_strategy.max_safe_value - (increment_step * 1000);
    sync_manager->value_strategy.auto_reset_enabled = auto_reset_enabled;

    CARDINAL_LOG_INFO(
        "[SYNC_MANAGER] Timeline value strategy initialized: step=%llu, auto_reset=%s",
        increment_step, auto_reset_enabled ? "enabled" : "disabled");

    return true;
}

uint64_t vulkan_sync_manager_get_optimized_next_value(VulkanSyncManager* sync_manager,
                                                      uint64_t min_increment) {
    if (!sync_manager) {
        return 0;
    }

    uint64_t increment = min_increment > sync_manager->value_strategy.increment_step
                             ? min_increment
                             : sync_manager->value_strategy.increment_step;

    uint64_t current_value = atomic_load(&sync_manager->global_timeline_counter);
    uint64_t next_value = current_value + increment;

    // Check for potential overflow
    if (next_value > sync_manager->value_strategy.overflow_threshold) {
        if (sync_manager->value_strategy.auto_reset_enabled) {
            CARDINAL_LOG_WARN(
                "[SYNC_MANAGER] Timeline value approaching overflow, triggering reset");
            if (vulkan_sync_manager_reset_timeline_values(sync_manager)) {
                next_value = sync_manager->value_strategy.increment_step;
            } else {
                CARDINAL_LOG_ERROR(
                    "[SYNC_MANAGER] Failed to reset timeline values, continuing with risky value");
            }
        } else {
            CARDINAL_LOG_WARN(
                "[SYNC_MANAGER] Timeline value %llu approaching overflow threshold %llu",
                next_value, sync_manager->value_strategy.overflow_threshold);
        }
    }

    // Atomically update the counter
    atomic_store(&sync_manager->global_timeline_counter, next_value);

    return next_value;
}

bool vulkan_sync_manager_check_overflow_risk(VulkanSyncManager* sync_manager,
                                             uint64_t* remaining_values) {
    if (!sync_manager) {
        return false;
    }

    uint64_t current_value = atomic_load(&sync_manager->global_timeline_counter);
    uint64_t threshold = sync_manager->value_strategy.overflow_threshold;

    if (remaining_values) {
        *remaining_values = threshold > current_value ? (threshold - current_value) : 0;
    }

    bool at_risk = current_value >= threshold;

    if (at_risk) {
        CARDINAL_LOG_WARN(
            "[SYNC_MANAGER] Timeline overflow risk detected: current=%llu, threshold=%llu",
            current_value, threshold);
    }

    return at_risk;
}

bool vulkan_sync_manager_reset_timeline_values(VulkanSyncManager* sync_manager) {
    if (!sync_manager || !sync_manager->timeline_semaphore) {
        return false;
    }

    CARDINAL_LOG_INFO("[SYNC_MANAGER] Resetting timeline values to prevent overflow");

    // Wait for all pending operations to complete
    uint64_t current_value;
    VkResult result = vkGetSemaphoreCounterValue(sync_manager->device,
                                                 sync_manager->timeline_semaphore, &current_value);

    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Failed to get current timeline value for reset: %d",
                           result);
        return false;
    }

    // Wait for the current value to be reached (ensures all operations are complete)
    VkSemaphoreWaitInfo wait_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                                     .semaphoreCount = 1,
                                     .pSemaphores = &sync_manager->timeline_semaphore,
                                     .pValues = &current_value};

    result = vkWaitSemaphores(sync_manager->device, &wait_info, UINT64_MAX);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Failed to wait for timeline completion before reset: %d",
                           result);
        return false;
    }

    // Recreate the timeline semaphore with initial value 0
    vkDestroySemaphore(sync_manager->device, sync_manager->timeline_semaphore, NULL);

    VkSemaphoreTypeCreateInfo timeline_info = {.sType =
                                                   VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
                                               .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
                                               .initialValue = 0};

    VkSemaphoreCreateInfo create_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                                         .pNext = &timeline_info};

    result = vkCreateSemaphore(sync_manager->device, &create_info, NULL,
                               &sync_manager->timeline_semaphore);

    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[SYNC_MANAGER] Failed to recreate timeline semaphore after reset: %d",
                           result);
        return false;
    }

    // Reset all atomic counters
    atomic_store(&sync_manager->global_timeline_counter, 0);
    atomic_store(&sync_manager->current_frame_value, 0);
    atomic_store(&sync_manager->image_available_value, 0);
    atomic_store(&sync_manager->render_complete_value, 0);

    // Reset strategy base value
    sync_manager->value_strategy.base_value = 0;

    CARDINAL_LOG_INFO("[SYNC_MANAGER] Timeline values reset successfully");
    return true;
}

void vulkan_sync_manager_optimize_value_allocation(VulkanSyncManager* sync_manager) {
    if (!sync_manager) {
        return;
    }

    uint64_t remaining_values;
    bool at_risk = vulkan_sync_manager_check_overflow_risk(sync_manager, &remaining_values);

    if (at_risk) {
        CARDINAL_LOG_INFO(
            "[SYNC_MANAGER] Optimizing timeline value allocation due to overflow risk");

        // If auto-reset is enabled and we're at risk, trigger a reset
        if (sync_manager->value_strategy.auto_reset_enabled) {
            vulkan_sync_manager_reset_timeline_values(sync_manager);
        } else {
            // Adjust increment step to use remaining values more efficiently
            uint64_t current_step = sync_manager->value_strategy.increment_step;
            uint64_t optimized_step =
                remaining_values / 1000; // Spread remaining values over 1000 operations

            if (optimized_step > 0 && optimized_step < current_step) {
                sync_manager->value_strategy.increment_step = optimized_step;
                CARDINAL_LOG_INFO("[SYNC_MANAGER] Reduced increment step from %llu to %llu to "
                                  "optimize remaining values",
                                  current_step, optimized_step);
            }
        }
    } else {
        // Check if we can increase increment step for better performance
        uint64_t current_step = sync_manager->value_strategy.increment_step;
        uint64_t optimal_step =
            remaining_values / 100000; // Allow for 100k operations with current step

        if (optimal_step > current_step * 2) {
            sync_manager->value_strategy.increment_step = current_step * 2;
            CARDINAL_LOG_DEBUG(
                "[SYNC_MANAGER] Increased increment step from %llu to %llu for better performance",
                current_step, sync_manager->value_strategy.increment_step);
        }
    }
}

VkResult vulkan_sync_manager_is_timeline_value_reached(VulkanSyncManager* sync_manager,
                                                       uint64_t value, bool* reached) {
    if (!sync_manager || !sync_manager->initialized || !reached) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    uint64_t current_value;
    VkResult result = vkGetSemaphoreCounterValue(sync_manager->device,
                                                 sync_manager->timeline_semaphore, &current_value);
    if (result != VK_SUCCESS) {
        return result;
    }

    *reached = (current_value >= value);
    return VK_SUCCESS;
}

VkResult vulkan_sync_manager_get_timeline_stats(VulkanSyncManager* sync_manager,
                                                uint64_t* wait_count, uint64_t* signal_count,
                                                uint64_t* current_value) {
    if (!sync_manager || !sync_manager->initialized) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    if (wait_count) {
        *wait_count = atomic_load(&sync_manager->timeline_wait_count);
    }

    if (signal_count) {
        *signal_count = atomic_load(&sync_manager->timeline_signal_count);
    }

    if (current_value) {
        VkResult result = vkGetSemaphoreCounterValue(
            sync_manager->device, sync_manager->timeline_semaphore, current_value);
        if (result != VK_SUCCESS) {
            return result;
        }
    }

    return VK_SUCCESS;
}
