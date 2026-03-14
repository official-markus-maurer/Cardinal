const std = @import("std");
const registry_pkg = @import("registry.zig");
const entity_pkg = @import("entity.zig");
const components = @import("components.zig");

pub const CreateNodeOptions = struct {
    skybox_path: ?[]const u8 = null,
};

pub fn create_node(registry: *registry_pkg.Registry, parent: ?entity_pkg.Entity, node_type: components.NodeType, name: []const u8, options: CreateNodeOptions) !entity_pkg.Entity {
    const entity = try registry.create();

    try registry.add(entity, components.Name.init(name));
    try registry.add(entity, components.Transform{});
    try registry.add(entity, components.Node{ .type = node_type });
    try registry.add(entity, components.Hierarchy{});

    switch (node_type) {
        .Camera3D => try registry.add(entity, components.Camera{ .type = .Perspective }),
        .Camera2D => try registry.add(entity, components.Camera{ .type = .Orthographic }),
        .DirectionalLight3D => try registry.add(entity, components.Light{ .type = .Directional, .cast_shadows = true }),
        .PointLight3D => try registry.add(entity, components.Light{ .type = .Point }),
        .SpotLight3D => try registry.add(entity, components.Light{ .type = .Spot }),
        .Skybox => {
            if (options.skybox_path) |p| {
                try registry.add(entity, components.Skybox.init(p));
            } else {
                try registry.add(entity, components.Skybox{});
            }
        },
        else => {},
    }

    if (parent) |p| {
        append_child(registry, p, entity);
    }

    return entity;
}

pub fn append_child(registry: *registry_pkg.Registry, parent: entity_pkg.Entity, child: entity_pkg.Entity) void {
    const parent_h_ptr = registry.get(components.Hierarchy, parent) orelse {
        registry.add(parent, components.Hierarchy{}) catch {};
        return append_child(registry, parent, child);
    };
    var parent_h = parent_h_ptr.*;

    const child_h_ptr = registry.get(components.Hierarchy, child) orelse {
        registry.add(child, components.Hierarchy{}) catch {};
        return append_child(registry, parent, child);
    };
    var child_h = child_h_ptr.*;

    child_h.parent = parent;
    child_h.prev_sibling = null;
    child_h.next_sibling = null;

    if (parent_h.first_child) |first| {
        var last = first;
        var loop_guard: u32 = 0;
        while (loop_guard < 100000) : (loop_guard += 1) {
            if (registry.get(components.Hierarchy, last)) |last_h_ptr| {
                if (last_h_ptr.next_sibling) |next| {
                    last = next;
                } else {
                    var last_h = last_h_ptr.*;
                    last_h.next_sibling = child;
                    registry.add(last, last_h) catch {};
                    child_h.prev_sibling = last;
                    break;
                }
            } else {
                break;
            }
        }
    } else {
        parent_h.first_child = child;
    }

    parent_h.child_count += 1;
    registry.add(parent, parent_h) catch {};
    registry.add(child, child_h) catch {};
}

