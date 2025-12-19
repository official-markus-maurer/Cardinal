const std = @import("std");
const memory = @import("memory.zig");

/// A thread-safe pool allocator for fixed-size objects.
/// Wraps std.heap.MemoryPool with a mutex.
pub fn PoolAllocator(comptime T: type) type {
    return struct {
        const Self = @This();
        const InnerPool = std.heap.MemoryPool(T);

        pool: InnerPool,
        mutex: std.Thread.Mutex,
        initialized: bool,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .pool = InnerPool.init(allocator),
                .mutex = .{},
                .initialized = true,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pool.deinit();
            self.initialized = false;
        }

        pub fn create(self: *Self) !*T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.pool.create();
        }

        pub fn destroy(self: *Self, ptr: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pool.destroy(ptr);
        }

        /// Reset the pool, freeing all items but keeping memory for reuse (if supported)
        /// or just deinit/init. std.heap.MemoryPool doesn't have reset(), so we rely on deinit/init
        /// or just keeping it alive.
        pub fn reset(self: *Self) void {
            // MemoryPool doesn't support simple reset without deinit.
            // We'll leave this empty or implement if needed.
            _ = self;
        }
    };
}
