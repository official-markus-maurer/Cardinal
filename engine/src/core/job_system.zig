const std = @import("std");
const log = @import("log.zig");
const memory = @import("memory.zig");
const pool_allocator = @import("pool_allocator.zig");

const job_log = log.ScopedLogger("JOB_SYSTEM");

// --- Types ---

pub const JobPriority = enum(c_int) {
    LOW = 0,
    NORMAL = 1,
    HIGH = 2,
    CRITICAL = 3,
};

pub const JobStatus = enum(c_int) {
    PENDING = 0,
    RUNNING = 1,
    COMPLETED = 2,
    FAILED = 3,
    CANCELLED = 4,
};

pub const JobFunc = ?*const fn (data: ?*anyopaque) callconv(.c) i32;
pub const JobErrorFunc = ?*const fn (data: ?*anyopaque, error_code: i32) callconv(.c) void;

pub const DependencyNode = struct {
    job: *Job,
    next: ?*DependencyNode,
};

pub const Job = extern struct {
    id: u32,
    priority: JobPriority,
    status: JobStatus,

    func: JobFunc,
    data: ?*anyopaque,

    // Error Handling
    error_func: JobErrorFunc,
    error_code: i32,

    // Internal List
    next: ?*Job,

    // Dependency Graph
    dependency_count: u32,
    dependents_head: ?*DependencyNode,
};

pub const JobSystemConfig = extern struct {
    worker_thread_count: u32,
    max_queue_size: u32,
    enable_priority_queue: bool,
};

// --- Internal State ---

const JobQueue = struct {
    head: ?*Job,
    tail: ?*Job,
    count: u32,
    max_size: u32,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
};

const WorkerThread = struct {
    thread_id: u32,
    should_exit: bool,
    thread: ?std.Thread,
};

const JobSystemState = struct {
    initialized: bool,
    shutting_down: bool,
    config: JobSystemConfig,
    pending_queue: JobQueue,
    waiting_queue: JobQueue,
    completed_queue: JobQueue,
    workers: ?[]WorkerThread,
    next_job_id: u32,
    state_mutex: std.Thread.Mutex,

    allocator: std.mem.Allocator,
    job_pool: pool_allocator.PoolAllocator(Job),
    dependency_pool: pool_allocator.PoolAllocator(DependencyNode),
};

pub var g_job_system: JobSystemState = undefined;

// --- Helper Functions ---

fn job_queue_init(queue: *JobQueue, max_size: u32) void {
    queue.head = null;
    queue.tail = null;
    queue.count = 0;
    queue.max_size = max_size;
    queue.mutex = .{};
    queue.condition = .{};
}

fn job_queue_push(queue: *JobQueue, job: *Job) bool {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    if (queue.max_size > 0 and queue.count >= queue.max_size) {
        return false;
    }

    job.next = null;
    if (queue.tail) |tail| {
        tail.next = job;
    } else {
        queue.head = job;
    }
    queue.tail = job;
    queue.count += 1;

    queue.condition.signal();
    return true;
}

fn job_queue_pop(queue: *JobQueue, wait: bool) ?*Job {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    while (queue.head == null and wait and !g_job_system.shutting_down) {
        queue.condition.wait(&queue.mutex);
    }

    if (queue.head) |job| {
        queue.head = job.next;
        if (queue.head == null) {
            queue.tail = null;
        }
        queue.count -= 1;
        job.next = null;
        return job;
    }

    return null;
}

fn job_queue_remove(queue: *JobQueue, job: *Job) bool {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    if (queue.head == null) return false;

    if (queue.head == job) {
        queue.head = job.next;
        if (queue.head == null) {
            queue.tail = null;
        }
        queue.count -= 1;
        job.next = null;
        return true;
    }

    var current = queue.head;
    while (current) |c| {
        if (c.next == job) {
            c.next = job.next;
            if (job == queue.tail) {
                queue.tail = current;
            }
            queue.count -= 1;
            job.next = null;
            return true;
        }
        current = c.next;
    }

    return false;
}

fn worker_thread_func(worker: *WorkerThread) void {
    // job_log.debug("Job worker thread {d} started", .{worker.thread_id});

    while (!worker.should_exit and !g_job_system.shutting_down) {
        const job_opt = job_queue_pop(&g_job_system.pending_queue, true);

        if (job_opt == null) continue;
        const job = job_opt.?;

        if (job.status == .CANCELLED) {
            _ = job_queue_push(&g_job_system.completed_queue, job);
            continue;
        }

        job.status = .RUNNING;
        if (job.func) |f| {
            const result = f(job.data);
            if (result != 0) {
                job.status = .FAILED;
                job.error_code = result;
                if (job.error_func) |ef| {
                    ef(job.data, result);
                }
            } else {
                job.status = .COMPLETED;
            }
        } else {
            job.status = .COMPLETED;
        }

        _ = job_queue_push(&g_job_system.completed_queue, job);

        // Process dependencies
        g_job_system.state_mutex.lock();
        var node = job.dependents_head;
        while (node) |n| {
            const dependent = n.job;
            if (dependent.dependency_count > 0) {
                dependent.dependency_count -= 1;
                if (dependent.dependency_count == 0) {
                    // Move from waiting to pending
                    if (job_queue_remove(&g_job_system.waiting_queue, dependent)) {
                        _ = job_queue_push(&g_job_system.pending_queue, dependent);
                    }
                }
            }
            const next = n.next;
            g_job_system.dependency_pool.destroy(n);
            node = next;
        }
        job.dependents_head = null;
        g_job_system.state_mutex.unlock();
    }
}

// --- Public API ---

pub fn init(config: ?*const JobSystemConfig) bool {
    if (g_job_system.initialized) return true;

    g_job_system = undefined;
    g_job_system.initialized = false;
    g_job_system.shutting_down = false;
    g_job_system.workers = null;

    if (config) |c| {
        g_job_system.config = c.*;
    } else {
        g_job_system.config.worker_thread_count = 4;
        g_job_system.config.max_queue_size = 1000;
        g_job_system.config.enable_priority_queue = true;
    }

    if (g_job_system.config.worker_thread_count == 0) {
        g_job_system.config.worker_thread_count = 4;
    }

    job_queue_init(&g_job_system.pending_queue, g_job_system.config.max_queue_size);
    job_queue_init(&g_job_system.waiting_queue, g_job_system.config.max_queue_size);
    job_queue_init(&g_job_system.completed_queue, g_job_system.config.max_queue_size);

    g_job_system.state_mutex = .{};
    g_job_system.next_job_id = 0;

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    g_job_system.allocator = allocator.as_allocator();
    g_job_system.job_pool = pool_allocator.PoolAllocator(Job).init(g_job_system.allocator);
    g_job_system.dependency_pool = pool_allocator.PoolAllocator(DependencyNode).init(g_job_system.allocator);

    const workers = memory.cardinal_alloc(allocator, @sizeOf(WorkerThread) * g_job_system.config.worker_thread_count);
    if (workers == null) return false;

    g_job_system.workers = @as([*]WorkerThread, @ptrCast(@alignCast(workers)))[0..g_job_system.config.worker_thread_count];

    var i: u32 = 0;
    while (i < g_job_system.config.worker_thread_count) : (i += 1) {
        g_job_system.workers.?[i] = .{
            .thread_id = i,
            .should_exit = false,
            .thread = null,
        };
        g_job_system.workers.?[i].thread = std.Thread.spawn(.{}, worker_thread_func, .{&g_job_system.workers.?[i]}) catch return false;
    }

    g_job_system.initialized = true;
    job_log.info("Job System initialized with {d} threads", .{g_job_system.config.worker_thread_count});
    return true;
}

pub fn shutdown() void {
    if (!g_job_system.initialized) return;

    job_log.info("Shutting down Job System...", .{});
    g_job_system.shutting_down = true;

    if (g_job_system.workers) |workers| {
        for (workers) |*worker| {
            worker.should_exit = true;
        }
        g_job_system.pending_queue.condition.broadcast();

        for (workers) |*worker| {
            if (worker.thread) |t| {
                t.join();
            }
        }

        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
        memory.cardinal_free(allocator, workers.ptr);
    }

    g_job_system.job_pool.deinit();
    g_job_system.dependency_pool.deinit();

    g_job_system.initialized = false;
}

pub fn create_job(func: JobFunc, data: ?*anyopaque, priority: JobPriority) ?*Job {
    if (!g_job_system.initialized) return null;

    const job = g_job_system.job_pool.create() catch return null;
    @memset(@as([*]u8, @ptrCast(job))[0..@sizeOf(Job)], 0);

    g_job_system.state_mutex.lock();
    g_job_system.next_job_id += 1;
    job.id = g_job_system.next_job_id;
    g_job_system.state_mutex.unlock();

    job.func = func;
    job.data = data;
    job.priority = priority;
    job.status = .PENDING;
    job.error_code = 0;
    job.error_func = null;

    return job;
}

pub fn create_job_with_error_handler(func: JobFunc, data: ?*anyopaque, priority: JobPriority, error_func: JobErrorFunc) ?*Job {
    const job = create_job(func, data, priority);
    if (job) |j| {
        j.error_func = error_func;
    }
    return job;
}

pub fn submit_job(job: *Job) bool {
    if (!g_job_system.initialized) return false;

    // If job has dependencies, put in waiting queue
    if (job.dependency_count > 0) {
        return job_queue_push(&g_job_system.waiting_queue, job);
    }

    return job_queue_push(&g_job_system.pending_queue, job);
}

pub fn free_job(job: *Job) void {
    // Clean up any remaining dependency nodes (though they should be gone if job ran)
    var node = job.dependents_head;
    while (node) |n| {
        const next = n.next;
        g_job_system.dependency_pool.destroy(n);
        node = next;
    }
    job.dependents_head = null;

    g_job_system.job_pool.destroy(job);
}

pub fn add_dependency(dependent: *Job, dependency: *Job) bool {
    if (!g_job_system.initialized) return false;

    g_job_system.state_mutex.lock();
    defer g_job_system.state_mutex.unlock();

    if (dependency.status == .COMPLETED) {
        return true; // Already done, no wait needed
    }

    const node = g_job_system.dependency_pool.create() catch return false;
    node.job = dependent;
    node.next = dependency.dependents_head;
    dependency.dependents_head = node;

    dependent.dependency_count += 1;

    return true;
}

pub fn process_completed_jobs(max_jobs: u32) u32 {
    if (!g_job_system.initialized) return 0;

    var processed: u32 = 0;
    while (max_jobs == 0 or processed < max_jobs) {
        const job = job_queue_pop(&g_job_system.completed_queue, false);
        if (job == null) break;
        // The caller is responsible for freeing the job or handling completion callbacks
        // Since Job doesn't have a callback field (generic), the 'func' or 'data' should handle it,
        // or the system wrapping this (AsyncLoader) handles it.
        processed += 1;
    }
    return processed;
}

pub fn get_completed_job() ?*Job {
    if (!g_job_system.initialized) return null;
    return job_queue_pop(&g_job_system.completed_queue, false);
}

pub fn get_pending_job_count() u32 {
    if (!g_job_system.initialized) return 0;

    g_job_system.pending_queue.mutex.lock();
    defer g_job_system.pending_queue.mutex.unlock();

    return g_job_system.pending_queue.count;
}
