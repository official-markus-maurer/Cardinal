const std = @import("std");
const log = @import("log.zig");
const memory = @import("memory.zig");
const handles = @import("handles.zig");

const async_log = log.ScopedLogger("ASYNC");

const ref_counting = @import("ref_counting.zig");
const scene = @import("../assets/scene.zig");
const job_system = @import("job_system.zig");

// Function Pointers
pub const Loaders = struct {
    pub var texture_load_fn: ?*const fn (file_path: ?[*]const u8, out_texture: ?*anyopaque) callconv(.c) ?*ref_counting.CardinalRefCountedResource = null;
    pub var scene_load_fn: ?*const fn (file_path: ?[*:0]const u8, scene: ?*scene.CardinalScene) callconv(.c) bool = null;
    pub var ecs_scene_load_fn: ?*const fn (file_path: ?[*:0]const u8) callconv(.c) ?*anyopaque = null;
};

pub export fn cardinal_async_register_texture_loader(load_fn: *const fn (?[*]const u8, ?*anyopaque) callconv(.c) ?*ref_counting.CardinalRefCountedResource) callconv(.c) void {
    Loaders.texture_load_fn = load_fn;
}

pub export fn cardinal_async_register_scene_loader(load_fn: *const fn (?[*:0]const u8, ?*scene.CardinalScene) callconv(.c) bool) callconv(.c) void {
    Loaders.scene_load_fn = load_fn;
}

pub export fn cardinal_async_register_ecs_scene_loader(load_fn: *const fn (?[*:0]const u8) callconv(.c) ?*anyopaque) callconv(.c) void {
    Loaders.ecs_scene_load_fn = load_fn;
}

// Enums and Structs
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
    ECS_SCENE_LOAD = 6,
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

    next: ?*CardinalAsyncTask, // Used to store pointer to underlying Job
    submit_time: u64,
};

pub const CardinalAsyncLoaderConfig = extern struct {
    worker_thread_count: u32,
    max_queue_size: u32,
    enable_priority_queue: bool,
};

// Internal State
const TaskSlot = struct {
    task: ?*CardinalAsyncTask,
    generation: u32,
};

const AsyncLoaderState = struct {
    initialized: bool,
    shutting_down: bool,
    config: CardinalAsyncLoaderConfig,
    next_task_id: u32,
    state_mutex: std.Thread.Mutex,

    task_pool: std.ArrayListUnmanaged(TaskSlot),
    free_indices: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
};

var g_async_loader: AsyncLoaderState = undefined;

// Helper Functions
fn get_timestamp_ms() u64 {
    return @as(u64, @intCast(std.time.milliTimestamp()));
}

fn execute_task_job(data: ?*anyopaque) callconv(.c) i32 {
    if (data) |d| {
        const task = @as(*CardinalAsyncTask, @ptrCast(@alignCast(d)));
        if (execute_task(task)) {
            return 0;
        } else {
            return -1; // Generic error code
        }
    }
    return -1;
}

fn create_task(task_type: CardinalAsyncTaskType, priority: CardinalAsyncPriority) ?*CardinalAsyncTask {
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const ptr = memory.cardinal_alloc(allocator, @sizeOf(CardinalAsyncTask));
    if (ptr == null) {
        async_log.err("Failed to allocate memory for async task", .{});
        return null;
    }
    const task = @as(*CardinalAsyncTask, @ptrCast(@alignCast(ptr)));

    // Zero initialize
    @memset(@as([*]u8, @ptrCast(task))[0..@sizeOf(CardinalAsyncTask)], 0);

    g_async_loader.state_mutex.lock();

    var index: u32 = 0;
    var generation: u32 = 1;

    if (g_async_loader.free_indices.items.len > 0) {
        index = g_async_loader.free_indices.pop().?;
        generation = g_async_loader.task_pool.items[index].generation + 1;
        if (generation == 0) generation = 1;
        g_async_loader.task_pool.items[index] = .{ .task = task, .generation = generation };
    } else {
        index = @intCast(g_async_loader.task_pool.items.len);
        g_async_loader.task_pool.append(g_async_loader.allocator, .{ .task = task, .generation = generation }) catch {
            g_async_loader.state_mutex.unlock();
            memory.cardinal_free(allocator, ptr);
            return null;
        };
    }
    task.id = index;

    g_async_loader.state_mutex.unlock();

    task.type = task_type;
    task.priority = priority;
    task.status = .PENDING;
    task.submit_time = get_timestamp_ms();

    // Create underlying Job
    const job_prio: job_system.JobPriority = switch (priority) {
        .LOW => .LOW,
        .NORMAL => .NORMAL,
        .HIGH => .HIGH,
        .CRITICAL => .CRITICAL,
    };

    const job = job_system.create_job(execute_task_job, task, job_prio);
    if (job == null) {
        memory.cardinal_free(allocator, ptr);
        return null;
    }

    // Ensure the job is pushed to the completed queue so we can process callbacks and free it
    job.?.push_to_completed_queue = true;

    // Store Job pointer in 'next' field (Type punning)
    task.next = @ptrCast(job);

    return task;
}

// Task Execution
fn execute_texture_load_task(task: *CardinalAsyncTask) bool {
    if (task.file_path == null) return false;

    async_log.debug("Loading texture: {s}", .{task.file_path.?});

    if (Loaders.texture_load_fn == null) {
        async_log.err("Texture loader not registered", .{});
        return false;
    }

    var texture_data: scene.CardinalTexture = undefined;

    const ref_resource = Loaders.texture_load_fn.?(task.file_path.?, &texture_data);

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

    async_log.debug("Successfully loaded texture: {s}", .{task.file_path.?});
    return true;
}

fn execute_scene_load_task(task: *CardinalAsyncTask) bool {
    if (task.file_path == null) return false;

    async_log.info("Loading scene: {s}", .{task.file_path.?});

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const scene_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalScene));
    if (scene_ptr == null) {
        // Set error message
        return false;
    }
    const scene_obj = @as(*scene.CardinalScene, @ptrCast(@alignCast(scene_ptr)));

    if (Loaders.scene_load_fn == null) {
        async_log.err("Scene loader function not registered", .{});
        memory.cardinal_free(allocator, scene_ptr);
        return false;
    }

    if (!Loaders.scene_load_fn.?(task.file_path.?, scene_obj)) {
        memory.cardinal_free(allocator, scene_ptr);
        return false;
    }

    task.result_data = scene_ptr;
    task.result_size = @sizeOf(scene.CardinalScene);

    if (task.file_path) |path| {
        async_log.debug("Successfully loaded scene: {s}", .{path});
    } else {
        async_log.debug("Successfully loaded scene (unknown path)", .{});
    }
    return true;
}

fn execute_material_load_task(task: *CardinalAsyncTask) bool {
    if (task.custom_data == null) return false;

    async_log.debug("Loading material", .{});

    task.result_data = task.custom_data;
    task.result_size = @sizeOf(scene.CardinalMaterial);
    task.custom_data = null; // Clear custom_data so we don't double-free or confuse ownership

    async_log.debug("Successfully loaded material", .{});
    return true;
}

fn execute_mesh_load_task(task: *CardinalAsyncTask) bool {
    if (task.custom_data == null) return false;

    async_log.debug("Loading mesh with reference counting", .{});

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

    async_log.debug("Successfully loaded mesh with reference counting", .{});
    return true;
}

fn execute_ecs_scene_load_task(task: *CardinalAsyncTask) bool {
    if (task.file_path == null) return false;

    async_log.info("Loading ECS scene: {s}", .{task.file_path.?});

    if (Loaders.ecs_scene_load_fn == null) {
        async_log.err("ECS scene loader function not registered", .{});
        return false;
    }

    const result = Loaders.ecs_scene_load_fn.?(task.file_path.?);
    if (result == null) {
        return false;
    }

    task.result_data = result;
    task.result_size = 0; // Opaque

    async_log.debug("Successfully loaded ECS scene data", .{});
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
        .ECS_SCENE_LOAD => success = execute_ecs_scene_load_task(task),
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

// Public API
pub export fn cardinal_async_loader_init(config: ?*const CardinalAsyncLoaderConfig) callconv(.c) bool {
    if (g_async_loader.initialized) {
        std.log.warn("Async loader already initialized", .{});
        return true;
    }

    g_async_loader.initialized = false;
    g_async_loader.shutting_down = false;

    if (config) |c| {
        g_async_loader.config = c.*;
    } else {
        g_async_loader.config = .{
            .worker_thread_count = 0,
            .max_queue_size = 1000,
            .enable_priority_queue = true,
        };
    }

    // Initialize Job System
    const job_config = job_system.JobSystemConfig{
        .worker_thread_count = g_async_loader.config.worker_thread_count,
        .max_queue_size = g_async_loader.config.max_queue_size,
        .enable_priority_queue = g_async_loader.config.enable_priority_queue,
    };

    if (!job_system.init(&job_config)) {
        return false;
    }

    // Update config with actual thread count used by job system (defaulted inside)
    g_async_loader.config.worker_thread_count = job_system.g_job_system.config.worker_thread_count;

    g_async_loader.state_mutex = .{};
    g_async_loader.next_task_id = 0;

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    g_async_loader.allocator = allocator.as_allocator();
    g_async_loader.task_pool = .{};
    g_async_loader.free_indices = .{};

    g_async_loader.initialized = true;
    std.log.info("Async loader (JobSystem) initialized with {d} worker threads", .{g_async_loader.config.worker_thread_count});
    return true;
}

pub export fn cardinal_async_loader_shutdown() callconv(.c) void {
    if (!g_async_loader.initialized) return;

    std.log.info("Shutting down async loader...", .{});
    g_async_loader.shutting_down = true;

    job_system.shutdown();

    g_async_loader.initialized = false;

    g_async_loader.task_pool.deinit(g_async_loader.allocator);
    g_async_loader.free_indices.deinit(g_async_loader.allocator);

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

    const job_dependent = @as(*job_system.Job, @ptrCast(t_dependent.next));
    const job_dependency = @as(*job_system.Job, @ptrCast(t_dependency.next));

    if (job_system.add_dependency(job_dependent, job_dependency)) {
        // Legacy tracking removed
        return true;
    }

    return false;
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
        async_log.debug("Task {d} created with path: {s}", .{ task.?.id, task.?.file_path.? });
    } else {
        cardinal_async_free_task(task);
        return null;
    }

    task.?.callback = callback;
    task.?.callback_data = user_data;

    const job = @as(*job_system.Job, @ptrCast(task.?.next));
    if (!job_system.submit_job(job)) {
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

    const job = @as(*job_system.Job, @ptrCast(task.?.next));
    if (!job_system.submit_job(job)) {
        cardinal_async_free_task(task);
        return null;
    }

    return task;
}

pub export fn cardinal_async_load_ecs_scene(file_path: ?[*:0]const u8, priority: CardinalAsyncPriority, callback: CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*CardinalAsyncTask {
    if (!g_async_loader.initialized or file_path == null) return null;

    const task = create_task(.ECS_SCENE_LOAD, priority);
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

    const job = @as(*job_system.Job, @ptrCast(task.?.next));
    if (!job_system.submit_job(job)) {
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

    const job = @as(*job_system.Job, @ptrCast(task.?.next));
    if (!job_system.submit_job(job)) {
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

    const job = @as(*job_system.Job, @ptrCast(task.?.next));
    if (!job_system.submit_job(job)) {
        if (copy.vertices) |v| memory.cardinal_free(allocator, v);
        if (copy.indices) |i| memory.cardinal_free(allocator, i);
        memory.cardinal_free(allocator, copy_ptr);
        cardinal_async_free_task(task);
        return null;
    }

    return task;
}

pub export fn cardinal_async_create_custom_task(task_func: CardinalAsyncTaskFunc, custom_data: ?*anyopaque, priority: CardinalAsyncPriority, callback: CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*CardinalAsyncTask {
    if (!g_async_loader.initialized or task_func == null) return null;

    const task = create_task(.CUSTOM, priority);
    if (task == null) return null;

    task.?.custom_func = task_func;
    task.?.custom_data = custom_data;
    task.?.callback = callback;
    task.?.callback_data = user_data;

    return task;
}

pub export fn cardinal_async_submit_task(task: ?*CardinalAsyncTask) callconv(.c) bool {
    if (task == null) return false;
    const t = task.?;
    const job = @as(*job_system.Job, @ptrCast(t.next));
    return job_system.submit_job(job);
}

pub export fn cardinal_async_submit_custom_task(task_func: CardinalAsyncTaskFunc, custom_data: ?*anyopaque, priority: CardinalAsyncPriority, callback: CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*CardinalAsyncTask {
    const task = cardinal_async_create_custom_task(task_func, custom_data, priority, callback, user_data);
    if (task == null) return null;

    if (!cardinal_async_submit_task(task)) {
        cardinal_async_free_task(task);
        return null;
    }

    return task;
}

pub export fn cardinal_async_cancel_task(task: ?*CardinalAsyncTask) callconv(.c) bool {
    if (task) |t| {
        if (t.status == .PENDING) {
            const job = @as(*job_system.Job, @ptrCast(t.next));
            // We need to mark job as cancelled too, but JobSystem API for cancel is implicit via status?
            // JobSystem worker checks job.status == .CANCELLED
            job.status = .CANCELLED;

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
            if (elapsed >= timeout_ms) {
                // If we time out, check if the underlying job actually finished but we missed the update
                // This shouldn't happen with correct synchronization but is a failsafe
                if (t.next) |job_ptr| {
                    const job = @as(*job_system.Job, @ptrCast(job_ptr));
                    if (job.status == .COMPLETED or job.status == .FAILED) {
                        // Sync status
                        // Note: This is racy without locks, but we are just reading
                        // t.status update happens in callback usually or job completion
                        // If callback hasn't run, status might still be running
                        // But job system updates job status before callback
                    }
                }
                return false;
            }
        }
        if (g_async_loader.shutting_down) return false;

        // Process completed tasks to ensure callbacks run and status updates propagate
        // This is critical if we are waiting on the main thread and callbacks run on main thread
        _ = cardinal_async_process_completed_tasks(0);

        Sleep(1);
    }

    return t.status == .COMPLETED;
}

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;

pub export fn cardinal_async_free_task(task: ?*CardinalAsyncTask) callconv(.c) void {
    if (task) |t| {
        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

        // Only free the job if the loader is initialized.
        // If we are shutting down (or already shut down), the job system pool is likely destroyed,
        // so the job pointer is invalid or the pool is gone.
        if (g_async_loader.initialized) {
            g_async_loader.state_mutex.lock();
            if (t.next) |job_ptr| {
                const job = @as(*job_system.Job, @ptrCast(job_ptr));
                // Detach task from job to signal it's orphaned.
                // We do NOT free the job here because it might be in the completed queue (or running).
                // process_completed_tasks handles freeing jobs with null data.
                job.data = null;
                t.next = null;
            }
            g_async_loader.state_mutex.unlock();
        }

        if (t.result_data) |data| {
            if (t.type == .SCENE_LOAD) {
                const scene_ptr = @as(*scene.CardinalScene, @ptrCast(@alignCast(data)));
                memory.cardinal_free(allocator, scene_ptr);
            } else if (t.type == .MATERIAL_LOAD) {
                const mat_ptr = @as(*scene.CardinalMaterial, @ptrCast(@alignCast(data)));
                memory.cardinal_free(allocator, mat_ptr);
            }
        }

        if (t.file_path) |path| {
            memory.cardinal_free(allocator, path);
        }
        if (t.error_message) |msg| {
            memory.cardinal_free(allocator, msg);
        }

        g_async_loader.state_mutex.lock();
        if (t.id < g_async_loader.task_pool.items.len) {
            g_async_loader.task_pool.items[t.id].task = null;
            g_async_loader.free_indices.append(g_async_loader.allocator, t.id) catch {
                async_log.err("Failed to recycle task index {d}", .{t.id});
            };
        }
        g_async_loader.state_mutex.unlock();

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
        // Zero out the source to transfer ownership (move semantics)
        // This prevents double-free when free_task calls scene_destroy
        s.* = std.mem.zeroes(scene.CardinalScene);
        return true;
    }

    return false;
}

pub export fn cardinal_async_get_ecs_scene_result(task: ?*CardinalAsyncTask) callconv(.c) ?*anyopaque {
    if (task == null or task.?.type != .ECS_SCENE_LOAD or task.?.status != .COMPLETED) {
        return null;
    }
    return task.?.result_data;
}

pub export fn cardinal_async_get_material_result(task: ?*CardinalAsyncTask, out_material: ?*scene.CardinalMaterial) callconv(.c) ?*ref_counting.CardinalRefCountedResource {
    if (task == null or task.?.type != .MATERIAL_LOAD or task.?.status != .COMPLETED or out_material == null) {
        return null;
    }

    // Modern system: result_data is *CardinalMaterial (POD), not RefCountedResource
    const material_ptr = @as(?*scene.CardinalMaterial, @ptrCast(@alignCast(task.?.result_data)));
    if (material_ptr) |mat| {
        out_material.?.* = mat.*;
    }

    return null; // No ref resource to return
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
    return job_system.get_pending_job_count();
}

pub export fn cardinal_async_get_worker_thread_count() callconv(.c) u32 {
    return g_async_loader.config.worker_thread_count;
}

pub export fn cardinal_async_process_completed_tasks(max_tasks: u32) callconv(.c) u32 {
    if (!g_async_loader.initialized) return 0;

    var processed: u32 = 0;

    while (max_tasks == 0 or processed < max_tasks) {
        const job_opt = job_system.get_completed_job();
        if (job_opt == null) break;
        const job = job_opt.?;

        // Safety check: ensure this job belongs to async_loader
        if (job.func != execute_task_job) {
             // Foreign job - skip processing but do NOT free it as we don't own it.
             // Note: This leaks the job if the owner expected it to be in the queue (which they shouldn't if they handle cleanup).
             // Ideally we would push it back, but that changes order.
             // Given the fix in JobSystem to allow opting out of completed queue, this should be rare.
             continue;
        }

        g_async_loader.state_mutex.lock();

        // If job data is null, the task was cancelled/freed already
        if (job.data == null) {
            g_async_loader.state_mutex.unlock();
            job_system.free_job(job);
            continue;
        }

        const task = @as(*CardinalAsyncTask, @ptrCast(@alignCast(job.data)));

        // Debug log (temporary)
        // std.debug.print("[ASYNC] Processing completed task ID: {d}, Type: {any}\n", .{task.id, task.type});

        // Detach job from task to prevent double-free or race conditions
        task.next = null;
        
        const cb = task.callback;
        const cb_data = task.callback_data;

        g_async_loader.state_mutex.unlock();

        if (cb) |f| {
            f(task, cb_data);
        }

        // We are responsible for freeing the job now that it's out of the queue
        job_system.free_job(job);

        processed += 1;
    }

    return processed;
}

// Handle System API
pub export fn cardinal_async_get_handle(task: ?*CardinalAsyncTask) callconv(.c) handles.AsyncHandle {
    if (task) |t| {
        g_async_loader.state_mutex.lock();
        defer g_async_loader.state_mutex.unlock();

        if (t.id < g_async_loader.task_pool.items.len) {
            const gen = g_async_loader.task_pool.items[t.id].generation;
            return handles.AsyncHandle{ .index = t.id, .generation = gen };
        }
    }
    return handles.AsyncHandle.INVALID;
}

pub export fn cardinal_async_is_loading(handle: handles.AsyncHandle) callconv(.c) bool {
    g_async_loader.state_mutex.lock();
    defer g_async_loader.state_mutex.unlock();

    if (handle.index >= g_async_loader.task_pool.items.len) return false;
    const slot = g_async_loader.task_pool.items[handle.index];
    if (slot.generation != handle.generation) return false;

    if (slot.task) |t| {
        return t.status == .PENDING or t.status == .RUNNING;
    }
    return false;
}

pub export fn cardinal_async_is_ready(handle: handles.AsyncHandle) callconv(.c) bool {
    g_async_loader.state_mutex.lock();
    defer g_async_loader.state_mutex.unlock();

    if (handle.index >= g_async_loader.task_pool.items.len) return false;
    const slot = g_async_loader.task_pool.items[handle.index];
    if (slot.generation != handle.generation) return false;

    if (slot.task) |t| {
        return t.status == .COMPLETED;
    }
    return false;
}

pub export fn cardinal_async_has_failed(handle: handles.AsyncHandle) callconv(.c) bool {
    g_async_loader.state_mutex.lock();
    defer g_async_loader.state_mutex.unlock();

    if (handle.index >= g_async_loader.task_pool.items.len) return true;
    const slot = g_async_loader.task_pool.items[handle.index];
    if (slot.generation != handle.generation) return true;

    if (slot.task) |t| {
        return t.status == .FAILED or t.status == .CANCELLED;
    }
    return true;
}

pub export fn cardinal_async_get_task_from_handle(handle: handles.AsyncHandle) callconv(.c) ?*CardinalAsyncTask {
    g_async_loader.state_mutex.lock();
    defer g_async_loader.state_mutex.unlock();

    if (handle.index >= g_async_loader.task_pool.items.len) return null;
    const slot = g_async_loader.task_pool.items[handle.index];
    if (slot.generation != handle.generation) return null;

    return slot.task;
}
