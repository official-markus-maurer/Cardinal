//! Pool allocator for fixed-size objects.
//!
//! Uses an `ArenaAllocator` as backing storage and a free-list to allow `destroy` without
//! returning memory to the OS. Intended for high-churn small objects like jobs and dependency nodes.
//!
//! TODO: Add an optional non-thread-safe mode to avoid mutex overhead in single-threaded use.
const std = @import("std");
const memory = @import("memory.zig");

/// Thread-safe pool allocator for fixed-size objects.
pub fn PoolAllocator(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Node structure used for the free-list (stored in reclaimed object memory).
        const Node = struct {
            next: ?*Node,
        };

        arena: std.heap.ArenaAllocator,
        free_list: ?*Node,
        mutex: std.Thread.Mutex,
        initialized: bool,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .free_list = null,
                .mutex = .{},
                .initialized = true,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.arena.deinit();
            self.initialized = false;
        }

        pub fn create(self: *Self) !*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.free_list) |node| {
                self.free_list = node.next;
                return @ptrCast(node);
            }

            const size = @max(@sizeOf(T), @sizeOf(Node));
            const alignment = comptime std.mem.Alignment.fromByteUnits(@max(@alignOf(T), @alignOf(Node)));

            const slice = try self.arena.allocator().alignedAlloc(u8, alignment, size);
            return @ptrCast(slice.ptr);
        }

        pub fn destroy(self: *Self, ptr: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const node: *Node = @ptrCast(ptr);
            node.next = self.free_list;
            self.free_list = node;
        }

        /// Reset the pool, freeing all items but keeping memory for reuse.
        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            _ = self.arena.reset(.retain_capacity);
            self.free_list = null;
        }
    };
}
