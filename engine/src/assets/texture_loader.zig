const std = @import("std");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const ref_counting = @import("../core/ref_counting.zig");
const async_loader = @import("../core/async_loader.zig");

// Import C functions from resource_state.h (not yet ported)
const CardinalResourceState = enum(c_int) {
    UNKNOWN = 0,
    LOADING = 1,
    LOADED = 2,
    ERROR = 3,
};

// Opaque types for C pointers
const CardinalResourceStateTracker = opaque {};

extern fn cardinal_resource_state_get(identifier: [*]const u8) CardinalResourceState;
extern fn cardinal_resource_state_wait_for(identifier: [*]const u8, state: CardinalResourceState, timeout_ms: u32) bool;
extern fn cardinal_resource_state_register(resource: *ref_counting.CardinalRefCountedResource) ?*CardinalResourceStateTracker;
extern fn cardinal_resource_state_try_acquire_loading(identifier: [*]const u8, thread_id: u32) bool;
extern fn cardinal_resource_state_set(identifier: [*]const u8, state: CardinalResourceState, thread_id: u32) void;

// Import STB functions
extern fn stbi_load(filename: [*]const u8, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbi_failure_reason() ?[*]const u8;
extern fn stbi_set_flip_vertically_on_load(flag_true_if_should_flip: c_int) void;

// System calls for thread ID
const builtin = @import("builtin");
fn getCurrentThreadId() u32 {
    if (builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetCurrentThreadId();
    } else {
        // Linux/Posix
        // Using libc syscall
        const SYS_gettid = 186; // x86_64
        return @as(u32, @intCast(std.os.linux.syscall0(SYS_gettid)));
    }
}

pub const TextureData = extern struct {
    data: ?[*]u8,
    width: u32,
    height: u32,
    channels: u32,
};

pub const TextureCacheStats = extern struct {
    entry_count: u32,
    max_entries: u32,
    cache_hits: u32,
    cache_misses: u32,
};

const TextureCacheEntry = struct {
    filepath: []const u8,
    resource: *ref_counting.CardinalRefCountedResource,
    last_access_time: u64,
    memory_usage: u64,
    next: ?*TextureCacheEntry,
    prev: ?*TextureCacheEntry,
};

const TextureCache = struct {
    head: ?*TextureCacheEntry = null,
    tail: ?*TextureCacheEntry = null,
    entry_count: u32 = 0,
    max_entries: u32 = 0,
    total_memory_usage: u64 = 0,
    max_memory_usage: u64 = 512 * 1024 * 1024,
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    evictions: u32 = 0,
    mutex: std.Thread.Mutex = .{},
    initialized: bool = false,
};

var g_texture_cache: TextureCache = .{};

// C API exports

pub export fn texture_cache_initialize(max_entries: u32) bool {
    if (g_texture_cache.initialized) return true;
    
    g_texture_cache.head = null;
    g_texture_cache.tail = null;
    g_texture_cache.entry_count = 0;
    g_texture_cache.max_entries = max_entries;
    g_texture_cache.total_memory_usage = 0;
    g_texture_cache.max_memory_usage = 512 * 1024 * 1024;
    g_texture_cache.cache_hits = 0;
    g_texture_cache.cache_misses = 0;
    g_texture_cache.evictions = 0;
    g_texture_cache.initialized = true;
    
    log.cardinal_log_info("[TEXTURE] LRU texture cache initialized (max_entries={d}, max_memory={d} MB)", .{max_entries, g_texture_cache.max_memory_usage / (1024 * 1024)});
    return true;
}

pub export fn texture_cache_shutdown_system() void {
    if (!g_texture_cache.initialized) return;
    
    g_texture_cache.mutex.lock();
    defer g_texture_cache.mutex.unlock();
    
    var entry = g_texture_cache.head;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    
    while (entry) |current| {
        const next = current.next;
        
        // Free filepath (allocated via cardinal_alloc)
        memory.cardinal_free(allocator, @ptrCast(@constCast(current.filepath.ptr)));
        
        // Release resource
        ref_counting.cardinal_ref_release(current.resource);
        
        // Free entry
        memory.cardinal_free(allocator, current);
        
        entry = next;
    }
    
    g_texture_cache.head = null;
    g_texture_cache.tail = null;
    g_texture_cache.entry_count = 0;
    g_texture_cache.total_memory_usage = 0;
    g_texture_cache.initialized = false;
    
    log.cardinal_log_info("[TEXTURE] Thread-safe texture cache shutdown", .{});
}

pub export fn texture_cache_get_stats() TextureCacheStats {
    if (!g_texture_cache.initialized) return std.mem.zeroes(TextureCacheStats);
    
    g_texture_cache.mutex.lock();
    defer g_texture_cache.mutex.unlock();
    
    return .{
        .entry_count = g_texture_cache.entry_count,
        .max_entries = g_texture_cache.max_entries,
        .cache_hits = g_texture_cache.cache_hits,
        .cache_misses = g_texture_cache.cache_misses,
    };
}

pub export fn texture_cache_clear() void {
    if (!g_texture_cache.initialized) return;
    
    g_texture_cache.mutex.lock();
    defer g_texture_cache.mutex.unlock();
    
    var entry = g_texture_cache.head;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    
    while (entry) |current| {
        const next = current.next;
        memory.cardinal_free(allocator, @ptrCast(@constCast(current.filepath.ptr)));
        ref_counting.cardinal_ref_release(current.resource);
        memory.cardinal_free(allocator, current);
        entry = next;
    }
    
    g_texture_cache.head = null;
    g_texture_cache.tail = null;
    g_texture_cache.entry_count = 0;
    g_texture_cache.total_memory_usage = 0;
    
    log.cardinal_log_info("[TEXTURE] Cache cleared", .{});
}

// Internal cache helpers
fn get_current_time_ms() u64 {
    return @as(u64, @intCast(std.time.milliTimestamp()));
}

fn move_to_head(entry: *TextureCacheEntry) void {
    if (entry == g_texture_cache.head) return;
    
    // Remove from current position
    if (entry.prev) |prev| {
        prev.next = entry.next;
    }
    if (entry.next) |next| {
        next.prev = entry.prev;
    }
    if (entry == g_texture_cache.tail) {
        g_texture_cache.tail = entry.prev;
    }
    
    // Move to head
    entry.prev = null;
    entry.next = g_texture_cache.head;
    if (g_texture_cache.head) |head| {
        head.prev = entry;
    }
    g_texture_cache.head = entry;
    
    if (g_texture_cache.tail == null) {
        g_texture_cache.tail = entry;
    }
}

fn remove_from_list(entry: *TextureCacheEntry) void {
    if (entry.prev) |prev| {
        prev.next = entry.next;
    } else {
        g_texture_cache.head = entry.next;
    }
    
    if (entry.next) |next| {
        next.prev = entry.prev;
    } else {
        g_texture_cache.tail = entry.prev;
    }
    
    entry.prev = null;
    entry.next = null;
}

fn texture_cache_get(filepath: []const u8) ?*ref_counting.CardinalRefCountedResource {
    if (!g_texture_cache.initialized) return null;
    
    g_texture_cache.mutex.lock();
    defer g_texture_cache.mutex.unlock();
    
    var entry = g_texture_cache.head;
    while (entry) |current| : (entry = current.next) {
        if (std.mem.eql(u8, current.filepath, filepath)) {
            current.last_access_time = get_current_time_ms();
            move_to_head(current);
            
            // Increment ref count
            _ = @atomicRmw(u32, &current.resource.ref_count, .Add, 1, .seq_cst);
            g_texture_cache.cache_hits += 1;
            
            log.cardinal_log_debug("[TEXTURE] Cache hit for {s} (memory usage: {d} bytes)", .{filepath, current.memory_usage});
            return current.resource;
        }
    }
    
    g_texture_cache.cache_misses += 1;
    return null;
}

fn texture_cache_put(filepath: []const u8, resource: *ref_counting.CardinalRefCountedResource) bool {
    if (!g_texture_cache.initialized) return false;
    
    const texture_data: *TextureData = @ptrCast(@alignCast(resource.resource.?));
    const texture_memory: u64 = @as(u64, texture_data.width) * texture_data.height * texture_data.channels;
    
    g_texture_cache.mutex.lock();
    defer g_texture_cache.mutex.unlock();
    
    // Evict entries
    while ((g_texture_cache.total_memory_usage + texture_memory > g_texture_cache.max_memory_usage or 
            g_texture_cache.entry_count >= g_texture_cache.max_entries) and 
           g_texture_cache.tail != null) {
        const to_remove = g_texture_cache.tail.?;
        remove_from_list(to_remove);
        
        g_texture_cache.total_memory_usage -= to_remove.memory_usage;
        g_texture_cache.entry_count -= 1;
        g_texture_cache.evictions += 1;
        
        log.cardinal_log_debug("[TEXTURE] Evicted {s} (freed {d} bytes, total: {d}/{d} bytes)", 
            .{to_remove.filepath, to_remove.memory_usage, g_texture_cache.total_memory_usage, g_texture_cache.max_memory_usage});
        
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
        memory.cardinal_free(allocator, @ptrCast(@constCast(to_remove.filepath.ptr)));
        ref_counting.cardinal_ref_release(to_remove.resource);
        memory.cardinal_free(allocator, to_remove);
    }
    
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    
    // Allocate new entry
    const entry_ptr = memory.cardinal_alloc(allocator, @sizeOf(TextureCacheEntry));
    if (entry_ptr == null) {
        log.cardinal_log_error("[TEXTURE] Failed to allocate cache entry for {s}", .{filepath});
        return false;
    }
    const new_entry: *TextureCacheEntry = @ptrCast(@alignCast(entry_ptr));
    
    // Copy filepath
    const filepath_ptr = memory.cardinal_alloc(allocator, filepath.len + 1);
    if (filepath_ptr == null) {
        log.cardinal_log_error("[TEXTURE] Failed to allocate filepath for {s}", .{filepath});
        memory.cardinal_free(allocator, entry_ptr);
        return false;
    }
    const new_filepath = @as([*]u8, @ptrCast(filepath_ptr))[0..filepath.len+1];
    @memcpy(new_filepath[0..filepath.len], filepath);
    new_filepath[filepath.len] = 0;
    
    new_entry.* = .{
        .filepath = new_filepath[0..filepath.len], // store slice excluding null terminator for convenience, but allocation includes it
        .resource = resource,
        .last_access_time = get_current_time_ms(),
        .memory_usage = texture_memory,
        .next = null,
        .prev = null,
    };
    
    // Increment ref count
    _ = @atomicRmw(u32, &resource.ref_count, .Add, 1, .seq_cst);
    
    // Add to head
    if (g_texture_cache.head) |head| {
        head.prev = new_entry;
        new_entry.next = g_texture_cache.head;
    } else {
        g_texture_cache.tail = new_entry;
    }
    g_texture_cache.head = new_entry;
    
    g_texture_cache.entry_count += 1;
    g_texture_cache.total_memory_usage += texture_memory;
    
    log.cardinal_log_debug("[TEXTURE] Cached {s} ({d} bytes, total: {d}/{d} bytes)", 
        .{filepath, texture_memory, g_texture_cache.total_memory_usage, g_texture_cache.max_memory_usage});
        
    return true;
}

// Destructor
export fn texture_data_destructor(resource: ?*anyopaque) callconv(.c) void {
    if (resource == null) {
        log.cardinal_log_warn("[CLEANUP] texture_data_destructor called with NULL resource", .{});
        return;
    }
    
    const texture: *TextureData = @ptrCast(@alignCast(resource));
    log.cardinal_log_debug("[CLEANUP] Destroying texture data at {*} (size: {d}x{d}, {d} channels)", 
        .{texture, texture.width, texture.height, texture.channels});
        
    if (texture.data) |data| {
        log.cardinal_log_debug("[CLEANUP] Freeing texture pixel data at {*}", .{data});
        stbi_image_free(data);
        texture.data = null;
        log.cardinal_log_debug("[CLEANUP] Texture pixel data freed and nullified", .{});
    } else {
        log.cardinal_log_warn("[CLEANUP] Texture data already NULL during destruction", .{});
    }
    
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    memory.cardinal_free(allocator, texture);
    log.cardinal_log_debug("[CLEANUP] Texture structure freed", .{});
}

pub export fn texture_data_free(texture: ?*TextureData) void {
    if (texture == null) {
        log.cardinal_log_warn("[CLEANUP] texture_data_free called with NULL texture", .{});
        return;
    }
    const t = texture.?;
    
    log.cardinal_log_debug("[CLEANUP] Freeing texture data at {*}", .{t});
    
    if (t.data) |data| {
        stbi_image_free(data);
        t.data = null;
    }
    
    t.width = 0;
    t.height = 0;
    t.channels = 0;
}

pub export fn texture_load_from_file(filepath: ?[*]const u8, out_texture: ?*TextureData) bool {
    if (filepath == null or out_texture == null) {
        log.cardinal_log_error("[TEXTURE] texture_load_from_file: invalid args", .{});
        return false;
    }
    const filename_c: [*:0]const u8 = @ptrCast(filepath.?);
    const path = std.mem.span(filename_c);
    const texture = out_texture.?;
    
    // Clear struct
    texture.* = std.mem.zeroes(TextureData);
    
    log.cardinal_log_info("[TEXTURE] Attempting to load texture: {s}", .{path});
    
    // Check file existence (optional but matches C logic)
    const file = std.fs.cwd().openFile(path, .{}) catch {
        log.cardinal_log_error("[CRITICAL] Cannot access file: {s}", .{path});
        return false;
    };
    file.close();
    
    stbi_set_flip_vertically_on_load(0);
    
    var w: c_int = 0;
    var h: c_int = 0;
    var c: c_int = 0;
    
    // Cast to [*:0]const u8 for stbi_load
    const data = stbi_load(filename_c, &w, &h, &c, 4);
    if (data == null) {
        const reason = stbi_failure_reason();
        log.cardinal_log_error("[CRITICAL] Failed to load image: {s}", .{path});
        if (reason) |r| {
             const r_c: [*:0]const u8 = @ptrCast(r);
             log.cardinal_log_error("[CRITICAL] STB failure reason: {s}", .{std.mem.span(r_c)});
        }
        return false;
    }
    
    if (w <= 0 or h <= 0 or w > 16384 or h > 16384) {
        log.cardinal_log_error("[CRITICAL] Invalid dimensions: {d}x{d} for {s}", .{w, h, path});
        stbi_image_free(data);
        return false;
    }
    
    texture.data = data;
    texture.width = @intCast(w);
    texture.height = @intCast(h);
    texture.channels = 4;
    
    const size = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    log.cardinal_log_info("[TEXTURE] Successfully loaded texture {s} ({d}x{d}, 4 channels, original: {d}, {d} bytes)", 
        .{path, texture.width, texture.height, c, size});
        
    return true;
}

pub export fn texture_load_with_ref_counting(filepath: ?[*]const u8, out_texture: ?*TextureData) ?*ref_counting.CardinalRefCountedResource {
    if (filepath == null or out_texture == null) return null;
    const filename_c: [*:0]const u8 = @ptrCast(filepath.?);
    const path = std.mem.span(filename_c);
    
    if (!g_texture_cache.initialized) {
        _ = texture_cache_initialize(256);
    }
    
    const state = cardinal_resource_state_get(filepath.?);
    
    if (state == .LOADED) {
        if (texture_cache_get(path)) |res| {
            const existing: *TextureData = @ptrCast(@alignCast(res.resource.?));
            out_texture.?.* = existing.*;
            log.cardinal_log_debug("[TEXTURE] Reusing loaded texture: {s} (ref_count={d})", .{path, res.ref_count});
            return res;
        }
        
        if (ref_counting.cardinal_ref_acquire(filename_c)) |res| {
            const existing: *TextureData = @ptrCast(@alignCast(res.resource.?));
            out_texture.?.* = existing.*;
            _ = texture_cache_put(path, res);
             log.cardinal_log_debug("[TEXTURE] Reusing registry texture: {s}", .{path});
            return res;
        }
    }
    
    if (state == .LOADING) {
        if (cardinal_resource_state_wait_for(filepath.?, .LOADED, 5000)) {
            var res = texture_cache_get(path);
            if (res == null) {
                log.cardinal_log_debug("[TEXTURE] Not in cache, trying registry: {s}", .{path});
                res = ref_counting.cardinal_ref_acquire(filename_c);
            } else {
                log.cardinal_log_debug("[TEXTURE] Found in cache: {s}", .{path});
            }
            if (res) |r| {
                const existing: *TextureData = @ptrCast(@alignCast(r.resource.?));
                out_texture.?.* = existing.*;
                return r;
            }
        }
        return null;
    }
    
    const thread_id = getCurrentThreadId();
    
    // Register temp ref for state tracking
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const temp_ref_ptr = memory.cardinal_alloc(allocator, @sizeOf(ref_counting.CardinalRefCountedResource));
    
    if (temp_ref_ptr) |ptr| {
        const temp_ref: *ref_counting.CardinalRefCountedResource = @ptrCast(@alignCast(ptr));
        temp_ref.* = std.mem.zeroes(ref_counting.CardinalRefCountedResource);
        
        const id_ptr = memory.cardinal_alloc(allocator, path.len + 1);
        if (id_ptr) |ip| {
             const new_id = @as([*]u8, @ptrCast(ip))[0..path.len+1];
             @memcpy(new_id[0..path.len], path);
             new_id[path.len] = 0;
             temp_ref.identifier = @ptrCast(ip);
             temp_ref.ref_count = 1;
             
             if (cardinal_resource_state_register(temp_ref) == null) {
                 memory.cardinal_free(allocator, ip);
                 memory.cardinal_free(allocator, ptr);
             }
        } else {
            memory.cardinal_free(allocator, ptr);
        }
    }
    
    if (!cardinal_resource_state_try_acquire_loading(filepath.?, thread_id)) {
        if (cardinal_resource_state_wait_for(filepath.?, .LOADED, 5000)) {
             var res = texture_cache_get(path);
             if (res == null) {
                 log.cardinal_log_debug("[TEXTURE] Not in cache, trying registry: {s}", .{path});
                 res = ref_counting.cardinal_ref_acquire(filename_c);
             } else {
                 log.cardinal_log_debug("[TEXTURE] Found in cache: {s}", .{path});
             }
             if (res) |r| {
                 const existing: *TextureData = @ptrCast(@alignCast(r.resource.?));
                 out_texture.?.* = existing.*;
                 log.cardinal_log_debug("[TEXTURE] Successfully retrieved texture after waiting: {s}", .{path});
                 return r;
             } else {
                 log.cardinal_log_error("[TEXTURE] Resource not found in cache or registry after wait: {s}", .{path});
             }
        } else {
            log.cardinal_log_error("[TEXTURE] Wait for resource loading timed out: {s}", .{path});
        }
        log.cardinal_log_error("[TEXTURE] Failed to get texture after waiting: {s}", .{path});
        return null;
    }
    
    if (!texture_load_from_file(filepath, out_texture)) {
        cardinal_resource_state_set(filepath.?, .ERROR, thread_id);
        return null;
    }
    
    // Create copy for registry
    const texture_copy_ptr = memory.cardinal_alloc(allocator, @sizeOf(TextureData));
    if (texture_copy_ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for texture copy", .{});
        texture_data_free(out_texture);
        cardinal_resource_state_set(filepath.?, .ERROR, thread_id);
        return null;
    }
    const texture_copy: *TextureData = @ptrCast(@alignCast(texture_copy_ptr));
    texture_copy.* = out_texture.?.*;
    
    const ref_res = ref_counting.cardinal_ref_create(filename_c, texture_copy, @sizeOf(TextureData), texture_data_destructor);
    if (ref_res == null) {
        log.cardinal_log_error("Failed to register texture in reference counting system: {s}", .{path});
        memory.cardinal_free(allocator, texture_copy_ptr);
        texture_data_free(out_texture);
        cardinal_resource_state_set(filepath.?, .ERROR, thread_id);
        return null;
    }
    
    _ = texture_cache_put(path, ref_res.?);
    
    // Register tracker again for the real resource? 
    // The C code calls cardinal_resource_state_register(ref_resource) here.
    _ = cardinal_resource_state_register(ref_res.?);
    
    cardinal_resource_state_set(filepath.?, .LOADED, thread_id);
    
    return ref_res;
}

pub export fn texture_release_ref_counted(ref_resource: ?*ref_counting.CardinalRefCountedResource) void {
    if (ref_resource) |r| {
        ref_counting.cardinal_ref_release(r);
    }
}

pub export fn texture_load_async(filepath: ?[*]const u8, priority: async_loader.CardinalAsyncPriority, callback: async_loader.CardinalAsyncCallback, user_data: ?*anyopaque) ?*async_loader.CardinalAsyncTask {
    if (filepath == null) return null;
    
    // In C this checked if initialized, but async_loader_load_texture does that too.
    const filepath_c: [*:0]const u8 = @ptrCast(filepath.?);
    return async_loader.cardinal_async_load_texture(filepath_c, priority, callback, user_data);
}
