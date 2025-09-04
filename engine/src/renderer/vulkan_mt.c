#include "cardinal/renderer/vulkan_mt.h"
#include "cardinal/renderer/vulkan_barrier_validation.h"
#include "vulkan_state.h"
#include "cardinal/core/log.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <process.h>
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

// Global multi-threading subsystem instance
CardinalMTSubsystem g_cardinal_mt_subsystem = {0};

// === Platform-specific threading utilities ===

#ifdef _WIN32

bool cardinal_mt_mutex_init(cardinal_mutex_t* mutex) {
    InitializeCriticalSection(mutex);
    return true;
}

void cardinal_mt_mutex_destroy(cardinal_mutex_t* mutex) {
    DeleteCriticalSection(mutex);
}

void cardinal_mt_mutex_lock(cardinal_mutex_t* mutex) {
    EnterCriticalSection(mutex);
}

void cardinal_mt_mutex_unlock(cardinal_mutex_t* mutex) {
    LeaveCriticalSection(mutex);
}

bool cardinal_mt_cond_init(cardinal_cond_t* cond) {
    InitializeConditionVariable(cond);
    return true;
}

void cardinal_mt_cond_destroy(cardinal_cond_t* cond) {
    // No explicit cleanup needed for Windows condition variables
    (void)cond;
}

void cardinal_mt_cond_wait(cardinal_cond_t* cond, cardinal_mutex_t* mutex) {
    SleepConditionVariableCS(cond, mutex, INFINITE);
}

void cardinal_mt_cond_signal(cardinal_cond_t* cond) {
    WakeConditionVariable(cond);
}

void cardinal_mt_cond_broadcast(cardinal_cond_t* cond) {
    WakeAllConditionVariable(cond);
}

bool cardinal_mt_cond_wait_timeout(cardinal_cond_t* cond, cardinal_mutex_t* mutex, uint32_t timeout_ms) {
    return SleepConditionVariableCS(cond, mutex, timeout_ms) != 0;
}

cardinal_thread_t cardinal_mt_get_current_thread_id(void) {
    return GetCurrentThread();
}

bool cardinal_mt_thread_ids_equal(cardinal_thread_t thread1, cardinal_thread_t thread2) {
    return GetThreadId(thread1) == GetThreadId(thread2);
}

uint32_t cardinal_mt_get_optimal_thread_count(void) {
    SYSTEM_INFO sysinfo;
    GetSystemInfo(&sysinfo);
    return (uint32_t)sysinfo.dwNumberOfProcessors;
}

static unsigned __stdcall cardinal_mt_worker_thread_func(void* arg);

static bool cardinal_mt_create_thread(cardinal_thread_t* thread, void* arg) {
    *thread = (HANDLE)_beginthreadex(NULL, 0, cardinal_mt_worker_thread_func, arg, 0, NULL);
    return *thread != NULL;
}

static void cardinal_mt_join_thread(cardinal_thread_t thread) {
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
}

#else

bool cardinal_mt_mutex_init(cardinal_mutex_t* mutex) {
    return pthread_mutex_init(mutex, NULL) == 0;
}

void cardinal_mt_mutex_destroy(cardinal_mutex_t* mutex) {
    pthread_mutex_destroy(mutex);
}

void cardinal_mt_mutex_lock(cardinal_mutex_t* mutex) {
    pthread_mutex_lock(mutex);
}

void cardinal_mt_mutex_unlock(cardinal_mutex_t* mutex) {
    pthread_mutex_unlock(mutex);
}

bool cardinal_mt_cond_init(cardinal_cond_t* cond) {
    return pthread_cond_init(cond, NULL) == 0;
}

void cardinal_mt_cond_destroy(cardinal_cond_t* cond) {
    pthread_cond_destroy(cond);
}

void cardinal_mt_cond_wait(cardinal_cond_t* cond, cardinal_mutex_t* mutex) {
    pthread_cond_wait(cond, mutex);
}

void cardinal_mt_cond_signal(cardinal_cond_t* cond) {
    pthread_cond_signal(cond);
}

void cardinal_mt_cond_broadcast(cardinal_cond_t* cond) {
    pthread_cond_broadcast(cond);
}

bool cardinal_mt_cond_wait_timeout(cardinal_cond_t* cond, cardinal_mutex_t* mutex, uint32_t timeout_ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (timeout_ms % 1000) * 1000000;
    if (ts.tv_nsec >= 1000000000) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000;
    }
    return pthread_cond_timedwait(cond, mutex, &ts) == 0;
}

cardinal_thread_t cardinal_mt_get_current_thread_id(void) {
    return pthread_self();
}

bool cardinal_mt_thread_ids_equal(cardinal_thread_t thread1, cardinal_thread_t thread2) {
    return pthread_equal(thread1, thread2) != 0;
}

uint32_t cardinal_mt_get_optimal_thread_count(void) {
    long nprocs = sysconf(_SC_NPROCESSORS_ONLN);
    return (nprocs > 0) ? (uint32_t)nprocs : 4;
}

static void* cardinal_mt_worker_thread_func(void* arg);

static bool cardinal_mt_create_thread(cardinal_thread_t* thread, void* arg) {
    return pthread_create(thread, NULL, cardinal_mt_worker_thread_func, arg) == 0;
}

static void cardinal_mt_join_thread(cardinal_thread_t thread) {
    pthread_join(thread, NULL);
}

#endif

// === Task Queue Management ===

static bool cardinal_mt_task_queue_init(CardinalMTTaskQueue* queue) {
    if (!queue) return false;
    
    queue->head = NULL;
    queue->tail = NULL;
    queue->task_count = 0;
    
    if (!cardinal_mt_mutex_init(&queue->queue_mutex)) {
        return false;
    }
    
    if (!cardinal_mt_cond_init(&queue->queue_condition)) {
        cardinal_mt_mutex_destroy(&queue->queue_mutex);
        return false;
    }

    return true;
}


static void cardinal_mt_task_queue_shutdown(CardinalMTTaskQueue* queue) {
    if (!queue) return;
    
    cardinal_mt_mutex_lock(&queue->queue_mutex);
    
    // Free all remaining tasks
    CardinalMTTask* current = queue->head;
    while (current) {
        CardinalMTTask* next = current->next;
        free(current);
        current = next;
    }
    
    queue->head = NULL;
    queue->tail = NULL;
    queue->task_count = 0;
    
    cardinal_mt_mutex_unlock(&queue->queue_mutex);
    
    cardinal_mt_cond_destroy(&queue->queue_condition);
    cardinal_mt_mutex_destroy(&queue->queue_mutex);
}

static void cardinal_mt_task_queue_push(CardinalMTTaskQueue* queue, CardinalMTTask* task) {
    if (!queue || !task) return;
    
    cardinal_mt_mutex_lock(&queue->queue_mutex);
    
    task->next = NULL;
    
    if (queue->tail) {
        queue->tail->next = task;
    } else {
        queue->head = task;
    }
    
    queue->tail = task;
    queue->task_count++;
    
    cardinal_mt_cond_signal(&queue->queue_condition);
    cardinal_mt_mutex_unlock(&queue->queue_mutex);
}

static CardinalMTTask* cardinal_mt_task_queue_pop(CardinalMTTaskQueue* queue) {
    if (!queue) return NULL;
    
    cardinal_mt_mutex_lock(&queue->queue_mutex);
    
    while (!queue->head && g_cardinal_mt_subsystem.is_running) {
        cardinal_mt_cond_wait(&queue->queue_condition, &queue->queue_mutex);
    }
    
    CardinalMTTask* task = queue->head;
    if (task) {
        queue->head = task->next;
        if (!queue->head) {
            queue->tail = NULL;
        }
        queue->task_count--;
        task->next = NULL;
    }
    
    cardinal_mt_mutex_unlock(&queue->queue_mutex);
    return task;
}



static CardinalMTTask* cardinal_mt_task_queue_try_pop(CardinalMTTaskQueue* queue) {
    if (!queue) return NULL;
    
    cardinal_mt_mutex_lock(&queue->queue_mutex);
    
    CardinalMTTask* task = queue->head;
    if (task) {
        queue->head = task->next;
        if (!queue->head) {
            queue->tail = NULL;
        }
        queue->task_count--;
        task->next = NULL;
    }
    
    cardinal_mt_mutex_unlock(&queue->queue_mutex);
    return task;
}

// === Command Buffer Management ===

bool cardinal_mt_command_manager_init(CardinalMTCommandManager* manager, VulkanState* vulkan_state) {
    if (!manager || !vulkan_state) {
        CARDINAL_LOG_ERROR("[MT] Invalid parameters for command manager initialization");
        return false;
    }
    
    manager->vulkan_state = vulkan_state;
    manager->active_thread_count = 0;
    manager->is_initialized = false;
    
    if (!cardinal_mt_mutex_init(&manager->pool_mutex)) {
        CARDINAL_LOG_ERROR("[MT] Failed to initialize command manager mutex");
        return false;
    }
    
    // Initialize all thread pools as inactive
    for (uint32_t i = 0; i < CARDINAL_MAX_MT_THREADS; i++) {
        CardinalThreadCommandPool* pool = &manager->thread_pools[i];
        pool->primary_pool = VK_NULL_HANDLE;
        pool->secondary_pool = VK_NULL_HANDLE;
        pool->secondary_buffers = NULL;
        pool->secondary_buffer_count = 0;
        pool->next_secondary_index = 0;
        pool->is_active = false;
    }
    
    manager->is_initialized = true;
    CARDINAL_LOG_INFO("[MT] Command manager initialized successfully");
    return true;
}

void cardinal_mt_command_manager_shutdown(CardinalMTCommandManager* manager) {
    if (!manager || !manager->is_initialized) return;
    
    cardinal_mt_mutex_lock(&manager->pool_mutex);
    
    // Wait for device idle before destroying command pools
    if (manager->vulkan_state && manager->vulkan_state->device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(manager->vulkan_state->device);
    }
    
    // Destroy all thread command pools
    for (uint32_t i = 0; i < CARDINAL_MAX_MT_THREADS; i++) {
        CardinalThreadCommandPool* pool = &manager->thread_pools[i];
        if (pool->is_active) {
            if (pool->secondary_buffers) {
                free(pool->secondary_buffers);
                pool->secondary_buffers = NULL;
            }
            
            if (pool->secondary_pool != VK_NULL_HANDLE) {
                vkDestroyCommandPool(manager->vulkan_state->device, pool->secondary_pool, NULL);
                pool->secondary_pool = VK_NULL_HANDLE;
            }
            
            if (pool->primary_pool != VK_NULL_HANDLE) {
                vkDestroyCommandPool(manager->vulkan_state->device, pool->primary_pool, NULL);
                pool->primary_pool = VK_NULL_HANDLE;
            }
            
            pool->is_active = false;
        }
    }
    
    manager->active_thread_count = 0;
    manager->is_initialized = false;
    
    cardinal_mt_mutex_unlock(&manager->pool_mutex);
    cardinal_mt_mutex_destroy(&manager->pool_mutex);
    
    CARDINAL_LOG_INFO("[MT] Command manager shutdown completed");
}

CardinalThreadCommandPool* cardinal_mt_get_thread_command_pool(CardinalMTCommandManager* manager) {
    if (!manager || !manager->is_initialized) {
        CARDINAL_LOG_ERROR("[MT] Command manager not initialized");
        return NULL;
    }
    
    cardinal_thread_t current_thread = cardinal_mt_get_current_thread_id();
    
    cardinal_mt_mutex_lock(&manager->pool_mutex);
    
    // Check if this thread already has a command pool
    for (uint32_t i = 0; i < manager->active_thread_count; i++) {
        CardinalThreadCommandPool* pool = &manager->thread_pools[i];
        if (pool->is_active && cardinal_mt_thread_ids_equal(pool->thread_id, current_thread)) {
            cardinal_mt_mutex_unlock(&manager->pool_mutex);
            return pool;
        }
    }
    
    // Create a new command pool for this thread
    if (manager->active_thread_count >= CARDINAL_MAX_MT_THREADS) {
        CARDINAL_LOG_ERROR("[MT] Maximum number of thread command pools reached");
        cardinal_mt_mutex_unlock(&manager->pool_mutex);
        return NULL;
    }
    
    CardinalThreadCommandPool* pool = &manager->thread_pools[manager->active_thread_count];
    pool->thread_id = current_thread;
    
    // Create primary command pool
    VkCommandPoolCreateInfo primary_pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = manager->vulkan_state->graphics_queue_family
    };
    
    if (vkCreateCommandPool(manager->vulkan_state->device, &primary_pool_info, NULL, &pool->primary_pool) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[MT] Failed to create primary command pool for thread");
        cardinal_mt_mutex_unlock(&manager->pool_mutex);
        return NULL;
    }
    
    // Create secondary command pool
    VkCommandPoolCreateInfo secondary_pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = manager->vulkan_state->graphics_queue_family
    };
    
    if (vkCreateCommandPool(manager->vulkan_state->device, &secondary_pool_info, NULL, &pool->secondary_pool) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[MT] Failed to create secondary command pool for thread");
        vkDestroyCommandPool(manager->vulkan_state->device, pool->primary_pool, NULL);
        pool->primary_pool = VK_NULL_HANDLE;
        cardinal_mt_mutex_unlock(&manager->pool_mutex);
        return NULL;
    }
    
    // Allocate secondary command buffers
    pool->secondary_buffer_count = CARDINAL_MAX_SECONDARY_COMMAND_BUFFERS;
    pool->secondary_buffers = (VkCommandBuffer*)malloc(sizeof(VkCommandBuffer) * pool->secondary_buffer_count);
    if (!pool->secondary_buffers) {
        CARDINAL_LOG_ERROR("[MT] Failed to allocate memory for secondary command buffers");
        vkDestroyCommandPool(manager->vulkan_state->device, pool->secondary_pool, NULL);
        vkDestroyCommandPool(manager->vulkan_state->device, pool->primary_pool, NULL);
        pool->primary_pool = VK_NULL_HANDLE;
        pool->secondary_pool = VK_NULL_HANDLE;
        cardinal_mt_mutex_unlock(&manager->pool_mutex);
        return NULL;
    }
    
    VkCommandBufferAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool->secondary_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_SECONDARY,
        .commandBufferCount = pool->secondary_buffer_count
    };
    
    if (vkAllocateCommandBuffers(manager->vulkan_state->device, &alloc_info, pool->secondary_buffers) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[MT] Failed to allocate secondary command buffers");
        free(pool->secondary_buffers);
        pool->secondary_buffers = NULL;
        vkDestroyCommandPool(manager->vulkan_state->device, pool->secondary_pool, NULL);
        vkDestroyCommandPool(manager->vulkan_state->device, pool->primary_pool, NULL);
        pool->primary_pool = VK_NULL_HANDLE;
        pool->secondary_pool = VK_NULL_HANDLE;
        cardinal_mt_mutex_unlock(&manager->pool_mutex);
        return NULL;
    }
    
    pool->next_secondary_index = 0;
    pool->is_active = true;
    manager->active_thread_count++;
    
    CARDINAL_LOG_INFO("[MT] Created command pool for thread (total active: %u)", manager->active_thread_count);
    
    cardinal_mt_mutex_unlock(&manager->pool_mutex);
    return pool;
}

bool cardinal_mt_allocate_secondary_command_buffer(CardinalThreadCommandPool* pool, 
                                                   CardinalSecondaryCommandContext* context) {
    if (!pool || !context || !pool->is_active) {
        CARDINAL_LOG_ERROR("[MT] Invalid parameters for secondary command buffer allocation");
        return false;
    }
    
    // Note: This function should only be called by the thread that owns the pool
    // since each thread has its own command pool. However, we add a safety check.
    cardinal_thread_t current_thread = cardinal_mt_get_current_thread_id();
    if (!cardinal_mt_thread_ids_equal(pool->thread_id, current_thread)) {
        CARDINAL_LOG_ERROR("[MT] Attempting to allocate from command pool owned by different thread");
        return false;
    }
    
    if (pool->next_secondary_index >= pool->secondary_buffer_count) {
        CARDINAL_LOG_ERROR("[MT] No more secondary command buffers available in pool");
        return false;
    }
    
    context->command_buffer = pool->secondary_buffers[pool->next_secondary_index];
    context->thread_index = pool->next_secondary_index;
    context->is_recording = false;
    
    pool->next_secondary_index++;
    
    return true;
}

bool cardinal_mt_begin_secondary_command_buffer(CardinalSecondaryCommandContext* context,
                                                const VkCommandBufferInheritanceInfo* inheritance_info) {
    if (!context || context->is_recording) {
        CARDINAL_LOG_ERROR("[MT] Invalid context or already recording");
        return false;
    }
    
    context->inheritance = *inheritance_info;
    
    VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT,
        .pInheritanceInfo = &context->inheritance
    };
    
    if (vkBeginCommandBuffer(context->command_buffer, &begin_info) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[MT] Failed to begin secondary command buffer");
        return false;
    }
    
    context->is_recording = true;
    
    // Validate secondary command buffer recording
    if (!cardinal_barrier_validation_validate_secondary_recording(context)) {
        CARDINAL_LOG_WARN("[MT] Barrier validation failed for secondary command buffer");
    }
    
    return true;
}

bool cardinal_mt_end_secondary_command_buffer(CardinalSecondaryCommandContext* context) {
    if (!context || !context->is_recording) {
        CARDINAL_LOG_ERROR("[MT] Invalid context or not recording");
        return false;
    }
    
    if (vkEndCommandBuffer(context->command_buffer) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[MT] Failed to end secondary command buffer");
        return false;
    }
    
    context->is_recording = false;
    return true;
}

void cardinal_mt_execute_secondary_command_buffers(VkCommandBuffer primary_cmd,
                                                   CardinalSecondaryCommandContext* secondary_contexts,
                                                   uint32_t count) {
    if (!primary_cmd || !secondary_contexts || count == 0) {
        CARDINAL_LOG_ERROR("[MT] Invalid parameters for executing secondary command buffers");
        return;
    }
    
    VkCommandBuffer* secondary_buffers = (VkCommandBuffer*)malloc(sizeof(VkCommandBuffer) * count);
    if (!secondary_buffers) {
        CARDINAL_LOG_ERROR("[MT] Failed to allocate memory for secondary buffer array");
        return;
    }
    
    for (uint32_t i = 0; i < count; i++) {
        secondary_buffers[i] = secondary_contexts[i].command_buffer;
    }
    
    vkCmdExecuteCommands(primary_cmd, count, secondary_buffers);
    
    free(secondary_buffers);
}

// === Worker Thread Function ===

#ifdef _WIN32
static unsigned __stdcall cardinal_mt_worker_thread_func(void* arg) {
#else
static void* cardinal_mt_worker_thread_func(void* arg) {
#endif
    (void)arg; // Unused parameter
    
    CARDINAL_LOG_INFO("[MT] Worker thread started");
    
    while (g_cardinal_mt_subsystem.is_running) {
        CardinalMTTask* task = cardinal_mt_task_queue_pop(&g_cardinal_mt_subsystem.pending_queue);
        if (!task) continue;
        
        // Execute the task
        if (task->execute_func) {
            task->execute_func(task->data);
            task->success = true;
        } else {
            task->success = false;
        }
        
        task->is_completed = true;
        
        // Move task to completed queue
        cardinal_mt_task_queue_push(&g_cardinal_mt_subsystem.completed_queue, task);
    }
    
    CARDINAL_LOG_INFO("[MT] Worker thread exiting");
    
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

// === Multi-Threading Subsystem Functions ===

bool cardinal_mt_subsystem_init(VulkanState* vulkan_state, uint32_t worker_thread_count) {
    if (g_cardinal_mt_subsystem.is_running) {
        CARDINAL_LOG_WARN("[MT] Subsystem already initialized");
        return true;
    }
    
    if (!vulkan_state) {
        CARDINAL_LOG_ERROR("[MT] Invalid Vulkan state for subsystem initialization");
        return false;
    }
    
    // Clamp worker thread count
    if (worker_thread_count == 0) {
        worker_thread_count = cardinal_mt_get_optimal_thread_count();
    }
    if (worker_thread_count > CARDINAL_MAX_MT_THREADS) {
        worker_thread_count = CARDINAL_MAX_MT_THREADS;
    }
    
    memset(&g_cardinal_mt_subsystem, 0, sizeof(CardinalMTSubsystem));
    
    // Initialize command manager
    if (!cardinal_mt_command_manager_init(&g_cardinal_mt_subsystem.command_manager, vulkan_state)) {
        CARDINAL_LOG_ERROR("[MT] Failed to initialize command manager");
        return false;
    }
    
    // Initialize task queues
    if (!cardinal_mt_task_queue_init(&g_cardinal_mt_subsystem.pending_queue)) {
        CARDINAL_LOG_ERROR("[MT] Failed to initialize pending task queue");
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }
    
    if (!cardinal_mt_task_queue_init(&g_cardinal_mt_subsystem.completed_queue)) {
        CARDINAL_LOG_ERROR("[MT] Failed to initialize completed task queue");
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }
    
    // Initialize subsystem mutex
    if (!cardinal_mt_mutex_init(&g_cardinal_mt_subsystem.subsystem_mutex)) {
        CARDINAL_LOG_ERROR("[MT] Failed to initialize subsystem mutex");
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }
    
    g_cardinal_mt_subsystem.worker_thread_count = worker_thread_count;
    g_cardinal_mt_subsystem.is_running = true;
    
    // Create worker threads
    for (uint32_t i = 0; i < worker_thread_count; i++) {
        if (!cardinal_mt_create_thread(&g_cardinal_mt_subsystem.worker_threads[i], NULL)) {
            CARDINAL_LOG_ERROR("[MT] Failed to create worker thread %u", i);
            
            // Cleanup already created threads
            g_cardinal_mt_subsystem.is_running = false;
            cardinal_mt_cond_broadcast(&g_cardinal_mt_subsystem.pending_queue.queue_condition);
            
            for (uint32_t j = 0; j < i; j++) {
                cardinal_mt_join_thread(g_cardinal_mt_subsystem.worker_threads[j]);
            }
            
            cardinal_mt_mutex_destroy(&g_cardinal_mt_subsystem.subsystem_mutex);
            cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
            cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
            cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
            return false;
        }
    }
    
    CARDINAL_LOG_INFO("[MT] Subsystem initialized with %u worker threads", worker_thread_count);
    return true;
}

void cardinal_mt_subsystem_shutdown(void) {
    if (!g_cardinal_mt_subsystem.is_running) {
        return;
    }
    
    CARDINAL_LOG_INFO("[MT] Shutting down subsystem...");
    
    // Signal all threads to stop
    g_cardinal_mt_subsystem.is_running = false;
    cardinal_mt_cond_broadcast(&g_cardinal_mt_subsystem.pending_queue.queue_condition);
    
    // Wait for all worker threads to finish
    for (uint32_t i = 0; i < g_cardinal_mt_subsystem.worker_thread_count; i++) {
        cardinal_mt_join_thread(g_cardinal_mt_subsystem.worker_threads[i]);
    }
    
    // Cleanup resources
    cardinal_mt_mutex_destroy(&g_cardinal_mt_subsystem.subsystem_mutex);
    cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
    cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
    cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
    
    memset(&g_cardinal_mt_subsystem, 0, sizeof(CardinalMTSubsystem));
    
    CARDINAL_LOG_INFO("[MT] Subsystem shutdown completed");
}

bool cardinal_mt_submit_task(CardinalMTTask* task) {
    if (!task || !g_cardinal_mt_subsystem.is_running) {
        CARDINAL_LOG_ERROR("[MT] Invalid task or subsystem not running");
        return false;
    }
    
    cardinal_mt_task_queue_push(&g_cardinal_mt_subsystem.pending_queue, task);
    return true;
}

void cardinal_mt_process_completed_tasks(uint32_t max_tasks) {
    if (!g_cardinal_mt_subsystem.is_running) {
        return;
    }
    
    uint32_t processed = 0;
    
    while ((max_tasks == 0 || processed < max_tasks)) {
        CardinalMTTask* task = cardinal_mt_task_queue_try_pop(&g_cardinal_mt_subsystem.completed_queue);
        if (!task) break;
        
        // Execute callback if provided
        if (task->callback_func) {
            task->callback_func(task->data, task->success);
        }
        
        // Free the task
        free(task);
        processed++;
    }
}

// === Task Creation Functions ===

CardinalMTTask* cardinal_mt_create_texture_load_task(const char* file_path, 
                                                    void (*callback)(void* data, bool success)) {
    if (!file_path) {
        CARDINAL_LOG_ERROR("[MT] Invalid file path for texture load task");
        return NULL;
    }
    
    CardinalMTTask* task = (CardinalMTTask*)malloc(sizeof(CardinalMTTask));
    if (!task) {
        CARDINAL_LOG_ERROR("[MT] Failed to allocate memory for texture load task");
        return NULL;
    }
    
    // For now, just create a placeholder task
    // TODO: Implement actual texture loading logic
    task->type = CARDINAL_MT_TASK_TEXTURE_LOAD;
    task->data = malloc(strlen(file_path) + 1);
    if (task->data) {
        strcpy((char*)task->data, file_path);
    }
    task->execute_func = NULL; // TODO: Implement texture loading function
    task->callback_func = callback;
    task->is_completed = false;
    task->success = false;
    task->next = NULL;
    
    return task;
}

CardinalMTTask* cardinal_mt_create_mesh_load_task(const char* file_path,
                                                 void (*callback)(void* data, bool success)) {
    if (!file_path) {
        CARDINAL_LOG_ERROR("[MT] Invalid file path for mesh load task");
        return NULL;
    }
    
    CardinalMTTask* task = (CardinalMTTask*)malloc(sizeof(CardinalMTTask));
    if (!task) {
        CARDINAL_LOG_ERROR("[MT] Failed to allocate memory for mesh load task");
        return NULL;
    }
    
    // For now, just create a placeholder task
    // TODO: Implement actual mesh loading logic
    task->type = CARDINAL_MT_TASK_MESH_LOAD;
    task->data = malloc(strlen(file_path) + 1);
    if (task->data) {
        strcpy((char*)task->data, file_path);
    }
    task->execute_func = NULL; // TODO: Implement mesh loading function
    task->callback_func = callback;
    task->is_completed = false;
    task->success = false;
    task->next = NULL;
    
    return task;
}

CardinalMTTask* cardinal_mt_create_command_record_task(void (*record_func)(void* data),
                                                      void* user_data,
                                                      void (*callback)(void* data, bool success)) {
    if (!record_func) {
        CARDINAL_LOG_ERROR("[MT] Invalid record function for command record task");
        return NULL;
    }
    
    CardinalMTTask* task = (CardinalMTTask*)malloc(sizeof(CardinalMTTask));
    if (!task) {
        CARDINAL_LOG_ERROR("[MT] Failed to allocate memory for command record task");
        return NULL;
    }
    
    task->type = CARDINAL_MT_TASK_COMMAND_RECORD;
    task->data = user_data;
    task->execute_func = record_func;
    task->callback_func = callback;
    task->is_completed = false;
    task->success = false;
    task->next = NULL;
    
    return task;
}
