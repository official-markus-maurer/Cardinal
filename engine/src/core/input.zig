const std = @import("std");
const window = @import("window.zig");
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
});

pub const InputState = struct {
    mouse_captured: bool = false,
    first_mouse: bool = true,
    last_x: f64 = 0,
    last_y: f64 = 0,
    mouse_delta_x: f64 = 0,
    mouse_delta_y: f64 = 0,
};

var g_input_state: InputState = .{};

// Action Mapping
pub const ActionId = u64;
pub const LayerId = u64;

pub const ActionBinding = struct {
    keys: std.ArrayListUnmanaged(c_int) = .{},
    mouse_buttons: std.ArrayListUnmanaged(c_int) = .{},
    layer_id: LayerId = 0,
};

pub const InputLayer = struct {
    id: LayerId,
    blocking: bool,
};

var g_action_map: std.AutoHashMapUnmanaged(ActionId, ActionBinding) = .{};
var g_layer_stack: std.ArrayListUnmanaged(InputLayer) = .{};
var g_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    g_input_state = .{};
    g_allocator = allocator;
    g_action_map = .{};
    g_layer_stack = .{};
    
    // Default "Global" layer
    pushLayer("Global", false);
}

pub fn shutdown() void {
    var it = g_action_map.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.keys.deinit(g_allocator);
        entry.value_ptr.mouse_buttons.deinit(g_allocator);
    }
    g_action_map.deinit(g_allocator);
    g_layer_stack.deinit(g_allocator);
}

pub fn pushLayer(name: []const u8, blocking: bool) void {
    const id = std.hash.Wyhash.hash(0, name);
    // Check if layer already exists in stack? 
    // Usually we want to allow pushing same layer type multiple times (like nested menus),
    // but typically we push a unique instance.
    // For simplicity, we just push.
    g_layer_stack.append(g_allocator, .{ .id = id, .blocking = blocking }) catch return;
}

pub fn popLayer() void {
    if (g_layer_stack.items.len > 0) {
        _ = g_layer_stack.pop();
    }
}

pub fn registerAction(name: []const u8, default_keys: []const c_int) void {
    registerActionWithLayer(name, default_keys, "Global");
}

pub fn registerActionWithLayer(name: []const u8, default_keys: []const c_int, layer_name: []const u8) void {
    const id = std.hash.Wyhash.hash(0, name);
    const layer_id = std.hash.Wyhash.hash(0, layer_name);

    var result = g_action_map.getOrPut(g_allocator, id) catch return;
    if (!result.found_existing) {
        result.value_ptr.* = .{ .layer_id = layer_id };
    } else {
        result.value_ptr.layer_id = layer_id;
    }
    
    for (default_keys) |key| {
        result.value_ptr.keys.append(g_allocator, key) catch return;
    }
}

pub fn registerActionMouseButton(name: []const u8, button: c_int) void {
    registerActionMouseButtonWithLayer(name, button, "Global");
}

pub fn registerActionMouseButtonWithLayer(name: []const u8, button: c_int, layer_name: []const u8) void {
    const id = std.hash.Wyhash.hash(0, name);
    const layer_id = std.hash.Wyhash.hash(0, layer_name);

    var result = g_action_map.getOrPut(g_allocator, id) catch return;
    if (!result.found_existing) {
        result.value_ptr.* = .{ .layer_id = layer_id };
    } else {
        result.value_ptr.layer_id = layer_id;
    }
    result.value_ptr.mouse_buttons.append(g_allocator, button) catch return;
}

pub fn isActionPressed(win: *const window.CardinalWindow, name: []const u8) bool {
    const id = std.hash.Wyhash.hash(0, name);
    const binding = g_action_map.get(id) orelse return false;

    // Check if layer is active
    if (!isLayerActive(binding.layer_id)) return false;

    for (binding.keys.items) |key| {
        if (isKeyPressed(win, key)) return true;
    }
    for (binding.mouse_buttons.items) |btn| {
        if (isMouseButtonPressed(win, btn)) return true;
    }
    return false;
}

fn isLayerActive(target_layer_id: LayerId) bool {
    // Iterate from top to bottom
    var i: usize = g_layer_stack.items.len;
    while (i > 0) {
        i -= 1;
        const layer = g_layer_stack.items[i];
        if (layer.id == target_layer_id) return true;
        if (layer.blocking) return false;
    }
    return false; // Layer not found in stack
}

pub fn isKeyPressed(win: *const window.CardinalWindow, key: c_int) bool {
    if (win.handle == null) return false;
    return c.glfwGetKey(@as(*c.GLFWwindow, @ptrCast(win.handle)), key) == c.GLFW_PRESS;
}

pub fn setCursorMode(win: *const window.CardinalWindow, captured: bool) void {
    if (win.handle == null) return;
    const mode = if (captured) c.GLFW_CURSOR_DISABLED else c.GLFW_CURSOR_NORMAL;
    c.glfwSetInputMode(@as(*c.GLFWwindow, @ptrCast(win.handle)), c.GLFW_CURSOR, mode);
    g_input_state.mouse_captured = captured;
    if (captured) {
        g_input_state.first_mouse = true;
    }
}

pub fn getCursorPos(win: *const window.CardinalWindow) struct { x: f64, y: f64 } {
    var x: f64 = 0;
    var y: f64 = 0;
    if (win.handle) |h| {
        c.glfwGetCursorPos(@as(*c.GLFWwindow, @ptrCast(h)), &x, &y);
    }
    return .{ .x = x, .y = y };
}

pub fn update(win: *const window.CardinalWindow) void {
    if (win.handle == null) return;

    var x: f64 = 0;
    var y: f64 = 0;
    c.glfwGetCursorPos(@as(*c.GLFWwindow, @ptrCast(win.handle)), &x, &y);

    if (g_input_state.first_mouse) {
        g_input_state.last_x = x;
        g_input_state.last_y = y;
        g_input_state.first_mouse = false;
    }

    g_input_state.mouse_delta_x = x - g_input_state.last_x;
    g_input_state.mouse_delta_y = g_input_state.last_y - y; // Reversed for camera control
    g_input_state.last_x = x;
    g_input_state.last_y = y;
}

pub fn getMouseDelta() struct { x: f64, y: f64 } {
    return .{ .x = g_input_state.mouse_delta_x, .y = g_input_state.mouse_delta_y };
}

pub fn isMouseButtonPressed(win: *const window.CardinalWindow, button: c_int) bool {
    if (win.handle == null) return false;
    return c.glfwGetMouseButton(@as(*c.GLFWwindow, @ptrCast(win.handle)), button) == c.GLFW_PRESS;
}

// Re-export common keys for convenience
pub const KEY_TAB = c.GLFW_KEY_TAB;
pub const KEY_ESCAPE = c.GLFW_KEY_ESCAPE;
pub const KEY_W = c.GLFW_KEY_W;
pub const KEY_A = c.GLFW_KEY_A;
pub const KEY_S = c.GLFW_KEY_S;
pub const KEY_D = c.GLFW_KEY_D;
pub const KEY_SPACE = c.GLFW_KEY_SPACE;
pub const KEY_LEFT_SHIFT = c.GLFW_KEY_LEFT_SHIFT;
pub const KEY_LEFT_CONTROL = c.GLFW_KEY_LEFT_CONTROL;
pub const KEY_KP_0 = c.GLFW_KEY_KP_0;
pub const MOUSE_BUTTON_LEFT = c.GLFW_MOUSE_BUTTON_LEFT;
pub const MOUSE_BUTTON_RIGHT = c.GLFW_MOUSE_BUTTON_RIGHT;
