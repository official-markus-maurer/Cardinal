//! Multi-threaded renderer task types.
//!
//! C-ABI-friendly task queue structures used by renderer worker threads.
const std = @import("std");
const c = @import("vulkan_c.zig").c;
const core = @import("vulkan_types_core.zig");

/// Background task kind used by the renderer MT subsystem.
pub const CardinalMTTaskType = enum(c_int) {
    CARDINAL_MT_TASK_COMMAND_RECORD = 0,
    CARDINAL_MT_TASK_TEXTURE_LOAD = 1,
    CARDINAL_MT_TASK_MESH_LOAD = 2,
};

/// Intrusive task node used by the MT subsystem queues.
pub const CardinalMTTask = extern struct {
    type: CardinalMTTaskType,
    data: ?*anyopaque,
    execute_func: ?*const fn (?*anyopaque) callconv(.c) void,
    callback_func: ?*const fn (?*anyopaque, bool) callconv(.c) void,
    success: bool,
    is_completed: bool,
    next: ?*CardinalMTTask,
};

/// Intrusive single-producer/single-consumer-style queue of tasks.
pub const CardinalMTTaskQueue = extern struct {
    head: ?*CardinalMTTask,
    tail: ?*CardinalMTTask,
    task_count: u32,
    queue_mutex: core.cardinal_mutex_t,
    queue_condition: core.cardinal_cond_t,
};

/// Thread pool wrapper used by the MT subsystem.
pub const CardinalMTThreadPool = extern struct {
    threads: ?[*]core.cardinal_thread_handle_t,
    thread_count: u32,
    is_active: bool,
    queue: ?*CardinalMTTaskQueue,
};

/// One secondary command buffer record context used per worker thread.
pub const CardinalSecondaryCommandContext = extern struct {
    command_buffer: c.VkCommandBuffer,
    is_recording: bool,
    thread_index: u32,
    inheritance: c.VkCommandBufferInheritanceInfo,
};

/// Per-thread Vulkan command pool state.
pub const CardinalThreadCommandPool = extern struct {
    primary_pool: c.VkCommandPool,
    secondary_pool: c.VkCommandPool,
    secondary_buffers: ?[*]c.VkCommandBuffer,
    secondary_buffer_count: u32,
    next_secondary_index: u32,
    is_active: bool,
    thread_id: core.cardinal_thread_id_t,
};

/// MT command recording manager shared across worker threads.
pub const CardinalMTCommandManager = extern struct {
    vulkan_state: ?*anyopaque,
    thread_pools: ?[*]CardinalThreadCommandPool,
    is_initialized: bool,
    pool_mutex: core.cardinal_mutex_t,
    active_thread_count: u32,
};

/// Global MT subsystem state (queues + command manager + worker threads).
pub const CardinalMTSubsystem = struct {
    pending_queue: CardinalMTTaskQueue,
    completed_queue: CardinalMTTaskQueue,
    command_manager: CardinalMTCommandManager,
    is_running: bool,
    worker_thread_count: u32,
    worker_threads: []?core.cardinal_thread_handle_t,
    subsystem_mutex: core.cardinal_mutex_t,
};
