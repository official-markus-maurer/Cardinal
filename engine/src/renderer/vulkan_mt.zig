const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;

// Global subsystem instance
pub export var g_cardinal_mt_subsystem: types.CardinalMTSubsystem = std.mem.zeroes(types.CardinalMTSubsystem);

// === Platform-specific threading utilities ===

pub export fn cardinal_mt_mutex_init(mutex: *types.cardinal_mutex_t) callconv(.c) bool {
    if (builtin.os.tag == .windows) {
        c.InitializeCriticalSection(mutex);
        return true;
    } else {
        return c.pthread_mutex_init(mutex, null) == 0;
    }
}

pub export fn cardinal_mt_mutex_destroy(mutex: *types.cardinal_mutex_t) callconv(.c) void {
    if (builtin.os.tag == .windows) {
        c.DeleteCriticalSection(mutex);
    } else {
        _ = c.pthread_mutex_destroy(mutex);
    }
}

pub export fn cardinal_mt_mutex_lock(mutex: *types.cardinal_mutex_t) callconv(.c) void {
    if (builtin.os.tag == .windows) {
        c.EnterCriticalSection(mutex);
    } else {
        _ = c.pthread_mutex_lock(mutex);
    }
}

pub export fn cardinal_mt_mutex_unlock(mutex: *types.cardinal_mutex_t) callconv(.c) void {
    if (builtin.os.tag == .windows) {
        c.LeaveCriticalSection(mutex);
    } else {
        _ = c.pthread_mutex_unlock(mutex);
    }
}

pub export fn cardinal_mt_cond_init(cond: *types.cardinal_cond_t) callconv(.c) bool {
    if (builtin.os.tag == .windows) {
        c.InitializeConditionVariable(cond);
        return true;
    } else {
        return c.pthread_cond_init(cond, null) == 0;
    }
}

pub export fn cardinal_mt_cond_destroy(cond: *types.cardinal_cond_t) callconv(.c) void {
    if (builtin.os.tag == .windows) {
        // No destroy needed for CONDITION_VARIABLE on Windows
    } else {
        _ = c.pthread_cond_destroy(cond);
    }
}

pub export fn cardinal_mt_cond_wait(cond: *types.cardinal_cond_t, mutex: *types.cardinal_mutex_t) callconv(.c) void {
    if (builtin.os.tag == .windows) {
        _ = c.SleepConditionVariableCS(cond, mutex, c.INFINITE);
    } else {
        _ = c.pthread_cond_wait(cond, mutex);
    }
}

pub export fn cardinal_mt_cond_signal(cond: *types.cardinal_cond_t) callconv(.c) void {
    if (builtin.os.tag == .windows) {
        c.WakeConditionVariable(cond);
    } else {
        _ = c.pthread_cond_signal(cond);
    }
}

pub export fn cardinal_mt_cond_broadcast(cond: *types.cardinal_cond_t) callconv(.c) void {
    if (builtin.os.tag == .windows) {
        c.WakeAllConditionVariable(cond);
    } else {
        _ = c.pthread_cond_broadcast(cond);
    }
}

pub export fn cardinal_mt_cond_wait_timeout(cond: *types.cardinal_cond_t, mutex: *types.cardinal_mutex_t, timeout_ms: u32) callconv(.c) bool {
    if (builtin.os.tag == .windows) {
        return c.SleepConditionVariableCS(cond, mutex, timeout_ms) != 0;
    } else {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
        ts.tv_sec += @intCast(timeout_ms / 1000);
        ts.tv_nsec += @intCast((timeout_ms % 1000) * 1000000);
        if (ts.tv_nsec >= 1000000000) {
            ts.tv_sec += 1;
            ts.tv_nsec -= 1000000000;
        }
        return c.pthread_cond_timedwait(cond, mutex, &ts) == 0;
    }
}

pub export fn cardinal_mt_get_current_thread_id() callconv(.c) types.cardinal_thread_id_t {
    if (builtin.os.tag == .windows) {
        return c.GetCurrentThreadId();
    } else {
        return c.pthread_self();
    }
}

pub export fn cardinal_mt_thread_ids_equal(thread1: types.cardinal_thread_id_t, thread2: types.cardinal_thread_id_t) callconv(.c) bool {
    if (builtin.os.tag == .windows) {
        return thread1 == thread2;
    } else {
        return c.pthread_equal(thread1, thread2) != 0;
    }
}

pub export fn cardinal_mt_get_optimal_thread_count() callconv(.c) u32 {
    if (builtin.os.tag == .windows) {
        var sys_info: c.SYSTEM_INFO = undefined;
        c.GetSystemInfo(&sys_info);
        return sys_info.dwNumberOfProcessors;
    } else {
        const nprocs = c.sysconf(c._SC_NPROCESSORS_ONLN);
        return if (nprocs > 0) @intCast(nprocs) else 4;
    }
}

// Worker thread function
fn cardinal_mt_worker_thread_func(arg: ?*anyopaque) callconv(if (builtin.os.tag == .windows) .winapi else .C) if (builtin.os.tag == .windows) c_uint else ?*anyopaque {
    _ = arg;
    const thread_id = cardinal_mt_get_current_thread_id();
    log.cardinal_log_debug("[MT] Worker thread started (ID: {d})", .{thread_id});

    while (g_cardinal_mt_subsystem.is_running) {
        const task = cardinal_mt_task_queue_pop(&g_cardinal_mt_subsystem.pending_queue);
        
        if (task) |t| {
            if (t.execute_func) |exec| {
                exec(t.data);
                t.success = true; // Assume success if no crash, logic can refine this
            } else if (t.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_COMMAND_RECORD) {
                // Special handling for command recording
                // This part was implicit in the C code or handled by execute_func?
                // Looking at C code:
                // task->execute_func = record_func;
                // So it is handled by execute_func.
            }
            
            t.is_completed = true;
            cardinal_mt_task_queue_push(&g_cardinal_mt_subsystem.completed_queue, t);
        }
    }

    log.cardinal_log_debug("[MT] Worker thread stopping (ID: {d})", .{thread_id});
    return if (builtin.os.tag == .windows) 0 else null;
}

fn cardinal_mt_create_thread(thread: *types.cardinal_thread_handle_t, arg: ?*anyopaque) bool {
    if (builtin.os.tag == .windows) {
        // Use CreateThread instead of _beginthreadex due to missing process.h
        const handle = c.CreateThread(null, 0, cardinal_mt_worker_thread_func, arg, 0, null);
        thread.* = handle;
        return thread.* != null;
    } else {
        return c.pthread_create(thread, null, cardinal_mt_worker_thread_func, arg) == 0;
    }
}

fn cardinal_mt_join_thread(thread: types.cardinal_thread_handle_t) void {
    if (builtin.os.tag == .windows) {
        _ = c.WaitForSingleObject(thread, c.INFINITE);
        _ = c.CloseHandle(thread);
    } else {
        _ = c.pthread_join(thread, null);
    }
}

// === Task Queue Management ===

fn cardinal_mt_task_queue_init(queue: *types.CardinalMTTaskQueue) bool {
    queue.head = null;
    queue.tail = null;
    queue.task_count = 0;

    if (!cardinal_mt_mutex_init(&queue.queue_mutex)) {
        return false;
    }

    if (!cardinal_mt_cond_init(&queue.queue_condition)) {
        cardinal_mt_mutex_destroy(&queue.queue_mutex);
        return false;
    }

    return true;
}

fn cardinal_mt_task_queue_shutdown(queue: *types.CardinalMTTaskQueue) void {
    cardinal_mt_mutex_lock(&queue.queue_mutex);
    
    // Free remaining tasks
    var current = queue.head;
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    
    while (current != null) {
        const curr = current;
        const next = curr.?.*.next;
        // Free data if needed (similar to process_completed_tasks)
        if (curr.?.*.data != null) {
             if (curr.?.*.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_TEXTURE_LOAD or
                curr.?.*.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_MESH_LOAD) {
                memory.cardinal_free(allocator, curr.?.*.data);
            }
        }
        memory.cardinal_free(allocator, curr);
        current = next;
    }
    
    queue.head = null;
    queue.tail = null;
    queue.task_count = 0;
    
    cardinal_mt_mutex_unlock(&queue.queue_mutex);
    cardinal_mt_mutex_destroy(&queue.queue_mutex);
    cardinal_mt_cond_destroy(&queue.queue_condition);
}

fn cardinal_mt_task_queue_push(queue: *types.CardinalMTTaskQueue, task: *types.CardinalMTTask) void {
    cardinal_mt_mutex_lock(&queue.queue_mutex);

    task.next = null;

    if (queue.tail != null) {
        queue.tail.?.*.next = task;
    } else {
        queue.head = task;
    }

    queue.tail = task;
    queue.task_count += 1;

    cardinal_mt_cond_signal(&queue.queue_condition);
    cardinal_mt_mutex_unlock(&queue.queue_mutex);
}

fn cardinal_mt_task_queue_pop(queue: *types.CardinalMTTaskQueue) ?*types.CardinalMTTask {
    cardinal_mt_mutex_lock(&queue.queue_mutex);

    while (queue.head == null and g_cardinal_mt_subsystem.is_running) {
        cardinal_mt_cond_wait(&queue.queue_condition, &queue.queue_mutex);
    }

    const task = queue.head;
    if (task != null) {
        queue.head = task.?.*.next;
        if (queue.head == null) {
            queue.tail = null;
        }
        queue.task_count -= 1;
        task.?.*.next = null;
    }

    cardinal_mt_mutex_unlock(&queue.queue_mutex);
    return task;
}

fn cardinal_mt_task_queue_try_pop(queue: *types.CardinalMTTaskQueue) ?*types.CardinalMTTask {
    cardinal_mt_mutex_lock(&queue.queue_mutex);

    const task = queue.head;
    if (task != null) {
        queue.head = task.?.*.next;
        if (queue.head == null) {
            queue.tail = null;
        }
        queue.task_count -= 1;
        task.?.*.next = null;
    }

    cardinal_mt_mutex_unlock(&queue.queue_mutex);
    return task;
}

// === Command Buffer Management ===

pub export fn cardinal_mt_command_manager_init(manager: *types.CardinalMTCommandManager, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (vulkan_state == null) {
        log.cardinal_log_error("[MT] Invalid parameters for command manager initialization", .{});
        return false;
    }

    manager.vulkan_state = vulkan_state;
    manager.active_thread_count = 0;
    manager.is_initialized = false;

    if (!cardinal_mt_mutex_init(&manager.pool_mutex)) {
        log.cardinal_log_error("[MT] Failed to initialize command manager mutex", .{});
        return false;
    }

    var i: u32 = 0;
    while (i < types.CARDINAL_MAX_MT_THREADS) : (i += 1) {
        var pool = &manager.thread_pools[i];
        pool.primary_pool = null; // VK_NULL_HANDLE
        pool.secondary_pool = null;
        pool.secondary_buffers = null;
        pool.secondary_buffer_count = 0;
        pool.next_secondary_index = 0;
        pool.is_active = false;
    }

    manager.is_initialized = true;
    log.cardinal_log_info("[MT] Command manager initialized successfully", .{});
    return true;
}

pub export fn cardinal_mt_command_manager_shutdown(manager: *types.CardinalMTCommandManager) callconv(.c) void {
    if (!manager.is_initialized) return;

    cardinal_mt_mutex_lock(&manager.pool_mutex);

    var i: u32 = 0;
    while (i < types.CARDINAL_MAX_MT_THREADS) : (i += 1) {
        var pool = &manager.thread_pools[i];
        if (pool.is_active) {
            const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
            if (pool.secondary_buffers != null) {
                memory.cardinal_free(allocator, @ptrCast(pool.secondary_buffers));
                pool.secondary_buffers = null;
            }
            
            const vs = manager.vulkan_state.?;
            
            if (pool.primary_pool != null) {
                c.vkDestroyCommandPool(vs.context.device, pool.primary_pool, null);
                pool.primary_pool = null;
            }
            if (pool.secondary_pool != null) {
                c.vkDestroyCommandPool(vs.context.device, pool.secondary_pool, null);
                pool.secondary_pool = null;
            }
            pool.is_active = false;
        }
    }

    manager.active_thread_count = 0;
    manager.is_initialized = false;

    cardinal_mt_mutex_unlock(&manager.pool_mutex);
    cardinal_mt_mutex_destroy(&manager.pool_mutex);

    log.cardinal_log_info("[MT] Command manager shutdown completed", .{});
}

pub export fn cardinal_mt_get_thread_command_pool(manager: *types.CardinalMTCommandManager) callconv(.c) ?*types.CardinalThreadCommandPool {
    if (!manager.is_initialized) return null;

    const thread_id = cardinal_mt_get_current_thread_id();

    cardinal_mt_mutex_lock(&manager.pool_mutex);

    // Find existing pool
    var i: u32 = 0;
    while (i < types.CARDINAL_MAX_MT_THREADS) : (i += 1) {
        const pool = &manager.thread_pools[i];
        if (pool.is_active and cardinal_mt_thread_ids_equal(pool.thread_id, thread_id)) {
            cardinal_mt_mutex_unlock(&manager.pool_mutex);
            return pool;
        }
    }

    // Allocate new pool
    i = 0;
    var free_pool: ?*types.CardinalThreadCommandPool = null;
    while (i < types.CARDINAL_MAX_MT_THREADS) : (i += 1) {
        if (!manager.thread_pools[i].is_active) {
            free_pool = &manager.thread_pools[i];
            break;
        }
    }

    if (free_pool == null) {
        log.cardinal_log_error("[MT] No free thread command pools available", .{});
        cardinal_mt_mutex_unlock(&manager.pool_mutex);
        return null;
    }

    const pool = free_pool.?;
    pool.thread_id = thread_id;
    
    // Create pools
    const vs = manager.vulkan_state.?;
    const queue_family_index = vs.context.graphics_queue_family;
    
    var pool_info = c.VkCommandPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family_index,
    };

    if (c.vkCreateCommandPool(vs.context.device, &pool_info, null, &pool.primary_pool) != c.VK_SUCCESS) {
        log.cardinal_log_error("[MT] Failed to create primary command pool", .{});
        cardinal_mt_mutex_unlock(&manager.pool_mutex);
        return null;
    }

    if (c.vkCreateCommandPool(vs.context.device, &pool_info, null, &pool.secondary_pool) != c.VK_SUCCESS) {
        log.cardinal_log_error("[MT] Failed to create secondary command pool", .{});
        c.vkDestroyCommandPool(vs.context.device, pool.primary_pool, null);
        pool.primary_pool = null;
        cardinal_mt_mutex_unlock(&manager.pool_mutex);
        return null;
    }

    pool.secondary_buffer_count = types.CARDINAL_MAX_SECONDARY_COMMAND_BUFFERS;
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    pool.secondary_buffers = @ptrCast(@alignCast(memory.cardinal_alloc(allocator, @sizeOf(c.VkCommandBuffer) * pool.secondary_buffer_count)));
    
    if (pool.secondary_buffers == null) {
        log.cardinal_log_error("[MT] Failed to allocate memory for secondary command buffers", .{});
        c.vkDestroyCommandPool(vs.context.device, pool.secondary_pool, null);
        c.vkDestroyCommandPool(vs.context.device, pool.primary_pool, null);
        pool.primary_pool = null;
        pool.secondary_pool = null;
        cardinal_mt_mutex_unlock(&manager.pool_mutex);
        return null;
    }

    var alloc_info = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = pool.secondary_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_SECONDARY,
        .commandBufferCount = pool.secondary_buffer_count,
    };

    if (c.vkAllocateCommandBuffers(vs.context.device, &alloc_info, pool.secondary_buffers) != c.VK_SUCCESS) {
        log.cardinal_log_error("[MT] Failed to allocate secondary command buffers", .{});
        memory.cardinal_free(allocator, @ptrCast(pool.secondary_buffers));
        pool.secondary_buffers = null;
        c.vkDestroyCommandPool(vs.context.device, pool.secondary_pool, null);
        c.vkDestroyCommandPool(vs.context.device, pool.primary_pool, null);
        pool.primary_pool = null;
        pool.secondary_pool = null;
        cardinal_mt_mutex_unlock(&manager.pool_mutex);
        return null;
    }

    pool.next_secondary_index = 0;
    pool.is_active = true;
    manager.active_thread_count += 1;

    log.cardinal_log_info("[MT] Created command pool for thread (total active: {d})", .{manager.active_thread_count});

    cardinal_mt_mutex_unlock(&manager.pool_mutex);
    return pool;
}

pub export fn cardinal_mt_allocate_secondary_command_buffer(pool: *types.CardinalThreadCommandPool, context: *types.CardinalSecondaryCommandContext) callconv(.c) bool {
    if (pool.next_secondary_index >= pool.secondary_buffer_count) {
        log.cardinal_log_warn("[MT] Thread command pool exhausted", .{});
        return false;
    }

    if (pool.secondary_buffers) |bufs| {
        context.command_buffer = bufs[pool.next_secondary_index];
    } else {
        return false;
    }

    pool.next_secondary_index += 1;
    context.is_recording = false;
    
    // We can't easily get thread index here without searching manager, 
    // but context.thread_index might not be critical or used for logging only.
    // For now set to 0 or we need to pass manager.
    context.thread_index = 0; 

    return true;
}

pub export fn cardinal_mt_begin_secondary_command_buffer(context: *types.CardinalSecondaryCommandContext, inheritance_info: *const c.VkCommandBufferInheritanceInfo) callconv(.c) bool {
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT | c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = inheritance_info,
    };

    if (c.vkBeginCommandBuffer(context.command_buffer, &begin_info) != c.VK_SUCCESS) {
        log.cardinal_log_error("[MT] Failed to begin secondary command buffer", .{});
        return false;
    }

    context.inheritance = inheritance_info.*;
    context.is_recording = true;
    return true;
}

pub export fn cardinal_mt_end_secondary_command_buffer(context: *types.CardinalSecondaryCommandContext) callconv(.c) bool {
    if (!context.is_recording) return false;

    if (c.vkEndCommandBuffer(context.command_buffer) != c.VK_SUCCESS) {
        log.cardinal_log_error("[MT] Failed to end secondary command buffer", .{});
        return false;
    }

    context.is_recording = false;
    return true;
}

pub export fn cardinal_mt_execute_secondary_command_buffers(primary_cmd: c.VkCommandBuffer, secondary_contexts: [*]types.CardinalSecondaryCommandContext, count: u32) callconv(.c) void {
    if (count == 0) return;

    // We need to collect VkCommandBuffers into an array
    // Since this is called frequently, avoiding allocation would be nice.
    // But we need a contiguous array of VkCommandBuffer.
    // Max secondary buffers is small (16 per thread * 8 threads = 128 max total).
    
    // Stack allocation for typical case
    var stack_buffers: [64]c.VkCommandBuffer = undefined;
    var buffers: [*]c.VkCommandBuffer = &stack_buffers;
    var allocated = false;
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);

    if (count > 64) {
        const alloc_result = memory.cardinal_alloc(allocator, @sizeOf(c.VkCommandBuffer) * count);
        if (alloc_result) |ptr| {
            buffers = @ptrCast(@alignCast(ptr));
            allocated = true;
        } else {
            return;
        }
    }

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        buffers[i] = secondary_contexts[i].command_buffer;
    }

    c.vkCmdExecuteCommands(primary_cmd, count, buffers);

    if (allocated) {
        memory.cardinal_free(allocator, @ptrCast(buffers));
    }
}

pub export fn cardinal_mt_wait_task(task: *types.CardinalMTTask) callconv(.c) void {
    while (!task.is_completed) {
        if (builtin.os.tag == .windows) {
            c.Sleep(1);
        } else {
            _ = c.usleep(1000);
        }
    }
}

// === Multi-Threading Subsystem Functions ===

pub export fn cardinal_mt_subsystem_init(vulkan_state: ?*types.VulkanState, worker_thread_count_in: u32) callconv(.c) bool {
    if (g_cardinal_mt_subsystem.is_running) {
        log.cardinal_log_warn("[MT] Subsystem already initialized", .{});
        return true;
    }

    if (vulkan_state == null) {
        log.cardinal_log_error("[MT] Invalid Vulkan state for subsystem initialization", .{});
        return false;
    }

    var worker_thread_count = worker_thread_count_in;
    if (worker_thread_count == 0) {
        worker_thread_count = cardinal_mt_get_optimal_thread_count();
    }
    if (worker_thread_count > types.CARDINAL_MAX_MT_THREADS) {
        worker_thread_count = types.CARDINAL_MAX_MT_THREADS;
    }

    g_cardinal_mt_subsystem = std.mem.zeroes(types.CardinalMTSubsystem);

    if (!cardinal_mt_command_manager_init(&g_cardinal_mt_subsystem.command_manager, vulkan_state)) {
        log.cardinal_log_error("[MT] Failed to initialize command manager", .{});
        return false;
    }

    if (!cardinal_mt_task_queue_init(&g_cardinal_mt_subsystem.pending_queue)) {
        log.cardinal_log_error("[MT] Failed to initialize pending task queue", .{});
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }

    if (!cardinal_mt_task_queue_init(&g_cardinal_mt_subsystem.completed_queue)) {
        log.cardinal_log_error("[MT] Failed to initialize completed task queue", .{});
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }

    if (!cardinal_mt_mutex_init(&g_cardinal_mt_subsystem.subsystem_mutex)) {
        log.cardinal_log_error("[MT] Failed to initialize subsystem mutex", .{});
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }

    g_cardinal_mt_subsystem.worker_thread_count = worker_thread_count;
    g_cardinal_mt_subsystem.is_running = true;

    var i: u32 = 0;
    while (i < worker_thread_count) : (i += 1) {
        if (!cardinal_mt_create_thread(&g_cardinal_mt_subsystem.worker_threads[i], null)) {
            log.cardinal_log_error("[MT] Failed to create worker thread {d}", .{i});
            
            g_cardinal_mt_subsystem.is_running = false;
            cardinal_mt_cond_broadcast(&g_cardinal_mt_subsystem.pending_queue.queue_condition);

            var j: u32 = 0;
            while (j < i) : (j += 1) {
                cardinal_mt_join_thread(g_cardinal_mt_subsystem.worker_threads[j]);
            }

            cardinal_mt_mutex_destroy(&g_cardinal_mt_subsystem.subsystem_mutex);
            cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
            cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
            cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
            return false;
        }
    }

    log.cardinal_log_info("[MT] Subsystem initialized with {d} worker threads", .{worker_thread_count});
    return true;
}

pub export fn cardinal_mt_subsystem_shutdown() callconv(.c) void {
    if (!g_cardinal_mt_subsystem.is_running) return;

    log.cardinal_log_info("[MT] Shutting down subsystem...", .{});

    g_cardinal_mt_subsystem.is_running = false;
    cardinal_mt_cond_broadcast(&g_cardinal_mt_subsystem.pending_queue.queue_condition);

    var i: u32 = 0;
    while (i < g_cardinal_mt_subsystem.worker_thread_count) : (i += 1) {
        cardinal_mt_join_thread(g_cardinal_mt_subsystem.worker_threads[i]);
    }

    cardinal_mt_mutex_destroy(&g_cardinal_mt_subsystem.subsystem_mutex);
    cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
    cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
    cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);

    g_cardinal_mt_subsystem = std.mem.zeroes(types.CardinalMTSubsystem);

    log.cardinal_log_info("[MT] Subsystem shutdown completed", .{});
}

pub export fn cardinal_mt_submit_task(task: *types.CardinalMTTask) callconv(.c) bool {
    if (!g_cardinal_mt_subsystem.is_running) {
        log.cardinal_log_error("[MT] Invalid task or subsystem not running", .{});
        return false;
    }

    cardinal_mt_task_queue_push(&g_cardinal_mt_subsystem.pending_queue, task);
    return true;
}

pub export fn cardinal_mt_process_completed_tasks(max_tasks: u32) callconv(.c) void {
    if (!g_cardinal_mt_subsystem.is_running) return;

    var processed: u32 = 0;
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);

    while (max_tasks == 0 or processed < max_tasks) {
        const task = cardinal_mt_task_queue_try_pop(&g_cardinal_mt_subsystem.completed_queue);
        if (task == null) break;

        const t = task.?;
        if (t.callback_func) |cb| {
            cb(t.data, t.success);
        }

        if (t.data != null) {
            if (t.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_TEXTURE_LOAD or
                t.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_MESH_LOAD) {
                memory.cardinal_free(allocator, t.data);
            }
        }

        memory.cardinal_free(allocator, t);
        processed += 1;
    }
}

pub export fn cardinal_mt_create_texture_load_task(file_path: ?[*:0]const u8, callback: ?*const fn(?*anyopaque, bool) callconv(.c) void) callconv(.c) ?*types.CardinalMTTask {
    if (file_path == null) {
        log.cardinal_log_error("[MT] Invalid file path for texture load task", .{});
        return null;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const task_ptr = memory.cardinal_alloc(allocator, @sizeOf(types.CardinalMTTask));
    if (task_ptr == null) {
        log.cardinal_log_error("[MT] Failed to allocate memory for texture load task", .{});
        return null;
    }
    const task: *types.CardinalMTTask = @ptrCast(@alignCast(task_ptr));

    task.type = types.CardinalMTTaskType.CARDINAL_MT_TASK_TEXTURE_LOAD;
    const len = c.strlen(file_path) + 1;
    task.data = memory.cardinal_alloc(allocator, len);
    if (task.data) |data| {
        _ = c.strcpy(@ptrCast(data), file_path);
    }
    task.execute_func = null; // TODO: Implement texture loading function
    task.callback_func = callback;
    task.is_completed = false;
    task.success = false;
    task.next = null;

    return task;
}

pub export fn cardinal_mt_create_mesh_load_task(file_path: ?[*:0]const u8, callback: ?*const fn(?*anyopaque, bool) callconv(.c) void) callconv(.c) ?*types.CardinalMTTask {
    if (file_path == null) {
        log.cardinal_log_error("[MT] Invalid file path for mesh load task", .{});
        return null;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const task_ptr = memory.cardinal_alloc(allocator, @sizeOf(types.CardinalMTTask));
    if (task_ptr == null) {
        log.cardinal_log_error("[MT] Failed to allocate memory for mesh load task", .{});
        return null;
    }
    const task: *types.CardinalMTTask = @ptrCast(@alignCast(task_ptr));

    task.type = types.CardinalMTTaskType.CARDINAL_MT_TASK_MESH_LOAD;
    const len = c.strlen(file_path) + 1;
    task.data = memory.cardinal_alloc(allocator, len);
    if (task.data) |data| {
        _ = c.strcpy(@ptrCast(data), file_path);
    }
    task.execute_func = null; // TODO: Implement mesh loading
    task.callback_func = callback;
    task.is_completed = false;
    task.success = false;
    task.next = null;

    return task;
}

pub export fn cardinal_mt_create_command_record_task(record_func: ?*const fn(?*anyopaque) callconv(.c) void, user_data: ?*anyopaque, callback: ?*const fn(?*anyopaque, bool) callconv(.c) void) callconv(.c) ?*types.CardinalMTTask {
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const task_ptr = memory.cardinal_alloc(allocator, @sizeOf(types.CardinalMTTask));
    if (task_ptr == null) {
        log.cardinal_log_error("[MT] Failed to allocate memory for command record task", .{});
        return null;
    }
    const task: *types.CardinalMTTask = @ptrCast(@alignCast(task_ptr));

    task.type = types.CardinalMTTaskType.CARDINAL_MT_TASK_COMMAND_RECORD;
    task.data = user_data;
    task.execute_func = record_func;
    task.callback_func = callback;
    task.is_completed = false;
    task.success = false;
    task.next = null;

    return task;
}
