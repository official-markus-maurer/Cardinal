const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory.zig");
const ref_counting = @import("ref_counting.zig");
const vulkan_mt = @import("../renderer/vulkan_mt.zig");
const types = @import("../renderer/vulkan_types.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
    } else {
        @cInclude("time.h");
        @cInclude("unistd.h");
        @cInclude("sys/syscall.h");
    }
});

// Enums and Structs
pub const CardinalResourceState = enum(c_int) {
    UNLOADED = 0,
    LOADING,
    LOADED,
    ERROR,
    UNLOADING,
};

pub const CardinalResourceStateTracker = struct {
    ref_resource: ?*ref_counting.CardinalRefCountedResource,
    state: CardinalResourceState,
    state_mutex: types.cardinal_mutex_t,
    state_changed: types.cardinal_cond_t,
    loading_thread_id: u32,
    state_change_timestamp: u64,
    identifier: ?[*:0]u8,
    next: ?*CardinalResourceStateTracker,
};

pub const CardinalResourceStateRegistry = struct {
    buckets: ?[*] ?*CardinalResourceStateTracker,
    bucket_count: usize,
    registry_mutex: types.cardinal_mutex_t,
    total_tracked_resources: u32,
    initialized: bool,
};

// Global state
var g_state_registry: CardinalResourceStateRegistry = std.mem.zeroes(CardinalResourceStateRegistry);

// Helpers
fn hash_string(str: [*:0]const u8) u32 {
    var hash: u32 = 5381;
    var ptr = str;
    while (ptr[0] != 0) : (ptr += 1) {
        const char = ptr[0];
        hash = ((hash << 5) +% hash) +% char;
    }
    return hash;
}

fn get_timestamp_ms() u64 {
    if (builtin.os.tag == .windows) {
        return c.GetTickCount64();
    } else {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1000000;
    }
}

fn find_state_tracker_unsafe(identifier: ?[*:0]const u8) ?*CardinalResourceStateTracker {
    if (!g_state_registry.initialized or identifier == null) return null;
    
    const hash = hash_string(identifier.?);
    const bucket_index = hash % g_state_registry.bucket_count;
    
    var current = g_state_registry.buckets.?[bucket_index];
    while (current) |curr| {
        if (c.strcmp(curr.identifier, identifier) == 0) {
            return curr;
        }
        current = curr.next;
    }
    return null;
}

// Exports
pub export fn cardinal_resource_state_init(bucket_count: usize) callconv(.c) bool {
    if (g_state_registry.initialized) {
        std.log.warn("Resource state tracking system already initialized", .{});
        return true;
    }

    const count = if (bucket_count == 0) 1009 else bucket_count;
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    const size = count * @sizeOf(?*CardinalResourceStateTracker);
    const ptr = allocator.alloc(allocator, size, 0);
    
    if (ptr) |p| {
        g_state_registry.buckets = @ptrCast(@alignCast(p));
        _ = c.memset(p, 0, size);
    } else {
        std.log.err("Failed to allocate memory for resource state registry buckets", .{});
        return false;
    }

    if (!vulkan_mt.cardinal_mt_mutex_init(&g_state_registry.registry_mutex)) {
        std.log.err("Failed to initialize resource state registry mutex", .{});
        allocator.free(allocator, ptr);
        return false;
    }

    g_state_registry.bucket_count = count;
    g_state_registry.total_tracked_resources = 0;
    g_state_registry.initialized = true;

    std.log.info("Resource state tracking system initialized with {d} buckets", .{count});
    return true;
}

pub export fn cardinal_resource_state_shutdown() callconv(.c) void {
    if (!g_state_registry.initialized) return;

    std.log.info("Shutting down resource state tracking system...", .{});

    vulkan_mt.cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    var i: usize = 0;
    while (i < g_state_registry.bucket_count) : (i += 1) {
        var current = g_state_registry.buckets.?[i];
        while (current) |curr| {
            const next = curr.next;

            const id_str: []const u8 = if (curr.identifier) |id| std.mem.span(id) else "null";
            std.log.debug("Cleaning up state tracker for resource '{s}'", .{id_str});

            vulkan_mt.cardinal_mt_mutex_destroy(&curr.state_mutex);
            vulkan_mt.cardinal_mt_cond_destroy(&curr.state_changed);

            allocator.free(allocator, curr.identifier);
            allocator.free(allocator, curr);

            current = next;
        }
    }

    allocator.free(allocator, @ptrCast(g_state_registry.buckets));
    g_state_registry.buckets = null;
    g_state_registry.bucket_count = 0;
    g_state_registry.total_tracked_resources = 0;

    vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
    vulkan_mt.cardinal_mt_mutex_destroy(&g_state_registry.registry_mutex);

    g_state_registry.initialized = false;

    std.log.info("Resource state tracking system shutdown complete", .{});
}

pub export fn cardinal_resource_state_register(ref_resource: ?*ref_counting.CardinalRefCountedResource) callconv(.c) ?*CardinalResourceStateTracker {
    if (!g_state_registry.initialized) {
        std.log.err("Resource state registry not initialized", .{});
        return null;
    }
    if (ref_resource == null) {
        std.log.err("ref_resource is NULL", .{});
        return null;
    }
    if (ref_resource.?.identifier == null) {
        std.log.err("ref_resource->identifier is NULL", .{});
        return null;
    }

    vulkan_mt.cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);

    const existing = find_state_tracker_unsafe(ref_resource.?.identifier);
    if (existing != null) {
        vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return existing;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    const tracker_ptr = allocator.alloc(allocator, @sizeOf(CardinalResourceStateTracker), 0);
    if (tracker_ptr == null) {
        std.log.err("Failed to allocate memory for resource state tracker", .{});
        vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return null;
    }
    const tracker: *CardinalResourceStateTracker = @ptrCast(@alignCast(tracker_ptr));
    _ = c.memset(tracker, 0, @sizeOf(CardinalResourceStateTracker));

    tracker.ref_resource = ref_resource;
    tracker.state = .UNLOADED;
    tracker.loading_thread_id = 0;
    tracker.state_change_timestamp = get_timestamp_ms();

    const id_len = c.strlen(ref_resource.?.identifier) + 1;
    const id_ptr = allocator.alloc(allocator, id_len, 0);
    if (id_ptr == null) {
        std.log.err("Failed to allocate memory for resource identifier copy", .{});
        allocator.free(allocator, tracker);
        vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return null;
    }
    tracker.identifier = @ptrCast(id_ptr);
    _ = c.strcpy(tracker.identifier, ref_resource.?.identifier);

    if (!vulkan_mt.cardinal_mt_mutex_init(&tracker.state_mutex)) {
        std.log.err("Failed to initialize state tracker mutex", .{});
        allocator.free(allocator, tracker.identifier);
        allocator.free(allocator, tracker);
        vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return null;
    }

    if (!vulkan_mt.cardinal_mt_cond_init(&tracker.state_changed)) {
        std.log.err("Failed to initialize state tracker condition variable", .{});
        vulkan_mt.cardinal_mt_mutex_destroy(&tracker.state_mutex);
        allocator.free(allocator, tracker.identifier);
        allocator.free(allocator, tracker);
        vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
        return null;
    }

    const hash = hash_string(ref_resource.?.identifier.?);
    const bucket_index = hash % g_state_registry.bucket_count;
    tracker.next = g_state_registry.buckets.?[bucket_index];
    g_state_registry.buckets.?[bucket_index] = tracker;
    g_state_registry.total_tracked_resources += 1;

    vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    std.log.debug("Registered resource state tracker for '{s}'", .{std.mem.span(ref_resource.?.identifier.?)});
    return tracker;
}

pub export fn cardinal_resource_state_unregister(identifier: ?[*:0]const u8) callconv(.c) void {
    if (!g_state_registry.initialized or identifier == null) return;

    vulkan_mt.cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);

    const hash = hash_string(identifier.?);
    const bucket_index = hash % g_state_registry.bucket_count;

    var current_ptr_ptr = &g_state_registry.buckets.?[bucket_index];
    while (current_ptr_ptr.*) |current| {
        if (c.strcmp(current.identifier, identifier) == 0) {
            current_ptr_ptr.* = current.next;

            const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

            vulkan_mt.cardinal_mt_mutex_destroy(&current.state_mutex);
            vulkan_mt.cardinal_mt_cond_destroy(&current.state_changed);

            allocator.free(allocator, current.identifier);
            allocator.free(allocator, current);

            g_state_registry.total_tracked_resources -= 1;

            const id_str: []const u8 = if (identifier) |id| std.mem.span(id) else "null";
            std.log.debug("Unregistered resource state tracker for '{s}'", .{id_str});
            break;
        }
        current_ptr_ptr = &current.next;
    }

    vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);
}

pub export fn cardinal_resource_state_get(identifier: ?[*:0]const u8) callconv(.c) CardinalResourceState {
    if (!g_state_registry.initialized or identifier == null) {
        return .UNLOADED;
    }

    vulkan_mt.cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);
    const tracker = find_state_tracker_unsafe(identifier);
    vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (tracker == null) {
        return .UNLOADED;
    }

    vulkan_mt.cardinal_mt_mutex_lock(&tracker.?.state_mutex);
    const state = tracker.?.state;
    vulkan_mt.cardinal_mt_mutex_unlock(&tracker.?.state_mutex);

    return state;
}

pub export fn cardinal_resource_state_set(identifier: ?[*:0]const u8, new_state: CardinalResourceState, loading_thread_id: u32) callconv(.c) bool {
    if (!g_state_registry.initialized or identifier == null) {
        return false;
    }

    vulkan_mt.cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);
    const tracker = find_state_tracker_unsafe(identifier);
    vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (tracker == null) {
        const id_str: []const u8 = if (identifier) |id| std.mem.span(id) else "null";
        std.log.err("Cannot set state for untracked resource '{s}'", .{id_str});
        return false;
    }

    vulkan_mt.cardinal_mt_mutex_lock(&tracker.?.state_mutex);

    const old_state = tracker.?.state;
    var valid_transition = false;

    switch (old_state) {
        .UNLOADED => {
            valid_transition = (new_state == .LOADING);
        },
        .LOADING => {
            if (tracker.?.loading_thread_id == loading_thread_id) {
                valid_transition = (new_state == .LOADED or new_state == .ERROR);
            }
        },
        .LOADED => {
            valid_transition = (new_state == .UNLOADING);
        },
        .ERROR => {
            valid_transition = (new_state == .LOADING or new_state == .UNLOADED);
        },
        .UNLOADING => {
            valid_transition = (new_state == .UNLOADED);
        },
    }

    if (!valid_transition) {
        std.log.err("Invalid state transition for resource '{s}': {d} -> {d}", .{if (identifier) |id| std.mem.span(id) else "null", @intFromEnum(old_state), @intFromEnum(new_state)});
        vulkan_mt.cardinal_mt_mutex_unlock(&tracker.?.state_mutex);
        return false;
    }

    tracker.?.state = new_state;
    tracker.?.state_change_timestamp = get_timestamp_ms();

    if (new_state == .LOADING) {
        tracker.?.loading_thread_id = loading_thread_id;
    } else if (new_state == .LOADED or new_state == .ERROR or new_state == .UNLOADED) {
        tracker.?.loading_thread_id = 0;
    }

    vulkan_mt.cardinal_mt_cond_broadcast(&tracker.?.state_changed);
    vulkan_mt.cardinal_mt_mutex_unlock(&tracker.?.state_mutex);

    std.log.debug("Resource '{s}' state changed: {d} -> {d} (thread {d})", .{if (identifier) |id| std.mem.span(id) else "null", @intFromEnum(old_state), @intFromEnum(new_state), loading_thread_id});
    return true;
}

pub export fn cardinal_resource_state_wait_for(identifier: ?[*:0]const u8, target_state: CardinalResourceState, timeout_ms: u32) callconv(.c) bool {
    if (!g_state_registry.initialized or identifier == null) {
        return false;
    }

    vulkan_mt.cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);
    const tracker = find_state_tracker_unsafe(identifier);
    vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (tracker == null) {
        return false;
    }

    vulkan_mt.cardinal_mt_mutex_lock(&tracker.?.state_mutex);

    const start_time = get_timestamp_ms();

    while (tracker.?.state != target_state) {
        if (timeout_ms > 0) {
            const elapsed = get_timestamp_ms() - start_time;
            if (elapsed >= timeout_ms) {
                vulkan_mt.cardinal_mt_mutex_unlock(&tracker.?.state_mutex);
                std.log.warn("Timeout waiting for resource '{s}' to reach state {d}", .{if (identifier) |id| std.mem.span(id) else "null", @intFromEnum(target_state)});
                return false;
            }

            const remaining_ms: u32 = timeout_ms - @as(u32, @intCast(elapsed));
            if (!vulkan_mt.cardinal_mt_cond_wait_timeout(&tracker.?.state_changed, &tracker.?.state_mutex, remaining_ms)) {
                vulkan_mt.cardinal_mt_mutex_unlock(&tracker.?.state_mutex);
                return false;
            }
        } else {
            vulkan_mt.cardinal_mt_cond_wait(&tracker.?.state_changed, &tracker.?.state_mutex);
        }
    }

    vulkan_mt.cardinal_mt_mutex_unlock(&tracker.?.state_mutex);
    return true;
}

pub export fn cardinal_resource_state_try_acquire_loading(identifier: ?[*:0]const u8, loading_thread_id: u32) callconv(.c) bool {
    if (!g_state_registry.initialized or identifier == null) {
        return false;
    }

    vulkan_mt.cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);
    const tracker = find_state_tracker_unsafe(identifier);
    vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (tracker == null) {
        return false;
    }

    vulkan_mt.cardinal_mt_mutex_lock(&tracker.?.state_mutex);

    var acquired = false;
    if (tracker.?.state == .UNLOADED or tracker.?.state == .ERROR) {
        tracker.?.state = .LOADING;
        tracker.?.loading_thread_id = loading_thread_id;
        tracker.?.state_change_timestamp = get_timestamp_ms();
        vulkan_mt.cardinal_mt_cond_broadcast(&tracker.?.state_changed);
        acquired = true;
    }

    vulkan_mt.cardinal_mt_mutex_unlock(&tracker.?.state_mutex);

    if (acquired) {
        std.log.debug("Thread {d} acquired loading access for resource '{s}'", .{loading_thread_id, if (identifier) |id| std.mem.span(id) else "null"});
    }

    return acquired;
}

pub export fn cardinal_resource_state_is_safe_to_access(identifier: ?[*:0]const u8) callconv(.c) bool {
    return cardinal_resource_state_get(identifier) == .LOADED;
}

pub export fn cardinal_resource_state_get_stats(out_total_tracked: ?*u32, out_loading_count: ?*u32, out_loaded_count: ?*u32, out_error_count: ?*u32) callconv(.c) void {
    if (!g_state_registry.initialized) {
        if (out_total_tracked) |p| p.* = 0;
        if (out_loading_count) |p| p.* = 0;
        if (out_loaded_count) |p| p.* = 0;
        if (out_error_count) |p| p.* = 0;
        return;
    }

    var total: u32 = 0;
    var loading: u32 = 0;
    var loaded: u32 = 0;
    var error_val: u32 = 0;

    vulkan_mt.cardinal_mt_mutex_lock(&g_state_registry.registry_mutex);

    var i: usize = 0;
    while (i < g_state_registry.bucket_count) : (i += 1) {
        var current = g_state_registry.buckets.?[i];
        while (current) |curr| {
            total += 1;

            vulkan_mt.cardinal_mt_mutex_lock(&curr.state_mutex);
            switch (curr.state) {
                .LOADING => loading += 1,
                .LOADED => loaded += 1,
                .ERROR => error_val += 1,
                else => {},
            }
            vulkan_mt.cardinal_mt_mutex_unlock(&curr.state_mutex);

            current = curr.next;
        }
    }

    vulkan_mt.cardinal_mt_mutex_unlock(&g_state_registry.registry_mutex);

    if (out_total_tracked) |p| p.* = total;
    if (out_loading_count) |p| p.* = loading;
    if (out_loaded_count) |p| p.* = loaded;
    if (out_error_count) |p| p.* = error_val;
}
