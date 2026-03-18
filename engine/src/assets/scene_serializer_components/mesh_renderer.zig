//! MeshRenderer component serialization.
const std = @import("std");
const components = @import("../../ecs/components.zig");

/// Serializes mesh/material handles and visibility flags.
pub fn serialize(writer: anytype, mr: *components.MeshRenderer) !void {
    try writer.beginObject();
    try writer.objectField("mesh_id");
    try writer.write(mr.mesh.index);
    try writer.objectField("material_id");
    try writer.write(mr.material.index);
    try writer.objectField("visible");
    try writer.write(mr.visible);
    try writer.objectField("cast_shadows");
    try writer.write(mr.cast_shadows);
    try writer.objectField("receive_shadows");
    try writer.write(mr.receive_shadows);
    try writer.endObject();
}

/// Parses mesh/material indices and visibility flags.
pub fn deserialize(val: std.json.Value) !components.MeshRenderer {
    if (val != .object) return error.InvalidFormat;
    var mr = components.MeshRenderer{
        .mesh = .{ .index = 0, .generation = 0 },
        .material = .{ .index = 0, .generation = 0 },
    };

    if (val.object.get("mesh_id")) |id| mr.mesh.index = @intCast(id.integer);
    if (val.object.get("material_id")) |id| mr.material.index = @intCast(id.integer);
    if (val.object.get("visible")) |v| mr.visible = v.bool;
    if (val.object.get("cast_shadows")) |v| mr.cast_shadows = v.bool;
    if (val.object.get("receive_shadows")) |v| mr.receive_shadows = v.bool;
    return mr;
}
