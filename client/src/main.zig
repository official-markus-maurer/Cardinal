const std = @import("std");

const c = @cImport({
    @cInclude("cardinal/assets/material_loader.h");
    @cInclude("cardinal/assets/mesh_loader.h");
    @cInclude("cardinal/assets/texture_loader.h");
    @cInclude("cardinal/cardinal.h");
    @cInclude("cardinal/core/async_loader.h");
    @cInclude("cardinal/core/log.h");
    @cInclude("cardinal/core/memory.h");
    @cInclude("cardinal/core/ref_counting.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
});

extern fn cardinal_log_from_zig(level: c.CardinalLogLevel, file: [*]const u8, line: c_int, msg: [*]const u8) void;

fn log_info(comptime fmt: []const u8, args: anytype) void {
    log_output(c.CARDINAL_LOG_LEVEL_INFO, fmt, args);
}

fn log_error(comptime fmt: []const u8, args: anytype) void {
    log_output(c.CARDINAL_LOG_LEVEL_ERROR, fmt, args);
}

fn log_output(level: c.CardinalLogLevel, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    cardinal_log_from_zig(level, "main.zig", @as(c_int, @intCast(@src().line)), msg.ptr);
}

fn print_usage(program_name: []const u8) void {
    std.debug.print("Usage: {s} [options]\n", .{program_name});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --log-level <level>  Set log level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)\n", .{});
    std.debug.print("  --help               Show this help message\n", .{});
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var log_level: c.CardinalLogLevel = c.CARDINAL_LOG_LEVEL_WARN;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--log-level") and i + 1 < args.len) {
            log_level = c.cardinal_log_parse_level(args[i + 1].ptr);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help")) {
            print_usage(args[0]);
            return 0;
        }
    }

    c.cardinal_log_init_with_level(log_level);

    // Initialize memory system
    c.cardinal_memory_init(1024 * 1024 * 64); // 64MB

    // Initialize async loader
    var async_config = c.CardinalAsyncLoaderConfig{
        .worker_thread_count = 4,
        .max_queue_size = 256,
        .enable_priority_queue = true,
    };

    if (!c.cardinal_async_loader_init(&async_config)) {
        log_error("Failed to initialize async loader", .{});
        c.cardinal_memory_shutdown();
        c.cardinal_log_shutdown();
        return 255;
    }

    // Initialize asset caches
    _ = c.texture_cache_initialize(1000);
    _ = c.mesh_cache_initialize(1000);
    _ = c.material_cache_initialize(1000);

    log_info("Multi-threaded engine initialized successfully", .{});

    var config = c.CardinalWindowConfig{
        .title = "Cardinal Client",
        .width = 1024,
        .height = 768,
        .resizable = true,
    };
    const window = c.cardinal_window_create(&config);
    if (window == null) {
        c.cardinal_log_shutdown();
        return 255;
    }

    var renderer: c.CardinalRenderer = undefined;
    if (!c.cardinal_renderer_create(&renderer, window)) {
        c.cardinal_window_destroy(window);
        c.cardinal_log_shutdown();
        return 255;
    }

    while (!c.cardinal_window_should_close(window)) {
        c.cardinal_window_poll(window);
        c.cardinal_renderer_draw_frame(&renderer);
    }

    c.cardinal_renderer_wait_idle(&renderer);
    c.cardinal_renderer_destroy(&renderer);
    c.cardinal_window_destroy(window);

    log_info("Shutting down multi-threaded engine systems", .{});

    c.texture_cache_shutdown_system();
    c.mesh_cache_shutdown_system();
    c.material_cache_shutdown_system();

    c.cardinal_async_loader_shutdown();
    c.cardinal_ref_counting_shutdown();
    c.cardinal_memory_shutdown();
    c.cardinal_log_shutdown();

    return 0;
}
