const std = @import("std");
const components = @import("../../ecs/components.zig");
const math = @import("../../core/math.zig");
const json = @import("../scene_serializer_json.zig");

fn serializeVec2(writer: anytype, v: anytype) !void {
    var buf: [96]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "[{d}, {d}]", .{ v.x, v.y });
    try writer.writeRaw(str);
}

fn deserializeVec2(val: std.json.Value) !math.Vec2 {
    if (val != .array or val.array.items.len < 2) return error.InvalidFormat;
    return .{
        .x = try json.jsonToF32(val.array.items[0]),
        .y = try json.jsonToF32(val.array.items[1]),
    };
}

pub fn serialize(writer: anytype, t: *components.Terrain) !void {
    try writer.beginObject();
    try writer.objectField("size");
    try serializeVec2(writer, t.size);
    try writer.objectField("resolution");
    try writer.write(t.resolution);
    try writer.objectField("thickness");
    try writer.write(t.thickness);
    try writer.objectField("model_id");
    try writer.write(t.model_id);
    try writer.objectField("mesh_index");
    try writer.write(t.mesh_index);
    try writer.objectField("data_id");
    try writer.write(t.data_id);
    try writer.endObject();
}

pub fn deserialize(val: std.json.Value) !components.Terrain {
    if (val != .object) return error.InvalidFormat;
    var t = components.Terrain{};
    if (val.object.get("size")) |v| t.size = try deserializeVec2(v);
    if (val.object.get("resolution")) |v| t.resolution = @intCast(v.integer);
    if (val.object.get("thickness")) |v| t.thickness = try json.jsonToF32(v);
    if (val.object.get("model_id")) |v| t.model_id = @intCast(v.integer);
    if (val.object.get("mesh_index")) |v| t.mesh_index = @intCast(v.integer);
    if (val.object.get("data_id")) |v| t.data_id = @intCast(v.integer);
    return t;
}
