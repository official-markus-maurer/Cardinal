//! Engine memory and allocation utilities.
//!
//! Provides a small set of allocators (dynamic/linear/arena) and per-category tracked allocators
//! used throughout the engine. The exported C-ABI functions are the stable interface; Zig code
//! typically uses `CardinalAllocator.as_allocator()` to get a `std.mem.Allocator`.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("stdio.h");
});

/// Memory allocation categories (C-ABI compatible).
pub const CardinalMemoryCategory = enum(c_int) { UNKNOWN = 0, ENGINE, RENDERER, VULKAN_BUFFERS, VULKAN_DEVICE, TEXTURES, MESHES, ASSETS, SHADERS, WINDOW, LOGGING, TEMPORARY, MAX };

/// Number of category slots tracked by `CardinalGlobalMemoryStats` and category allocators.
pub const CATEGORY_SLOT_COUNT: usize = @as(usize, @intCast(@intFromEnum(CardinalMemoryCategory.MAX)));

/// Allocator kinds supported by the C-facing memory system.
pub const CardinalAllocatorType = enum(c_int) { DYNAMIC = 0, LINEAR = 1, TRACKED = 2, ARENA = 3 };

const ArenaState = extern struct {
    backing: *CardinalAllocator,
    current_block: ?*ArenaBlock,
    default_block_size: usize,
};

const ArenaBlock = extern struct {
    next: ?*ArenaBlock,
    capacity: usize,
    offset: usize,
    /// Flexible array member data pointer.
    data: [*]u8,
};

pub const CardinalMemoryStats = extern struct {
    total_allocated: usize,
    current_usage: usize,
    peak_usage: usize,
    allocation_count: usize,
    free_count: usize,
};

pub const CardinalGlobalMemoryStats = extern struct {
    /// Per-category memory statistics.
    categories: [CATEGORY_SLOT_COUNT]CardinalMemoryStats,
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

    pub fn as_allocator(self: *CardinalAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = wrap_alloc,
        .resize = wrap_resize,
        .free = wrap_free,
        .remap = wrap_remap,
    };

    fn wrap_alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *CardinalAllocator = @ptrCast(@alignCast(ctx));
        const alignment = ptr_align.toByteUnits();
        const ptr = self.alloc(self, len, alignment);
        return @ptrCast(ptr);
    }

    fn wrap_resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *CardinalAllocator = @ptrCast(@alignCast(ctx));
        const alignment = buf_align.toByteUnits();

        switch (self.type) {
            .DYNAMIC => {
                const max_align = @alignOf(c_longdouble);
                if (alignment <= max_align) {
                    if (find_alloc(buf.ptr)) |info| {
                        if (info.is_aligned) return false;

                        if (platform.expand(buf.ptr, new_len)) |_| {
                            // TODO: Update allocation size in-place instead of untrack/track.
                            var old_size: usize = 0;
                            var is_aligned: bool = false;
                            if (untrack_alloc(buf.ptr, &old_size, &is_aligned)) {
                                track_alloc(buf.ptr, new_len, is_aligned);
                                stats_on_free(self.category, old_size);
                                stats_on_alloc(self.category, new_len);
                            }
                            return true;
                        }
                    }
                }
                return false;
            },
            .LINEAR => {
                const state: *LinearState = @ptrCast(@alignCast(self.state));
                const buf_end = @intFromPtr(buf.ptr) + buf.len;
                const top = @intFromPtr(state.buffer) + state.offset;

                if (buf_end == top) {
                    const new_top = @intFromPtr(buf.ptr) + new_len;
                    if (new_top <= @intFromPtr(state.buffer) + state.capacity) {
                        state.offset = new_top - @intFromPtr(state.buffer);
                        return true;
                    }
                } else if (new_len <= buf.len) {
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn wrap_remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn wrap_free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        _ = buf_align;
        const self: *CardinalAllocator = @ptrCast(@alignCast(ctx));
        self.free(self, buf.ptr);
    }
};

/// Allocator state for the dynamic (malloc-backed) allocator.
const DynamicState = extern struct {
    placeholder: c_int,
};

/// Allocator state for the linear/bump allocator.
const LinearState = extern struct {
    buffer: ?[*]u8,
    capacity: usize,
    offset: usize,
};

/// Allocator state for a tracked allocator wrapper.
const TrackedState = extern struct {
    backing: *CardinalAllocator,
    category: CardinalMemoryCategory,
};

/// Per-allocation tracking record (debugging/statistics).
const AllocInfo = struct {
    ptr: ?*anyopaque,
    size: usize,
    is_aligned: bool,
    in_use: bool,
    stack_addresses: [16]usize,
    stack_depth: usize,
};

/// Global memory statistics and allocator state.
var g_stats: CardinalGlobalMemoryStats = std.mem.zeroes(CardinalGlobalMemoryStats);
var g_alloc_map: std.AutoHashMap(usize, AllocInfo) = undefined;
var g_alloc_map_lock: std.Thread.RwLock = .{};
var g_alloc_map_init: bool = false;
var g_active_allocs: usize = 0;
var g_initialized: bool = false;

var g_dynamic_state: DynamicState = .{ .placeholder = 0 };
var g_linear_state: LinearState = undefined;
var g_arena_state: ArenaState = undefined;
var g_tracked_state: [CATEGORY_SLOT_COUNT]TrackedState = undefined;

var g_dynamic: CardinalAllocator = undefined;
var g_linear: CardinalAllocator = undefined;
var g_arena: CardinalAllocator = undefined;
var g_tracked: [CATEGORY_SLOT_COUNT]CardinalAllocator = undefined;

/// Updates stats on allocation.
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

/// Copies current memory statistics into `out_stats` (no-op if null).
pub export fn cardinal_memory_get_stats(out_stats: ?*CardinalGlobalMemoryStats) void {
    if (out_stats) |s| {
        s.* = g_stats;
    }
}

/// Resets global memory statistics counters.
pub export fn cardinal_memory_reset_stats() void {
    g_stats = std.mem.zeroes(CardinalGlobalMemoryStats);
}

/// Internal allocation tracking map initialization.
fn ensure_alloc_map() void {
    if (!g_alloc_map_init) {
        g_alloc_map = std.AutoHashMap(usize, AllocInfo).init(std.heap.c_allocator);
        g_alloc_map_init = true;
    }
}

/// Tracks a live allocation for debugging and per-category statistics.
///
/// Stack trace capture is intentionally disabled by default for performance.
fn track_alloc(ptr: ?*anyopaque, size: usize, is_aligned: bool) void {
    if (ptr == null) return;

    g_alloc_map_lock.lock();
    defer g_alloc_map_lock.unlock();

    ensure_alloc_map();

    const addr = @intFromPtr(ptr);
    var info = AllocInfo{
        .ptr = ptr,
        .size = size,
        .is_aligned = is_aligned,
        .in_use = true,
        .stack_addresses = undefined,
        .stack_depth = 0,
    };
    @memset(&info.stack_addresses, 0);

    const enable_stack_trace = false;
    if (builtin.mode == .Debug and enable_stack_trace) {
        var stack: [16]?*anyopaque = undefined;
        const count = platform.capture_stack_back_trace(0, 16, &stack, null);

        if (count > 0) {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                info.stack_addresses[i] = @intFromPtr(stack[i]);
            }
            info.stack_depth = count;
        } else {
            info.stack_addresses[0] = @returnAddress();
            info.stack_depth = 1;
        }
    }

    g_alloc_map.put(addr, info) catch |err| {
        _ = c.printf("Cardinal Memory Error: Failed to track allocation (OOM?): %s\n", @errorName(err).ptr);
    };
    g_active_allocs = g_alloc_map.count();
}

/// Prints captured stack addresses in a stable format for external symbolization.
fn print_stack_trace(addresses: []const usize, depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const addr = addresses[i];
        _ = c.printf("      0x%zx\n", addr);
    }
}

fn find_alloc(ptr: ?*anyopaque) ?AllocInfo {
    if (ptr == null) return null;

    g_alloc_map_lock.lockShared();
    defer g_alloc_map_lock.unlockShared();

    if (!g_alloc_map_init) return null;

    const addr = @intFromPtr(ptr);
    return g_alloc_map.get(addr);
}

fn untrack_alloc(ptr: ?*anyopaque, out_size: ?*usize, out_is_aligned: ?*bool) bool {
    if (ptr == null) return false;

    g_alloc_map_lock.lock();
    defer g_alloc_map_lock.unlock();

    if (!g_alloc_map_init) return false;

    const addr = @intFromPtr(ptr);
    if (g_alloc_map.fetchRemove(addr)) |kv| {
        if (out_size) |s| s.* = kv.value.size;
        if (out_is_aligned) |a| a.* = kv.value.is_aligned;
        g_active_allocs = g_alloc_map.count();
        return true;
    }
    return false;
}

/// Dynamic allocator implementation.
fn dyn_alloc(_: *CardinalAllocator, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    var ptr: ?*anyopaque = null;
    var is_aligned = false;

    const max_align = @alignOf(c_longdouble);

    if (alignment > 0 and alignment > max_align) {
        is_aligned = true;
        ptr = platform.aligned_alloc(size, alignment);
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
        if (new_ptr != null) {
            if (actual_old_size > 0) {
                const copy_size = if (actual_old_size < new_size) actual_old_size else new_size;
                _ = c.memcpy(new_ptr, ptr, copy_size);
            }

            if (is_aligned) {
                platform.aligned_free(ptr);
            } else {
                c.free(ptr);
            }
        } else {
            if (was_tracked) {
                track_alloc(ptr, actual_old_size, is_aligned);
            }
        }
    } else {
        new_ptr = c.realloc(ptr, new_size);
        if (new_ptr != null) {
            track_alloc(new_ptr, new_size, false);
        } else {
            if (was_tracked) {
                track_alloc(ptr, actual_old_size, is_aligned);
            }
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
        platform.aligned_free(ptr);
    } else {
        c.free(ptr);
    }
}

/// Linear bump allocator implementation.
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

fn lin_free(_: *CardinalAllocator, _: ?*anyopaque) callconv(.c) void {}

fn lin_reset(self: *CardinalAllocator) callconv(.c) void {
    const st: *LinearState = @ptrCast(@alignCast(self.state));
    st.offset = 0;
}

/// Arena allocator implementation.
fn arena_create_block(backing: *CardinalAllocator, capacity: usize) ?*ArenaBlock {
    const total_size = @sizeOf(ArenaBlock) + capacity;
    const ptr = backing.alloc(backing, total_size, @alignOf(ArenaBlock));
    if (ptr == null) return null;

    const block: *ArenaBlock = @ptrCast(@alignCast(ptr));
    block.next = null;
    block.capacity = capacity;
    block.offset = 0;

    const ptr_int = @intFromPtr(ptr);
    block.data = @ptrFromInt(ptr_int + @sizeOf(ArenaBlock));

    return block;
}

/// Allocates from the current arena block, creating a new block when needed.
fn arena_alloc(self: *CardinalAllocator, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const st: *ArenaState = @ptrCast(@alignCast(self.state));
    const align_val = if (alignment > 0) alignment else @sizeOf(?*anyopaque);

    if (st.current_block) |block| {
        const ptr_int = @intFromPtr(block.data) + block.offset;
        const mis = ptr_int % align_val;
        const pad = if (mis > 0) align_val - mis else 0;

        if (block.offset + pad + size <= block.capacity) {
            block.offset += pad + size;
            return @ptrFromInt(ptr_int + pad);
        }
    }

    const block_size = if (size > st.default_block_size) size else st.default_block_size;
    const new_block = arena_create_block(st.backing, block_size);
    if (new_block == null) return null;

    new_block.?.next = st.current_block;
    st.current_block = new_block;

    // TODO: Simplify arena block alignment logic.
    const block = new_block.?;
    const ptr_int = @intFromPtr(block.data);
    const mis = ptr_int % align_val;
    const pad = if (mis > 0) align_val - mis else 0;

    block.offset = pad + size;
    return @ptrFromInt(ptr_int + pad);
}

/// Attempts an in-place arena realloc when `ptr` is the most recent allocation.
fn arena_realloc(self: *CardinalAllocator, ptr: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return arena_alloc(self, new_size, alignment);

    const st: *ArenaState = @ptrCast(@alignCast(self.state));

    if (st.current_block) |block| {
        const ptr_addr = @intFromPtr(ptr);
        const align_val = if (alignment > 0) alignment else @sizeOf(?*anyopaque);

        if (ptr_addr % align_val == 0) {
            const block_data_addr = @intFromPtr(block.data);
            const current_end = block_data_addr + block.offset;

            if (ptr_addr + old_size == current_end) {
                if (new_size > old_size) {
                    const diff = new_size - old_size;
                    if (block.offset + diff <= block.capacity) {
                        block.offset += diff;
                        return ptr;
                    }
                } else if (new_size < old_size) {
                    const diff = old_size - new_size;
                    block.offset -= diff;
                    return ptr;
                } else {
                    return ptr;
                }
            }
        }
    }

    const new_ptr = arena_alloc(self, new_size, alignment);
    if (new_ptr != null and old_size > 0) {
        const copy_len = if (old_size < new_size) old_size else new_size;
        _ = c.memcpy(new_ptr, ptr, copy_len);
    }
    return new_ptr;
}

/// Individual frees are ignored; call `arena_reset` to release arena memory.
fn arena_free(_: *CardinalAllocator, _: ?*anyopaque) callconv(.c) void {}

/// Frees all arena blocks.
fn arena_reset(self: *CardinalAllocator) callconv(.c) void {
    const st: *ArenaState = @ptrCast(@alignCast(self.state));

    var curr = st.current_block;
    while (curr) |block| {
        const next = block.next;
        st.backing.free(st.backing, block);
        curr = next;
    }
    st.current_block = null;
}

/// Tracked allocator wrapper that updates per-category statistics.
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

/// Initializes global allocators and per-category tracked allocators.
pub export fn cardinal_memory_init(default_linear_capacity: usize) void {
    cardinal_memory_reset_stats();

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

    g_arena_state = .{
        .backing = &g_dynamic,
        .current_block = null,
        .default_block_size = 4 * 1024 * 1024,
    };
    g_arena = .{
        .type = .ARENA,
        .name = "arena",
        .category = .ENGINE,
        .state = &g_arena_state,
        .alloc = arena_alloc,
        .realloc = arena_realloc,
        .free = arena_free,
        .reset = arena_reset,
    };

    var i: usize = 0;
    while (i < CATEGORY_SLOT_COUNT) : (i += 1) {
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

/// Shuts down the memory subsystem and releases allocator backing storage.
pub export fn cardinal_memory_shutdown() void {
    if (!g_initialized) return;
    g_initialized = false;

    arena_reset(&g_arena);

    if (g_linear_state.capacity > 0) {
        if (g_linear_state.buffer) |b| {
            c.free(@ptrCast(b));
        }
        g_linear_state.buffer = null;
        g_linear_state.capacity = 0;
        g_linear_state.offset = 0;
    }

    g_alloc_map_lock.lock();
    defer g_alloc_map_lock.unlock();

    if (g_alloc_map_init) {
        if (g_alloc_map.count() > 0) {
            _ = c.printf("[Memory] Warning: %d allocations leaked at shutdown.\n", g_alloc_map.count());

            if (builtin.mode == .Debug) {
                var it = g_alloc_map.iterator();
                while (it.next()) |entry| {
                    const info = entry.value_ptr;
                    _ = c.printf("  Leak: %p, Size: %zu\n", info.ptr, info.size);

                    if (info.stack_depth > 0) {
                        _ = c.printf("    Stack Trace:\n");
                        print_stack_trace(&info.stack_addresses, info.stack_depth);
                    }
                }
            }
        }
        g_alloc_map.deinit();
        g_alloc_map_init = false;
        g_active_allocs = 0;
    }
}

export fn cardinal_get_dynamic_allocator() *CardinalAllocator {
    return &g_dynamic;
}

export fn cardinal_get_linear_allocator() *CardinalAllocator {
    return &g_linear;
}

export fn cardinal_get_arena_allocator() *CardinalAllocator {
    return &g_arena;
}

/// Returns the tracked allocator for a memory category (falls back to UNKNOWN).
pub export fn cardinal_get_allocator_for_category(category: CardinalMemoryCategory) *CardinalAllocator {
    const idx = @as(usize, @intCast(@intFromEnum(category)));
    if (idx >= CATEGORY_SLOT_COUNT) {
        return &g_tracked[@as(usize, @intCast(@intFromEnum(CardinalMemoryCategory.UNKNOWN)))];
    }
    return &g_tracked[@intCast(idx)];
}

/// Allocates `size` bytes from `allocator`.
pub export fn cardinal_alloc(allocator: *CardinalAllocator, size: usize) callconv(.c) ?*anyopaque {
    return allocator.alloc(allocator, size, 0);
}

/// Frees a pointer previously allocated by the same allocator.
pub export fn cardinal_free(allocator: *CardinalAllocator, ptr: ?*anyopaque) callconv(.c) void {
    allocator.free(allocator, ptr);
}

/// Reallocates `ptr` to `size` bytes (allocator-specific semantics).
pub export fn cardinal_realloc(allocator: *CardinalAllocator, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return allocator.realloc(allocator, ptr, 0, size, 0);
}

/// Allocates `count * size` bytes and zero-initializes the result.
pub export fn cardinal_calloc(allocator: *CardinalAllocator, count: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = count * size;
    const ptr = allocator.alloc(allocator, total, 0);
    if (ptr) |p| {
        _ = c.memset(p, 0, total);
    }
    return ptr;
}

/// Creates a heap-backed linear allocator instance.
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

/// Destroys an allocator created by `cardinal_linear_allocator_create`.
pub export fn cardinal_linear_allocator_destroy(allocator: ?*CardinalAllocator) void {
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

/// Creates an arena allocator backed by `backing_allocator`.
pub export fn cardinal_arena_create(backing_allocator: ?*CardinalAllocator, default_block_size: usize) ?*CardinalAllocator {
    if (backing_allocator == null) return null;

    const backing = backing_allocator.?;

    const state_ptr = backing.alloc(backing, @sizeOf(ArenaState), @alignOf(ArenaState));
    if (state_ptr == null) return null;

    const state: *ArenaState = @ptrCast(@alignCast(state_ptr));
    state.backing = backing;
    state.current_block = null;
    state.default_block_size = if (default_block_size > 0) default_block_size else 4096;

    const alloc_ptr = backing.alloc(backing, @sizeOf(CardinalAllocator), @alignOf(CardinalAllocator));
    if (alloc_ptr == null) {
        backing.free(backing, state_ptr);
        return null;
    }
    const allocator: *CardinalAllocator = @ptrCast(@alignCast(alloc_ptr));

    allocator.* = .{
        .type = .ARENA,
        .name = "arena",
        .category = .TEMPORARY,
        .state = state,
        .alloc = arena_alloc,
        .realloc = arena_realloc,
        .free = arena_free,
        .reset = arena_reset,
    };

    return allocator;
}

/// Destroys an allocator created by `cardinal_arena_create`.
pub export fn cardinal_arena_destroy(allocator: ?*CardinalAllocator) void {
    if (allocator) |a| {
        if (a.type != .ARENA) return;

        const st: *ArenaState = @ptrCast(@alignCast(a.state));
        const backing = st.backing;

        var curr = st.current_block;
        while (curr) |block| {
            const next = block.next;
            backing.free(backing, block);
            curr = next;
        }

        backing.free(backing, st);
        backing.free(backing, a);
    }
}
