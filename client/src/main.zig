//! Cardinal client entrypoint.
//!
//! This executable is primarily a thin wrapper around engine subsystems. It currently contains
//! a small bootstrap loop intended for smoke-testing renderer init and frame submission.
const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const memory = engine.memory;
const async_loader = engine.async_loader;
const texture_loader = engine.texture_loader;
const mesh_loader = engine.mesh_loader;
const material_loader = engine.material_loader;
const window = engine.window;
const vulkan_renderer = engine.vulkan_renderer;
const vulkan_renderer_frame = engine.vulkan_renderer_frame;
const types = engine.vulkan_types;
const ref_counting = engine.ref_counting;

const client_log = log.ScopedLogger("CLIENT");

/// Routes `std.log` into Cardinal's logging backend.
pub const std_options: std.Options = .{
    .logFn = myLogFn,
};

/// `std.log` callback used by `std_options`.
fn myLogFn(
    comptime message_level: std.log.Level,
    comptime scope: anytype,
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_name = @tagName(scope);
    const scoped_log = log.ScopedLogger(scope_name);

    switch (message_level) {
        .err => scoped_log.err(format, args),
        .warn => scoped_log.warn(format, args),
        .info => scoped_log.info(format, args),
        .debug => scoped_log.debug(format, args),
    }
}

/// Prints CLI usage text.
fn print_usage(program_name: []const u8) void {
    std.debug.print("Usage: {s} [options]\n", .{program_name});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --log-level <level>  Set log level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)\n", .{});
    std.debug.print("  --config <path>      Config file path (default: cardinal_config.json)\n", .{});
    std.debug.print("  --help               Show this help message\n", .{});
}

/// Initializes subsystems, runs a short render loop, then shuts down.
pub fn main() !u8 {
    var log_level: log.CardinalLogLevel = .WARN;
    var config_path: []const u8 = "cardinal_config.json";

    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--log-level") and i + 1 < args.len) {
            log_level = log.cardinal_log_parse_level(args[i + 1].ptr);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--config") and i + 1 < args.len) {
            config_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help")) {
            print_usage(args[0]);
            return 0;
        }
    }

    var config_manager = engine.config.ConfigManager.init(std.heap.page_allocator, config_path, .{
        .window_title = "Cardinal Client",
        .window_width = 1024,
        .window_height = 768,
        .window_resizable = true,
        .memory_size = 1024 * 1024 * 64,
        .ref_counting_buckets = 1009,
        .async_worker_threads = 4,
        .async_queue_size = 256,
        .cache_size = 1000,
    });
    defer config_manager.deinit();
    config_manager.load() catch |err| {
        std.debug.print("Failed to load config '{s}': {s}\n", .{ config_manager.config_path, @errorName(err) });
    };

    const cfg = config_manager.config;
    memory.cardinal_memory_init(cfg.memory_size);
    defer memory.cardinal_memory_shutdown();

    log.cardinal_log_init_with_level(log_level);
    defer log.cardinal_log_shutdown();

    if (!ref_counting.cardinal_ref_counting_init(cfg.ref_counting_buckets)) {
        client_log.err("Failed to initialize reference counting registry", .{});
        return 255;
    }
    defer ref_counting.cardinal_ref_counting_shutdown();

    const async_config = async_loader.CardinalAsyncLoaderConfig{
        .worker_thread_count = cfg.async_worker_threads,
        .max_queue_size = cfg.async_queue_size,
        .enable_priority_queue = true,
    };
    if (!async_loader.cardinal_async_loader_init(&async_config)) {
        client_log.err("Failed to initialize async loader", .{});
        return 255;
    }
    defer async_loader.cardinal_async_loader_shutdown();

    _ = texture_loader.texture_cache_initialize(cfg.cache_size);
    _ = mesh_loader.mesh_cache_initialize(cfg.cache_size);
    defer texture_loader.texture_cache_shutdown_system();
    defer mesh_loader.mesh_cache_shutdown_system();

    client_log.info("Multi-threaded engine initialized successfully", .{});

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const title_z = allocator.dupeZ(u8, cfg.window_title) catch return 255;
    defer allocator.free(title_z);

    const config = window.CardinalWindowConfig{
        .title = title_z.ptr,
        .width = cfg.window_width,
        .height = cfg.window_height,
        .resizable = cfg.window_resizable,
    };
    const win = window.cardinal_window_create(&config);
    if (win == null) {
        return 255;
    }
    defer window.cardinal_window_destroy(win);

    var renderer: types.CardinalRenderer = .{ ._opaque = null };
    if (!vulkan_renderer.cardinal_renderer_create(&renderer, win, &cfg.renderer)) {
        return 255;
    }
    defer vulkan_renderer.cardinal_renderer_destroy(&renderer);

    vulkan_renderer.cardinal_renderer_enable_pbr(&renderer, true);

    var frames: u32 = 0;
    while (!window.cardinal_window_should_close(win)) {
        window.cardinal_window_poll(win);
        vulkan_renderer_frame.cardinal_renderer_draw_frame(&renderer);
        engine.tracy.frameMark();
        frames += 1;
        // TODO: Replace this early-exit with a real game loop or CLI-controlled frame count.
        if (frames > 10) break;
    }

    vulkan_renderer.cardinal_renderer_wait_idle(&renderer);

    client_log.info("Shutting down multi-threaded engine systems", .{});

    return 0;
}
