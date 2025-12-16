const std = @import("std");
const log = @import("cardinal_engine").log;

const c = @cImport({
    @cInclude("editor_layer.h");
    @cInclude("cardinal/assets/material_loader.h");
    @cInclude("cardinal/assets/mesh_loader.h");
    @cInclude("cardinal/assets/texture_loader.h");
    @cInclude("cardinal/cardinal.h");
    @cInclude("cardinal/core/async_loader.h");
    // @cInclude("cardinal/core/log.h"); // Handled by Zig module
    @cInclude("cardinal/core/ref_counting.h");
    @cInclude("cardinal/core/resource_state.h");
    @cInclude("string.h");
    @cInclude("stdio.h");
});

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

    log.cardinal_log_info("Initializing memory management system...", .{});
    c.cardinal_memory_init(4 * 1024 * 1024);
    log.cardinal_log_info("Memory management system initialized", .{});

    log.cardinal_log_info("Initializing reference counting system...", .{});
    if (!c.cardinal_ref_counting_init(1009)) {
        log.cardinal_log_error("Failed to initialize reference counting system", .{});
        c.cardinal_memory_shutdown();
        log.cardinal_log_shutdown();
        return 255;
    }
    log.cardinal_log_info("Reference counting system initialized", .{});

    log.cardinal_log_info("Initializing resource state tracking system...", .{});
    if (!c.cardinal_resource_state_init(1009)) {
        log.cardinal_log_error("Failed to initialize resource state tracking system", .{});
        c.cardinal_ref_counting_shutdown();
        c.cardinal_memory_shutdown();
        log.cardinal_log_shutdown();
        return 255;
    }
    log.cardinal_log_info("Resource state tracking system initialized", .{});

    log.cardinal_log_info("Initializing async loader system...", .{});

    if (c.cardinal_get_allocator_for_category(c.CARDINAL_MEMORY_CATEGORY_ENGINE) == null) {
        log.cardinal_log_error("Engine memory allocator not available", .{});
        c.cardinal_memory_shutdown();
        log.cardinal_log_shutdown();
        return 255;
    }
    log.cardinal_log_info("Memory allocator check passed", .{});

    var async_config = c.CardinalAsyncLoaderConfig{
        .worker_thread_count = 2,
        .max_queue_size = 100,
        .enable_priority_queue = true,
    };

    log.cardinal_log_info("About to call cardinal_async_loader_init...", .{});
    if (!c.cardinal_async_loader_init(&async_config)) {
        log.cardinal_log_error("Failed to initialize async loader system", .{});
        c.cardinal_memory_shutdown();
        log.cardinal_log_shutdown();
        return 255;
    }
    log.cardinal_log_info("Async loader system initialized successfully", .{});

    _ = c.texture_cache_initialize(1000);
    _ = c.mesh_cache_initialize(1000);
    _ = c.material_cache_initialize(1000);

    log.cardinal_log_info("Multi-threaded asset caches initialized successfully", .{});

    var config = c.CardinalWindowConfig{
        .title = "Cardinal Editor",
        .width = 1600,
        .height = 900,
        .resizable = true,
    };
    const window = c.cardinal_window_create(&config);
    if (window == null) {
        c.cardinal_async_loader_shutdown();
        c.cardinal_memory_shutdown();
        log.cardinal_log_shutdown();
        return 255;
    }

    var renderer: c.CardinalRenderer = undefined;
    if (!c.cardinal_renderer_create(&renderer, window)) {
        c.cardinal_window_destroy(window);
        c.cardinal_async_loader_shutdown();
        c.cardinal_memory_shutdown();
        log.cardinal_log_shutdown();
        return 255;
    }

    if (!c.editor_layer_init(window, &renderer)) {
        c.cardinal_renderer_destroy(&renderer);
        c.cardinal_window_destroy(window);
        c.cardinal_async_loader_shutdown();
        c.cardinal_memory_shutdown();
        log.cardinal_log_shutdown();
        return 255;
    }

    while (!c.cardinal_window_should_close(window)) {
        c.cardinal_window_poll(window);

        c.editor_layer_update();
        c.editor_layer_render();

        c.cardinal_renderer_draw_frame(&renderer);

        log.cardinal_log_debug("[EDITOR] Processing pending uploads after frame draw", .{});
        c.editor_layer_process_pending_uploads();
    }

    c.cardinal_renderer_wait_idle(&renderer);
    c.editor_layer_shutdown();
    c.cardinal_renderer_destroy(&renderer);
    c.cardinal_window_destroy(window);

    c.material_cache_shutdown_system();
    c.mesh_cache_shutdown_system();
    c.texture_cache_shutdown_system();

    c.cardinal_async_loader_shutdown();

    c.cardinal_resource_state_shutdown();
    c.cardinal_ref_counting_shutdown();

    c.cardinal_memory_shutdown();
    log.cardinal_log_shutdown();
    return 0;
}
