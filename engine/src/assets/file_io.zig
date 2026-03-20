//! Asset file I/O helpers.
//!
//! Centralizes raw file reads and simple file metadata queries for asset-like consumers.

const std = @import("std");
const vfs = @import("../core/vfs.zig");

/// Reads the entire file at `path` into an owned buffer.
///
/// Uses the process working directory as the base path.
pub fn read_file_alloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try vfs.read_file_alloc(allocator, path);
}

/// Reads a SPIR-V file into an owned `[]u32` slice.
///
/// Returns an error if the file length is not 4-byte aligned.
pub fn read_file_u32(allocator: std.mem.Allocator, path: []const u8) ![]u32 {
    return try vfs.read_file_u32(allocator, path);
}

/// Returns the file modification time in nanoseconds.
///
/// Uses the process working directory as the base path.
pub fn get_mtime_ns(path: []const u8) !u64 {
    return try vfs.get_mtime_ns(path);
}
