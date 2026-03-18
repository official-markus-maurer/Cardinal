//! Name component serialization.
const std = @import("std");
const components = @import("../../ecs/components.zig");

/// Serializes a name as a JSON string.
pub fn serialize(writer: anytype, n: *components.Name) !void {
    try writer.write(n.slice());
}

/// Parses a name from a JSON string.
pub fn deserialize(val: std.json.Value) !components.Name {
    if (val != .string) return error.InvalidFormat;
    return components.Name.init(val.string);
}
