const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

// External C functions for aligned allocation
extern "c" fn _aligned_malloc(size: usize, alignment: usize) ?*anyopaque;
extern "c" fn _aligned_free(ptr: ?*anyopaque) void;
extern "c" fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) c_int;

// Constants
const MAX_ALLOCS = 8192;
const HASH_MULTIPLIER = 0x9e3779b9;

// Enums and Structs matching C header
pub const CardinalMemoryCategory = enum(c_int) {
    UNKNOWN = 0,
    ENGINE,
    RENDERER,
    VULKAN_BUFFERS,
    VULKAN_DEVICE,
    TEXTURES,
    MESHES,
    ASSETS,
    SHADERS,
    WINDOW,
    LOGGING,
    TEMPORARY,
    MAX
};

pub const CardinalAllocatorType = enum(c_int) {
    DYNAMIC = 0,
    LINEAR = 1,
    TRACKED = 2
};

pub const CardinalMemoryStats = extern struct {
    total_allocated: usize,
    current_usage: usize,
    peak_usage: usize,
    allocation_count: usize,
    free_count: usize,
};

pub const CardinalGlobalMemoryStats = extern struct {
    categories: [12]CardinalMemoryStats, // 12 = CARDINAL_MEMORY_CATEGORY_MAX
    total: CardinalMemoryStats,
};

pub const CardinalAllocator = extern struct {
    type: CardinalAllocatorType,
    name: [*:0]const u8,
    category: CardinalMemoryCategory,
    state: ?*anyopaque,
    alloc: *const fn (*CardinalAllocator, usize, usize) callconv(.c) ?*anyopaque,
    realloc: *const fn (*CardinalAllocator, ?*anyopaque, usize, usize, usize) callconv(.c) ?*anyopaque,
    free: *const fn (*CardinalAllocator, ?*anyopaque) callconv(.c) void,
    reset: ?*const fn (*CardinalAllocator) callconv(.c) void,
};

// Internal State Structures
const DynamicState = extern struct {
    placeholder: c_int,
};

const LinearState = extern struct {
    buffer: ?[*]u8,
    capacity: usize,
    offset: usize,
};

const TrackedState = extern struct {
    backing: *CardinalAllocator,
    category: CardinalMemoryCategory,
};

const AllocInfo = struct {
    ptr: ?*anyopaque,
    size: usize,
    is_aligned: bool,
    in_use: bool,
};

// Global State
var g_stats: CardinalGlobalMemoryStats = std.mem.zeroes(CardinalGlobalMemoryStats);
var g_alloc_table: [MAX_ALLOCS]AllocInfo = std.mem.zeroes([MAX_ALLOCS]AllocInfo);
var g_alloc_table_init: bool = false;
var g_active_allocs: usize = 0;

var g_dynamic_state: DynamicState = .{ .placeholder = 0 };
var g_linear_state: LinearState = undefined;
var g_tracked_state: [12]TrackedState = undefined;

var g_dynamic: CardinalAllocator = undefined;
var g_linear: CardinalAllocator = undefined;
var g_tracked: [12]CardinalAllocator = undefined;

// Stats Helpers
fn stats_on_alloc(cat: CardinalMemoryCategory, size: usize) void {
    var category = cat;
    if (@intFromEnum(category) >= @intFromEnum(CardinalMemoryCategory.MAX)) {
        category = .UNKNOWN;
    }
    
    const cat_idx = @as(usize, @intCast(@intFromEnum(category)));
    g_stats.categories[cat_idx].total_allocated += size;
    g_stats.categories[cat_idx].current_usage += size;
    if (g_stats.categories[cat_idx].current_usage > g_stats.categories[cat_idx].peak_usage) {
        g_stats.categories[cat_idx].peak_usage = g_stats.categories[cat_idx].current_usage;
    }
    g_stats.categories[cat_idx].allocation_count += 1;

    g_stats.total.total_allocated += size;
    g_stats.total.current_usage += size;
    if (g_stats.total.current_usage > g_stats.total.peak_usage) {
        g_stats.total.peak_usage = g_stats.total.current_usage;
    }
    g_stats.total.allocation_count += 1;
}

fn stats_on_free(cat: CardinalMemoryCategory, size: usize) void {
    var category = cat;
    if (@intFromEnum(category) >= @intFromEnum(CardinalMemoryCategory.MAX)) {
        category = .UNKNOWN;
    }

    const cat_idx = @as(usize, @intCast(@intFromEnum(category)));
    if (g_stats.categories[cat_idx].current_usage >= size) {
        g_stats.categories[cat_idx].current_usage -= size;
    } else {
        g_stats.categories[cat_idx].current_usage = 0;
    }
    g_stats.categories[cat_idx].free_count += 1;

    if (g_stats.total.current_usage >= size) {
        g_stats.total.current_usage -= size;
    } else {
        g_stats.total.current_usage = 0;
    }
    g_stats.total.free_count += 1;
}

export fn cardinal_memory_get_stats(out_stats: ?*CardinalGlobalMemoryStats) void {
    if (out_stats) |s| {
        s.* = g_stats;
    }
}

export fn cardinal_memory_reset_stats() void {
    g_stats = std.mem.zeroes(CardinalGlobalMemoryStats);
}

// Allocation Tracking
fn init_alloc_table() void {
    if (!g_alloc_table_init) {
        g_alloc_table = std.mem.zeroes([MAX_ALLOCS]AllocInfo);
        g_alloc_table_init = true;
        g_active_allocs = 0;
    }
}

fn hash_ptr(ptr: ?*anyopaque) usize {
    var addr = @intFromPtr(ptr);
    addr ^= addr >> 16;
    addr *%= HASH_MULTIPLIER;
    addr ^= addr >> 16;
    return addr % MAX_ALLOCS;
}

fn track_alloc(ptr: ?*anyopaque, size: usize, is_aligned: bool) void {
    if (ptr == null) return;
    init_alloc_table();

    const hash = hash_ptr(ptr);
    var i: usize = 0;
    while (i < MAX_ALLOCS) : (i += 1) {
        const idx = (hash + i) % MAX_ALLOCS;
        if (!g_alloc_table[idx].in_use) {
            g_alloc_table[idx].ptr = ptr;
            g_alloc_table[idx].size = size;
            g_alloc_table[idx].is_aligned = is_aligned;
            g_alloc_table[idx].in_use = true;
            g_active_allocs += 1;
            return;
        }
    }
    // Table full - critical error in production
}

fn find_alloc(ptr: ?*anyopaque) ?*AllocInfo {
    if (ptr == null) return null;
    init_alloc_table();

    const hash = hash_ptr(ptr);
    var i: usize = 0;
    while (i < MAX_ALLOCS) : (i += 1) {
        const idx = (hash + i) % MAX_ALLOCS;
        if (g_alloc_table[idx].in_use and g_alloc_table[idx].ptr == ptr) {
            return &g_alloc_table[idx];
        }
    }
    return null;
}

fn untrack_alloc(ptr: ?*anyopaque, out_size: ?*usize, out_is_aligned: ?*bool) bool {
    if (find_alloc(ptr)) |info| {
        if (out_size) |s| s.* = info.size;
        if (out_is_aligned) |a| a.* = info.is_aligned;
        
        info.ptr = null;
        info.size = 0;
        info.is_aligned = false;
        info.in_use = false;
        g_active_allocs -= 1;
        return true;
    }
    return false;
}

// Dynamic Allocator
fn dyn_alloc(_: *CardinalAllocator, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    var ptr: ?*anyopaque = null;
    var is_aligned = false;
    
    // max_align_t is usually 16 bytes on 64-bit systems
    const max_align = @alignOf(c_longdouble);

    if (alignment > 0 and alignment > max_align) {
        is_aligned = true;
        if (builtin.os.tag == .windows) {
            ptr = _aligned_malloc(size, alignment);
        } else {
            var temp_ptr: ?*anyopaque = null;
            if (posix_memalign(&temp_ptr, alignment, size) == 0) {
                ptr = temp_ptr;
            }
        }
    } else {
        ptr = c.malloc(size);
    }

    if (ptr != null) {
        track_alloc(ptr, size, is_aligned);
    }
    return ptr;
}

fn dyn_realloc(self: *CardinalAllocator, ptr: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) {
        return dyn_alloc(self, new_size, alignment);
    }

    var tracked_old_size: usize = 0;
    var is_aligned = false;
    const was_tracked = untrack_alloc(ptr, &tracked_old_size, &is_aligned);

    const actual_old_size = if (was_tracked) tracked_old_size else old_size;
    const max_align = @alignOf(c_longdouble);

    var new_ptr: ?*anyopaque = null;
    if (is_aligned or (alignment > 0 and alignment > max_align)) {
        new_ptr = dyn_alloc(self, new_size, alignment);
        if (new_ptr != null and actual_old_size > 0) {
            const copy_size = if (actual_old_size < new_size) actual_old_size else new_size;
            _ = c.memcpy(new_ptr, ptr, copy_size);
        }
        
        if (is_aligned) {
            if (builtin.os.tag == .windows) {
                _aligned_free(ptr);
            } else {
                c.free(ptr);
            }
        } else {
            c.free(ptr);
        }
    } else {
        new_ptr = c.realloc(ptr, new_size);
        if (new_ptr != null) {
            track_alloc(new_ptr, new_size, false);
        }
    }

    return new_ptr;
}

fn dyn_free(_: *CardinalAllocator, ptr: ?*anyopaque) callconv(.c) void {
    if (ptr == null) return;

    var size: usize = 0;
    var is_aligned = false;
    const was_tracked = untrack_alloc(ptr, &size, &is_aligned);

    if (was_tracked and is_aligned) {
        if (builtin.os.tag == .windows) {
            _aligned_free(ptr);
        } else {
            c.free(ptr);
        }
    } else {
        c.free(ptr);
    }
}

// Linear Allocator
fn lin_alloc(self: *CardinalAllocator, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const st: *LinearState = @ptrCast(@alignCast(self.state));
    const current = st.offset;
    const align_val = if (alignment > 0) alignment else @sizeOf(?*anyopaque);
    
    const ptr_int = @intFromPtr(st.buffer) + current;
    const mis = ptr_int % align_val;
    const pad = if (mis > 0) align_val - mis else 0;
    
    if (current + pad + size > st.capacity) return null;
    
    const at = current + pad;
    st.offset = at + size;
    return @ptrFromInt(@intFromPtr(st.buffer) + at);
}

fn lin_realloc(self: *CardinalAllocator, ptr: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return lin_alloc(self, new_size, alignment);
    
    const n = lin_alloc(self, new_size, alignment);
    if (n == null) return null;
    
    const copy = if (old_size < new_size) old_size else new_size;
    _ = c.memcpy(n, ptr, copy);
    return n;
}

fn lin_free(_: *CardinalAllocator, _: ?*anyopaque) callconv(.c) void {
    // no-op
}

fn lin_reset(self: *CardinalAllocator) callconv(.c) void {
    const st: *LinearState = @ptrCast(@alignCast(self.state));
    st.offset = 0;
}

// Tracked Allocator
fn tracked_alloc(self: *CardinalAllocator, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const ts: *TrackedState = @ptrCast(@alignCast(self.state));
    const backing = ts.backing;
    const p = backing.alloc(backing, size, alignment);
    
    if (p != null and size > 0) {
        stats_on_alloc(ts.category, size);
        const max_align = @alignOf(c_longdouble);
        track_alloc(p, size, alignment > 0 and alignment > max_align);
    }
    return p;
}

fn tracked_realloc(self: *CardinalAllocator, ptr: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const ts: *TrackedState = @ptrCast(@alignCast(self.state));
    
    var actual_old_size = old_size;
    if (ptr != null) {
        if (find_alloc(ptr)) |info| {
            actual_old_size = info.size;
        }
    }

    const backing = ts.backing;
    const p = backing.realloc(backing, ptr, actual_old_size, new_size, alignment);
    
    if (p != null) {
        if (new_size > actual_old_size) {
            stats_on_alloc(ts.category, new_size - actual_old_size);
        } else if (actual_old_size > new_size) {
            stats_on_free(ts.category, actual_old_size - new_size);
        }
        
        const max_align = @alignOf(c_longdouble);
        track_alloc(p, new_size, alignment > 0 and alignment > max_align);
    }
    return p;
}

fn tracked_free(self: *CardinalAllocator, ptr: ?*anyopaque) callconv(.c) void {
    const ts: *TrackedState = @ptrCast(@alignCast(self.state));
    if (ptr != null) {
        var size: usize = 0;
        var is_aligned = false;
        if (untrack_alloc(ptr, &size, &is_aligned)) {
            stats_on_free(ts.category, size);
        }
    }
    const backing = ts.backing;
    backing.free(backing, ptr);
}

fn tracked_reset(self: *CardinalAllocator) callconv(.c) void {
    const ts: *TrackedState = @ptrCast(@alignCast(self.state));
    const backing = ts.backing;
    if (backing.reset) |reset_fn| {
        reset_fn(backing);
    }
}

// Initialization and Shutdown
export fn cardinal_memory_init(default_linear_capacity: usize) void {
    cardinal_memory_reset_stats();

    // Dynamic
    g_dynamic = .{
        .type = .DYNAMIC,
        .name = "dynamic",
        .category = .ENGINE,
        .state = &g_dynamic_state,
        .alloc = dyn_alloc,
        .realloc = dyn_realloc,
        .free = dyn_free,
        .reset = null,
    };

    // Linear
    const cap = if (default_linear_capacity == 0) 4 * 1024 * 1024 else default_linear_capacity;
    const lin_ptr = c.malloc(cap);
    if (lin_ptr) |p| {
        g_linear_state.buffer = @ptrCast(@alignCast(p));
        g_linear_state.capacity = cap;
    } else {
        g_linear_state.buffer = null;
        g_linear_state.capacity = 0;
    }
    g_linear_state.offset = 0;

    g_linear = .{
        .type = .LINEAR,
        .name = "linear",
        .category = .TEMPORARY,
        .state = &g_linear_state,
        .alloc = lin_alloc,
        .realloc = lin_realloc,
        .free = lin_free,
        .reset = lin_reset,
    };

    // Tracked
    var i: usize = 0;
    while (i < 12) : (i += 1) { // 12 = CARDINAL_MEMORY_CATEGORY_MAX
        g_tracked_state[i] = .{
            .backing = &g_dynamic,
            .category = @enumFromInt(@as(c_int, @intCast(i))),
        };
        g_tracked[i] = .{
            .type = .TRACKED,
            .name = "tracked_dynamic",
            .category = @enumFromInt(@as(c_int, @intCast(i))),
            .state = &g_tracked_state[i],
            .alloc = tracked_alloc,
            .realloc = tracked_realloc,
            .free = tracked_free,
            .reset = tracked_reset,
        };
    }
}

export fn cardinal_memory_shutdown() void {
    if (g_linear_state.capacity > 0) {
        if (g_linear_state.buffer) |b| {
            c.free(@ptrCast(b));
        }
        g_linear_state.buffer = null;
        g_linear_state.capacity = 0;
        g_linear_state.offset = 0;
    }
}

export fn cardinal_get_dynamic_allocator() *CardinalAllocator {
    return &g_dynamic;
}

export fn cardinal_get_linear_allocator() *CardinalAllocator {
    return &g_linear;
}

pub export fn cardinal_get_allocator_for_category(category: CardinalMemoryCategory) *CardinalAllocator {
    const idx = @as(usize, @intCast(@intFromEnum(category)));
    if (idx < 0 or idx >= 12) {
        return &g_tracked[@as(usize, @intCast(@intFromEnum(CardinalMemoryCategory.UNKNOWN)))];
    }
    return &g_tracked[@intCast(idx)];
}

pub export fn cardinal_alloc(allocator: *CardinalAllocator, size: usize) callconv(.c) ?*anyopaque {
    return allocator.alloc(allocator, size, 0);
}

pub export fn cardinal_free(allocator: *CardinalAllocator, ptr: ?*anyopaque) callconv(.c) void {
    allocator.free(allocator, ptr);
}

pub export fn cardinal_realloc(allocator: *CardinalAllocator, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return allocator.realloc(allocator, ptr, 0, size, 0);
}

pub export fn cardinal_calloc(allocator: *CardinalAllocator, count: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = count * size;
    const ptr = allocator.alloc(allocator, total, 0);
    if (ptr) |p| {
        _ = c.memset(p, 0, total);
    }
    return ptr;
}

export fn cardinal_linear_allocator_create(capacity: usize) ?*CardinalAllocator {
    if (capacity == 0) return null;

    const st = c.malloc(@sizeOf(LinearState));
    if (st == null) return null;
    const state: *LinearState = @ptrCast(@alignCast(st));

    const buf_ptr = c.malloc(capacity);
    if (buf_ptr) |p| {
        state.buffer = @ptrCast(@alignCast(p));
    } else {
        c.free(st);
        return null;
    }

    state.capacity = capacity;
    state.offset = 0;

    const a_ptr = c.malloc(@sizeOf(CardinalAllocator));
    if (a_ptr == null) {
        if (state.buffer) |b| {
            c.free(@ptrCast(b));
        }
        c.free(st);
        return null;
    }
    const a: *CardinalAllocator = @ptrCast(@alignCast(a_ptr));

    a.* = .{
        .type = .LINEAR,
        .name = "linear_dyn",
        .category = .TEMPORARY,
        .state = state,
        .alloc = lin_alloc,
        .realloc = lin_realloc,
        .free = lin_free,
        .reset = lin_reset,
    };

    return a;
}

export fn cardinal_linear_allocator_destroy(allocator: ?*CardinalAllocator) void {
    if (allocator) |a| {
        if (a.type != .LINEAR) return;
        
        const st: *LinearState = @ptrCast(@alignCast(a.state));
        if (st.buffer) |b| {
            c.free(@ptrCast(b));
        }
        c.free(st);
        c.free(a);
    }
}
