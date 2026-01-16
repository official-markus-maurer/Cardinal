const std = @import("std");
const entity_pkg = @import("entity.zig");
const component_pkg = @import("component.zig");

pub const Entity = entity_pkg.Entity;

pub const Registry = struct {
    entity_manager: entity_pkg.EntityManager,
    // Map ComponentTypeID -> StorageInterface
    storages: std.AutoHashMapUnmanaged(u64, component_pkg.StorageInterface),
    // We need to own the actual storage pointers to free them
    // Map ComponentTypeID -> *anyopaque (to be casted to *SparseSet(T) for freeing)
    storage_ptrs: std.AutoHashMapUnmanaged(u64, *anyopaque),
    // Map ComponentTypeID -> DeinitFunc
    deinit_fns: std.AutoHashMapUnmanaged(u64, *const fn (*anyopaque, std.mem.Allocator) void),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .entity_manager = entity_pkg.EntityManager.init(allocator),
            .storages = .{},
            .storage_ptrs = .{},
            .deinit_fns = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.storage_ptrs.iterator();
        while (it.next()) |entry| {
            const type_id = entry.key_ptr.*;
            const ptr = entry.value_ptr.*;
            if (self.deinit_fns.get(type_id)) |deinit_fn| {
                deinit_fn(ptr, self.allocator);
            }
        }
        self.storages.deinit(self.allocator);
        self.storage_ptrs.deinit(self.allocator);
        self.deinit_fns.deinit(self.allocator);
        self.entity_manager.deinit();
    }

    pub fn create(self: *Registry) !Entity {
        return self.entity_manager.create();
    }

    pub fn destroy(self: *Registry, entity: Entity) void {
        if (self.entity_manager.destroy(entity)) {
            // Remove components
            var it = self.storages.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.remove(entity);
            }
        }
    }

    pub fn get_type_id(comptime T: type) u64 {
        return std.hash.Wyhash.hash(0, @typeName(T));
    }

    fn deinit_wrapper(comptime T: type) fn (*anyopaque, std.mem.Allocator) void {
        return struct {
            fn func(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const storage: *component_pkg.SparseSet(T) = @ptrCast(@alignCast(ptr));
                storage.deinit();
                allocator.destroy(storage);
            }
        }.func;
    }

    pub fn assure_storage(self: *Registry, comptime T: type) !*component_pkg.SparseSet(T) {
        const id = get_type_id(T);
        if (self.storage_ptrs.get(id)) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }

        const storage = try self.allocator.create(component_pkg.SparseSet(T));
        storage.* = component_pkg.SparseSet(T).init(self.allocator);

        try self.storage_ptrs.put(self.allocator, id, storage);
        try self.storages.put(self.allocator, id, storage.interface());
        try self.deinit_fns.put(self.allocator, id, deinit_wrapper(T));

        return storage;
    }

    pub fn add(self: *Registry, entity: Entity, component: anytype) !void {
        const T = @TypeOf(component);
        const storage = try self.assure_storage(T);
        try storage.set(entity, component);
    }

    pub fn remove(self: *Registry, comptime T: type, entity: Entity) void {
        const id = get_type_id(T);
        if (self.storages.get(id)) |storage| {
            storage.remove(entity);
        }
    }

    pub fn get(self: *Registry, comptime T: type, entity: Entity) ?*T {
        const id = get_type_id(T);
        if (self.storage_ptrs.get(id)) |ptr| {
            const storage: *component_pkg.SparseSet(T) = @ptrCast(@alignCast(ptr));
            return storage.get(entity);
        }
        return null;
    }

    // View iterator helper
    pub fn view(self: *Registry, comptime T: type) View(T) {
        const id = get_type_id(T);
        if (self.storage_ptrs.get(id)) |ptr| {
            const storage: *component_pkg.SparseSet(T) = @ptrCast(@alignCast(ptr));
            return View(T){ .storage = storage };
        }
        return View(T){ .storage = null };
    }

    pub fn multi_view(self: *Registry, comptime types_tuple: anytype) MultiView(types_tuple) {
        const Count = types_tuple.len;
        var storages: [Count]?*anyopaque = undefined;

        inline for (types_tuple, 0..) |T, i| {
            const id = get_type_id(T);
            if (self.storage_ptrs.get(id)) |ptr| {
                storages[i] = ptr;
            } else {
                storages[i] = null;
            }
        }
        return MultiView(types_tuple){ .storages = storages };
    }
};

pub fn View(comptime T: type) type {
    return struct {
        storage: ?*component_pkg.SparseSet(T),

        pub const Iterator = struct {
            storage: ?*component_pkg.SparseSet(T),
            index: usize,

            pub fn next(self: *Iterator) ?struct { entity: Entity, component: *T } {
                if (self.storage) |s| {
                    if (self.index >= s.packed_entities.items.len) return null;
                    const i = self.index;
                    self.index += 1;
                    return .{
                        .entity = s.packed_entities.items[i],
                        .component = &s.components.items[i],
                    };
                }
                return null;
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .storage = self.storage, .index = 0 };
        }

        pub fn each(self: @This(), context: anytype, callback: fn (@TypeOf(context), Entity, *T) void) void {
            if (self.storage) |s| {
                for (s.packed_entities.items, s.components.items) |e, *c| {
                    callback(context, e, c);
                }
            }
        }

        pub fn count(self: @This()) usize {
            if (self.storage) |s| {
                return s.packed_entities.items.len;
            }
            return 0;
        }
    };
}

pub fn MultiView(comptime types_tuple: anytype) type {
    const Count = types_tuple.len;

    const ComponentsTuple = blk: {
        var types: [Count]type = undefined;
        inline for (types_tuple, 0..) |T, i| {
            types[i] = *T;
        }
        break :blk std.meta.Tuple(&types);
    };

    return struct {
        storages: [Count]?*anyopaque,

        pub const Iterator = struct {
            storages: [Count]?*anyopaque,
            entities: []const Entity,
            index: usize,

            pub fn next(self: *Iterator) ?struct { entity: Entity, components: ComponentsTuple } {
                while (self.index < self.entities.len) {
                    const entity = self.entities[self.index];
                    self.index += 1;

                    var all_present = true;
                    // Check if entity is present in all storages
                    inline for (types_tuple, 0..) |T, i| {
                        if (self.storages[i]) |ptr| {
                            const storage: *component_pkg.SparseSet(T) = @ptrCast(@alignCast(ptr));
                            if (!storage.has(entity)) {
                                all_present = false;
                            }
                        } else {
                            all_present = false;
                        }
                    }

                    if (!all_present) continue;

                    // If we are here, entity is in all storages
                    var components: ComponentsTuple = undefined;
                    inline for (types_tuple, 0..) |T, i| {
                        if (self.storages[i]) |ptr| {
                            const storage: *component_pkg.SparseSet(T) = @ptrCast(@alignCast(ptr));
                            components[i] = storage.get(entity).?;
                        }
                    }
                    return .{ .entity = entity, .components = components };
                }
                return null;
            }
        };

        pub fn iterator(self: @This()) Iterator {
            var min_count: usize = std.math.maxInt(usize);
            var best_index: usize = 0;
            var any_missing = false;

            inline for (types_tuple, 0..) |T, i| {
                if (self.storages[i]) |ptr| {
                    const storage: *component_pkg.SparseSet(T) = @ptrCast(@alignCast(ptr));
                    const count = storage.packed_entities.items.len;
                    if (count < min_count) {
                        min_count = count;
                        best_index = i;
                    }
                } else {
                    any_missing = true;
                }
            }

            if (any_missing) {
                return Iterator{
                    .storages = self.storages,
                    .entities = &.{},
                    .index = 0,
                };
            }

            // Get entities from best storage
            var entities: []const Entity = undefined;
            inline for (types_tuple, 0..) |T, i| {
                if (i == best_index) {
                    const storage: *component_pkg.SparseSet(T) = @ptrCast(@alignCast(self.storages[i].?));
                    entities = storage.packed_entities.items;
                }
            }

            return Iterator{
                .storages = self.storages,
                .entities = entities,
                .index = 0,
            };
        }
    };
}

test "MultiView iteration" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Define some components for testing
    const CompA = struct { value: u32 };
    const CompB = struct { value: f32 };
    const CompC = struct { value: bool };

    // Create entities
    const e1 = try registry.create();
    const e2 = try registry.create();
    const e3 = try registry.create();
    const e4 = try registry.create();

    // e1: A, B
    try registry.add(e1, CompA{ .value = 10 });
    try registry.add(e1, CompB{ .value = 1.0 });

    // e2: A, B, C
    try registry.add(e2, CompA{ .value = 20 });
    try registry.add(e2, CompB{ .value = 2.0 });
    try registry.add(e2, CompC{ .value = true });

    // e3: A only
    try registry.add(e3, CompA{ .value = 30 });

    // e4: B, C
    try registry.add(e4, CompB{ .value = 4.0 });
    try registry.add(e4, CompC{ .value = false });

    // Test MultiView(A, B) -> Should match e1, e2
    var view_ab = registry.multi_view(.{ CompA, CompB });
    var it_ab = view_ab.iterator();
    var count_ab: usize = 0;
    while (it_ab.next()) |entry| {
        count_ab += 1;
        const e = entry.entity;
        const comps = entry.components; // tuple { *CompA, *CompB }

        if (e.id == e1.id) {
            try std.testing.expectEqual(@as(u32, 10), comps[0].value);
            try std.testing.expectEqual(@as(f32, 1.0), comps[1].value);
        } else if (e.id == e2.id) {
            try std.testing.expectEqual(@as(u32, 20), comps[0].value);
            try std.testing.expectEqual(@as(f32, 2.0), comps[1].value);
        } else {
            try std.testing.expect(false); // Unexpected entity
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count_ab);

    // Test MultiView(B, C) -> Should match e2, e4
    var view_bc = registry.multi_view(.{ CompB, CompC });
    var it_bc = view_bc.iterator();
    var count_bc: usize = 0;
    while (it_bc.next()) |entry| {
        count_bc += 1;
        const e = entry.entity;
        const comps = entry.components;

        if (e.id == e2.id) {
            try std.testing.expectEqual(@as(f32, 2.0), comps[0].value);
            try std.testing.expectEqual(true, comps[1].value);
        } else if (e.id == e4.id) {
            try std.testing.expectEqual(@as(f32, 4.0), comps[0].value);
            try std.testing.expectEqual(false, comps[1].value);
        } else {
            try std.testing.expect(false);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count_bc);

    // Test MultiView(A, B, C) -> Should match e2 only
    var view_abc = registry.multi_view(.{ CompA, CompB, CompC });
    var it_abc = view_abc.iterator();
    var count_abc: usize = 0;
    while (it_abc.next()) |entry| {
        count_abc += 1;
        const e = entry.entity;
        const comps = entry.components;

        try std.testing.expectEqual(e2.id, e.id);
        try std.testing.expectEqual(@as(u32, 20), comps[0].value);
        try std.testing.expectEqual(@as(f32, 2.0), comps[1].value);
        try std.testing.expectEqual(true, comps[2].value);
    }
    try std.testing.expectEqual(@as(usize, 1), count_abc);
}
