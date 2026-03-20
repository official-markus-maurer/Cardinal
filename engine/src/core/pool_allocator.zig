//! Pool allocator for fixed-size objects.
//!
//! Uses an `ArenaAllocator` as backing storage and a free-list to allow `destroy` without
//! returning memory to the OS. Intended for high-churn small objects like jobs and dependency nodes.
const std = @import("std");
const memory = @import("memory.zig");

/// Thread-safe pool allocator for fixed-size objects.
pub fn PoolAllocator(comptime T: type) type {
    return PoolAllocatorWithMode(T, true);
}

/// Non-thread-safe pool allocator for fixed-size objects.
pub fn PoolAllocatorNonThreadSafe(comptime T: type) type {
    return PoolAllocatorWithMode(T, false);
}

fn PoolAllocatorWithMode(comptime T: type, comptime thread_safe: bool) type {
    return struct {
        const Self = @This();

        /// Node structure used for the free-list (stored in reclaimed object memory).
        const Node = struct {
            next: ?*Node,
        };

        const MutexType = if (thread_safe)
            std.Thread.Mutex
        else
            struct {
                pub fn lock(_: *@This()) void {}
                pub fn unlock(_: *@This()) void {}
            };

        arena: std.heap.ArenaAllocator,
        free_list: ?*Node,
        mutex: MutexType,
        initialized: bool,

        /// Initializes the pool using an arena backed by `allocator`.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .free_list = null,
                .mutex = .{},
                .initialized = true,
            };
        }

        /// Releases all pool memory back to the backing allocator.
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.arena.deinit();
            self.initialized = false;
        }

        /// Allocates one `T`, reusing a freed slot when available.
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

        /// Returns `ptr` to the pool for reuse.
        pub fn destroy(self: *Self, ptr: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const node: *Node = @ptrCast(@alignCast(ptr));
            node.next = self.free_list;
            self.free_list = node;
        }

        /// Resets the pool, freeing all items but keeping memory for reuse.
        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            _ = self.arena.reset(.retain_capacity);
            self.free_list = null;
        }
    };
}

test "PoolAllocator non-thread-safe mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var pool = PoolAllocatorNonThreadSafe(u32).init(arena.allocator());
    defer pool.deinit();

    const a = try pool.create();
    const b = try pool.create();
    a.* = 10;
    b.* = 20;

    pool.destroy(a);
    pool.destroy(b);

    const c = try pool.create();
    const d = try pool.create();
    _ = c;
    _ = d;

    pool.reset();
}
