//! Skybox component serialization.
const std = @import("std");
const components = @import("../../ecs/components.zig");

/// Serializes a skybox path, using `root_path` for relative output when possible.
pub fn serialize(writer: anytype, allocator: std.mem.Allocator, s: *components.Skybox, root_path: ?[]const u8) !void {
    const path_slice = s.slice();
    if (path_slice.len == 0) {
        try writer.write("");
        return;
    }

    if (root_path) |root| {
        if (std.fs.path.isAbsolute(path_slice)) {
            const rel = std.fs.path.relative(allocator, root, path_slice) catch {
                try writer.write(path_slice);
                return;
            };
            defer allocator.free(rel);
            try writer.write(rel);
            return;
        }
    }

    try writer.write(path_slice);
}

/// Parses a skybox path, joining with `root_path` for relative input when provided.
pub fn deserialize(allocator: std.mem.Allocator, val: std.json.Value, root_path: ?[]const u8) !components.Skybox {
    if (val != .string) return error.InvalidFormat;
    const path_slice = val.string;
    if (path_slice.len == 0) return components.Skybox{};

    if (root_path) |root| {
        if (!std.fs.path.isAbsolute(path_slice)) {
            const full = try std.fs.path.join(allocator, &[_][]const u8{ root, path_slice });
            defer allocator.free(full);
            return components.Skybox.init(full);
        }
    }

    return components.Skybox.init(path_slice);
}
