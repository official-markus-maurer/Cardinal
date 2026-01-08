const std = @import("std");
const builtin = @import("builtin");

/// Returns the current thread ID as a u32.
/// This abstracts platform-specific thread ID retrieval.
pub fn get_current_thread_id() u32 {
    // std.Thread.getCurrentId() returns Thread.Id which varies by platform.
    // We cast to u32 for consistency across the engine (logging/tracking).
    const id = std.Thread.getCurrentId();
    return @intCast(id);
}

/// Returns the current monotonic time in milliseconds.
pub fn get_time_ms() u64 {
    return @intCast(std.time.milliTimestamp());
}

/// Returns the current monotonic time in nanoseconds.
pub fn get_time_ns() u64 {
    return @intCast(std.time.nanoTimestamp());
}
