//! Hierarchy component serialization.
const std = @import("std");
const entity_pkg = @import("../../ecs/entity.zig");
const components = @import("../../ecs/components.zig");

const serializer_log = std.log.scoped(.scene_serializer);

/// Serializes hierarchy links using entity IDs.
pub fn serialize(writer: anytype, h: *components.Hierarchy) !void {
    try writer.beginObject();
    try writer.objectField("parent");
    if (h.parent) |p| try writer.write(p.id) else try writer.write(null);
    try writer.objectField("first_child");
    if (h.first_child) |c| try writer.write(c.id) else try writer.write(null);
    try writer.objectField("next_sibling");
    if (h.next_sibling) |s| try writer.write(s.id) else try writer.write(null);
    try writer.objectField("prev_sibling");
    if (h.prev_sibling) |s| try writer.write(s.id) else try writer.write(null);
    try writer.objectField("child_count");
    try writer.write(h.child_count);
    try writer.endObject();
}

/// Parses hierarchy links from entity IDs using `id_map`.
pub fn deserialize(val: std.json.Value, id_map: *std.AutoHashMap(u64, entity_pkg.Entity)) !components.Hierarchy {
    if (val != .object) return error.InvalidFormat;
    var h = components.Hierarchy{};
    if (val.object.get("parent")) |p| {
        if (p != .null) {
            const old_id: u64 = @intCast(p.integer);
            if (id_map.get(old_id)) |new_entity| {
                h.parent = new_entity;
            } else {
                serializer_log.warn("Hierarchy: parent ID {d} not found in map", .{old_id});
            }
        }
    }
    if (val.object.get("first_child")) |c| {
        if (c != .null) {
            const old_id: u64 = @intCast(c.integer);
            if (id_map.get(old_id)) |new_entity| {
                h.first_child = new_entity;
            } else {
                serializer_log.warn("Hierarchy: first_child ID {d} not found in map", .{old_id});
            }
        }
    }
    if (val.object.get("next_sibling")) |s| {
        if (s != .null) {
            const old_id: u64 = @intCast(s.integer);
            if (id_map.get(old_id)) |new_entity| {
                h.next_sibling = new_entity;
            } else {
                serializer_log.warn("Hierarchy: next_sibling ID {d} not found in map", .{old_id});
            }
        }
    }
    if (val.object.get("prev_sibling")) |s| {
        if (s != .null) {
            const old_id: u64 = @intCast(s.integer);
            if (id_map.get(old_id)) |new_entity| {
                h.prev_sibling = new_entity;
            } else {
                serializer_log.warn("Hierarchy: prev_sibling ID {d} not found in map", .{old_id});
            }
        }
    }
    if (val.object.get("child_count")) |c| h.child_count = @intCast(c.integer);
    return h;
}
