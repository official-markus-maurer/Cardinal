const std = @import("std");
const log = @import("log.zig");
const memory = @import("memory.zig");

const ref_log = log.ScopedLogger("REF_COUNT");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    // For mutex/atomic operations, we will use Zig's std.Thread
});

// Mutex for registry thread safety
var g_registry_mutex: std.Thread.Mutex = .{};

// Global resource registry
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

// Simple hash function for string identifiers
fn hash_string(str: [*:0]const u8) u32 {
    const slice = std.mem.span(str);
    return @truncate(std.hash.Wyhash.hash(0, slice));
}

// Find a resource in the registry by identifier
// Assumes lock is held by caller!
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

// Remove a resource from the registry
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
            // Check if resource was resurrected by another thread acquiring it
            // while we were waiting for the lock
            if (@atomicLoad(u32, &curr.ref_count, .seq_cst) > 0) {
                ref_log.debug("Resource '{s}' resurrected (ref_count={d}), cancelling removal", .{ identifier.?, curr.ref_count });
                return false;
            }

            if (prev) |p| {
                p.next = curr.next;
            } else {
                g_registry.buckets.?[bucket_index] = curr.next;
            }

            // Free the resource using its destructor
            if (curr.destructor) |destructor| {
                if (curr.resource) |res| {
                    destructor(res);
                }
            }
            curr.resource = null;

            const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

            // Decrement weak count (releasing the strong ref's hold on the block)
            const old_weak = @atomicRmw(u32, &curr.weak_count, .Sub, 1, .seq_cst);
            if (old_weak == 1) {
                // We were the last ones holding the block
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

    // Debug: print registry contents to help diagnose
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

    return false;
}

pub export fn cardinal_ref_counting_init(bucket_count: usize) callconv(.c) bool {
    if (g_registry_initialized) {
        ref_log.warn("Reference counting system already initialized", .{});
        return true;
    }

    const count = if (bucket_count == 0) 1009 else bucket_count; // Default prime number

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const buckets = memory.cardinal_alloc(allocator, count * @sizeOf(?*CardinalRefCountedResource));

    if (buckets == null) {
        ref_log.err("Failed to allocate memory for resource registry buckets", .{});
        return false;
    }

    g_registry.buckets = @ptrCast(@alignCast(buckets));
    @memset(g_registry.buckets.?[0..count], null);

    g_registry.bucket_count = count;
    g_registry.total_resources = 0;

    g_registry_initialized = true;

    ref_log.info("Reference counting system initialized with {d} buckets", .{count});
    return true;
}

pub export fn cardinal_ref_counting_shutdown() callconv(.c) void {
    if (!g_registry_initialized) {
        ref_log.info("Ref counting shutdown called but not initialized", .{});
        return;
    }

    ref_log.info("Shutting down reference counting system...", .{});

    g_registry_mutex.lock();

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    var count: u32 = 0;

    // Clean up all remaining resources
    var i: usize = 0;
    while (i < g_registry.bucket_count) : (i += 1) {
        var current = g_registry.buckets.?[i];
        while (current) |curr| {
            const next = curr.next;
            count += 1;

            const id_str = if (curr.identifier) |id| id else "null";
            ref_log.warn("Resource '{s}' still has {d} references during shutdown", .{ id_str, @atomicLoad(u32, &curr.ref_count, .seq_cst) });

            // Force cleanup
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

    // Check if resource already exists
    if (find_resource_locked(identifier)) |existing| {
        _ = @atomicRmw(u32, &existing.ref_count, .Add, 1, .seq_cst);
        ref_log.debug("Acquired existing resource '{s}', ref_count={d}", .{ identifier.?, existing.ref_count });
        return existing;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    // Create new resource
    const ref_resource_ptr = memory.cardinal_alloc(allocator, @sizeOf(CardinalRefCountedResource));
    if (ref_resource_ptr == null) {
        ref_log.err("Failed to allocate memory for reference counted resource", .{});
        return null;
    }
    const ref_resource: *CardinalRefCountedResource = @ptrCast(@alignCast(ref_resource_ptr));

    ref_resource.resource = resource;
    ref_resource.ref_count = 1;
    ref_resource.weak_count = 1; // Strong ref counts as 1 weak ref
    ref_resource.destructor = destructor;
    ref_resource.resource_size = resource_size;
    ref_resource.next = null;

    // Copy identifier
    const id_len = std.mem.len(identifier.?) + 1;
    const id_ptr = memory.cardinal_alloc(allocator, id_len);
    if (id_ptr == null) {
        ref_log.err("Failed to allocate memory for resource identifier", .{});
        memory.cardinal_free(allocator, ref_resource);
        return null;
    }
    ref_resource.identifier = @ptrCast(id_ptr);
    @memcpy(ref_resource.identifier.?[0..id_len], identifier.?[0..id_len]);

    // Add to registry
    const hash = hash_string(identifier.?);
    const bucket_index = hash % g_registry.bucket_count;

    // Insert at the beginning of the chain
    ref_resource.next = g_registry.buckets.?[bucket_index];
    g_registry.buckets.?[bucket_index] = ref_resource;

    _ = @atomicRmw(u32, &g_registry.total_resources, .Add, 1, .seq_cst);

    ref_log.debug("Created new resource '{s}', ref_count=1, total_resources={d}", .{ identifier.?, g_registry.total_resources });

    return ref_resource;
}

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
            // Check if it was resurrected (ref_count > 0)
            if (@atomicLoad(u32, &res.ref_count, .seq_cst) > 0) {
                ref_log.debug("Resource '{s}' resurrected during release, skipping cleanup", .{res.identifier.?});
                return;
            }

            // If not found in registry (orphan), we must free it manually to prevent leaks
            ref_log.warn("Cleaning up orphan resource '{s}' (not in registry)", .{res.identifier.?});

            if (res.destructor) |destructor| {
                if (res.resource) |r| {
                    destructor(r);
                }
            }
            res.resource = null;

            // Decrement weak count
            const old_weak = @atomicRmw(u32, &res.weak_count, .Sub, 1, .seq_cst);
            if (old_weak == 1) {
                const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
                memory.cardinal_free(allocator, res.identifier);
                memory.cardinal_free(allocator, res);
            }
        }
    }
}

pub export fn cardinal_ref_get_count(ref_resource: ?*const CardinalRefCountedResource) callconv(.c) u32 {
    if (ref_resource == null) {
        return 0;
    }
    return @atomicLoad(u32, &ref_resource.?.ref_count, .seq_cst);
}

pub export fn cardinal_ref_get_total_resources() callconv(.c) u32 {
    if (!g_registry_initialized) {
        return 0;
    }
    return @atomicLoad(u32, &g_registry.total_resources, .seq_cst);
}

pub export fn cardinal_ref_exists(identifier: ?[*:0]const u8) callconv(.c) bool {
    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();
    return find_resource_locked(identifier) != null;
}

pub export fn cardinal_ref_debug_print_resources() callconv(.c) void {
    if (!g_registry_initialized) {
        std.log.info("Reference counting system not initialized", .{});
        return;
    }

    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();

    std.log.info("=== Reference Counted Resources Debug Info ===", .{});
    std.log.info("Total resources: {d}", .{g_registry.total_resources});
    std.log.info("Bucket count: {d}", .{g_registry.bucket_count});

    var i: usize = 0;
    while (i < g_registry.bucket_count) : (i += 1) {
        var current = g_registry.buckets.?[i];
        if (current != null) {
            std.log.info("Bucket {d}:", .{i});
            while (current) |curr| {
                std.log.info("  - '{s}': ref_count={d}, weak_count={d}, size={d} bytes", .{ curr.identifier.?, curr.ref_count, curr.weak_count, curr.resource_size });
                current = curr.next;
            }
        }
    }
    std.log.info("=== End Debug Info ===", .{});
}

pub export fn cardinal_weak_ref_acquire(ref_resource: ?*CardinalRefCountedResource) callconv(.c) void {
    if (ref_resource == null) return;
    _ = @atomicRmw(u32, &ref_resource.?.weak_count, .Add, 1, .seq_cst);
}

pub export fn cardinal_weak_ref_release(ref_resource: ?*CardinalRefCountedResource) callconv(.c) void {
    if (ref_resource == null) return;
    const res = ref_resource.?;
    const old_weak = @atomicRmw(u32, &res.weak_count, .Sub, 1, .seq_cst);
    if (old_weak == 1) {
        // We were the last one holding the block (and strong refs are gone)
        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
        memory.cardinal_free(allocator, res.identifier);
        memory.cardinal_free(allocator, res);
    }
}

pub export fn cardinal_weak_ref_lock(ref_resource: ?*CardinalRefCountedResource) callconv(.c) ?*CardinalRefCountedResource {
    if (ref_resource == null) return null;
    const res = ref_resource.?;

    var count = @atomicLoad(u32, &res.ref_count, .seq_cst);
    while (count > 0) {
        const old = @cmpxchgWeak(u32, &res.ref_count, count, count + 1, .seq_cst, .seq_cst);
        if (old) |val| {
            count = val; // Retry with new value
        } else {
            // Success
            return res;
        }
    }
    return null;
}
