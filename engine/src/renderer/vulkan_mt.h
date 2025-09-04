#ifndef VULKAN_MT_H
#define VULKAN_MT_H

#include "vulkan_state.h"
#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef _WIN32
#include <windows.h>
typedef HANDLE cardinal_thread_t;
typedef CRITICAL_SECTION cardinal_mutex_t;
typedef CONDITION_VARIABLE cardinal_cond_t;
#else
#include <pthread.h>
typedef pthread_t cardinal_thread_t;
typedef pthread_mutex_t cardinal_mutex_t;
typedef pthread_cond_t cardinal_cond_t;
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Maximum number of worker threads for command buffer allocation
#define CARDINAL_MAX_MT_THREADS 8
#define CARDINAL_MAX_SECONDARY_COMMAND_BUFFERS 16

// Thread-local command buffer pool
typedef struct CardinalThreadCommandPool {
    VkCommandPool primary_pool;           // Primary command pool for this thread
    VkCommandPool secondary_pool;         // Secondary command pool for parallel recording
    VkCommandBuffer* secondary_buffers;   // Array of secondary command buffers
    uint32_t secondary_buffer_count;      // Number of allocated secondary buffers
    uint32_t next_secondary_index;        // Next available secondary buffer index
    cardinal_thread_t thread_id;          // Thread ID that owns this pool
    bool is_active;                       // Whether this pool is currently in use
} CardinalThreadCommandPool;

// Multi-threaded command buffer manager
typedef struct CardinalMTCommandManager {
    VulkanState* vulkan_state;                                    // Reference to Vulkan state
    CardinalThreadCommandPool thread_pools[CARDINAL_MAX_MT_THREADS]; // Per-thread command pools
    uint32_t active_thread_count;                                // Number of active threads
    cardinal_mutex_t pool_mutex;                                 // Mutex for thread pool access
    bool is_initialized;                                         // Initialization flag
} CardinalMTCommandManager;

// Secondary command buffer recording context
typedef struct CardinalSecondaryCommandContext {
    VkCommandBuffer command_buffer;       // Secondary command buffer
    VkCommandBufferInheritanceInfo inheritance; // Inheritance info for secondary buffer
    uint32_t thread_index;               // Index of the thread recording this buffer
    bool is_recording;                   // Whether recording is in progress
} CardinalSecondaryCommandContext;

// Multi-threaded resource loading task types
typedef enum CardinalMTTaskType {
    CARDINAL_MT_TASK_TEXTURE_LOAD,
    CARDINAL_MT_TASK_MESH_LOAD,
    CARDINAL_MT_TASK_MATERIAL_LOAD,
    CARDINAL_MT_TASK_COMMAND_RECORD,
    CARDINAL_MT_TASK_COUNT
} CardinalMTTaskType;

// Multi-threaded task structure
typedef struct CardinalMTTask {
    CardinalMTTaskType type;              // Type of task
    void* data;                          // Task-specific data
    void (*execute_func)(void* data);    // Function to execute the task
    void (*callback_func)(void* data, bool success); // Completion callback
    bool is_completed;                   // Completion flag
    bool success;                        // Success flag
    struct CardinalMTTask* next;         // Next task in queue
} CardinalMTTask;

// Multi-threaded task queue
typedef struct CardinalMTTaskQueue {
    CardinalMTTask* head;                // Head of the task queue
    CardinalMTTask* tail;                // Tail of the task queue
    cardinal_mutex_t queue_mutex;        // Mutex for queue access
    cardinal_cond_t queue_condition;     // Condition variable for queue notifications
    uint32_t task_count;                 // Number of tasks in queue
} CardinalMTTaskQueue;

// Enhanced multi-threading subsystem
typedef struct CardinalMTSubsystem {
    CardinalMTCommandManager command_manager;     // Command buffer manager
    CardinalMTTaskQueue pending_queue;            // Queue for pending tasks
    CardinalMTTaskQueue completed_queue;          // Queue for completed tasks
    cardinal_thread_t worker_threads[CARDINAL_MAX_MT_THREADS]; // Worker threads
    uint32_t worker_thread_count;                // Number of worker threads
    bool is_running;                             // Whether the subsystem is running
    cardinal_mutex_t subsystem_mutex;            // Global subsystem mutex
} CardinalMTSubsystem;

// Global multi-threading subsystem instance
extern CardinalMTSubsystem g_cardinal_mt_subsystem;

// === Command Buffer Management Functions ===

/**
 * @brief Initialize the multi-threaded command buffer manager
 * @param manager Pointer to the command manager
 * @param vulkan_state Pointer to the Vulkan state
 * @return true on success, false on failure
 */
bool cardinal_mt_command_manager_init(CardinalMTCommandManager* manager, VulkanState* vulkan_state);

/**
 * @brief Shutdown the multi-threaded command buffer manager
 * @param manager Pointer to the command manager
 */
void cardinal_mt_command_manager_shutdown(CardinalMTCommandManager* manager);

/**
 * @brief Get or create a thread-local command pool
 * @param manager Pointer to the command manager
 * @return Pointer to the thread's command pool, or NULL on failure
 */
CardinalThreadCommandPool* cardinal_mt_get_thread_command_pool(CardinalMTCommandManager* manager);

/**
 * @brief Allocate a secondary command buffer for parallel recording
 * @param pool Pointer to the thread command pool
 * @param context Pointer to the secondary command context to fill
 * @return true on success, false on failure
 */
bool cardinal_mt_allocate_secondary_command_buffer(CardinalThreadCommandPool* pool, 
                                                   CardinalSecondaryCommandContext* context);

/**
 * @brief Begin recording a secondary command buffer
 * @param context Pointer to the secondary command context
 * @param inheritance_info Inheritance information for the secondary buffer
 * @return true on success, false on failure
 */
bool cardinal_mt_begin_secondary_command_buffer(CardinalSecondaryCommandContext* context,
                                                const VkCommandBufferInheritanceInfo* inheritance_info);

/**
 * @brief End recording a secondary command buffer
 * @param context Pointer to the secondary command context
 * @return true on success, false on failure
 */
bool cardinal_mt_end_secondary_command_buffer(CardinalSecondaryCommandContext* context);

/**
 * @brief Execute secondary command buffers in a primary command buffer
 * @param primary_cmd Primary command buffer
 * @param secondary_contexts Array of secondary command contexts
 * @param count Number of secondary command buffers
 */
void cardinal_mt_execute_secondary_command_buffers(VkCommandBuffer primary_cmd,
                                                   CardinalSecondaryCommandContext* secondary_contexts,
                                                   uint32_t count);

// === Multi-Threading Subsystem Functions ===

/**
 * @brief Initialize the multi-threading subsystem
 * @param vulkan_state Pointer to the Vulkan state
 * @param worker_thread_count Number of worker threads to create
 * @return true on success, false on failure
 */
bool cardinal_mt_subsystem_init(VulkanState* vulkan_state, uint32_t worker_thread_count);

/**
 * @brief Shutdown the multi-threading subsystem
 */
void cardinal_mt_subsystem_shutdown(void);

/**
 * @brief Submit a task to the multi-threading subsystem
 * @param task Pointer to the task to submit
 * @return true on success, false on failure
 */
bool cardinal_mt_submit_task(CardinalMTTask* task);

/**
 * @brief Process completed tasks (call from main thread)
 * @param max_tasks Maximum number of tasks to process (0 = process all)
 */
void cardinal_mt_process_completed_tasks(uint32_t max_tasks);

/**
 * @brief Create a texture loading task
 * @param file_path Path to the texture file
 * @param callback Completion callback function
 * @return Pointer to the created task, or NULL on failure
 */
CardinalMTTask* cardinal_mt_create_texture_load_task(const char* file_path, 
                                                    void (*callback)(void* data, bool success));

/**
 * @brief Create a mesh loading task
 * @param file_path Path to the mesh file
 * @param callback Completion callback function
 * @return Pointer to the created task, or NULL on failure
 */
CardinalMTTask* cardinal_mt_create_mesh_load_task(const char* file_path,
                                                 void (*callback)(void* data, bool success));

/**
 * @brief Create a command recording task
 * @param record_func Function to record commands
 * @param user_data User data to pass to the recording function
 * @param callback Completion callback function
 * @return Pointer to the created task, or NULL on failure
 */
CardinalMTTask* cardinal_mt_create_command_record_task(void (*record_func)(void* data),
                                                      void* user_data,
                                                      void (*callback)(void* data, bool success));

// === Utility Functions ===

/**
 * @brief Get the current thread ID
 * @return Current thread ID
 */
cardinal_thread_t cardinal_mt_get_current_thread_id(void);

/**
 * @brief Check if two thread IDs are equal
 * @param thread1 First thread ID
 * @param thread2 Second thread ID
 * @return true if equal, false otherwise
 */
bool cardinal_mt_thread_ids_equal(cardinal_thread_t thread1, cardinal_thread_t thread2);

/**
 * @brief Get the optimal number of worker threads for the current system
 * @return Recommended number of worker threads
 */
uint32_t cardinal_mt_get_optimal_thread_count(void);

/**
 * @brief Broadcast signal to all threads waiting on a condition variable
 * @param cond Condition variable to broadcast to
 */
void cardinal_mt_cond_broadcast(cardinal_cond_t* cond);

/**
 * @brief Wait on a condition variable with timeout
 * @param cond Condition variable to wait on
 * @param mutex Associated mutex (must be locked)
 * @param timeout_ms Timeout in milliseconds
 * @return true if signaled, false if timeout
 */
bool cardinal_mt_cond_wait_timeout(cardinal_cond_t* cond, cardinal_mutex_t* mutex, uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_MT_H
