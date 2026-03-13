//! Entity identifiers and lifecycle management.
//!
//! Entities are opaque handles with an index and generation, backed by a handle manager.
const std = @import("std");
const handle_manager = @import("../core/handle_manager.zig");

/// Raw entity identifier encoding `{ generation: u32, index: u32 }` into a `u64`.
pub const EntityId = u64;

/// Opaque entity handle with index+generation packed into a `u64`.
pub const Entity = struct {
    id: EntityId,

    /// Returns the entity's dense index portion.
    pub fn index(self: Entity) u32 {
        return @truncate(self.id);
    }

    /// Returns the entity's generation portion.
    pub fn generation(self: Entity) u32 {
        return @truncate(self.id >> 32);
    }

    /// Constructs an entity handle from index and generation.
    pub fn make(idx: u32, gen: u32) Entity {
        return .{ .id = (@as(u64, gen) << 32) | idx };
    }
};

/// Creates, destroys, and validates entities.
pub const EntityManager = struct {
    handles: handle_manager.HandleManager,

    /// Creates an entity manager backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) EntityManager {
        return .{
            .handles = handle_manager.HandleManager.init(allocator),
        };
    }

    /// Releases internal storage.
    pub fn deinit(self: *EntityManager) void {
        self.handles.deinit();
    }

    /// Allocates a new entity handle.
    pub fn create(self: *EntityManager) !Entity {
        const allocation = try self.handles.allocate();
        return Entity.make(allocation.index, allocation.generation);
    }

    /// Destroys an entity handle. Returns false if it was already invalid.
    pub fn destroy(self: *EntityManager, entity: Entity) bool {
        return self.handles.free(entity.index(), entity.generation());
    }

    /// Returns true if the entity handle refers to a live entity.
    pub fn is_alive(self: *const EntityManager, entity: Entity) bool {
        return self.handles.is_valid(entity.index(), entity.generation());
    }
};
