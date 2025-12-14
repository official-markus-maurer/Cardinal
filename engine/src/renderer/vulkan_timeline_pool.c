/**
 * @file vulkan_timeline_pool.c
 * @brief Timeline semaphore pooling system implementation
 *
 * This file implements a pooling system for timeline semaphores to reduce
 * creation/destruction overhead and improve performance.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include <cardinal/core/log.h>
#include <cardinal/renderer/vulkan_timeline_pool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
    #include <windows.h>
    #define POOL_MUTEX CRITICAL_SECTION
    #define pool_mutex_init(m) InitializeCriticalSection((CRITICAL_SECTION*)(m))
    #define pool_mutex_destroy(m) DeleteCriticalSection((CRITICAL_SECTION*)(m))
    #define pool_mutex_lock(m) EnterCriticalSection((CRITICAL_SECTION*)(m))
    #define pool_mutex_unlock(m) LeaveCriticalSection((CRITICAL_SECTION*)(m))
#else
    #include <pthread.h>
    #define POOL_MUTEX pthread_mutex_t
    #define pool_mutex_init(m) pthread_mutex_init((pthread_mutex_t*)(m), NULL)
    #define pool_mutex_destroy(m) pthread_mutex_destroy((pthread_mutex_t*)(m))
    #define pool_mutex_lock(m) pthread_mutex_lock((pthread_mutex_t*)(m))
    #define pool_mutex_unlock(m) pthread_mutex_unlock((pthread_mutex_t*)(m))
#endif

// Helper function to get current time in nanoseconds
static uint64_t get_current_time_ns(void) {
#ifdef _WIN32
    LARGE_INTEGER frequency, counter;
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&counter);
    return (uint64_t)((counter.QuadPart * 1000000000ULL) / frequency.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)(ts.tv_sec * 1000000000ULL + ts.tv_nsec);
#endif
}

// Helper function to create a timeline semaphore
static bool create_timeline_semaphore(VkDevice device, VkSemaphore* semaphore) {
    VkSemaphoreTypeCreateInfo timeline_info = {.sType =
                                                   VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
                                               .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
                                               .initialValue = 0};

    VkSemaphoreCreateInfo create_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                                         .pNext = &timeline_info};

    VkResult result = vkCreateSemaphore(device, &create_info, NULL, semaphore);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[TIMELINE_POOL] Failed to create timeline semaphore: %d", result);
        return false;
    }

    return true;
}

bool vulkan_timeline_pool_init(VulkanTimelinePool* pool, VkDevice device, uint32_t initial_size,
                               uint32_t max_size) {
    if (!pool || !device || initial_size == 0) {
        return false;
    }

    memset(pool, 0, sizeof(VulkanTimelinePool));

    pool->device = device;
    pool->pool_size = 0;
    pool->max_pool_size = max_size > 0 ? max_size : UINT32_MAX;
    atomic_store(&pool->active_count, 0);

    // Allocate entries array
    pool->entries =
        (VulkanTimelinePoolEntry*)calloc(pool->max_pool_size, sizeof(VulkanTimelinePoolEntry));
    if (!pool->entries) {
        CARDINAL_LOG_ERROR("[TIMELINE_POOL] Failed to allocate pool entries");
        return false;
    }

    // Initialize mutex
    pool->mutex = malloc(sizeof(POOL_MUTEX));
    if (!pool->mutex) {
        CARDINAL_LOG_ERROR("[TIMELINE_POOL] Failed to allocate mutex");
        free(pool->entries);
        return false;
    }
    pool_mutex_init(pool->mutex);

    // Initialize statistics
    atomic_store(&pool->allocations, 0);
    atomic_store(&pool->deallocations, 0);
    atomic_store(&pool->cache_hits, 0);
    atomic_store(&pool->cache_misses, 0);

    // Default configuration
    pool->max_idle_time_ns = 5000000000ULL; // 5 seconds
    pool->auto_cleanup_enabled = true;

    // Pre-allocate initial semaphores
    uint64_t current_time = get_current_time_ns();
    for (uint32_t i = 0; i < initial_size && i < pool->max_pool_size; i++) {
        if (create_timeline_semaphore(device, &pool->entries[i].semaphore)) {
            pool->entries[i].last_signaled_value = 0;
            pool->entries[i].in_use = false;
            pool->entries[i].creation_time = current_time;
            pool->pool_size++;
        } else {
            CARDINAL_LOG_WARN("[TIMELINE_POOL] Failed to pre-allocate semaphore %u", i);
            break;
        }
    }

    pool->initialized = true;
    CARDINAL_LOG_INFO("[TIMELINE_POOL] Initialized with %u/%u semaphores (max: %u)",
                      pool->pool_size, initial_size, pool->max_pool_size);

    return true;
}

void vulkan_timeline_pool_destroy(VulkanTimelinePool* pool) {
    if (!pool || !pool->initialized) {
        return;
    }

    pool_mutex_lock(pool->mutex);

    // Destroy all semaphores
    for (uint32_t i = 0; i < pool->pool_size; i++) {
        if (pool->entries[i].semaphore != VK_NULL_HANDLE) {
            vkDestroySemaphore(pool->device, pool->entries[i].semaphore, NULL);
        }
    }

    pool_mutex_unlock(pool->mutex);

    // Cleanup resources
    pool_mutex_destroy(pool->mutex);
    free(pool->mutex);
    free(pool->entries);

    memset(pool, 0, sizeof(VulkanTimelinePool));

    CARDINAL_LOG_INFO("[TIMELINE_POOL] Destroyed");
}

bool vulkan_timeline_pool_allocate(VulkanTimelinePool* pool,
                                   VulkanTimelinePoolAllocation* allocation) {
    if (!pool || !pool->initialized || !allocation) {
        return false;
    }

    pool_mutex_lock(pool->mutex);

    // Try to find an unused semaphore
    for (uint32_t i = 0; i < pool->pool_size; i++) {
        if (!pool->entries[i].in_use && pool->entries[i].semaphore != VK_NULL_HANDLE) {
            pool->entries[i].in_use = true;
            allocation->semaphore = pool->entries[i].semaphore;
            allocation->pool_index = i;
            allocation->from_cache = true;

            atomic_fetch_add(&pool->active_count, 1);
            atomic_fetch_add(&pool->allocations, 1);
            atomic_fetch_add(&pool->cache_hits, 1);

            pool_mutex_unlock(pool->mutex);
            return true;
        }
    }

    // No free semaphore found, create new one if possible
    if (pool->pool_size < pool->max_pool_size) {
        uint32_t new_index = pool->pool_size;
        if (create_timeline_semaphore(pool->device, &pool->entries[new_index].semaphore)) {
            pool->entries[new_index].last_signaled_value = 0;
            pool->entries[new_index].in_use = true;
            pool->entries[new_index].creation_time = get_current_time_ns();

            allocation->semaphore = pool->entries[new_index].semaphore;
            allocation->pool_index = new_index;
            allocation->from_cache = false;

            pool->pool_size++;
            atomic_fetch_add(&pool->active_count, 1);
            atomic_fetch_add(&pool->allocations, 1);
            atomic_fetch_add(&pool->cache_misses, 1);

            pool_mutex_unlock(pool->mutex);
            return true;
        }
    }

    pool_mutex_unlock(pool->mutex);

    CARDINAL_LOG_ERROR("[TIMELINE_POOL] Failed to allocate semaphore (pool full: %u/%u)",
                       pool->pool_size, pool->max_pool_size);
    return false;
}

void vulkan_timeline_pool_deallocate(VulkanTimelinePool* pool, uint32_t pool_index,
                                     uint64_t last_value) {
    if (!pool || !pool->initialized || pool_index >= pool->pool_size) {
        return;
    }

    pool_mutex_lock(pool->mutex);

    if (pool->entries[pool_index].in_use) {
        pool->entries[pool_index].in_use = false;
        pool->entries[pool_index].last_signaled_value = last_value;

        atomic_fetch_sub(&pool->active_count, 1);
        atomic_fetch_add(&pool->deallocations, 1);
    }

    pool_mutex_unlock(pool->mutex);
}

uint32_t vulkan_timeline_pool_cleanup_idle(VulkanTimelinePool* pool, uint64_t current_time_ns) {
    if (!pool || !pool->initialized) {
        return 0;
    }

    pool_mutex_lock(pool->mutex);

    uint32_t cleaned_up = 0;

    // Only cleanup if auto-cleanup is enabled
    if (pool->auto_cleanup_enabled) {
        for (uint32_t i = 0; i < pool->pool_size; i++) {
            if (!pool->entries[i].in_use && pool->entries[i].semaphore != VK_NULL_HANDLE &&
                (current_time_ns - pool->entries[i].creation_time) > pool->max_idle_time_ns) {
                vkDestroySemaphore(pool->device, pool->entries[i].semaphore, NULL);
                pool->entries[i].semaphore = VK_NULL_HANDLE;
                cleaned_up++;
            }
        }
    }

    pool_mutex_unlock(pool->mutex);

    if (cleaned_up > 0) {
        CARDINAL_LOG_DEBUG("[TIMELINE_POOL] Cleaned up %u idle semaphores", cleaned_up);
    }

    return cleaned_up;
}

bool vulkan_timeline_pool_get_stats(VulkanTimelinePool* pool, uint32_t* active_count,
                                    uint64_t* total_allocations, float* cache_hit_rate) {
    if (!pool || !pool->initialized) {
        return false;
    }

    if (active_count) {
        *active_count = atomic_load(&pool->active_count);
    }

    if (total_allocations) {
        *total_allocations = atomic_load(&pool->allocations);
    }

    if (cache_hit_rate) {
        uint64_t hits = atomic_load(&pool->cache_hits);
        uint64_t total = atomic_load(&pool->allocations);
        *cache_hit_rate = total > 0 ? (float)hits / (float)total : 0.0f;
    }

    return true;
}

void vulkan_timeline_pool_configure_cleanup(VulkanTimelinePool* pool, bool enabled,
                                            uint64_t max_idle_time_ns) {
    if (!pool || !pool->initialized) {
        return;
    }

    pool_mutex_lock(pool->mutex);
    pool->auto_cleanup_enabled = enabled;
    pool->max_idle_time_ns = max_idle_time_ns;
    pool_mutex_unlock(pool->mutex);

    CARDINAL_LOG_INFO("[TIMELINE_POOL] Auto-cleanup %s, max idle time: %llu ns",
                      enabled ? "enabled" : "disabled", max_idle_time_ns);
}

void vulkan_timeline_pool_reset_stats(VulkanTimelinePool* pool) {
    if (!pool || !pool->initialized) {
        return;
    }

    atomic_store(&pool->allocations, 0);
    atomic_store(&pool->deallocations, 0);
    atomic_store(&pool->cache_hits, 0);
    atomic_store(&pool->cache_misses, 0);

    CARDINAL_LOG_INFO("[TIMELINE_POOL] Statistics reset");
}
