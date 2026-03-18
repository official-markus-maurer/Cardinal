//! Node component serialization.
const std = @import("std");
const components = @import("../../ecs/components.zig");

/// Serializes a node type tag.
pub fn serialize(writer: anytype, n: *components.Node) !void {
    try writer.beginObject();
    try writer.objectField("type");
    try writer.write(@tagName(n.type));
    try writer.endObject();
}

/// Parses a node type tag.
pub fn deserialize(val: std.json.Value) !components.Node {
    if (val != .object) return error.InvalidFormat;
    var n = components.Node{};
    if (val.object.get("type")) |t| {
        switch (t) {
            .string => |s| {
                if (std.meta.stringToEnum(components.NodeType, s)) |nt| {
                    n.type = nt;
                } else {
                    return error.InvalidFormat;
                }
            },
            .integer => |i| n.type = @enumFromInt(i),
            else => return error.InvalidFormat,
        }
    }
    return n;
}
