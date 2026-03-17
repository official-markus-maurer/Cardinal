//! Mesh caching and load helpers.
//!
//! Provides a small thread-safe cache of meshes keyed by identifier, backed by the ref-counting
//! registry. Mesh decoding is currently delegated to scene loaders (glTF/NIF) that populate
//! `scene.CardinalMesh` data.
const std = @import("std");
const scene = @import("scene.zig");
const ref_counting = @import("../core/ref_counting.zig");
const async_loader = @import("../core/async_loader.zig");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");

/// Module logger.
const mesh_log = log.ScopedLogger("MESH");

/// Single-linked cache entry.
const MeshCacheEntry = struct {
    mesh_id: [:0]const u8,
    resource: *ref_counting.CardinalRefCountedResource,
    mesh_bytes: usize,
    prev: ?*MeshCacheEntry,
    next: ?*MeshCacheEntry,
};

/// Mesh cache protected by a mutex.
const MeshCache = struct {
    head: ?*MeshCacheEntry,
    tail: ?*MeshCacheEntry,
    entry_count: u32,
    max_entries: u32,
    cache_hits: u32,
    cache_misses: u32,
    total_bytes: usize,
    peak_bytes: usize,
    initialized: bool,
    mutex: std.Thread.Mutex,
};

var g_mesh_cache: MeshCache = .{
    .head = null,
    .tail = null,
    .entry_count = 0,
    .max_entries = 0,
    .cache_hits = 0,
    .cache_misses = 0,
    .total_bytes = 0,
    .peak_bytes = 0,
    .initialized = false,
    .mutex = .{},
};

/// Initializes the cache (idempotent).
fn mesh_cache_init(max_entries: u32) bool {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (g_mesh_cache.initialized) {
        return true;
    }

    g_mesh_cache.head = null;
    g_mesh_cache.tail = null;
    g_mesh_cache.entry_count = 0;
    g_mesh_cache.max_entries = max_entries;
    g_mesh_cache.cache_hits = 0;
    g_mesh_cache.cache_misses = 0;
    g_mesh_cache.total_bytes = 0;
    g_mesh_cache.peak_bytes = 0;
    g_mesh_cache.initialized = true;

    mesh_log.info_s(.{ .max_entries = max_entries }, "Cache initialized", .{});
    return true;
}

fn entry_detach(entry: *MeshCacheEntry) void {
    if (entry.prev) |p| {
        p.next = entry.next;
    } else {
        g_mesh_cache.head = entry.next;
    }
    if (entry.next) |n| {
        n.prev = entry.prev;
    } else {
        g_mesh_cache.tail = entry.prev;
    }
    entry.prev = null;
    entry.next = null;
}

fn entry_push_front(entry: *MeshCacheEntry) void {
    entry.prev = null;
    entry.next = g_mesh_cache.head;
    if (g_mesh_cache.head) |h| {
        h.prev = entry;
    } else {
        g_mesh_cache.tail = entry;
    }
    g_mesh_cache.head = entry;
}

fn entry_mesh_bytes(resource: *ref_counting.CardinalRefCountedResource) usize {
    const mesh: *scene.CardinalMesh = @ptrCast(@alignCast(resource.resource.?));
    var bytes: usize = @sizeOf(scene.CardinalMesh);
    if (mesh.vertices != null and mesh.vertex_count > 0) {
        bytes += @as(usize, @intCast(mesh.vertex_count)) * @sizeOf(scene.CardinalVertex);
    }
    if (mesh.indices != null and mesh.index_count > 0) {
        bytes += @as(usize, @intCast(mesh.index_count)) * @sizeOf(u32);
    }
    return bytes;
}

fn evict_tail_if_needed(allocator: *memory.CardinalAllocator) void {
    if (g_mesh_cache.max_entries == 0) return;
    while (g_mesh_cache.entry_count >= g_mesh_cache.max_entries) {
        const to_remove = g_mesh_cache.tail orelse return;
        entry_detach(to_remove);

        memory.cardinal_free(allocator, @ptrCast(@constCast(to_remove.mesh_id.ptr)));
        ref_counting.cardinal_ref_release(to_remove.resource);
        g_mesh_cache.total_bytes -|= to_remove.mesh_bytes;
        memory.cardinal_free(allocator, to_remove);

        if (g_mesh_cache.entry_count > 0) g_mesh_cache.entry_count -= 1;
    }
}

/// Returns a retained mesh resource if present in cache.
fn mesh_cache_get(mesh_id: []const u8) ?*ref_counting.CardinalRefCountedResource {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (!g_mesh_cache.initialized) {
        return null;
    }

    var entry = g_mesh_cache.head;
    while (entry) |e| {
        if (std.mem.eql(u8, e.mesh_id, mesh_id)) {
            if (ref_counting.cardinal_ref_acquire(e.resource.identifier)) |res| {
                g_mesh_cache.cache_hits += 1;
                if (g_mesh_cache.head == null or g_mesh_cache.head.?.mesh_id.ptr != e.mesh_id.ptr) {
                    entry_detach(e);
                    entry_push_front(e);
                }
                return res;
            }
        }
        entry = e.next;
    }

    g_mesh_cache.cache_misses += 1;
    return null;
}

/// Inserts a mesh resource into the cache and retains it.
fn mesh_cache_put(mesh_id: [:0]const u8, resource: *ref_counting.CardinalRefCountedResource) void {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (!g_mesh_cache.initialized) {
        return;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    var it = g_mesh_cache.head;
    while (it) |e| {
        if (std.mem.eql(u8, e.mesh_id, mesh_id)) {
            if (g_mesh_cache.head == null or g_mesh_cache.head.?.mesh_id.ptr != e.mesh_id.ptr) {
                entry_detach(e);
                entry_push_front(e);
            }
            return;
        }
        it = e.next;
    }

    evict_tail_if_needed(allocator);

    const new_entry_ptr = memory.cardinal_alloc(allocator, @sizeOf(MeshCacheEntry));
    if (new_entry_ptr == null) return;
    const new_entry: *MeshCacheEntry = @ptrCast(@alignCast(new_entry_ptr));

    const id_len = mesh_id.len;
    const id_copy_ptr = memory.cardinal_alloc(allocator, id_len + 1);
    if (id_copy_ptr == null) {
        memory.cardinal_free(allocator, new_entry);
        return;
    }

    @memcpy(@as([*]u8, @ptrCast(id_copy_ptr))[0..id_len], mesh_id);
    @as([*]u8, @ptrCast(id_copy_ptr))[id_len] = 0;
    new_entry.mesh_id = @as([*:0]const u8, @ptrCast(id_copy_ptr))[0..id_len :0];

    new_entry.resource = resource;
    _ = ref_counting.cardinal_ref_acquire(resource.identifier);
    new_entry.mesh_bytes = entry_mesh_bytes(resource);
    g_mesh_cache.total_bytes += new_entry.mesh_bytes;
    if (g_mesh_cache.total_bytes > g_mesh_cache.peak_bytes) g_mesh_cache.peak_bytes = g_mesh_cache.total_bytes;

    new_entry.prev = null;
    new_entry.next = null;
    entry_push_front(new_entry);
    g_mesh_cache.entry_count += 1;
}

/// Produces a stable identifier for a mesh based on a small content hash.
fn generate_mesh_id(mesh: scene.CardinalMesh) ?[:0]const u8 {
    const prime: u64 = 1099511628211;
    var hash: u64 = 14695981039346656037;

    const update = struct {
        fn bytes(h: *u64, b: []const u8) void {
            for (b) |v| {
                h.* ^= v;
                h.* *%= prime;
            }
        }
    }.bytes;

    update(&hash, std.mem.asBytes(&mesh.vertex_count));
    update(&hash, std.mem.asBytes(&mesh.index_count));
    update(&hash, std.mem.asBytes(&mesh.material_index));
    update(&hash, std.mem.asBytes(&mesh.bounding_box_min));
    update(&hash, std.mem.asBytes(&mesh.bounding_box_max));

    const full_limit: usize = 4 * 1024 * 1024;

    if (mesh.vertices) |vertices| {
        if (mesh.vertex_count > 0) {
            const verts = vertices[0..mesh.vertex_count];
            const bytes_len: usize = @as(usize, mesh.vertex_count) * @sizeOf(scene.CardinalVertex);
            const bytes = @as([*]const u8, @ptrCast(verts.ptr))[0..bytes_len];
            if (bytes_len <= full_limit) {
                update(&hash, bytes);
            } else {
                const head_len: usize = @min(bytes_len, 4096);
                update(&hash, bytes[0..head_len]);
                if (bytes_len > head_len) {
                    const tail_len: usize = @min(bytes_len - head_len, 4096);
                    update(&hash, bytes[bytes_len - tail_len .. bytes_len]);
                }
            }
        }
    }

    if (mesh.indices) |indices| {
        if (mesh.index_count > 0) {
            const idx = indices[0..mesh.index_count];
            const bytes_len: usize = @as(usize, mesh.index_count) * @sizeOf(u32);
            const bytes = @as([*]const u8, @ptrCast(idx.ptr))[0..bytes_len];
            if (bytes_len <= full_limit) {
                update(&hash, bytes);
            } else {
                const head_len: usize = @min(bytes_len, 4096);
                update(&hash, bytes[0..head_len]);
                if (bytes_len > head_len) {
                    const tail_len: usize = @min(bytes_len - head_len, 4096);
                    update(&hash, bytes[bytes_len - tail_len .. bytes_len]);
                }
            }
        }
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const buf = memory.cardinal_alloc(allocator, 40);
    if (buf) |b| {
        const slice = @as([*]u8, @ptrCast(b))[0..40];
        const formatted = std.fmt.bufPrint(slice, "mesh_{x:0>16}\x00", .{hash}) catch {
            memory.cardinal_free(allocator, b);
            return null;
        };
        return @as([*:0]const u8, @ptrCast(b))[0 .. formatted.len - 1 :0];
    }
    return null;
}

fn mesh_data_destructor(data: ?*anyopaque) callconv(.c) void {
    if (data) |d| {
        mesh_log.debug("Freeing mesh at {any}", .{d});
        const mesh: *scene.CardinalMesh = @ptrCast(@alignCast(d));
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

        if (mesh.vertices) |v| {
            memory.cardinal_free(allocator, v);
        }
        if (mesh.indices) |i| {
            memory.cardinal_free(allocator, i);
        }
        memory.cardinal_free(allocator, mesh);
    }
}

pub export fn mesh_load_with_ref_counting(mesh_data: ?*const scene.CardinalMesh, out_mesh: ?*scene.CardinalMesh) callconv(.c) ?*ref_counting.CardinalRefCountedResource {
    if (mesh_data == null or out_mesh == null) {
        mesh_log.err("mesh_load_with_ref_counting: invalid args", .{});
        return null;
    }

    if (!g_mesh_cache.initialized) {
        _ = mesh_cache_init(128);
    }

    const mesh_id_slice = generate_mesh_id(mesh_data.?.*);
    if (mesh_id_slice == null) {
        mesh_log.err("Failed to generate mesh ID", .{});
        return null;
    }
    const mesh_id = mesh_id_slice.?;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    defer memory.cardinal_free(allocator, @ptrCast(@constCast(mesh_id.ptr)));

    if (mesh_cache_get(mesh_id)) |ref_resource| {
        const existing_mesh: *scene.CardinalMesh = @ptrCast(@alignCast(ref_resource.resource.?));
        out_mesh.?.* = existing_mesh.*;
        mesh_log.debug_s(.{ .mesh_id = mesh_id, .ref_count = ref_counting.cardinal_ref_get_count(ref_resource) }, "Reusing cached mesh", .{});
        return ref_resource;
    }

    if (ref_counting.cardinal_ref_acquire(mesh_id.ptr)) |ref_resource| {
        const existing_mesh: *scene.CardinalMesh = @ptrCast(@alignCast(ref_resource.resource.?));
        out_mesh.?.* = existing_mesh.*;
        mesh_cache_put(mesh_id, ref_resource);
        mesh_log.debug_s(.{ .mesh_id = mesh_id, .ref_count = ref_counting.cardinal_ref_get_count(ref_resource) }, "Reusing registry mesh", .{});
        return ref_resource;
    }

    const mesh_copy_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalMesh));
    if (mesh_copy_ptr == null) {
        mesh_log.err("Failed to allocate memory for mesh copy", .{});
        return null;
    }
    const mesh_copy: *scene.CardinalMesh = @ptrCast(@alignCast(mesh_copy_ptr));
    mesh_copy.* = mesh_data.?.*;

    if (mesh_data.?.vertices) |vertices| {
        if (mesh_data.?.vertex_count > 0) {
            const vertex_size = mesh_data.?.vertex_count * @sizeOf(scene.CardinalVertex);
            const v_ptr = memory.cardinal_alloc(allocator, vertex_size);
            if (v_ptr == null) {
                memory.cardinal_free(allocator, mesh_copy);
                mesh_log.err("Failed to allocate memory for vertex data", .{});
                return null;
            }
            @memcpy(@as([*]u8, @ptrCast(v_ptr))[0..vertex_size], @as([*]const u8, @ptrCast(vertices))[0..vertex_size]);
            mesh_copy.vertices = @ptrCast(@alignCast(v_ptr));
        }
    }

    if (mesh_data.?.indices) |indices| {
        if (mesh_data.?.index_count > 0) {
            const index_size = mesh_data.?.index_count * @sizeOf(u32);
            const i_ptr = memory.cardinal_alloc(allocator, index_size);
            if (i_ptr == null) {
                if (mesh_copy.vertices) |v| memory.cardinal_free(allocator, v);
                memory.cardinal_free(allocator, mesh_copy);
                mesh_log.err("Failed to allocate memory for index data", .{});
                return null;
            }
            @memcpy(@as([*]u8, @ptrCast(i_ptr))[0..index_size], @as([*]const u8, @ptrCast(indices))[0..index_size]);
            mesh_copy.indices = @ptrCast(@alignCast(i_ptr));
        }
    }

    const ref_resource = ref_counting.cardinal_ref_create(mesh_id.ptr, mesh_copy, @sizeOf(scene.CardinalMesh), mesh_data_destructor);
    if (ref_resource == null) {
        mesh_log.err("Failed to register mesh: {s}", .{mesh_id});
        if (mesh_copy.vertices) |v| memory.cardinal_free(allocator, v);
        if (mesh_copy.indices) |i| memory.cardinal_free(allocator, i);
        memory.cardinal_free(allocator, mesh_copy);
        return null;
    }

    mesh_cache_put(mesh_id, ref_resource.?);
    out_mesh.?.* = mesh_copy.*;

    mesh_log.info_s(.{ .vertices = mesh_data.?.vertex_count, .indices = mesh_data.?.index_count }, "Registered new mesh", .{});
    return ref_resource;
}

pub export fn mesh_release_ref_counted(ref_resource: ?*ref_counting.CardinalRefCountedResource) callconv(.c) void {
    if (ref_resource) |r| {
        ref_counting.cardinal_ref_release(r);
    }
}

pub export fn mesh_data_free(mesh: ?*scene.CardinalMesh) callconv(.c) void {
    if (mesh) |m| {
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
        if (m.vertices) |v| {
            memory.cardinal_free(allocator, v);
            m.vertices = null;
        }
        if (m.indices) |i| {
            memory.cardinal_free(allocator, i);
            m.indices = null;
        }
        m.vertex_count = 0;
        m.index_count = 0;
    }
}

pub export fn mesh_load_async(mesh_data: ?*const scene.CardinalMesh, priority: async_loader.CardinalAsyncPriority, callback: async_loader.CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*async_loader.CardinalAsyncTask {
    if (mesh_data == null) {
        mesh_log.err("mesh_load_async: mesh_data is NULL", .{});
        return null;
    }

    mesh_log.debug("Starting async load for mesh", .{});

    return async_loader.cardinal_async_load_mesh(mesh_data, priority, callback, user_data);
}

pub export fn mesh_cache_initialize(max_entries: u32) callconv(.c) bool {
    return mesh_cache_init(max_entries);
}

pub export fn mesh_cache_shutdown_system() callconv(.c) void {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (!g_mesh_cache.initialized) return;

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    var entry = g_mesh_cache.head;
    while (entry) |e| {
        const next = e.next;
        memory.cardinal_free(allocator, @ptrCast(@constCast(e.mesh_id.ptr)));
        ref_counting.cardinal_ref_release(e.resource);
        g_mesh_cache.total_bytes -|= e.mesh_bytes;
        memory.cardinal_free(allocator, e);
        entry = next;
    }

    g_mesh_cache.head = null;
    g_mesh_cache.tail = null;
    g_mesh_cache.entry_count = 0;
    g_mesh_cache.initialized = false;
    mesh_log.info("Cache shutdown complete", .{});
}

pub const MeshCacheStats = extern struct {
    entry_count: u32,
    max_entries: u32,
    cache_hits: u32,
    cache_misses: u32,
};

pub export fn mesh_cache_get_stats() callconv(.c) MeshCacheStats {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (!g_mesh_cache.initialized) return std.mem.zeroes(MeshCacheStats);

    return .{
        .entry_count = g_mesh_cache.entry_count,
        .max_entries = g_mesh_cache.max_entries,
        .cache_hits = g_mesh_cache.cache_hits,
        .cache_misses = g_mesh_cache.cache_misses,
    };
}

pub export fn mesh_cache_clear() callconv(.c) void {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (!g_mesh_cache.initialized) return;

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    var entry = g_mesh_cache.head;
    while (entry) |e| {
        const next = e.next;
        memory.cardinal_free(allocator, @ptrCast(@constCast(e.mesh_id.ptr)));
        ref_counting.cardinal_ref_release(e.resource);
        g_mesh_cache.total_bytes -|= e.mesh_bytes;
        memory.cardinal_free(allocator, e);
        entry = next;
    }

    g_mesh_cache.head = null;
    g_mesh_cache.tail = null;
    g_mesh_cache.entry_count = 0;
    mesh_log.info("Cache cleared", .{});
}

pub export fn mesh_cache_get_memory_stats(total_bytes: ?*u64, peak_bytes: ?*u64) callconv(.c) void {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (total_bytes) |t| t.* = @intCast(g_mesh_cache.total_bytes);
    if (peak_bytes) |p| p.* = @intCast(g_mesh_cache.peak_bytes);
}
