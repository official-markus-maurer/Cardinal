//! Light component serialization.
const std = @import("std");
const components = @import("../../ecs/components.zig");
const json = @import("../scene_serializer_json.zig");

/// Serializes light parameters and type.
pub fn serialize(writer: anytype, l: *components.Light) !void {
    try writer.beginObject();
    try writer.objectField("type");
    try writer.write(@intFromEnum(l.type));
    try writer.objectField("color");
    try json.serializeVec3(writer, l.color);
    try writer.objectField("intensity");
    try writer.write(l.intensity);
    try writer.objectField("range");
    try writer.write(l.range);
    try writer.objectField("inner_cone_angle");
    try writer.write(l.inner_cone_angle);
    try writer.objectField("outer_cone_angle");
    try writer.write(l.outer_cone_angle);
    try writer.objectField("cast_shadows");
    try writer.write(l.cast_shadows);
    try writer.endObject();
}

/// Parses light parameters and type.
pub fn deserialize(val: std.json.Value) !components.Light {
    if (val != .object) return error.InvalidFormat;
    var l = components.Light{ .type = .Directional };
    if (val.object.get("type")) |t| l.type = @enumFromInt(t.integer);
    if (val.object.get("color")) |c| l.color = try json.deserializeVec3(c);
    if (val.object.get("intensity")) |i| l.intensity = try json.jsonToF32(i);
    if (val.object.get("range")) |r| l.range = try json.jsonToF32(r);
    if (val.object.get("inner_cone_angle")) |a| l.inner_cone_angle = try json.jsonToF32(a);
    if (val.object.get("outer_cone_angle")) |a| l.outer_cone_angle = try json.jsonToF32(a);
    if (val.object.get("cast_shadows")) |cs| l.cast_shadows = cs.bool;
    return l;
}
