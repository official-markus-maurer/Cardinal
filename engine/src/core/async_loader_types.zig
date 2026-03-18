//! Async loader public types.
//!
//! Holds the C-ABI-visible task types and loader registration hooks shared by the async loader.
const std = @import("std");
const scene = @import("../assets/scene.zig");
const ref_counting = @import("ref_counting.zig");

/// Registered loader entrypoints used by task execution.
pub const Loaders = struct {
    pub var texture_load_fn: ?*const fn (file_path: ?[*]const u8, out_texture: ?*anyopaque) callconv(.c) ?*ref_counting.CardinalRefCountedResource = null;
    pub var scene_load_fn: ?*const fn (file_path: ?[*:0]const u8, scene: ?*scene.CardinalScene) callconv(.c) bool = null;
    pub var ecs_scene_load_fn: ?*const fn (file_path: ?[*:0]const u8) callconv(.c) ?*anyopaque = null;
};

/// Scheduling priority for async tasks.
pub const CardinalAsyncPriority = enum(c_int) {
    LOW = 0,
    NORMAL = 1,
    HIGH = 2,
    CRITICAL = 3,
};

/// Task lifecycle status.
pub const CardinalAsyncStatus = enum(c_int) {
    PENDING = 0,
    RUNNING = 1,
    COMPLETED = 2,
    FAILED = 3,
    CANCELLED = 4,
};

/// Built-in task types supported by the async loader.
pub const CardinalAsyncTaskType = enum(c_int) {
    TEXTURE_LOAD = 0,
    SCENE_LOAD = 1,
    BUFFER_UPLOAD = 2,
    MATERIAL_LOAD = 3,
    MESH_LOAD = 4,
    CUSTOM = 5,
    ECS_SCENE_LOAD = 6,
};

/// Configuration for the async loader and backing job system.
pub const CardinalAsyncLoaderConfig = extern struct {
    worker_thread_count: u32,
    max_queue_size: u32,
    enable_priority_queue: bool,
};

/// Task execution callback used for CUSTOM tasks.
pub const CardinalAsyncTaskFunc = ?*const fn (task: ?*CardinalAsyncTask, user_data: ?*anyopaque) callconv(.c) bool;
/// Completion callback invoked after a task finishes (typically on the main thread).
pub const CardinalAsyncCallback = ?*const fn (task: ?*CardinalAsyncTask, user_data: ?*anyopaque) callconv(.c) void;

/// C-ABI-friendly task record owned by the async loader.
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

    /// Stores a pointer to the underlying job (type-punned).
    next: ?*CardinalAsyncTask,
    submit_time: u64,
};
