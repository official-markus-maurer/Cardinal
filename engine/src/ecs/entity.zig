const std = @import("std");
const handle_manager = @import("../core/handle_manager.zig");

pub const EntityId = u64;

pub const Entity = struct {
    id: EntityId,

    pub fn index(self: Entity) u32 {
        return @truncate(self.id);
    }

    pub fn generation(self: Entity) u32 {
        return @truncate(self.id >> 32);
    }

    pub fn make(idx: u32, gen: u32) Entity {
        return .{ .id = (@as(u64, gen) << 32) | idx };
    }
};

pub const EntityManager = struct {
    handles: handle_manager.HandleManager,

    pub fn init(allocator: std.mem.Allocator) EntityManager {
        return .{
            .handles = handle_manager.HandleManager.init(allocator),
        };
    }

    pub fn deinit(self: *EntityManager) void {
        self.handles.deinit();
    }

    pub fn create(self: *EntityManager) !Entity {
        const allocation = try self.handles.allocate();
        return Entity.make(allocation.index, allocation.generation);
    }

    pub fn destroy(self: *EntityManager, entity: Entity) bool {
        return self.handles.free(entity.index(), entity.generation());
    }

    pub fn is_alive(self: *const EntityManager, entity: Entity) bool {
        return self.handles.is_valid(entity.index(), entity.generation());
    }
};
