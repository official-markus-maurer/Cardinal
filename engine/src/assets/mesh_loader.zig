const std = @import("std");
const scene = @import("scene.zig");
const ref_counting = @import("../core/ref_counting.zig");
const async_loader = @import("../core/async_loader.zig");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");

// Thread-safe mesh cache
const MeshCacheEntry = struct {
    mesh_id: [:0]const u8,
    resource: *ref_counting.CardinalRefCountedResource,
    next: ?*MeshCacheEntry,
};

const MeshCache = struct {
    entries: ?*MeshCacheEntry,
    entry_count: u32,
    max_entries: u32,
    cache_hits: u32,
    cache_misses: u32,
    initialized: bool,
    mutex: std.Thread.Mutex,
};

var g_mesh_cache: MeshCache = .{
    .entries = null,
    .entry_count = 0,
    .max_entries = 0,
    .cache_hits = 0,
    .cache_misses = 0,
    .initialized = false,
    .mutex = .{},
};

// Initialize the mesh cache
fn mesh_cache_init(max_entries: u32) bool {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (g_mesh_cache.initialized) {
        return true;
    }

    g_mesh_cache.entries = null;
    g_mesh_cache.entry_count = 0;
    g_mesh_cache.max_entries = max_entries;
    g_mesh_cache.cache_hits = 0;
    g_mesh_cache.cache_misses = 0;
    g_mesh_cache.initialized = true;

    log.cardinal_log_info("[MESH] Cache initialized with max_entries={d}", .{max_entries});
    return true;
}

// Get mesh from cache
fn mesh_cache_get(mesh_id: []const u8) ?*ref_counting.CardinalRefCountedResource {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (!g_mesh_cache.initialized) {
        return null;
    }

    var entry = g_mesh_cache.entries;
    while (entry) |e| {
        if (std.mem.eql(u8, e.mesh_id, mesh_id)) {
            // Found in cache, acquire reference
            if (ref_counting.cardinal_ref_acquire(e.resource.identifier)) |res| {
                g_mesh_cache.cache_hits += 1;
                return res;
            }
        }
        entry = e.next;
    }

    g_mesh_cache.cache_misses += 1;
    return null;
}

// Add mesh to cache
fn mesh_cache_put(mesh_id: [:0]const u8, resource: *ref_counting.CardinalRefCountedResource) void {
    g_mesh_cache.mutex.lock();
    defer g_mesh_cache.mutex.unlock();

    if (!g_mesh_cache.initialized) {
        return;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    // Check if we're at capacity
    if (g_mesh_cache.entry_count >= g_mesh_cache.max_entries) {
        // Remove tail (FIFO/LRU approximation)
        var prev: ?*MeshCacheEntry = null;
        var curr = g_mesh_cache.entries;
        
        // Find tail
        while (curr) |c| {
            if (c.next == null) break;
            prev = c;
            curr = c.next;
        }
        
        if (curr) |to_remove| {
            if (prev) |p| {
                p.next = null;
            } else {
                g_mesh_cache.entries = null;
            }
            
            memory.cardinal_free(allocator, @ptrCast(@constCast(to_remove.mesh_id.ptr)));
            ref_counting.cardinal_ref_release(to_remove.resource);
            memory.cardinal_free(allocator, to_remove);
            g_mesh_cache.entry_count -= 1;
        }
    }

    // Create new entry
    const new_entry_ptr = memory.cardinal_alloc(allocator, @sizeOf(MeshCacheEntry));
    if (new_entry_ptr == null) return;
    const new_entry: *MeshCacheEntry = @ptrCast(@alignCast(new_entry_ptr));

    // Copy mesh ID
    const id_len = mesh_id.len;
    const id_copy_ptr = memory.cardinal_alloc(allocator, id_len + 1);
    if (id_copy_ptr == null) {
        memory.cardinal_free(allocator, new_entry);
        return;
    }
    
    @memcpy(@as([*]u8, @ptrCast(id_copy_ptr))[0..id_len], mesh_id);
    @as([*]u8, @ptrCast(id_copy_ptr))[id_len] = 0;
    new_entry.mesh_id = @as([*:0]const u8, @ptrCast(id_copy_ptr))[0..id_len :0];

    // Acquire reference to resource
    new_entry.resource = resource;
    _ = ref_counting.cardinal_ref_acquire(resource.identifier);

    // Add to front of list
    new_entry.next = g_mesh_cache.entries;
    g_mesh_cache.entries = new_entry;
    g_mesh_cache.entry_count += 1;
}

fn generate_mesh_id(mesh: scene.CardinalMesh) ?[:0]const u8 {
    var hash: u32 = 0;
    hash ^= mesh.vertex_count;
    hash ^= mesh.index_count << 16;
    hash ^= mesh.material_index;

    // Hash some vertex data if available
    if (mesh.vertices) |vertices| {
        if (mesh.vertex_count > 0) {
            var i: u32 = 0;
            while (i < mesh.vertex_count and i < 10) : (i += 1) {
                // Hash the bytes of the vertex
                const v = vertices[i];
                const v_bytes = std.mem.asBytes(&v);
                // Use a simple hash for bytes
                var h: u32 = 5381;
                for (v_bytes) |b| {
                    h = ((h << 5) + h) + b;
                }
                hash ^= h;
            }
        }
    }

    // Hash some index data if available
    if (mesh.indices) |indices| {
        if (mesh.index_count > 0) {
            var i: u32 = 0;
            while (i < mesh.index_count and i < 10) : (i += 1) {
                hash ^= indices[i];
            }
        }
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    // 32 chars is enough for "mesh_" + 8 hex digits + null
    const buf = memory.cardinal_alloc(allocator, 32);
    if (buf) |b| {
        const slice = @as([*]u8, @ptrCast(b))[0..32];
        // We use bufPrint with \x00 to ensure it writes a null byte
        const formatted = std.fmt.bufPrint(slice, "mesh_{x:0>8}\x00", .{hash}) catch {
            memory.cardinal_free(allocator, b);
            return null;
        };
        // formatted includes the \x00 at the end.
        // Return slice excluding the \x00 but with sentinel
        return @as([*:0]const u8, @ptrCast(b))[0..formatted.len-1 :0];
    }
    return null;
}

fn mesh_data_destructor(data: ?*anyopaque) callconv(.c) void {
    if (data) |d| {
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
        log.cardinal_log_error("mesh_load_with_ref_counting: invalid args", .{});
        return null;
    }

    // Initialize cache
    if (!g_mesh_cache.initialized) {
        _ = mesh_cache_init(128);
    }

    const mesh_id_slice = generate_mesh_id(mesh_data.?.*);
    if (mesh_id_slice == null) {
        log.cardinal_log_error("Failed to generate mesh ID", .{});
        return null;
    }
    const mesh_id = mesh_id_slice.?;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    defer memory.cardinal_free(allocator, @ptrCast(@constCast(mesh_id.ptr))); // Free ID at end

    // Try cache
    if (mesh_cache_get(mesh_id)) |ref_resource| {
        const existing_mesh: *scene.CardinalMesh = @ptrCast(@alignCast(ref_resource.resource.?));
        out_mesh.?.* = existing_mesh.*;
        log.cardinal_log_debug("[MESH] Reusing cached mesh: {s} (ref_count={d})", .{mesh_id, ref_counting.cardinal_ref_get_count(ref_resource)});
        return ref_resource;
    }

    // Try registry
    if (ref_counting.cardinal_ref_acquire(mesh_id.ptr)) |ref_resource| {
        const existing_mesh: *scene.CardinalMesh = @ptrCast(@alignCast(ref_resource.resource.?));
        out_mesh.?.* = existing_mesh.*;
        mesh_cache_put(mesh_id, ref_resource);
        log.cardinal_log_debug("[MESH] Reusing registry mesh: {s} (ref_count={d})", .{mesh_id, ref_counting.cardinal_ref_get_count(ref_resource)});
        return ref_resource;
    }

    // Create deep copy
    const mesh_copy_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalMesh));
    if (mesh_copy_ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for mesh copy", .{});
        return null;
    }
    const mesh_copy: *scene.CardinalMesh = @ptrCast(@alignCast(mesh_copy_ptr));
    mesh_copy.* = mesh_data.?.*;

    // Deep copy vertices
    if (mesh_data.?.vertices) |vertices| {
        if (mesh_data.?.vertex_count > 0) {
            const vertex_size = mesh_data.?.vertex_count * @sizeOf(scene.CardinalVertex);
            const v_ptr = memory.cardinal_alloc(allocator, vertex_size);
            if (v_ptr == null) {
                memory.cardinal_free(allocator, mesh_copy);
                log.cardinal_log_error("Failed to allocate memory for vertex data", .{});
                return null;
            }
            @memcpy(@as([*]u8, @ptrCast(v_ptr))[0..vertex_size], @as([*]const u8, @ptrCast(vertices))[0..vertex_size]);
            mesh_copy.vertices = @ptrCast(@alignCast(v_ptr));
        }
    }

    // Deep copy indices
    if (mesh_data.?.indices) |indices| {
        if (mesh_data.?.index_count > 0) {
            const index_size = mesh_data.?.index_count * @sizeOf(u32);
            const i_ptr = memory.cardinal_alloc(allocator, index_size);
            if (i_ptr == null) {
                if (mesh_copy.vertices) |v| memory.cardinal_free(allocator, v);
                memory.cardinal_free(allocator, mesh_copy);
                log.cardinal_log_error("Failed to allocate memory for index data", .{});
                return null;
            }
            @memcpy(@as([*]u8, @ptrCast(i_ptr))[0..index_size], @as([*]const u8, @ptrCast(indices))[0..index_size]);
            mesh_copy.indices = @ptrCast(@alignCast(i_ptr));
        }
    }

    // Register
    const ref_resource = ref_counting.cardinal_ref_create(mesh_id.ptr, mesh_copy, @sizeOf(scene.CardinalMesh), mesh_data_destructor);
    if (ref_resource == null) {
        log.cardinal_log_error("Failed to register mesh: {s}", .{mesh_id});
         if (mesh_copy.vertices) |v| memory.cardinal_free(allocator, v);
         if (mesh_copy.indices) |i| memory.cardinal_free(allocator, i);
        memory.cardinal_free(allocator, mesh_copy);
        return null;
    }

    mesh_cache_put(mesh_id, ref_resource.?);
    out_mesh.?.* = mesh_copy.*;

    log.cardinal_log_info("[MESH] Registered new mesh: vertices={d}, indices={d}", .{mesh_data.?.vertex_count, mesh_data.?.index_count});
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
        log.cardinal_log_error("mesh_load_async: mesh_data is NULL", .{});
        return null;
    }

    log.cardinal_log_debug("[MESH] Starting async load for mesh", .{});
    
    // In C: return cardinal_async_load_mesh(mesh_data, priority, callback, user_data);
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
    var entry = g_mesh_cache.entries;
    while (entry) |e| {
        const next = e.next;
        memory.cardinal_free(allocator, @ptrCast(@constCast(e.mesh_id.ptr)));
        ref_counting.cardinal_ref_release(e.resource);
        memory.cardinal_free(allocator, e);
        entry = next;
    }

    g_mesh_cache.entries = null;
    g_mesh_cache.entry_count = 0;
    g_mesh_cache.initialized = false;
    log.cardinal_log_info("[MESH] Cache shutdown complete", .{});
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
    var entry = g_mesh_cache.entries;
    while (entry) |e| {
        const next = e.next;
        memory.cardinal_free(allocator, @ptrCast(@constCast(e.mesh_id.ptr)));
        ref_counting.cardinal_ref_release(e.resource);
        memory.cardinal_free(allocator, e);
        entry = next;
    }

    g_mesh_cache.entries = null;
    g_mesh_cache.entry_count = 0;
    log.cardinal_log_info("[MESH] Cache cleared", .{});
}
