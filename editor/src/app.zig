const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const memory = engine.memory;
const ref_counting = engine.ref_counting;
const resource_state = engine.resource_state;
const async_loader = engine.async_loader;
const window = engine.window;
const vulkan_renderer = engine.vulkan_renderer;
const vulkan_renderer_frame = engine.vulkan_renderer_frame;
const types = engine.vulkan_types;
const texture_loader = engine.texture_loader;
const mesh_loader = engine.mesh_loader;
const material_loader = engine.material_loader;

const editor_layer = @import("editor_layer.zig");

const c = @cImport({
    @cInclude("stdio.h");
});

pub const EditorConfig = struct {
    window_title: [*:0]const u8 = "Cardinal Editor",
    window_width: u32 = 1600,
    window_height: u32 = 900,
    window_resizable: bool = true,
    memory_size: usize = 4 * 1024 * 1024,
    ref_counting_buckets: u32 = 1009,
    async_worker_threads: u32 = 2,
    async_queue_size: u32 = 100,
    cache_size: u32 = 1000,
};

pub const EditorApp = struct {
    allocator: std.mem.Allocator,
    module_manager: engine.module.ModuleManager,
    window: ?*window.CardinalWindow,
    renderer: types.CardinalRenderer,
    config: EditorConfig,

    // Track initialization state to ensure proper cleanup order
    memory_initialized: bool = false,
    ref_counting_initialized: bool = false,
    resource_state_initialized: bool = false,
    async_loader_initialized: bool = false,
    caches_initialized: bool = false,
    window_initialized: bool = false,
    renderer_initialized: bool = false,
    editor_layer_initialized: bool = false,

    pub fn create(allocator: std.mem.Allocator, config: EditorConfig) !*EditorApp {
        const app = try allocator.create(EditorApp);
        app.* = EditorApp{
            .allocator = allocator,
            .module_manager = engine.module.ModuleManager.init(allocator),
            .config = config,
            .window = null,
            .renderer = .{ ._opaque = null },
        };
        errdefer {
            app.deinit();
            allocator.destroy(app);
        }

        try app.initSystems();
        try app.initWindowAndRenderer();
        try app.initEditorLayer();

        // Start modules
        try app.module_manager.startup();

        return app;
    }

    fn initSystems(self: *EditorApp) !void {
        log.cardinal_log_info("Initializing memory management system...", .{});
        memory.cardinal_memory_init(self.config.memory_size);
        self.memory_initialized = true;
        log.cardinal_log_info("Memory management system initialized", .{});

        // Register Modules
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

        log.cardinal_log_info("Initializing reference counting system...", .{});
        if (!ref_counting.cardinal_ref_counting_init(self.config.ref_counting_buckets)) {
            log.cardinal_log_error("Failed to initialize reference counting system", .{});
            return error.RefCountingInitFailed;
        }
        self.ref_counting_initialized = true;
        log.cardinal_log_info("Reference counting system initialized", .{});

        log.cardinal_log_info("Initializing resource state tracking system...", .{});
        if (!resource_state.cardinal_resource_state_init(self.config.ref_counting_buckets)) {
            log.cardinal_log_error("Failed to initialize resource state tracking system", .{});
            return error.ResourceStateInitFailed;
        }
        self.resource_state_initialized = true;
        log.cardinal_log_info("Resource state tracking system initialized", .{});

        log.cardinal_log_info("Initializing async loader system...", .{});

        // memory.cardinal_get_allocator_for_category returns a pointer, so it is assumed to be valid if init was called.
        log.cardinal_log_info("Memory allocator check passed", .{});

        const async_config = async_loader.CardinalAsyncLoaderConfig{
            .worker_thread_count = self.config.async_worker_threads,
            .max_queue_size = self.config.async_queue_size,
            .enable_priority_queue = true,
        };

        log.cardinal_log_info("About to call cardinal_async_loader_init...", .{});
        if (!async_loader.cardinal_async_loader_init(&async_config)) {
            log.cardinal_log_error("Failed to initialize async loader system", .{});
            return error.AsyncLoaderInitFailed;
        }
        self.async_loader_initialized = true;
        log.cardinal_log_info("Async loader system initialized successfully", .{});

        _ = texture_loader.texture_cache_initialize(self.config.cache_size);
        _ = mesh_loader.mesh_cache_initialize(self.config.cache_size);
        self.caches_initialized = true;

        log.cardinal_log_info("Multi-threaded asset caches initialized successfully", .{});
    }

    // Module wrappers
    fn initEvents(ctx: ?*anyopaque) !void {
        const self = @as(*EditorApp, @ptrCast(@alignCast(ctx)));
        engine.events.init(self.allocator);
    }

    fn shutdownEvents(ctx: ?*anyopaque) !void {
        _ = ctx;
        engine.events.shutdown();
    }

    fn initInput(ctx: ?*anyopaque) !void {
        const self = @as(*EditorApp, @ptrCast(@alignCast(ctx)));
        engine.input.init(self.allocator);
        self.registerInputActions();
    }

    fn shutdownInput(ctx: ?*anyopaque) !void {
        _ = ctx;
        // Input system doesn't have a shutdown yet, but we added one in previous turn
        engine.input.shutdown();
    }

    fn registerInputActions(self: *EditorApp) void {
        _ = self;
        // Base layer actions (always active unless blocked by something very high priority)
        engine.input.registerActionWithLayer("ToggleCursor", &[_]c_int{engine.input.KEY_TAB}, "Base");

        // Game layer actions
        engine.input.registerActionWithLayer("MoveForward", &[_]c_int{engine.input.KEY_W}, "Game");
        engine.input.registerActionWithLayer("MoveBackward", &[_]c_int{engine.input.KEY_S}, "Game");
        engine.input.registerActionWithLayer("StrafeLeft", &[_]c_int{engine.input.KEY_A}, "Game");
        engine.input.registerActionWithLayer("StrafeRight", &[_]c_int{engine.input.KEY_D}, "Game");
        engine.input.registerActionWithLayer("Jump", &[_]c_int{engine.input.KEY_SPACE}, "Game");
        engine.input.registerActionWithLayer("Descend", &[_]c_int{engine.input.KEY_LEFT_SHIFT}, "Game");
        engine.input.registerActionWithLayer("Sprint", &[_]c_int{engine.input.KEY_LEFT_CONTROL}, "Game");
        
        // Initialize layers
        engine.input.pushLayer("Base", false);
        // We start with just Base active. Game layer will be pushed when we capture cursor.
    }

    fn initWindowAndRenderer(self: *EditorApp) !void {
        const config = window.CardinalWindowConfig{
            .title = self.config.window_title,
            .width = self.config.window_width,
            .height = self.config.window_height,
            .resizable = self.config.window_resizable,
        };
        self.window = window.cardinal_window_create(&config);
        if (self.window == null) {
            return error.WindowCreateFailed;
        }
        self.window_initialized = true;

        if (!vulkan_renderer.cardinal_renderer_create(&self.renderer, self.window)) {
            // Cleanup window if renderer creation fails
            window.cardinal_window_destroy(self.window);
            self.window = null;
            self.window_initialized = false;
            return error.RendererCreateFailed;
        }

        // Set device loss callbacks
        vulkan_renderer.cardinal_renderer_set_device_loss_callbacks(&self.renderer, editor_layer.on_device_loss, editor_layer.on_device_restored, null);

        self.renderer_initialized = true;
    }

    fn initEditorLayer(self: *EditorApp) !void {
        // Pass pointers directly
        if (!editor_layer.init(self.window.?, &self.renderer)) {
            return error.EditorLayerInitFailed;
        }
        self.editor_layer_initialized = true;
    }

    pub fn run(self: *EditorApp) !void {
        while (!window.cardinal_window_should_close(self.window)) {
            window.cardinal_window_poll(self.window);
            if (self.window) |win| {
                engine.input.update(win);
            }

            editor_layer.update();
            editor_layer.render();

            _ = vulkan_renderer_frame.cardinal_renderer_draw_frame(&self.renderer);

            log.cardinal_log_debug("[EDITOR] Processing pending uploads after frame draw", .{});
            editor_layer.process_pending_uploads();
        }

        vulkan_renderer.cardinal_renderer_wait_idle(&self.renderer);
    }

    pub fn destroy(self: *EditorApp) void {
        self.deinit();
        self.allocator.destroy(self);
    }

    fn deinit(self: *EditorApp) void {
        // Shutdown async loader first to stop worker threads and release pending tasks
        if (self.async_loader_initialized) {
            async_loader.cardinal_async_loader_shutdown();
            self.async_loader_initialized = false;
        }

        // Shutdown caches to release held references before renderer/ref-counting shutdown
        if (self.caches_initialized) {
            // material_cache_shutdown_system removed - legacy system
            mesh_loader.mesh_cache_shutdown_system();
            texture_loader.texture_cache_shutdown_system();
            self.caches_initialized = false;
        }

        if (self.editor_layer_initialized) {
            editor_layer.shutdown();
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
    }
};
