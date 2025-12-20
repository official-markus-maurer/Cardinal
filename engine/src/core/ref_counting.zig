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
    var hash: u32 = 5381;
    var ptr = str;
    while (ptr[0] != 0) : (ptr += 1) {
        hash = ((hash << 5) +% hash) +% ptr[0]; // hash * 33 + c
    }
    return hash;
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
fn remove_resource(identifier: ?[*:0]const u8) void {
    if (!g_registry_initialized or identifier == null) {
        return;
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
                return;
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

            const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

            // Free the identifier and the ref counted wrapper
            memory.cardinal_free(allocator, curr.identifier);
            memory.cardinal_free(allocator, curr);

            _ = @atomicRmw(u32, &g_registry.total_resources, .Sub, 1, .seq_cst);
            ref_log.debug("Successfully removed and freed resource '{s}'", .{identifier.?});
            return;
        }
        prev = curr;
        current = curr.next;
    }
    ref_log.warn("Failed to find resource '{s}' in registry for removal!", .{identifier.?});
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
        remove_resource(res.identifier);
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
                std.log.info("  - '{s}': ref_count={d}, size={d} bytes", .{ curr.identifier.?, curr.ref_count, curr.resource_size });
                current = curr.next;
            }
        }
    }
    std.log.info("=== End Debug Info ===", .{});
}
