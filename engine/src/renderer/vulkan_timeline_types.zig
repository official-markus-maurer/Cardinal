const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("stdint.h");
    @cInclude("stdio.h");
    
    // Skip stdatomic.h and define types manually to avoid C import errors
    @cDefine("__STDATOMIC_H", "1");
    @cDefine("_STDATOMIC_H", "1");
    @cDefine("__CLANG_STDATOMIC_H", "1");
    @cDefine("__zig_translate_c__", "1");
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    
    @cDefine("memory_order", "int");
    @cDefine("memory_order_relaxed", "0");
    @cDefine("memory_order_consume", "1");
    @cDefine("memory_order_acquire", "2");
    @cDefine("memory_order_release", "3");
    @cDefine("memory_order_acq_rel", "4");
    @cDefine("memory_order_seq_cst", "5");
    
    @cInclude("vulkan/vulkan.h");
    
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
        @cInclude("processthreadsapi.h");
    } else {
        @cInclude("pthread.h");
        @cInclude("time.h");
        @cInclude("unistd.h");
        @cInclude("sys/syscall.h");
    }
});

pub const VULKAN_TIMELINE_DEBUG_MAX_EVENTS = 1024;
pub const VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH = 64;

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

// Export constants to C namespace style for compatibility
pub const VULKAN_TIMELINE_EVENT_WAIT_START = VulkanTimelineEventType.WAIT_START;
pub const VULKAN_TIMELINE_EVENT_WAIT_END = VulkanTimelineEventType.WAIT_END;
pub const VULKAN_TIMELINE_EVENT_SIGNAL_START = VulkanTimelineEventType.SIGNAL_START;
pub const VULKAN_TIMELINE_EVENT_SIGNAL_END = VulkanTimelineEventType.SIGNAL_END;
pub const VULKAN_TIMELINE_EVENT_VALUE_QUERY = VulkanTimelineEventType.VALUE_QUERY;
pub const VULKAN_TIMELINE_EVENT_ERROR = VulkanTimelineEventType.ERROR;
pub const VULKAN_TIMELINE_EVENT_RECOVERY = VulkanTimelineEventType.RECOVERY;
pub const VULKAN_TIMELINE_EVENT_POOL_ALLOC = VulkanTimelineEventType.POOL_ALLOC;
pub const VULKAN_TIMELINE_EVENT_POOL_DEALLOC = VulkanTimelineEventType.POOL_DEALLOC;

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

pub const VulkanTimelineStateSnapshot = extern struct {
    current_value: u64,
    last_signaled_value: u64,
    next_expected_value: u64,
    pending_signals: u32,
    pending_waits: u32,
    is_valid: bool,
    last_error: c.VkResult,
};

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

pub const VulkanTimelineDebugContext = extern struct {
    mutex: ?*anyopaque,
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

pub const VulkanTimelinePoolEntry = extern struct {
    semaphore: c.VkSemaphore,
    last_signaled_value: u64,
    in_use: bool,
    creation_time: u64,
};

pub const VulkanTimelinePoolAllocation = extern struct {
    semaphore: c.VkSemaphore,
    pool_index: u32,
    from_cache: bool,
};

pub const VulkanTimelinePool = extern struct {
    device: c.VkDevice,
    pool_size: u32,
    max_pool_size: u32,
    active_count: u32,
    entries: [*]VulkanTimelinePoolEntry,
    mutex: ?*anyopaque,
    allocations: u64,
    deallocations: u64,
    cache_hits: u64,
    cache_misses: u64,
    max_idle_time_ns: u64,
    auto_cleanup_enabled: bool,
    initialized: bool,
};
