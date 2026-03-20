//! Lightweight event bus.
//!
//! Provides a simple publish/subscribe mechanism keyed by hashed event names. Uses a global map
//! protected by a mutex and copies listeners before dispatch to allow callbacks to mutate state.
const std = @import("std");
const log = @import("log.zig");
const name_hash = @import("name_hash.zig");
const evt_log = log.ScopedLogger("EVENTS");

/// Opaque event identifier (typically `makeEventId` of a string).
pub const EventId = u64;

/// Published event data passed to handlers.
pub const Event = struct {
    id: EventId,
    data: ?*const anyopaque,
};

/// Event handler function signature.
pub const EventHandler = *const fn (event: Event, user_data: ?*anyopaque) void;

const Listener = struct {
    callback: EventHandler,
    user_data: ?*anyopaque,
};

const QueueCell = struct {
    seq: std.atomic.Value(u32),
    event: Event,
};

const EventQueue = struct {
    allocator: std.mem.Allocator,
    cells: []QueueCell,
    mask: u32,
    capacity: u32,
    head: std.atomic.Value(u32),
    tail: std.atomic.Value(u32),
    refs: std.atomic.Value(u32),

    fn create(allocator: std.mem.Allocator, requested_capacity: u32) !*EventQueue {
        const cap = try std.math.ceilPowerOfTwo(u32, if (requested_capacity < 2) 2 else requested_capacity);
        const queue = try allocator.create(EventQueue);

        queue.* = .{
            .allocator = allocator,
            .cells = try allocator.alloc(QueueCell, cap),
            .mask = cap - 1,
            .capacity = cap,
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(0),
            .refs = std.atomic.Value(u32).init(1),
        };

        var i: u32 = 0;
        while (i < cap) : (i += 1) {
            const idx: usize = @intCast(i);
            queue.cells[idx].seq = std.atomic.Value(u32).init(i);
            queue.cells[idx].event = .{ .id = 0, .data = null };
        }

        return queue;
    }

    fn retain(self: *EventQueue) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    fn release(self: *EventQueue) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.allocator.free(self.cells);
            self.allocator.destroy(self);
        }
    }

    fn enqueue(self: *EventQueue, event: Event) bool {
        var pos = self.tail.load(.acquire);
        while (true) {
            const cell = &self.cells[@as(usize, @intCast(pos & self.mask))];
            const seq = cell.seq.load(.acquire);
            const dif_i64: i64 = @as(i64, @intCast(seq)) - @as(i64, @intCast(pos));
            if (dif_i64 == 0) {
                if (self.tail.cmpxchgWeak(pos, pos +% 1, .acq_rel, .acquire)) |new_pos| {
                    pos = new_pos;
                    continue;
                }
                cell.event = event;
                cell.seq.store(pos +% 1, .release);
                return true;
            }
            if (dif_i64 < 0) {
                return false;
            }
            pos = self.tail.load(.acquire);
        }
    }

    fn dequeue(self: *EventQueue, out_event: *Event) bool {
        var pos = self.head.load(.acquire);
        while (true) {
            const cell = &self.cells[@as(usize, @intCast(pos & self.mask))];
            const seq = cell.seq.load(.acquire);
            const dif_i64: i64 = @as(i64, @intCast(seq)) - @as(i64, @intCast(pos +% 1));
            if (dif_i64 == 0) {
                if (self.head.cmpxchgWeak(pos, pos +% 1, .acq_rel, .acquire)) |new_pos| {
                    pos = new_pos;
                    continue;
                }
                out_event.* = cell.event;
                cell.seq.store(pos +% self.capacity, .release);
                return true;
            }
            if (dif_i64 < 0) {
                return false;
            }
            pos = self.head.load(.acquire);
        }
    }
};

var g_allocator: std.mem.Allocator = undefined;
var g_listeners: std.AutoHashMapUnmanaged(EventId, std.ArrayListUnmanaged(Listener)) = .{};
var g_queues: std.AutoHashMapUnmanaged(EventId, *EventQueue) = .{};
var g_mutex: std.Thread.Mutex = .{};

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    g_listeners = .{};
    g_queues = .{};
}

/// Releases all registered listeners and backing storage.
pub fn shutdown() void {
    g_mutex.lock();
    defer g_mutex.unlock();

    var it = g_listeners.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(g_allocator);
    }
    g_listeners.deinit(g_allocator);

    var qit = g_queues.iterator();
    while (qit.next()) |entry| {
        entry.value_ptr.*.release();
    }
    g_queues.deinit(g_allocator);
}

/// Computes a stable event id from a human-readable name.
pub fn makeEventId(name: []const u8) EventId {
    return name_hash.hash_u64_wyhash(name);
}

/// Registers a handler for `event_id`.
pub fn subscribe(event_id: EventId, callback: EventHandler, user_data: ?*anyopaque) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    var list = g_listeners.getOrPut(g_allocator, event_id) catch return;
    if (!list.found_existing) {
        list.value_ptr.* = .{};
    }
    list.value_ptr.append(g_allocator, .{ .callback = callback, .user_data = user_data }) catch return;
}

/// Removes all handlers for `event_id` matching `callback`.
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

/// Enables a bounded lock-free queue for `event_id` to decouple producers from listeners.
pub fn enableQueue(event_id: EventId, capacity: u32) bool {
    g_mutex.lock();
    defer g_mutex.unlock();

    if (g_queues.contains(event_id)) return true;

    const queue = EventQueue.create(g_allocator, capacity) catch return false;
    g_queues.put(g_allocator, event_id, queue) catch {
        queue.release();
        return false;
    };
    return true;
}

/// Disables the lock-free queue for `event_id` and releases its storage.
pub fn disableQueue(event_id: EventId) void {
    var removed: ?*EventQueue = null;

    g_mutex.lock();
    if (g_queues.fetchRemove(event_id)) |kv| {
        removed = kv.value;
    }
    g_mutex.unlock();

    if (removed) |q| q.release();
}

/// TODO: Deduplicate listener snapshot logic shared with `flush`.
fn dispatch_to_listeners(event_id: EventId, data: ?*const anyopaque) void {
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
        var listeners_copy = list.clone(g_allocator) catch {
            g_mutex.unlock();
            evt_log.err("Failed to allocate listener copy for event {}", .{event_id});
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

/// Publishes an event to all current subscribers.
pub fn publish(event_id: EventId, data: ?*const anyopaque) void {
    var queue: ?*EventQueue = null;
    g_mutex.lock();
    if (g_queues.get(event_id)) |q| {
        q.retain();
        queue = q;
    }
    g_mutex.unlock();

    if (queue) |q| {
        defer q.release();
        if (!q.enqueue(.{ .id = event_id, .data = data })) {
            evt_log.warn("Event queue full for event {}", .{event_id});
        }
        return;
    }

    dispatch_to_listeners(event_id, data);
}

/// Drains up to `max_events` queued events for `event_id`, dispatching them to current listeners.
/// Returns the number of events actually drained. A `max_events` of 0 drains until empty.
pub fn flush(event_id: EventId, max_events: u32) u32 {
    var queue: ?*EventQueue = null;
    const MAX_STACK_LISTENERS = 64;
    var stack_buffer: [MAX_STACK_LISTENERS]Listener = undefined;
    var heap_copy: ?std.ArrayListUnmanaged(Listener) = null;
    var listener_count: usize = 0;

    g_mutex.lock();
    if (g_queues.get(event_id)) |q| {
        q.retain();
        queue = q;
    }

    const list_ptr = g_listeners.getPtr(event_id);
    if (list_ptr) |list| {
        listener_count = list.items.len;
        if (listener_count <= MAX_STACK_LISTENERS) {
            @memcpy(stack_buffer[0..listener_count], list.items);
        } else {
            const copy = list.clone(g_allocator) catch {
                g_mutex.unlock();
                if (queue) |q| q.release();
                evt_log.err("Failed to allocate listener copy for event {}", .{event_id});
                return 0;
            };
            heap_copy = copy;
        }
    }
    g_mutex.unlock();

    defer {
        if (heap_copy) |*copy| copy.deinit(g_allocator);
        if (queue) |q| q.release();
    }

    if (queue == null) return 0;
    if (listener_count == 0) {
        var ignored: Event = undefined;
        var drained: u32 = 0;
        const limit = if (max_events == 0) std.math.maxInt(u32) else max_events;
        while (drained < limit) : (drained += 1) {
            if (!queue.?.dequeue(&ignored)) break;
        }
        return drained;
    }

    var dispatched: u32 = 0;
    const limit = if (max_events == 0) std.math.maxInt(u32) else max_events;
    var ev: Event = undefined;
    while (dispatched < limit) : (dispatched += 1) {
        if (!queue.?.dequeue(&ev)) break;
        if (heap_copy) |copy| {
            for (copy.items) |listener| {
                listener.callback(ev, listener.user_data);
            }
        } else {
            for (stack_buffer[0..listener_count]) |listener| {
                listener.callback(ev, listener.user_data);
            }
        }
    }

    return dispatched;
}

test "events queued publish and flush" {
    const allocator = std.testing.allocator;
    init(allocator);
    defer shutdown();

    const event_id = makeEventId("queued_test");
    try std.testing.expect(enableQueue(event_id, 8));

    const User = struct {
        values: [4]u32 = .{ 0, 0, 0, 0 },
        count: u32 = 0,
    };

    const handler = struct {
        fn onEvent(event: Event, user_data: ?*anyopaque) void {
            const u: *User = @ptrCast(@alignCast(user_data.?));
            const v: *const u32 = @ptrCast(@alignCast(event.data.?));
            u.values[u.count] = v.*;
            u.count += 1;
        }
    }.onEvent;

    var user: User = .{};
    subscribe(event_id, handler, &user);

    const d0: u32 = 10;
    const d1: u32 = 20;
    const d2: u32 = 30;
    const d3: u32 = 40;

    publish(event_id, &d0);
    publish(event_id, &d1);
    publish(event_id, &d2);
    publish(event_id, &d3);

    const flushed = flush(event_id, 0);
    try std.testing.expectEqual(@as(u32, 4), flushed);
    try std.testing.expectEqual(@as(u32, 4), user.count);
    try std.testing.expectEqual(@as(u32, 10), user.values[0]);
    try std.testing.expectEqual(@as(u32, 20), user.values[1]);
    try std.testing.expectEqual(@as(u32, 30), user.values[2]);
    try std.testing.expectEqual(@as(u32, 40), user.values[3]);
}
