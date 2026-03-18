//! Script component serialization.
const std = @import("std");
const components = @import("../../ecs/components.zig");

/// Serializes script metadata only.
pub fn serialize(writer: anytype, s: *components.Script) !void {
    try writer.beginObject();
    try writer.objectField("script_id");
    try writer.write(s.script_id);
    try writer.endObject();
}

/// Parses script metadata only.
pub fn deserialize(val: std.json.Value) !components.Script {
    if (val != .object) return error.InvalidFormat;
    var s = components.Script{};
    if (val.object.get("script_id")) |id| s.script_id = @intCast(id.integer);
    return s;
}
