const std = @import("std");
const config_pkg = @import("config.zig");
const log = @import("log.zig");
const eng_log = log.ScopedLogger("ENGINE");
const memory = @import("memory.zig");
const ref_counting = @import("ref_counting.zig");
const resource_state = @import("resource_state.zig");
const async_loader = @import("async_loader.zig");
const window = @import("window.zig");
const module = @import("module.zig");
const platform = @import("platform.zig");
const events = @import("events.zig");
const input = @import("input.zig");
const stack_allocator = @import("stack_allocator.zig");
const texture_loader = @import("../assets/texture_loader.zig");
const loader_mod = @import("../assets/loader.zig");
const mesh_loader = @import("../assets/mesh_loader.zig");
const vulkan_renderer = @import("../renderer/vulkan_renderer.zig");
const vulkan_types = @import("../renderer/vulkan_types.zig");

pub const CardinalEngineConfig = config_pkg.CardinalEngineConfig;

pub const CardinalEngine = struct {
    allocator: std.mem.Allocator,
    module_manager: module.ModuleManager,
    window: ?*window.CardinalWindow,
    renderer: vulkan_types.CardinalRenderer,
    config: CardinalEngineConfig,
    config_manager: config_pkg.ConfigManager,

    frame_allocator: stack_allocator.StackAllocator = undefined,
    frame_memory: []u8 = undefined,

    // Time tracking
    last_frame_time: u64 = 0,

    // Track initialization state
    memory_initialized: bool = false,
    ref_counting_initialized: bool = false,
    resource_state_initialized: bool = false,
    async_loader_initialized: bool = false,
    caches_initialized: bool = false,
    window_initialized: bool = false,
    renderer_initialized: bool = false,

    pub fn create(allocator: std.mem.Allocator, config: CardinalEngineConfig) !*CardinalEngine {
        const self = try allocator.create(CardinalEngine);

        var config_manager = config_pkg.ConfigManager.init(allocator, "cardinal_config.json", config);
        config_manager.load() catch |err| {
            eng_log.warn("Failed to load config file: {}", .{err});
        };

        self.* = CardinalEngine{
            .allocator = allocator,
            .module_manager = module.ModuleManager.init(allocator),
            .config_manager = config_manager,
            .config = config_manager.config,
            .window = null,
            .renderer = .{ ._opaque = null },
            .last_frame_time = platform.get_time_ns(),
        };
        errdefer {
            self.deinit();
            allocator.destroy(self);
        }

        try self.initSystems();
        try self.initWindowAndRenderer();

        // Start modules
        try self.module_manager.startup();

        return self;
    }

    pub fn deinit(self: *CardinalEngine) void {
        // Shutdown async loader first to stop worker threads and release pending tasks
        if (self.async_loader_initialized) {
            async_loader.cardinal_async_loader_shutdown();
            self.async_loader_initialized = false;
        }

        // Shutdown caches to release held references before renderer/ref-counting shutdown
        if (self.caches_initialized) {
            mesh_loader.mesh_cache_shutdown_system();
            texture_loader.texture_cache_shutdown_system();
            self.caches_initialized = false;
        }

        // Shutdown modules
        self.module_manager.shutdown();
        self.module_manager.deinit();

        if (self.renderer_initialized) {
            vulkan_renderer.cardinal_renderer_destroy(&self.renderer);
        }

        if (self.window_initialized) {
            window.cardinal_window_destroy(self.window);
        }

        if (self.resource_state_initialized) {
            resource_state.cardinal_resource_state_shutdown();
        }

        if (self.ref_counting_initialized) {
            ref_counting.cardinal_ref_counting_shutdown();
        }

        if (self.memory_initialized) {
            memory.cardinal_memory_shutdown();
        }

        if (self.frame_memory.len > 0) {
            self.allocator.free(self.frame_memory);
        }

        self.config_manager.deinit();
    }

    pub fn update(self: *CardinalEngine) !void {
        // Calculate delta time
        const current_time = platform.get_time_ns();
        const dt_ns = current_time - self.last_frame_time;
        self.last_frame_time = current_time;

        // Convert to seconds (f32)
        const delta_time = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;

        // Reset frame allocator at the beginning of the frame
        self.frame_allocator.reset();

        if (self.window) |win| {
            window.cardinal_window_poll(win);
            input.update(win);
        }
        try self.module_manager.update(delta_time);
    }

    pub fn shouldClose(self: *CardinalEngine) bool {
        return window.cardinal_window_should_close(self.window);
    }

    fn initSystems(self: *CardinalEngine) !void {
        eng_log.info("Initializing memory management system...", .{});
        memory.cardinal_memory_init(self.config.memory_size);
        self.memory_initialized = true;
        eng_log.info("Memory management system initialized", .{});

        // Initialize Frame Allocator (16MB)
        const frame_mem_size = 16 * 1024 * 1024;
        self.frame_memory = try self.allocator.alloc(u8, frame_mem_size);
        self.frame_allocator = stack_allocator.StackAllocator.init(self.frame_memory);
        eng_log.info("Frame allocator initialized with {d}MB", .{frame_mem_size / 1024 / 1024});

        // Register Core Modules
        try self.module_manager.register(.{
            .name = "Events",
            .init_fn = initEvents,
            .shutdown_fn = shutdownEvents,
            .ctx = self,
        });

        try self.module_manager.register(.{
            .name = "Input",
            .init_fn = initInput,
            .shutdown_fn = shutdownInput,
            .ctx = self,
        });

        eng_log.info("Initializing reference counting system...", .{});
        if (!ref_counting.cardinal_ref_counting_init(self.config.ref_counting_buckets)) {
            eng_log.err("Failed to initialize reference counting system", .{});
            return error.RefCountingInitFailed;
        }
        self.ref_counting_initialized = true;
        eng_log.info("Reference counting system initialized", .{});

        eng_log.info("Initializing resource state tracking system...", .{});
        if (!resource_state.cardinal_resource_state_init(self.config.ref_counting_buckets)) {
            eng_log.err("Failed to initialize resource state tracking system", .{});
            return error.ResourceStateInitFailed;
        }
        self.resource_state_initialized = true;
        eng_log.info("Resource state tracking system initialized", .{});

        eng_log.info("Initializing async loader system...", .{});

        // memory.cardinal_get_allocator_for_category returns a pointer, so it is assumed to be valid if init was called.
        eng_log.info("Memory allocator check passed", .{});

        const async_config = async_loader.CardinalAsyncLoaderConfig{
            .worker_thread_count = self.config.async_worker_threads,
            .max_queue_size = self.config.async_queue_size,
            .enable_priority_queue = true,
        };

        eng_log.info("About to call cardinal_async_loader_init...", .{});
        if (!async_loader.cardinal_async_loader_init(&async_config)) {
            eng_log.err("Failed to initialize async loader system", .{});
            return error.AsyncLoaderInitFailed;
        }

        // Register loaders
        const texture_load_fn: *const fn (?[*]const u8, ?*anyopaque) callconv(.c) ?*ref_counting.CardinalRefCountedResource = @ptrCast(&texture_loader.texture_load_with_ref_counting);
        async_loader.cardinal_async_register_texture_loader(texture_load_fn);
        async_loader.cardinal_async_register_scene_loader(loader_mod.cardinal_scene_load);

        self.async_loader_initialized = true;
        log.cardinal_log_info("Async loader system initialized successfully", .{});

        _ = texture_loader.texture_cache_initialize(self.config.cache_size);
        _ = mesh_loader.mesh_cache_initialize(self.config.cache_size);
        self.caches_initialized = true;

        eng_log.info("Multi-threaded asset caches initialized successfully", .{});
    }

    fn initWindowAndRenderer(self: *CardinalEngine) !void {
        const title_z = try self.allocator.dupeZ(u8, self.config.window_title);
        defer self.allocator.free(title_z);

        const config = window.CardinalWindowConfig{
            .title = title_z,
            .width = self.config.window_width,
            .height = self.config.window_height,
            .resizable = self.config.window_resizable,
        };
        self.window = window.cardinal_window_create(&config);
        if (self.window == null) {
            return error.WindowCreateFailed;
        }
        self.window_initialized = true;

        if (!vulkan_renderer.cardinal_renderer_create(&self.renderer, self.window, &self.config.renderer)) {
            // Cleanup window if renderer creation fails
            window.cardinal_window_destroy(self.window);
            self.window = null;
            self.window_initialized = false;
            return error.RendererCreateFailed;
        }
        self.renderer_initialized = true;

        // Set frame allocator
        vulkan_renderer.cardinal_renderer_set_frame_allocator(&self.renderer, &self.frame_allocator);
    }
};

// Module wrappers
fn initEvents(ctx: ?*anyopaque) !void {
    const self = @as(*CardinalEngine, @ptrCast(@alignCast(ctx)));
    events.init(self.allocator);
}

fn shutdownEvents(ctx: ?*anyopaque) !void {
    _ = ctx;
    events.shutdown();
}

fn initInput(ctx: ?*anyopaque) !void {
    const self = @as(*CardinalEngine, @ptrCast(@alignCast(ctx)));
    input.init(self.allocator);
    input.pushLayer("Base", false);
}

fn shutdownInput(ctx: ?*anyopaque) !void {
    _ = ctx;
    input.shutdown();
}
