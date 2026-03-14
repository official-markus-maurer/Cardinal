//! Engine orchestration: subsystem initialization, per-frame update, and shutdown.
//!
//! `CardinalEngine` owns the core runtime systems (memory, window, renderer, ECS, modules) and
//! provides a single update loop entrypoint for applications.
const std = @import("std");
const config_pkg = @import("config.zig");
const log = @import("log.zig");
const tracy = @import("tracy.zig");
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
const ecs_registry = @import("../ecs/registry.zig");
const ecs_systems = @import("../ecs/systems.zig");
const ecs_scheduler = @import("../ecs/scheduler.zig");
const ecs_components = @import("../ecs/components.zig");

/// Runtime configuration for the engine instance.
pub const CardinalEngineConfig = config_pkg.CardinalEngineConfig;

/// Owns core subsystems and drives initialization, updates, and shutdown.
pub const CardinalEngine = struct {
    allocator: std.mem.Allocator,
    module_manager: module.ModuleManager,
    window: ?*window.CardinalWindow,
    renderer: vulkan_types.CardinalRenderer,
    config: CardinalEngineConfig,
    config_manager: config_pkg.ConfigManager,
    registry: ecs_registry.Registry,
    scheduler: ecs_scheduler.Scheduler,

    frame_allocator: stack_allocator.StackAllocator = undefined,
    frame_memory: []u8 = undefined,

    /// Timestamp of the previous frame in nanoseconds.
    last_frame_time: u64 = 0,

    /// Subsystem initialization flags used to order shutdown.
    memory_initialized: bool = false,
    ref_counting_initialized: bool = false,
    resource_state_initialized: bool = false,
    async_loader_initialized: bool = false,
    caches_initialized: bool = false,
    window_initialized: bool = false,
    renderer_initialized: bool = false,

    skybox_path: ?[:0]u8 = null,

    /// Allocates and initializes a new engine instance.
    pub fn create(allocator: std.mem.Allocator, config: CardinalEngineConfig) !*CardinalEngine {
        const self = try allocator.create(CardinalEngine);

        var config_manager = config_pkg.ConfigManager.init(allocator, "cardinal_config.json", config);
        config_manager.load() catch |err| {
            eng_log.warn("Failed to load config file: {}", .{err});
        };

        self.allocator = allocator;
        self.module_manager = module.ModuleManager.init(allocator);
        self.window = null;
        self.renderer = .{ ._opaque = null };
        self.config_manager = config_manager;
        self.config = config_manager.config;
        self.registry = ecs_registry.Registry.init(allocator);
        self.scheduler = ecs_scheduler.Scheduler.init(allocator, &self.registry);
        self.last_frame_time = platform.get_time_ns();
        self.memory_initialized = false;
        self.ref_counting_initialized = false;
        self.resource_state_initialized = false;
        self.async_loader_initialized = false;
        self.caches_initialized = false;
        self.window_initialized = false;
        self.renderer_initialized = false;
        self.skybox_path = null;

        errdefer {
            self.deinit();
            allocator.destroy(self);
        }

        try self.initSystems();
        try self.initWindowAndRenderer();

        try self.module_manager.startup();

        return self;
    }

    /// Shuts down subsystems in a dependency-safe order.
    pub fn deinit(self: *CardinalEngine) void {
        self.scheduler.deinit();

        if (self.async_loader_initialized) {
            async_loader.cardinal_async_loader_shutdown();
            self.async_loader_initialized = false;
        }

        if (self.caches_initialized) {
            mesh_loader.mesh_cache_shutdown_system();
            texture_loader.texture_cache_shutdown_system();
            self.caches_initialized = false;
        }

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

        if (self.skybox_path) |p| {
            self.allocator.free(p);
            self.skybox_path = null;
        }

        self.registry.deinit();
        self.config_manager.deinit();
    }

    /// Runs a single frame: polling, ECS, modules, and per-frame allocator reset.
    pub fn update(self: *CardinalEngine) !void {
        const zone = tracy.zoneS(@src(), "Engine Update");
        defer zone.end();

        const current_time = platform.get_time_ns();
        const dt_ns = current_time - self.last_frame_time;
        self.last_frame_time = current_time;

        const delta_time = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;

        self.frame_allocator.reset();

        if (self.window) |win| {
            window.cardinal_window_poll(win);
            input.update(win);
        }

        try self.scheduler.run(delta_time);
        self.sync_skybox_from_ecs();

        try self.module_manager.update(delta_time);
    }

    fn sync_skybox_from_ecs(self: *CardinalEngine) void {
        if (!self.renderer_initialized) return;
        var view = self.registry.view(ecs_components.Skybox);
        var it = view.iterator();
        const entry = it.next() orelse return;
        const sky = entry.component;
        const path = sky.slice();
        if (path.len == 0) return;

        if (self.skybox_path) |p| {
            if (std.mem.eql(u8, std.mem.span(p.ptr), path)) return;
            self.allocator.free(p);
            self.skybox_path = null;
        }

        self.skybox_path = self.allocator.dupeZ(u8, path) catch return;
        const ptr_path: ?[*:0]const u8 = if (self.skybox_path) |p| p.ptr else null;
        _ = vulkan_renderer.cardinal_renderer_set_skybox(&self.renderer, ptr_path);
    }

    /// Returns true when the window requests close.
    pub fn shouldClose(self: *CardinalEngine) bool {
        return window.cardinal_window_should_close(self.window);
    }

    /// Initializes core subsystems (memory, ECS systems, modules, async loaders, caches).
    fn initSystems(self: *CardinalEngine) !void {
        try self.scheduler.add(ecs_systems.ScriptSystemDesc);
        try self.scheduler.add(ecs_systems.PhysicsSystemDesc);
        try self.scheduler.add(ecs_systems.TransformSystemDesc);
        try self.scheduler.add(ecs_systems.RenderSystemDesc);

        eng_log.info("Initializing memory management system...", .{});
        memory.cardinal_memory_init(self.config.memory_size);
        self.memory_initialized = true;
        eng_log.info("Memory management system initialized", .{});

        // TODO: Make frame allocator size configurable via CardinalEngineConfig.
        const frame_mem_size = 16 * 1024 * 1024;
        self.frame_memory = try self.allocator.alloc(u8, frame_mem_size);
        self.frame_allocator = stack_allocator.StackAllocator.init(self.frame_memory);
        eng_log.info("Frame allocator initialized with {d}MB", .{frame_mem_size / 1024 / 1024});

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

        const texture_load_fn: *const fn (?[*]const u8, ?*anyopaque) callconv(.c) ?*ref_counting.CardinalRefCountedResource = @ptrCast(&texture_loader.texture_load_with_ref_counting);
        async_loader.cardinal_async_register_texture_loader(texture_load_fn);
        async_loader.cardinal_async_register_scene_loader(loader_mod.cardinal_scene_load);

        self.async_loader_initialized = true;
        eng_log.info("Async loader system initialized successfully", .{});

        _ = texture_loader.texture_cache_initialize(self.config.cache_size);
        _ = mesh_loader.mesh_cache_initialize(self.config.cache_size);
        self.caches_initialized = true;

        eng_log.info("Multi-threaded asset caches initialized successfully", .{});
    }

    /// Creates the window and initializes the renderer.
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
            window.cardinal_window_destroy(self.window);
            self.window = null;
            self.window_initialized = false;
            return error.RendererCreateFailed;
        }
        self.renderer_initialized = true;

        vulkan_renderer.cardinal_renderer_set_frame_allocator(&self.renderer, &self.frame_allocator);
    }
};

/// Module init/shutdown callbacks used by the module manager.
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
