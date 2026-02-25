const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("../platform/windows.zig"),
    .linux => @import("../platform/linux.zig"),
    .macos => @import("../platform/macos.zig"),
    else => @compileError("Unsupported platform"),
};

pub const c = impl.c;

pub fn get_current_thread_id() u32 {
    return impl.get_current_thread_id();
}

pub fn get_time_ms() u64 {
    return @intCast(std.time.milliTimestamp());
}

pub fn get_time_ns() u64 {
    return @intCast(std.time.nanoTimestamp());
}

pub fn write_minidump() bool {
    return impl.write_minidump(null);
}

pub fn aligned_alloc(size: usize, alignment: usize) ?*anyopaque {
    return impl.aligned_alloc(size, alignment);
}

pub fn aligned_free(ptr: ?*anyopaque) void {
    impl.aligned_free(ptr);
}

pub fn expand(memblock: ?*anyopaque, size: usize) ?*anyopaque {
    return impl.expand(memblock, size);
}

pub fn capture_stack_back_trace(frames_to_skip: u32, frames_to_capture: u32, back_trace: [*]?*anyopaque, back_trace_hash: ?*u32) u16 {
    return impl.capture_stack_back_trace(frames_to_skip, frames_to_capture, back_trace, back_trace_hash);
}

pub fn open_file_dialog(allocator: std.mem.Allocator, filter: ?[:0]const u8, default_path: ?[:0]const u8) ?[]const u8 {
    return impl.open_file_dialog(allocator, filter, default_path);
}

pub fn save_file_dialog(allocator: std.mem.Allocator, filter: ?[:0]const u8, default_path: ?[:0]const u8) ?[]const u8 {
    return impl.save_file_dialog(allocator, filter, default_path);
}

pub fn open_folder_dialog(allocator: std.mem.Allocator, default_path: ?[:0]const u8) ?[]const u8 {
    return impl.open_folder_dialog(allocator, default_path);
}

