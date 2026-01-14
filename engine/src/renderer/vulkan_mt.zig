const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;
const texture_loader = @import("../assets/texture_loader.zig");
const gltf_loader = @import("../assets/gltf_loader.zig");
const scene = @import("../assets/scene.zig");
const ref_counting = @import("../core/ref_counting.zig");

const mt_log = log.ScopedLogger("MT");

// Global subsystem instance
pub var g_cardinal_mt_subsystem: types.CardinalMTSubsystem = std.mem.zeroes(types.CardinalMTSubsystem);

// Task context structures
const TextureLoadContext = struct {
    file_path: [:0]u8,
    result_resource: ?*ref_counting.CardinalRefCountedResource,
};

const MeshLoadContext = struct {
    file_path: [:0]u8,
    result_scene: ?*scene.CardinalScene,
};

// Platform-specific threading utilities
pub fn cardinal_mt_mutex_init(mutex: *types.cardinal_mutex_t) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const m = memory.cardinal_alloc(mem_alloc, @sizeOf(std.Thread.Mutex));
    if (m == null) return false;

    const mutex_ptr = @as(*std.Thread.Mutex, @ptrCast(@alignCast(m)));
    mutex_ptr.* = .{};

    mutex.* = @ptrCast(mutex_ptr);
    return true;
}

pub fn cardinal_mt_mutex_destroy(mutex: *types.cardinal_mutex_t) void {
    if (mutex.*) |ptr| {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, ptr);
        mutex.* = null;
    }
}

pub fn cardinal_mt_mutex_lock(mutex: *types.cardinal_mutex_t) void {
    if (mutex.*) |ptr| {
        const mutex_ptr = @as(*std.Thread.Mutex, @ptrCast(@alignCast(ptr)));
        mutex_ptr.lock();
    }
}

pub fn cardinal_mt_mutex_unlock(mutex: *types.cardinal_mutex_t) void {
    if (mutex.*) |ptr| {
        const mutex_ptr = @as(*std.Thread.Mutex, @ptrCast(@alignCast(ptr)));
        mutex_ptr.unlock();
    }
}

pub fn cardinal_mt_cond_init(cond: *types.cardinal_cond_t) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const c_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(std.Thread.Condition));
    if (c_ptr == null) return false;

    const cond_ptr = @as(*std.Thread.Condition, @ptrCast(@alignCast(c_ptr)));
    cond_ptr.* = .{};

    cond.* = @ptrCast(cond_ptr);
    return true;
}

pub fn cardinal_mt_cond_destroy(cond: *types.cardinal_cond_t) void {
    if (cond.*) |ptr| {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, ptr);
        cond.* = null;
    }
}

pub fn cardinal_mt_cond_wait(cond: *types.cardinal_cond_t, mutex: *types.cardinal_mutex_t) void {
    if (cond.*) |c_ptr| {
        if (mutex.*) |m_ptr| {
            const cond_ptr = @as(*std.Thread.Condition, @ptrCast(@alignCast(c_ptr)));
            const mutex_ptr = @as(*std.Thread.Mutex, @ptrCast(@alignCast(m_ptr)));
            cond_ptr.wait(mutex_ptr);
        }
    }
}

pub fn cardinal_mt_cond_signal(cond: *types.cardinal_cond_t) void {
    if (cond.*) |ptr| {
        const cond_ptr = @as(*std.Thread.Condition, @ptrCast(@alignCast(ptr)));
        cond_ptr.signal();
    }
}

pub fn cardinal_mt_cond_broadcast(cond: *types.cardinal_cond_t) void {
    if (cond.*) |ptr| {
        const cond_ptr = @as(*std.Thread.Condition, @ptrCast(@alignCast(ptr)));
        cond_ptr.broadcast();
    }
}

pub fn cardinal_mt_cond_wait_timeout(cond: *types.cardinal_cond_t, mutex: *types.cardinal_mutex_t, timeout_ms: u32) bool {
    if (cond.*) |c_ptr| {
        if (mutex.*) |m_ptr| {
            const cond_ptr = @as(*std.Thread.Condition, @ptrCast(@alignCast(c_ptr)));
            const mutex_ptr = @as(*std.Thread.Mutex, @ptrCast(@alignCast(m_ptr)));
            cond_ptr.timedWait(mutex_ptr, @as(u64, timeout_ms) * 1_000_000) catch return false;
            return true;
        }
    }
    return false;
}

pub fn cardinal_mt_get_current_thread_id() types.cardinal_thread_id_t {
    return std.Thread.getCurrentId();
}

pub fn cardinal_mt_thread_ids_equal(thread1: types.cardinal_thread_id_t, thread2: types.cardinal_thread_id_t) bool {
    return thread1 == thread2;
}

pub fn cardinal_mt_get_optimal_thread_count() u32 {
    return @intCast(std.Thread.getCpuCount() catch 4);
}

// Worker thread function
fn cardinal_mt_worker_thread_func(arg: ?*anyopaque) void {
    _ = arg;
    const thread_id = cardinal_mt_get_current_thread_id();
    mt_log.debug("Worker thread started (ID: {any})", .{thread_id});

    while (g_cardinal_mt_subsystem.is_running) {
        const task = cardinal_mt_task_queue_pop(&g_cardinal_mt_subsystem.pending_queue);

        if (task) |t| {
            if (t.execute_func) |exec| {
                exec(t.data);
                t.success = true; // Assume success if no crash, logic can refine this
            } else if (t.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_COMMAND_RECORD) {}

            t.is_completed = true;
            cardinal_mt_task_queue_push(&g_cardinal_mt_subsystem.completed_queue, t);
        }
    }

    mt_log.debug("Worker thread stopping (ID: {any})", .{thread_id});
}

fn cardinal_mt_create_thread(thread: *?types.cardinal_thread_handle_t, arg: ?*anyopaque) bool {
    thread.* = std.Thread.spawn(.{}, cardinal_mt_worker_thread_func, .{arg}) catch return false;
    return true;
}

fn cardinal_mt_join_thread(thread: types.cardinal_thread_handle_t) void {
    thread.join();
}

// Task Queue Management
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

        // Free data if needed
        if (curr.?.*.data) |data| {
            if (curr.?.*.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_TEXTURE_LOAD) {
                const ctx: *TextureLoadContext = @ptrCast(@alignCast(data));
                memory.cardinal_free(allocator, ctx.file_path.ptr);
                // Note: result_resource is ref counted, should be released if not picked up?
                // But this is shutdown, so we should release.
                if (ctx.result_resource) |res| {
                    ref_counting.cardinal_ref_release(res);
                }
                memory.cardinal_free(allocator, ctx);
            } else if (curr.?.*.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_MESH_LOAD) {
                const ctx: *MeshLoadContext = @ptrCast(@alignCast(data));
                memory.cardinal_free(allocator, ctx.file_path.ptr);
                if (ctx.result_scene) |s| {
                    scene.cardinal_scene_destroy(s);
                    memory.cardinal_free(allocator, s);
                }
                memory.cardinal_free(allocator, ctx);
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

// Command Buffer Management
pub fn cardinal_mt_command_manager_init(manager: *types.CardinalMTCommandManager, vulkan_state: ?*types.VulkanState) bool {
    if (vulkan_state == null) {
        mt_log.err("Invalid parameters for command manager initialization", .{});
        return false;
    }

    manager.vulkan_state = vulkan_state;
    manager.active_thread_count = 0;
    manager.is_initialized = false;

    if (!cardinal_mt_mutex_init(&manager.pool_mutex)) {
        mt_log.err("Failed to initialize command manager mutex", .{});
        return false;
    }

    // Allocate thread pools
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(allocator, @sizeOf(types.CardinalThreadCommandPool) * types.CARDINAL_MAX_MT_THREADS);
    if (ptr == null) {
        mt_log.err("Failed to allocate thread pools", .{});
        cardinal_mt_mutex_destroy(&manager.pool_mutex);
        return false;
    }
    manager.thread_pools = @as([*]types.CardinalThreadCommandPool, @ptrCast(@alignCast(ptr)));

    var i: u32 = 0;
    while (i < types.CARDINAL_MAX_MT_THREADS) : (i += 1) {
        var pool = &manager.thread_pools.?[i];
        pool.primary_pool = null; // VK_NULL_HANDLE
        pool.secondary_pool = null;
        pool.secondary_buffers = null;
        pool.secondary_buffer_count = 0;
        pool.next_secondary_index = 0;
        pool.is_active = false;
    }

    manager.is_initialized = true;
    mt_log.info("Command manager initialized successfully", .{});
    return true;
}

pub fn cardinal_mt_command_manager_shutdown(manager: *types.CardinalMTCommandManager) void {
    if (!manager.is_initialized) return;

    cardinal_mt_mutex_lock(&manager.pool_mutex);

    var i: u32 = 0;
    while (i < types.CARDINAL_MAX_MT_THREADS) : (i += 1) {
        var pool = &manager.thread_pools.?[i];
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

    // Free thread pools array
    if (manager.thread_pools != null) {
        const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(allocator, @ptrCast(manager.thread_pools));
        manager.thread_pools = null;
    }

    cardinal_mt_mutex_unlock(&manager.pool_mutex);
    cardinal_mt_mutex_destroy(&manager.pool_mutex);
    manager.is_initialized = false;
}

pub fn cardinal_mt_get_thread_command_pool(manager: *types.CardinalMTCommandManager) ?*types.CardinalThreadCommandPool {
    if (!manager.is_initialized) return null;

    const thread_id = cardinal_mt_get_current_thread_id();

    cardinal_mt_mutex_lock(&manager.pool_mutex);

    // Find existing pool
    var i: u32 = 0;
    while (i < types.CARDINAL_MAX_MT_THREADS) : (i += 1) {
        const pool = &manager.thread_pools.?[i];
        if (pool.is_active and cardinal_mt_thread_ids_equal(pool.thread_id, thread_id)) {
            cardinal_mt_mutex_unlock(&manager.pool_mutex);
            return pool;
        }
    }

    // Allocate new pool
    i = 0;
    var free_pool: ?*types.CardinalThreadCommandPool = null;
    while (i < types.CARDINAL_MAX_MT_THREADS) : (i += 1) {
        if (!manager.thread_pools.?[i].is_active) {
            free_pool = &manager.thread_pools.?[i];
            break;
        }
    }

    if (free_pool == null) {
        mt_log.err("No free thread command pools available", .{});
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
        mt_log.err("Failed to create primary command pool", .{});
        cardinal_mt_mutex_unlock(&manager.pool_mutex);
        return null;
    }

    if (c.vkCreateCommandPool(vs.context.device, &pool_info, null, &pool.secondary_pool) != c.VK_SUCCESS) {
        mt_log.err("Failed to create secondary command pool", .{});
        c.vkDestroyCommandPool(vs.context.device, pool.primary_pool, null);
        pool.primary_pool = null;
        cardinal_mt_mutex_unlock(&manager.pool_mutex);
        return null;
    }

    pool.secondary_buffer_count = types.CARDINAL_MAX_SECONDARY_COMMAND_BUFFERS;
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    pool.secondary_buffers = @ptrCast(@alignCast(memory.cardinal_alloc(allocator, @sizeOf(c.VkCommandBuffer) * pool.secondary_buffer_count)));

    if (pool.secondary_buffers == null) {
        mt_log.err("Failed to allocate memory for secondary command buffers", .{});
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
        mt_log.err("Failed to allocate secondary command buffers", .{});
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

    mt_log.info("Created command pool for thread (total active: {d})", .{manager.active_thread_count});

    cardinal_mt_mutex_unlock(&manager.pool_mutex);
    return pool;
}

pub fn cardinal_mt_allocate_secondary_command_buffer(pool: *types.CardinalThreadCommandPool, context: *types.CardinalSecondaryCommandContext) bool {
    if (pool.next_secondary_index >= pool.secondary_buffer_count) {
        mt_log.warn("Thread command pool exhausted", .{});
        return false;
    }

    if (pool.secondary_buffers) |bufs| {
        context.command_buffer = bufs[pool.next_secondary_index];
    } else {
        return false;
    }

    pool.next_secondary_index += 1;
    context.is_recording = false;

    context.thread_index = 0;

    return true;
}

pub fn cardinal_mt_begin_secondary_command_buffer(context: *types.CardinalSecondaryCommandContext, inheritance_info: *const c.VkCommandBufferInheritanceInfo) bool {
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT | c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = inheritance_info,
    };

    if (c.vkBeginCommandBuffer(context.command_buffer, &begin_info) != c.VK_SUCCESS) {
        mt_log.err("Failed to begin secondary command buffer", .{});
        return false;
    }

    context.inheritance = inheritance_info.*;
    context.is_recording = true;
    return true;
}

pub fn cardinal_mt_end_secondary_command_buffer(context: *types.CardinalSecondaryCommandContext) bool {
    // Check if we think we are recording
    if (!context.is_recording) {
        mt_log.warn("Attempted to end secondary command buffer that is not recording", .{});
        return false;
    }

    // Try to end the command buffer
    if (c.vkEndCommandBuffer(context.command_buffer) != c.VK_SUCCESS) {
        // If it failed, it might not have been in recording state (validation error), or other error
        mt_log.err("Failed to end secondary command buffer", .{});
        // We still mark it as not recording to avoid stuck state
        context.is_recording = false;
        return false;
    }

    context.is_recording = false;
    return true;
}

pub fn cardinal_mt_execute_secondary_command_buffers(primary_cmd: c.VkCommandBuffer, secondary_contexts: []types.CardinalSecondaryCommandContext) void {
    if (secondary_contexts.len == 0) return;

    const count = @as(u32, @intCast(secondary_contexts.len));

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

pub fn cardinal_mt_reset_all_command_pools(manager: *types.CardinalMTCommandManager) void {
    if (!manager.is_initialized) return;

    cardinal_mt_mutex_lock(&manager.pool_mutex);
    defer cardinal_mt_mutex_unlock(&manager.pool_mutex);

    var i: u32 = 0;
    while (i < types.CARDINAL_MAX_MT_THREADS) : (i += 1) {
        var pool = &manager.thread_pools.?[i];
        if (pool.is_active) {
            const device = manager.vulkan_state.?.context.device;

            // Reset secondary pool
            if (pool.secondary_pool != null) {
                _ = c.vkResetCommandPool(device, pool.secondary_pool, 0);
            }

            // Reset index
            pool.next_secondary_index = 0;
        }
    }
}

pub fn cardinal_mt_wait_task(task: *types.CardinalMTTask) void {
    while (!task.is_completed) {
        if (builtin.os.tag == .windows) {
            c.Sleep(1);
        } else {
            _ = c.usleep(1000);
        }
    }
}

// === Multi-Threading Subsystem Functions ===

pub fn cardinal_mt_subsystem_init(vulkan_state: ?*types.VulkanState, worker_thread_count_in: u32) bool {
    if (g_cardinal_mt_subsystem.is_running) {
        mt_log.warn("Subsystem already initialized", .{});
        return true;
    }

    if (vulkan_state == null) {
        mt_log.err("Invalid Vulkan state for subsystem initialization", .{});
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
        mt_log.err("Failed to initialize command manager", .{});
        return false;
    }

    if (!cardinal_mt_task_queue_init(&g_cardinal_mt_subsystem.pending_queue)) {
        mt_log.err("Failed to initialize pending task queue", .{});
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }

    if (!cardinal_mt_task_queue_init(&g_cardinal_mt_subsystem.completed_queue)) {
        mt_log.err("Failed to initialize completed task queue", .{});
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }

    if (!cardinal_mt_mutex_init(&g_cardinal_mt_subsystem.subsystem_mutex)) {
        mt_log.err("Failed to initialize subsystem mutex", .{});
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }

    g_cardinal_mt_subsystem.worker_thread_count = worker_thread_count;
    g_cardinal_mt_subsystem.is_running = true;

    // Allocate worker threads array
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const threads_ptr = memory.cardinal_alloc(allocator, @sizeOf(?types.cardinal_thread_handle_t) * worker_thread_count);
    if (threads_ptr == null) {
        mt_log.err("Failed to allocate worker threads array", .{});
        cardinal_mt_mutex_destroy(&g_cardinal_mt_subsystem.subsystem_mutex);
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
        cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
        cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
        return false;
    }
    g_cardinal_mt_subsystem.worker_threads = @as([*]?types.cardinal_thread_handle_t, @ptrCast(@alignCast(threads_ptr)))[0..worker_thread_count];

    // Initialize threads to null
    var k: u32 = 0;
    while (k < worker_thread_count) : (k += 1) {
        g_cardinal_mt_subsystem.worker_threads[k] = null;
    }

    var i: u32 = 0;
    while (i < worker_thread_count) : (i += 1) {
        if (!cardinal_mt_create_thread(&g_cardinal_mt_subsystem.worker_threads[i], null)) {
            mt_log.err("Failed to create worker thread {d}", .{i});

            g_cardinal_mt_subsystem.is_running = false;
            cardinal_mt_cond_broadcast(&g_cardinal_mt_subsystem.pending_queue.queue_condition);

            var j: u32 = 0;
            while (j < i) : (j += 1) {
                if (g_cardinal_mt_subsystem.worker_threads[j]) |thread| {
                    cardinal_mt_join_thread(thread);
                }
            }

            memory.cardinal_free(allocator, threads_ptr);
            g_cardinal_mt_subsystem.worker_threads = &.{};

            cardinal_mt_mutex_destroy(&g_cardinal_mt_subsystem.subsystem_mutex);
            cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
            cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
            cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);
            return false;
        }
    }

    mt_log.info("Subsystem initialized with {d} worker threads", .{worker_thread_count});
    return true;
}

pub fn cardinal_mt_subsystem_shutdown() void {
    if (!g_cardinal_mt_subsystem.is_running) return;

    mt_log.info("Shutting down subsystem...", .{});

    g_cardinal_mt_subsystem.is_running = false;
    cardinal_mt_cond_broadcast(&g_cardinal_mt_subsystem.pending_queue.queue_condition);

    var i: u32 = 0;
    while (i < g_cardinal_mt_subsystem.worker_thread_count) : (i += 1) {
        if (g_cardinal_mt_subsystem.worker_threads[i]) |thread| {
            cardinal_mt_join_thread(thread);
        }
    }

    // Free worker threads array
    if (g_cardinal_mt_subsystem.worker_threads.len > 0) {
        const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(allocator, @ptrCast(g_cardinal_mt_subsystem.worker_threads.ptr));
        g_cardinal_mt_subsystem.worker_threads = &.{};
    }

    cardinal_mt_mutex_destroy(&g_cardinal_mt_subsystem.subsystem_mutex);
    cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.completed_queue);
    cardinal_mt_task_queue_shutdown(&g_cardinal_mt_subsystem.pending_queue);
    cardinal_mt_command_manager_shutdown(&g_cardinal_mt_subsystem.command_manager);

    g_cardinal_mt_subsystem = std.mem.zeroes(types.CardinalMTSubsystem);

    mt_log.info("Subsystem shutdown completed", .{});
}

pub fn cardinal_mt_submit_task(task: *types.CardinalMTTask) bool {
    if (!g_cardinal_mt_subsystem.is_running) {
        mt_log.err("Invalid task or subsystem not running", .{});
        return false;
    }

    cardinal_mt_task_queue_push(&g_cardinal_mt_subsystem.pending_queue, task);
    return true;
}

pub fn cardinal_mt_process_completed_tasks(max_tasks: u32) void {
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
            if (t.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_TEXTURE_LOAD) {
                const ctx: *TextureLoadContext = @ptrCast(@alignCast(t.data));
                memory.cardinal_free(allocator, ctx.file_path.ptr);
                // Note: result_resource is ref counted, so if callback didn't take it (and inc ref),
                // we should release it here?
                // The callback gets the context. If it wants to keep the resource, it should have used it.
                // But ref_acquire increments ref count.
                // So here we should release our reference.
                if (ctx.result_resource) |res| {
                    ref_counting.cardinal_ref_release(res);
                }
                memory.cardinal_free(allocator, ctx);
            } else if (t.type == types.CardinalMTTaskType.CARDINAL_MT_TASK_MESH_LOAD) {
                const ctx: *MeshLoadContext = @ptrCast(@alignCast(t.data));
                memory.cardinal_free(allocator, ctx.file_path.ptr);
                // Similar logic for scene
                if (ctx.result_scene) |s| {
                    scene.cardinal_scene_destroy(s);
                    memory.cardinal_free(allocator, s);
                }
                memory.cardinal_free(allocator, ctx);
            }
        }

        memory.cardinal_free(allocator, t);
        processed += 1;
    }
}

// === Task Implementations ===

fn execute_texture_load(data: ?*anyopaque) void {
    if (data == null) return;
    const ctx: *TextureLoadContext = @ptrCast(@alignCast(data));

    // Use the existing texture loader
    var tex_data: texture_loader.TextureData = undefined;
    const ref_res = texture_loader.texture_load_with_ref_counting(ctx.file_path.ptr, &tex_data);

    if (ref_res) |res| {
        ctx.result_resource = res;
    } else {
        mt_log.err("Failed to load texture: {s}", .{ctx.file_path});
        ctx.result_resource = null;
    }
}

pub fn cardinal_mt_create_texture_load_task(file_path: []const u8, callback: ?*const fn (?*anyopaque, bool) void) ?*types.CardinalMTTask {
    if (file_path.len == 0) {
        mt_log.err("Invalid file path for texture load task", .{});
        return null;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const task_ptr = memory.cardinal_alloc(allocator, @sizeOf(types.CardinalMTTask));
    if (task_ptr == null) {
        mt_log.err("Failed to allocate memory for texture load task", .{});
        return null;
    }
    const task: *types.CardinalMTTask = @ptrCast(@alignCast(task_ptr));

    // Allocate context
    const ctx_ptr = memory.cardinal_alloc(allocator, @sizeOf(TextureLoadContext));
    if (ctx_ptr == null) {
        memory.cardinal_free(allocator, task_ptr);
        return null;
    }
    const ctx: *TextureLoadContext = @ptrCast(@alignCast(ctx_ptr));

    // Copy string
    const path_copy_ptr = memory.cardinal_alloc(allocator, file_path.len + 1);
    if (path_copy_ptr == null) {
        memory.cardinal_free(allocator, ctx_ptr);
        memory.cardinal_free(allocator, task_ptr);
        return null;
    }

    const path_slice = @as([*]u8, @ptrCast(path_copy_ptr))[0..file_path.len];
    @memcpy(path_slice, file_path);
    @as([*]u8, @ptrCast(path_copy_ptr))[file_path.len] = 0;

    ctx.file_path = @as([*:0]u8, @ptrCast(path_copy_ptr))[0..file_path.len :0];
    ctx.result_resource = null;

    task.type = types.CardinalMTTaskType.CARDINAL_MT_TASK_TEXTURE_LOAD;
    task.data = ctx;
    task.execute_func = execute_texture_load;
    task.callback_func = callback;
    task.is_completed = false;
    task.success = false;
    task.next = null;

    return task;
}

fn execute_mesh_load(data: ?*anyopaque) void {
    if (data == null) return;
    const ctx: *MeshLoadContext = @ptrCast(@alignCast(data));

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const scene_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalScene));
    if (scene_ptr == null) return;

    const s: *scene.CardinalScene = @ptrCast(@alignCast(scene_ptr));

    if (gltf_loader.cardinal_gltf_load_scene(ctx.file_path.ptr, s)) {
        ctx.result_scene = s;
    } else {
        mt_log.err("Failed to load mesh/scene: {s}", .{ctx.file_path});
        memory.cardinal_free(allocator, scene_ptr);
        ctx.result_scene = null;
    }
}

pub fn cardinal_mt_create_mesh_load_task(file_path: []const u8, callback: ?*const fn (?*anyopaque, bool) void) ?*types.CardinalMTTask {
    if (file_path.len == 0) {
        mt_log.err("Invalid file path for mesh load task", .{});
        return null;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const task_ptr = memory.cardinal_alloc(allocator, @sizeOf(types.CardinalMTTask));
    if (task_ptr == null) {
        mt_log.err("Failed to allocate memory for mesh load task", .{});
        return null;
    }
    const task: *types.CardinalMTTask = @ptrCast(@alignCast(task_ptr));

    // Allocate context
    const ctx_ptr = memory.cardinal_alloc(allocator, @sizeOf(MeshLoadContext));
    if (ctx_ptr == null) {
        memory.cardinal_free(allocator, task_ptr);
        return null;
    }
    const ctx: *MeshLoadContext = @ptrCast(@alignCast(ctx_ptr));

    // Copy string
    const path_copy_ptr = memory.cardinal_alloc(allocator, file_path.len + 1);
    if (path_copy_ptr == null) {
        memory.cardinal_free(allocator, ctx_ptr);
        memory.cardinal_free(allocator, task_ptr);
        return null;
    }

    const path_slice = @as([*]u8, @ptrCast(path_copy_ptr))[0..file_path.len];
    @memcpy(path_slice, file_path);
    @as([*]u8, @ptrCast(path_copy_ptr))[file_path.len] = 0;

    ctx.file_path = @as([*:0]u8, @ptrCast(path_copy_ptr))[0..file_path.len :0];
    ctx.result_scene = null;

    task.type = types.CardinalMTTaskType.CARDINAL_MT_TASK_MESH_LOAD;
    task.data = ctx;
    task.execute_func = execute_mesh_load;
    task.callback_func = callback;
    task.is_completed = false;
    task.success = false;
    task.next = null;

    return task;
}

pub fn cardinal_mt_create_command_record_task(record_func: ?*const fn (?*anyopaque) void, user_data: ?*anyopaque, callback: ?*const fn (?*anyopaque, bool) void) ?*types.CardinalMTTask {
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const task_ptr = memory.cardinal_alloc(allocator, @sizeOf(types.CardinalMTTask));
    if (task_ptr == null) {
        mt_log.err("Failed to allocate memory for command record task", .{});
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
