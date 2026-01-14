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

// Define std_options to route std.log to our logging system
pub const std_options: std.Options = .{
    .logFn = myLogFn,
};

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

fn print_usage(program_name: []const u8) void {
    std.debug.print("Usage: {s} [options]\n", .{program_name});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --log-level <level>  Set log level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)\n", .{});
    std.debug.print("  --help               Show this help message\n", .{});
}

pub fn main() !u8 {
    // Initialize memory system first
    memory.cardinal_memory_init(1024 * 1024 * 64); // 64MB
    
    // Get allocator for arguments
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

    // Initialize async loader
    const async_config = async_loader.CardinalAsyncLoaderConfig{
        .worker_thread_count = 4,
        .max_queue_size = 256,
        .enable_priority_queue = true,
    };

    if (!async_loader.cardinal_async_loader_init(&async_config)) {
        log.cardinal_log_error("Failed to initialize async loader", .{});
        memory.cardinal_memory_shutdown();
        log.cardinal_log_shutdown();
        return 255;
    }

    // Initialize asset caches
    _ = texture_loader.texture_cache_initialize(1000);
    _ = mesh_loader.mesh_cache_initialize(1000);

    log.cardinal_log_info("Multi-threaded engine initialized successfully", .{});

    const config = window.CardinalWindowConfig{
        .title = "Cardinal Client",
        .width = 1024,
        .height = 768,
        .resizable = true,
    };
    const win = window.cardinal_window_create(&config);
    if (win == null) {
        log.cardinal_log_shutdown();
        return 255;
    }

    var renderer: types.CardinalRenderer = .{ ._opaque = null };
    if (!vulkan_renderer.cardinal_renderer_create(&renderer, win, null)) {
        window.cardinal_window_destroy(win);
        log.cardinal_log_shutdown();
        return 255;
    }

    // Enable PBR to ensure pipelines are set up (skybox might depend on some shared state or just to be safe)
    vulkan_renderer.cardinal_renderer_enable_pbr(&renderer, true);

    // Load Skybox
    // const skybox_path = "C:\\Users\\admin\\Documents\\Cardinal\\assets\\skybox\\kloofendal_48d_partly_cloudy_puresky_16k.exr";
    // if (!vulkan_renderer.cardinal_renderer_set_skybox(&renderer, skybox_path)) {
    //    log.cardinal_log_error("Failed to set skybox: {s}", .{skybox_path});
    // }

    var frames: u32 = 0;
    while (!window.cardinal_window_should_close(win)) {
        window.cardinal_window_poll(win);
        vulkan_renderer_frame.cardinal_renderer_draw_frame(&renderer);
        frames += 1;
        if (frames > 10) break;
    }

    vulkan_renderer.cardinal_renderer_wait_idle(&renderer);
    vulkan_renderer.cardinal_renderer_destroy(&renderer);
    window.cardinal_window_destroy(win);

    log.cardinal_log_info("Shutting down multi-threaded engine systems", .{});

    texture_loader.texture_cache_shutdown_system();
    mesh_loader.mesh_cache_shutdown_system();

    async_loader.cardinal_async_loader_shutdown();
    ref_counting.cardinal_ref_counting_shutdown();
    memory.cardinal_memory_shutdown();
    log.cardinal_log_shutdown();

    return 0;
}
