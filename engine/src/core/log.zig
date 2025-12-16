const std = @import("std");

const c = @cImport({
    @cInclude("stdarg.h");
    @cInclude("string.h");
});

// Manual enum definition matching C
pub const CardinalLogLevel = enum(c_int) {
    TRACE = 0,
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    FATAL = 5,
};

// Manual stdio definitions
const FILE = opaque {};
extern fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn fclose(stream: *FILE) c_int;
extern fn fprintf(stream: *FILE, format: [*:0]const u8, ...) c_int;
extern fn printf(format: [*:0]const u8, ...) c_int;
extern fn fflush(stream: *FILE) c_int;
extern fn snprintf(s: [*]u8, n: usize, format: [*:0]const u8, ...) c_int;
extern fn vsnprintf(s: [*]u8, n: usize, format: [*:0]const u8, arg: c.va_list) c_int;

// MSVC specific for stdout/stderr
extern fn __acrt_iob_func(index: c_uint) *FILE;

fn get_stdout() *FILE { return __acrt_iob_func(1); }
fn get_stderr() *FILE { return __acrt_iob_func(2); }

// Global state
var min_log_level: CardinalLogLevel = .WARN;
var log_file: ?*FILE = null;

fn getLevelStr(level: CardinalLogLevel) [:0]const u8 {
    return switch (level) {
        .TRACE => "TRACE",
        .DEBUG => "DEBUG",
        .INFO => "INFO",
        .WARN => "WARN",
        .ERROR => "ERROR",
        .FATAL => "FATAL",
    };
}

export fn cardinal_log_init() void {
    cardinal_log_init_with_level(min_log_level);
}

pub export fn cardinal_log_init_with_level(level: CardinalLogLevel) void {
    min_log_level = level;

    if (log_file == null) {
        log_file = fopen("build/cardinal_debug.log", "w");
        if (log_file == null) {
            log_file = fopen("cardinal_debug.log", "w");
        }
    }

    const level_str = getLevelStr(min_log_level);
    _ = printf("==== Cardinal Log Start (Level: %s) ====\n", level_str.ptr);
    if (log_file) |f| {
        _ = fprintf(f, "==== Cardinal Log Start (Level: %s) ====\n", level_str.ptr);
        _ = fflush(f);
    }
}

pub export fn cardinal_log_shutdown() void {
    _ = printf("==== Cardinal Log End ====\n");
    if (log_file) |f| {
        _ = fprintf(f, "==== Cardinal Log End ====\n");
        _ = fclose(f);
        log_file = null;
    }
}

pub export fn cardinal_log_set_level(level: CardinalLogLevel) void {
    min_log_level = level;
}

pub export fn cardinal_log_get_level() CardinalLogLevel {
    return min_log_level;
}

pub export fn cardinal_log_parse_level(level_str_input: ?[*:0]const u8) CardinalLogLevel {
    if (level_str_input == null) return .INFO;
    const s = std.mem.span(level_str_input.?);

    if (std.ascii.eqlIgnoreCase(s, "TRACE")) return .TRACE;
    if (std.ascii.eqlIgnoreCase(s, "DEBUG")) return .DEBUG;
    if (std.ascii.eqlIgnoreCase(s, "INFO")) return .INFO;
    if (std.ascii.eqlIgnoreCase(s, "WARN")) return .WARN;
    if (std.ascii.eqlIgnoreCase(s, "ERROR")) return .ERROR;
    if (std.ascii.eqlIgnoreCase(s, "FATAL")) return .FATAL;

    return .INFO;
}

pub export fn cardinal_log_output_v(level: CardinalLogLevel, file: [*:0]const u8, line: c_int, fmt: [*:0]const u8, args: c.va_list) void {
    if (@intFromEnum(level) < @intFromEnum(min_log_level)) return;

    var buffer: [4096]u8 = undefined;
    _ = vsnprintf(&buffer, buffer.len, fmt, args);

    var final_filename: [*:0]const u8 = file;
    const last_slash = c.strrchr(file, '/');
    const last_backslash = c.strrchr(file, '\\');
    
    if (last_slash != null and last_backslash != null) {
        if (@intFromPtr(last_slash) > @intFromPtr(last_backslash)) {
            final_filename = last_slash + 1;
        } else {
            final_filename = last_backslash + 1;
        }
    } else if (last_slash != null) {
        final_filename = last_slash + 1;
    } else if (last_backslash != null) {
        final_filename = last_backslash + 1;
    }

    var final_buffer: [4096]u8 = undefined;
    const level_str = getLevelStr(level);
    
    _ = snprintf(&final_buffer, final_buffer.len, "%s(%d): [%s] %s", final_filename, line, level_str.ptr, &buffer);

    const output_stream = if (@intFromEnum(level) >= @intFromEnum(CardinalLogLevel.ERROR)) get_stderr() else get_stdout();
    _ = fprintf(output_stream, "%s\n", &final_buffer);
    _ = fflush(output_stream);

    if (log_file) |f| {
        _ = fprintf(f, "%s\n", &final_buffer);
        _ = fflush(f);
    }
}

// Stubs for sink functions
export fn cardinal_log_add_sink(sink_ptr: ?*anyopaque) void {
    _ = sink_ptr;
}
export fn cardinal_log_remove_sink(sink_ptr: ?*anyopaque) void {
    _ = sink_ptr;
}
export fn cardinal_log_set_pattern(pattern: ?[*:0]const u8) void {
    _ = pattern;
}
export fn cardinal_log_create_file_sink(filename: ?[*:0]const u8) ?*anyopaque {
    _ = filename;
    return null;
}
export fn cardinal_log_create_rotating_sink(filename: ?[*:0]const u8, max_size: usize, max_files: usize) ?*anyopaque {
    _ = filename;
    _ = max_size;
    _ = max_files;
    return null;
}
export fn cardinal_log_destroy_sink(sink_ptr: ?*anyopaque) void {
    _ = sink_ptr;
}

// Zig-friendly wrappers
fn log_internal(comptime level: CardinalLogLevel, comptime fmt: []const u8, args: anytype, src: std.builtin.SourceLocation) void {
    if (@intFromEnum(level) < @intFromEnum(min_log_level)) return;

    var buffer: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, fmt, args) catch "Log message too long";

    var final_filename: []const u8 = src.file;
    // Simple path extraction (std.fs.path.basename equivalent)
    var i = final_filename.len;
    while (i > 0) : (i -= 1) {
        if (final_filename[i-1] == '/' or final_filename[i-1] == '\\') {
            final_filename = final_filename[i..];
            break;
        }
    }

    var final_buffer: [4096]u8 = undefined;
    const level_str = getLevelStr(level);
    const final_msg = std.fmt.bufPrintZ(&final_buffer, "{s}({d}): [{s}] {s}", .{final_filename, src.line, level_str, msg}) catch return;

    const output_stream = if (@intFromEnum(level) >= @intFromEnum(CardinalLogLevel.ERROR)) get_stderr() else get_stdout();
    _ = fprintf(output_stream, "%s\n", final_msg.ptr);
    _ = fflush(output_stream);

    if (log_file) |f| {
        _ = fprintf(f, "%s\n", final_msg.ptr);
        _ = fflush(f);
    }
}

pub fn cardinal_log_trace(comptime fmt: []const u8, args: anytype) void {
    log_internal(.TRACE, fmt, args, @src());
}
pub fn cardinal_log_debug(comptime fmt: []const u8, args: anytype) void {
    log_internal(.DEBUG, fmt, args, @src());
}
pub fn cardinal_log_info(comptime fmt: []const u8, args: anytype) void {
    log_internal(.INFO, fmt, args, @src());
}
pub fn cardinal_log_warn(comptime fmt: []const u8, args: anytype) void {
    log_internal(.WARN, fmt, args, @src());
}
pub fn cardinal_log_error(comptime fmt: []const u8, args: anytype) void {
    log_internal(.ERROR, fmt, args, @src());
}
pub fn cardinal_log_fatal(comptime fmt: []const u8, args: anytype) void {
    log_internal(.FATAL, fmt, args, @src());
}
