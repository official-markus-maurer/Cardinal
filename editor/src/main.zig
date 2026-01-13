const std = @import("std");
const log = @import("cardinal_engine").log;
const EditorApp = @import("app.zig").EditorApp;
const EditorConfig = @import("app.zig").EditorConfig;

fn print_usage(program_name: []const u8) void {
    std.debug.print("Usage: {s} [options]\n", .{program_name});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --log-level <level>  Set log level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)\n", .{});
    std.debug.print("  --help               Show this help message\n", .{});
}

pub fn main() !u8 {
    // Initialize memory system first
    // Note: CardinalEngine also initializes memory, but we made it idempotent.
    const memory = @import("cardinal_engine").memory;
    memory.cardinal_memory_init(1024 * 1024 * 64); // 64MB

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    var log_level: log.CardinalLogLevel = .WARN;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--log-level") and i + 1 < args.len) {
            log_level = log.cardinal_log_parse_level(args[i + 1].ptr);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help")) {
            print_usage(args[0]);
            return 0;
        }
    }

    log.cardinal_log_init_with_level(log_level);
    defer log.cardinal_log_shutdown();
    defer memory.cardinal_memory_shutdown();

    var config = EditorConfig{
        .window_title = "Cardinal Editor",
    };
    config.renderer.prefer_hdr = false;

    var app = EditorApp.create(allocator, config) catch |err| {
        log.cardinal_log_error("Failed to initialize editor application: {}", .{err});
        return 255;
    };
    defer app.destroy();

    app.run() catch |err| {
        log.cardinal_log_error("Runtime error: {}", .{err});
        return 255;
    };

    return 0;
}
