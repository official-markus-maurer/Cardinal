/**
 * @file async_loader.c
 * @brief Implementation of asynchronous loading system for Cardinal Engine
 */

#include "cardinal/core/async_loader.h"
#include "cardinal/assets/loader.h"
#include "cardinal/assets/texture_loader.h"
#include "cardinal/core/log.h"
#include "cardinal/core/memory.h"
#include "cardinal/core/ref_counting.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
    #include <process.h>
    #include <windows.h>
#else
    #include <pthread.h>
    #include <sys/time.h>
    #include <unistd.h>
#endif

// =============================================================================
// Internal Structures
// =============================================================================

/**
 * @brief Thread-safe task queue
 */
typedef struct {
    CardinalAsyncTask* head;
    CardinalAsyncTask* tail;
    uint32_t count;
    uint32_t max_size;

#ifdef _WIN32
    CRITICAL_SECTION mutex;
    CONDITION_VARIABLE condition;
#else
    pthread_mutex_t mutex;
    pthread_cond_t condition;
#endif
} TaskQueue;

/**
 * @brief Worker thread data
 */
typedef struct {
    uint32_t thread_id;
    bool should_exit;

#ifdef _WIN32
    HANDLE thread_handle;
#else
    pthread_t thread_handle;
#endif
} WorkerThread;

/**
 * @brief Async loader state
 */
typedef struct {
    bool initialized;
    bool shutting_down;

    // Configuration
    CardinalAsyncLoaderConfig config;

    // Task queues
    TaskQueue pending_queue;
    TaskQueue completed_queue;

    // Worker threads
    WorkerThread* workers;
    uint32_t worker_count;

    // Task management
    uint32_t next_task_id;

#ifdef _WIN32
    CRITICAL_SECTION state_mutex;
#else
    pthread_mutex_t state_mutex;
#endif
} AsyncLoaderState;

static AsyncLoaderState g_async_loader = {0};

// =============================================================================
// Platform-specific Threading
// =============================================================================

#ifdef _WIN32

static void mutex_init(CRITICAL_SECTION* mutex) {
    InitializeCriticalSection(mutex);
}

static void mutex_destroy(CRITICAL_SECTION* mutex) {
    DeleteCriticalSection(mutex);
}

static void mutex_lock(CRITICAL_SECTION* mutex) {
    EnterCriticalSection(mutex);
}

static void mutex_unlock(CRITICAL_SECTION* mutex) {
    LeaveCriticalSection(mutex);
}

static void condition_init(CONDITION_VARIABLE* cond) {
    InitializeConditionVariable(cond);
}

static void condition_destroy(CONDITION_VARIABLE* cond) {
    // No cleanup needed on Windows
    (void)cond;
}

static void condition_wait(CONDITION_VARIABLE* cond, CRITICAL_SECTION* mutex) {
    SleepConditionVariableCS(cond, mutex, INFINITE);
}

static void condition_signal(CONDITION_VARIABLE* cond) {
    WakeConditionVariable(cond);
}

static uint32_t get_cpu_count(void) {
    SYSTEM_INFO sysinfo;
    GetSystemInfo(&sysinfo);
    return sysinfo.dwNumberOfProcessors;
}

static uint64_t get_timestamp_ms(void) {
    return GetTickCount64();
}

#else

static void mutex_init(pthread_mutex_t* mutex) {
    pthread_mutex_init(mutex, NULL);
}

static void mutex_destroy(pthread_mutex_t* mutex) {
    pthread_mutex_destroy(mutex);
}

static void mutex_lock(pthread_mutex_t* mutex) {
    pthread_mutex_lock(mutex);
}

static void mutex_unlock(pthread_mutex_t* mutex) {
    pthread_mutex_unlock(mutex);
}

static void condition_init(pthread_cond_t* cond) {
    pthread_cond_init(cond, NULL);
}

static void condition_destroy(pthread_cond_t* cond) {
    pthread_cond_destroy(cond);
}

static void condition_wait(pthread_cond_t* cond, pthread_mutex_t* mutex) {
    pthread_cond_wait(cond, mutex);
}

static void condition_signal(pthread_cond_t* cond) {
    pthread_cond_signal(cond);
}

static uint32_t get_cpu_count(void) {
    return sysconf(_SC_NPROCESSORS_ONLN);
}

static uint64_t get_timestamp_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

#endif

// =============================================================================
// Task Queue Implementation
// =============================================================================

static bool task_queue_init(TaskQueue* queue, uint32_t max_size) {
    if (!queue)
        return false;

    memset(queue, 0, sizeof(TaskQueue));
    queue->max_size = max_size;

    mutex_init(&queue->mutex);
    condition_init(&queue->condition);

    return true;
}

static void task_queue_destroy(TaskQueue* queue) {
    if (!queue)
        return;

    mutex_lock(&queue->mutex);

    // Free remaining tasks
    CardinalAsyncTask* task = queue->head;
    while (task) {
        CardinalAsyncTask* next = task->next;
        cardinal_async_free_task(task);
        task = next;
    }

    mutex_unlock(&queue->mutex);

    condition_destroy(&queue->condition);
    mutex_destroy(&queue->mutex);

    memset(queue, 0, sizeof(TaskQueue));
}

static bool task_queue_push(TaskQueue* queue, CardinalAsyncTask* task) {
    if (!queue || !task)
        return false;

    mutex_lock(&queue->mutex);

    // Check queue size limit
    if (queue->max_size > 0 && queue->count >= queue->max_size) {
        mutex_unlock(&queue->mutex);
        return false;
    }

    task->next = NULL;

    if (queue->tail) {
        queue->tail->next = task;
    } else {
        queue->head = task;
    }
    queue->tail = task;
    queue->count++;

    condition_signal(&queue->condition);
    mutex_unlock(&queue->mutex);

    return true;
}

static CardinalAsyncTask* task_queue_pop(TaskQueue* queue, bool wait) {
    if (!queue)
        return NULL;

    mutex_lock(&queue->mutex);

    while (!queue->head && wait && !g_async_loader.shutting_down) {
        condition_wait(&queue->condition, &queue->mutex);
    }

    CardinalAsyncTask* task = queue->head;
    if (task) {
        queue->head = task->next;
        if (!queue->head) {
            queue->tail = NULL;
        }
        queue->count--;
        task->next = NULL;
    }

    mutex_unlock(&queue->mutex);

    return task;
}

static uint32_t task_queue_size(TaskQueue* queue) {
    if (!queue)
        return 0;

    mutex_lock(&queue->mutex);
    uint32_t count = queue->count;
    mutex_unlock(&queue->mutex);

    return count;
}

// =============================================================================
// Task Implementation
// =============================================================================

static CardinalAsyncTask* create_task(CardinalAsyncTaskType type, CardinalAsyncPriority priority) {
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    CardinalAsyncTask* task = cardinal_alloc(allocator, sizeof(CardinalAsyncTask));
    if (!task) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for async task");
        return NULL;
    }

    memset(task, 0, sizeof(CardinalAsyncTask));

    mutex_lock(&g_async_loader.state_mutex);
    task->id = ++g_async_loader.next_task_id;
    mutex_unlock(&g_async_loader.state_mutex);

    task->type = type;
    task->priority = priority;
    task->status = CARDINAL_ASYNC_STATUS_PENDING;
    task->submit_time = get_timestamp_ms();

    return task;
}

// Wrapper function to match expected destructor signature
static void texture_destructor_wrapper(void* data) {
    texture_data_free((TextureData*)data);
}

static bool execute_texture_load_task(CardinalAsyncTask* task) {
    if (!task || !task->file_path) {
        return false;
    }

    CARDINAL_LOG_DEBUG("Loading texture: %s", task->file_path);

    // Load texture using existing texture loader
    TextureData* texture = cardinal_alloc(
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ASSETS), sizeof(TextureData));
    if (!texture || !texture_load_from_file(task->file_path, texture)) {
        CardinalAllocator* allocator =
            cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
        task->error_message = cardinal_alloc(allocator, 256);
        if (task->error_message) {
            snprintf(task->error_message, 256, "Failed to load texture: %s", task->file_path);
        }
        return false;
    }

    // Create reference counted resource
    CardinalRefCountedResource* ref_resource = cardinal_ref_create(
        task->file_path, texture, sizeof(TextureData), texture_destructor_wrapper);

    if (!ref_resource) {
        CardinalAllocator* allocator =
            cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
        cardinal_free(allocator, texture);
        task->error_message = cardinal_alloc(allocator, 256);
        if (task->error_message) {
            snprintf(task->error_message, 256, "Failed to create reference counted texture: %s",
                     task->file_path);
        }
        return false;
    }

    task->result_data = ref_resource;
    task->result_size = sizeof(CardinalRefCountedResource);

    CARDINAL_LOG_DEBUG("Successfully loaded texture: %s", task->file_path);
    return true;
}

static bool execute_scene_load_task(CardinalAsyncTask* task) {
    if (!task || !task->file_path) {
        return false;
    }

    CARDINAL_LOG_DEBUG("Loading scene: %s", task->file_path);

    // Load scene using existing scene loader
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    CardinalScene* scene = cardinal_alloc(allocator, sizeof(CardinalScene));
    if (!scene) {
        task->error_message = cardinal_alloc(allocator, 256);
        if (task->error_message) {
            snprintf(task->error_message, 256, "Failed to allocate memory for scene: %s",
                     task->file_path);
        }
        return false;
    }

    // Use existing scene loading function
    if (!cardinal_scene_load(task->file_path, scene)) {
        CardinalAllocator* allocator =
            cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
        cardinal_free(allocator, scene);
        task->error_message = cardinal_alloc(allocator, 256);
        if (task->error_message) {
            snprintf(task->error_message, 256, "Failed to load scene: %s", task->file_path);
        }
        return false;
    }

    task->result_data = scene;
    task->result_size = sizeof(CardinalScene);

    CARDINAL_LOG_DEBUG("Successfully loaded scene: %s", task->file_path);
    return true;
}

static bool execute_task(CardinalAsyncTask* task) {
    if (!task)
        return false;

    task->status = CARDINAL_ASYNC_STATUS_RUNNING;

    bool success = false;

    switch (task->type) {
        case CARDINAL_ASYNC_TASK_TEXTURE_LOAD:
            success = execute_texture_load_task(task);
            break;

        case CARDINAL_ASYNC_TASK_SCENE_LOAD:
            success = execute_scene_load_task(task);
            break;

        case CARDINAL_ASYNC_TASK_CUSTOM:
            if (task->custom_func) {
                success = task->custom_func(task, task->custom_data);
            }
            break;

        default:
            CardinalAllocator* allocator =
                cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
            task->error_message = cardinal_alloc(allocator, 64);
            if (task->error_message) {
                snprintf(task->error_message, 64, "Unknown task type: %d", task->type);
            }
            break;
    }

    task->status = success ? CARDINAL_ASYNC_STATUS_COMPLETED : CARDINAL_ASYNC_STATUS_FAILED;
    return success;
}

// =============================================================================
// Worker Thread Implementation
// =============================================================================

#ifdef _WIN32
static unsigned __stdcall worker_thread_func(void* arg) {
#else
static void* worker_thread_func(void* arg) {
#endif
    WorkerThread* worker = (WorkerThread*)arg;

    CARDINAL_LOG_DEBUG("Worker thread %u started", worker->thread_id);

    while (!worker->should_exit && !g_async_loader.shutting_down) {
        // Get next task from pending queue
        CardinalAsyncTask* task = task_queue_pop(&g_async_loader.pending_queue, true);

        if (!task) {
            continue;
        }

        // Check if task was cancelled
        if (task->status == CARDINAL_ASYNC_STATUS_CANCELLED) {
            task_queue_push(&g_async_loader.completed_queue, task);
            continue;
        }

        // Execute the task
        execute_task(task);

        // Move task to completed queue
        task_queue_push(&g_async_loader.completed_queue, task);
    }

    CARDINAL_LOG_DEBUG("Worker thread %u exiting", worker->thread_id);

#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

static bool create_worker_threads(uint32_t count) {
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    g_async_loader.workers = cardinal_alloc(allocator, sizeof(WorkerThread) * count);
    if (!g_async_loader.workers) {
        CARDINAL_LOG_ERROR("Failed to allocate memory for worker threads");
        return false;
    }

    memset(g_async_loader.workers, 0, sizeof(WorkerThread) * count);
    g_async_loader.worker_count = count;

    for (uint32_t i = 0; i < count; i++) {
        WorkerThread* worker = &g_async_loader.workers[i];
        worker->thread_id = i;
        worker->should_exit = false;

#ifdef _WIN32
        worker->thread_handle =
            (HANDLE)_beginthreadex(NULL, 0, worker_thread_func, worker, 0, NULL);

        if (!worker->thread_handle) {
            CARDINAL_LOG_ERROR("Failed to create worker thread %u", i);
            return false;
        }
#else
        if (pthread_create(&worker->thread_handle, NULL, worker_thread_func, worker) != 0) {
            CARDINAL_LOG_ERROR("Failed to create worker thread %u", i);
            return false;
        }
#endif
    }

    CARDINAL_LOG_INFO("Created %u worker threads", count);
    return true;
}

static void destroy_worker_threads(void) {
    if (!g_async_loader.workers)
        return;

    // Signal all workers to exit
    for (uint32_t i = 0; i < g_async_loader.worker_count; i++) {
        g_async_loader.workers[i].should_exit = true;
    }

    // Wake up all waiting workers
    condition_signal(&g_async_loader.pending_queue.condition);

    // Wait for all threads to finish
    for (uint32_t i = 0; i < g_async_loader.worker_count; i++) {
        WorkerThread* worker = &g_async_loader.workers[i];

#ifdef _WIN32
        if (worker->thread_handle) {
            WaitForSingleObject(worker->thread_handle, INFINITE);
            CloseHandle(worker->thread_handle);
        }
#else
        if (worker->thread_handle) {
            pthread_join(worker->thread_handle, NULL);
        }
#endif
    }

    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    cardinal_free(allocator, g_async_loader.workers);
    g_async_loader.workers = NULL;
    g_async_loader.worker_count = 0;

    CARDINAL_LOG_INFO("Destroyed worker threads");
}

// =============================================================================
// Public API Implementation
// =============================================================================

bool cardinal_async_loader_init(const CardinalAsyncLoaderConfig* config) {
    if (g_async_loader.initialized) {
        CARDINAL_LOG_WARN("Async loader already initialized");
        return true;
    }

    memset(&g_async_loader, 0, sizeof(AsyncLoaderState));

    // Set default configuration
    if (config) {
        g_async_loader.config = *config;
    } else {
        g_async_loader.config.worker_thread_count = 0; // Auto-detect
        g_async_loader.config.max_queue_size = 1000;
        g_async_loader.config.enable_priority_queue = true;
    }

    // Auto-detect worker thread count
    if (g_async_loader.config.worker_thread_count == 0) {
        uint32_t cpu_count = get_cpu_count();
        g_async_loader.config.worker_thread_count = cpu_count > 1 ? cpu_count - 1 : 1;
    }

    // Initialize mutexes
    mutex_init(&g_async_loader.state_mutex);

    // Initialize task queues
    if (!task_queue_init(&g_async_loader.pending_queue, g_async_loader.config.max_queue_size)) {
        CARDINAL_LOG_ERROR("Failed to initialize pending task queue");
        goto cleanup;
    }

    if (!task_queue_init(&g_async_loader.completed_queue, 0)) {
        CARDINAL_LOG_ERROR("Failed to initialize completed task queue");
        goto cleanup;
    }

    // Create worker threads
    if (!create_worker_threads(g_async_loader.config.worker_thread_count)) {
        CARDINAL_LOG_ERROR("Failed to create worker threads");
        goto cleanup;
    }

    g_async_loader.initialized = true;
    g_async_loader.shutting_down = false;

    CARDINAL_LOG_INFO("Async loader initialized with %u worker threads",
                      g_async_loader.config.worker_thread_count);

    return true;

cleanup:
    task_queue_destroy(&g_async_loader.pending_queue);
    task_queue_destroy(&g_async_loader.completed_queue);
    mutex_destroy(&g_async_loader.state_mutex);
    memset(&g_async_loader, 0, sizeof(AsyncLoaderState));
    return false;
}

void cardinal_async_loader_shutdown(void) {
    if (!g_async_loader.initialized)
        return;

    CARDINAL_LOG_INFO("Shutting down async loader...");

    g_async_loader.shutting_down = true;

    // Destroy worker threads (this will wait for completion)
    destroy_worker_threads();

    // Destroy task queues
    task_queue_destroy(&g_async_loader.pending_queue);
    task_queue_destroy(&g_async_loader.completed_queue);

    // Destroy mutexes
    mutex_destroy(&g_async_loader.state_mutex);

    memset(&g_async_loader, 0, sizeof(AsyncLoaderState));

    CARDINAL_LOG_INFO("Async loader shutdown complete");
}

void cardinal_async_loader_shutdown_immediate(void) {
    // For now, same as regular shutdown
    // TODO: Implement immediate cancellation of all tasks
    cardinal_async_loader_shutdown();
}

bool cardinal_async_loader_is_initialized(void) {
    return g_async_loader.initialized;
}

CardinalAsyncTask* cardinal_async_load_texture(const char* file_path,
                                               CardinalAsyncPriority priority,
                                               CardinalAsyncCallback callback, void* user_data) {
    if (!g_async_loader.initialized || !file_path) {
        return NULL;
    }

    CardinalAsyncTask* task = create_task(CARDINAL_ASYNC_TASK_TEXTURE_LOAD, priority);
    if (!task) {
        return NULL;
    }

    // Copy file path
    size_t path_len = strlen(file_path) + 1;
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    task->file_path = cardinal_alloc(allocator, path_len);
    if (!task->file_path) {
        cardinal_free(allocator, task);
        return NULL;
    }
    strcpy(task->file_path, file_path);

    task->callback = callback;
    task->callback_data = user_data;

    // Submit task to queue
    if (!task_queue_push(&g_async_loader.pending_queue, task)) {
        cardinal_async_free_task(task);
        return NULL;
    }

    return task;
}

CardinalAsyncTask* cardinal_async_load_scene(const char* file_path, CardinalAsyncPriority priority,
                                             CardinalAsyncCallback callback, void* user_data) {
    if (!g_async_loader.initialized || !file_path) {
        return NULL;
    }

    CardinalAsyncTask* task = create_task(CARDINAL_ASYNC_TASK_SCENE_LOAD, priority);
    if (!task) {
        return NULL;
    }

    // Copy file path
    size_t path_len = strlen(file_path) + 1;
    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);
    task->file_path = cardinal_alloc(allocator, path_len);
    if (!task->file_path) {
        cardinal_free(allocator, task);
        return NULL;
    }
    strcpy(task->file_path, file_path);

    task->callback = callback;
    task->callback_data = user_data;

    // Submit task to queue
    if (!task_queue_push(&g_async_loader.pending_queue, task)) {
        cardinal_async_free_task(task);
        return NULL;
    }

    return task;
}

CardinalAsyncTask* cardinal_async_submit_custom_task(CardinalAsyncTaskFunc task_func,
                                                     void* custom_data,
                                                     CardinalAsyncPriority priority,
                                                     CardinalAsyncCallback callback,
                                                     void* user_data) {
    if (!g_async_loader.initialized || !task_func) {
        return NULL;
    }

    CardinalAsyncTask* task = create_task(CARDINAL_ASYNC_TASK_CUSTOM, priority);
    if (!task) {
        return NULL;
    }

    task->custom_func = task_func;
    task->custom_data = custom_data;
    task->callback = callback;
    task->callback_data = user_data;

    // Submit task to queue
    if (!task_queue_push(&g_async_loader.pending_queue, task)) {
        cardinal_async_free_task(task);
        return NULL;
    }

    return task;
}

bool cardinal_async_cancel_task(CardinalAsyncTask* task) {
    if (!task)
        return false;

    // Can only cancel pending tasks
    if (task->status == CARDINAL_ASYNC_STATUS_PENDING) {
        task->status = CARDINAL_ASYNC_STATUS_CANCELLED;
        return true;
    }

    return false;
}

CardinalAsyncStatus cardinal_async_get_task_status(const CardinalAsyncTask* task) {
    return task ? task->status : CARDINAL_ASYNC_STATUS_FAILED;
}

bool cardinal_async_wait_for_task(CardinalAsyncTask* task, uint32_t timeout_ms) {
    if (!task)
        return false;

    uint64_t start_time = get_timestamp_ms();

    while (task->status == CARDINAL_ASYNC_STATUS_PENDING ||
           task->status == CARDINAL_ASYNC_STATUS_RUNNING) {
        if (timeout_ms > 0) {
            uint64_t elapsed = get_timestamp_ms() - start_time;
            if (elapsed >= timeout_ms) {
                return false; // Timeout
            }
        }

        // Sleep for a short time
#ifdef _WIN32
        Sleep(1);
#else
        usleep(1000);
#endif
    }

    return task->status == CARDINAL_ASYNC_STATUS_COMPLETED;
}

void cardinal_async_free_task(CardinalAsyncTask* task) {
    if (!task)
        return;

    CardinalAllocator* allocator =
        cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE);

    if (task->file_path) {
        cardinal_free(allocator, task->file_path);
    }

    if (task->error_message) {
        cardinal_free(allocator, task->error_message);
    }

    // Note: result_data is not freed here as it may be reference counted
    // or owned by the caller

    cardinal_free(allocator, task);
}

CardinalRefCountedResource* cardinal_async_get_texture_result(CardinalAsyncTask* task,
                                                              TextureData* out_texture) {
    if (!task || task->type != CARDINAL_ASYNC_TASK_TEXTURE_LOAD ||
        task->status != CARDINAL_ASYNC_STATUS_COMPLETED || !out_texture) {
        return NULL;
    }

    CardinalRefCountedResource* ref_resource = (CardinalRefCountedResource*)task->result_data;
    if (!ref_resource) {
        return NULL;
    }

    // Copy texture data
    TextureData* texture = (TextureData*)ref_resource->resource;
    if (texture) {
        *out_texture = *texture;
    }

    return ref_resource;
}

bool cardinal_async_get_scene_result(CardinalAsyncTask* task, CardinalScene* out_scene) {
    if (!task || task->type != CARDINAL_ASYNC_TASK_SCENE_LOAD ||
        task->status != CARDINAL_ASYNC_STATUS_COMPLETED || !out_scene) {
        return false;
    }

    CardinalScene* scene = (CardinalScene*)task->result_data;
    if (!scene) {
        return false;
    }

    *out_scene = *scene;
    return true;
}

const char* cardinal_async_get_error_message(const CardinalAsyncTask* task) {
    return (task && task->status == CARDINAL_ASYNC_STATUS_FAILED) ? task->error_message : NULL;
}

uint32_t cardinal_async_get_pending_task_count(void) {
    return task_queue_size(&g_async_loader.pending_queue);
}

uint32_t cardinal_async_get_worker_thread_count(void) {
    return g_async_loader.worker_count;
}

uint32_t cardinal_async_process_completed_tasks(uint32_t max_tasks) {
    if (!g_async_loader.initialized)
        return 0;

    uint32_t processed = 0;

    while ((max_tasks == 0 || processed < max_tasks)) {
        CardinalAsyncTask* task = task_queue_pop(&g_async_loader.completed_queue, false);
        if (!task)
            break;

        // Call completion callback if provided
        if (task->callback) {
            task->callback(task, task->callback_data);
        }

        processed++;
    }

    return processed;
}
