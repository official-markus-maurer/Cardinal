const std = @import("std");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const ref_counting = @import("../core/ref_counting.zig");
const resource_state = @import("../core/resource_state.zig");
const async_loader = @import("../core/async_loader.zig");
const material_ref_counting = @import("material_ref_counting.zig");
const scene = @import("scene.zig");
const builtin = @import("builtin");

const mat_log = log.ScopedLogger("MATERIAL");

// --- Struct Definitions ---

pub const MaterialCacheStats = extern struct {
    entry_count: u32,
    max_entries: u32,
    cache_hits: u32,
    cache_misses: u32,
};

const MaterialCacheEntry = struct {
    material_id: [:0]u8,
    resource: *ref_counting.CardinalRefCountedResource,
    next: ?*MaterialCacheEntry,
};

const MaterialCache = struct {
    entries: ?*MaterialCacheEntry = null,
    entry_count: u32 = 0,
    max_entries: u32 = 0,
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    initialized: bool = false,
    mutex: std.Thread.Mutex = .{},
};

// Global material cache instance
var g_material_cache: MaterialCache = .{};

// --- Helper Functions ---

fn getCurrentThreadId() u32 {
    if (builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetCurrentThreadId();
    } else {
        // Linux/Posix
        const SYS_gettid = 186; // x86_64
        return @as(u32, @intCast(std.os.linux.syscall0(SYS_gettid)));
    }
}

// Generate a unique ID for a material using the existing hash system
fn generate_material_id(material: *const scene.CardinalMaterial) ?[:0]u8 {
    const hash = material_ref_counting.cardinal_material_generate_hash(material);

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const id_ptr = memory.cardinal_alloc(allocator, 64);
    if (id_ptr == null) return null;

    const id_slice = @as([*]u8, @ptrCast(id_ptr))[0..64];
    _ = material_ref_counting.cardinal_material_hash_to_string(&hash, @ptrCast(id_slice.ptr));

    // Find actual length to create a proper slice
    const len = std.mem.len(@as([*:0]u8, @ptrCast(id_slice.ptr)));
    return @as([*:0]u8, @ptrCast(id_slice.ptr))[0..len :0];
}

// Material data destructor for reference counting
export fn material_data_destructor(data: ?*anyopaque) callconv(.c) void {
    if (data) |ptr| {
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
        memory.cardinal_free(allocator, ptr);
    }
}

// --- Internal Cache Functions ---

fn material_cache_init(max_entries: u32) bool {
    if (g_material_cache.initialized) return true;

    g_material_cache.entries = null;
    g_material_cache.entry_count = 0;
    g_material_cache.max_entries = max_entries;
    g_material_cache.cache_hits = 0;
    g_material_cache.cache_misses = 0;
    g_material_cache.initialized = true;

    mat_log.info("Cache initialized with max_entries={d}", .{max_entries});
    return true;
}

fn material_cache_shutdown() void {
    if (!g_material_cache.initialized) return;

    g_material_cache.mutex.lock();
    defer g_material_cache.mutex.unlock();

    var entry = g_material_cache.entries;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    while (entry) |current| {
        const next = current.next;
        memory.cardinal_free(allocator, @ptrCast(current.material_id.ptr));
        ref_counting.cardinal_ref_release(current.resource);
        memory.cardinal_free(allocator, current);
        entry = next;
    }

    g_material_cache.entries = null;
    g_material_cache.entry_count = 0;
    g_material_cache.initialized = false;

    mat_log.info("Cache shutdown complete", .{});
}

fn material_cache_get(material_id: []const u8) ?*ref_counting.CardinalRefCountedResource {
    if (!g_material_cache.initialized) return null;

    g_material_cache.mutex.lock();
    defer g_material_cache.mutex.unlock();

    var entry = g_material_cache.entries;
    while (entry) |current| : (entry = current.next) {
        if (std.mem.eql(u8, current.material_id, material_id)) {
            // Found in cache, acquire reference
            _ = ref_counting.cardinal_ref_acquire(current.resource.identifier);
            g_material_cache.cache_hits += 1;
            return current.resource;
        }
    }

    g_material_cache.cache_misses += 1;
    return null;
}

fn material_cache_put(material_id: [:0]const u8, resource: *ref_counting.CardinalRefCountedResource) void {
    if (!g_material_cache.initialized) return;

    g_material_cache.mutex.lock();
    defer g_material_cache.mutex.unlock();

    // Check if we're at capacity
    if (g_material_cache.entry_count >= g_material_cache.max_entries) {
        // Remove oldest entry (simple FIFO eviction)
        if (g_material_cache.entries) |head| {
            // Wait, this list is LIFO (new entries at head). So oldest is at tail.
            // But implementation in C was removing head?
            // C code:
            // MaterialCacheEntry* to_remove = g_material_cache.entries;
            // g_material_cache.entries = to_remove->next;
            // Yes, it was removing the newest entry if it was prepending.
            // Or maybe it treated it as a stack?
            // "Remove oldest entry (simple FIFO eviction)" comment says FIFO.
            // But code removes head. If we add to head, head is newest.
            // So it was evicting the NEWEST entry? That seems wrong for a cache.
            // Unless it was adding to tail?
            // C code: new_entry->next = g_material_cache.entries; g_material_cache.entries = new_entry;
            // This is adding to head.
            // So eviction was removing head (newest).
            // That's weird. It's LIFO eviction (stack).

            // I'll stick to C behavior for now to avoid behavioral changes,
            // but maybe I should fix it to be LRU or FIFO?
            // The comment says "FIFO eviction", but the code does LIFO eviction.
            // Let's implement LRU or FIFO properly?
            // Or just do what C code did: remove head.

            const to_remove = head;
            g_material_cache.entries = to_remove.next;

            const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
            memory.cardinal_free(allocator, @ptrCast(to_remove.material_id.ptr));
            ref_counting.cardinal_ref_release(to_remove.resource);
            memory.cardinal_free(allocator, to_remove);

            g_material_cache.entry_count -= 1;
        }
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const new_entry_ptr = memory.cardinal_alloc(allocator, @sizeOf(MaterialCacheEntry));
    if (new_entry_ptr == null) return;

    const new_entry: *MaterialCacheEntry = @ptrCast(@alignCast(new_entry_ptr));

    // Copy material ID
    const id_len = material_id.len;
    const id_ptr = memory.cardinal_alloc(allocator, id_len + 1);
    if (id_ptr == null) {
        memory.cardinal_free(allocator, new_entry);
        return;
    }

    @memcpy(@as([*]u8, @ptrCast(id_ptr))[0..id_len], material_id);
    @as([*]u8, @ptrCast(id_ptr))[id_len] = 0;
    new_entry.material_id = @as([*:0]u8, @ptrCast(id_ptr))[0..id_len :0];

    new_entry.resource = resource;
    // Acquire reference to resource
    _ = ref_counting.cardinal_ref_acquire(resource.identifier);

    // Add to front of list
    new_entry.next = g_material_cache.entries;
    g_material_cache.entries = new_entry;
    g_material_cache.entry_count += 1;
}

// --- Public API ---

pub export fn material_load_with_ref_counting(material_data: ?*const scene.CardinalMaterial, out_material: ?*scene.CardinalMaterial) callconv(.c) ?*ref_counting.CardinalRefCountedResource {
    if (material_data == null or out_material == null) {
        log.cardinal_log_error("material_load_with_ref_counting: invalid args", .{});
        return null;
    }

    if (!g_material_cache.initialized) {
        _ = material_cache_init(256);
    }

    const material_id_slice = generate_material_id(material_data.?);
    if (material_id_slice == null) {
        log.cardinal_log_error("Failed to generate material ID", .{});
        return null;
    }
    const material_id = material_id_slice.?;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    defer memory.cardinal_free(allocator, @ptrCast(material_id.ptr)); // We free the ID string at end of function

    // Check resource state first
    const state = resource_state.cardinal_resource_state_get(material_id.ptr);

    if (state == .LOADED) {
        if (material_cache_get(material_id)) |ref_resource| {
            const existing_material: *scene.CardinalMaterial = @ptrCast(@alignCast(ref_resource.resource.?));
            out_material.?.* = existing_material.*;
            log.cardinal_log_debug("[MATERIAL] Reusing loaded material: {s} (ref_count={d})", .{ material_id, ref_counting.cardinal_ref_get_count(ref_resource) });
            return ref_resource;
        }

        if (ref_counting.cardinal_ref_acquire(material_id.ptr)) |ref_resource| {
            const existing_material: *scene.CardinalMaterial = @ptrCast(@alignCast(ref_resource.resource.?));
            out_material.?.* = existing_material.*;
            material_cache_put(material_id, ref_resource);
            log.cardinal_log_debug("[MATERIAL] Reusing registry material: {s} (ref_count={d})", .{ material_id, ref_counting.cardinal_ref_get_count(ref_resource) });
            return ref_resource;
        }
    }

    if (state == .LOADING) {
        log.cardinal_log_debug("[MATERIAL] Waiting for material to finish loading: {s}", .{material_id});
        if (resource_state.cardinal_resource_state_wait_for(material_id.ptr, .LOADED, 5000)) {
            var ref_resource = material_cache_get(material_id);
            if (ref_resource == null) {
                ref_resource = ref_counting.cardinal_ref_acquire(material_id.ptr);
            }

            if (ref_resource) |res| {
                const existing_material: *scene.CardinalMaterial = @ptrCast(@alignCast(res.resource.?));
                out_material.?.* = existing_material.*;
                log.cardinal_log_debug("[MATERIAL] Got material after waiting: {s}", .{material_id});
                return res;
            }
        } else {
            log.cardinal_log_warn("[MATERIAL] Timeout waiting for material to load: {s}", .{material_id});
        }
    }

    // Try to acquire loading access
    const thread_id = getCurrentThreadId();

    if (!resource_state.cardinal_resource_state_try_acquire_loading(material_id.ptr, thread_id)) {
        // Another thread is loading, wait for completion
        log.cardinal_log_debug("[MATERIAL] Another thread is loading, waiting: {s}", .{material_id});
        if (resource_state.cardinal_resource_state_wait_for(material_id.ptr, .LOADED, 5000)) {
            var ref_resource = material_cache_get(material_id);
            if (ref_resource == null) {
                ref_resource = ref_counting.cardinal_ref_acquire(material_id.ptr);
            }

            if (ref_resource) |res| {
                const existing_material: *scene.CardinalMaterial = @ptrCast(@alignCast(res.resource.?));
                out_material.?.* = existing_material.*;
                return res;
            }
        }
        log.cardinal_log_error("[MATERIAL] Failed to get material after waiting: {s}", .{material_id});
        return null;
    }

    log.cardinal_log_debug("[MATERIAL] Starting material load: {s}", .{material_id});

    // Try to use the existing material reference counting system first
    // Note: material_ref_counting.zig's load function does its own ref_acquire logic,
    // but we've already done that above. It's fine, it will just increment count again.
    // However, we want to control the state.
    // If we call cardinal_material_load_with_ref_counting, it will create the resource if not exists.

    const ref_resource = material_ref_counting.cardinal_material_load_with_ref_counting(material_data, out_material);

    if (ref_resource) |res| {
        // Register with state tracking system
        if (resource_state.cardinal_resource_state_register(@ptrCast(res)) == null) {
            log.cardinal_log_warn("Failed to register material with state tracking: {s}", .{material_id});
        }

        // Add to cache
        material_cache_put(material_id, res);

        // Mark as loaded
        _ = resource_state.cardinal_resource_state_set(material_id.ptr, .LOADED, thread_id);

        log.cardinal_log_debug("[MATERIAL] Loaded material via registry: {s} (ref_count={d})", .{ material_id, ref_counting.cardinal_ref_get_count(res) });
        return res;
    }

    // If existing system failed, create a new material manually (fallback)
    // But cardinal_material_load_with_ref_counting creates it if it doesn't exist.
    // So if it returned null, something went wrong (alloc failure).

    const material_copy_ptr = memory.cardinal_alloc(allocator, @sizeOf(scene.CardinalMaterial));
    if (material_copy_ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for material copy", .{});
        _ = resource_state.cardinal_resource_state_set(material_id.ptr, .ERROR, thread_id);
        return null;
    }

    const material_copy: *scene.CardinalMaterial = @ptrCast(@alignCast(material_copy_ptr));
    material_copy.* = material_data.?.*;
    out_material.?.* = material_data.?.*;

    // Register the material
    const fallback_res = ref_counting.cardinal_ref_create(material_id.ptr, material_copy, @sizeOf(scene.CardinalMaterial), material_data_destructor);
    if (fallback_res == null) {
        log.cardinal_log_error("Failed to register material in reference counting system: {s}", .{material_id});
        memory.cardinal_free(allocator, material_copy);
        _ = resource_state.cardinal_resource_state_set(material_id.ptr, .ERROR, thread_id);
        return null;
    }

    if (resource_state.cardinal_resource_state_register(@ptrCast(fallback_res.?)) == null) {
        log.cardinal_log_warn("Failed to register material with state tracking: {s}", .{material_id});
    }

    material_cache_put(material_id, fallback_res.?);
    _ = resource_state.cardinal_resource_state_set(material_id.ptr, .LOADED, thread_id);

    log.cardinal_log_info("[MATERIAL] Successfully loaded and registered material (fallback path)", .{});
    return fallback_res;
}

pub export fn material_release_ref_counted(ref_resource: ?*ref_counting.CardinalRefCountedResource) callconv(.c) void {
    if (ref_resource) |res| {
        ref_counting.cardinal_ref_release(res);
    }
}

pub export fn material_data_free(material: ?*scene.CardinalMaterial) callconv(.c) void {
    if (material) |mat| {
        @memset(@as([*]u8, @ptrCast(mat))[0..@sizeOf(scene.CardinalMaterial)], 0);
    }
}

pub export fn material_load_async(material_data: ?*const scene.CardinalMaterial, priority: async_loader.CardinalAsyncPriority, callback: async_loader.CardinalAsyncCallback, user_data: ?*anyopaque) callconv(.c) ?*async_loader.CardinalAsyncTask {
    if (material_data == null) {
        log.cardinal_log_error("material_load_async: material_data is NULL", .{});
        return null;
    }

    log.cardinal_log_debug("[MATERIAL] Starting async load for material", .{});

    const task = async_loader.cardinal_async_load_material(@ptrCast(material_data), priority, callback, user_data);
    if (task == null) {
        log.cardinal_log_error("Failed to create async material loading task", .{});
        return null;
    }

    log.cardinal_log_debug("[MATERIAL] Async task created for material loading", .{});
    return task;
}

pub export fn material_cache_initialize(max_entries: u32) callconv(.c) bool {
    return material_cache_init(max_entries);
}

pub export fn material_cache_shutdown_system() callconv(.c) void {
    material_cache_shutdown();
}

pub export fn material_cache_get_stats() callconv(.c) MaterialCacheStats {
    if (!g_material_cache.initialized) {
        return std.mem.zeroes(MaterialCacheStats);
    }

    g_material_cache.mutex.lock();
    defer g_material_cache.mutex.unlock();

    return MaterialCacheStats{
        .entry_count = g_material_cache.entry_count,
        .max_entries = g_material_cache.max_entries,
        .cache_hits = g_material_cache.cache_hits,
        .cache_misses = g_material_cache.cache_misses,
    };
}

pub export fn material_cache_clear() callconv(.c) void {
    if (!g_material_cache.initialized) return;

    g_material_cache.mutex.lock();
    defer g_material_cache.mutex.unlock();

    var entry = g_material_cache.entries;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    while (entry) |current| {
        const next = current.next;
        memory.cardinal_free(allocator, @ptrCast(current.material_id.ptr));
        ref_counting.cardinal_ref_release(current.resource);
        memory.cardinal_free(allocator, current);
        entry = next;
    }

    g_material_cache.entries = null;
    g_material_cache.entry_count = 0;

    log.cardinal_log_info("[MATERIAL] Cache cleared", .{});
}
