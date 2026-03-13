//! Component storage abstractions.
//!
//! Components are stored in per-type sparse sets. This file provides a type-erased storage
//! interface and a generic `SparseSet(T)` implementation.
const std = @import("std");
const entity_pkg = @import("entity.zig");
const Entity = entity_pkg.Entity;

/// Type-erased interface for component storages.
pub const StorageInterface = struct {
    ptr: *anyopaque,
    remove_fn: *const fn (ptr: *anyopaque, entity: Entity) void,

    /// Removes all data for `entity` from the underlying storage.
    pub fn remove(self: StorageInterface, entity: Entity) void {
        self.remove_fn(self.ptr, entity);
    }
};

/// Sparse-set storage for a component type `T`.
pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        // Sparse array: maps Entity Index -> Dense Index
        // We use ArrayList but we need to handle gaps or resize manually
        // For simplicity, we'll use a large enough array or resize on demand
        sparse: std.ArrayListUnmanaged(u32),

        // Dense arrays
        packed_entities: std.ArrayListUnmanaged(Entity),
        components: std.ArrayListUnmanaged(T),

        allocator: std.mem.Allocator,

        /// Creates an empty sparse set.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .sparse = .{},
                .packed_entities = .{},
                .components = .{},
                .allocator = allocator,
            };
        }

        /// Releases internal storage.
        pub fn deinit(self: *Self) void {
            self.sparse.deinit(self.allocator);
            self.packed_entities.deinit(self.allocator);
            self.components.deinit(self.allocator);
        }

        /// Inserts or overwrites `component` for `entity`.
        pub fn set(self: *Self, entity: Entity, component: T) !void {
            const idx = entity.index();

            // Ensure sparse array is big enough
            if (idx >= self.sparse.items.len) {
                const old_len = self.sparse.items.len;
                const new_len = idx + 1;
                // Fill with maxInt to indicate empty
                try self.sparse.resize(self.allocator, new_len);
                @memset(self.sparse.items[old_len..], std.math.maxInt(u32));
            }

            const dense_idx = self.sparse.items[idx];

            if (dense_idx != std.math.maxInt(u32) and dense_idx < self.packed_entities.items.len) {
                // Update existing
                // Verify generation? Ideally yes, but sparse set usually assumes valid entity
                self.components.items[dense_idx] = component;
                self.packed_entities.items[dense_idx] = entity; // Update generation just in case
            } else {
                // Add new
                const new_dense_idx = @as(u32, @intCast(self.packed_entities.items.len));
                try self.packed_entities.append(self.allocator, entity);
                try self.components.append(self.allocator, component);
                self.sparse.items[idx] = new_dense_idx;
            }
        }

        /// Returns a mutable pointer to `T` for `entity` if present and generation matches.
        pub fn get(self: *Self, entity: Entity) ?*T {
            const idx = entity.index();
            if (idx >= self.sparse.items.len) return null;

            const dense_idx = self.sparse.items[idx];
            if (dense_idx == std.math.maxInt(u32)) return null;

            // Check generation
            if (self.packed_entities.items[dense_idx].id != entity.id) return null;

            return &self.components.items[dense_idx];
        }

        /// Removes `entity` from the set if present.
        pub fn remove(self: *Self, entity: Entity) void {
            const idx = entity.index();
            if (idx >= self.sparse.items.len) return;

            const dense_idx = self.sparse.items[idx];
            if (dense_idx == std.math.maxInt(u32)) return;

            // Check generation
            if (self.packed_entities.items[dense_idx].id != entity.id) return;

            // Swap and pop
            const last_idx = self.packed_entities.items.len - 1;
            const last_entity = self.packed_entities.items[last_idx];

            // Move last element to deleted slot
            self.packed_entities.items[dense_idx] = last_entity;
            self.components.items[dense_idx] = self.components.items[last_idx];

            // Update sparse map for the moved entity
            self.sparse.items[last_entity.index()] = dense_idx;

            // Mark deleted slot as empty in sparse map
            self.sparse.items[idx] = std.math.maxInt(u32);

            // Pop
            _ = self.packed_entities.pop();
            _ = self.components.pop();
        }

        /// Returns true if `entity` exists in the set and generation matches.
        pub fn has(self: *Self, entity: Entity) bool {
            const idx = entity.index();
            if (idx >= self.sparse.items.len) return false;

            const dense_idx = self.sparse.items[idx];
            if (dense_idx == std.math.maxInt(u32)) return false;

            return self.packed_entities.items[dense_idx].id == entity.id;
        }

        /// Removes all entities and components, retaining capacity.
        pub fn clear(self: *Self) void {
            self.packed_entities.clearRetainingCapacity();
            self.components.clearRetainingCapacity();
            @memset(self.sparse.items, std.math.maxInt(u32));
        }

        // Type erased interface wrapper
        fn remove_wrapper(ptr: *anyopaque, entity: Entity) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.remove(entity);
        }

        /// Returns a type-erased interface for the storage.
        pub fn interface(self: *Self) StorageInterface {
            return .{
                .ptr = self,
                .remove_fn = remove_wrapper,
            };
        }
    };
}
