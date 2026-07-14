const std = @import("std");
const components = @import("../../ecs/components.zig");
const math = @import("../../core/math.zig");
const json = @import("../scene_serializer_json.zig");

fn serializeVec3(writer: anytype, v: anytype) !void {
    var buf: [128]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "[{d}, {d}, {d}]", .{ v.x, v.y, v.z });
    try writer.writeRaw(str);
}

fn deserializeVec3(val: std.json.Value) !math.Vec3 {
    if (val != .array or val.array.items.len < 3) return error.InvalidFormat;
    return .{
        .x = try json.jsonToF32(val.array.items[0]),
        .y = try json.jsonToF32(val.array.items[1]),
        .z = try json.jsonToF32(val.array.items[2]),
    };
}

pub fn serialize(writer: anytype, t: *components.VolumetricTerrain) !void {
    try writer.beginObject();
    try writer.objectField("size");
    try serializeVec3(writer, t.size);
    try writer.objectField("resolution");
    try writer.write(t.resolution);
    try writer.objectField("chunk_x");
    try writer.write(t.chunk_x);
    try writer.objectField("chunk_y");
    try writer.write(t.chunk_y);
    try writer.objectField("chunk_z");
    try writer.write(t.chunk_z);
    try writer.objectField("model_id");
    try writer.write(t.model_id);
    try writer.objectField("mesh_index");
    try writer.write(t.mesh_index);
    try writer.objectField("data_id");
    try writer.write(t.data_id);
    try writer.endObject();
}

pub fn deserialize(val: std.json.Value) !components.VolumetricTerrain {
    if (val != .object) return error.InvalidFormat;
    var out = components.VolumetricTerrain{};

    if (val.object.get("size")) |v| out.size = try deserializeVec3(v);
    if (val.object.get("resolution")) |v| out.resolution = @intCast(v.integer);
    if (val.object.get("chunk_x")) |v| out.chunk_x = @intCast(v.integer);
    if (val.object.get("chunk_y")) |v| out.chunk_y = @intCast(v.integer);
    if (val.object.get("chunk_z")) |v| out.chunk_z = @intCast(v.integer);
    if (val.object.get("model_id")) |v| out.model_id = @intCast(v.integer);
    if (val.object.get("mesh_index")) |v| out.mesh_index = @intCast(v.integer);
    if (val.object.get("data_id")) |v| out.data_id = @intCast(v.integer);

    return out;
}
