//! Camera component serialization.
const std = @import("std");
const components = @import("../../ecs/components.zig");
const json = @import("../scene_serializer_json.zig");

/// Serializes camera projection parameters.
pub fn serialize(writer: anytype, c: *components.Camera) !void {
    try writer.beginObject();
    try writer.objectField("type");
    try writer.write(@intFromEnum(c.type));
    try writer.objectField("fov");
    try writer.write(c.fov);
    try writer.objectField("aspect_ratio");
    try writer.write(c.aspect_ratio);
    try writer.objectField("near_plane");
    try writer.write(c.near_plane);
    try writer.objectField("far_plane");
    try writer.write(c.far_plane);
    try writer.objectField("ortho_size");
    try writer.write(c.ortho_size);
    try writer.endObject();
}

/// Parses camera projection parameters.
pub fn deserialize(val: std.json.Value) !components.Camera {
    if (val != .object) return error.InvalidFormat;
    var c = components.Camera{ .type = .Perspective };
    if (val.object.get("type")) |t| c.type = @enumFromInt(t.integer);
    if (val.object.get("fov")) |v| c.fov = try json.jsonToF32(v);
    if (val.object.get("aspect_ratio")) |v| c.aspect_ratio = try json.jsonToF32(v);
    if (val.object.get("near_plane")) |v| c.near_plane = try json.jsonToF32(v);
    if (val.object.get("far_plane")) |v| c.far_plane = try json.jsonToF32(v);
    if (val.object.get("ortho_size")) |v| c.ortho_size = try json.jsonToF32(v);
    return c;
}
