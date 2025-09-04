/**
 * @file vulkan_barrier_validation.c
 * @brief Implementation of memory barrier and synchronization validation
 */

#include "cardinal/renderer/vulkan_barrier_validation.h"
#include "cardinal/renderer/vulkan_mt.h"
#include "cardinal/core/log.h"
#include "cardinal/core/memory.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#include <sys/syscall.h>
#endif

// Global validation context
static CardinalBarrierValidationContext g_validation_context = {0};
static bool g_validation_initialized = false;

// Statistics
static uint32_t g_total_accesses = 0;
static uint32_t g_validation_errors = 0;
static uint32_t g_race_conditions = 0;

// Thread-safe access mutex
#ifdef _WIN32
static CRITICAL_SECTION g_validation_mutex;
#else
static pthread_mutex_t g_validation_mutex = PTHREAD_MUTEX_INITIALIZER;
#endif

// === Platform-specific utilities ===

static uint32_t get_current_thread_id(void) {
#ifdef _WIN32
    return GetCurrentThreadId();
#else
    return (uint32_t)syscall(SYS_gettid);
#endif
}

static uint64_t get_timestamp(void) {
#ifdef _WIN32
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    return (uint64_t)counter.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
#endif
}

static void lock_validation_mutex(void) {
#ifdef _WIN32
    EnterCriticalSection(&g_validation_mutex);
#else
    pthread_mutex_lock(&g_validation_mutex);
#endif
}

static void unlock_validation_mutex(void) {
#ifdef _WIN32
    LeaveCriticalSection(&g_validation_mutex);
#else
    pthread_mutex_unlock(&g_validation_mutex);
#endif
}

// === Implementation ===

bool cardinal_barrier_validation_init(uint32_t max_tracked_accesses, bool strict_mode) {
    if (g_validation_initialized) {
        CARDINAL_LOG_WARN("[BARRIER_VALIDATION] Already initialized");
        return true;
    }

#ifdef _WIN32
    InitializeCriticalSection(&g_validation_mutex);
#endif

    CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    
    g_validation_context.resource_accesses = cardinal_alloc(allocator, 
        sizeof(CardinalResourceAccess) * max_tracked_accesses);
    if (!g_validation_context.resource_accesses) {
        CARDINAL_LOG_ERROR("[BARRIER_VALIDATION] Failed to allocate memory for resource tracking");
        return false;
    }

    g_validation_context.access_count = 0;
    g_validation_context.max_accesses = max_tracked_accesses;
    g_validation_context.validation_enabled = true;
    g_validation_context.strict_mode = strict_mode;

    // Reset statistics
    g_total_accesses = 0;
    g_validation_errors = 0;
    g_race_conditions = 0;

    g_validation_initialized = true;
    
    CARDINAL_LOG_INFO("[BARRIER_VALIDATION] Initialized with %u max accesses, strict_mode=%s",
                      max_tracked_accesses, strict_mode ? "true" : "false");
    return true;
}

void cardinal_barrier_validation_shutdown(void) {
    if (!g_validation_initialized) {
        return;
    }

    lock_validation_mutex();
    
    if (g_validation_context.resource_accesses) {
        CardinalAllocator* allocator = cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
        cardinal_free(allocator, g_validation_context.resource_accesses);
        g_validation_context.resource_accesses = NULL;
    }

    g_validation_context.access_count = 0;
    g_validation_context.max_accesses = 0;
    g_validation_context.validation_enabled = false;
    
    unlock_validation_mutex();

#ifdef _WIN32
    DeleteCriticalSection(&g_validation_mutex);
#endif

    g_validation_initialized = false;
    
    CARDINAL_LOG_INFO("[BARRIER_VALIDATION] Shutdown complete. Stats: %u accesses, %u errors, %u race conditions",
                      g_total_accesses, g_validation_errors, g_race_conditions);
}

void cardinal_barrier_validation_set_enabled(bool enabled) {
    if (!g_validation_initialized) {
        return;
    }

    lock_validation_mutex();
    g_validation_context.validation_enabled = enabled;
    unlock_validation_mutex();
    
    CARDINAL_LOG_DEBUG("[BARRIER_VALIDATION] Validation %s", enabled ? "enabled" : "disabled");
}

bool cardinal_barrier_validation_track_access(uint64_t resource_id,
                                               CardinalResourceType resource_type,
                                               CardinalResourceAccessType access_type,
                                               VkPipelineStageFlags2 stage_mask,
                                               VkAccessFlags2 access_mask,
                                               uint32_t thread_id,
                                               VkCommandBuffer command_buffer) {
    if (!g_validation_initialized || !g_validation_context.validation_enabled) {
        return true;
    }

    lock_validation_mutex();
    
    // Check if we have space for more accesses
    if (g_validation_context.access_count >= g_validation_context.max_accesses) {
        // In non-strict mode, just overwrite the oldest entry
        if (!g_validation_context.strict_mode) {
            g_validation_context.access_count = 0;
        } else {
            unlock_validation_mutex();
            CARDINAL_LOG_ERROR("[BARRIER_VALIDATION] Maximum tracked accesses exceeded");
            g_validation_errors++;
            return false;
        }
    }

    // Check for potential race conditions with existing accesses
    for (uint32_t i = 0; i < g_validation_context.access_count; i++) {
        CardinalResourceAccess* existing = &g_validation_context.resource_accesses[i];
        
        if (existing->resource_id == resource_id && existing->thread_id != thread_id) {
            // Different threads accessing the same resource
            if (access_type == CARDINAL_ACCESS_WRITE || existing->access_type == CARDINAL_ACCESS_WRITE) {
                CARDINAL_LOG_WARN("[BARRIER_VALIDATION] Potential race condition detected: "
                                  "Resource 0x%llx accessed by threads %u and %u",
                                  (unsigned long long)resource_id, existing->thread_id, thread_id);
                g_race_conditions++;
            }
        }
    }

    // Record the access
    CardinalResourceAccess* access = &g_validation_context.resource_accesses[g_validation_context.access_count];
    access->resource_id = resource_id;
    access->resource_type = resource_type;
    access->access_type = access_type;
    access->stage_mask = stage_mask;
    access->access_mask = access_mask;
    access->thread_id = thread_id;
    access->timestamp = get_timestamp();
    access->command_buffer = command_buffer;

    g_validation_context.access_count++;
    g_total_accesses++;
    
    unlock_validation_mutex();
    return true;
}

bool cardinal_barrier_validation_validate_memory_barrier(const VkMemoryBarrier2* barrier,
                                                          VkCommandBuffer command_buffer,
                                                          uint32_t thread_id) {
    if (!g_validation_initialized || !g_validation_context.validation_enabled || !barrier) {
        return true;
    }

    bool valid = true;

    // Check for valid stage masks
    if (barrier->srcStageMask == 0 || barrier->dstStageMask == 0) {
        CARDINAL_LOG_ERROR("[BARRIER_VALIDATION] Invalid stage mask in memory barrier (thread %u)", thread_id);
        g_validation_errors++;
        valid = false;
    }

    // Check for proper access mask alignment with stage masks
    if ((barrier->srcAccessMask & VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT) &&
        !(barrier->srcStageMask & VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT)) {
        CARDINAL_LOG_WARN("[BARRIER_VALIDATION] Access mask mismatch with stage mask (thread %u)", thread_id);
    }

    CARDINAL_LOG_DEBUG("[BARRIER_VALIDATION] Memory barrier validated (thread %u, cmd %p)", 
                       thread_id, (void*)command_buffer);
    return valid;
}

bool cardinal_barrier_validation_validate_buffer_barrier(const VkBufferMemoryBarrier2* barrier,
                                                          VkCommandBuffer command_buffer,
                                                          uint32_t thread_id) {
    if (!g_validation_initialized || !g_validation_context.validation_enabled || !barrier) {
        return true;
    }

    bool valid = true;
    uint64_t buffer_id = (uint64_t)(uintptr_t)barrier->buffer;

    // Track this buffer access
    CardinalResourceAccessType access_type = CARDINAL_ACCESS_READ_WRITE;
    if (barrier->srcAccessMask & (VK_ACCESS_2_SHADER_WRITE_BIT | VK_ACCESS_2_TRANSFER_WRITE_BIT)) {
        access_type = CARDINAL_ACCESS_WRITE;
    } else if (barrier->srcAccessMask & (VK_ACCESS_2_SHADER_READ_BIT | VK_ACCESS_2_TRANSFER_READ_BIT)) {
        access_type = CARDINAL_ACCESS_READ;
    }

    cardinal_barrier_validation_track_access(buffer_id, CARDINAL_RESOURCE_BUFFER, access_type,
                                              barrier->srcStageMask, barrier->srcAccessMask,
                                              thread_id, command_buffer);

    // Validate queue family indices
    if (barrier->srcQueueFamilyIndex != barrier->dstQueueFamilyIndex &&
        (barrier->srcQueueFamilyIndex == VK_QUEUE_FAMILY_IGNORED ||
         barrier->dstQueueFamilyIndex == VK_QUEUE_FAMILY_IGNORED)) {
        CARDINAL_LOG_WARN("[BARRIER_VALIDATION] Inconsistent queue family indices in buffer barrier (thread %u)", thread_id);
    }

    CARDINAL_LOG_DEBUG("[BARRIER_VALIDATION] Buffer barrier validated (thread %u, buffer 0x%llx)", 
                       thread_id, (unsigned long long)buffer_id);
    return valid;
}

bool cardinal_barrier_validation_validate_image_barrier(const VkImageMemoryBarrier2* barrier,
                                                         VkCommandBuffer command_buffer,
                                                         uint32_t thread_id) {
    if (!g_validation_initialized || !g_validation_context.validation_enabled || !barrier) {
        return true;
    }

    bool valid = true;
    uint64_t image_id = (uint64_t)(uintptr_t)barrier->image;

    // Track this image access
    CardinalResourceAccessType access_type = CARDINAL_ACCESS_READ_WRITE;
    if (barrier->srcAccessMask & (VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)) {
        access_type = CARDINAL_ACCESS_WRITE;
    } else if (barrier->srcAccessMask & (VK_ACCESS_2_SHADER_READ_BIT | VK_ACCESS_2_INPUT_ATTACHMENT_READ_BIT)) {
        access_type = CARDINAL_ACCESS_READ;
    }

    cardinal_barrier_validation_track_access(image_id, CARDINAL_RESOURCE_IMAGE, access_type,
                                              barrier->srcStageMask, barrier->srcAccessMask,
                                              thread_id, command_buffer);

    // Validate layout transitions
    if (barrier->oldLayout == barrier->newLayout && barrier->oldLayout != VK_IMAGE_LAYOUT_GENERAL) {
        CARDINAL_LOG_WARN("[BARRIER_VALIDATION] Unnecessary layout transition (thread %u, image 0x%llx)", 
                          thread_id, (unsigned long long)image_id);
    }

    // Check for invalid layout transitions
    if (barrier->oldLayout == VK_IMAGE_LAYOUT_UNDEFINED && 
        barrier->newLayout != VK_IMAGE_LAYOUT_PREINITIALIZED &&
        barrier->srcAccessMask != 0) {
        CARDINAL_LOG_ERROR("[BARRIER_VALIDATION] Invalid src access mask for UNDEFINED layout (thread %u)", thread_id);
        g_validation_errors++;
        valid = false;
    }

    CARDINAL_LOG_DEBUG("[BARRIER_VALIDATION] Image barrier validated (thread %u, image 0x%llx)", 
                       thread_id, (unsigned long long)image_id);
    return valid;
}

bool cardinal_barrier_validation_validate_pipeline_barrier(const VkDependencyInfo* dependency_info,
                                                            VkCommandBuffer command_buffer,
                                                            uint32_t thread_id) {
    if (!g_validation_initialized || !g_validation_context.validation_enabled || !dependency_info) {
        return true;
    }

    bool valid = true;

    // Validate memory barriers
    for (uint32_t i = 0; i < dependency_info->memoryBarrierCount; i++) {
        if (!cardinal_barrier_validation_validate_memory_barrier(&dependency_info->pMemoryBarriers[i],
                                                                  command_buffer, thread_id)) {
            valid = false;
        }
    }

    // Validate buffer barriers
    for (uint32_t i = 0; i < dependency_info->bufferMemoryBarrierCount; i++) {
        if (!cardinal_barrier_validation_validate_buffer_barrier(&dependency_info->pBufferMemoryBarriers[i],
                                                                  command_buffer, thread_id)) {
            valid = false;
        }
    }

    // Validate image barriers
    for (uint32_t i = 0; i < dependency_info->imageMemoryBarrierCount; i++) {
        if (!cardinal_barrier_validation_validate_image_barrier(&dependency_info->pImageMemoryBarriers[i],
                                                                 command_buffer, thread_id)) {
            valid = false;
        }
    }

    CARDINAL_LOG_DEBUG("[BARRIER_VALIDATION] Pipeline barrier validated (thread %u, cmd %p): %u memory, %u buffer, %u image barriers",
                       thread_id, (void*)command_buffer,
                       dependency_info->memoryBarrierCount,
                       dependency_info->bufferMemoryBarrierCount,
                       dependency_info->imageMemoryBarrierCount);
    return valid;
}

bool cardinal_barrier_validation_validate_secondary_recording(const CardinalSecondaryCommandContext* context) {
    if (!g_validation_initialized || !g_validation_context.validation_enabled || !context) {
        return true;
    }

    if (!context->is_recording) {
        CARDINAL_LOG_ERROR("[BARRIER_VALIDATION] Attempting to validate non-recording secondary command buffer");
        g_validation_errors++;
        return false;
    }

    uint32_t thread_id = get_current_thread_id();
    
    // Track command buffer usage
    uint64_t cmd_buffer_id = (uint64_t)(uintptr_t)context->command_buffer;
    cardinal_barrier_validation_track_access(cmd_buffer_id, CARDINAL_RESOURCE_DESCRIPTOR_SET, CARDINAL_ACCESS_WRITE,
                                              VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT,
                                              thread_id, context->command_buffer);

    CARDINAL_LOG_DEBUG("[BARRIER_VALIDATION] Secondary command buffer recording validated (thread %u)", thread_id);
    return true;
}

bool cardinal_barrier_validation_check_race_condition(uint32_t thread_id1, uint32_t thread_id2) {
    if (!g_validation_initialized || !g_validation_context.validation_enabled) {
        return false;
    }

    lock_validation_mutex();
    
    bool race_detected = false;
    
    // Look for resources accessed by both threads
    for (uint32_t i = 0; i < g_validation_context.access_count; i++) {
        CardinalResourceAccess* access1 = &g_validation_context.resource_accesses[i];
        if (access1->thread_id != thread_id1) continue;
        
        for (uint32_t j = i + 1; j < g_validation_context.access_count; j++) {
            CardinalResourceAccess* access2 = &g_validation_context.resource_accesses[j];
            if (access2->thread_id != thread_id2) continue;
            
            if (access1->resource_id == access2->resource_id &&
                (access1->access_type == CARDINAL_ACCESS_WRITE || access2->access_type == CARDINAL_ACCESS_WRITE)) {
                CARDINAL_LOG_WARN("[BARRIER_VALIDATION] Race condition detected between threads %u and %u on resource 0x%llx",
                                  thread_id1, thread_id2, (unsigned long long)access1->resource_id);
                race_detected = true;
                g_race_conditions++;
            }
        }
    }
    
    unlock_validation_mutex();
    return race_detected;
}

void cardinal_barrier_validation_get_stats(uint32_t* out_total_accesses,
                                            uint32_t* out_validation_errors,
                                            uint32_t* out_race_conditions) {
    if (out_total_accesses) *out_total_accesses = g_total_accesses;
    if (out_validation_errors) *out_validation_errors = g_validation_errors;
    if (out_race_conditions) *out_race_conditions = g_race_conditions;
}

void cardinal_barrier_validation_clear_accesses(void) {
    if (!g_validation_initialized) {
        return;
    }

    lock_validation_mutex();
    g_validation_context.access_count = 0;
    unlock_validation_mutex();
    
    CARDINAL_LOG_DEBUG("[BARRIER_VALIDATION] Cleared all tracked accesses");
}