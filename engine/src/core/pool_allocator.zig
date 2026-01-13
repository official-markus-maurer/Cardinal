const std = @import("std");
const memory = @import("memory.zig");

/// A thread-safe pool allocator for fixed-size objects.
/// Implemented using an ArenaAllocator and a free list to support efficient reset.
pub fn PoolAllocator(comptime T: type) type {
    return struct {
        const Self = @This();
        
        // We need a node structure for the free list.
        // It must fit within the allocated memory for T.
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

            // Allocate new item from arena
            // Ensure size and alignment cover both T and Node (for reuse)
            const size = @max(@sizeOf(T), @sizeOf(Node));
            const alignment = comptime std.mem.Alignment.fromByteUnits(@max(@alignOf(T), @alignOf(Node)));
            
            const slice = try self.arena.allocator().alignedAlloc(u8, alignment, size);
            return @ptrCast(slice.ptr);
        }

        pub fn destroy(self: *Self, ptr: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Add to free list
            const node: *Node = @ptrCast(ptr);
            node.next = self.free_list;
            self.free_list = node;
        }

        /// Reset the pool, freeing all items but keeping memory for reuse.
        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            // Reset arena (retain capacity for efficiency)
            _ = self.arena.reset(.retain_capacity);
            // Clear free list (all nodes are effectively freed/invalidated)
            self.free_list = null;
        }
    };
}
