//! Handle allocation and generation tracking.
//!
//! Provides a small allocator for (index, generation) pairs used to build stable handles.
//! Freeing an index increments its generation to invalidate existing handles.
const std = @import("std");

/// Allocates and validates handle indices with generation counters.
pub const HandleManager = struct {
    generations: std.ArrayListUnmanaged(u32),
    free_indices: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    capacity: u32,
    next_unused: u32,

    /// Creates an empty handle manager using `allocator` for internal storage.
    pub fn init(allocator: std.mem.Allocator) HandleManager {
        return .{
            .generations = .{},
            .free_indices = .{},
            .allocator = allocator,
            .capacity = 0,
            .next_unused = 0,
        };
    }

    /// Creates a handle manager with a fixed capacity to avoid reallocations after init.
    pub fn initFixed(allocator: std.mem.Allocator, capacity: u32) !HandleManager {
        var manager = HandleManager{
            .generations = .{},
            .free_indices = .{},
            .allocator = allocator,
            .capacity = capacity,
            .next_unused = 0,
        };

        if (capacity > 0) {
            try manager.generations.resize(allocator, capacity);
            @memset(manager.generations.items, 0);
            try manager.free_indices.ensureTotalCapacityPrecise(allocator, capacity);
        }

        return manager;
    }

    /// Releases internal storage.
    pub fn deinit(self: *HandleManager) void {
        self.generations.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
    }

    pub const Allocation = struct {
        /// Allocated index into the backing generation array.
        index: u32,
        /// Generation value associated with `index` at allocation time.
        generation: u32,
    };

    /// Allocates a new handle allocation.
    pub fn allocate(self: *HandleManager) !Allocation {
        var index: u32 = 0;
        var generation: u32 = 1;

        if (self.free_indices.items.len > 0) {
            index = self.free_indices.pop().?;
            generation = self.generations.items[index];
        } else if (self.capacity > 0) {
            if (self.next_unused >= self.capacity) return error.OutOfHandles;
            index = self.next_unused;
            self.next_unused += 1;
            generation = self.generations.items[index];
            if (generation == 0) {
                generation = 1;
                self.generations.items[index] = generation;
            }
        } else {
            index = @intCast(self.generations.items.len);
            try self.generations.append(self.allocator, generation);
        }

        return Allocation{ .index = index, .generation = generation };
    }

    /// Frees an allocation if `generation` matches, incrementing the generation on success.
    pub fn free(self: *HandleManager, index: u32, generation: u32) bool {
        if (generation == 0) return false;
        if (index >= self.generations.items.len) return false;
        if (self.generations.items[index] != generation) return false;

        self.generations.items[index] += 1;
        if (self.generations.items[index] == 0) self.generations.items[index] = 1;

        if (self.capacity > 0) {
            if (self.free_indices.items.len >= self.capacity) return false;
            self.free_indices.appendAssumeCapacity(index);
        } else {
            self.free_indices.append(self.allocator, index) catch return false;
        }
        return true;
    }

    /// Returns true if `index` is in-range and `generation` matches the current value.
    pub fn is_valid(self: *const HandleManager, index: u32, generation: u32) bool {
        if (generation == 0) return false;
        if (index >= self.generations.items.len) return false;
        return self.generations.items[index] == generation;
    }

    /// Returns the current generation for `index`, or 0 if out-of-range.
    pub fn get_generation(self: *const HandleManager, index: u32) u32 {
        if (index >= self.generations.items.len) return 0;
        return self.generations.items[index];
    }
};

test "HandleManager basic usage" {
    const allocator = std.testing.allocator;
    var manager = HandleManager.init(allocator);
    defer manager.deinit();

    const h1 = try manager.allocate();
    try std.testing.expectEqual(@as(u32, 0), h1.index);
    try std.testing.expectEqual(@as(u32, 1), h1.generation);
    try std.testing.expect(manager.is_valid(h1.index, h1.generation));

    const h2 = try manager.allocate();
    try std.testing.expectEqual(@as(u32, 1), h2.index);
    try std.testing.expectEqual(@as(u32, 1), h2.generation);

    try std.testing.expect(manager.free(h1.index, h1.generation));
    try std.testing.expect(!manager.is_valid(h1.index, h1.generation));

    const h3 = try manager.allocate();
    try std.testing.expectEqual(@as(u32, 0), h3.index);
    try std.testing.expectEqual(@as(u32, 2), h3.generation);
    try std.testing.expect(manager.is_valid(h3.index, h3.generation));
}

test "HandleManager fixed capacity" {
    const allocator = std.testing.allocator;
    var manager = try HandleManager.initFixed(allocator, 2);
    defer manager.deinit();

    const h1 = try manager.allocate();
    const h2 = try manager.allocate();
    try std.testing.expectEqual(@as(u32, 0), h1.index);
    try std.testing.expectEqual(@as(u32, 1), h2.index);
    try std.testing.expectError(error.OutOfHandles, manager.allocate());

    try std.testing.expect(manager.free(h1.index, h1.generation));
    const h3 = try manager.allocate();
    try std.testing.expectEqual(@as(u32, 0), h3.index);
    try std.testing.expectEqual(@as(u32, 2), h3.generation);
}
