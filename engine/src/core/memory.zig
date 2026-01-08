const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("stdio.h");
});

// External C functions for aligned allocation
extern "c" fn _aligned_malloc(size: usize, alignment: usize) ?*anyopaque;
extern "c" fn _aligned_free(ptr: ?*anyopaque) void;
extern "c" fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) c_int;

// Windows Stack Trace
extern "kernel32" fn RtlCaptureStackBackTrace(
    FramesToSkip: u32,
    FramesToCapture: u32,
    BackTrace: [*]?*anyopaque,
    BackTraceHash: ?*u32,
) u16;

// Enums and Structs matching C header
pub const CardinalMemoryCategory = enum(c_int) { UNKNOWN = 0, ENGINE, RENDERER, VULKAN_BUFFERS, VULKAN_DEVICE, TEXTURES, MESHES, ASSETS, SHADERS, WINDOW, LOGGING, TEMPORARY, MAX };

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
    data: [*]u8, // Flexible array member in C, pointer here
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
    stack_addresses: [16]usize,
    stack_depth: usize,
};

// Global State
var g_stats: CardinalGlobalMemoryStats = std.mem.zeroes(CardinalGlobalMemoryStats);
var g_alloc_map: std.AutoHashMap(usize, AllocInfo) = undefined;
var g_alloc_map_lock: std.Thread.RwLock = .{};
var g_alloc_map_init: bool = false;
var g_active_allocs: usize = 0;

var g_dynamic_state: DynamicState = .{ .placeholder = 0 };
var g_linear_state: LinearState = undefined;
var g_arena_state: ArenaState = undefined;
var g_tracked_state: [12]TrackedState = undefined;

var g_dynamic: CardinalAllocator = undefined;
var g_linear: CardinalAllocator = undefined;
var g_arena: CardinalAllocator = undefined;
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

pub export fn cardinal_memory_get_stats(out_stats: ?*CardinalGlobalMemoryStats) void {
    if (out_stats) |s| {
        s.* = g_stats;
    }
}

pub export fn cardinal_memory_reset_stats() void {
    g_stats = std.mem.zeroes(CardinalGlobalMemoryStats);
}

// Allocation Tracking
fn ensure_alloc_map() void {
    if (!g_alloc_map_init) {
        g_alloc_map = std.AutoHashMap(usize, AllocInfo).init(std.heap.c_allocator);
        g_alloc_map_init = true;
    }
}

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

    // Capture stack trace if debug build
    if (builtin.mode == .Debug) {
        if (builtin.os.tag == .windows) {
             // Use Windows API for faster/safer stack walking
             // Skip 0 frames (capture current), capture up to 16
             var stack: [16]?*anyopaque = undefined;
             const count = RtlCaptureStackBackTrace(0, 16, &stack, null);
             
             var i: usize = 0;
             while (i < count) : (i += 1) {
                 info.stack_addresses[i] = @intFromPtr(stack[i]);
             }
             info.stack_depth = count;
        } else {
            // Fallback for other OSs using Zig's StackIterator
            var it = std.debug.StackIterator.init(@returnAddress(), null);
            var idx: usize = 0;
            while (it.next()) |return_address| : (idx += 1) {
                if (idx >= 16) break;
                info.stack_addresses[idx] = return_address;
            }
            info.stack_depth = idx;
        }

        // Fallback: If stack capture failed to find anything, at least grab the immediate caller
        if (info.stack_depth == 0) {
            info.stack_addresses[0] = @returnAddress();
            info.stack_depth = 1;
        }
    }

    g_alloc_map.put(addr, info) catch |err| {
        _ = c.printf("Cardinal Memory Error: Failed to track allocation (OOM?): %s\n", @errorName(err).ptr);
    };
    g_active_allocs = g_alloc_map.count();
}

// Helper to resolve and print address
// Since we don't have easy symbol resolution in Zig's std lib for bare metal/C-interop without debug info attached to the binary in a specific way,
// we just print the address. Users can use `addr2line -e CardinalEditor.exe <addr>` to find the line.
// However, we can try to be helpful if we are on Windows and have PDBs? No, too complex.
// Just printing raw addresses is standard for simple leak detectors.
fn print_stack_trace(addresses: []const usize, depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const addr = addresses[i];
        // We can try to use std.debug.print to get some formatting, but we are using C printf for consistency with the rest of the file.
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

// Arena Allocator Implementation
fn arena_create_block(backing: *CardinalAllocator, capacity: usize) ?*ArenaBlock {
    // Layout: [ArenaBlock header] [data ... capacity]
    const total_size = @sizeOf(ArenaBlock) + capacity;
    const ptr = backing.alloc(backing, total_size, @alignOf(ArenaBlock));
    if (ptr == null) return null;

    const block: *ArenaBlock = @ptrCast(@alignCast(ptr));
    block.next = null;
    block.capacity = capacity;
    block.offset = 0;

    // Data starts after the struct
    const ptr_int = @intFromPtr(ptr);
    block.data = @ptrFromInt(ptr_int + @sizeOf(ArenaBlock));

    return block;
}

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

    // New block needed
    const block_size = if (size > st.default_block_size) size else st.default_block_size;
    const new_block = arena_create_block(st.backing, block_size);
    if (new_block == null) return null;

    // Link
    new_block.?.next = st.current_block;
    st.current_block = new_block;

    // Allocate from new block (guaranteed to fit and be aligned at start)
    // Note: arena_create_block returns aligned pointer for ArenaBlock,
    // but data might need alignment relative to start if header is weirdly sized.
    // However, @sizeOf(ArenaBlock) should be aligned enough.
    // Let's re-calculate just to be safe.

    const block = new_block.?;
    const ptr_int = @intFromPtr(block.data);
    const mis = ptr_int % align_val;
    const pad = if (mis > 0) align_val - mis else 0;

    block.offset = pad + size;
    return @ptrFromInt(ptr_int + pad);
}

fn arena_realloc(self: *CardinalAllocator, ptr: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    // Arenas don't support true realloc easily (in-place expansion), so we alloc-copy
    if (ptr == null) return arena_alloc(self, new_size, alignment);

    const st: *ArenaState = @ptrCast(@alignCast(self.state));

    if (st.current_block) |block| {
        const ptr_addr = @intFromPtr(ptr);
        const align_val = if (alignment > 0) alignment else @sizeOf(?*anyopaque);

        // Cannot expand in place if the existing pointer doesn't satisfy the new alignment
        if (ptr_addr % align_val == 0) {
            const block_data_addr = @intFromPtr(block.data);
            const current_end = block_data_addr + block.offset;

            // Check if this is the last allocation
            if (ptr_addr + old_size == current_end) {
                if (new_size > old_size) {
                    // Expand
                    const diff = new_size - old_size;
                    if (block.offset + diff <= block.capacity) {
                        block.offset += diff;
                        return ptr;
                    }
                } else if (new_size < old_size) {
                    // Shrink
                    const diff = old_size - new_size;
                    block.offset -= diff;
                    return ptr;
                } else {
                    return ptr;
                }
            }
        }
    }

    // Fallback to alloc-copy
    const new_ptr = arena_alloc(self, new_size, alignment);
    if (new_ptr != null and old_size > 0) {
        const copy_len = if (old_size < new_size) old_size else new_size;
        _ = c.memcpy(new_ptr, ptr, copy_len);
    }
    return new_ptr;
}

fn arena_free(_: *CardinalAllocator, _: ?*anyopaque) callconv(.c) void {
    // No-op for individual frees
}

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
pub export fn cardinal_memory_init(default_linear_capacity: usize) void {
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

    // Arena
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

pub export fn cardinal_memory_shutdown() void {
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

pub export fn cardinal_arena_create(backing_allocator: ?*CardinalAllocator, default_block_size: usize) ?*CardinalAllocator {
    if (backing_allocator == null) return null;

    const backing = backing_allocator.?;

    // Allocate state container from backing allocator
    const state_ptr = backing.alloc(backing, @sizeOf(ArenaState), @alignOf(ArenaState));
    if (state_ptr == null) return null;

    const state: *ArenaState = @ptrCast(@alignCast(state_ptr));
    state.backing = backing;
    state.current_block = null;
    state.default_block_size = if (default_block_size > 0) default_block_size else 4096;

    // Allocate Allocator struct
    const alloc_ptr = backing.alloc(backing, @sizeOf(CardinalAllocator), @alignOf(CardinalAllocator));
    if (alloc_ptr == null) {
        backing.free(backing, state_ptr);
        return null;
    }
    const allocator: *CardinalAllocator = @ptrCast(@alignCast(alloc_ptr));

    allocator.* = .{
        .type = .ARENA,
        .name = "arena",
        .category = .TEMPORARY, // Default category, user can change
        .state = state,
        .alloc = arena_alloc,
        .realloc = arena_realloc,
        .free = arena_free,
        .reset = arena_reset,
    };

    return allocator;
}

pub export fn cardinal_arena_destroy(allocator: ?*CardinalAllocator) void {
    if (allocator) |a| {
        if (a.type != .ARENA) return;

        const st: *ArenaState = @ptrCast(@alignCast(a.state));
        const backing = st.backing;

        // Free all blocks
        var curr = st.current_block;
        while (curr) |block| {
            const next = block.next;
            backing.free(backing, block);
            curr = next;
        }

        // Free state and allocator struct
        backing.free(backing, st);
        backing.free(backing, a);
    }
}
