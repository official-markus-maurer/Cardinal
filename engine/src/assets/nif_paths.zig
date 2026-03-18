//! Path helpers for NIF/KF loading.
//!
//! Contains small utilities for resolving schema file paths and for locating referenced texture
//! files relative to a NIF.
const std = @import("std");
const nif_schema = @import("nif_schema.zig");

/// Resolves a schema `FilePath` represented as either a string-table index or an inline string.
pub fn resolveFilePath(strings: [][]u8, file_path: ?nif_schema.FilePath) ?[]const u8 {
    if (file_path) |fp| {
        if (fp.Index) |idx| {
            if (idx >= 0 and idx < strings.len) {
                return strings[@as(usize, @intCast(idx))];
            }
        } else if (fp.String) |str| {
            if (str.Value.len > 0) return @ptrCast(str.Value);
        }
    }
    return null;
}

/// Attempts to resolve `texture_path` to an existing file.
///
/// Tries the normalized path (cwd), then relative to `nif_path`, then a common `../texture/`
/// sibling directory layout.
pub fn resolve_texture_path(allocator: std.mem.Allocator, nif_path: []const u8, texture_path: []const u8) ?[:0]u8 {
    const ExistsCheck = struct {
        fn exists(path: []const u8) bool {
            if (std.fs.path.isAbsolute(path)) {
                var f = std.fs.openFileAbsolute(path, .{}) catch return false;
                f.close();
                return true;
            }
            var f = std.fs.cwd().openFile(path, .{}) catch return false;
            f.close();
            return true;
        }
    };

    var scratch: [512]u8 = undefined;
    var norm_buf: []u8 = undefined;
    var needs_free = false;
    const need = texture_path.len + 1;
    if (need <= scratch.len) {
        norm_buf = scratch[0..need];
    } else {
        norm_buf = allocator.alloc(u8, need) catch return null;
        needs_free = true;
    }
    defer if (needs_free) allocator.free(norm_buf);

    var i: usize = 0;
    for (texture_path) |char| {
        if (char == '\\') {
            norm_buf[i] = '/';
        } else {
            norm_buf[i] = std.ascii.toLower(char);
        }
        i += 1;
    }
    norm_buf[i] = 0;
    const norm_base_slice: [:0]u8 = norm_buf[0..i :0];

    if (ExistsCheck.exists(norm_base_slice)) {
        return allocator.dupeZ(u8, norm_base_slice) catch null;
    }

    const nif_dir = std.fs.path.dirname(nif_path) orelse ".";
    const path_rel = std.fs.path.join(allocator, &.{ nif_dir, norm_base_slice }) catch return null;
    defer allocator.free(path_rel);

    if (ExistsCheck.exists(path_rel)) {
        return allocator.dupeZ(u8, path_rel) catch null;
    }

    const sibling_texture_path = std.fs.path.join(allocator, &.{ nif_dir, "../texture", norm_base_slice }) catch return null;
    defer allocator.free(sibling_texture_path);

    if (ExistsCheck.exists(sibling_texture_path)) {
        return allocator.dupeZ(u8, sibling_texture_path) catch null;
    }

    return allocator.dupeZ(u8, norm_base_slice) catch null;
}
