const std = @import("std");

pub const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
    @cInclude("pthread.h");
    @cInclude("execinfo.h");
});

pub fn get_current_thread_id() u32 {
    const id = std.Thread.getCurrentId();
    return @intCast(id);
}

pub fn write_minidump(exception_pointers: ?*anyopaque) bool {
    _ = exception_pointers;
    // TODO: Implement macOS crash reporting
    return false;
}

pub fn aligned_alloc(size: usize, alignment: usize) ?*anyopaque {
    var ptr: ?*anyopaque = null;
    if (c.posix_memalign(&ptr, alignment, size) == 0) {
        return ptr;
    }
    return null;
}

pub fn aligned_free(ptr: ?*anyopaque) void {
    c.free(ptr);
}

pub fn expand(memblock: ?*anyopaque, size: usize) ?*anyopaque {
    _ = memblock;
    _ = size;
    return null;
}

pub fn open_file_dialog(allocator: std.mem.Allocator, filter: ?[:0]const u8, default_path: ?[:0]const u8) ?[]const u8 {
    _ = allocator;
    _ = filter;
    _ = default_path;
    // TODO: NSOpenPanel
    return null;
}

pub fn save_file_dialog(allocator: std.mem.Allocator, filter: ?[:0]const u8, default_path: ?[:0]const u8) ?[]const u8 {
    _ = allocator;
    _ = filter;
    _ = default_path;
    return null;
}

pub fn open_folder_dialog(allocator: std.mem.Allocator, default_path: ?[:0]const u8) ?[]const u8 {
    _ = allocator;
    _ = default_path;
    return null;
}

pub fn capture_stack_back_trace(frames_to_skip: u32, frames_to_capture: u32, back_trace: [*]?*anyopaque, back_trace_hash: ?*u32) u16 {
    _ = frames_to_skip;
    _ = back_trace_hash;
    const count = c.backtrace(@ptrCast(back_trace), @intCast(frames_to_capture));
    return @intCast(count);
}
