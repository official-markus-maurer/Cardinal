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

    fn get_type_id(comptime T: type) u64 {
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
        
        pub fn each(self: @This(), context: anytype, callback: fn(@TypeOf(context), Entity, *T) void) void {
            if (self.storage) |s| {
                for (s.packed_entities.items, s.components.items) |e, *c| {
                    callback(context, e, c);
                }
            }
        }
    };
}
