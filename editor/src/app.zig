const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const vulkan_renderer = engine.vulkan_renderer;
const vulkan_renderer_frame = engine.vulkan_renderer_frame;
const editor_layer = @import("editor_layer.zig");

const app_log = log.ScopedLogger("APP");

const CardinalEngine = engine.engine.CardinalEngine;
pub const EditorConfig = engine.engine.CardinalEngineConfig;

pub const EditorApp = struct {
    allocator: std.mem.Allocator,
    engine: *CardinalEngine,
    editor_layer_initialized: bool = false,

    pub fn create(allocator: std.mem.Allocator, config: EditorConfig) !*EditorApp {
        const app = try allocator.create(EditorApp);
        app.allocator = allocator;
        app.editor_layer_initialized = false;

        // Create engine
        app.engine = try CardinalEngine.create(allocator, config);

        errdefer {
            allocator.destroy(app);
        }

        // Register input actions
        app.registerInputActions();

        // Initialize editor layer
        if (!editor_layer.init(app.engine.window.?, &app.engine.renderer, &app.engine.registry)) {
            app.engine.deinit();
            allocator.destroy(app.engine);
            allocator.destroy(app);
            return error.EditorLayerInitFailed;
        }
        app.editor_layer_initialized = true;

        app_log.info("Setting device loss callbacks...", .{});
        // Set device loss callbacks
        vulkan_renderer.cardinal_renderer_set_device_loss_callbacks(&app.engine.renderer, editor_layer.on_device_loss, editor_layer.on_device_restored, null);
        app_log.info("Device loss callbacks set.", .{});

        return app;
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
        // Base layer is pushed in engine init, but we can ensure it here if we want.
        // engine.input.pushLayer("Base", false);
    }

    pub fn run(self: *EditorApp) !void {
        while (!self.engine.shouldClose()) {
            try self.engine.update();

            editor_layer.update();
            editor_layer.render();

            _ = vulkan_renderer_frame.cardinal_renderer_draw_frame(&self.engine.renderer);
            engine.tracy.frameMark();

            log.cardinal_log_debug("[EDITOR] Processing pending uploads after frame draw", .{});
            editor_layer.process_pending_uploads();
        }

        vulkan_renderer.cardinal_renderer_wait_idle(&self.engine.renderer);
    }

    pub fn destroy(self: *EditorApp) void {
        if (self.editor_layer_initialized) {
            editor_layer.shutdown();
        }

        self.engine.deinit();
        self.allocator.destroy(self.engine);
        self.allocator.destroy(self);
    }
};
