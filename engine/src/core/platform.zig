//! Platform abstraction layer.
//!
//! This module selects the OS-specific implementation at compile time and exposes a stable API
//! for timing, aligned allocation, stack traces, crash dumps, and native file dialogs.
const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("../platform/windows.zig"),
    .linux => @import("../platform/linux.zig"),
    .macos => @import("../platform/macos.zig"),
    else => @compileError("Unsupported platform"),
};

pub const c = impl.c;

/// Returns an OS-specific thread identifier for the current thread.
pub fn get_current_thread_id() u32 {
    return impl.get_current_thread_id();
}

/// Returns wall-clock time in milliseconds.
pub fn get_time_ms() u64 {
    return @intCast(std.time.milliTimestamp());
}

/// Returns wall-clock time in nanoseconds.
pub fn get_time_ns() u64 {
    return @intCast(std.time.nanoTimestamp());
}

/// Attempts to write a minidump for the current process (where supported).
pub fn write_minidump() bool {
    return impl.write_minidump(null);
}

/// Allocates `size` bytes aligned to `alignment`.
pub fn aligned_alloc(size: usize, alignment: usize) ?*anyopaque {
    return impl.aligned_alloc(size, alignment);
}

/// Frees a pointer returned by `aligned_alloc`.
pub fn aligned_free(ptr: ?*anyopaque) void {
    impl.aligned_free(ptr);
}

/// Attempts to expand an allocation in-place.
pub fn expand(memblock: ?*anyopaque, size: usize) ?*anyopaque {
    return impl.expand(memblock, size);
}

/// Captures a backtrace into `back_trace`, returning the number of frames written.
pub fn capture_stack_back_trace(frames_to_skip: u32, frames_to_capture: u32, back_trace: [*]?*anyopaque, back_trace_hash: ?*u32) u16 {
    return impl.capture_stack_back_trace(frames_to_skip, frames_to_capture, back_trace, back_trace_hash);
}

/// Opens a native "open file" dialog and returns an owned path on success.
pub fn open_file_dialog(allocator: std.mem.Allocator, filter: ?[:0]const u8, default_path: ?[:0]const u8) ?[]const u8 {
    return impl.open_file_dialog(allocator, filter, default_path);
}

/// Opens a native "save file" dialog and returns an owned path on success.
pub fn save_file_dialog(allocator: std.mem.Allocator, filter: ?[:0]const u8, default_path: ?[:0]const u8) ?[]const u8 {
    return impl.save_file_dialog(allocator, filter, default_path);
}

/// Opens a native "select folder" dialog and returns an owned path on success.
pub fn open_folder_dialog(allocator: std.mem.Allocator, default_path: ?[:0]const u8) ?[]const u8 {
    return impl.open_folder_dialog(allocator, default_path);
}
