const std = @import("std");
const entity_pkg = @import("entity.zig");
const registry_pkg = @import("registry.zig");

const Entity = entity_pkg.Entity;

pub const CommandType = enum {
    Add,
    Remove,
    Destroy,
};

pub const CommandBuffer = struct {
    allocator: std.mem.Allocator,

    // We use a simple byte buffer for payload data to handle generic components
    payload: std.ArrayListUnmanaged(u8),
    commands: std.ArrayListUnmanaged(CommandHeader),

    pub const CommandHeader = struct {
        cmd_type: CommandType,
        entity: Entity,
        component_type_id: u64 = 0,
        payload_offset: usize = 0,
        payload_size: usize = 0,
        // Function pointer to apply the operation
        apply_fn: ?*const fn (registry: *registry_pkg.Registry, entity: Entity, data: []const u8) anyerror!void = null,
    };

    pub fn init(allocator: std.mem.Allocator) CommandBuffer {
        return .{
            .allocator = allocator,
            .payload = .{},
            .commands = .{},
        };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.payload.deinit(self.allocator);
        self.commands.deinit(self.allocator);
    }

    pub fn add(self: *CommandBuffer, entity: Entity, component: anytype) !void {
        const T = @TypeOf(component);
        const type_id = registry_pkg.Registry.get_type_id(T);
        const size = @sizeOf(T);

        const offset = self.payload.items.len;
        try self.payload.appendSlice(self.allocator, std.mem.asBytes(&component));

        try self.commands.append(self.allocator, .{
            .cmd_type = .Add,
            .entity = entity,
            .component_type_id = type_id,
            .payload_offset = offset,
            .payload_size = size,
            .apply_fn = struct {
                fn apply(reg: *registry_pkg.Registry, ent: Entity, data: []const u8) !void {
                    const comp = std.mem.bytesAsValue(T, data).*;
                    try reg.add(ent, comp);
                }
            }.apply,
        });
    }

    pub fn remove(self: *CommandBuffer, comptime T: type, entity: Entity) !void {
        const type_id = registry_pkg.Registry.get_type_id(T);

        try self.commands.append(self.allocator, .{
            .cmd_type = .Remove,
            .entity = entity,
            .component_type_id = type_id,
            .apply_fn = struct {
                fn apply(reg: *registry_pkg.Registry, ent: Entity, data: []const u8) !void {
                    _ = data;
                    reg.remove(T, ent);
                }
            }.apply,
        });
    }

    pub fn destroy(self: *CommandBuffer, entity: Entity) !void {
        try self.commands.append(self.allocator, .{
            .cmd_type = .Destroy,
            .entity = entity,
        });
    }

    pub fn flush(self: *CommandBuffer, registry: *registry_pkg.Registry) !void {
        for (self.commands.items) |cmd| {
            switch (cmd.cmd_type) {
                .Add => {
                    if (cmd.apply_fn) |apply| {
                        const data = self.payload.items[cmd.payload_offset .. cmd.payload_offset + cmd.payload_size];
                        apply(registry, cmd.entity, data) catch |err| {
                            std.log.err("Failed to apply Add command for entity {d}: {}", .{ cmd.entity.id, err });
                        };
                    }
                },
                .Remove => {
                    if (cmd.apply_fn) |apply| {
                        apply(registry, cmd.entity, &.{}) catch |err| {
                            std.log.err("Failed to apply Remove command for entity {d}: {}", .{ cmd.entity.id, err });
                        };
                    }
                },
                .Destroy => {
                    registry.destroy(cmd.entity);
                },
            }
        }
        self.clear();
    }

    pub fn clear(self: *CommandBuffer) void {
        self.payload.clearRetainingCapacity();
        self.commands.clearRetainingCapacity();
    }
};
