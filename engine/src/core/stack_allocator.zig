const std = @import("std");
const memory = @import("memory.zig");

pub const StackAllocator = struct {
    buffer: []u8,
    offset: usize,

    pub const Marker = usize;

    pub fn init(buffer: []u8) StackAllocator {
        return .{
            .buffer = buffer,
            .offset = 0,
        };
    }

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

    pub fn getMarker(self: *StackAllocator) Marker {
        return self.offset;
    }

    pub fn freeToMarker(self: *StackAllocator, marker: Marker) void {
        std.debug.assert(marker <= self.offset);
        self.offset = marker;
    }

    pub fn reset(self: *StackAllocator) void {
        self.offset = 0;
    }

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

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self = @as(*StackAllocator, @ptrCast(@alignCast(ctx)));
        const align_val = @as(u29, @intCast(ptr_align.toByteUnits()));
        const result = self.alloc(len, align_val) catch return null;
        return result.ptr;
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = buf_align;
        _ = ret_addr;
        const self = @as(*StackAllocator, @ptrCast(@alignCast(ctx)));

        // We can only resize if it's the last allocation
        const end_offset = (@intFromPtr(buf.ptr) - @intFromPtr(self.buffer.ptr)) + buf.len;
        if (end_offset == self.offset) {
            if (new_len > buf.len) {
                // Grow
                const diff = new_len - buf.len;
                if (self.offset + diff > self.buffer.len) return false;
                self.offset += diff;
                return true;
            } else {
                // Shrink
                const diff = buf.len - new_len;
                self.offset -= diff;
                return true;
            }
        }
        return false;
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = buf_align;
        _ = ret_addr;
        const self = @as(*StackAllocator, @ptrCast(@alignCast(ctx)));
        // Free is a no-op unless it's the top of the stack (optimization)
        const end_offset = (@intFromPtr(buf.ptr) - @intFromPtr(self.buffer.ptr)) + buf.len;
        if (end_offset == self.offset) {
            self.offset -= buf.len;
        }
    }

    fn remapFn(ctx: *anyopaque, memory_slice: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory_slice;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        // Stack allocator doesn't support remapping to a new address efficiently without moving
        // (unless it's the last one, which resizeFn handles)
        return null;
    }
};
