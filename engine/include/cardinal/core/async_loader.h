/**
 * @file async_loader.h
 * @brief Asynchronous loading system for Cardinal Engine
 *
 * This module provides a thread pool-based asynchronous loading system to
 * prevent UI blocking during resource loading operations. It supports loading
 * textures, scenes, and other assets in background threads with callback-based
 * completion notification.
 *
 * Key features:
 * - Thread pool with configurable worker count
 * - Task queue with priority support
 * - Callback-based completion notification
 * - Thread-safe resource loading
 * - Integration with reference counting system
 * - Progress tracking and cancellation support
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_CORE_ASYNC_LOADER_H
#define CARDINAL_CORE_ASYNC_LOADER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
typedef struct CardinalScene CardinalScene;
typedef struct TextureData TextureData;
typedef struct CardinalRefCountedResource CardinalRefCountedResource;

/**
 * @brief Task priority levels
 */
typedef enum {
  CARDINAL_ASYNC_PRIORITY_LOW = 0,
  CARDINAL_ASYNC_PRIORITY_NORMAL = 1,
  CARDINAL_ASYNC_PRIORITY_HIGH = 2,
  CARDINAL_ASYNC_PRIORITY_CRITICAL = 3
} CardinalAsyncPriority;

/**
 * @brief Task status enumeration
 */
typedef enum {
  CARDINAL_ASYNC_STATUS_PENDING = 0,
  CARDINAL_ASYNC_STATUS_RUNNING = 1,
  CARDINAL_ASYNC_STATUS_COMPLETED = 2,
  CARDINAL_ASYNC_STATUS_FAILED = 3,
  CARDINAL_ASYNC_STATUS_CANCELLED = 4
} CardinalAsyncStatus;

/**
 * @brief Task type enumeration
 */
typedef enum {
  CARDINAL_ASYNC_TASK_TEXTURE_LOAD = 0,
  CARDINAL_ASYNC_TASK_SCENE_LOAD = 1,
  CARDINAL_ASYNC_TASK_BUFFER_UPLOAD = 2,
  CARDINAL_ASYNC_TASK_CUSTOM = 3
} CardinalAsyncTaskType;

/**
 * @brief Async task handle
 */
typedef struct CardinalAsyncTask CardinalAsyncTask;

/**
 * @brief Task completion callback function
 * @param task The completed task
 * @param user_data User-provided data passed to the callback
 */
typedef void (*CardinalAsyncCallback)(CardinalAsyncTask *task, void *user_data);

/**
 * @brief Custom task function
 * @param task The task being executed
 * @param user_data User-provided data for the task
 * @return true on success, false on failure
 */
typedef bool (*CardinalAsyncTaskFunc)(CardinalAsyncTask *task, void *user_data);

/**
 * @brief Async task structure
 */
struct CardinalAsyncTask {
  uint32_t id;                         /**< Unique task identifier */
  CardinalAsyncTaskType type;          /**< Task type */
  CardinalAsyncPriority priority;      /**< Task priority */
  volatile CardinalAsyncStatus status; /**< Current task status */

  // Task data
  char *file_path;    /**< File path for loading tasks */
  void *result_data;  /**< Result data pointer */
  size_t result_size; /**< Size of result data */

  // Custom task support
  CardinalAsyncTaskFunc custom_func; /**< Custom task function */
  void *custom_data;                 /**< Custom task data */

  // Completion callback
  CardinalAsyncCallback callback; /**< Completion callback */
  void *callback_data;            /**< User data for callback */

  // Error information
  char *error_message; /**< Error message if task failed */

  // Internal fields
  struct CardinalAsyncTask *next; /**< Next task in queue */
  uint64_t submit_time;           /**< Task submission timestamp */
};

/**
 * @brief Async loader configuration
 */
typedef struct {
  uint32_t
      worker_thread_count;    /**< Number of worker threads (0 = auto-detect) */
  uint32_t max_queue_size;    /**< Maximum number of queued tasks */
  bool enable_priority_queue; /**< Enable priority-based task scheduling */
} CardinalAsyncLoaderConfig;

// =============================================================================
// Async Loader Management
// =============================================================================

/**
 * @brief Initialize the async loading system
 * @param config Configuration for the async loader (NULL for defaults)
 * @return true on success, false on failure
 */
bool cardinal_async_loader_init(const CardinalAsyncLoaderConfig *config);

/**
 * @brief Shutdown the async loading system
 *
 * This function will wait for all pending tasks to complete before shutting
 * down. Use cardinal_async_loader_shutdown_immediate() to cancel pending tasks.
 */
void cardinal_async_loader_shutdown(void);

/**
 * @brief Immediately shutdown the async loading system
 *
 * This function will cancel all pending tasks and shutdown immediately.
 */
void cardinal_async_loader_shutdown_immediate(void);

/**
 * @brief Check if the async loader is initialized
 * @return true if initialized, false otherwise
 */
bool cardinal_async_loader_is_initialized(void);

// =============================================================================
// Task Management
// =============================================================================

/**
 * @brief Submit a texture loading task
 * @param file_path Path to the texture file
 * @param priority Task priority
 * @param callback Completion callback (can be NULL)
 * @param user_data User data for callback
 * @return Task handle, or NULL on failure
 */
CardinalAsyncTask *cardinal_async_load_texture(const char *file_path,
                                               CardinalAsyncPriority priority,
                                               CardinalAsyncCallback callback,
                                               void *user_data);

/**
 * @brief Submit a scene loading task
 * @param file_path Path to the scene file
 * @param priority Task priority
 * @param callback Completion callback (can be NULL)
 * @param user_data User data for callback
 * @return Task handle, or NULL on failure
 */
CardinalAsyncTask *cardinal_async_load_scene(const char *file_path,
                                             CardinalAsyncPriority priority,
                                             CardinalAsyncCallback callback,
                                             void *user_data);

/**
 * @brief Submit a custom task
 * @param task_func Custom task function
 * @param custom_data Data for the custom task
 * @param priority Task priority
 * @param callback Completion callback (can be NULL)
 * @param user_data User data for callback
 * @return Task handle, or NULL on failure
 */
CardinalAsyncTask *cardinal_async_submit_custom_task(
    CardinalAsyncTaskFunc task_func, void *custom_data,
    CardinalAsyncPriority priority, CardinalAsyncCallback callback,
    void *user_data);

/**
 * @brief Cancel a pending task
 * @param task Task to cancel
 * @return true if successfully cancelled, false if task is already
 * running/completed
 */
bool cardinal_async_cancel_task(CardinalAsyncTask *task);

/**
 * @brief Get task status
 * @param task Task to query
 * @return Current task status
 */
CardinalAsyncStatus
cardinal_async_get_task_status(const CardinalAsyncTask *task);

/**
 * @brief Wait for a task to complete
 * @param task Task to wait for
 * @param timeout_ms Timeout in milliseconds (0 = no timeout)
 * @return true if task completed, false on timeout or error
 */
bool cardinal_async_wait_for_task(CardinalAsyncTask *task, uint32_t timeout_ms);

/**
 * @brief Free a completed task
 * @param task Task to free
 *
 * @note Only call this after the task has completed or been cancelled.
 *       The task handle becomes invalid after this call.
 */
void cardinal_async_free_task(CardinalAsyncTask *task);

// =============================================================================
// Result Access
// =============================================================================

/**
 * @brief Get texture result from completed task
 * @param task Completed texture loading task
 * @param out_texture Pointer to store texture data
 * @return Reference counted resource, or NULL on failure
 */
CardinalRefCountedResource *
cardinal_async_get_texture_result(CardinalAsyncTask *task,
                                  TextureData *out_texture);

/**
 * @brief Get scene result from completed task
 * @param task Completed scene loading task
 * @param out_scene Pointer to store scene data
 * @return true on success, false on failure
 */
bool cardinal_async_get_scene_result(CardinalAsyncTask *task,
                                     CardinalScene *out_scene);

/**
 * @brief Get error message from failed task
 * @param task Failed task
 * @return Error message string, or NULL if no error
 */
const char *cardinal_async_get_error_message(const CardinalAsyncTask *task);

// =============================================================================
// System Status
// =============================================================================

/**
 * @brief Get number of pending tasks
 * @return Number of tasks in queue
 */
uint32_t cardinal_async_get_pending_task_count(void);

/**
 * @brief Get number of active worker threads
 * @return Number of worker threads
 */
uint32_t cardinal_async_get_worker_thread_count(void);

/**
 * @brief Process completed tasks on main thread
 *
 * This function should be called regularly on the main thread to process
 * completed task callbacks and cleanup finished tasks.
 *
 * @param max_tasks Maximum number of tasks to process (0 = process all)
 * @return Number of tasks processed
 */
uint32_t cardinal_async_process_completed_tasks(uint32_t max_tasks);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_ASYNC_LOADER_H
