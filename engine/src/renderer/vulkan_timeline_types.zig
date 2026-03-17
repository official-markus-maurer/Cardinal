//! Timeline semaphore debug and pooling types.
//!
//! Defines C-ABI-friendly structs shared by the timeline semaphore pool and debug recorder.
//! This file keeps the public layout stable even when the implementation changes.
const std = @import("std");
const builtin = @import("builtin");

pub const c = @import("vulkan_c.zig").c;

pub const VULKAN_TIMELINE_DEBUG_MAX_EVENTS = 1024;
pub const VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH = 64;

pub const VulkanTimelineMutexStorageSize: usize = if (builtin.os.tag == .windows) @sizeOf(c.CRITICAL_SECTION) else @sizeOf(c.pthread_mutex_t);
pub const VulkanTimelineMutexStorageAlign: usize = if (builtin.os.tag == .windows) @alignOf(c.CRITICAL_SECTION) else @alignOf(c.pthread_mutex_t);

/// Platform mutex stored inline to avoid heap allocations.
pub const VulkanTimelineMutex = extern struct {
    storage: [VulkanTimelineMutexStorageSize]u8 align(VulkanTimelineMutexStorageAlign),
    initialized: u32,
};

/// Type of recorded timeline event.
pub const VulkanTimelineEventType = enum(c_int) {
    WAIT_START = 0,
    WAIT_END = 1,
    SIGNAL_START = 2,
    SIGNAL_END = 3,
    VALUE_QUERY = 4,
    ERROR = 5,
    RECOVERY = 6,
    POOL_ALLOC = 7,
    POOL_DEALLOC = 8,
};

/// C-style exported aliases for `VulkanTimelineEventType`.
pub const VULKAN_TIMELINE_EVENT_WAIT_START = VulkanTimelineEventType.WAIT_START;
pub const VULKAN_TIMELINE_EVENT_WAIT_END = VulkanTimelineEventType.WAIT_END;
pub const VULKAN_TIMELINE_EVENT_SIGNAL_START = VulkanTimelineEventType.SIGNAL_START;
pub const VULKAN_TIMELINE_EVENT_SIGNAL_END = VulkanTimelineEventType.SIGNAL_END;
pub const VULKAN_TIMELINE_EVENT_VALUE_QUERY = VulkanTimelineEventType.VALUE_QUERY;
pub const VULKAN_TIMELINE_EVENT_ERROR = VulkanTimelineEventType.ERROR;
pub const VULKAN_TIMELINE_EVENT_RECOVERY = VulkanTimelineEventType.RECOVERY;
pub const VULKAN_TIMELINE_EVENT_POOL_ALLOC = VulkanTimelineEventType.POOL_ALLOC;
pub const VULKAN_TIMELINE_EVENT_POOL_DEALLOC = VulkanTimelineEventType.POOL_DEALLOC;

/// Aggregated performance counters collected by the debug recorder.
pub const VulkanTimelinePerformanceMetrics = extern struct {
    total_waits: u64,
    total_signals: u64,
    total_wait_time_ns: u64,
    total_signal_time_ns: u64,
    max_wait_time_ns: u64,
    max_signal_time_ns: u64,
    timeout_count: u64,
    error_count: u64,
    recovery_count: u64,
};

/// Snapshot of the timeline state captured at a point in time.
pub const VulkanTimelineStateSnapshot = extern struct {
    current_value: u64,
    last_signaled_value: u64,
    next_expected_value: u64,
    pending_signals: u32,
    pending_waits: u32,
    is_valid: bool,
    last_error: c.VkResult,
};

/// One recorded timeline event entry.
pub const VulkanTimelineDebugEvent = extern struct {
    type: VulkanTimelineEventType,
    timestamp_ns: u64,
    timeline_value: u64,
    duration_ns: u64,
    result: c.VkResult,
    thread_id: u32,
    name: [VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH]u8,
    details: [128]u8,
};

/// Debug recorder state and ring-buffer storage.
pub const VulkanTimelineDebugContext = extern struct {
    mutex: VulkanTimelineMutex,
    event_write_index: u32,
    event_count: u32,
    metrics: VulkanTimelinePerformanceMetrics,
    enabled: bool,
    collect_events: bool,
    collect_performance: bool,
    verbose_logging: bool,
    snapshot_interval_ns: u64,
    last_snapshot_time: u64,
    events: [VULKAN_TIMELINE_DEBUG_MAX_EVENTS]VulkanTimelineDebugEvent,
    last_snapshot: VulkanTimelineStateSnapshot,
};

/// Pool entry for a timeline semaphore.
pub const VulkanTimelinePoolEntry = extern struct {
    semaphore: c.VkSemaphore,
    last_signaled_value: u64,
    in_use: bool,
    creation_time: u64,
};

/// Result of a pool allocation request.
pub const VulkanTimelinePoolAllocation = extern struct {
    semaphore: c.VkSemaphore,
    pool_index: u32,
    from_cache: bool,
};

/// Pool state for timeline semaphores.
pub const VulkanTimelinePool = extern struct {
    device: c.VkDevice,
    pool_size: u32,
    max_pool_size: u32,
    active_count: u32,
    entries: [*]VulkanTimelinePoolEntry,
    mutex: VulkanTimelineMutex,
    allocations: u64,
    deallocations: u64,
    cache_hits: u64,
    cache_misses: u64,
    max_idle_time_ns: u64,
    auto_cleanup_enabled: bool,
    initialized: bool,
};
