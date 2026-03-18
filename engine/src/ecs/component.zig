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

        /// Maps entity index -> dense index, or maxInt(u32) for empty.
        sparse_chunks: std.ArrayListUnmanaged(?*SparseChunk),

        /// Dense entity list parallel to `components`.
        packed_entities: std.ArrayListUnmanaged(Entity),
        /// Dense component storage parallel to `packed_entities`.
        components: std.ArrayListUnmanaged(T),

        allocator: std.mem.Allocator,

        const empty_dense_index = std.math.maxInt(u32);
        const sparse_chunk_shift: comptime_int = 10;
        const sparse_chunk_size: comptime_int = 1 << sparse_chunk_shift;
        const sparse_chunk_mask: usize = sparse_chunk_size - 1;
        const SparseChunk = [sparse_chunk_size]u32;

        /// Creates an empty sparse set.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .sparse_chunks = .{},
                .packed_entities = .{},
                .components = .{},
                .allocator = allocator,
            };
        }

        /// Releases internal storage.
        pub fn deinit(self: *Self) void {
            for (self.sparse_chunks.items) |chunk_opt| {
                if (chunk_opt) |chunk| {
                    self.allocator.destroy(chunk);
                }
            }
            self.sparse_chunks.deinit(self.allocator);
            self.packed_entities.deinit(self.allocator);
            self.components.deinit(self.allocator);
        }

        fn assure_chunk(self: *Self, chunk_index: usize) !*SparseChunk {
            if (chunk_index >= self.sparse_chunks.items.len) {
                const old_len = self.sparse_chunks.items.len;
                const new_len = chunk_index + 1;
                try self.sparse_chunks.resize(self.allocator, new_len);
                @memset(self.sparse_chunks.items[old_len..], null);
            }

            if (self.sparse_chunks.items[chunk_index] == null) {
                const chunk = try self.allocator.create(SparseChunk);
                @memset(chunk, empty_dense_index);
                self.sparse_chunks.items[chunk_index] = chunk;
            }

            return self.sparse_chunks.items[chunk_index].?;
        }

        fn get_slot_ptr(self: *Self, entity_index: u32) ?*u32 {
            const idx: usize = @intCast(entity_index);
            const chunk_index = idx >> sparse_chunk_shift;
            if (chunk_index >= self.sparse_chunks.items.len) return null;
            const chunk = self.sparse_chunks.items[chunk_index] orelse return null;
            return &chunk[idx & sparse_chunk_mask];
        }

        fn assure_slot_ptr(self: *Self, entity_index: u32) !*u32 {
            const idx: usize = @intCast(entity_index);
            const chunk_index = idx >> sparse_chunk_shift;
            const chunk = try self.assure_chunk(chunk_index);
            return &chunk[idx & sparse_chunk_mask];
        }

        /// Inserts or overwrites `component` for `entity`.
        pub fn set(self: *Self, entity: Entity, component: T) !void {
            const idx = entity.index();
            const slot = try self.assure_slot_ptr(idx);
            const dense_idx = slot.*;

            if (dense_idx != empty_dense_index and dense_idx < self.packed_entities.items.len) {
                self.components.items[dense_idx] = component;
                self.packed_entities.items[dense_idx] = entity;
            } else {
                const new_dense_idx = @as(u32, @intCast(self.packed_entities.items.len));
                try self.packed_entities.append(self.allocator, entity);
                try self.components.append(self.allocator, component);
                slot.* = new_dense_idx;
            }
        }

        /// Returns a mutable pointer to `T` for `entity` if present and generation matches.
        pub fn get(self: *Self, entity: Entity) ?*T {
            const slot = self.get_slot_ptr(entity.index()) orelse return null;
            const dense_idx = slot.*;
            if (dense_idx == empty_dense_index) return null;
            if (dense_idx >= self.packed_entities.items.len) return null;
            if (self.packed_entities.items[dense_idx].id != entity.id) return null;

            return &self.components.items[dense_idx];
        }

        /// Removes `entity` from the set if present.
        pub fn remove(self: *Self, entity: Entity) void {
            const slot = self.get_slot_ptr(entity.index()) orelse return;
            const dense_idx = slot.*;
            if (dense_idx == empty_dense_index) return;
            if (dense_idx >= self.packed_entities.items.len) return;
            if (self.packed_entities.items[dense_idx].id != entity.id) return;

            const last_idx = self.packed_entities.items.len - 1;
            const last_entity = self.packed_entities.items[last_idx];

            self.packed_entities.items[dense_idx] = last_entity;
            self.components.items[dense_idx] = self.components.items[last_idx];

            if (self.get_slot_ptr(last_entity.index())) |moved_slot| {
                moved_slot.* = @intCast(dense_idx);
            }

            slot.* = empty_dense_index;

            _ = self.packed_entities.pop();
            _ = self.components.pop();
        }

        /// Returns true if `entity` exists in the set and generation matches.
        pub fn has(self: *Self, entity: Entity) bool {
            const slot = self.get_slot_ptr(entity.index()) orelse return false;
            const dense_idx = slot.*;
            if (dense_idx == empty_dense_index) return false;
            if (dense_idx >= self.packed_entities.items.len) return false;
            return self.packed_entities.items[dense_idx].id == entity.id;
        }

        /// Removes all entities and components, retaining capacity.
        pub fn clear(self: *Self) void {
            self.packed_entities.clearRetainingCapacity();
            self.components.clearRetainingCapacity();
            for (self.sparse_chunks.items) |chunk_opt| {
                if (chunk_opt) |chunk| {
                    @memset(chunk, empty_dense_index);
                }
            }
        }

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
