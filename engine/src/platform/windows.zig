const std = @import("std");

pub const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
    @cInclude("windows.h");
    @cInclude("commdlg.h");
    @cInclude("malloc.h");
    @cDefine("GLFW_EXPOSE_NATIVE_WIN32", {});
    @cInclude("GLFW/glfw3native.h");
    @cInclude("DbgHelp.h");
});

pub fn get_current_thread_id() u32 {
    return c.GetCurrentThreadId();
}

pub fn write_minidump(exception_pointers: ?*anyopaque) bool {
    const now_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    const seconds: u64 = now_ms / 1000;
    const millis: u64 = now_ms % 1000;

    var name_buf: [256]u8 = undefined;
    var name_fbs = std.io.fixedBufferStream(&name_buf);
    const name_writer = name_fbs.writer();

    name_writer.print("crash_{d}_{d:0>3}.dmp", .{ seconds, millis }) catch return false;
    const name_slice = name_fbs.getWritten();

    const cwd = std.fs.cwd();

    _ = cwd.makeDir("dumps") catch {};

    var path_buf: [512]u8 = undefined;
    var path_fbs = std.io.fixedBufferStream(&path_buf);
    const path_writer = path_fbs.writer();
    path_writer.print("dumps/{s}", .{name_slice}) catch return false;
    const path_slice = path_fbs.getWritten();

    var file = cwd.createFile(path_slice, .{}) catch return false;
    defer file.close();

    const handle = file.handle;

    const process_handle: c.HANDLE = c.GetCurrentProcess();
    const process_id: c.DWORD = c.GetCurrentProcessId();

    var ex_info: c.MINIDUMP_EXCEPTION_INFORMATION = std.mem.zeroes(c.MINIDUMP_EXCEPTION_INFORMATION);
    ex_info.ThreadId = c.GetCurrentThreadId();
    ex_info.ExceptionPointers = @ptrCast(@alignCast(exception_pointers));
    ex_info.ClientPointers = c.FALSE;

    const ok = c.MiniDumpWriteDump(
        process_handle,
        process_id,
        handle,
        c.MiniDumpWithIndirectlyReferencedMemory,
        if (exception_pointers != null) &ex_info else null,
        null,
        null,
    );

    return ok != c.FALSE;
}

pub fn aligned_alloc(size: usize, alignment: usize) ?*anyopaque {
    return c._aligned_malloc(size, alignment);
}

pub fn aligned_free(ptr: ?*anyopaque) void {
    c._aligned_free(ptr);
}

pub fn expand(memblock: ?*anyopaque, size: usize) ?*anyopaque {
    return c._expand(memblock, size);
}

pub fn capture_stack_back_trace(frames_to_skip: u32, frames_to_capture: u32, back_trace: [*]?*anyopaque, back_trace_hash: ?*u32) u16 {
    return c.RtlCaptureStackBackTrace(frames_to_skip, frames_to_capture, back_trace, back_trace_hash);
}

pub fn open_file_dialog(allocator: std.mem.Allocator, filter: ?[:0]const u8, default_path: ?[:0]const u8) ?[]const u8 {
    var ofn: c.OPENFILENAMEA = std.mem.zeroes(c.OPENFILENAMEA);
    var buffer: [260]u8 = std.mem.zeroes([260]u8);

    ofn.lStructSize = @sizeOf(c.OPENFILENAMEA);
    // Use active window as owner if possible, but null is fine for now
    ofn.hwndOwner = null;
    ofn.hInstance = null;
    ofn.lpstrFile = &buffer;
    ofn.nMaxFile = buffer.len;
    
    // Filter format: "Text Files\0*.txt\0All Files\0*.*\0"
    if (filter) |f| {
        ofn.lpstrFilter = f.ptr;
    } else {
        ofn.lpstrFilter = "All Files\x00*.*\x00";
    }
    
    ofn.nFilterIndex = 1;
    ofn.lpstrFileTitle = null;
    ofn.nMaxFileTitle = 0;
    
    if (default_path) |p| {
        ofn.lpstrInitialDir = p.ptr;
    }
    
    ofn.Flags = c.OFN_PATHMUSTEXIST | c.OFN_FILEMUSTEXIST | c.OFN_NOCHANGEDIR;

    if (c.GetOpenFileNameA(&ofn) != 0) {
        const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse buffer.len;
        return allocator.dupe(u8, buffer[0..len]) catch null;
    }

    return null;
}

pub fn save_file_dialog(allocator: std.mem.Allocator, filter: ?[:0]const u8, default_path: ?[:0]const u8) ?[]const u8 {
    var ofn: c.OPENFILENAMEA = std.mem.zeroes(c.OPENFILENAMEA);
    var buffer: [260]u8 = std.mem.zeroes([260]u8);

    ofn.lStructSize = @sizeOf(c.OPENFILENAMEA);
    ofn.hwndOwner = null;
    ofn.hInstance = null;
    ofn.lpstrFile = &buffer;
    ofn.nMaxFile = buffer.len;
    
    if (filter) |f| {
        ofn.lpstrFilter = f.ptr;
    } else {
        ofn.lpstrFilter = "All Files\x00*.*\x00";
    }
    
    ofn.nFilterIndex = 1;
    ofn.lpstrFileTitle = null;
    ofn.nMaxFileTitle = 0;
    
    if (default_path) |p| {
        ofn.lpstrInitialDir = p.ptr;
    }
    
    ofn.Flags = c.OFN_PATHMUSTEXIST | c.OFN_OVERWRITEPROMPT | c.OFN_NOCHANGEDIR;

    if (c.GetSaveFileNameA(&ofn) != 0) {
        const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse buffer.len;
        return allocator.dupe(u8, buffer[0..len]) catch null;
    }

    return null;
}

pub fn open_folder_dialog(allocator: std.mem.Allocator, default_path: ?[:0]const u8) ?[]const u8 {
    // IFileOpenDialog is complex to implement via C API bindings (COM).
    // Fallback to simple implementation or skip for now.
    // For now, let's just return null or implement a hacky solution if needed.
    _ = allocator;
    _ = default_path;
    return null;
}
