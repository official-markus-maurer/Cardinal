const std = @import("std");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const ref_counting = @import("../core/ref_counting.zig");
const async_loader = @import("../core/async_loader.zig");
const resource_state = @import("../core/resource_state.zig");

const texture_log = log.ScopedLogger("TEXTURE");

// Import STB functions
extern fn stbi_load(filename: [*]const u8, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbi_failure_reason() ?[*]const u8;
extern fn stbi_set_flip_vertically_on_load(flag_true_if_should_flip: c_int) void;
extern fn stbi_is_hdr(filename: [*]const u8) c_int;
extern fn stbi_loadf(filename: [*]const u8, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]f32;
extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_is_hdr_from_memory(buffer: [*]const u8, len: c_int) c_int;
extern fn stbi_loadf_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]f32;

// TinyEXR functions
extern fn LoadEXR(out_rgba: *?[*]f32, width: *c_int, height: *c_int, filename: [*]const u8, err: *?[*]const u8) c_int;
extern fn IsEXR(filename: [*]const u8) c_int;
extern fn LoadEXRFromMemory(out_rgba: *?[*]f32, width: *c_int, height: *c_int, memory: [*]const u8, size: usize, err: *?[*]const u8) c_int;
extern fn IsEXRFromMemory(memory: [*]const u8, size: usize) c_int;
extern fn FreeEXRErrorMessage(msg: [*]const u8) void;

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
    is_hdr: bool,
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

// Placeholder texture (1x1 magenta)
var g_placeholder_data = [_]u8{ 255, 0, 255, 255 };
var g_placeholder_texture = TextureData{
    .data = @ptrCast(&g_placeholder_data),
    .width = 1,
    .height = 1,
    .channels = 4,
    .is_hdr = false,
};

pub export fn cardinal_texture_check_cache(path: [*:0]const u8) ?*ref_counting.CardinalRefCountedResource {
    if (!g_texture_cache.initialized) return null;
    const filepath_slice = std.mem.span(path);
    return texture_cache_get(filepath_slice);
}

pub export fn cardinal_texture_get_placeholder(out_texture: *TextureData) void {
    out_texture.* = g_placeholder_texture;
}

pub export fn texture_load_from_disk(path: [*:0]const u8, out_texture: *TextureData) bool {
    const filename_slice = std.mem.span(path);

    // Use std.fs to read file into memory (handles Unicode paths on Windows)
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS).as_allocator();

    // Handle absolute vs relative paths
    var file_buffer: []u8 = undefined;

    if (std.fs.path.isAbsolute(filename_slice)) {
        var file = std.fs.openFileAbsolute(filename_slice, .{}) catch |err| {
            texture_log.err("Failed to open file '{s}': {s}", .{ filename_slice, @errorName(err) });
            return false;
        };
        defer file.close();

        file_buffer = file.readToEndAlloc(allocator, 4 * 1024 * 1024 * 1024) catch |err| {
            texture_log.err("Failed to read file '{s}': {s}", .{ filename_slice, @errorName(err) });
            return false;
        };
    } else {
        file_buffer = std.fs.cwd().readFileAlloc(allocator, filename_slice, 4 * 1024 * 1024 * 1024) catch |err| {
            texture_log.err("Failed to read file '{s}': {s}", .{ filename_slice, @errorName(err) });
            return false;
        };
    }
    defer allocator.free(file_buffer);

    return texture_load_from_memory(file_buffer.ptr, file_buffer.len, out_texture);
}

pub export fn texture_load_from_memory(data: [*]const u8, size: usize, out_texture: *TextureData) bool {
    var w: c_int = 0;
    var h: c_int = 0;
    var c: c_int = 0;

    // Check for EXR
    // Note: IsEXRFromMemory seems to return true for PNGs/others in some cases, so we enforce the magic byte check.
    // Magic bytes: 0x76, 0x2f, 0x31, 0x01
    var is_exr = false;
    if (size >= 4) {
        if (data[0] == 0x76 and data[1] == 0x2f and data[2] == 0x31 and data[3] == 0x01) {
            is_exr = true;
        }
    }

    if (is_exr) {
        var exr_data: ?[*]f32 = null;
        var err: ?[*]const u8 = null;
        const res = LoadEXRFromMemory(&exr_data, &w, &h, data, size, &err);

        if (res != 0) {
            if (err) |e| {
                const e_span = @as([*:0]const u8, @ptrCast(e));
                texture_log.err("TinyEXR memory load failed: {s}", .{std.mem.span(e_span)});
                FreeEXRErrorMessage(e);
            }
            return false;
        }

        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) {
            texture_log.err("Invalid dimensions from EXR memory load: {d}x{d}", .{ w, h });
            if (exr_data) |ptr| std.c.free(ptr); // TinyEXR uses malloc/free
            return false;
        }

        out_texture.data = @ptrCast(exr_data);
        out_texture.width = @intCast(w);
        out_texture.height = @intCast(h);
        out_texture.channels = 4;
        out_texture.is_hdr = true;
        return true;
    }

    // Check for HDR (stb)
    const is_hdr = (stbi_is_hdr_from_memory(data, @intCast(size)) != 0);

    var pixels: ?*anyopaque = null;
    if (is_hdr) {
        pixels = @ptrCast(stbi_loadf_from_memory(data, @intCast(size), &w, &h, &c, 4));
    } else {
        pixels = @ptrCast(stbi_load_from_memory(data, @intCast(size), &w, &h, &c, 4));
    }

    if (pixels == null) {
        const reason = stbi_failure_reason();
        texture_log.err("Failed to load texture from memory", .{});
        if (reason) |r| {
            const r_c: [*:0]const u8 = @ptrCast(r);
            texture_log.err("STB failure reason: {s}", .{std.mem.span(r_c)});
        }
        return false;
    }

    if (w <= 0 or h <= 0 or w > 16384 or h > 16384) {
        texture_log.err("Invalid dimensions from memory load: {d}x{d}", .{ w, h });
        stbi_image_free(pixels);
        return false;
    }

    out_texture.data = @ptrCast(pixels);
    out_texture.width = @intCast(w);
    out_texture.height = @intCast(h);
    out_texture.channels = 4;
    out_texture.is_hdr = is_hdr;

    return true;
}

fn normalize_path(allocator: *memory.CardinalAllocator, path: []const u8) ?[]u8 {
    const normalized = memory.cardinal_alloc(allocator, path.len + 1);
    if (normalized) |ptr| {
        const slice = @as([*]u8, @ptrCast(ptr))[0..path.len];
        @memcpy(slice, path);
        @as([*]u8, @ptrCast(ptr))[path.len] = 0; // Null terminate

        for (slice) |*c| {
            if (c.* == '\\') c.* = '/';
        }

        // Remove /./ from path
        var write_idx: usize = 0;
        var read_idx: usize = 0;
        while (read_idx < slice.len) {
            // Check for /./
            if (read_idx + 2 < slice.len and slice[read_idx] == '/' and slice[read_idx + 1] == '.' and slice[read_idx + 2] == '/') {
                read_idx += 2; // Skip /., keep the last / (which will be copied in next iter)
                continue;
            }
            slice[write_idx] = slice[read_idx];
            write_idx += 1;
            read_idx += 1;
        }

        // Null terminate at new length
        @as([*]u8, @ptrCast(ptr))[write_idx] = 0;
        return @as([*]u8, @ptrCast(ptr))[0..write_idx];
    }
    return null;
}

const TextureLoadContext = struct {
    resource: *ref_counting.CardinalRefCountedResource,
    loading_thread_id: u32,
};

fn texture_load_async_func(task: ?*async_loader.CardinalAsyncTask, user_data: ?*anyopaque) callconv(.c) bool {
    _ = task;
    if (user_data == null) return false;

    const context = @as(*TextureLoadContext, @ptrCast(@alignCast(user_data)));
    const resource = context.resource;
    const loading_thread_id = context.loading_thread_id;

    // Ensure we clean up context and release resource reference at the end
    defer {
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
        memory.cardinal_free(allocator, context);
        ref_counting.cardinal_ref_release(resource);
    }

    if (resource.identifier == null) return false;
    const path: [*:0]const u8 = @ptrCast(resource.identifier);

    var tex_data: TextureData = undefined;
    if (texture_load_from_disk(path, &tex_data)) {
        const existing_data = @as(*TextureData, @ptrCast(@alignCast(resource.resource.?)));
        existing_data.* = tex_data;

        _ = resource_state.cardinal_resource_state_set(resource.identifier.?, .LOADED, loading_thread_id);
        return true;
    } else {
        _ = resource_state.cardinal_resource_state_set(resource.identifier.?, .ERROR, loading_thread_id);
        return false;
    }
}

fn texture_load_task_cleanup(task: ?*async_loader.CardinalAsyncTask, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    async_loader.cardinal_async_free_task(task);
}

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

    texture_log.info("LRU texture cache initialized (max_entries={d}, max_memory={d} MB)", .{ max_entries, g_texture_cache.max_memory_usage / (1024 * 1024) });
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

    texture_log.info("Thread-safe texture cache shutdown", .{});
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

    texture_log.info("Cache cleared", .{});
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

const asset_manager = @import("asset_manager.zig");

fn texture_cache_get(filepath: []const u8) ?*ref_counting.CardinalRefCountedResource {
    // Check AssetManager first
    if (asset_manager.get().findTexture(filepath)) |tex| {
        if (tex.ref_resource) |res| {
            // Increment ref count
            _ = @atomicRmw(u32, &res.ref_count, .Add, 1, .seq_cst);
            texture_log.debug("Cache hit from AssetManager for {s}", .{filepath});
            return res;
        }
    }

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

            texture_log.debug("Cache hit for {s} (memory usage: {d} bytes)", .{ filepath, current.memory_usage });
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
        g_texture_cache.tail != null)
    {
        const to_remove = g_texture_cache.tail.?;
        remove_from_list(to_remove);

        g_texture_cache.total_memory_usage -= to_remove.memory_usage;
        g_texture_cache.entry_count -= 1;
        g_texture_cache.evictions += 1;

        texture_log.debug("Evicted {s} (freed {d} bytes, total: {d}/{d} bytes)", .{ to_remove.filepath, to_remove.memory_usage, g_texture_cache.total_memory_usage, g_texture_cache.max_memory_usage });

        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
        memory.cardinal_free(allocator, @ptrCast(@constCast(to_remove.filepath.ptr)));
        ref_counting.cardinal_ref_release(to_remove.resource);
        memory.cardinal_free(allocator, to_remove);
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    // Allocate new entry
    const entry_ptr = memory.cardinal_alloc(allocator, @sizeOf(TextureCacheEntry));
    if (entry_ptr == null) {
        texture_log.err("Failed to allocate cache entry for {s}", .{filepath});
        return false;
    }
    const new_entry: *TextureCacheEntry = @ptrCast(@alignCast(entry_ptr));

    // Copy filepath
    const filepath_ptr = memory.cardinal_alloc(allocator, filepath.len + 1);
    if (filepath_ptr == null) {
        texture_log.err("Failed to allocate filepath for {s}", .{filepath});
        memory.cardinal_free(allocator, entry_ptr);
        return false;
    }
    const new_filepath = @as([*]u8, @ptrCast(filepath_ptr))[0 .. filepath.len + 1];
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

    texture_log.debug("Cached {s} ({d} bytes, total: {d}/{d} bytes)", .{ filepath, texture_memory, g_texture_cache.total_memory_usage, g_texture_cache.max_memory_usage });

    return true;
}

// Destructor
export fn texture_data_destructor(resource: ?*anyopaque) callconv(.c) void {
    if (resource == null) {
        texture_log.warn("texture_data_destructor called with NULL resource", .{});
        return;
    }

    const texture: *TextureData = @ptrCast(@alignCast(resource));
    texture_log.debug("Destroying texture data at {*} (size: {d}x{d}, {d} channels)", .{ texture, texture.width, texture.height, texture.channels });

    if (texture.data) |data| {
        texture_log.debug("Freeing texture pixel data at {*}", .{data});
        stbi_image_free(data);
        texture.data = null;
        texture_log.debug("Texture pixel data freed and nullified", .{});
    } else {
        texture_log.warn("Texture data already NULL during destruction", .{});
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    memory.cardinal_free(allocator, texture);
    texture_log.debug("Texture structure freed", .{});
}

pub export fn texture_data_free(texture: ?*TextureData) void {
    if (texture == null) {
        texture_log.warn("texture_data_free called with NULL texture", .{});
        return;
    }
    const t = texture.?;

    texture_log.debug("Freeing texture data at {*}", .{t});

    if (t.data) |data| {
        stbi_image_free(data);
        t.data = null;
    }

    t.width = 0;
    t.height = 0;
    t.channels = 0;
}

pub export fn texture_load_with_ref_counting(filepath: ?[*]const u8, out_texture: ?*TextureData) ?*ref_counting.CardinalRefCountedResource {
    if (filepath == null or out_texture == null) return null;
    const filename_c: [*:0]const u8 = @ptrCast(filepath.?);
    const raw_path = std.mem.span(filename_c);

    if (!g_texture_cache.initialized) {
        _ = texture_cache_initialize(256);
    }

    // Normalize path
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const normalized_path_slice = normalize_path(allocator, raw_path);
    if (normalized_path_slice == null) return null;
    defer memory.cardinal_free(allocator, @ptrCast(normalized_path_slice.?.ptr));

    // Create null-terminated pointer for C APIs
    const path = normalized_path_slice.?;
    // We can cast ptr because we allocated size+1 and null terminated it in normalize_path
    const path_c: [*:0]const u8 = @ptrCast(path.ptr);

    texture_log.debug("Texture load request: {s} (raw: {s})", .{ path, raw_path });

    const state = resource_state.cardinal_resource_state_get(path_c);

    if (state == .LOADED) {
        if (texture_cache_get(path)) |res| {
            const existing: *TextureData = @ptrCast(@alignCast(res.resource.?));
            out_texture.?.* = existing.*;
            texture_log.debug("Reusing loaded texture: {s} (ref_count={d})", .{ path, res.ref_count });
            return res;
        }

        if (ref_counting.cardinal_ref_acquire(path_c)) |res| {
            const existing: *TextureData = @ptrCast(@alignCast(res.resource.?));
            out_texture.?.* = existing.*;
            _ = texture_cache_put(path, res);
            texture_log.debug("Reusing registry texture: {s}", .{path});
            return res;
        }
    }

    if (state == .LOADING) {
        // Check cache for placeholder
        if (texture_cache_get(path)) |res| {
            const existing: *TextureData = @ptrCast(@alignCast(res.resource.?));
            out_texture.?.* = existing.*;
            return res;
        }

        // Short wait to handle race condition where registration is finishing
        if (resource_state.cardinal_resource_state_wait_for(path_c, .LOADED, 10)) {
            if (texture_cache_get(path)) |res| {
                const existing: *TextureData = @ptrCast(@alignCast(res.resource.?));
                out_texture.?.* = existing.*;
                return res;
            }
        }
    }

    const thread_id = getCurrentThreadId();

    // Register temp ref for state tracking
    // We need to persist the path for the identifier

    // Allocate TextureData first
    const data_ptr = memory.cardinal_alloc(allocator, @sizeOf(TextureData));
    if (data_ptr == null) {
        texture_log.err("Failed to allocate TextureData for {s}", .{path});
        return null;
    }
    const tex_data = @as(*TextureData, @ptrCast(@alignCast(data_ptr)));
    // Initialize with placeholder
    tex_data.* = g_placeholder_texture;

    const path_c_id: [*:0]const u8 = @ptrCast(path.ptr);
    const temp_ref_opt = ref_counting.cardinal_ref_create(path_c_id, tex_data, @sizeOf(TextureData), texture_data_destructor);

    if (temp_ref_opt) |temp_ref| {
        if (resource_state.cardinal_resource_state_register(temp_ref) == null) {
            // Recursion here is dangerous if register fails repeatedly.
            // Instead of recursive call, return null to avoid stack overflow.
            log.cardinal_log_error("[TEXTURE] Failed to register resource state for {s}", .{path});
            // Release the ref we just created (which will trigger removal from registry and destructor)
            ref_counting.cardinal_ref_release(temp_ref);
            return null;
        }

        // Cache it immediately so others find it
        _ = texture_cache_put(path, temp_ref);

        // Set state to LOADING
        if (resource_state.cardinal_resource_state_try_acquire_loading(temp_ref.identifier.?, thread_id)) {
            // Create context for async task
            const ctx_ptr = memory.cardinal_alloc(allocator, @sizeOf(TextureLoadContext));
            if (ctx_ptr) |cp| {
                const ctx = @as(*TextureLoadContext, @ptrCast(@alignCast(cp)));
                ctx.resource = temp_ref;
                ctx.loading_thread_id = thread_id;

                // Increment ref count for the task (released in task)
                _ = @atomicRmw(u32, &temp_ref.ref_count, .Add, 1, .seq_cst);

                // Launch Async Task
                const task = async_loader.cardinal_async_submit_custom_task(texture_load_async_func, ctx, .NORMAL, texture_load_task_cleanup, null);
                if (task == null) {
                    // Failed to submit task, clean up
                    log.cardinal_log_error("[TEXTURE] Failed to submit async task for {s}", .{path});
                    memory.cardinal_free(allocator, ctx);
                    // Release the ref we added for the task
                    _ = @atomicRmw(u32, &temp_ref.ref_count, .Sub, 1, .seq_cst);
                    _ = resource_state.cardinal_resource_state_set(temp_ref.identifier.?, .ERROR, thread_id);
                }
            } else {
                texture_log.err("Failed to allocate context for async load", .{});
                _ = resource_state.cardinal_resource_state_set(temp_ref.identifier.?, .ERROR, thread_id);
            }
        }

        out_texture.?.* = tex_data.*;
        return temp_ref;
    } else {
        memory.cardinal_free(allocator, tex_data);
        return null;
    }
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
