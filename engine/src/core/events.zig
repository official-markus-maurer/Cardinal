const std = @import("std");
const log = @import("log.zig");

pub const EventId = u64;

pub const Event = struct {
    id: EventId,
    data: ?*const anyopaque,
};

pub const EventHandler = *const fn (event: Event, user_data: ?*anyopaque) void;

const Listener = struct {
    callback: EventHandler,
    user_data: ?*anyopaque,
};

var g_allocator: std.mem.Allocator = undefined;
var g_listeners: std.AutoHashMapUnmanaged(EventId, std.ArrayListUnmanaged(Listener)) = .{};
var g_mutex: std.Thread.Mutex = .{};

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    g_listeners = .{};
}

pub fn shutdown() void {
    g_mutex.lock();
    defer g_mutex.unlock();

    var it = g_listeners.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(g_allocator);
    }
    g_listeners.deinit(g_allocator);
}

pub fn makeEventId(name: []const u8) EventId {
    return std.hash.Wyhash.hash(0, name);
}

pub fn subscribe(event_id: EventId, callback: EventHandler, user_data: ?*anyopaque) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    var list = g_listeners.getOrPut(g_allocator, event_id) catch return;
    if (!list.found_existing) {
        list.value_ptr.* = .{};
    }
    list.value_ptr.append(g_allocator, .{ .callback = callback, .user_data = user_data }) catch return;
}

pub fn unsubscribe(event_id: EventId, callback: EventHandler) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    if (g_listeners.getPtr(event_id)) |list| {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].callback == callback) {
                _ = list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

pub fn publish(event_id: EventId, data: ?*const anyopaque) void {
    // Use a stack buffer for small listener counts to avoid allocation
    const MAX_STACK_LISTENERS = 64;
    var stack_buffer: [MAX_STACK_LISTENERS]Listener = undefined;

    g_mutex.lock();

    const list_ptr = g_listeners.getPtr(event_id);
    if (list_ptr == null) {
        g_mutex.unlock();
        return;
    }

    const list = list_ptr.?;
    const count = list.items.len;

    if (count <= MAX_STACK_LISTENERS) {
        @memcpy(stack_buffer[0..count], list.items);
        g_mutex.unlock();

        const event = Event{ .id = event_id, .data = data };
        for (stack_buffer[0..count]) |listener| {
            listener.callback(event, listener.user_data);
        }
    } else {
        // Fallback to heap allocation for large listener counts
        const listeners_copy = list.clone(g_allocator) catch {
            g_mutex.unlock();
            log.cardinal_log_error("Failed to allocate listener copy for event {}", .{event_id});
            return;
        };
        g_mutex.unlock();
        defer listeners_copy.deinit(g_allocator);

        const event = Event{ .id = event_id, .data = data };
        for (listeners_copy.items) |listener| {
            listener.callback(event, listener.user_data);
        }
    }
}
