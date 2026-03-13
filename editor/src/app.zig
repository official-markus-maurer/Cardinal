//! Editor application wrapper around the engine runtime.
//!
//! `EditorApp` owns a `CardinalEngine` instance and connects it to editor-specific layers.
const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const vulkan_renderer = engine.vulkan_renderer;
const vulkan_renderer_frame = engine.vulkan_renderer_frame;
const editor_layer = @import("editor_layer.zig");

const app_log = log.ScopedLogger("APP");

const CardinalEngine = engine.engine.CardinalEngine;
/// Editor configuration currently reuses the engine config type.
pub const EditorConfig = engine.engine.CardinalEngineConfig;

/// High-level editor application lifecycle.
pub const EditorApp = struct {
    allocator: std.mem.Allocator,
    engine: *CardinalEngine,
    editor_layer_initialized: bool = false,

    /// Allocates, initializes the engine, and sets up editor layers.
    pub fn create(allocator: std.mem.Allocator, config: EditorConfig) !*EditorApp {
        const app = try allocator.create(EditorApp);
        app.allocator = allocator;
        app.editor_layer_initialized = false;

        app.engine = try CardinalEngine.create(allocator, config);

        if (app.engine.window) |win| {
            engine.window.cardinal_window_set_size(win, 600, 400);
            engine.window.cardinal_window_set_title(win, "Cardinal Project Manager");
            engine.window.cardinal_window_center(win);
        }

        errdefer {
            allocator.destroy(app);
        }

        app.registerInputActions();

        if (!editor_layer.init(app.engine.window.?, &app.engine.renderer, &app.engine.registry)) {
            app.engine.deinit();
            allocator.destroy(app.engine);
            allocator.destroy(app);
            return error.EditorLayerInitFailed;
        }
        app.editor_layer_initialized = true;

        app_log.info("Setting device loss callbacks...", .{});
        vulkan_renderer.cardinal_renderer_set_device_loss_callbacks(&app.engine.renderer, editor_layer.on_device_loss, editor_layer.on_device_restored, null);
        app_log.info("Device loss callbacks set.", .{});

        return app;
    }

    /// Registers global editor input bindings.
    fn registerInputActions(self: *EditorApp) void {
        _ = self;
        engine.input.registerActionWithLayer("ToggleCursor", &[_]c_int{engine.input.KEY_TAB}, "Base");
        engine.input.registerActionWithLayer("CreateMinidump", &[_]c_int{engine.input.KEY_KP_0}, "Base");

        engine.input.registerActionWithLayer("MoveForward", &[_]c_int{engine.input.KEY_W}, "Game");
        engine.input.registerActionWithLayer("MoveBackward", &[_]c_int{engine.input.KEY_S}, "Game");
        engine.input.registerActionWithLayer("StrafeLeft", &[_]c_int{engine.input.KEY_A}, "Game");
        engine.input.registerActionWithLayer("StrafeRight", &[_]c_int{engine.input.KEY_D}, "Game");
        engine.input.registerActionWithLayer("Jump", &[_]c_int{engine.input.KEY_SPACE}, "Game");
        engine.input.registerActionWithLayer("Descend", &[_]c_int{engine.input.KEY_LEFT_SHIFT}, "Game");
        engine.input.registerActionWithLayer("Sprint", &[_]c_int{engine.input.KEY_LEFT_CONTROL}, "Game");
    }

    /// Runs the editor main loop until window close or unrecoverable device loss.
    pub fn run(self: *EditorApp) !void {
        while (!self.engine.shouldClose()) {
            if (editor_layer.has_device_recovery_failed()) {
                app_log.err("Device recovery failed, closing editor", .{});
                break;
            }

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

    /// Shuts down editor layers and destroys the engine and app.
    pub fn destroy(self: *EditorApp) void {
        if (self.editor_layer_initialized) {
            editor_layer.shutdown();
        }
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        self.allocator.destroy(self);
    }
};
