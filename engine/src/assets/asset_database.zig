//! Asset database: GUID <-> path mapping backed by `.meta` sidecar files.
//!
//! Scans an asset root directory for `*.meta` files and maintains maps for resolving GUIDs to
//! absolute asset paths (and vice versa). When a `.meta` file is missing, it can be created on
//! demand with a freshly generated GUID.
const std = @import("std");

/// 128-bit stable identifier stored in `.meta` files.
pub const AssetGuid = u128;

/// Asset importer classification derived from file extension.
pub const Importer = enum {
    Texture,
    Model,
    Scene,
    Shader,
    Pipeline,
    Audio,
    Unknown,
};

/// Import settings for texture assets.
pub const TextureImportSettings = struct {
    srgb: bool = true,
    generate_mips: bool = true,
};

/// Import settings for model assets.
pub const ModelImportSettings = struct {
    scale: f32 = 1.0,
};

/// Tracks GUID/path mappings and performs `.meta` discovery under `root_dir`.
pub const AssetDatabase = struct {
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    guid_to_path: std.AutoHashMapUnmanaged(AssetGuid, []const u8) = .{},
    path_to_guid: std.StringHashMapUnmanaged(AssetGuid) = .{},

    /// Creates a database rooted at `root_dir` (must be an absolute path).
    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) !AssetDatabase {
        return .{
            .allocator = allocator,
            .root_dir = try allocator.dupe(u8, root_dir),
            .guid_to_path = .{},
            .path_to_guid = .{},
        };
    }

    /// Frees all stored path strings and releases internal maps.
    pub fn deinit(self: *AssetDatabase) void {
        var it = self.guid_to_path.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.guid_to_path.deinit(self.allocator);

        var it2 = self.path_to_guid.iterator();
        while (it2.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.path_to_guid.deinit(self.allocator);

        self.allocator.free(self.root_dir);
    }

    /// Clears current mappings and rescans `root_dir` for `*.meta` files.
    pub fn refresh(self: *AssetDatabase) !void {
        self.clearRetainingCapacity();
        var path_buf = std.ArrayListUnmanaged(u8){};
        defer path_buf.deinit(self.allocator);
        try path_buf.appendSlice(self.allocator, self.root_dir);
        try self.scanForMetaFiles(&path_buf);
    }

    /// Clears both maps without freeing their backing capacity.
    pub fn clearRetainingCapacity(self: *AssetDatabase) void {
        var it = self.guid_to_path.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.guid_to_path.clearRetainingCapacity();

        var it2 = self.path_to_guid.iterator();
        while (it2.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.path_to_guid.clearRetainingCapacity();
    }

    /// Returns the absolute asset path for `guid` if known.
    pub fn resolvePathByGuid(self: *const AssetDatabase, guid: AssetGuid) ?[]const u8 {
        return self.guid_to_path.get(guid);
    }

    /// Returns the GUID for `asset_path_abs` if known.
    pub fn getGuidForPath(self: *const AssetDatabase, asset_path_abs: []const u8) ?AssetGuid {
        return self.path_to_guid.get(asset_path_abs);
    }

    /// Returns the GUID for `asset_path_abs`, creating a `.meta` file when missing.
    pub fn getOrCreateGuidForAsset(self: *AssetDatabase, asset_path_abs: []const u8) !AssetGuid {
        if (self.path_to_guid.get(asset_path_abs)) |g| return g;

        const importer = inferImporter(asset_path_abs);
        const meta_path = try metaPathForAsset(self.allocator, asset_path_abs);
        defer self.allocator.free(meta_path);

        const guid = (readGuidFromMetaFile(self.allocator, meta_path) catch null) orelse blk: {
            const g = generateGuid();
            try writeMetaFile(self.allocator, meta_path, g, importer);
            break :blk g;
        };

        const stored_path = try self.allocator.dupe(u8, asset_path_abs);
        errdefer self.allocator.free(stored_path);

        if (self.guid_to_path.getPtr(guid)) |existing| {
            self.allocator.free(existing.*);
            existing.* = stored_path;
        } else {
            try self.guid_to_path.put(self.allocator, guid, stored_path);
        }

        if (self.path_to_guid.getPtr(asset_path_abs)) |existing_guid| {
            existing_guid.* = guid;
        } else {
            const key_copy = try self.allocator.dupe(u8, asset_path_abs);
            errdefer self.allocator.free(key_copy);
            try self.path_to_guid.put(self.allocator, key_copy, guid);
        }

        return guid;
    }

    fn scanForMetaFiles(self: *AssetDatabase, path_buf: *std.ArrayListUnmanaged(u8)) !void {
        const dir_path = path_buf.items;
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            const base_len = path_buf.items.len;
            defer path_buf.items.len = base_len;

            if (path_buf.items.len > 0 and path_buf.items[path_buf.items.len - 1] != std.fs.path.sep) {
                try path_buf.appendSlice(self.allocator, std.fs.path.sep_str);
            }
            try path_buf.appendSlice(self.allocator, entry.name);
            const child_path = path_buf.items;

            if (entry.kind == .directory) {
                try self.scanForMetaFiles(path_buf);
                continue;
            }

            if (!std.mem.endsWith(u8, entry.name, ".meta")) continue;

            const guid = readGuidFromMetaFile(self.allocator, child_path) catch continue;
            const asset_path = child_path[0 .. child_path.len - ".meta".len];

            const asset_file = std.fs.openFileAbsolute(asset_path, .{}) catch continue;
            asset_file.close();

            const stored_path = try self.allocator.dupe(u8, asset_path);
            errdefer self.allocator.free(stored_path);
            if (self.guid_to_path.getPtr(guid)) |existing| {
                self.allocator.free(existing.*);
                existing.* = stored_path;
            } else {
                try self.guid_to_path.put(self.allocator, guid, stored_path);
            }

            if (self.path_to_guid.getPtr(asset_path)) |existing_guid| {
                existing_guid.* = guid;
            } else {
                const key_copy = try self.allocator.dupe(u8, asset_path);
                errdefer self.allocator.free(key_copy);
                try self.path_to_guid.put(self.allocator, key_copy, guid);
            }
        }
    }
};

/// Returns `asset_path_abs ++ ".meta"`.
pub fn metaPathForAsset(allocator: std.mem.Allocator, asset_path_abs: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &[_][]const u8{ asset_path_abs, ".meta" });
}

/// Infers an importer type from `asset_path`'s extension.
pub fn inferImporter(asset_path: []const u8) Importer {
    const ext = std.fs.path.extension(asset_path);
    if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg") or std.mem.eql(u8, ext, ".tga") or std.mem.eql(u8, ext, ".bmp") or std.mem.eql(u8, ext, ".hdr") or std.mem.eql(u8, ext, ".exr")) {
        return .Texture;
    }
    if (std.mem.eql(u8, ext, ".gltf") or std.mem.eql(u8, ext, ".glb") or std.mem.eql(u8, ext, ".kfm") or std.mem.eql(u8, ext, ".nif") or std.mem.eql(u8, ext, ".obj")) {
        return .Model;
    }
    if (std.mem.eql(u8, ext, ".json")) {
        return .Scene;
    }
    if (std.mem.eql(u8, ext, ".vert") or std.mem.eql(u8, ext, ".frag") or std.mem.eql(u8, ext, ".comp") or std.mem.eql(u8, ext, ".mesh") or std.mem.eql(u8, ext, ".task") or std.mem.eql(u8, ext, ".spv")) {
        return .Shader;
    }
    if (std.mem.eql(u8, ext, ".wav") or std.mem.eql(u8, ext, ".ogg") or std.mem.eql(u8, ext, ".mp3")) {
        return .Audio;
    }
    return .Unknown;
}

/// Writes `guid` as 32 lowercase hex characters into `out`.
pub fn guidToHex(guid: AssetGuid, out: *[32]u8) void {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, guid, .big);

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        out[i * 2] = hexNibble(@intCast(b >> 4));
        out[i * 2 + 1] = hexNibble(@intCast(b & 0x0F));
    }
}

/// Parses a 32-hex-character GUID string (dashes are ignored).
pub fn parseGuidHex(s: []const u8) !AssetGuid {
    var tmp: [32]u8 = undefined;
    var filled: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (filled >= tmp.len) return error.InvalidGuid;
        tmp[filled] = c;
        filled += 1;
    }
    if (filled != 32) return error.InvalidGuid;

    var bytes: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = try parseHexNibble(tmp[i * 2]);
        const lo = try parseHexNibble(tmp[i * 2 + 1]);
        bytes[i] = @intCast((hi << 4) | lo);
    }
    return std.mem.readInt(u128, &bytes, .big);
}

fn hexNibble(v: u8) u8 {
    return if (v < 10) ('0' + v) else ('a' + (v - 10));
}

fn parseHexNibble(c: u8) !u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' and c <= 'F') return 10 + (c - 'A');
    return error.InvalidGuid;
}

pub fn generateGuid() AssetGuid {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.mem.readInt(u128, &bytes, .big);
}

fn readGuidFromMetaFile(allocator: std.mem.Allocator, meta_path_abs: []const u8) !AssetGuid {
    const file = std.fs.openFileAbsolute(meta_path_abs, .{}) catch |err| {
        if (err == error.FileNotFound) return error.FileNotFound;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    const Parsed = struct {
        guid: ?[]const u8 = null,
    };

    const parsed = try std.json.parseFromSlice(Parsed, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const guid_str = parsed.value.guid orelse return error.InvalidGuid;
    return parseGuidHex(guid_str);
}

fn writeMetaFile(allocator: std.mem.Allocator, meta_path_abs: []const u8, guid: AssetGuid, importer: Importer) !void {
    const file = try std.fs.createFileAbsolute(meta_path_abs, .{ .truncate = true });
    defer file.close();

    var guid_hex: [32]u8 = undefined;
    guidToHex(guid, &guid_hex);

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    const w = out.writer(allocator);
    try w.writeAll("{\n");
    try w.writeAll("    \"version\": 1,\n");
    try w.print("    \"guid\": \"{s}\",\n", .{guid_hex[0..]});
    try w.print("    \"importer\": \"{s}\",\n", .{@tagName(importer)});
    try w.writeAll("    \"import_settings\": ");

    switch (importer) {
        .Texture => {
            const settings = TextureImportSettings{};
            try w.print("{f}", .{std.json.fmt(settings, .{ .whitespace = .indent_4 })});
        },
        .Model => {
            const settings = ModelImportSettings{};
            try w.print("{f}", .{std.json.fmt(settings, .{ .whitespace = .indent_4 })});
        },
        else => {
            try w.writeAll("{}");
        },
    }

    try w.writeAll("\n}\n");

    try file.writeAll(out.items);
}
