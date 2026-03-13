//! Simple bump/stack allocator over a fixed buffer.
//!
//! Supports markers for bulk rollbacks. Exposes a `std.mem.Allocator` adapter for convenience.
//!
//! TODO: Add optional bounds-checking mode that stores the last allocation size for `free`.
const std = @import("std");
const memory = @import("memory.zig");

/// Stack allocator state backed by a caller-provided buffer.
pub const StackAllocator = struct {
    buffer: []u8,
    offset: usize,

    /// Marker captured from `getMarker` used by `freeToMarker`.
    pub const Marker = usize;

    /// Creates an allocator over `buffer`.
    pub fn init(buffer: []u8) StackAllocator {
        return .{
            .buffer = buffer,
            .offset = 0,
        };
    }

    /// Allocates `size` bytes aligned to `alignment` from the current top.
    pub fn alloc(self: *StackAllocator, size: usize, alignment: u29) ![]u8 {
        const ptr = @intFromPtr(self.buffer.ptr) + self.offset;
        const aligned_ptr = std.mem.alignForward(usize, ptr, alignment);
        const padding = aligned_ptr - ptr;

        if (self.offset + padding + size > self.buffer.len) {
            return error.OutOfMemory;
        }

        self.offset += padding + size;
        return self.buffer[(aligned_ptr - @intFromPtr(self.buffer.ptr))..][0..size];
    }

    /// Returns a marker representing the current allocation offset.
    pub fn getMarker(self: *StackAllocator) Marker {
        return self.offset;
    }

    /// Resets the allocator to a previous marker.
    pub fn freeToMarker(self: *StackAllocator, marker: Marker) void {
        std.debug.assert(marker <= self.offset);
        self.offset = marker;
    }

    /// Resets the allocator to the beginning of the buffer.
    pub fn reset(self: *StackAllocator) void {
        self.offset = 0;
    }

    /// Returns a `std.mem.Allocator` interface backed by this stack allocator.
    pub fn allocator(self: *StackAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .free = freeFn,
                .remap = remapFn,
            },
        };
    }

    /// `std.mem.Allocator.alloc` implementation.
    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self = @as(*StackAllocator, @ptrCast(@alignCast(ctx)));
        const align_val = @as(u29, @intCast(ptr_align.toByteUnits()));
        const result = self.alloc(len, align_val) catch return null;
        return result.ptr;
    }

    /// `std.mem.Allocator.resize` implementation (only supports resizing the last allocation).
    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = buf_align;
        _ = ret_addr;
        const self = @as(*StackAllocator, @ptrCast(@alignCast(ctx)));

        const end_offset = (@intFromPtr(buf.ptr) - @intFromPtr(self.buffer.ptr)) + buf.len;
        if (end_offset == self.offset) {
            if (new_len > buf.len) {
                const diff = new_len - buf.len;
                if (self.offset + diff > self.buffer.len) return false;
                self.offset += diff;
                return true;
            } else {
                const diff = buf.len - new_len;
                self.offset -= diff;
                return true;
            }
        }
        return false;
    }

    /// `std.mem.Allocator.free` implementation (only pops when freeing the last allocation).
    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = buf_align;
        _ = ret_addr;
        const self = @as(*StackAllocator, @ptrCast(@alignCast(ctx)));
        const end_offset = (@intFromPtr(buf.ptr) - @intFromPtr(self.buffer.ptr)) + buf.len;
        if (end_offset == self.offset) {
            self.offset -= buf.len;
        }
    }

    /// `std.mem.Allocator.remap` implementation (not supported by this allocator).
    fn remapFn(ctx: *anyopaque, memory_slice: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory_slice;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }
};
