//! Window creation and input callback routing.
//!
//! Wraps GLFW window handles behind a C-ABI `CardinalWindow` and allows clients to register
//! callbacks for resize, key, mouse button, and cursor movement.
const std = @import("std");
const log = @import("log.zig");
const builtin = @import("builtin");
const platform = @import("platform.zig");

const win_log = log.ScopedLogger("WINDOW");

const c = platform.c;

var g_glfw_lock = std.Thread.Mutex{};
var g_glfw_initialized = false;
var g_glfw_window_count: u32 = 0;

fn glfw_acquire() bool {
    g_glfw_lock.lock();
    defer g_glfw_lock.unlock();

    if (!g_glfw_initialized) {
        if (c.glfwInit() == c.GLFW_FALSE) {
            win_log.err("GLFW init failed", .{});
            return false;
        }
        _ = c.glfwSetErrorCallback(glfw_error_callback);
        g_glfw_initialized = true;
    }

    g_glfw_window_count += 1;
    return true;
}

fn glfw_release() void {
    g_glfw_lock.lock();
    defer g_glfw_lock.unlock();

    if (g_glfw_window_count > 0) {
        g_glfw_window_count -= 1;
    }

    if (g_glfw_window_count == 0 and g_glfw_initialized) {
        c.glfwTerminate();
        g_glfw_initialized = false;
    }
}

/// Configuration used by `cardinal_window_create`.
pub const CardinalWindowConfig = extern struct {
    title: [*:0]const u8,
    width: u32,
    height: u32,
    resizable: bool,
};

/// Opaque window wrapper around a GLFW window handle plus per-window callbacks/state.
pub const CardinalWindow = struct {
    handle: ?*c.GLFWwindow,
    width: u32,
    height: u32,
    should_close: bool,
    mutex: std.Thread.Mutex,

    resize_pending: bool,
    new_width: u32,
    new_height: u32,
    is_minimized: bool,
    was_minimized: bool,

    resize_callback: ?*const fn (u32, u32, ?*anyopaque) callconv(.c) void,
    resize_user_data: ?*anyopaque,

    key_callback: ?*const fn (c_int, c_int, c_int, c_int, ?*anyopaque) callconv(.c) void,
    key_user_data: ?*anyopaque,

    mouse_button_callback: ?*const fn (c_int, c_int, c_int, ?*anyopaque) callconv(.c) void,
    mouse_button_user_data: ?*anyopaque,

    cursor_pos_callback: ?*const fn (f64, f64, ?*anyopaque) callconv(.c) void,
    cursor_pos_user_data: ?*anyopaque,

    content_scale_x: f32,
    content_scale_y: f32,
};

/// Updates content scale state when the OS DPI scale changes.
fn window_content_scale_callback(window: ?*c.GLFWwindow, xscale: f32, yscale: f32) callconv(.c) void {
    const win = @as(?*CardinalWindow, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));
    if (win) |w| {
        w.content_scale_x = xscale;
        w.content_scale_y = yscale;
    }
}

/// Forwards GLFW key events to the registered callback.
fn key_callback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    const win = @as(?*CardinalWindow, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));
    if (win) |w| {
        if (w.key_callback) |cb| {
            cb(key, scancode, action, mods, w.key_user_data);
        }
    }
}

/// Forwards GLFW mouse button events to the registered callback.
fn mouse_button_callback(window: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    const win = @as(?*CardinalWindow, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));
    if (win) |w| {
        if (w.mouse_button_callback) |cb| {
            cb(button, action, mods, w.mouse_button_user_data);
        }
    }
}

/// Forwards GLFW cursor position events to the registered callback.
fn cursor_pos_callback(window: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    const win = @as(?*CardinalWindow, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));
    if (win) |w| {
        if (w.cursor_pos_callback) |cb| {
            cb(xpos, ypos, w.cursor_pos_user_data);
        }
    }
}

/// GLFW error callback.
fn glfw_error_callback(error_code: c_int, description: [*c]const u8) callconv(.c) void {
    win_log.err("GLFW error {d}: {s}", .{ error_code, if (description != null) std.mem.span(description) else "(null)" });
}

/// Forwards framebuffer resize events and marks `resize_pending`.
fn framebuffer_resize_callback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    const win = @as(?*CardinalWindow, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));
    if (win) |w| {
        if (width > 0 and height > 0) {
            w.resize_pending = true;
            w.new_width = @intCast(width);
            w.new_height = @intCast(height);
            w.width = @intCast(width);
            w.height = @intCast(height);
            if (w.resize_callback) |cb| {
                cb(w.new_width, w.new_height, w.resize_user_data);
            }
        }
    }
}

/// Tracks minimize/restore and triggers a resize callback on restore.
fn window_iconify_callback(window: ?*c.GLFWwindow, iconified: c_int) callconv(.c) void {
    const win = @as(?*CardinalWindow, @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window))));
    if (win) |w| {
        w.was_minimized = w.is_minimized;
        w.is_minimized = (iconified == c.GLFW_TRUE);

        if (w.was_minimized and !w.is_minimized) {
            var width: c_int = 0;
            var height: c_int = 0;
            c.glfwGetFramebufferSize(window, &width, &height);
            if (width > 0 and height > 0) {
                w.resize_pending = true;
                w.new_width = @intCast(width);
                w.new_height = @intCast(height);
                w.width = @intCast(width);
                w.height = @intCast(height);
                if (w.resize_callback) |cb| {
                    cb(w.new_width, w.new_height, w.resize_user_data);
                }
            }
        }
    }
}

/// Creates a window and initializes GLFW for Vulkan usage.
pub export fn cardinal_window_create(config: *const CardinalWindowConfig) callconv(.c) ?*CardinalWindow {
    win_log.info("cardinal_window_create: begin", .{});

    if (!glfw_acquire()) {
        return null;
    }

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, if (config.resizable) c.GLFW_TRUE else c.GLFW_FALSE);

    const handle = c.glfwCreateWindow(@intCast(config.width), @intCast(config.height), config.title, null, null);
    if (handle == null) {
        win_log.err("GLFW create window failed", .{});
        glfw_release();
        return null;
    }

    const win_ptr = c.malloc(@sizeOf(CardinalWindow));
    if (win_ptr == null) {
        c.glfwDestroyWindow(handle);
        glfw_release();
        return null;
    }
    const win = @as(*CardinalWindow, @ptrCast(@alignCast(win_ptr)));
    win.* = std.mem.zeroes(CardinalWindow);

    win.handle = handle;
    win.width = config.width;
    win.height = config.height;
    win.should_close = false;

    var x_scale: f32 = 1.0;
    var y_scale: f32 = 1.0;
    c.glfwGetWindowContentScale(handle, &x_scale, &y_scale);
    win.content_scale_x = x_scale;
    win.content_scale_y = y_scale;

    c.glfwSetWindowUserPointer(handle, win);
    _ = c.glfwSetFramebufferSizeCallback(handle, framebuffer_resize_callback);
    _ = c.glfwSetWindowContentScaleCallback(handle, window_content_scale_callback);
    _ = c.glfwSetWindowIconifyCallback(handle, window_iconify_callback);
    _ = c.glfwSetKeyCallback(handle, key_callback);
    _ = c.glfwSetMouseButtonCallback(handle, mouse_button_callback);
    _ = c.glfwSetCursorPosCallback(handle, cursor_pos_callback);

    win.mutex = .{};

    win_log.info("cardinal_window_create: success", .{});
    return win;
}

/// Polls the window event loop and updates `should_close`.
pub export fn cardinal_window_poll(window: ?*CardinalWindow) callconv(.c) void {
    if (window) |win| {
        win.mutex.lock();
        c.glfwPollEvents();
        win.should_close = (c.glfwWindowShouldClose(win.handle) != 0);

        win.mutex.unlock();
    }
}

/// Returns true if the window has requested close.
pub export fn cardinal_window_should_close(window: ?*const CardinalWindow) callconv(.c) bool {
    if (window) |win| {
        return win.should_close;
    }
    return true;
}

/// Destroys the window.
pub export fn cardinal_window_destroy(window: ?*CardinalWindow) callconv(.c) void {
    if (window) |win| {
        win.mutex.lock();

        if (win.handle) |h| {
            c.glfwDestroyWindow(h);
            win.handle = null;
        }

        win.mutex.unlock();

        c.free(win);
        glfw_release();
    }
}

/// Returns the underlying platform native window handle (if available).
pub export fn cardinal_window_get_native_handle(window: ?*const CardinalWindow) callconv(.c) ?*anyopaque {
    if (window) |win| {
        if (win.handle) |h| {
            if (builtin.os.tag == .windows) {
                return c.glfwGetWin32Window(h);
            }
        }
    }
    return null;
}

pub export fn cardinal_window_is_minimized(window: ?*const CardinalWindow) callconv(.c) bool {
    if (window) |win| {
        return win.is_minimized;
    }
    return false;
}

pub export fn cardinal_window_set_key_callback(window: ?*CardinalWindow, callback: ?*const fn (c_int, c_int, c_int, c_int, ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) callconv(.c) void {
    if (window) |win| {
        win.key_callback = callback;
        win.key_user_data = user_data;
    }
}

pub export fn cardinal_window_set_mouse_button_callback(window: ?*CardinalWindow, callback: ?*const fn (c_int, c_int, c_int, ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) callconv(.c) void {
    if (window) |win| {
        win.mouse_button_callback = callback;
        win.mouse_button_user_data = user_data;
    }
}

pub export fn cardinal_window_set_cursor_pos_callback(window: ?*CardinalWindow, callback: ?*const fn (f64, f64, ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) callconv(.c) void {
    if (window) |win| {
        win.cursor_pos_callback = callback;
        win.cursor_pos_user_data = user_data;
    }
}

pub export fn cardinal_window_get_content_scale(window: ?*const CardinalWindow, x_scale: ?*f32, y_scale: ?*f32) callconv(.c) void {
    if (window) |win| {
        if (x_scale) |x| x.* = win.content_scale_x;
        if (y_scale) |y| y.* = win.content_scale_y;
    } else {
        if (x_scale) |x| x.* = 1.0;
        if (y_scale) |y| y.* = 1.0;
    }
}

// Additional window functions for Project Manager
pub export fn cardinal_window_set_size(window: ?*CardinalWindow, width: u32, height: u32) callconv(.c) void {
    if (window) |win| {
        if (win.handle) |h| {
            c.glfwSetWindowSize(h, @intCast(width), @intCast(height));
            win.width = width;
            win.height = height;
        }
    }
}

pub export fn cardinal_window_set_title(window: ?*CardinalWindow, title: [*c]const u8) callconv(.c) void {
    if (window) |win| {
        if (win.handle) |h| {
            c.glfwSetWindowTitle(h, title);
        }
    }
}

pub export fn cardinal_window_maximize(window: ?*CardinalWindow) callconv(.c) void {
    if (window) |win| {
        if (win.handle) |h| {
            c.glfwMaximizeWindow(h);
        }
    }
}

pub export fn cardinal_window_center(window: ?*CardinalWindow) callconv(.c) void {
    if (window) |win| {
        if (win.handle) |h| {
            const monitor = c.glfwGetPrimaryMonitor();
            if (monitor) |m| {
                const mode = c.glfwGetVideoMode(m);
                if (mode) |vmode| {
                    var width: c_int = 0;
                    var height: c_int = 0;
                    c.glfwGetWindowSize(h, &width, &height);

                    const x = @divTrunc(vmode.*.width - width, 2);
                    const y = @divTrunc(vmode.*.height - height, 2);
                    c.glfwSetWindowPos(h, x, y);
                }
            }
        }
    }
}

pub export fn cardinal_window_restore(window: ?*CardinalWindow) callconv(.c) void {
    if (window) |win| {
        if (win.handle) |h| {
            c.glfwRestoreWindow(h);
        }
    }
}

pub export fn cardinal_window_get_glfw_handle(window: ?*const CardinalWindow) callconv(.c) ?*anyopaque {
    if (window) |win| {
        return win.handle;
    }
    return null;
}
