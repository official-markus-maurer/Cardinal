const std = @import("std");
const builtin = @import("builtin");

const win_c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("windows.h");
    @cInclude("DbgHelp.h");
}) else struct {};

pub fn get_current_thread_id() u32 {
    const id = std.Thread.getCurrentId();
    return @intCast(id);
}

pub fn get_time_ms() u64 {
    return @intCast(std.time.milliTimestamp());
}

pub fn get_time_ns() u64 {
    return @intCast(std.time.nanoTimestamp());
}

fn write_minidump_internal(exception_pointers: ?*win_c.EXCEPTION_POINTERS) bool {
    if (builtin.os.tag != .windows) {
        return false;
    }

    const now_ms = get_time_ms();
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

    const process_handle: win_c.HANDLE = win_c.GetCurrentProcess();
    const process_id: win_c.DWORD = win_c.GetCurrentProcessId();

    var ex_info: win_c.MINIDUMP_EXCEPTION_INFORMATION = std.mem.zeroes(win_c.MINIDUMP_EXCEPTION_INFORMATION);
    ex_info.ThreadId = win_c.GetCurrentThreadId();
    ex_info.ExceptionPointers = exception_pointers;
    ex_info.ClientPointers = win_c.FALSE;

    const ok = win_c.MiniDumpWriteDump(
        process_handle,
        process_id,
        handle,
        win_c.MiniDumpWithIndirectlyReferencedMemory,
        if (exception_pointers) |_| &ex_info else null,
        null,
        null,
    );

    const success = ok != win_c.FALSE;

    return success;
}

pub fn write_minidump() bool {
    return write_minidump_internal(null);
}

// Unhandled exception filter support is intentionally disabled for now because
// the exact function pointer type signature on this Zig/Windows toolchain
// causes calling convention mismatches when passed to SetUnhandledExceptionFilter.
// If needed later, this can be reintroduced with a small C shim.
