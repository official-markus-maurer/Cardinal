//! NIF/KF loader for Gamebryo assets.
//!
//! This module parses NIF scenes into `scene.CardinalScene` and can merge KF animation data into
//! an existing scene's animation system.
//!
//! TODO: Split this file into smaller parsing/extraction stages to reduce coupling and rebuild time.
//! TODO: Unify allocation strategy (ASSETS vs c_allocator) and add a single cleanup path on failure.
const std = @import("std");
const scene = @import("scene.zig");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const math = @import("../core/math.zig");
const transform = @import("../core/transform.zig");
const animation = @import("animation.zig");
const texture_loader = @import("texture_loader.zig");
const asset_manager = @import("asset_manager.zig");
const resource_state = @import("../core/resource_state.zig");
const handles = @import("../core/handles.zig");
const ref_counting = @import("../core/ref_counting.zig");
const builtin = @import("builtin");
const nif_schema = @import("nif_schema.zig");

fn getNifString(ns: nif_schema.NifString, strings: [][]u8) []const u8 {
    if (ns.index != 0xffffffff) {
        if (ns.index < strings.len) {
            return strings[ns.index];
        }
    } else {
        if (ns.data.len > 0) {
            return ns.data;
        }
    }
    return "";
}

const nif_log = log.ScopedLogger("NIF");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

const VK_FORMAT_R8G8B8A8_UNORM: u32 = 37;
const VK_FORMAT_R8G8B8A8_SRGB: u32 = 43;
const VK_FORMAT_B8G8R8A8_UNORM: u32 = 44;
const VK_FORMAT_B8G8R8A8_SRGB: u32 = 50;

fn promote_color_format_to_srgb(format: u32) u32 {
    if (format == VK_FORMAT_R8G8B8A8_UNORM) return VK_FORMAT_R8G8B8A8_SRGB;
    if (format == VK_FORMAT_B8G8R8A8_UNORM) return VK_FORMAT_B8G8R8A8_SRGB;
    return format;
}

fn fixup_skinned_vertex_weights(mesh: *scene.CardinalMesh) void {
    if (mesh.vertices == null or mesh.vertex_count == 0) return;
    const verts = mesh.vertices.?;
    var i: u32 = 0;
    while (i < mesh.vertex_count) : (i += 1) {
        var w0 = verts[i].bone_weights[0];
        var w1 = verts[i].bone_weights[1];
        var w2 = verts[i].bone_weights[2];
        var w3 = verts[i].bone_weights[3];

        if (verts[i].bone_indices[0] >= 256) w0 = 0;
        if (verts[i].bone_indices[1] >= 256) w1 = 0;
        if (verts[i].bone_indices[2] >= 256) w2 = 0;
        if (verts[i].bone_indices[3] >= 256) w3 = 0;

        var sum = w0 + w1 + w2 + w3;
        if (sum < 0.0001) {
            verts[i].bone_weights = .{ 1, 0, 0, 0 };
            verts[i].bone_indices = .{ 0, 0, 0, 0 };
            continue;
        }

        const inv = 1.0 / sum;
        w0 *= inv;
        w1 *= inv;
        w2 *= inv;
        w3 *= inv;
        sum = w0 + w1 + w2 + w3;

        if (sum < 0.0001) {
            verts[i].bone_weights = .{ 1, 0, 0, 0 };
            verts[i].bone_indices = .{ 0, 0, 0, 0 };
            continue;
        }

        verts[i].bone_weights[0] = w0;
        verts[i].bone_weights[1] = w1;
        verts[i].bone_weights[2] = w2;
        verts[i].bone_weights[3] = w3;
    }
}

fn propagate_transforms_to_meshes(node: ?*scene.CardinalSceneNode, meshes: []scene.CardinalMesh) void {
    if (node == null) return;
    const n = node.?;

    if (n.mesh_indices) |indices| {
        var i: u32 = 0;
        while (i < n.mesh_count) : (i += 1) {
            const mesh_idx = indices[i];
            if (mesh_idx < meshes.len) {
                @memcpy(&meshes[mesh_idx].transform, &n.world_transform);
            }
        }
    }

    if (n.children) |children| {
        var i: u32 = 0;
        while (i < n.child_count) : (i += 1) {
            propagate_transforms_to_meshes(children[i], meshes);
        }
    }
}

fn nif_transform_to_mat(nt: nif_schema.NiTransform) [16]f32 {
    var out: [16]f32 = undefined;
    var t: [3]f32 = .{ nt.Translation.x, nt.Translation.y, nt.Translation.z };
    var r: [9]f32 = .{
        nt.Rotation.m11,
        nt.Rotation.m12,
        nt.Rotation.m13,
        nt.Rotation.m21,
        nt.Rotation.m22,
        nt.Rotation.m23,
        nt.Rotation.m31,
        nt.Rotation.m32,
        nt.Rotation.m33,
    };
    transform.cardinal_matrix_from_rt_s(&r, &t, nt.Scale, &out);
    return out;
}

/// Parsed NIF file header and string tables.
const NifHeader = struct {
    version_str: []u8,
    version: u32,
    endian_type: u8,
    user_version: u32,
    num_blocks: u32,
    user_version_2: u32,
    num_block_types: u16,
    block_types: [][]u8,
    block_type_indices: []u16,
    block_sizes: []u32,
    num_strings: u32,
    strings: [][]u8,
    groups: []u32,
};

/// Block metadata and optional parsed schema payload.
const NifBlock = struct {
    /// Index into `header.block_types`.
    type_index: u16,
    /// Offset in the file buffer where this block's data begins.
    data_offset: usize,
    size: u32,

    parsed: ?nif_schema.NifBlockData,
};

/// Streaming reader over an in-memory NIF/KF buffer.
pub const NifReader = struct {
    buffer: []const u8,
    pos: usize,
    header: NifHeader,
    allocator: std.mem.Allocator,

    blocks: []NifBlock,

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) NifReader {
        return .{
            .buffer = buffer,
            .pos = 0,
            .header = std.mem.zeroes(NifHeader),
            .blocks = &[_]NifBlock{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NifReader) void {
        if (self.blocks.len > 0) self.allocator.free(self.blocks);
        if (self.header.version_str.len > 0) self.allocator.free(self.header.version_str);
        if (self.header.block_types.len > 0) {
            for (self.header.block_types) |s| {
                if (s.len > 0) self.allocator.free(s);
            }
            self.allocator.free(self.header.block_types);
        }
        if (self.header.block_type_indices.len > 0) self.allocator.free(self.header.block_type_indices);
        if (self.header.block_sizes.len > 0) self.allocator.free(self.header.block_sizes);
        if (self.header.strings.len > 0) {
            for (self.header.strings) |s| {
                if (s.len > 0) self.allocator.free(s);
            }
            self.allocator.free(self.header.strings);
        }
        if (self.header.groups.len > 0) self.allocator.free(self.header.groups);
    }

    /// Reads a trivially-copiable value from the buffer.
    pub fn read(self: *NifReader, comptime T: type) !T {
        if (self.pos + @sizeOf(T) > self.buffer.len) return error.EndOfBuffer;
        var val: T = undefined;
        @memcpy(std.mem.asBytes(&val), self.buffer[self.pos .. self.pos + @sizeOf(T)]);
        self.pos += @sizeOf(T);
        return val;
    }

    /// Returns a borrowed slice of `count` bytes from the buffer.
    pub fn read_bytes(self: *NifReader, count: usize) ![]const u8 {
        if (self.pos + count > self.buffer.len) return error.EndOfBuffer;
        const slice = self.buffer[self.pos .. self.pos + count];
        self.pos += count;
        return slice;
    }

    /// Reads a newline-terminated string (excluding the newline).
    pub fn read_string_lf(self: *NifReader) ![]u8 {
        var end = self.pos;
        while (end < self.buffer.len and self.buffer[end] != 0x0A) : (end += 1) {}
        const slice = try self.allocator.dupe(u8, self.buffer[self.pos..end]);
        self.pos = end + 1; // Skip \n
        return slice;
    }

    pub fn read_sized_string(self: *NifReader) ![]u8 {
        const len = try self.read(u32);
        if (len > 1024 * 4) return error.StringTooLong;
        if (len == 0) return try self.allocator.dupe(u8, "");
        const slice = try self.allocator.dupe(u8, self.buffer[self.pos .. self.pos + len]);
        self.pos += len;
        return slice;
    }

    // --- Reader Interface for Schema ---
    pub fn readInt(self: *NifReader, comptime T: type, endian: std.builtin.Endian) !T {
        _ = endian; // NIF is always Little Endian (mostly)
        return self.read(T);
    }

    pub fn readFloat(self: *NifReader, comptime T: type, endian: std.builtin.Endian) !T {
        _ = endian;
        return self.read(T);
    }

    pub fn readNoEof(self: *NifReader, buf: []u8) !void {
        if (self.pos + buf.len > self.buffer.len) return error.EndOfBuffer;
        @memcpy(buf, self.buffer[self.pos .. self.pos + buf.len]);
        self.pos += buf.len;
    }

    // --- Parse Header ---
    pub fn parse_header(self: *NifReader) !void {
        // Header string: "NetImmerse File Format, Version X.X.X.X\n"
        self.header.version_str = try self.read_string_lf();
        nif_log.warn("NIF Header: {s}", .{self.header.version_str});

        self.header.version = try self.read(u32);
        self.header.endian_type = try self.read(u8); // 1 = Little Endian
        self.header.user_version = try self.read(u32);
        self.header.num_blocks = try self.read(u32);

        var skip_meta_data = false;

        if (self.header.version >= 0x14010003) {
            // Heuristic: Check if UserVer2 should be skipped
            var looks_like_block_types = false;
            if (self.pos + 6 <= self.buffer.len) {
                const num_types = std.mem.readInt(u16, self.buffer[self.pos..][0..2], .little);
                const str_len = std.mem.readInt(u32, self.buffer[self.pos + 2 ..][0..4], .little);
                // Allow reasonable limits for validation
                if (num_types > 0 and num_types < 256 and str_len > 0 and str_len < 256) {
                    // Check ASCII
                    if (self.pos + 6 + str_len <= self.buffer.len) {
                        const str = self.buffer[self.pos + 6 ..][0..str_len];
                        var is_ascii = true;
                        for (str) |char| {
                            if (char < 32 or char > 126) {
                                is_ascii = false;
                                break;
                            }
                        }
                        if (is_ascii) looks_like_block_types = true;
                    }
                }
            }

            if (looks_like_block_types) {
                nif_log.warn("Heuristic: Detected Block Types at Pos {d}. Skipping UserVer2.", .{self.pos});
                self.header.user_version_2 = 0;
                skip_meta_data = true;
            } else {
                self.header.user_version_2 = try self.read(u32);
            }
        } else {
            self.header.user_version_2 = 0;
        }

        nif_log.warn("NIF Version: 0x{x}, Blocks: {d}, Endian: {d}, UserVer: {d}, UserVer2: {d}", .{ self.header.version, self.header.num_blocks, self.header.endian_type, self.header.user_version, self.header.user_version_2 });

        // NIF File Metadata (Since 20.2.0.7?)
        if (self.header.version >= 0x14020008 and !skip_meta_data) {
            var looks_like_block_types = false;
            if (self.pos + 6 <= self.buffer.len) {
                const num_types = std.mem.readInt(u16, self.buffer[self.pos..][0..2], .little);
                const str_len = std.mem.readInt(u32, self.buffer[self.pos + 2 ..][0..4], .little);
                if (num_types > 0 and num_types < 256 and str_len > 0 and str_len < 256) {
                    if (self.pos + 6 + str_len <= self.buffer.len) {
                        const str = self.buffer[self.pos + 6 ..][0..str_len];
                        var is_ascii = true;
                        for (str) |char| {
                            if (char < 32 or char > 126) {
                                is_ascii = false;
                                break;
                            }
                        }
                        if (is_ascii) looks_like_block_types = true;
                    }
                }
            }

            if (looks_like_block_types) {
                nif_log.warn("Heuristic: Detected Block Types at Pos {d}. Skipping MetaData.", .{self.pos});
                skip_meta_data = true;
            } else {
                const num_meta = try self.read(u32);
                nif_log.warn("Num Meta Data: {d} (Pos: {d})", .{ num_meta, self.pos });
            }
        }

        // Parse Block Types (Version >= 20.0.0.5)
        if (self.header.version >= 0x14000005) {
            self.header.num_block_types = try self.read(u16);
            nif_log.warn("Num Block Types: {d} (Pos: {d})", .{ self.header.num_block_types, self.pos });

            self.header.block_types = try self.allocator.alloc([]u8, self.header.num_block_types);
            for (self.header.block_types) |*s| s.* = &.{};

            var i: usize = 0;
            while (i < self.header.num_block_types) : (i += 1) {
                self.header.block_types[i] = try self.read_sized_string();
            }

            self.header.block_type_indices = try self.allocator.alloc(u16, self.header.num_blocks);
            i = 0;
            while (i < self.header.num_blocks) : (i += 1) {
                self.header.block_type_indices[i] = try self.read(u16);
            }

            self.header.block_sizes = try self.allocator.alloc(u32, self.header.num_blocks);
            i = 0;
            nif_log.debug("Reading Block Sizes at Pos: {d}", .{self.pos});
            while (i < self.header.num_blocks) : (i += 1) {
                self.header.block_sizes[i] = try self.read(u32);
            }

            self.header.num_strings = try self.read(u32);
            nif_log.debug("Num Strings: {d} (Pos: {d})", .{ self.header.num_strings, self.pos });

            const max_str_len = try self.read(u32);
            nif_log.debug("Max String Length: {d} (Pos: {d})", .{ max_str_len, self.pos });

            self.header.strings = try self.allocator.alloc([]u8, self.header.num_strings);
            for (self.header.strings) |*s| s.* = &.{};

            const MAX_STR_LEN = 1024 * 4;

            i = 0;
            while (i < self.header.num_strings) : (i += 1) {
                const len = try self.read(u32);
                if (len > MAX_STR_LEN) return error.StringTooLong;
                const slice = try self.allocator.dupe(u8, self.buffer[self.pos .. self.pos + len]);
                self.pos += len;
                self.header.strings[i] = slice;
            }

            const num_groups = try self.read(u32);
            if (num_groups > 0) {
                self.header.groups = try self.allocator.alloc(u32, num_groups);
                i = 0;
                while (i < num_groups) : (i += 1) {
                    self.header.groups[i] = try self.read(u32);
                }
            } else {
                self.header.groups = &.{};
            }
        } else {
            return error.UnsupportedVersion;
        }
    }

    pub fn parse_blocks(self: *NifReader) !void {
        self.blocks = try self.allocator.alloc(NifBlock, self.header.num_blocks);

        var i: usize = 0;
        while (i < self.header.num_blocks) : (i += 1) {
            const block = &self.blocks[i];
            block.type_index = self.header.block_type_indices[i];
            block.size = self.header.block_sizes[i];
            block.data_offset = self.pos;
            block.parsed = null;

            const type_name = self.header.block_types[block.type_index];

            // Safe parsing: always restore position to end of block
            const end_pos = block.data_offset + block.size;
            defer self.pos = end_pos;

            if (nif_schema.blockTypeFromString(type_name)) |block_type| {
                const schema_header = nif_schema.Header{
                    .version = self.header.version,
                    .user_version = self.header.user_version,
                    .user_version_2 = self.header.user_version_2,
                };
                nif_log.warn("Parsing block {d}: {s} (Size: {d})", .{ i, type_name, block.size });
                block.parsed = try nif_schema.read_block(self.allocator, self, schema_header, block_type);
            } else {
                nif_log.warn("Unknown block type: {s}", .{type_name});
            }
        }
    }
};

// Helper: Get property block from a list of properties
fn findProperty(reader: *NifReader, properties: ?[]i32, comptime Tag: std.meta.Tag(nif_schema.NifBlockData)) ?std.meta.TagPayload(nif_schema.NifBlockData, Tag) {
    @setEvalBranchQuota(100000);
    if (properties) |props| {
        for (props) |prop_ref| {
            if (prop_ref < 0 or prop_ref >= reader.header.num_blocks) continue;
            const block = &reader.blocks[@as(usize, @intCast(prop_ref))];
            if (block.parsed) |parsed| {
                if (std.meta.activeTag(parsed) == Tag) {
                    return @field(parsed, @tagName(Tag));
                }
            }
        }
    }
    return null;
}

// Helper: Resolve NIF file path (SizedString or IndexString)
fn resolveFilePath(reader: *NifReader, file_path: ?nif_schema.FilePath) ?[]const u8 {
    if (file_path) |fp| {
        if (fp.Index) |idx| {
            if (idx >= 0 and idx < reader.header.num_strings) {
                return reader.header.strings[@as(usize, @intCast(idx))];
            }
        } else if (fp.String) |str| {
            if (str.Value.len > 0) return @ptrCast(str.Value);
        }
    }
    return null;
}

fn resolve_texture_path(allocator: std.mem.Allocator, nif_path: []const u8, texture_path: []const u8) ?[:0]u8 {
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

    // 1. Normalize basic path (replace \ with / and lower case)
    var norm_base = allocator.alloc(u8, texture_path.len + 1) catch return null;
    var i: usize = 0;
    for (texture_path) |char| {
        if (char == '\\') {
            norm_base[i] = '/';
        } else {
            norm_base[i] = std.ascii.toLower(char);
        }
        i += 1;
    }
    norm_base[i] = 0;
    const norm_base_slice = norm_base[0..i :0];
    defer allocator.free(norm_base_slice);

    // 2. Check if it exists as is (relative to CWD)
    if (ExistsCheck.exists(norm_base_slice)) {
        return allocator.dupeZ(u8, norm_base_slice) catch null;
    }

    // 3. Try relative to NIF
    const nif_dir = std.fs.path.dirname(nif_path) orelse ".";
    const path_rel = std.fs.path.join(allocator, &.{ nif_dir, norm_base_slice }) catch return null;
    defer allocator.free(path_rel);

    if (ExistsCheck.exists(path_rel)) {
        return allocator.dupeZ(u8, path_rel) catch null;
    }

    // 4. Try sibling "texture" directory if in "model" directory (common structure)
    // Try ../texture/filename relative to NIF dir
    const sibling_texture_path = std.fs.path.join(allocator, &.{ nif_dir, "../texture", norm_base_slice }) catch return null;
    defer allocator.free(sibling_texture_path);

    if (ExistsCheck.exists(sibling_texture_path)) {
        return allocator.dupeZ(u8, sibling_texture_path) catch null;
    }

    // Fallback: return the normalized base path
    return allocator.dupeZ(u8, norm_base_slice) catch null;
}

fn getSkinMaxVertexIndex(reader: *NifReader, skin_inst_idx: usize) u32 {
    if (skin_inst_idx >= reader.blocks.len) return 0;
    const block = &reader.blocks[skin_inst_idx];
    if (block.parsed) |parsed| {
        if (std.meta.activeTag(parsed) == .NiSkinInstance) {
            const skin_inst = parsed.NiSkinInstance;

            // Check NiSkinData
            if (skin_inst.Data >= 0 and skin_inst.Data < reader.header.num_blocks) {
                const data_block = &reader.blocks[@as(usize, @intCast(skin_inst.Data))];
                if (data_block.parsed) |data_parsed| {
                    if (std.meta.activeTag(data_parsed) == .NiSkinData) {
                        const sd = data_parsed.NiSkinData;
                        var max_idx: u32 = 0;
                        for (sd.Bone_List) |bone| {
                            if (bone.Vertex_Weights) |weights| {
                                for (weights) |w| {
                                    if (w.Index > max_idx) max_idx = w.Index;
                                }
                            } else if (bone.Vertex_Weights_1) |weights| {
                                for (weights) |w| {
                                    if (w.Index > max_idx) max_idx = w.Index;
                                }
                            }
                        }
                        return max_idx;
                    }
                }
            }

            // Check NiSkinPartition (if data check was insufficient or unavailable)
            if (skin_inst.Skin_Partition) |part_ref| {
                if (part_ref >= 0 and part_ref < reader.header.num_blocks) {
                    const part_block = &reader.blocks[@as(usize, @intCast(part_ref))];
                    if (part_block.parsed) |part_parsed| {
                        if (std.meta.activeTag(part_parsed) == .NiSkinPartition) {
                            const sp = part_parsed.NiSkinPartition;
                            var max_idx: u32 = 0;
                            for (sp.Partitions) |p| {
                                if (p.Vertex_Map) |vm| {
                                    for (vm) |idx| {
                                        if (idx > max_idx) max_idx = idx;
                                    }
                                } else if (p.Vertex_Map_1) |vm| {
                                    for (vm) |idx| {
                                        if (idx > max_idx) max_idx = idx;
                                    }
                                } else {
                                    nif_log.warn("Heuristic: Partition has no Vertex Map! Cannot determine max index.", .{});
                                }
                            }
                            nif_log.warn("Heuristic: NiSkinPartition (Block {d}) Max Index found: {d}", .{ part_ref, max_idx });
                            return max_idx;
                        }
                    }
                }
            }
        }
    }
    return 0;
}

/// Parses a KF file and merges any controller sequences into `out_scene.animation_system`.
pub export fn cardinal_nif_merge_kf(path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool {
    const file_path = std.mem.span(path);
    nif_log.info("Merging KF: {s}", .{file_path});

    var file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        nif_log.err("Failed to open KF file: {s} ({})", .{ file_path, err });
        return false;
    };
    defer file.close();

    const file_size = file.getEndPos() catch 0;
    const buffer = std.heap.c_allocator.alloc(u8, file_size) catch return false;
    defer std.heap.c_allocator.free(buffer);
    _ = file.readAll(buffer) catch return false;

    var reader = NifReader.init(std.heap.c_allocator, buffer);
    defer reader.deinit();

    reader.parse_header() catch |err| {
        nif_log.err("Failed to parse KF header: {}", .{err});
        return false;
    };

    reader.parse_blocks() catch |err| {
        nif_log.err("Failed to parse KF blocks: {}", .{err});
        return false;
    };

    // Find NiControllerSequence blocks
    var seq_count: usize = 0;
    var i: usize = 0;
    while (i < reader.header.num_blocks) : (i += 1) {
        const block = &reader.blocks[i];
        if (block.parsed) |parsed| {
            if (std.meta.activeTag(parsed) == .NiControllerSequence) {
                seq_count += 1;
            }
        }
    }

    if (seq_count == 0) {
        nif_log.warn("No sequences found in KF.", .{});
        return true; // Not an error, just nothing to do
    }

    // Initialize Animation System if not present
    if (out_scene.animation_system == null) {
        // Create animation system with capacity for found sequences
        // We need to import animation module properly or use the function pointer/extern if available?
        // nif_loader imports animation.zig, so we can use it directly.
        out_scene.animation_system = @ptrCast(animation.cardinal_animation_system_create(@intCast(seq_count + 10), 10)); // +10 buffer
        nif_log.info("Initialized Animation System for KF merge (Capacity: {d})", .{seq_count + 10});
    }

    const anim_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(out_scene.animation_system.?)));

    // Iterate sequences and add to scene
    i = 0;
    while (i < reader.header.num_blocks) : (i += 1) {
        const block = &reader.blocks[i];
        if (block.parsed) |parsed| {
            if (std.meta.activeTag(parsed) == .NiControllerSequence) {
                const seq = parsed.NiControllerSequence;
                var seq_name: []const u8 = "Unknown";

                const s = getNifString(seq.base.Name, reader.header.strings);
                if (s.len > 0) {
                    seq_name = s;
                }

                nif_log.info("Found Sequence: {s}, Roots: {d}", .{ seq_name, seq.base.Num_Controlled_Blocks });

                // Create CardinalAnimation from NiControllerSequence
                var anim_desc = std.mem.zeroes(animation.CardinalAnimation);

                // Name
                // We need to allocate name because animation system takes ownership or copies?
                // cardinal_animation_system_add_animation copies the name string.
                // So we can just pass a pointer to our stack/temp string.
                // But wait, seq_name is a slice. We need a null-terminated string.
                const name_z = std.heap.c_allocator.dupeZ(u8, seq_name) catch "Unknown";
                defer if (seq_name.len > 0) std.heap.c_allocator.free(name_z);

                // name_z.ptr is [*:0]u8 if it's from dupeZ, but [*:0]const u8 if it's "Unknown" literal.
                // We need to handle both cases or ensure we always have a mutable buffer if required,
                // but "Unknown" is const.
                // The C struct likely wants [*:0]u8 (non-const) if it modifies it, or it should be const.
                // Looking at error: expected '?[*:0]u8', found '[*:0]const u8'.
                // So the struct field is mutable.
                // If we pass "Unknown", we need to cast away const, BUT we must ensure the C code doesn't write to it.
                // cardinal_animation_system_add_animation copies the string, so it's safe to read.
                anim_desc.name = @constCast(name_z.ptr);

                // Duration
                // Start_Time and Stop_Time might be optional or just f32.
                // In some NIF schemas they are f32, in others optional.
                // Error says: invalid operands to binary expression: 'optional' and 'optional'
                // So they are optional.
                const start = seq.Start_Time orelse 0.0;
                const stop = seq.Stop_Time orelse 0.0;
                anim_desc.duration = stop - start;
                if (anim_desc.duration < 0) anim_desc.duration = 0;

                // Cycle Type (Loop)
                // Cycle_Type: 0=Loop, 1=Reverse, 2=Clamp
                // We don't have a direct field in CardinalAnimation for loop mode yet (it's in state),
                // but we can store it or use it for defaults.

                // Add to system
                _ = animation.cardinal_animation_system_add_animation(anim_sys, &anim_desc);

                // Controlled Blocks link to nodes
                for (seq.base.Controlled_Blocks) |cb| {
                    var node_name: []const u8 = "None";
                    if (cb.Node_Name) |nn| {
                        const ns = getNifString(nn, reader.header.strings);
                        if (ns.len > 0) {
                            node_name = ns;
                        }
                    }
                    // nif_log.info("  Target Node: {s}", .{node_name});
                }
            }
        }
    }

    return true;
}

/// Parses a NIF file and populates `out_scene` with meshes/materials/textures/nodes and skins.
pub export fn cardinal_nif_load_scene(path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool {
    @setEvalBranchQuota(100000);
    const file_path = std.mem.span(path);
    nif_log.info("Loading NIF: {s}", .{file_path});
    const assets_allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    var file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        nif_log.err("Failed to open file: {s} ({})", .{ file_path, err });
        return false;
    };
    defer file.close();

    const file_size = file.getEndPos() catch 0;
    const buffer = std.heap.c_allocator.alloc(u8, file_size) catch return false;
    defer std.heap.c_allocator.free(buffer);
    _ = file.readAll(buffer) catch return false;

    var reader = NifReader.init(std.heap.c_allocator, buffer);
    defer reader.deinit();

    reader.parse_header() catch |err| {
        nif_log.err("Failed to parse header: {}", .{err});
        return false;
    };

    reader.parse_blocks() catch |err| {
        nif_log.err("Failed to parse blocks: {}", .{err});
        return false;
    };

    var nodes = std.ArrayListUnmanaged(?*scene.CardinalSceneNode){};
    defer nodes.deinit(std.heap.c_allocator);

    // Resize nodes to match blocks (some will be null)
    nodes.appendNTimes(std.heap.c_allocator, null, reader.header.num_blocks) catch return false;

    var meshes = std.ArrayListUnmanaged(scene.CardinalMesh){};
    defer meshes.deinit(std.heap.c_allocator);

    // Parallel array to store skin instance block ref for each mesh (block index)
    var mesh_skin_refs = std.ArrayListUnmanaged(?i32){};
    defer mesh_skin_refs.deinit(std.heap.c_allocator);

    var materials = std.ArrayListUnmanaged(scene.CardinalMaterial){};
    defer materials.deinit(std.heap.c_allocator);

    var textures = std.ArrayListUnmanaged(scene.CardinalTexture){};
    defer textures.deinit(std.heap.c_allocator);

    // Pass 1: Create Nodes
    var i: usize = 0;
    while (i < reader.header.num_blocks) : (i += 1) {
        const block = &reader.blocks[i];
        if (block.parsed) |parsed_data| {
            // Check for Node-like types (NiNode, NiTriShape, etc.)
            var is_node = false;
            var node_name_str: []const u8 = "";
            var translation: [3]f32 = .{ 0, 0, 0 };
            var rotation: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
            var scale: f32 = 1.0;
            var properties: ?[]i32 = null;

            // Extract common node data
            switch (parsed_data) {
                .NiNode => |node| {
                    is_node = true;
                    node_name_str = getNifString(node.base.base.Name, reader.header.strings);
                    translation = .{ node.base.Translation.x, node.base.Translation.y, node.base.Translation.z };
                    rotation[0] = node.base.Rotation.m11;
                    rotation[1] = node.base.Rotation.m12;
                    rotation[2] = node.base.Rotation.m13;
                    rotation[3] = node.base.Rotation.m21;
                    rotation[4] = node.base.Rotation.m22;
                    rotation[5] = node.base.Rotation.m23;
                    rotation[6] = node.base.Rotation.m31;
                    rotation[7] = node.base.Rotation.m32;
                    rotation[8] = node.base.Rotation.m33;
                    scale = node.base.Scale;
                    properties = node.base.Properties;
                },
                .NiTriShape => |shape| {
                    is_node = true;
                    node_name_str = getNifString(shape.base.base.base.base.Name, reader.header.strings);
                    translation = .{ shape.base.base.base.Translation.x, shape.base.base.base.Translation.y, shape.base.base.base.Translation.z };
                    rotation[0] = shape.base.base.base.Rotation.m11;
                    rotation[1] = shape.base.base.base.Rotation.m12;
                    rotation[2] = shape.base.base.base.Rotation.m13;
                    rotation[3] = shape.base.base.base.Rotation.m21;
                    rotation[4] = shape.base.base.base.Rotation.m22;
                    rotation[5] = shape.base.base.base.Rotation.m23;
                    rotation[6] = shape.base.base.base.Rotation.m31;
                    rotation[7] = shape.base.base.base.Rotation.m32;
                    rotation[8] = shape.base.base.base.Rotation.m33;
                    scale = shape.base.base.base.Scale;
                    properties = shape.base.base.base.Properties;
                },
                else => {},
            }

            if (is_node) {
                var s_z: ?[:0]u8 = null;
                defer if (s_z) |s| std.heap.c_allocator.free(s);

                if (node_name_str.len > 0) {
                    s_z = std.heap.c_allocator.dupeZ(u8, node_name_str) catch return false;
                } else {
                    s_z = std.heap.c_allocator.dupeZ(u8, "Node") catch return false;
                }

                const sn = scene.cardinal_scene_node_create(s_z.?) orelse return false;

                nodes.items[i] = sn;

                // Transform
                var transform_mat: [16]f32 = undefined;
                transform.cardinal_matrix_from_rt_s(&rotation, &translation, scale, &transform_mat);
                if (i == 0) {
                    const nif_to_engine = [16]f32{
                        1, 0, 0,  0,
                        0, 0, -1, 0,
                        0, 1, 0,  0,
                        0, 0, 0,  1,
                    };
                    var corrected: [16]f32 = undefined;
                    transform.cardinal_matrix_multiply(&nif_to_engine, &transform_mat, &corrected);
                    transform_mat = corrected;
                }
                scene.cardinal_scene_node_set_local_transform(sn, &transform_mat);

                // Material & Texture (Create Material if properties exist)
                var mat_index: i32 = -1;

                // Check for material/texture properties
                var has_mat_prop = false;
                var has_tex_prop = false;

                var mat = std.mem.zeroes(scene.CardinalMaterial);
                mat.albedo_factor = .{ 1, 1, 1, 1 };
                mat.roughness_factor = 1.0;
                mat.metallic_factor = 0.0;
                mat.emissive_strength = 1.0;
                mat.normal_scale = 1.0;
                mat.ao_strength = 1.0;
                mat.alpha_mode = .OPAQUE;
                mat.alpha_cutoff = 0.5;
                mat.albedo_texture = handles.TextureHandle.INVALID;
                mat.normal_texture = handles.TextureHandle.INVALID;
                mat.metallic_roughness_texture = handles.TextureHandle.INVALID;
                mat.ao_texture = handles.TextureHandle.INVALID;
                mat.emissive_texture = handles.TextureHandle.INVALID;
                mat.albedo_transform.scale = .{ 1, 1 };
                mat.normal_transform.scale = .{ 1, 1 };
                mat.metallic_roughness_transform.scale = .{ 1, 1 };
                mat.ao_transform.scale = .{ 1, 1 };
                mat.emissive_transform.scale = .{ 1, 1 };

                // Material Property
                if (findProperty(&reader, properties, .NiMaterialProperty)) |mat_prop| {
                    has_mat_prop = true;
                    if (mat_prop.Diffuse_Color) |dc| {
                        mat.albedo_factor = .{
                            std.math.clamp(dc.r, 0.0, 1.0),
                            std.math.clamp(dc.g, 0.0, 1.0),
                            std.math.clamp(dc.b, 0.0, 1.0),
                            std.math.clamp(mat_prop.Alpha, 0.0, 1.0),
                        };
                    }
                    mat.emissive_factor = .{ mat_prop.Emissive_Color.r, mat_prop.Emissive_Color.g, mat_prop.Emissive_Color.b };
                    // Approximate roughness from glossiness? Gloss 0-100 usually.
                    // Roughness = 1 - (Gloss / 100) or similar.
                    mat.roughness_factor = std.math.clamp(1.0 - (mat_prop.Glossiness / 100.0), 0.0, 1.0);
                    nif_log.info("Mesh 3 has MaterialProperty: Alpha={d}", .{mat_prop.Alpha});
                    if (mat_prop.Diffuse_Color) |dc| {
                        nif_log.info("  Diffuse({d},{d},{d})", .{ dc.r, dc.g, dc.b });
                    }
                    if (findProperty(&reader, properties, .NiAlphaProperty)) |alpha_prop| {
                        has_mat_prop = true;
                        const flags_u32: u32 = @bitCast(@as(i32, alpha_prop.Flags));
                        const flags16: u32 = flags_u32 & 0xFFFF;
                        const reconstructed_threshold: u8 = @intCast((flags_u32 >> 16) & 0xFF);
                        const threshold_u8: u8 = if (alpha_prop.Threshold == 0 and flags_u32 > 0xFFFF) reconstructed_threshold else alpha_prop.Threshold;

                        const blend_enabled = (flags16 & 1) != 0;
                        const test_enabled = (flags16 & (1 << 9)) != 0;

                        if (test_enabled) {
                            mat.alpha_mode = .MASK;
                            mat.alpha_cutoff = if (threshold_u8 == 0) (1.0 / 255.0) else (@as(f32, @floatFromInt(threshold_u8)) / 255.0);
                        } else if (blend_enabled) {
                            mat.alpha_mode = if (mat_prop.Alpha < 0.99) .BLEND else .OPAQUE;
                        } else {
                            mat.alpha_mode = .OPAQUE;
                        }

                        // Force OPAQUE if flags look garbage (very large number) or if we suspect it's misinterpreting.
                        // 92082924 (0x057D12EC) has bit 0 (0x1) NOT set (0xC = 1100).
                        // Bit 9 (0x200) is ... 0x...2EC. E is 1110. C is 1100.
                        // 9th bit: 0x200.
                        // 0x...2EC:
                        // ... 0010 1110 1100
                        // Bit 0 is 0.
                        // Bit 9 is 1. (0x200 is set).
                        // So test_enabled = true.
                        // Threshold is 0.
                        // Mode is MASK. Cutoff 0.
                        // In GLTF/Shader: if (alpha < cutoff) discard.
                        // if (1.0 < 0.0) discard -> False. Visible.
                        // But if the shader logic is `if (alpha <= cutoff) discard`, then alpha 0 would be discarded.
                        // But our vertices have alpha?
                        // Vertex colors might have alpha.
                        // Diffuse color has alpha.
                        // The log said: "Mesh 3 has MaterialProperty: Alpha=1, Diffuse(1,1,1)". So Alpha is 1.0.
                        // Vertices have color {1,1,1,1}.
                        // Texture? If texture is present, it might have alpha channel.
                        // "DDS loaded ... Format: 138".
                        // If texture alpha is 0 (or absent/black), and we use it...

                        nif_log.info("Mesh Alpha Mode: {any}, Cutoff: {d}, Flags: 0x{x} (flags16=0x{x}, thr={d})", .{ mat.alpha_mode, mat.alpha_cutoff, flags_u32, flags16, threshold_u8 });
                    }

                    // Stencil Property (Double Sided)
                    if (findProperty(&reader, properties, .NiStencilProperty)) |stencil_prop| {
                        // Flags Bit 0: Enabled (if 0, default culling?)
                        // Flags Bit 1: Double Sided (if 1, no culling)
                        // Wait, standard NIF:
                        // Bit 0: Enabled
                        // Bit 1: FAIL Action...
                        // Actually, culling is often determined by the "Cull Mode" in Stencil or separate property.
                        // But in older NIFs, Stencil Property controls double sidedness.
                        // Flags:
                        // 0: Standard (Cull Back)
                        // ?
                        // Let's check schema. But commonly, if Stencil Property exists and Draw Mode is DOUBLE_SIDED...
                        // In many NIF versions:
                        // Bit 0-11: Standard stencil stuff.
                        // Double sided is often a separate flag or derived.
                        // However, `NiStencilProperty` often implies "Two Sided" in some exporters if enabled.
                        // Let's check `stencil_prop.Flags`.
                        // In NifSkope: "Draw Mode" -> 0=CW, 1=CCW, 2=BOTH.
                        // Flags bits 16-17? Or bits 0-?
                        // Let's assume for now if Stencil Property is present, we might want to enable double sided if configured.
                        // Actually, let's just log it for now.
                        // But we can check `Draw_Mode`.
                        // In our schema `NiStencilProperty` has `Flags`.
                        // Bits 10-11 usually control Face Culling (0=None?, 1=CW, 2=CCW?)
                        // Wait, NIF default is Cull Back (CCW winding, Cull CW backfaces?).
                        // If Draw Mode is 2 (BOTH), then double sided.

                        // From NifDocs:
                        // Bit 0: Enable
                        // Bit 1-3: Fail Action
                        // ...
                        // Bit 10-11: Culling Mode (0=NONE, 1=CW, 2=CCW) -> 0 means Double Sided!

                        const flags = stencil_prop.Flags orelse 0;
                        const cull_mode = (flags >> 10) & 0x3;
                        if (cull_mode == 0) {
                            mat.double_sided = true;
                            nif_log.info("Mesh {d} is Double Sided (Stencil Cull Mode 0)", .{i});
                        }
                    }

                    // Texture Property
                    if (findProperty(&reader, properties, .NiTexturingProperty)) |tex_prop| {
                        has_tex_prop = true;
                        if (tex_prop.Has_Base_Texture and tex_prop.Base_Texture != null) {
                            const desc = tex_prop.Base_Texture.?;
                            if (desc.Source) |source_idx| {
                                if (source_idx >= 0 and source_idx < reader.header.num_blocks) {
                                    const source_block = &reader.blocks[@as(usize, @intCast(source_idx))];
                                    if (source_block.parsed) |source_parsed| {
                                        if (std.meta.activeTag(source_parsed) == .NiSourceTexture) {
                                            const source = source_parsed.NiSourceTexture;
                                            var raw_path: ?[]const u8 = null;
                                            if (source.Use_External == 1) {
                                                raw_path = resolveFilePath(&reader, source.File_Name);
                                            } else if (source.File_Name_1 != null) {
                                                raw_path = resolveFilePath(&reader, source.File_Name_1);
                                            }

                                            if (raw_path) |p| {
                                                // Create Texture
                                                const norm_path = resolve_texture_path(assets_allocator.as_allocator(), file_path, p);
                                                if (norm_path) |np| {
                                                    // Add texture to scene list
                                                    // Check if already loaded? Skip for now.
                                                    var tex = std.mem.zeroes(scene.CardinalTexture);
                                                    tex.path = @ptrCast(np.ptr);

                                                    var path_owned = true;
                                                    defer if (path_owned) assets_allocator.as_allocator().free(np);

                                                    var temp_data = std.mem.zeroes(texture_loader.TextureData);
                                                    const res = texture_loader.texture_load_with_ref_counting(@ptrCast(tex.path.?), &temp_data);
                                                    if (res) |r| {
                                                        tex.data = temp_data.data;
                                                        tex.width = temp_data.width;
                                                        tex.height = temp_data.height;
                                                        tex.channels = temp_data.channels;
                                                        tex.is_hdr = temp_data.is_hdr;
                                                        tex.format = promote_color_format_to_srgb(temp_data.format);
                                                        tex.data_size = temp_data.data_size;
                                                        tex.ref_resource = r;
                                                    }

                                                    textures.append(std.heap.c_allocator, tex) catch return false;
                                                    path_owned = false;
                                                    // 0-based index for texture handle
                                                    const idx: u32 = @intCast(textures.items.len - 1);
                                                    mat.albedo_texture = .{ .index = idx, .generation = 0 };
                                                    const uv_set_raw: u32 = desc.UV_Set orelse 0;
                                                    mat.uv_indices[0] = @intCast(if (uv_set_raw > 1) 1 else uv_set_raw);
                                                    nif_log.info("Assigned texture index {d} ({s}) to material", .{ idx, np });
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if (has_mat_prop or has_tex_prop) {
                        materials.append(std.heap.c_allocator, mat) catch return false;
                        mat_index = @as(i32, @intCast(materials.items.len - 1));
                    }

                    // Mesh Data
                    if (std.meta.activeTag(parsed_data) == .NiTriShape) {
                        const shape = parsed_data.NiTriShape;

                        if (shape.base.base.Skin_Instance) |si| {
                            nif_log.debug("NiTriShape (Block {d}) Skin Instance Ref: {d}", .{ i, si });
                        } else {
                            nif_log.debug("NiTriShape (Block {d}) Skin Instance Ref: null", .{i});
                        }

                        if (shape.base.base.Data) |d_idx| {
                            nif_log.debug("NiTriShape (Block {d}) Data Ref: {d}", .{ i, d_idx });
                            if (d_idx >= 0 and d_idx < reader.header.num_blocks) {
                                const data_block = &reader.blocks[@as(usize, @intCast(d_idx))];
                                if (data_block.parsed) |data_parsed| {
                                    if (std.meta.activeTag(data_parsed) == .NiTriShapeData) {
                                        nif_log.debug("Found NiTriShapeData at block {d}", .{d_idx});
                                        const data = data_parsed.NiTriShapeData;
                                        var mesh = std.mem.zeroes(scene.CardinalMesh);
                                        mesh.visible = true; // Ensure visible

                                        if (mat_index >= 0) {
                                            mesh.material_index = @as(u32, @intCast(mat_index));
                                        }

                                        // Vertices
                                        if (data.base.base.Vertices) |verts| {
                                            nif_log.debug("NiTriShapeData: Has {d} vertices", .{verts.len});
                                            mesh.vertex_count = @intCast(verts.len);
                                            // Allocate CardinalVertex array
                                            const c_verts_ptr = memory.cardinal_alloc(assets_allocator, mesh.vertex_count * @sizeOf(scene.CardinalVertex)) orelse return false;
                                            const c_verts = @as([*]scene.CardinalVertex, @ptrCast(@alignCast(c_verts_ptr)))[0..mesh.vertex_count];

                                            var min_pt = @import("../core/math.zig").Vec3{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32), .z = std.math.floatMax(f32) };
                                            var max_pt = @import("../core/math.zig").Vec3{ .x = -std.math.floatMax(f32), .y = -std.math.floatMax(f32), .z = -std.math.floatMax(f32) };

                                            for (c_verts, 0..) |*v, v_idx| {
                                                v.* = std.mem.zeroes(scene.CardinalVertex);
                                                v.px = verts[v_idx].x;
                                                v.py = verts[v_idx].y;
                                                v.pz = verts[v_idx].z;
                                                v.color = .{ 1, 1, 1, 1 }; // Default white

                                                if (v.px < min_pt.x) min_pt.x = v.px;
                                                if (v.py < min_pt.y) min_pt.y = v.py;
                                                if (v.pz < min_pt.z) min_pt.z = v.pz;
                                                if (v.px > max_pt.x) max_pt.x = v.px;
                                                if (v.py > max_pt.y) max_pt.y = v.py;
                                                if (v.pz > max_pt.z) max_pt.z = v.pz;
                                            }

                                            mesh.bounding_box_min = .{ min_pt.x, min_pt.y, min_pt.z };
                                            mesh.bounding_box_max = .{ max_pt.x, max_pt.y, max_pt.z };
                                            nif_log.debug("Mesh {d} AABB: Min({d}, {d}, {d}) Max({d}, {d}, {d})", .{ i, min_pt.x, min_pt.y, min_pt.z, max_pt.x, max_pt.y, max_pt.z });

                                            // Normals
                                            if (data.base.base.Normals) |norms| {
                                                for (c_verts, 0..) |*v, v_idx| {
                                                    if (v_idx < norms.len) {
                                                        v.nx = norms[v_idx].x;
                                                        v.ny = norms[v_idx].y;
                                                        v.nz = norms[v_idx].z;
                                                    }
                                                }
                                            }

                                            // UVs
                                            const uv_sets = data.base.base.UV_Sets;
                                            if (uv_sets.len > 0) {
                                                const uvs = uv_sets[0];
                                                var min_u: f32 = std.math.floatMax(f32);
                                                var max_u: f32 = -std.math.floatMax(f32);
                                                var min_v: f32 = std.math.floatMax(f32);
                                                var max_v: f32 = -std.math.floatMax(f32);
                                                var non_zero: usize = 0;
                                                for (c_verts, 0..) |*v, v_idx| {
                                                    if (v_idx < uvs.len) {
                                                        const u = uvs[v_idx].u;
                                                        const vv = uvs[v_idx].v;
                                                        v.u = u;
                                                        v.v = vv;
                                                        if (u != 0 or vv != 0) non_zero += 1;
                                                        if (u < min_u) min_u = u;
                                                        if (u > max_u) max_u = u;
                                                        if (vv < min_v) min_v = vv;
                                                        if (vv > max_v) max_v = vv;
                                                    }
                                                }
                                                nif_log.info("Mesh {d} UV0: count={d} nonZero={d} u={any}..{any} v={any}..{any}", .{ i, uvs.len, non_zero, min_u, max_u, min_v, max_v });
                                            } else {
                                                nif_log.warn("Mesh {d} has no UV sets", .{i});
                                                if (mat_index >= 0) {
                                                    const mi: usize = @intCast(mat_index);
                                                    if (mi < materials.items.len) {
                                                        const src = materials.items[mi];
                                                        if (src.albedo_texture.is_valid() or src.normal_texture.is_valid() or src.metallic_roughness_texture.is_valid() or src.ao_texture.is_valid() or src.emissive_texture.is_valid()) {
                                                            var m2 = src;
                                                            m2.albedo_texture = handles.TextureHandle.INVALID;
                                                            m2.normal_texture = handles.TextureHandle.INVALID;
                                                            m2.metallic_roughness_texture = handles.TextureHandle.INVALID;
                                                            m2.ao_texture = handles.TextureHandle.INVALID;
                                                            m2.emissive_texture = handles.TextureHandle.INVALID;
                                                            materials.append(std.heap.c_allocator, m2) catch return false;
                                                            mesh.material_index = @intCast(materials.items.len - 1);
                                                        }
                                                    }
                                                }
                                            }

                                            if (uv_sets.len > 1) {
                                                const uvs = uv_sets[1];
                                                var min_u: f32 = std.math.floatMax(f32);
                                                var max_u: f32 = -std.math.floatMax(f32);
                                                var min_v: f32 = std.math.floatMax(f32);
                                                var max_v: f32 = -std.math.floatMax(f32);
                                                var non_zero: usize = 0;
                                                for (c_verts, 0..) |*v, v_idx| {
                                                    if (v_idx < uvs.len) {
                                                        const u = uvs[v_idx].u;
                                                        const vv = uvs[v_idx].v;
                                                        v.u1 = u;
                                                        v.v1 = vv;
                                                        if (u != 0 or vv != 0) non_zero += 1;
                                                        if (u < min_u) min_u = u;
                                                        if (u > max_u) max_u = u;
                                                        if (vv < min_v) min_v = vv;
                                                        if (vv > max_v) max_v = vv;
                                                    }
                                                }
                                                nif_log.info("Mesh {d} UV1: count={d} nonZero={d} u={any}..{any} v={any}..{any}", .{ i, uvs.len, non_zero, min_u, max_u, min_v, max_v });
                                            }

                                            // Colors
                                            // Has_Vertex_Colors is in NiGeometryData?
                                            // nif.xml says "Has Vertex Colors" in NiGeometryData.
                                            if (data.base.base.Vertex_Colors) |colors| {
                                                for (c_verts, 0..) |*v, v_idx| {
                                                    if (v_idx < colors.len) {
                                                        v.color = .{
                                                            std.math.clamp(colors[v_idx].r, 0.0, 1.0),
                                                            std.math.clamp(colors[v_idx].g, 0.0, 1.0),
                                                            std.math.clamp(colors[v_idx].b, 0.0, 1.0),
                                                            1.0,
                                                        };
                                                    }
                                                }
                                            }

                                            mesh.vertices = c_verts.ptr;
                                        }

                                        // Indices
                                        var indices: ?[]u32 = null;
                                        var idx_offset_tris: usize = 0;
                                        if (data.Triangles) |tris| {
                                            const inds_ptr = memory.cardinal_alloc(assets_allocator, tris.len * 3 * @sizeOf(u32)) orelse return false;
                                            indices = @as([*]u32, @ptrCast(@alignCast(inds_ptr)))[0 .. tris.len * 3];
                                            for (tris) |tri| {
                                                const v1: u32 = tri.v1;
                                                const v2: u32 = tri.v2;
                                                const v3: u32 = tri.v3;
                                                if (v1 >= mesh.vertex_count or v2 >= mesh.vertex_count or v3 >= mesh.vertex_count) continue;
                                                indices.?[idx_offset_tris + 0] = v1;
                                                indices.?[idx_offset_tris + 1] = v2;
                                                indices.?[idx_offset_tris + 2] = v3;
                                                idx_offset_tris += 3;
                                            }
                                        } else if (data.Has_Triangles.? and data.Triangles_1 != null) {
                                            const tris = data.Triangles_1.?;
                                            const inds_ptr = memory.cardinal_alloc(assets_allocator, tris.len * 3 * @sizeOf(u32)) orelse return false;
                                            indices = @as([*]u32, @ptrCast(@alignCast(inds_ptr)))[0 .. tris.len * 3];
                                            for (tris) |tri| {
                                                const v1: u32 = tri.v1;
                                                const v2: u32 = tri.v2;
                                                const v3: u32 = tri.v3;
                                                if (v1 >= mesh.vertex_count or v2 >= mesh.vertex_count or v3 >= mesh.vertex_count) continue;
                                                indices.?[idx_offset_tris + 0] = v1;
                                                indices.?[idx_offset_tris + 1] = v2;
                                                indices.?[idx_offset_tris + 2] = v3;
                                                idx_offset_tris += 3;
                                            }
                                        }

                                        if (indices) |inds| {
                                            if (idx_offset_tris == 0) {
                                                memory.cardinal_free(assets_allocator, @ptrCast(inds.ptr));
                                            } else {
                                                mesh.index_count = @intCast(idx_offset_tris);
                                                mesh.indices = inds.ptr;
                                            }
                                        }

                                        // Determine Skin Instance
                                        var skin_inst_ref_final: ?i32 = shape.base.base.Skin_Instance;
                                        if (skin_inst_ref_final) |si| {
                                            if (si < 0) skin_inst_ref_final = null;
                                        }

                                        // --- Debug Logging for Transforms & Material ---
                                        const local_trans = shape.base.base.base.Translation;
                                        const local_scale = shape.base.base.base.Scale;
                                        nif_log.warn("Mesh {d} Transform: Pos({d}, {d}, {d}) Scale({d})", .{ i, local_trans.x, local_trans.y, local_trans.z, local_scale });

                                        if (shape.base.base.base.Properties) |props| {
                                            for (props) |prop_ref| {
                                                if (prop_ref >= 0 and prop_ref < reader.header.num_blocks) {
                                                    const prop_block = &reader.blocks[@as(usize, @intCast(prop_ref))];
                                                    if (prop_block.parsed) |pp| {
                                                        switch (std.meta.activeTag(pp)) {
                                                            .NiAlphaProperty => {
                                                                const alpha = pp.NiAlphaProperty;
                                                                nif_log.warn("Mesh {d} has AlphaProperty: Flags={d}, Threshold={d}", .{ i, alpha.Flags, alpha.Threshold });
                                                            },
                                                            .NiMaterialProperty => {
                                                                const debug_mat_prop = pp.NiMaterialProperty;
                                                                if (debug_mat_prop.Diffuse_Color) |diff| {
                                                                    nif_log.warn("Mesh {d} has MaterialProperty: Alpha={d}, Diffuse({d},{d},{d})", .{ i, debug_mat_prop.Alpha, diff.r, diff.g, diff.b });
                                                                } else {
                                                                    nif_log.warn("Mesh {d} has MaterialProperty: Alpha={d}, Diffuse(null)", .{ i, debug_mat_prop.Alpha });
                                                                }
                                                            },
                                                            else => {},
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        // -----------------------------------------------

                                        if (mesh.index_count == 0 and skin_inst_ref_final == null) {
                                            // Heuristic: Search for orphan NiSkinInstance
                                            var b_idx: usize = 0;
                                            while (b_idx < reader.header.num_blocks) : (b_idx += 1) {
                                                const search_block = &reader.blocks[b_idx];
                                                if (search_block.parsed) |search_parsed| {
                                                    if (std.meta.activeTag(search_parsed) == .NiSkinInstance) {
                                                        const max_idx = getSkinMaxVertexIndex(&reader, b_idx);
                                                        if (max_idx < mesh.vertex_count) {
                                                            skin_inst_ref_final = @as(i32, @intCast(b_idx));
                                                            nif_log.warn("Heuristic: Assigned orphan NiSkinInstance {d} to mesh {d} (Max Ref Idx: {d} < Vertex Count: {d})", .{ b_idx, i, max_idx, mesh.vertex_count });
                                                            break;
                                                        } else {
                                                            nif_log.warn("Heuristic: Skipped orphan NiSkinInstance {d} for mesh {d} (Max Ref Idx: {d} >= Vertex Count: {d})", .{ b_idx, i, max_idx, mesh.vertex_count });
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        if (skin_inst_ref_final) |skin_inst_ref| {
                                            if (skin_inst_ref >= 0 and skin_inst_ref < reader.header.num_blocks) {
                                                const skin_inst_block = &reader.blocks[@as(usize, @intCast(skin_inst_ref))];
                                                if (skin_inst_block.parsed) |skin_inst_parsed| {
                                                    if (std.meta.activeTag(skin_inst_parsed) == .NiSkinInstance) {
                                                        const skin_inst = skin_inst_parsed.NiSkinInstance;
                                                        if (skin_inst.Skin_Partition) |part_ref| {
                                                            if (part_ref >= 0 and part_ref < reader.header.num_blocks) {
                                                                const part_block = &reader.blocks[@as(usize, @intCast(part_ref))];
                                                                if (part_block.parsed) |part_parsed| {
                                                                    if (std.meta.activeTag(part_parsed) == .NiSkinPartition) {
                                                                        const partition = part_parsed.NiSkinPartition;
                                                                        // Collect triangles from all partitions
                                                                        var total_indices: usize = 0;
                                                                        for (partition.Partitions) |p| {
                                                                            if (p.Triangles) |tris| {
                                                                                total_indices += tris.len * 3;
                                                                            } else if (p.Triangles_1) |tris| {
                                                                                total_indices += tris.len * 3;
                                                                            } else if (p.Strips) |strips| {
                                                                                for (strips) |strip| {
                                                                                    if (strip.len >= 3) {
                                                                                        total_indices += (strip.len - 2) * 3;
                                                                                    }
                                                                                }
                                                                            } else if (p.Strips_1) |strips| {
                                                                                for (strips) |strip| {
                                                                                    if (strip.len >= 3) {
                                                                                        total_indices += (strip.len - 2) * 3;
                                                                                    }
                                                                                }
                                                                            }
                                                                        }

                                                                        if (total_indices > 0) {
                                                                            const skin_inds_ptr = memory.cardinal_alloc(assets_allocator, total_indices * @sizeOf(u32)) orelse return false;
                                                                            const skin_indices = @as([*]u32, @ptrCast(@alignCast(skin_inds_ptr)))[0..total_indices];
                                                                            var idx_offset: usize = 0;
                                                                            for (partition.Partitions) |p| {
                                                                                if (mesh.vertices) |verts| {
                                                                                    var vmap = p.Vertex_Map;
                                                                                    if (vmap == null) vmap = p.Vertex_Map_1;

                                                                                    var weights_opt = p.Vertex_Weights;
                                                                                    if (weights_opt == null) weights_opt = p.Vertex_Weights_1;

                                                                                    if (weights_opt) |weights_arr| {
                                                                                        if (p.Bone_Indices) |bone_indices_arr| {
                                                                                            const bones = p.Bones;
                                                                                            const limit = @min(weights_arr.len, bone_indices_arr.len);
                                                                                            var pv: usize = 0;
                                                                                            while (pv < limit) : (pv += 1) {
                                                                                                const orig_idx: u32 = if (vmap) |vm| blk: {
                                                                                                    if (pv < vm.len) break :blk vm[pv];
                                                                                                    break :blk @intCast(pv);
                                                                                                } else @intCast(pv);
                                                                                                if (orig_idx >= mesh.vertex_count) continue;

                                                                                                verts[orig_idx].bone_weights = .{ 0, 0, 0, 0 };
                                                                                                verts[orig_idx].bone_indices = .{ 0, 0, 0, 0 };

                                                                                                const v_weights = weights_arr[pv];
                                                                                                const v_bones = bone_indices_arr[pv];

                                                                                                var slot: usize = 0;
                                                                                                const wlimit = @min(v_weights.len, v_bones.len);
                                                                                                var k: usize = 0;
                                                                                                while (k < wlimit and slot < 4) : (k += 1) {
                                                                                                    const w = v_weights[k];
                                                                                                    if (w <= 0.001) continue;
                                                                                                    const local_bone_idx: u8 = v_bones[k];
                                                                                                    if (local_bone_idx >= bones.len) continue;
                                                                                                    const global_bone_idx = bones[local_bone_idx];
                                                                                                    verts[orig_idx].bone_weights[slot] = w;
                                                                                                    verts[orig_idx].bone_indices[slot] = @intCast(global_bone_idx);
                                                                                                    slot += 1;
                                                                                                }

                                                                                                const sum: f32 = verts[orig_idx].bone_weights[0] + verts[orig_idx].bone_weights[1] + verts[orig_idx].bone_weights[2] + verts[orig_idx].bone_weights[3];
                                                                                                if (sum < 0.0001) {
                                                                                                    verts[orig_idx].bone_weights = .{ 1, 0, 0, 0 };
                                                                                                    verts[orig_idx].bone_indices = .{ 0, 0, 0, 0 };
                                                                                                } else {
                                                                                                    const inv = 1.0 / sum;
                                                                                                    verts[orig_idx].bone_weights[0] *= inv;
                                                                                                    verts[orig_idx].bone_weights[1] *= inv;
                                                                                                    verts[orig_idx].bone_weights[2] *= inv;
                                                                                                    verts[orig_idx].bone_weights[3] *= inv;
                                                                                                }
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }

                                                                                // Helper to process a triangle
                                                                                const process_tri = struct {
                                                                                    fn func(v1_in: u32, v2_in: u32, v3_in: u32, part: anytype, out_indices: []u32, offset: *usize, mesh_ref: *scene.CardinalMesh) void {
                                                                                        const v1 = v1_in;
                                                                                        const v2 = v2_in;
                                                                                        const v3 = v3_in;

                                                                                        var vmap = part.Vertex_Map;
                                                                                        if (vmap == null) vmap = part.Vertex_Map_1;

                                                                                        var original_v1 = v1;
                                                                                        var original_v2 = v2;
                                                                                        var original_v3 = v3;

                                                                                        if (vmap) |vm| {
                                                                                            if (v1 < vm.len) original_v1 = vm[v1];
                                                                                            if (v2 < vm.len) original_v2 = vm[v2];
                                                                                            if (v3 < vm.len) original_v3 = vm[v3];
                                                                                        }

                                                                                        if (original_v1 >= mesh_ref.vertex_count or original_v2 >= mesh_ref.vertex_count or original_v3 >= mesh_ref.vertex_count) {
                                                                                            return;
                                                                                        }

                                                                                        if (offset.* + 3 > out_indices.len) return;
                                                                                        out_indices[offset.* + 0] = original_v1;
                                                                                        out_indices[offset.* + 1] = original_v2;
                                                                                        out_indices[offset.* + 2] = original_v3;
                                                                                        offset.* += 3;
                                                                                    }
                                                                                }.func;

                                                                                if (p.Triangles) |tris| {
                                                                                    for (tris) |tri| {
                                                                                        process_tri(tri.v1, tri.v2, tri.v3, p, skin_indices, &idx_offset, &mesh);
                                                                                    }
                                                                                } else if (p.Triangles_1) |tris| {
                                                                                    for (tris) |tri| {
                                                                                        process_tri(tri.v1, tri.v2, tri.v3, p, skin_indices, &idx_offset, &mesh);
                                                                                    }
                                                                                } else if (p.Strips) |strips| {
                                                                                    for (strips) |strip| {
                                                                                        if (strip.len < 3) continue;
                                                                                        var i_strip: usize = 0;
                                                                                        while (i_strip < strip.len - 2) : (i_strip += 1) {
                                                                                            const v1 = strip[i_strip];
                                                                                            const v2 = strip[i_strip + 1];
                                                                                            const v3 = strip[i_strip + 2];
                                                                                            if (i_strip % 2 == 0) {
                                                                                                process_tri(v1, v2, v3, p, skin_indices, &idx_offset, &mesh);
                                                                                            } else {
                                                                                                process_tri(v1, v3, v2, p, skin_indices, &idx_offset, &mesh);
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                } else if (p.Strips_1) |strips| {
                                                                                    for (strips) |strip| {
                                                                                        if (strip.len < 3) continue;
                                                                                        var i_strip: usize = 0;
                                                                                        while (i_strip < strip.len - 2) : (i_strip += 1) {
                                                                                            const v1 = strip[i_strip];
                                                                                            const v2 = strip[i_strip + 1];
                                                                                            const v3 = strip[i_strip + 2];
                                                                                            if (i_strip % 2 == 0) {
                                                                                                process_tri(v1, v2, v3, p, skin_indices, &idx_offset, &mesh);
                                                                                            } else {
                                                                                                process_tri(v1, v3, v2, p, skin_indices, &idx_offset, &mesh);
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                            mesh.index_count = @intCast(idx_offset);
                                                                            mesh.indices = skin_indices.ptr;
                                                                            nif_log.info("Loaded {d} indices from NiSkinPartition (Block {d})", .{ total_indices, part_ref });
                                                                        } else {
                                                                            nif_log.warn("NiSkinPartition (Block {d}) has 0 indices!", .{part_ref});
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        if (skin_inst_ref_final != null) {
                                            fixup_skinned_vertex_weights(&mesh);
                                        }

                                        // Debug: Check weights of first few vertices
                                        if (mesh.vertex_count > 0 and mesh.vertices != null) {
                                            const v0 = mesh.vertices.?[0];
                                            nif_log.info("Vertex 0 Weights: {d}, {d}, {d}, {d}", .{ v0.bone_weights[0], v0.bone_weights[1], v0.bone_weights[2], v0.bone_weights[3] });
                                            nif_log.info("Vertex 0 Joints: {d}, {d}, {d}, {d}", .{ v0.bone_indices[0], v0.bone_indices[1], v0.bone_indices[2], v0.bone_indices[3] });
                                            // Check max joint index vs total bones
                                        }

                                        nif_log.debug("About to append mesh with {d} vertices and {d} indices", .{ mesh.vertex_count, mesh.index_count });
                                        meshes.append(std.heap.c_allocator, mesh) catch return false;
                                        mesh_skin_refs.append(std.heap.c_allocator, skin_inst_ref_final) catch return false;
                                        nif_log.info("Added mesh {d} with {d} vertices and {d} indices", .{ meshes.items.len - 1, mesh.vertex_count, mesh.index_count });

                                        // Assign mesh to node
                                        // Allocate mesh_indices array for node
                                        const mesh_idx = @as(u32, @intCast(meshes.items.len - 1));
                                        const node_mesh_indices_ptr = memory.cardinal_alloc(assets_allocator, @sizeOf(u32)) orelse return false;
                                        const node_mesh_indices = @as([*]u32, @ptrCast(@alignCast(node_mesh_indices_ptr)))[0..1];
                                        node_mesh_indices[0] = mesh_idx;
                                        sn.mesh_indices = node_mesh_indices.ptr;
                                        sn.mesh_count = 1;
                                    } else {
                                        nif_log.warn("NiTriShape (Block {d}) Data Ref {d} is not NiTriShapeData (Tag: {any})", .{ i, d_idx, std.meta.activeTag(data_parsed) });
                                    }
                                }
                            }
                        } else {
                            nif_log.warn("NiTriShape (Block {d}) has no Data ref", .{i});
                        }
                    }
                }
            }
        }
    }

    // Pass 2: Hierarchy
    {
        var j: usize = 0;
        while (j < reader.header.num_blocks) : (j += 1) {
            const pass2_block = &reader.blocks[j];
            const parent_node_opt = nodes.items[j];

            if (parent_node_opt) |parent_node| {
                if (pass2_block.parsed) |parsed_data| {
                    if (std.meta.activeTag(parsed_data) == .NiNode) {
                        const node = parsed_data.NiNode;
                        nif_log.info("Node {d} has {d} children", .{ j, node.Children.len });
                        // Debug transform
                        // NiNode -> NiAVObject -> Translation
                        const translation = node.base.Translation;
                        const scale = node.base.Scale;

                        nif_log.info("Node {d} Transform: Pos({d},{d},{d}) Rot(Matrix) Scale({d})", .{ j, translation.x, translation.y, translation.z, scale });

                        for (node.Children) |child_ref| {
                            if (child_ref >= 0 and child_ref < reader.header.num_blocks) {
                                nif_log.info("  -> Child {d}", .{child_ref});
                                const child_idx: usize = @intCast(child_ref);
                                if (nodes.items[child_idx]) |child_node| {
                                    _ = scene.cardinal_scene_node_add_child(parent_node, child_node);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (nodes.items.len > 0) {
        var root_count: usize = 0;
        for (nodes.items) |n_opt| {
            if (n_opt) |n| {
                if (n.parent == null) root_count += 1;
            }
        }

        const count: usize = if (root_count > 0) root_count else 1;
        const roots_ptr = memory.cardinal_alloc(assets_allocator, count * @sizeOf(?*scene.CardinalSceneNode)) orelse return false;
        const roots = @as([*]?*scene.CardinalSceneNode, @ptrCast(@alignCast(roots_ptr)))[0..count];

        if (root_count > 0) {
            var wi: usize = 0;
            for (nodes.items) |n_opt| {
                if (n_opt) |n| {
                    if (n.parent == null) {
                        roots[wi] = n;
                        wi += 1;
                    }
                }
            }
        } else {
            roots[0] = nodes.items[0];
        }

        out_scene.root_nodes = roots.ptr;
        out_scene.root_node_count = @intCast(count);

        var ri: usize = 0;
        while (ri < count) : (ri += 1) {
            if (roots[ri]) |root| {
                scene.cardinal_scene_node_update_transforms(root, null);
                propagate_transforms_to_meshes(root, meshes.items);
            }
        }
    } else {
        out_scene.root_nodes = null;
        out_scene.root_node_count = 0;
    }

    if (meshes.items.len > 0) {
        nif_log.warn("Collecting {d} meshes for scene", .{meshes.items.len});
        out_scene.mesh_count = @intCast(meshes.items.len);
        const scene_meshes_ptr = memory.cardinal_alloc(assets_allocator, out_scene.mesh_count * @sizeOf(scene.CardinalMesh)) orelse return false;
        const scene_meshes = @as([*]scene.CardinalMesh, @ptrCast(@alignCast(scene_meshes_ptr)))[0..out_scene.mesh_count];
        @memcpy(scene_meshes, meshes.items);
        out_scene.meshes = scene_meshes.ptr;

        var total_verts: usize = 0;
        for (meshes.items, 0..) |m, m_idx| {
            total_verts += m.vertex_count;
            nif_log.warn("Mesh {d} Final AABB: Min({d:.2}, {d:.2}, {d:.2}) Max({d:.2}, {d:.2}, {d:.2}) Visible={any} VCount={d} ICount={d}", .{ m_idx, m.bounding_box_min[0], m.bounding_box_min[1], m.bounding_box_min[2], m.bounding_box_max[0], m.bounding_box_max[1], m.bounding_box_max[2], m.visible, m.vertex_count, m.index_count });
        }
        nif_log.info("Scene has {d} total vertices across {d} meshes", .{ total_verts, out_scene.mesh_count });
    } else {
        nif_log.warn("No meshes collected for scene!", .{});
    }

    if (materials.items.len > 0) {
        out_scene.material_count = @intCast(materials.items.len);
        const scene_mats_ptr = memory.cardinal_alloc(assets_allocator, out_scene.material_count * @sizeOf(scene.CardinalMaterial)) orelse return false;
        const scene_mats = @as([*]scene.CardinalMaterial, @ptrCast(@alignCast(scene_mats_ptr)))[0..out_scene.material_count];
        @memcpy(scene_mats, materials.items);
        out_scene.materials = scene_mats.ptr;
    }

    if (textures.items.len > 0) {
        out_scene.texture_count = @intCast(textures.items.len);
        const texs_ptr = memory.cardinal_calloc(assets_allocator, out_scene.texture_count, @sizeOf(scene.CardinalTexture));
        if (texs_ptr == null) return false;
        const scene_texs: [*]scene.CardinalTexture = @ptrCast(@alignCast(texs_ptr));
        @memcpy(scene_texs[0..out_scene.texture_count], textures.items);
        out_scene.textures = scene_texs;
    }

    // Populate all_nodes for the scene (Required for animation system)
    if (nodes.items.len > 0) {
        const all_nodes_ptr = memory.cardinal_alloc(assets_allocator, nodes.items.len * @sizeOf(?*scene.CardinalSceneNode)) orelse return false;
        const all_nodes = @as([*]?*scene.CardinalSceneNode, @ptrCast(@alignCast(all_nodes_ptr)))[0..nodes.items.len];
        @memcpy(all_nodes, nodes.items);
        out_scene.all_nodes = all_nodes.ptr;
        out_scene.all_node_count = @intCast(nodes.items.len);
        nif_log.info("Populated all_nodes with {d} entries", .{out_scene.all_node_count});
    }

    // Pass 4: Create Skins
    var skins = std.ArrayListUnmanaged(animation.CardinalSkin){};
    defer skins.deinit(std.heap.c_allocator);

    var b_idx: usize = 0;
    while (b_idx < reader.header.num_blocks) : (b_idx += 1) {
        const block = &reader.blocks[b_idx];
        if (block.parsed) |parsed| {
            if (std.meta.activeTag(parsed) == .NiSkinInstance) {
                const skin_inst = parsed.NiSkinInstance;
                var new_skin = std.mem.zeroes(animation.CardinalSkin);

                // Name
                var name_buf: [64]u8 = undefined;
                const name_slice = std.fmt.bufPrint(&name_buf, "Skin_{d}", .{b_idx}) catch "Skin";
                const skin_name_ptr = memory.cardinal_alloc(assets_allocator, name_slice.len + 1) orelse return false;
                const skin_name = @as([*]u8, @ptrCast(@alignCast(skin_name_ptr)))[0 .. name_slice.len + 1];
                @memcpy(skin_name[0..name_slice.len], name_slice);
                skin_name[name_slice.len] = 0;
                new_skin.name = @ptrCast(skin_name.ptr);

                // Find meshes that use this skin
                var skin_mesh_indices = std.ArrayListUnmanaged(u32){};
                defer skin_mesh_indices.deinit(std.heap.c_allocator);

                var m_idx: usize = 0;
                while (m_idx < mesh_skin_refs.items.len) : (m_idx += 1) {
                    if (mesh_skin_refs.items[m_idx]) |ref| {
                        if (ref == @as(i32, @intCast(b_idx))) {
                            skin_mesh_indices.append(std.heap.c_allocator, @intCast(m_idx)) catch continue;
                        }
                    }
                }

                if (skin_mesh_indices.items.len > 0) {
                    new_skin.mesh_count = @intCast(skin_mesh_indices.items.len);
                    const mesh_indices_ptr = memory.cardinal_alloc(assets_allocator, new_skin.mesh_count * @sizeOf(u32)) orelse return false;
                    const mesh_indices_arr = @as([*]u32, @ptrCast(@alignCast(mesh_indices_ptr)))[0..new_skin.mesh_count];
                    @memcpy(mesh_indices_arr, skin_mesh_indices.items);
                    new_skin.mesh_indices = mesh_indices_arr.ptr;
                }

                // Bones
                if (skin_inst.Data >= 0 and skin_inst.Data < reader.header.num_blocks) {
                    const data_block = &reader.blocks[@as(usize, @intCast(skin_inst.Data))];
                    if (data_block.parsed) |data_parsed| {
                        if (std.meta.activeTag(data_parsed) == .NiSkinData) {
                            const sd = data_parsed.NiSkinData;
                            const bone_count = @min(skin_inst.Bones.len, sd.Bone_List.len);

                            new_skin.bone_count = @intCast(bone_count);
                            if (bone_count > 0) {
                                const bones_ptr = memory.cardinal_alloc(assets_allocator, bone_count * @sizeOf(animation.CardinalBone)) orelse return false;
                                const bones_arr = @as([*]animation.CardinalBone, @ptrCast(@alignCast(bones_ptr)))[0..bone_count];
                                var k: usize = 0;
                                while (k < bone_count) : (k += 1) {
                                    var bone = std.mem.zeroes(animation.CardinalBone);
                                    bone.node_index = @intCast(skin_inst.Bones[k]); // Block Index

                                    // Inverse Bind Matrix
                                    const bone_data = sd.Bone_List[k];

                                    // Assuming Skin_Transform is the field name for Bone Transform in NiSkinData
                                    // If compiler fails, check nif_schema.zig
                                    const bt = bone_data.Skin_Transform;

                                    const skin_bind = nif_transform_to_mat(sd.Skin_Transform);
                                    const bone_bind = nif_transform_to_mat(bt);

                                    var bone_bind_inv: [16]f32 = undefined;
                                    if (!transform.cardinal_matrix_invert(&bone_bind, &bone_bind_inv)) {
                                        bone_bind_inv = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
                                    }

                                    transform.cardinal_matrix_multiply(&bone_bind_inv, &skin_bind, &bone.inverse_bind_matrix);

                                    // Current Matrix (Identity)
                                    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
                                    @memcpy(&bone.current_matrix, &identity);

                                    bones_arr[k] = bone;
                                }
                                new_skin.bones = bones_arr.ptr;
                            }
                        }
                    }
                }

                skins.append(std.heap.c_allocator, new_skin) catch return false;
            }
        }
    }

    if (skins.items.len > 0) {
        out_scene.skin_count = @intCast(skins.items.len);
        const scene_skins_ptr = memory.cardinal_alloc(assets_allocator, out_scene.skin_count * @sizeOf(animation.CardinalSkin)) orelse return false;
        const scene_skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(scene_skins_ptr)))[0..out_scene.skin_count];
        @memcpy(scene_skins, skins.items);
        out_scene.skins = @ptrCast(scene_skins.ptr);
        nif_log.info("Added {d} skins to scene", .{out_scene.skin_count});

        // Create Animation System and populate it
        // This is required for the Model Manager to correctly merge skins into the Combined Scene
        const anim_sys_ptr = animation.cardinal_animation_system_create(0, out_scene.skin_count);
        if (anim_sys_ptr) |sys| {
            for (skins.items) |*skin| {
                _ = animation.cardinal_animation_system_add_skin(sys, skin);
            }
            out_scene.animation_system = @ptrCast(sys);
            nif_log.info("Created Animation System with {d} skins", .{sys.skin_count});
        }

        // Fixup Nodes: Set skin_index
        var n_idx: usize = 0;
        while (n_idx < nodes.items.len) : (n_idx += 1) {
            if (nodes.items[n_idx]) |node| {
                if (node.mesh_count > 0) {
                    if (node.mesh_indices) |indices| {
                        const m_idx = indices[0];
                        var s_idx: usize = 0;
                        while (s_idx < skins.items.len) : (s_idx += 1) {
                            const skin = &skins.items[s_idx];
                            var found = false;
                            var k: usize = 0;
                            while (k < skin.mesh_count) : (k += 1) {
                                if (skin.mesh_indices) |s_indices| {
                                    if (s_indices[k] == m_idx) {
                                        found = true;
                                        break;
                                    }
                                }
                            }
                            if (found) {
                                node.skin_index = @intCast(s_idx);
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    return true;
}
