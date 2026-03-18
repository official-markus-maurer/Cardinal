//! Transform component serialization.
const std = @import("std");
const components = @import("../../ecs/components.zig");
const json = @import("../scene_serializer_json.zig");

/// Serializes `Transform` as `{ position, rotation, scale }`.
pub fn serialize(writer: anytype, t: *components.Transform) !void {
    try writer.beginObject();
    try writer.objectField("position");
    try json.serializeVec3(writer, t.position);
    try writer.objectField("rotation");
    try json.serializeQuat(writer, t.rotation);
    try writer.objectField("scale");
    try json.serializeVec3(writer, t.scale);
    try writer.endObject();
}

/// Parses `Transform` from an object with optional fields.
pub fn deserialize(val: std.json.Value) !components.Transform {
    if (val != .object) return error.InvalidFormat;
    var t = components.Transform{};
    if (val.object.get("position")) |p| t.position = try json.deserializeVec3(p);
    if (val.object.get("rotation")) |r| t.rotation = try json.deserializeQuat(r);
    if (val.object.get("scale")) |s| t.scale = try json.deserializeVec3(s);
    return t;
}
