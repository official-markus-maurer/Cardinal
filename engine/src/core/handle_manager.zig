const std = @import("std");

pub const HandleManager = struct {
    generations: std.ArrayListUnmanaged(u32),
    free_indices: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HandleManager {
        return .{
            .generations = .{},
            .free_indices = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HandleManager) void {
        self.generations.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
    }

    pub const Allocation = struct {
        index: u32,
        generation: u32,
    };

    pub fn allocate(self: *HandleManager) !Allocation {
        var index: u32 = 0;
        var generation: u32 = 1;

        if (self.free_indices.items.len > 0) {
            index = self.free_indices.pop().?;
            generation = self.generations.items[index];
        } else {
            index = @intCast(self.generations.items.len);
            try self.generations.append(self.allocator, generation);
        }

        return Allocation{ .index = index, .generation = generation };
    }

    pub fn free(self: *HandleManager, index: u32, generation: u32) bool {
        if (index >= self.generations.items.len) return false;
        if (self.generations.items[index] != generation) return false;

        // Increment generation to invalidate current handle
        self.generations.items[index] += 1;
        if (self.generations.items[index] == 0) self.generations.items[index] = 1;

        self.free_indices.append(self.allocator, index) catch return false;
        return true;
    }

    pub fn is_valid(self: *const HandleManager, index: u32, generation: u32) bool {
        if (index >= self.generations.items.len) return false;
        return self.generations.items[index] == generation;
    }

    pub fn get_generation(self: *const HandleManager, index: u32) u32 {
        if (index >= self.generations.items.len) return 0;
        return self.generations.items[index];
    }
};

test "HandleManager basic usage" {
    const allocator = std.testing.allocator;
    var manager = HandleManager.init(allocator);
    defer manager.deinit();

    // Test allocation
    const h1 = try manager.allocate();
    try std.testing.expectEqual(@as(u32, 0), h1.index);
    try std.testing.expectEqual(@as(u32, 1), h1.generation);
    try std.testing.expect(manager.is_valid(h1.index, h1.generation));

    const h2 = try manager.allocate();
    try std.testing.expectEqual(@as(u32, 1), h2.index);
    try std.testing.expectEqual(@as(u32, 1), h2.generation);

    // Test free
    try std.testing.expect(manager.free(h1.index, h1.generation));
    try std.testing.expect(!manager.is_valid(h1.index, h1.generation));

    // Test reuse
    const h3 = try manager.allocate();
    try std.testing.expectEqual(@as(u32, 0), h3.index);
    try std.testing.expectEqual(@as(u32, 2), h3.generation);
    try std.testing.expect(manager.is_valid(h3.index, h3.generation));
}
