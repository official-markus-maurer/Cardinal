const std = @import("std");
const memory = @import("memory.zig");

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

// Extern vsnprintf (standard C, but we removed stdio.h)
extern fn vsnprintf(s: [*]u8, n: usize, format: [*:0]const u8, arg: c.va_list) c_int;

// Global state
var min_log_level: CardinalLogLevel = .WARN;

// Sink Interface
pub const CardinalLogSink = extern struct {
    // Updated signature: added category and json_fields
    log_func: *const fn (user_data: ?*anyopaque, level: CardinalLogLevel, category: [*:0]const u8, json_fields: ?[*:0]const u8, file: [*:0]const u8, line: c_int, msg: [*:0]const u8) callconv(.c) void,
    flush_func: ?*const fn (user_data: ?*anyopaque) callconv(.c) void,
    destroy_func: ?*const fn (user_data: ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
};

const MAX_SINKS = 8;
var g_sinks: [MAX_SINKS]?*CardinalLogSink = .{null} ** MAX_SINKS;
var g_sinks_mutex: std.Thread.Mutex = .{};
var g_initialized: bool = false;

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

// --- Console Sink ---
fn console_sink_log(_: ?*anyopaque, level: CardinalLogLevel, category: [*:0]const u8, json_fields: ?[*:0]const u8, file: [*:0]const u8, line: c_int, msg: [*:0]const u8) callconv(.c) void {
    const level_str = getLevelStr(level);
    const use_stderr = @intFromEnum(level) >= @intFromEnum(CardinalLogLevel.ERROR);

    const file_span = std.mem.span(file);
    const cat_span = std.mem.span(category);
    const msg_span = std.mem.span(msg);

    // Format: file(line): [LEVEL][CATEGORY] msg {json}
    if (use_stderr) {
        std.debug.print("{s}({d}): [{s}][{s}] {s}", .{ file_span, line, level_str, cat_span, msg_span });
        if (json_fields) |json| {
            std.debug.print(" {s}", .{std.mem.span(json)});
        }
        std.debug.print("\n", .{});
    } else {
        // Use std.debug.print for all output to avoid issues with std.io.getStdOut in some Zig versions/targets
        std.debug.print("{s}({d}): [{s}][{s}] {s}", .{ file_span, line, level_str, cat_span, msg_span });
        if (json_fields) |json| {
            std.debug.print(" {s}", .{std.mem.span(json)});
        }
        std.debug.print("\n", .{});
    }
}

fn console_sink_flush(_: ?*anyopaque) callconv(.c) void {
    // std.io writers don't necessarily support explicit flush for stdout/stderr in the same way C does,
    // but they are usually unbuffered or line-buffered.
    // We can try to use OS primitives if needed, but for now we rely on default behavior.
}

var g_console_sink: CardinalLogSink = .{
    .log_func = console_sink_log,
    .flush_func = console_sink_flush,
    .destroy_func = null,
    .user_data = null,
};

// --- File Sink ---
const FileSinkData = extern struct {
    file_handle: std.fs.File.Handle,
};

fn file_sink_log(user_data: ?*anyopaque, level: CardinalLogLevel, category: [*:0]const u8, json_fields: ?[*:0]const u8, file: [*:0]const u8, line: c_int, msg: [*:0]const u8) callconv(.c) void {
    if (user_data) |ptr| {
        const data: *FileSinkData = @ptrCast(@alignCast(ptr));
        const file_obj = std.fs.File{ .handle = data.file_handle };
        const level_str = getLevelStr(level);

        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        writer.print("{s}({d}): [{s}][{s}] {s}", .{ std.mem.span(file), line, level_str, std.mem.span(category), std.mem.span(msg) }) catch return;
        if (json_fields) |json| {
            writer.print(" {s}", .{std.mem.span(json)}) catch return;
        }
        writer.print("\n", .{}) catch return;

        file_obj.writeAll(fbs.getWritten()) catch return;
    }
}

fn file_sink_flush(user_data: ?*anyopaque) callconv(.c) void {
    if (user_data) |ptr| {
        const data: *FileSinkData = @ptrCast(@alignCast(ptr));
        const file_obj = std.fs.File{ .handle = data.file_handle };
        file_obj.sync() catch {};
    }
}

fn file_sink_destroy(user_data: ?*anyopaque) callconv(.c) void {
    if (user_data) |ptr| {
        const data: *FileSinkData = @ptrCast(@alignCast(ptr));
        const file_obj = std.fs.File{ .handle = data.file_handle };
        file_obj.close();
        const allocator = memory.cardinal_get_allocator_for_category(.LOGGING).as_allocator();
        allocator.destroy(data);
    }
}

pub export fn cardinal_log_create_file_sink(filename: ?[*:0]const u8) ?*CardinalLogSink {
    if (filename == null) return null;

    const span = std.mem.span(filename.?);
    const f = std.fs.cwd().createFile(span, .{}) catch return null;

    const allocator = memory.cardinal_get_allocator_for_category(.LOGGING).as_allocator();
    const data_ptr = allocator.create(FileSinkData) catch {
        f.close();
        return null;
    };
    data_ptr.file_handle = f.handle;

    const sink_ptr = allocator.create(CardinalLogSink) catch {
        allocator.destroy(data_ptr);
        f.close();
        return null;
    };
    sink_ptr.* = .{
        .log_func = file_sink_log,
        .flush_func = file_sink_flush,
        .destroy_func = file_sink_destroy,
        .user_data = data_ptr,
    };

    return sink_ptr;
}

// --- Initialization ---

pub export fn cardinal_log_init() void {
    cardinal_log_init_with_level(min_log_level);
}

pub export fn cardinal_log_init_with_level(level: CardinalLogLevel) void {
    min_log_level = level;

    g_sinks_mutex.lock();
    defer g_sinks_mutex.unlock();

    if (g_initialized) return;

    // Add console sink by default
    g_sinks[0] = &g_console_sink;

    // Add default file sink
    var file_sink = cardinal_log_create_file_sink("build/cardinal_debug.log");
    if (file_sink == null) {
        file_sink = cardinal_log_create_file_sink("cardinal_debug.log");
    }
    if (file_sink) |sink| {
        g_sinks[1] = sink;
    }

    g_initialized = true;

    const msg = "==== Cardinal Log Start ====";

    // Initial log
    // We can't use standard log machinery easily here without a dummy file/line
    // So we just iterate sinks manually
    for (g_sinks) |s| {
        if (s) |sink| {
            sink.log_func(sink.user_data, .INFO, "GENERAL", null, "log.zig", 0, msg);
            if (sink.flush_func) |flush| flush(sink.user_data);
        }
    }
}

pub export fn cardinal_log_shutdown() void {
    g_sinks_mutex.lock();
    defer g_sinks_mutex.unlock();

    const msg = "==== Cardinal Log End ====";
    for (g_sinks) |s| {
        if (s) |sink| {
            sink.log_func(sink.user_data, .INFO, "GENERAL", null, "log.zig", 0, msg);
            if (sink.flush_func) |flush| flush(sink.user_data);
        }
    }

    // Destroy all sinks except console (which is static)
    for (g_sinks, 0..) |s, i| {
        if (s) |sink| {
            if (sink != &g_console_sink) {
                if (sink.destroy_func) |destroy| {
                    destroy(sink.user_data);
                }
                const allocator = memory.cardinal_get_allocator_for_category(.LOGGING).as_allocator();
                allocator.destroy(sink);
            }
            g_sinks[i] = null;
        }
    }
    g_initialized = false;
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

// --- Sink Management ---

pub export fn cardinal_log_add_sink(sink_ptr: ?*CardinalLogSink) void {
    if (sink_ptr == null) return;

    g_sinks_mutex.lock();
    defer g_sinks_mutex.unlock();

    // Check if already added
    for (g_sinks) |s| {
        if (s == sink_ptr) return;
    }

    // Find empty slot
    for (g_sinks, 0..) |s, i| {
        if (s == null) {
            g_sinks[i] = sink_ptr;
            return;
        }
    }
}

pub export fn cardinal_log_remove_sink(sink_ptr: ?*CardinalLogSink) void {
    if (sink_ptr == null) return;

    g_sinks_mutex.lock();
    defer g_sinks_mutex.unlock();

    for (g_sinks, 0..) |s, i| {
        if (s == sink_ptr) {
            g_sinks[i] = null;
            return;
        }
    }
}

pub export fn cardinal_log_destroy_sink(sink_ptr: ?*CardinalLogSink) void {
    if (sink_ptr == null) return;

    // Remove if attached
    cardinal_log_remove_sink(sink_ptr);

    if (sink_ptr.?.destroy_func) |destroy| {
        destroy(sink_ptr.?.user_data);
    }
    const allocator = memory.cardinal_get_allocator_for_category(.LOGGING).as_allocator();
    allocator.destroy(sink_ptr.?);
}

// --- Log Output ---

pub export fn cardinal_log_output_full(level: CardinalLogLevel, category: [*:0]const u8, json_fields: ?[*:0]const u8, file: [*:0]const u8, line: c_int, fmt: [*:0]const u8, args: c.va_list) void {
    if (@intFromEnum(level) < @intFromEnum(min_log_level)) return;

    var buffer: [4096]u8 = undefined;
    _ = vsnprintf(&buffer, buffer.len, fmt, args);

    var final_filename: [*:0]const u8 = file;
    const last_slash = std.mem.lastIndexOfScalar(u8, std.mem.span(file), '/');
    const last_backslash = std.mem.lastIndexOfScalar(u8, std.mem.span(file), '\\');

    var offset: usize = 0;
    if (last_slash != null and last_backslash != null) {
        offset = @max(last_slash.?, last_backslash.?) + 1;
    } else if (last_slash != null) {
        offset = last_slash.? + 1;
    } else if (last_backslash != null) {
        offset = last_backslash.? + 1;
    }
    final_filename = @ptrCast(file + offset);

    g_sinks_mutex.lock();
    defer g_sinks_mutex.unlock();

    for (g_sinks) |s| {
        if (s) |sink| {
            sink.log_func(sink.user_data, level, category, json_fields, final_filename, line, @ptrCast(&buffer));
            if (sink.flush_func) |flush| flush(sink.user_data);
        }
    }
}

pub export fn cardinal_log_output_v(level: CardinalLogLevel, file: [*:0]const u8, line: c_int, fmt: [*:0]const u8, args: c.va_list) void {
    cardinal_log_output_full(level, "GENERAL", null, file, line, fmt, args);
}

// Zig-friendly wrappers
fn log_internal(comptime level: CardinalLogLevel, category: []const u8, fields: anytype, comptime fmt: []const u8, args: anytype, src: std.builtin.SourceLocation) void {
    if (@intFromEnum(level) < @intFromEnum(min_log_level)) return;

    var buffer: [4096]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buffer, fmt, args) catch "Log message too long";

    // Handle structured data
    var json_buffer: [4096]u8 = undefined;
    var json_ptr: ?[*:0]const u8 = null;
    if (@TypeOf(fields) != void and @TypeOf(fields) != @TypeOf(null)) {
        var fbs = std.io.fixedBufferStream(&json_buffer);
        fbs.writer().print("{f}", .{std.json.fmt(fields, .{})}) catch {};

        // Manually write null terminator if space allows
        if (fbs.pos < json_buffer.len) {
            json_buffer[fbs.pos] = 0;
            json_ptr = @ptrCast(&json_buffer);
        }
    }

    // Handle category string (convert to null-terminated)
    var cat_buffer: [64]u8 = undefined;
    const cat_len = @min(category.len, 63);
    @memcpy(cat_buffer[0..cat_len], category[0..cat_len]);
    cat_buffer[cat_len] = 0;

    var final_filename_slice: []const u8 = src.file;
    // Simple path extraction (std.fs.path.basename equivalent)
    var i = final_filename_slice.len;
    while (i > 0) : (i -= 1) {
        if (final_filename_slice[i - 1] == '/' or final_filename_slice[i - 1] == '\\') {
            final_filename_slice = final_filename_slice[i..];
            break;
        }
    }

    // Convert slice to null-terminated for C interop
    var filename_buf: [256]u8 = undefined;
    const len = @min(final_filename_slice.len, 255);
    @memcpy(filename_buf[0..len], final_filename_slice[0..len]);
    filename_buf[len] = 0;

    g_sinks_mutex.lock();
    defer g_sinks_mutex.unlock();

    for (g_sinks) |s| {
        if (s) |sink| {
            sink.log_func(sink.user_data, level, @ptrCast(&cat_buffer), json_ptr, @ptrCast(&filename_buf), @intCast(src.line), msg.ptr);
            if (sink.flush_func) |flush| flush(sink.user_data);
        }
    }
}

pub fn ScopedLogger(comptime category: []const u8) type {
    return struct {
        pub fn trace(comptime fmt: []const u8, args: anytype) void {
            log_internal(.TRACE, category, null, fmt, args, @src());
        }
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            log_internal(.DEBUG, category, null, fmt, args, @src());
        }
        pub fn info(comptime fmt: []const u8, args: anytype) void {
            log_internal(.INFO, category, null, fmt, args, @src());
        }
        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            log_internal(.WARN, category, null, fmt, args, @src());
        }
        pub fn err(comptime fmt: []const u8, args: anytype) void {
            log_internal(.ERROR, category, null, fmt, args, @src());
        }
        pub fn fatal(comptime fmt: []const u8, args: anytype) void {
            log_internal(.FATAL, category, null, fmt, args, @src());
        }

        // Structured logging versions
        pub fn trace_s(fields: anytype, comptime fmt: []const u8, args: anytype) void {
            log_internal(.TRACE, category, fields, fmt, args, @src());
        }
        pub fn debug_s(fields: anytype, comptime fmt: []const u8, args: anytype) void {
            log_internal(.DEBUG, category, fields, fmt, args, @src());
        }
        pub fn info_s(fields: anytype, comptime fmt: []const u8, args: anytype) void {
            log_internal(.INFO, category, fields, fmt, args, @src());
        }
        pub fn warn_s(fields: anytype, comptime fmt: []const u8, args: anytype) void {
            log_internal(.WARN, category, fields, fmt, args, @src());
        }
        pub fn err_s(fields: anytype, comptime fmt: []const u8, args: anytype) void {
            log_internal(.ERROR, category, fields, fmt, args, @src());
        }
        pub fn fatal_s(fields: anytype, comptime fmt: []const u8, args: anytype) void {
            log_internal(.FATAL, category, fields, fmt, args, @src());
        }
    };
}

pub fn cardinal_log_trace(comptime fmt: []const u8, args: anytype) void {
    log_internal(.TRACE, "GENERAL", null, fmt, args, @src());
}
pub fn cardinal_log_debug(comptime fmt: []const u8, args: anytype) void {
    log_internal(.DEBUG, "GENERAL", null, fmt, args, @src());
}
pub fn cardinal_log_info(comptime fmt: []const u8, args: anytype) void {
    log_internal(.INFO, "GENERAL", null, fmt, args, @src());
}
pub fn cardinal_log_warn(comptime fmt: []const u8, args: anytype) void {
    log_internal(.WARN, "GENERAL", null, fmt, args, @src());
}
pub fn cardinal_log_error(comptime fmt: []const u8, args: anytype) void {
    log_internal(.ERROR, "GENERAL", null, fmt, args, @src());
}
pub fn cardinal_log_fatal(comptime fmt: []const u8, args: anytype) void {
    log_internal(.FATAL, "GENERAL", null, fmt, args, @src());
}
