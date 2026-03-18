//! JSON helpers for scene serialization.
//!
//! Provides minimal encoding/decoding helpers shared across component serializers.
const std = @import("std");
const math = @import("../core/math.zig");

/// Converts a JSON number into `f32`.
pub fn jsonToF32(val: std.json.Value) !f32 {
    return switch (val) {
        .float => |v| @floatCast(v),
        .integer => |v| @floatFromInt(v),
        else => error.InvalidFormat,
    };
}

/// Writes a `Vec3` as a JSON array `[x, y, z]`.
pub fn serializeVec3(writer: anytype, v: math.Vec3) !void {
    var buf: [128]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "[{d}, {d}, {d}]", .{ v.x, v.y, v.z });
    try writer.writeRaw(str);
}

/// Parses a `Vec3` from a JSON array `[x, y, z]`.
pub fn deserializeVec3(val: std.json.Value) !math.Vec3 {
    if (val != .array or val.array.items.len < 3) return error.InvalidFormat;
    return math.Vec3{
        .x = try jsonToF32(val.array.items[0]),
        .y = try jsonToF32(val.array.items[1]),
        .z = try jsonToF32(val.array.items[2]),
    };
}

/// Writes a quaternion as a JSON array `[x, y, z, w]`.
pub fn serializeQuat(writer: anytype, q: math.Quat) !void {
    var buf: [128]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "[{d}, {d}, {d}, {d}]", .{ q.x, q.y, q.z, q.w });
    try writer.writeRaw(str);
}

/// Parses a quaternion from a JSON array `[x, y, z, w]`.
pub fn deserializeQuat(val: std.json.Value) !math.Quat {
    if (val != .array or val.array.items.len < 4) return error.InvalidFormat;
    return math.Quat{
        .x = try jsonToF32(val.array.items[0]),
        .y = try jsonToF32(val.array.items[1]),
        .z = try jsonToF32(val.array.items[2]),
        .w = try jsonToF32(val.array.items[3]),
    };
}

/// Writes a column-major 4x4 matrix as a JSON array of 16 scalars.
pub fn serializeMat4(writer: anytype, m: [16]f32) !void {
    var buf: [512]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "[{d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}]", .{ m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15] });
    try writer.writeRaw(str);
}

/// Parses a column-major 4x4 matrix from a JSON array of 16 scalars.
pub fn deserializeMat4(val: std.json.Value) ![16]f32 {
    if (val != .array or val.array.items.len < 16) return error.InvalidFormat;
    var m: [16]f32 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        m[i] = try jsonToF32(val.array.items[i]);
    }
    return m;
}
