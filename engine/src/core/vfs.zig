//! Virtual filesystem facade.
//!
//! Provides a central place to route file reads/writes. The current implementation uses the
//! process working directory, but call sites should prefer this module over `std.fs.cwd()`.
//!
//! TODO: Add mount points and asset root resolution.

const std = @import("std");

/// Reads the entire file at `path` into an owned buffer.
pub fn read_file_alloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

/// Reads a file into an owned `[]u32` slice, requiring 4-byte alignment.
pub fn read_file_u32(allocator: std.mem.Allocator, path: []const u8) ![]u32 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) return error.EmptyFile;
    if (stat.size % 4 != 0) return error.InvalidWordAlignment;

    const buffer = try allocator.alloc(u32, stat.size / 4);
    errdefer allocator.free(buffer);

    const bytes = std.mem.sliceAsBytes(buffer);
    const read = try file.readAll(bytes);
    if (read != stat.size) return error.IncompleteRead;

    return buffer;
}

/// Returns the file modification time in nanoseconds.
pub fn get_mtime_ns(path: []const u8) !u64 {
    const stat = try std.fs.cwd().statFile(path);
    return @intCast(@max(stat.mtime, 0));
}

/// Writes `data` to `path`, truncating or creating the file.
pub fn write_file_all(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

/// Writes `header` then `body` to `path`, truncating or creating the file.
pub fn write_file_parts(path: []const u8, header: []const u8, body: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(header);
    try file.writeAll(body);
}
