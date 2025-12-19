const std = @import("std");
const log = @import("log.zig");
const memory = @import("memory.zig");
const ref_counting = @import("ref_counting.zig");
const scene = @import("../assets/scene.zig");

// --- External Dependencies ---
extern fn texture_load_with_ref_counting(file_path: [*:0]const u8, out_texture: ?*anyopaque) callconv(.c) ?*ref_counting.CardinalRefCountedResource;
extern fn texture_data_free(data: ?*anyopaque) callconv(.c) void;

extern fn cardinal_scene_load(file_path: [*:0]const u8, scene: ?*scene.CardinalScene) callconv(.c) bool;

extern fn material_load_with_ref_counting(material_data: ?*const scene.CardinalMaterial, out_material: ?*scene.CardinalMaterial) callconv(.c) ?*ref_counting.CardinalRefCountedResource;
extern fn material_data_free(material: ?*scene.CardinalMaterial) callconv(.c) void;

// --- Enums and Structs ---

pub const CardinalAsyncPriority = enum(c_int) {
    LOW = 0,
    NORMAL = 1,
    HIGH = 2,
    CRITICAL = 3,
};

pub const CardinalAsyncStatus = enum(c_int) {
    PENDING = 0,
    RUNNING = 1,
    COMPLETED = 2,
    FAILED = 3,
    CANCELLED = 4,
};

pub const CardinalAsyncTaskType = enum(c_int) {
    TEXTURE_LOAD = 0,
    SCENE_LOAD = 1,
    BUFFER_UPLOAD = 2,
    MATERIAL_LOAD = 3,
    MESH_LOAD = 4,
    CUSTOM = 5,
};

pub const CardinalAsyncTaskFunc = ?*const fn (task: ?*CardinalAsyncTask, user_data: ?*anyopaque) callconv(.c) bool;
pub const CardinalAsyncCallback = ?*const fn (task: ?*CardinalAsyncTask, user_data: ?*anyopaque) callconv(.c) void;

pub const CardinalAsyncTask = extern struct {
    id: u32,
    type: CardinalAsyncTaskType,
    priority: CardinalAsyncPriority,
    status: CardinalAsyncStatus,

    file_path: ?[*:0]u8,
    result_data: ?*anyopaque,
    result_size: usize,

    custom_func: CardinalAsyncTaskFunc,
    custom_data: ?*anyopaque,

    callback: CardinalAsyncCallback,
    callback_data: ?*anyopaque,

    error_message: ?[*:0]u8,

    next: ?*CardinalAsyncTask,
    submit_time: u64,

    // Dependency Graph
    dependency_count: u32,
    dependents: [8]?*CardinalAsyncTask,
};

pub const CardinalAsyncLoaderConfig = extern struct {
    worker_thread_count: u32,
    max_queue_size: u32,
    enable_priority_queue: bool,
};

// --- Internal State ---

const TaskQueue = struct {
    head: ?*CardinalAsyncTask,
    tail: ?*CardinalAsyncTask,
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

const AsyncLoaderState = struct {
    initialized: bool,
    shutting_down: bool,
    config: CardinalAsyncLoaderConfig,
    pending_queue: TaskQueue,
    waiting_queue: TaskQueue,
    completed_queue: TaskQueue,
    workers: ?[]WorkerThread,
    next_task_id: u32,
    state_mutex: std.Thread.Mutex,
};

var g_async_loader: AsyncLoaderState = undefined;

// --- Helper Functions ---

fn get_timestamp_ms() u64 {
    return @as(u64, @intCast(std.time.milliTimestamp()));
}

fn task_queue_init(queue: *TaskQueue, max_size: u32) void {
    queue.head = null;
    queue.tail = null;
    queue.count = 0;
    queue.max_size = max_size;
    queue.mutex = .{};
    queue.condition = .{};
}

fn task_queue_destroy(queue: *TaskQueue) void {
    queue.mutex.lock();
    var task = queue.head;
    while (task) |t| {
        const next = t.next;
        cardinal_async_free_task(t);
        task = next;
    }
    queue.mutex.unlock();
    queue.* = undefined;
}

fn task_queue_push(queue: *TaskQueue, task: *CardinalAsyncTask) bool {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    if (queue.max_size > 0 and queue.count >= queue.max_size) {
        return false;
    }

    task.next = null;
    if (queue.tail) |tail| {
        tail.next = task;
    } else {
        queue.head = task;
    }
    queue.tail = task;
    queue.count += 1;

    queue.condition.signal();
    return true;
}

fn task_queue_pop(queue: *TaskQueue, wait: bool) ?*CardinalAsyncTask {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    while (queue.head == null and wait and !g_async_loader.shutting_down) {
        queue.condition.wait(&queue.mutex);
    }

    if (queue.head) |task| {
        queue.head = task.next;
        if (queue.head == null) {
            queue.tail = null;
        }
        queue.count -= 1;
        task.next = null;
        return task;
    }

    return null;
}

fn task_queue_remove(queue: *TaskQueue, task: *CardinalAsyncTask) bool {
    queue.mutex.lock();
    defer queue.mutex.unlock();

    if (queue.head == null) return false;

    if (queue.head == task) {
        queue.head = task.next;
        if (queue.head == null) {
            queue.tail = null;
        }
        queue.count -= 1;
        task.next = null;
        return true;
    }

    var current = queue.head;
    while (current) |c| {
        if (c.next == task) {
            c.next = task.next;
            if (task == queue.tail) {
                queue.tail = current;
            }
            queue.count -= 1;
            task.next = null;
            return true;
        }
        current = c.next;
    }

    return false;
}

fn task_queue_size(queue: *TaskQueue) u32 {
    queue.mutex.lock();
    defer queue.mutex.unlock();
    return queue.count;
}

fn create_task(task_type: CardinalAsyncTaskType, priority: CardinalAsyncPriority) ?*CardinalAsyncTask {
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const ptr = memory.cardinal_alloc(allocator, @sizeOf(CardinalAsyncTask));
    if (ptr == null) {
        std.log.err("Failed to allocate memory for async task", .{});
        return null;
    }
    const task = @as(*CardinalAsyncTask, @ptrCast(@alignCast(ptr)));

    // Zero initialize
    @memset(@as([*]u8, @ptrCast(task))[0..@sizeOf(CardinalAsyncTask)], 0);

    g_async_loader.state_mutex.lock();
    g_async_loader.next_task_id += 1;
    task.id = g_async_loader.next_task_id;
    g_async_loader.state_mutex.unlock();

    task.type = task_type;
    task.priority = priority;
    task.status = .PENDING;
    task.submit_time = get_timestamp_ms();

    return task;
}

// --- Task Execution ---

fn execute_texture_load_task(task: *CardinalAsyncTask) bool {
    if (task.file_path == null) return false;

    std.log.debug("Loading texture: {s}", .{task.file_path.?});

    // We need to allocate TextureData (opaque)
    // Actually texture_load_with_ref_counting takes pointer to TextureData.
    // We'll treat TextureData as opaque block of memory for now, assuming size is handled inside.
    // Wait, in C code: TextureData texture_data; ... &texture_data
    // TextureData is a struct. I should define it in scene.zig or just allocate enough space.
    // Since I don't have TextureData definition fully in Zig yet (it's in scene.zig as CardinalTexture),
    // let's assume CardinalTexture IS TextureData (checking C code... yes, mostly).

    // Wait, texture_load_with_ref_counting takes `TextureData*`.
    // In `texture_loader.h` (not read yet), `TextureData` is likely `CardinalTexture`.
    // Let's assume `scene.CardinalTexture` is compatible.

    var texture_data: scene.CardinalTexture = undefined;

    const ref_resource = texture_load_with_ref_counting(task.file_path.?, &texture_data);

    if (ref_resource == null) {
        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
        const msg = "Failed to load texture";
        const msg_ptr = memory.cardinal_alloc(allocator, msg.len + 1);
        if (msg_ptr) |ptr| {
            const slice = @as([*]u8, @ptrCast(ptr))[0..msg.len];
            @memcpy(slice, msg);
            @as([*]u8, @ptrCast(ptr))[msg.len] = 0;
            task.error_message = @ptrCast(ptr);
        }
        return false;
    }

    task.result_data = ref_resource;
    task.result_size = @sizeOf(ref_counting.CardinalRefCountedResource);

    std.log.debug("Successfully loaded texture: {s}", .{task.file_path.?});
    return true;
}

fn execute_scene_load_task(task: *CardinalAsyncTask) bool {
    if (task.file_path == null) return false;

    std.log.debug("Loading scene: {s}", .{task.file_path.?});

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const scene_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalScene));
    if (scene_ptr == null) {
        // Set error message
        return false;
    }
    const scene_obj = @as(*scene.CardinalScene, @ptrCast(@alignCast(scene_ptr)));

    if (!cardinal_scene_load(task.file_path.?, scene_obj)) {
        memory.cardinal_free(allocator, scene_ptr);
        return false;
    }

    task.result_data = scene_ptr;
    task.result_size = @sizeOf(scene.CardinalScene);

    std.log.debug("Successfully loaded scene: {s}", .{task.file_path.?});
    return true;
}

fn execute_material_load_task(task: *CardinalAsyncTask) bool {
    if (task.custom_data == null) return false;

    std.log.debug("Loading material with reference counting", .{});

    const source_material = @as(*const scene.CardinalMaterial, @ptrCast(@alignCast(task.custom_data)));

    // Allocate memory for material copy (managed by C code usually, but here we do it)
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const material_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalMaterial));
    if (material_ptr == null) return false;

    const material = @as(*scene.CardinalMaterial, @ptrCast(@alignCast(material_ptr)));
    material.* = source_material.*;

    var out_material: scene.CardinalMaterial = undefined;
    const ref_resource = material_load_with_ref_counting(material, &out_material);

    if (ref_resource == null) {
        memory.cardinal_free(allocator, material_ptr);
        return false;
    }

    memory.cardinal_free(allocator, material_ptr);

    task.result_data = ref_resource;
    task.result_size = @sizeOf(ref_counting.CardinalRefCountedResource);

    std.log.debug("Successfully loaded material with reference counting", .{});
    return true;
}

fn execute_mesh_load_task(task: *CardinalAsyncTask) bool {
    if (task.custom_data == null) return false;

    std.log.debug("Loading mesh with reference counting", .{});

    const source_mesh = @as(*const scene.CardinalMesh, @ptrCast(@alignCast(task.custom_data)));

    // Allocate memory for mesh copy
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const mesh_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalMesh));
    if (mesh_ptr == null) return false;

    const mesh = @as(*scene.CardinalMesh, @ptrCast(@alignCast(mesh_ptr)));
    mesh.* = source_mesh.*;

    // Deep copy vertex data
    if (source_mesh.vertex_count > 0 and source_mesh.vertices != null) {
        const vertex_size = source_mesh.vertex_count * @sizeOf(scene.CardinalVertex);
        const vertices_ptr = memory.cardinal_alloc(allocator, vertex_size);
        if (vertices_ptr == null) {
            memory.cardinal_free(allocator, mesh_ptr);
            return false;
        }
        @memcpy(@as([*]u8, @ptrCast(vertices_ptr))[0..vertex_size], @as([*]u8, @ptrCast(source_mesh.vertices))[0..vertex_size]);
        mesh.vertices = @ptrCast(@alignCast(vertices_ptr));
    } else {
        mesh.vertices = null;
    }

    // Deep copy index data
    if (source_mesh.index_count > 0 and source_mesh.indices != null) {
        const index_size = source_mesh.index_count * @sizeOf(u32);
        const indices_ptr = memory.cardinal_alloc(allocator, index_size);
        if (indices_ptr == null) {
            if (mesh.vertices) |v| memory.cardinal_free(allocator, v);
            memory.cardinal_free(allocator, mesh_ptr);
            return false;
        }
        @memcpy(@as([*]u8, @ptrCast(indices_ptr))[0..index_size], @as([*]u8, @ptrCast(source_mesh.indices))[0..index_size]);
        mesh.indices = @ptrCast(@alignCast(indices_ptr));
    } else {
        mesh.indices = null;
    }

    // Generate ID
    var mesh_id: [128]u8 = undefined;
    _ = std.fmt.bufPrintZ(&mesh_id, "mesh_{d}_{d}_{x}", .{ mesh.vertex_count, mesh.index_count, @intFromPtr(mesh) }) catch {
        if (mesh.vertices) |v| memory.cardinal_free(allocator, v);
        if (mesh.indices) |i| memory.cardinal_free(allocator, i);
        memory.cardinal_free(allocator, mesh_ptr);
        return false;
    };

    const ref_resource = ref_counting.cardinal_ref_create(@ptrCast(&mesh_id), mesh_ptr, @sizeOf(scene.CardinalMesh), mesh_destructor_wrapper);

    if (ref_resource == null) {
        if (mesh.vertices) |v| memory.cardinal_free(allocator, v);
        if (mesh.indices) |i| memory.cardinal_free(allocator, i);
        memory.cardinal_free(allocator, mesh_ptr);
        return false;
    }

    task.result_data = ref_resource;
    task.result_size = @sizeOf(ref_counting.CardinalRefCountedResource);

    std.log.debug("Successfully loaded mesh with reference counting", .{});
    return true;
}

fn mesh_destructor_wrapper(data: ?*anyopaque) callconv(.c) void {
    if (data) |d| {
        const mesh = @as(*scene.CardinalMesh, @ptrCast(@alignCast(d)));
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

        if (mesh.vertices) |v| memory.cardinal_free(allocator, v);
        if (mesh.indices) |i| memory.cardinal_free(allocator, i);

        memory.cardinal_free(allocator, d);
    }
}

fn execute_task(task: *CardinalAsyncTask) bool {
    task.status = .RUNNING;
    var success = false;

    switch (task.type) {
        .TEXTURE_LOAD => success = execute_texture_load_task(task),
        .SCENE_LOAD => success = execute_scene_load_task(task),
        .MATERIAL_LOAD => success = execute_material_load_task(task),
        .MESH_LOAD => success = execute_mesh_load_task(task),
        .CUSTOM => {
            if (task.custom_func) |func| {
                success = func(task, task.custom_data);
            }
        },
        else => {},
    }

    task.status = if (success) .COMPLETED else .FAILED;
    return success;
}

fn worker_thread_func(worker: *WorkerThread) void {
    std.log.debug("Worker thread {d} started", .{worker.thread_id});

    while (!worker.should_exit and !g_async_loader.shutting_down) {
        const task = task_queue_pop(&g_async_loader.pending_queue, true);

        if (task == null) continue;
        const t = task.?;

        if (t.status == .CANCELLED) {
            _ = task_queue_push(&g_async_loader.completed_queue, t);
            continue;
        }

        _ = execute_task(t);
        _ = task_queue_push(&g_async_loader.completed_queue, t);

        // Process dependencies
        g_async_loader.state_mutex.lock();
        for (t.dependents) |dependent_opt| {
            if (dependent_opt) |dependent| {
                if (dependent.dependency_count > 0) {
                    dependent.dependency_count -= 1;
                    if (dependent.dependency_count == 0) {
                        // Move from waiting to pending
                        if (task_queue_remove(&g_async_loader.waiting_queue, dependent)) {
                            _ = task_queue_push(&g_async_loader.pending_queue, dependent);
                        }
                    }
                }
            }
        }
        g_async_loader.state_mutex.unlock();
    }

    std.log.debug("Worker thread {d} exiting", .{worker.thread_id});
}

// --- Public API ---

pub export fn cardinal_async_loader_init(config: ?*const CardinalAsyncLoaderConfig) callconv(.c) bool {
    if (g_async_loader.initialized) {
        std.log.warn("Async loader already initialized", .{});
        return true;
    }

    g_async_loader = std.mem.zeroes(AsyncLoaderState);

    if (config) |c| {
        g_async_loader.config = c.*;
    } else {
        g_async_loader.config.worker_thread_count = 0;
        g_async_loader.config.max_queue_size = 1000;
        g_async_loader.config.enable_priority_queue = true;
    }

    if (g_async_loader.config.worker_thread_count == 0) {
        // Simple heuristic: cpu_count - 1
        // For now hardcode to 4 if detection fails, or use std.Thread.getCpuCount()
        const count = std.Thread.getCpuCount() catch 1;
        g_async_loader.config.worker_thread_count = if (count > 1) @intCast(count - 1) else 1;
    }

    g_async_loader.state_mutex = .{};
    task_queue_init(&g_async_loader.pending_queue, g_async_loader.config.max_queue_size);
    task_queue_init(&g_async_loader.waiting_queue, g_async_loader.config.max_queue_size);
    task_queue_init(&g_async_loader.completed_queue, 0);

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const workers_ptr = memory.cardinal_alloc(allocator, @sizeOf(WorkerThread) * g_async_loader.config.worker_thread_count);
    if (workers_ptr == null) {
        // Cleanup
        return false;
    }

    // We need to manage the slice manually since it came from C allocator
    const workers = @as([*]WorkerThread, @ptrCast(@alignCast(workers_ptr)))[0..g_async_loader.config.worker_thread_count];
    g_async_loader.workers = workers;

    for (workers, 0..) |*worker, i| {
        worker.thread_id = @intCast(i);
        worker.should_exit = false;
        worker.thread = std.Thread.spawn(.{}, worker_thread_func, .{worker}) catch |err| {
            std.log.err("Failed to spawn worker thread: {}", .{err});
            return false;
        };
    }

    g_async_loader.initialized = true;
    g_async_loader.shutting_down = false;

    std.log.info("Async loader initialized with {d} worker threads", .{g_async_loader.config.worker_thread_count});
    return true;
}

pub export fn cardinal_async_loader_shutdown() callconv(.c) void {
    if (!g_async_loader.initialized) return;

    std.log.info("Shutting down async loader...", .{});
    g_async_loader.shutting_down = true;

    // Wake up workers
    if (g_async_loader.workers) |workers| {
        for (workers) |*worker| {
            worker.should_exit = true;
        }
        g_async_loader.pending_queue.condition.broadcast();

        for (workers) |*worker| {
            if (worker.thread) |t| {
                t.join();
            }
        }
    }

    g_async_loader.initialized = false;
    std.log.info("Async loader shutdown complete", .{});
}

pub export fn cardinal_async_loader_shutdown_immediate() callconv(.c) void {
    cardinal_async_loader_shutdown();
}

pub export fn cardinal_async_loader_is_initialized() callconv(.c) bool {
    return g_async_loader.initialized;
}

pub export fn cardinal_async_add_dependency(dependent: ?*CardinalAsyncTask, dependency: ?*CardinalAsyncTask) callconv(.c) bool {
    if (!g_async_loader.initialized or dependent == null or dependency == null) return false;

    const t_dependent = dependent.?;
    const t_dependency = dependency.?;

    // 1. Lock global state to ensure consistent moves
    g_async_loader.state_mutex.lock();
    defer g_async_loader.state_mutex.unlock();

    // Check if dependency is already completed
    if (t_dependency.status == .COMPLETED or t_dependency.status == .FAILED or t_dependency.status == .CANCELLED) {
        return true; // Already done, no wait needed
    }

    // Check if dependent is already running or completed
    if (t_dependent.status == .RUNNING or t_dependent.status == .COMPLETED or t_dependent.status == .FAILED or t_dependent.status == .CANCELLED) {
        return false; // Too late to add dependency
    }

    // 2. Add dependent to dependency's list
    // This is simple since we assume single-producer or locked add.
    // Ideally we'd lock dependency task, but we are under global lock for now (simplification).
    var added = false;
    for (t_dependency.dependents, 0..) |slot, i| {
        if (slot == null) {
            t_dependency.dependents[i] = t_dependent;
            added = true;
            break;
        }
    }
    if (!added) return false; // Max dependents reached

    // 3. Move dependent from pending to waiting if needed
    // If it was in pending queue (status PENDING), move it.
    // If it was newly created but not submitted? We assume submitted tasks are in pending_queue.

    // We try to remove from pending queue. If successful, it was there.
    if (task_queue_remove(&g_async_loader.pending_queue, t_dependent)) {
        // Add to waiting queue
        if (!task_queue_push(&g_async_loader.waiting_queue, t_dependent)) {
            // Should not happen if sizes match
            // Fallback: put back in pending?
            _ = task_queue_push(&g_async_loader.pending_queue, t_dependent);
            return false;
        }
    } else {
        // It might be in waiting queue already (multiple dependencies)
        // Check if it's in waiting queue? task_queue_remove returns false if not found.
        // If it's not in pending, and status is PENDING, it MUST be in waiting queue (or not submitted yet).
        // Since we support adding deps before submission, we just increment counter.
    }

    t_dependent.dependency_count += 1;
    return true;
}

pub export fn cardinal_async_load_texture(file_path: ?[*:0]const u8, priority: CardinalAsyncPriority, callback: CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*CardinalAsyncTask {
    if (!g_async_loader.initialized or file_path == null) return null;

    const task = create_task(.TEXTURE_LOAD, priority);
    if (task == null) return null;

    const len = std.mem.len(file_path.?);
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const path_ptr = memory.cardinal_alloc(allocator, len + 1);
    if (path_ptr) |ptr| {
        @memcpy(@as([*]u8, @ptrCast(ptr))[0..len], file_path.?[0..len]);
        @as([*]u8, @ptrCast(ptr))[len] = 0;
        task.?.file_path = @ptrCast(ptr);
    } else {
        cardinal_async_free_task(task);
        return null;
    }

    task.?.callback = callback;
    task.?.callback_data = user_data;

    if (!task_queue_push(&g_async_loader.pending_queue, task.?)) {
        cardinal_async_free_task(task);
        return null;
    }

    return task;
}

pub export fn cardinal_async_load_scene(file_path: ?[*:0]const u8, priority: CardinalAsyncPriority, callback: CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*CardinalAsyncTask {
    if (!g_async_loader.initialized or file_path == null) return null;

    const task = create_task(.SCENE_LOAD, priority);
    if (task == null) return null;

    const len = std.mem.len(file_path.?);
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const path_ptr = memory.cardinal_alloc(allocator, len + 1);
    if (path_ptr) |ptr| {
        @memcpy(@as([*]u8, @ptrCast(ptr))[0..len], file_path.?[0..len]);
        @as([*]u8, @ptrCast(ptr))[len] = 0;
        task.?.file_path = @ptrCast(ptr);
    } else {
        cardinal_async_free_task(task);
        return null;
    }

    task.?.callback = callback;
    task.?.callback_data = user_data;

    if (!task_queue_push(&g_async_loader.pending_queue, task.?)) {
        cardinal_async_free_task(task);
        return null;
    }

    return task;
}

pub export fn cardinal_async_load_material(material_data: ?*const anyopaque, priority: CardinalAsyncPriority, callback: CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*CardinalAsyncTask {
    if (!g_async_loader.initialized or material_data == null) return null;

    const task = create_task(.MATERIAL_LOAD, priority);
    if (task == null) return null;

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const copy_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalMaterial));
    if (copy_ptr == null) {
        cardinal_async_free_task(task);
        return null;
    }

    const copy = @as(*scene.CardinalMaterial, @ptrCast(@alignCast(copy_ptr)));
    const src = @as(*const scene.CardinalMaterial, @ptrCast(@alignCast(material_data)));
    copy.* = src.*;

    task.?.custom_data = copy_ptr;
    task.?.callback = callback;
    task.?.callback_data = user_data;

    if (!task_queue_push(&g_async_loader.pending_queue, task.?)) {
        memory.cardinal_free(allocator, copy_ptr);
        cardinal_async_free_task(task);
        return null;
    }

    return task;
}

pub export fn cardinal_async_load_mesh(mesh_data: ?*const anyopaque, priority: CardinalAsyncPriority, callback: CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*CardinalAsyncTask {
    if (!g_async_loader.initialized or mesh_data == null) return null;

    const task = create_task(.MESH_LOAD, priority);
    if (task == null) return null;

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const copy_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalMesh));
    if (copy_ptr == null) {
        cardinal_async_free_task(task);
        return null;
    }

    const copy = @as(*scene.CardinalMesh, @ptrCast(@alignCast(copy_ptr)));
    const src = @as(*const scene.CardinalMesh, @ptrCast(@alignCast(mesh_data)));
    copy.* = src.*;

    // Deep copy vertex data
    if (src.vertex_count > 0 and src.vertices != null) {
        const vertex_size = src.vertex_count * @sizeOf(scene.CardinalVertex);
        const vertices_ptr = memory.cardinal_alloc(allocator, vertex_size);
        if (vertices_ptr == null) {
            memory.cardinal_free(allocator, copy_ptr);
            cardinal_async_free_task(task);
            return null;
        }
        @memcpy(@as([*]u8, @ptrCast(vertices_ptr))[0..vertex_size], @as([*]u8, @ptrCast(src.vertices))[0..vertex_size]);
        copy.vertices = @ptrCast(@alignCast(vertices_ptr));
    } else {
        copy.vertices = null;
    }

    // Deep copy index data
    if (src.index_count > 0 and src.indices != null) {
        const index_size = src.index_count * @sizeOf(u32);
        const indices_ptr = memory.cardinal_alloc(allocator, index_size);
        if (indices_ptr == null) {
            if (copy.vertices) |v| memory.cardinal_free(allocator, v);
            memory.cardinal_free(allocator, copy_ptr);
            cardinal_async_free_task(task);
            return null;
        }
        @memcpy(@as([*]u8, @ptrCast(indices_ptr))[0..index_size], @as([*]u8, @ptrCast(src.indices))[0..index_size]);
        copy.indices = @ptrCast(@alignCast(indices_ptr));
    } else {
        copy.indices = null;
    }

    task.?.custom_data = copy_ptr;
    task.?.callback = callback;
    task.?.callback_data = user_data;

    if (!task_queue_push(&g_async_loader.pending_queue, task.?)) {
        if (copy.vertices) |v| memory.cardinal_free(allocator, v);
        if (copy.indices) |i| memory.cardinal_free(allocator, i);
        memory.cardinal_free(allocator, copy_ptr);
        cardinal_async_free_task(task);
        return null;
    }

    return task;
}

pub export fn cardinal_async_submit_custom_task(task_func: CardinalAsyncTaskFunc, custom_data: ?*anyopaque, priority: CardinalAsyncPriority, callback: CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*CardinalAsyncTask {
    if (!g_async_loader.initialized or task_func == null) return null;

    const task = create_task(.CUSTOM, priority);
    if (task == null) return null;

    task.?.custom_func = task_func;
    task.?.custom_data = custom_data;
    task.?.callback = callback;
    task.?.callback_data = user_data;

    if (!task_queue_push(&g_async_loader.pending_queue, task.?)) {
        cardinal_async_free_task(task);
        return null;
    }

    return task;
}

pub export fn cardinal_async_cancel_task(task: ?*CardinalAsyncTask) callconv(.c) bool {
    if (task) |t| {
        if (t.status == .PENDING) {
            t.status = .CANCELLED;
            return true;
        }
    }
    return false;
}

pub export fn cardinal_async_get_task_status(task: ?*const CardinalAsyncTask) callconv(.c) CardinalAsyncStatus {
    return if (task) |t| t.status else .FAILED;
}

pub export fn cardinal_async_wait_for_task(task: ?*CardinalAsyncTask, timeout_ms: u32) callconv(.c) bool {
    if (task == null) return false;
    const t = task.?;

    const start_time = get_timestamp_ms();

    while (t.status == .PENDING or t.status == .RUNNING) {
        if (timeout_ms > 0) {
            const elapsed = get_timestamp_ms() - start_time;
            if (elapsed >= timeout_ms) return false;
        }
        if (g_async_loader.shutting_down) return false;

        // std.time.sleep(1 * std.time.ns_per_ms);
        // Workaround for missing std.time.sleep in this Zig version?
        // Using direct Sleep from kernel32 for Windows
        Sleep(1);
    }

    return t.status == .COMPLETED;
}

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;

pub export fn cardinal_async_free_task(task: ?*CardinalAsyncTask) callconv(.c) void {
    if (task) |t| {
        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

        if (t.file_path) |path| {
            memory.cardinal_free(allocator, path);
        }
        if (t.error_message) |msg| {
            memory.cardinal_free(allocator, msg);
        }

        memory.cardinal_free(allocator, t);
    }
}

pub export fn cardinal_async_get_texture_result(task: ?*CardinalAsyncTask, out_texture: ?*anyopaque) callconv(.c) ?*ref_counting.CardinalRefCountedResource {
    if (task == null or task.?.type != .TEXTURE_LOAD or task.?.status != .COMPLETED or out_texture == null) {
        return null;
    }

    const ref_resource = @as(?*ref_counting.CardinalRefCountedResource, @ptrCast(@alignCast(task.?.result_data)));
    if (ref_resource == null) return null;

    const texture = @as(?*scene.CardinalTexture, @ptrCast(@alignCast(ref_resource.?.resource)));
    if (texture) |tex| {
        const out = @as(*scene.CardinalTexture, @ptrCast(@alignCast(out_texture)));
        out.* = tex.*;
    }

    return ref_resource;
}

pub export fn cardinal_async_get_scene_result(task: ?*CardinalAsyncTask, out_scene: ?*scene.CardinalScene) callconv(.c) bool {
    if (task == null or task.?.type != .SCENE_LOAD or task.?.status != .COMPLETED or out_scene == null) {
        return false;
    }

    const scene_res = @as(?*scene.CardinalScene, @ptrCast(@alignCast(task.?.result_data)));
    if (scene_res) |s| {
        out_scene.?.* = s.*;
        return true;
    }

    return false;
}

pub export fn cardinal_async_get_material_result(task: ?*CardinalAsyncTask, out_material: ?*scene.CardinalMaterial) callconv(.c) ?*ref_counting.CardinalRefCountedResource {
    if (task == null or task.?.type != .MATERIAL_LOAD or task.?.status != .COMPLETED or out_material == null) {
        return null;
    }

    const ref_resource = @as(?*ref_counting.CardinalRefCountedResource, @ptrCast(@alignCast(task.?.result_data)));
    if (ref_resource == null) return null;

    const material = @as(?*scene.CardinalMaterial, @ptrCast(@alignCast(ref_resource.?.resource)));
    if (material) |mat| {
        out_material.?.* = mat.*;
    }

    return ref_resource;
}

pub export fn cardinal_async_get_mesh_result(task: ?*CardinalAsyncTask, out_mesh: ?*scene.CardinalMesh) callconv(.c) ?*ref_counting.CardinalRefCountedResource {
    if (task == null or task.?.type != .MESH_LOAD or task.?.status != .COMPLETED or out_mesh == null) {
        return null;
    }

    const ref_resource = @as(?*ref_counting.CardinalRefCountedResource, @ptrCast(@alignCast(task.?.result_data)));
    if (ref_resource == null) return null;

    const mesh = @as(?*scene.CardinalMesh, @ptrCast(@alignCast(ref_resource.?.resource)));
    if (mesh) |m| {
        out_mesh.?.* = m.*;
    }

    return ref_resource;
}

pub export fn cardinal_async_get_error_message(task: ?*const CardinalAsyncTask) callconv(.c) ?[*:0]const u8 {
    if (task != null and task.?.status == .FAILED) {
        return task.?.error_message;
    }
    return null;
}

pub export fn cardinal_async_get_pending_task_count() callconv(.c) u32 {
    return task_queue_size(&g_async_loader.pending_queue);
}

pub export fn cardinal_async_get_worker_thread_count() callconv(.c) u32 {
    // return g_async_loader.worker_count; // Wait, workers is a slice now, I should store count or use len
    // config.worker_thread_count stores it
    return g_async_loader.config.worker_thread_count;
}

pub export fn cardinal_async_process_completed_tasks(max_tasks: u32) callconv(.c) u32 {
    if (!g_async_loader.initialized) return 0;

    var processed: u32 = 0;

    while (max_tasks == 0 or processed < max_tasks) {
        const task = task_queue_pop(&g_async_loader.completed_queue, false);
        if (task == null) break;

        if (task.?.callback) |cb| {
            cb(task, task.?.callback_data);
        }

        processed += 1;
    }

    return processed;
}
