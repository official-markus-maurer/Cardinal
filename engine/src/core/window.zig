const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");

    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
        @cDefine("GLFW_EXPOSE_NATIVE_WIN32", {});
        @cInclude("GLFW/glfw3native.h");
    } else {
        @cInclude("pthread.h");
    }
});

pub const CardinalWindowConfig = extern struct {
    title: [*:0]const u8,
    width: u32,
    height: u32,
    resizable: bool,
};

pub const CardinalWindow = extern struct {
    handle: ?*c.GLFWwindow,
    width: u32,
    height: u32,
    should_close: bool,
    // Mutex
    mutex: if (builtin.os.tag == .windows) c.CRITICAL_SECTION else c.pthread_mutex_t,

    resize_pending: bool,
    new_width: u32,
    new_height: u32,
    is_minimized: bool,
    was_minimized: bool,

    resize_callback: ?*const fn (u32, u32, ?*anyopaque) callconv(.c) void,
    resize_user_data: ?*anyopaque,
};

// Callbacks
fn glfw_error_callback(error_code: c_int, description: [*c]const u8) callconv(.c) void {
    std.log.err("GLFW error {d}: {s}", .{ error_code, if (description != null) std.mem.span(description) else "(null)" });
}

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

// Exported functions
pub export fn cardinal_window_create(config: *const CardinalWindowConfig) callconv(.c) ?*CardinalWindow {
    std.log.info("cardinal_window_create: begin", .{});

    if (c.glfwInit() == c.GLFW_FALSE) {
        std.log.err("GLFW init failed", .{});
        return null;
    }

    _ = c.glfwSetErrorCallback(glfw_error_callback);

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, if (config.resizable) c.GLFW_TRUE else c.GLFW_FALSE);

    const handle = c.glfwCreateWindow(@intCast(config.width), @intCast(config.height), config.title, null, null);
    if (handle == null) {
        std.log.err("GLFW create window failed", .{});
        c.glfwTerminate();
        return null;
    }

    const win_ptr = c.malloc(@sizeOf(CardinalWindow));
    if (win_ptr == null) {
        c.glfwDestroyWindow(handle);
        c.glfwTerminate();
        return null;
    }
    const win = @as(*CardinalWindow, @ptrCast(@alignCast(win_ptr)));
    // Initialize struct to zero
    win.* = std.mem.zeroes(CardinalWindow);

    win.handle = handle;
    win.width = config.width;
    win.height = config.height;
    win.should_close = false;

    c.glfwSetWindowUserPointer(handle, win);
    _ = c.glfwSetFramebufferSizeCallback(handle, framebuffer_resize_callback);
    _ = c.glfwSetWindowIconifyCallback(handle, window_iconify_callback);

    if (builtin.os.tag == .windows) {
        c.InitializeCriticalSection(&win.mutex);
    } else {
        if (c.pthread_mutex_init(&win.mutex, null) != 0) {
            std.log.err("Failed to initialize window mutex", .{});
            c.glfwDestroyWindow(handle);
            c.free(win);
            return null;
        }
    }

    std.log.info("cardinal_window_create: success", .{});
    return win;
}

pub export fn cardinal_window_poll(window: ?*CardinalWindow) callconv(.c) void {
    if (window) |win| {
        if (builtin.os.tag == .windows) {
            c.EnterCriticalSection(&win.mutex);
        } else {
            _ = c.pthread_mutex_lock(&win.mutex);
        }

        c.glfwPollEvents();
        win.should_close = (c.glfwWindowShouldClose(win.handle) != 0);

        if (builtin.os.tag == .windows) {
            c.LeaveCriticalSection(&win.mutex);
        } else {
            _ = c.pthread_mutex_unlock(&win.mutex);
        }
    }
}

pub export fn cardinal_window_should_close(window: ?*const CardinalWindow) callconv(.c) bool {
    if (window) |win| {
        return win.should_close;
    }
    return true;
}

pub export fn cardinal_window_destroy(window: ?*CardinalWindow) callconv(.c) void {
    if (window) |win| {
        if (builtin.os.tag == .windows) {
            c.EnterCriticalSection(&win.mutex);
        } else {
            _ = c.pthread_mutex_lock(&win.mutex);
        }

        if (win.handle) |h| {
            c.glfwDestroyWindow(h);
            win.handle = null;
        }
        c.glfwTerminate();

        if (builtin.os.tag == .windows) {
            c.LeaveCriticalSection(&win.mutex);
            c.DeleteCriticalSection(&win.mutex);
        } else {
            _ = c.pthread_mutex_unlock(&win.mutex);
            _ = c.pthread_mutex_destroy(&win.mutex);
        }

        c.free(win);
    }
}

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
