//! Timeline semaphore synchronization types.
//!
//! Shared structs used by the sync manager and timeline wait/submit paths.
const c = @import("vulkan_c.zig").c;

/// High-level error classification for timeline waits.
pub const VulkanTimelineError = enum(c_int) {
    NONE = 0,
    TIMEOUT = 1,
    DEVICE_LOST = 2,
    OUT_OF_MEMORY = 3,
    INVALID_VALUE = 4,
    SEMAPHORE_INVALID = 5,
    UNKNOWN = 6,
};

/// Detailed error payload for timeline operations.
pub const VulkanTimelineErrorInfo = extern struct {
    error_type: VulkanTimelineError,
    vulkan_result: c.VkResult,
    timeline_value: u64,
    timeout_ns: u64,
    error_message: [256]u8,
};

/// Strategy for generating monotonic timeline values.
pub const TimelineValueStrategy = extern struct {
    base_value: u64,
    increment_step: u64,
    max_safe_value: u64,
    overflow_threshold: u64,
    auto_reset_enabled: bool,
};

/// Central sync manager state shared by renderer subsystems.
pub const VulkanSyncManager = extern struct {
    device: c.VkDevice,
    graphics_queue: c.VkQueue,
    max_frames_in_flight: u32,
    current_frame: u32,
    image_acquired_semaphores: ?[*]c.VkSemaphore,
    render_finished_semaphores: ?[*]c.VkSemaphore,
    in_flight_fences: ?[*]c.VkFence,
    timeline_semaphore: c.VkSemaphore,
    initialized: bool,
    global_timeline_counter: u64,
    current_frame_value: u64,
    timeline_wait_count: u64,
    image_available_value: u64,
    render_complete_value: u64,
    timeline_signal_count: u64,
    value_strategy: TimelineValueStrategy,
    max_ahead_value: u64,
};
