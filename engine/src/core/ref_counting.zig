//! Reference-counted resource registry.
//!
//! Tracks resources by identifier (string key) and exposes retain/release-style APIs for shared
//! ownership across subsystems (textures, materials, etc).
//!
//! TODO: Replace the single global mutex with bucket-level locking for better contention behavior.
const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const memory = @import("memory.zig");

const ref_log = log.ScopedLogger("REF_COUNT");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

/// Mutex protecting the global registry.
var g_registry_mutex: std.Thread.Mutex = .{};

/// Reference-counted resource record.
///
/// `ref_count` counts strong references, while `weak_count` tracks weak refs (if used).
pub const CardinalRefCountedResource = extern struct {
    resource: ?*anyopaque,
    ref_count: u32,
    weak_count: u32,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
    identifier: ?[*:0]u8,
    resource_size: usize,
    next: ?*CardinalRefCountedResource,
};

const CardinalResourceRegistry = extern struct {
    buckets: ?[*]?*CardinalRefCountedResource,
    bucket_count: usize,
    total_resources: u32,
};

var g_registry: CardinalResourceRegistry = std.mem.zeroes(CardinalResourceRegistry);
var g_registry_initialized: bool = false;

/// Hashes a null-terminated identifier string for bucket selection.
fn hash_string(str: [*:0]const u8) u32 {
    const slice = std.mem.span(str);
    return @truncate(std.hash.Wyhash.hash(0, slice));
}

/// Finds a resource in the registry by identifier (caller holds `g_registry_mutex`).
fn find_resource_locked(identifier: ?[*:0]const u8) ?*CardinalRefCountedResource {
    if (!g_registry_initialized or identifier == null) {
        return null;
    }

    const hash = hash_string(identifier.?);
    const bucket_index = hash % g_registry.bucket_count;

    var current = g_registry.buckets.?[bucket_index];
    while (current) |curr| {
        if (std.mem.orderZ(u8, curr.identifier.?, identifier.?) == .eq) {
            return curr;
        }
        current = curr.next;
    }

    return null;
}

/// Removes a resource from the registry and runs its destructor if not resurrected.
fn remove_resource(identifier: ?[*:0]const u8) bool {
    if (!g_registry_initialized or identifier == null) {
        return false;
    }

    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();

    const hash = hash_string(identifier.?);
    const bucket_index = hash % g_registry.bucket_count;

    var prev: ?*CardinalRefCountedResource = null;
    var current = g_registry.buckets.?[bucket_index];

    while (current) |curr| {
        if (std.mem.orderZ(u8, curr.identifier.?, identifier.?) == .eq) {
            if (@atomicLoad(u32, &curr.ref_count, .seq_cst) > 0) {
                ref_log.debug("Resource '{s}' resurrected (ref_count={d}), cancelling removal", .{ identifier.?, curr.ref_count });
                return false;
            }

            if (prev) |p| {
                p.next = curr.next;
            } else {
                g_registry.buckets.?[bucket_index] = curr.next;
            }

            if (curr.destructor) |destructor| {
                if (curr.resource) |res| {
                    destructor(res);
                }
            }
            curr.resource = null;

            const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

            const old_weak = @atomicRmw(u32, &curr.weak_count, .Sub, 1, .seq_cst);
            if (old_weak == 1) {
                memory.cardinal_free(allocator, curr.identifier);
                memory.cardinal_free(allocator, curr);
                ref_log.debug("Successfully removed and freed resource '{s}'", .{identifier.?});
            } else {
                ref_log.debug("Removed resource '{s}' from registry, but block kept alive (weak_count={d})", .{ identifier.?, old_weak - 1 });
            }

            _ = @atomicRmw(u32, &g_registry.total_resources, .Sub, 1, .seq_cst);
            return true;
        }
        prev = curr;
        current = curr.next;
    }
    ref_log.warn("Failed to find resource '{s}' in registry for removal!", .{identifier.?});

    if (builtin.mode == .Debug) {
        ref_log.warn("Registry state at failure:", .{});
        var i: usize = 0;
        while (i < g_registry.bucket_count) : (i += 1) {
            var current_node = g_registry.buckets.?[i];
            while (current_node) |node| {
                const node_id = if (node.identifier) |id| id else "null";
                ref_log.warn("  - Bucket {d}: '{s}' (ref: {d})", .{ i, node_id, @atomicLoad(u32, &node.ref_count, .seq_cst) });
                current_node = node.next;
            }
        }
    }

    return false;
}

/// Initializes the global registry.
pub export fn cardinal_ref_counting_init(bucket_count: usize) callconv(.c) bool {
    if (g_registry_initialized) {
        ref_log.warn("Reference counting system already initialized", .{});
        return true;
    }

    const count = if (bucket_count == 0) 1009 else bucket_count;

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const buckets = memory.cardinal_calloc(allocator, count, @sizeOf(?*CardinalRefCountedResource));

    if (buckets == null) {
        ref_log.err("Failed to allocate memory for resource registry buckets", .{});
        return false;
    }

    g_registry.buckets = @ptrCast(@alignCast(buckets));

    g_registry.bucket_count = count;
    g_registry.total_resources = 0;

    g_registry_initialized = true;

    ref_log.info("Reference counting system initialized with {d} buckets", .{count});
    return true;
}

/// Shuts down the registry and releases any remaining resources.
pub export fn cardinal_ref_counting_shutdown() callconv(.c) void {
    if (!g_registry_initialized) {
        ref_log.info("Ref counting shutdown called but not initialized", .{});
        return;
    }

    ref_log.info("Shutting down reference counting system...", .{});

    g_registry_mutex.lock();

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    var count: u32 = 0;

    var i: usize = 0;
    while (i < g_registry.bucket_count) : (i += 1) {
        var current = g_registry.buckets.?[i];
        while (current) |curr| {
            const next = curr.next;
            count += 1;

            const id_str = if (curr.identifier) |id| id else "null";
            ref_log.warn("Resource '{s}' still has {d} references during shutdown", .{ id_str, @atomicLoad(u32, &curr.ref_count, .seq_cst) });

            if (curr.destructor) |destructor| {
                if (curr.resource) |res| {
                    destructor(res);
                }
            }
            if (curr.identifier) |id| {
                memory.cardinal_free(allocator, id);
            }
            memory.cardinal_free(allocator, curr);

            current = next;
        }
    }
    ref_log.info("Ref counting shutdown: freed {d} resources", .{count});

    memory.cardinal_free(allocator, @ptrCast(g_registry.buckets));
    g_registry = std.mem.zeroes(CardinalResourceRegistry);

    g_registry_mutex.unlock();
    g_registry_initialized = false;

    ref_log.info("Reference counting system shutdown complete", .{});
}

/// Creates a new resource record or acquires an existing one by identifier.
pub export fn cardinal_ref_create(identifier: ?[*:0]const u8, resource: ?*anyopaque, resource_size: usize, destructor: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) ?*CardinalRefCountedResource {
    if (!g_registry_initialized) {
        ref_log.err("Reference counting system not initialized", .{});
        return null;
    }

    if (identifier == null or resource == null) {
        ref_log.err("Invalid parameters for ref_create: identifier={?s}, resource={?*}", .{ identifier, resource });
        return null;
    }

    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();

    if (find_resource_locked(identifier)) |existing| {
        _ = @atomicRmw(u32, &existing.ref_count, .Add, 1, .seq_cst);
        ref_log.debug("Acquired existing resource '{s}', ref_count={d}", .{ identifier.?, existing.ref_count });
        return existing;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    const ref_resource_ptr = memory.cardinal_alloc(allocator, @sizeOf(CardinalRefCountedResource));
    if (ref_resource_ptr == null) {
        ref_log.err("Failed to allocate memory for reference counted resource", .{});
        return null;
    }
    const ref_resource: *CardinalRefCountedResource = @ptrCast(@alignCast(ref_resource_ptr));

    ref_resource.resource = resource;
    ref_resource.ref_count = 1;
    ref_resource.weak_count = 1;
    ref_resource.destructor = destructor;
    ref_resource.resource_size = resource_size;
    ref_resource.next = null;

    const id_len = std.mem.len(identifier.?) + 1;
    const id_ptr = memory.cardinal_alloc(allocator, id_len);
    if (id_ptr == null) {
        ref_log.err("Failed to allocate memory for resource identifier", .{});
        memory.cardinal_free(allocator, ref_resource);
        return null;
    }
    ref_resource.identifier = @ptrCast(id_ptr);
    @memcpy(ref_resource.identifier.?[0..id_len], identifier.?[0..id_len]);

    const hash = hash_string(identifier.?);
    const bucket_index = hash % g_registry.bucket_count;

    ref_resource.next = g_registry.buckets.?[bucket_index];
    g_registry.buckets.?[bucket_index] = ref_resource;

    _ = @atomicRmw(u32, &g_registry.total_resources, .Add, 1, .seq_cst);

    ref_log.debug("Created new resource '{s}', ref_count=1, total_resources={d}", .{ identifier.?, g_registry.total_resources });

    return ref_resource;
}

/// Acquires an existing resource record by identifier.
pub export fn cardinal_ref_acquire(identifier: ?[*:0]const u8) callconv(.c) ?*CardinalRefCountedResource {
    if (!g_registry_initialized or identifier == null) {
        return null;
    }

    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();

    if (find_resource_locked(identifier)) |resource| {
        _ = @atomicRmw(u32, &resource.ref_count, .Add, 1, .seq_cst);
        ref_log.debug("Acquired resource '{s}', ref_count={d}", .{ identifier.?, resource.ref_count });
        return resource;
    }

    return null;
}

/// Releases a strong reference and destroys the resource when it reaches zero.
pub export fn cardinal_ref_release(ref_resource: ?*CardinalRefCountedResource) callconv(.c) void {
    if (ref_resource == null) {
        return;
    }

    const res = ref_resource.?;
    const old_count = @atomicRmw(u32, &res.ref_count, .Sub, 1, .seq_cst);
    const new_count = old_count - 1;

    ref_log.debug("Released resource '{s}', ref_count={d}", .{ res.identifier.?, new_count });

    if (new_count == 0) {
        ref_log.debug("Resource '{s}' ref_count reached 0, cleaning up", .{res.identifier.?});
        if (!remove_resource(res.identifier)) {
            if (@atomicLoad(u32, &res.ref_count, .seq_cst) > 0) {
                ref_log.debug("Resource '{s}' resurrected during release, skipping cleanup", .{res.identifier.?});
                return;
            }

            ref_log.warn("Cleaning up orphan resource '{s}' (not in registry)", .{res.identifier.?});

            if (res.destructor) |destructor| {
                if (res.resource) |r| {
                    destructor(r);
                }
            }
            res.resource = null;

            const old_weak = @atomicRmw(u32, &res.weak_count, .Sub, 1, .seq_cst);
            if (old_weak == 1) {
                const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
                memory.cardinal_free(allocator, res.identifier);
                memory.cardinal_free(allocator, res);
            }
        }
    }
}

/// Returns the current strong reference count for a resource record.
pub export fn cardinal_ref_get_count(ref_resource: ?*const CardinalRefCountedResource) callconv(.c) u32 {
    if (ref_resource == null) {
        return 0;
    }
    return @atomicLoad(u32, &ref_resource.?.ref_count, .seq_cst);
}

/// Returns the total number of registered resources.
pub export fn cardinal_ref_get_total_resources() callconv(.c) u32 {
    if (!g_registry_initialized) {
        return 0;
    }
    return @atomicLoad(u32, &g_registry.total_resources, .seq_cst);
}

/// Returns whether a resource exists for `identifier`.
pub export fn cardinal_ref_exists(identifier: ?[*:0]const u8) callconv(.c) bool {
    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();
    return find_resource_locked(identifier) != null;
}

/// Logs the current registry contents for debugging.
pub export fn cardinal_ref_debug_print_resources() callconv(.c) void {
    if (!g_registry_initialized) {
        std.log.info("Reference counting system not initialized", .{});
        return;
    }

    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();

    ref_log.info("=== Reference Counted Resources Debug Info ===", .{});
    ref_log.info("Total resources: {d}", .{g_registry.total_resources});
    ref_log.info("Bucket count: {d}", .{g_registry.bucket_count});

    var i: usize = 0;
    while (i < g_registry.bucket_count) : (i += 1) {
        var current = g_registry.buckets.?[i];
        if (current != null) {
            ref_log.info("Bucket {d}:", .{i});
            while (current) |curr| {
                ref_log.info("  - '{s}': ref_count={d}, weak_count={d}, size={d} bytes", .{ curr.identifier.?, curr.ref_count, curr.weak_count, curr.resource_size });
                current = curr.next;
            }
        }
    }
    ref_log.info("=== End Debug Info ===", .{});
}

/// Adds one weak reference to a resource record.
pub export fn cardinal_weak_ref_acquire(ref_resource: ?*CardinalRefCountedResource) callconv(.c) void {
    if (ref_resource == null) return;
    _ = @atomicRmw(u32, &ref_resource.?.weak_count, .Add, 1, .seq_cst);
}

/// Releases one weak reference and frees the record when both counts reach zero.
pub export fn cardinal_weak_ref_release(ref_resource: ?*CardinalRefCountedResource) callconv(.c) void {
    if (ref_resource == null) return;
    const res = ref_resource.?;
    const old_weak = @atomicRmw(u32, &res.weak_count, .Sub, 1, .seq_cst);
    if (old_weak == 1) {
        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
        memory.cardinal_free(allocator, res.identifier);
        memory.cardinal_free(allocator, res);
    }
}

/// Promotes a weak reference to a strong one when the resource is still alive.
pub export fn cardinal_weak_ref_lock(ref_resource: ?*CardinalRefCountedResource) callconv(.c) ?*CardinalRefCountedResource {
    if (ref_resource == null) return null;
    const res = ref_resource.?;

    var count = @atomicLoad(u32, &res.ref_count, .seq_cst);
    while (count > 0) {
        const old = @cmpxchgWeak(u32, &res.ref_count, count, count + 1, .seq_cst, .seq_cst);
        if (old) |val| {
            count = val;
        } else {
            return res;
        }
    }
    return null;
}
