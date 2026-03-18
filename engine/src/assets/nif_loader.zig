//! NIF/KF loader for Gamebryo assets.
//!
//! This module parses NIF scenes into `scene.CardinalScene` and can merge KF animation data into
//! an existing scene's animation system.
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
const nif_paths = @import("nif_paths.zig");

/// Resolves a schema string reference to a borrowed slice.
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

/// Promotes common UNORM color formats to their SRGB counterparts.
fn promote_color_format_to_srgb(format: u32) u32 {
    if (format == VK_FORMAT_R8G8B8A8_UNORM) return VK_FORMAT_R8G8B8A8_SRGB;
    if (format == VK_FORMAT_B8G8R8A8_UNORM) return VK_FORMAT_B8G8R8A8_SRGB;
    return format;
}

/// Parsed header data starting at `num_block_types`.
const ParsedHeaderTail = struct {
    user_version_2: u32,
    num_block_types: u16,
    block_types: [][]u8,
    block_type_indices: []u16,
    block_sizes: []u32,
    num_strings: u32,
    strings: [][]u8,
    groups: []u32,
};

/// Releases allocations owned by a partially-parsed header tail.
fn free_header_tail(allocator: std.mem.Allocator, tail: *ParsedHeaderTail) void {
    if (tail.block_types.len > 0) {
        for (tail.block_types) |s| {
            if (s.len > 0) allocator.free(s);
        }
        allocator.free(tail.block_types);
        tail.block_types = &.{};
    }
    if (tail.block_type_indices.len > 0) {
        allocator.free(tail.block_type_indices);
        tail.block_type_indices = &.{};
    }
    if (tail.block_sizes.len > 0) {
        allocator.free(tail.block_sizes);
        tail.block_sizes = &.{};
    }
    if (tail.strings.len > 0) {
        for (tail.strings) |s| {
            if (s.len > 0) allocator.free(s);
        }
        allocator.free(tail.strings);
        tail.strings = &.{};
    }
    if (tail.groups.len > 0) {
        allocator.free(tail.groups);
        tail.groups = &.{};
    }
}

/// Parses the post-version header region using the given layout flags.
fn parse_header_tail(self: *NifReader, include_user_version_2: bool, include_meta: bool) !ParsedHeaderTail {
    const allocator = self.allocator;
    const start_pos = self.pos;

    var tail: ParsedHeaderTail = .{
        .user_version_2 = 0,
        .num_block_types = 0,
        .block_types = &.{},
        .block_type_indices = &.{},
        .block_sizes = &.{},
        .num_strings = 0,
        .strings = &.{},
        .groups = &.{},
    };
    errdefer {
        free_header_tail(allocator, &tail);
        self.pos = start_pos;
    }

    if (include_user_version_2) {
        tail.user_version_2 = try self.read(u32);
    }

    if (include_meta) {
        _ = try self.read(u32);
    }

    tail.num_block_types = try self.read(u16);
    if (tail.num_block_types == 0 or tail.num_block_types > 4096) return error.InvalidHeader;

    tail.block_types = try allocator.alloc([]u8, tail.num_block_types);
    for (tail.block_types) |*s| s.* = &.{};

    var i: usize = 0;
    while (i < tail.num_block_types) : (i += 1) {
        tail.block_types[i] = try self.read_sized_string();
        if (tail.block_types[i].len == 0) return error.InvalidHeader;
    }

    tail.block_type_indices = try allocator.alloc(u16, self.header.num_blocks);
    i = 0;
    while (i < self.header.num_blocks) : (i += 1) {
        tail.block_type_indices[i] = try self.read(u16);
        if (tail.block_type_indices[i] >= tail.num_block_types) return error.InvalidHeader;
    }

    tail.block_sizes = try allocator.alloc(u32, self.header.num_blocks);
    i = 0;
    while (i < self.header.num_blocks) : (i += 1) {
        tail.block_sizes[i] = try self.read(u32);
        if (tail.block_sizes[i] > self.buffer.len) return error.InvalidHeader;
    }

    tail.num_strings = try self.read(u32);
    const max_str_len = try self.read(u32);
    const MAX_STR_LEN = 1024 * 4;
    if (max_str_len > MAX_STR_LEN) return error.InvalidHeader;
    if (tail.num_strings > 1_000_000) return error.InvalidHeader;

    tail.strings = try allocator.alloc([]u8, tail.num_strings);
    for (tail.strings) |*s| s.* = &.{};

    i = 0;
    while (i < tail.num_strings) : (i += 1) {
        const len = try self.read(u32);
        if (len > MAX_STR_LEN) return error.StringTooLong;
        if (self.pos + len > self.buffer.len) return error.EndOfBuffer;
        const slice = try allocator.dupe(u8, self.buffer[self.pos .. self.pos + len]);
        self.pos += len;
        tail.strings[i] = slice;
    }

    const num_groups = try self.read(u32);
    if (num_groups > 0) {
        if (num_groups > 1_000_000) return error.InvalidHeader;
        tail.groups = try allocator.alloc(u32, num_groups);
        i = 0;
        while (i < num_groups) : (i += 1) {
            tail.groups[i] = try self.read(u32);
        }
    } else {
        tail.groups = &.{};
    }

    const blocks_start = self.pos;
    var total_block_bytes: usize = 0;
    for (tail.block_sizes) |sz_u32| {
        total_block_bytes = std.math.add(usize, total_block_bytes, @as(usize, sz_u32)) catch return error.InvalidHeader;
    }
    const blocks_end = std.math.add(usize, blocks_start, total_block_bytes) catch return error.InvalidHeader;
    if (blocks_end > self.buffer.len) return error.InvalidHeader;

    return tail;
}

/// Normalizes bone weights and clamps out-of-range bone indices for a skinned mesh.
fn fixup_skinned_vertex_weights(mesh: *scene.CardinalMesh, max_bones: u16) void {
    if (mesh.vertices == null or mesh.vertex_count == 0) return;
    const verts = mesh.vertices.?;
    var i: u32 = 0;
    while (i < mesh.vertex_count) : (i += 1) {
        var w0 = verts[i].bone_weights[0];
        var w1 = verts[i].bone_weights[1];
        var w2 = verts[i].bone_weights[2];
        var w3 = verts[i].bone_weights[3];

        if (verts[i].bone_indices[0] >= max_bones) w0 = 0;
        if (verts[i].bone_indices[1] >= max_bones) w1 = 0;
        if (verts[i].bone_indices[2] >= max_bones) w2 = 0;
        if (verts[i].bone_indices[3] >= max_bones) w3 = 0;

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

/// Copies scene-node world transforms into any meshes referenced by the node subtree.
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

/// Converts a schema `NiTransform` to a column-major 4x4 matrix.
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
        self.pos = end + 1;
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

    /// Schema adapter for reading integer primitives.
    pub fn readInt(self: *NifReader, comptime T: type, endian: std.builtin.Endian) !T {
        _ = endian;
        return self.read(T);
    }

    /// Schema adapter for reading float primitives.
    pub fn readFloat(self: *NifReader, comptime T: type, endian: std.builtin.Endian) !T {
        _ = endian;
        return self.read(T);
    }

    /// Schema adapter for reading an exact number of bytes.
    pub fn readNoEof(self: *NifReader, buf: []u8) !void {
        if (self.pos + buf.len > self.buffer.len) return error.EndOfBuffer;
        @memcpy(buf, self.buffer[self.pos .. self.pos + buf.len]);
        self.pos += buf.len;
    }

    /// Parses the NIF header and block table.
    pub fn parse_header(self: *NifReader) !void {
        self.header.version_str = try self.read_string_lf();
        nif_log.warn("NIF Header: {s}", .{self.header.version_str});

        self.header.version = try self.read(u32);
        self.header.endian_type = try self.read(u8);
        self.header.user_version = try self.read(u32);
        self.header.num_blocks = try self.read(u32);

        if (self.header.version < 0x14000005) return error.UnsupportedVersion;

        const has_user_ver2 = self.header.version >= 0x14010003;
        const has_meta = self.header.version >= 0x14020008;

        const Variant = struct { user_ver2: bool, meta: bool };
        const variants: []const Variant = if (has_meta) blk: {
            if (has_user_ver2) break :blk &[_]Variant{
                .{ .user_ver2 = true, .meta = true },
                .{ .user_ver2 = false, .meta = true },
                .{ .user_ver2 = true, .meta = false },
                .{ .user_ver2 = false, .meta = false },
            };
            break :blk &[_]Variant{
                .{ .user_ver2 = false, .meta = true },
                .{ .user_ver2 = false, .meta = false },
            };
        } else if (has_user_ver2)
            &[_]Variant{
                .{ .user_ver2 = true, .meta = false },
                .{ .user_ver2 = false, .meta = false },
            }
        else
            &[_]Variant{
                .{ .user_ver2 = false, .meta = false },
            };

        const base_pos = self.pos;
        var last_err: anyerror = error.InvalidHeader;
        for (variants) |v| {
            self.pos = base_pos;
            const tail = parse_header_tail(self, v.user_ver2, v.meta) catch |err| {
                last_err = err;
                continue;
            };

            self.header.user_version_2 = tail.user_version_2;
            self.header.num_block_types = tail.num_block_types;
            self.header.block_types = tail.block_types;
            self.header.block_type_indices = tail.block_type_indices;
            self.header.block_sizes = tail.block_sizes;
            self.header.num_strings = tail.num_strings;
            self.header.strings = tail.strings;
            self.header.groups = tail.groups;
            return;
        }

        return last_err;
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

            const end_pos = block.data_offset + block.size;
            defer self.pos = end_pos;
            if (end_pos > self.buffer.len) {
                nif_log.err("Block {d} ({s}) exceeds file bounds: end={d} len={d}", .{ i, type_name, end_pos, self.buffer.len });
                return error.InvalidHeader;
            }

            if (nif_schema.blockTypeFromString(type_name)) |block_type| {
                const schema_header = nif_schema.Header{
                    .version = self.header.version,
                    .user_version = self.header.user_version,
                    .user_version_2 = self.header.user_version_2,
                };
                nif_log.warn("Parsing block {d}: {s} (Size: {d})", .{ i, type_name, block.size });
                if (block_type == .NiTransformData or block_type == .NiKeyframeData) {
                    continue;
                }
                const parsed = nif_schema.read_block(self.allocator, self, schema_header, block_type) catch |err| {
                    nif_log.err("Failed to parse block {d}: {s}: {s}", .{ i, type_name, @errorName(err) });
                    continue;
                };
                block.parsed = parsed;
            } else {
                nif_log.warn("Unknown block type: {s}", .{type_name});
            }
        }
    }
};

/// Finds the first property of the requested block tag from a property list.
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

/// Returns the highest vertex index referenced by a `NiSkinInstance`, or 0 when unknown.
fn getSkinMaxVertexIndex(reader: *NifReader, skin_inst_idx: usize) u32 {
    if (skin_inst_idx >= reader.blocks.len) return 0;
    const block = &reader.blocks[skin_inst_idx];
    if (block.parsed) |parsed| {
        if (std.meta.activeTag(parsed) == .NiSkinInstance) {
            const skin_inst = parsed.NiSkinInstance;

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

/// Counts `NiControllerSequence` blocks in a parsed KF/NIF buffer.
fn count_controller_sequences(reader: *const NifReader) usize {
    var seq_count: usize = 0;
    var i: usize = 0;
    while (i < reader.header.num_blocks) : (i += 1) {
        const block = &reader.blocks[i];
        if (block.parsed) |parsed| {
            if (std.meta.activeTag(parsed) == .NiControllerSequence) seq_count += 1;
        }
    }
    return seq_count;
}

/// Extracts the target node name from a controller sequence block.
fn resolve_controlled_block_node_name(cb: nif_schema.ControlledBlock, strings: [][]u8) []const u8 {
    if (cb.Node_Name) |n| {
        const s = getNifString(n, strings);
        if (s.len > 0) return s;
    }
    if (cb.Node_Name_1) |n| {
        const s = getNifString(n, strings);
        if (s.len > 0) return s;
    }
    if (cb.Target_Name) |t| {
        return @as([*]const u8, @ptrCast(t.Value.ptr))[0..t.Value.len];
    }
    return "";
}

/// Finds the index of a scene node by exact name match.
fn find_scene_node_index_by_name(scene_ptr: *const scene.CardinalScene, name: []const u8) ?u32 {
    if (name.len == 0) return null;
    if (scene_ptr.all_nodes == null or scene_ptr.all_node_count == 0) return null;

    const nodes = scene_ptr.all_nodes.?[0..@as(usize, @intCast(scene_ptr.all_node_count))];
    for (nodes, 0..) |node_opt, idx| {
        const n = node_opt orelse continue;
        const n_name_ptr = n.name orelse continue;
        const n_name = std.mem.span(n_name_ptr);
        if (std.mem.eql(u8, n_name, name)) return @intCast(idx);
    }
    return null;
}

/// Resolves the interpolator block index referenced by a controlled block.
fn resolve_interpolator_ref(reader: *const NifReader, cb: nif_schema.ControlledBlock) ?i32 {
    if (cb.Interpolator) |r| return r;
    if (cb.Controller) |c_ref| {
        if (c_ref < 0 or c_ref >= reader.header.num_blocks) return null;
        const block = &reader.blocks[@as(usize, @intCast(c_ref))];
        if (block.parsed) |parsed| {
            switch (std.meta.activeTag(parsed)) {
                .NiTransformController => {
                    const ctrl = parsed.NiTransformController;
                    return ctrl.base.base.Interpolator;
                },
                .NiKeyframeController => {
                    const ctrl = parsed.NiKeyframeController;
                    return ctrl.base.Interpolator;
                },
                .BSKeyframeController => {
                    const ctrl = parsed.BSKeyframeController;
                    return ctrl.base.base.Interpolator;
                },
                else => {},
            }
        }
    }
    return null;
}

/// Resolves a `NiTransformInterpolator` referenced by a controlled block.
fn resolve_transform_interpolator(reader: *const NifReader, cb: nif_schema.ControlledBlock) ?*nif_schema.NiTransformInterpolator {
    const ref = resolve_interpolator_ref(reader, cb) orelse return null;
    if (ref < 0 or ref >= reader.header.num_blocks) return null;
    const block = &reader.blocks[@as(usize, @intCast(ref))];
    if (block.parsed) |parsed| {
        if (std.meta.activeTag(parsed) == .NiTransformInterpolator) {
            return parsed.NiTransformInterpolator;
        }
    }
    return null;
}

fn resolve_transform_data_ref(reader: *const NifReader, cb: nif_schema.ControlledBlock) ?i32 {
    if (resolve_transform_interpolator(reader, cb)) |interp| {
        if (interp.Data >= 0) return interp.Data;
    }

    if (cb.Controller) |c_ref| {
        if (c_ref < 0 or c_ref >= reader.header.num_blocks) return null;
        const block = &reader.blocks[@as(usize, @intCast(c_ref))];
        if (block.parsed) |parsed| {
            switch (std.meta.activeTag(parsed)) {
                .NiTransformController => {
                    const ctrl = parsed.NiTransformController;
                    if (ctrl.base.Data) |d| if (d >= 0) return d;
                },
                .NiKeyframeController => {
                    const ctrl = parsed.NiKeyframeController;
                    if (ctrl.Data) |d| if (d >= 0) return d;
                },
                .BSKeyframeController => {
                    const ctrl = parsed.BSKeyframeController;
                    if (ctrl.base.Data) |d| if (d >= 0) return d;
                    if (ctrl.Data_2 >= 0) return ctrl.Data_2;
                },
                else => {},
            }
        }
    }

    return null;
}

const BlockReader = struct {
    buf: []const u8,
    pos: usize,
    end: usize,

    fn remaining(self: *const BlockReader) usize {
        if (self.pos >= self.end) return 0;
        return self.end - self.pos;
    }

    fn skip(self: *BlockReader, n: usize) !void {
        if (n > self.remaining()) return error.EndOfBuffer;
        self.pos += n;
    }

    fn readInt(self: *BlockReader, comptime T: type) !T {
        const size = @sizeOf(T);
        if (size > self.remaining()) return error.EndOfBuffer;
        const bytes: *const [size]u8 = @ptrCast(self.buf[self.pos .. self.pos + size].ptr);
        const v = std.mem.readInt(T, bytes, .little);
        self.pos += size;
        return v;
    }

    fn readF32(self: *BlockReader) !f32 {
        const bits = try self.readInt(u32);
        return @bitCast(bits);
    }
};

fn interpolation_from_key_type(key_type: u32) animation.CardinalAnimationInterpolation {
    _ = key_type;
    return .LINEAR;
}

fn key_type_kind(raw: u32) enum { linear, quadratic, tbc } {
    return switch (raw) {
        2 => .quadratic,
        3 => .tbc,
        else => .linear,
    };
}

fn skip_key_extras(br: *BlockReader, key_type_raw: u32, value_components: u32) !void {
    const fsz = @sizeOf(f32);
    switch (key_type_kind(key_type_raw)) {
        .linear => {},
        .quadratic => try br.skip(@as(usize, value_components) * 2 * fsz),
        .tbc => try br.skip(3 * fsz),
    }
}

fn read_key_group_header(br: *BlockReader) !struct { count: u32, key_type: u32 } {
    const count = try br.readInt(u32);
    if (count == 0) return .{ .count = 0, .key_type = 1 };
    const key_type = try br.readInt(u32);
    return .{ .count = count, .key_type = key_type };
}

fn sort_f32_in_place(values: []f32) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const key = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = key;
    }
}

fn unique_sorted_f32_in_place(values: []f32) []f32 {
    if (values.len == 0) return values;
    var out: usize = 1;
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        if (values[i] != values[out - 1]) {
            values[out] = values[i];
            out += 1;
        }
    }
    return values[0..out];
}

fn sample_curve(times: []const f32, values: []const f32, t: f32) f32 {
    if (times.len == 0) return 0;
    if (t <= times[0]) return values[0];
    const last = times.len - 1;
    if (t >= times[last]) return values[last];
    var i: usize = 1;
    while (i < times.len) : (i += 1) {
        if (t <= times[i]) {
            const t0 = times[i - 1];
            const t1 = times[i];
            const v0 = values[i - 1];
            const v1 = values[i];
            const denom = t1 - t0;
            if (denom == 0) return v1;
            const alpha = (t - t0) / denom;
            return math.lerp(v0, v1, alpha);
        }
    }
    return values[last];
}

fn fill_constant_sampler_vec3(assets_allocator: *memory.CardinalAllocator, sampler: *animation.CardinalAnimationSampler, v: [3]f32) bool {
    sampler.input_count = 1;
    sampler.output_count = 3;
    sampler.interpolation = .LINEAR;
    sampler.last_index = 0;
    const in_ptr = memory.cardinal_calloc(assets_allocator, 1, @sizeOf(f32)) orelse return false;
    const out_ptr = memory.cardinal_calloc(assets_allocator, 3, @sizeOf(f32)) orelse {
        memory.cardinal_free(assets_allocator, in_ptr);
        return false;
    };
    sampler.input = @ptrCast(@alignCast(in_ptr));
    sampler.output = @ptrCast(@alignCast(out_ptr));
    sampler.input.?[0] = 0.0;
    sampler.output.?[0] = v[0];
    sampler.output.?[1] = v[1];
    sampler.output.?[2] = v[2];
    return true;
}

fn fill_constant_sampler_quat(assets_allocator: *memory.CardinalAllocator, sampler: *animation.CardinalAnimationSampler, q: [4]f32) bool {
    sampler.input_count = 1;
    sampler.output_count = 4;
    sampler.interpolation = .LINEAR;
    sampler.last_index = 0;
    const in_ptr = memory.cardinal_calloc(assets_allocator, 1, @sizeOf(f32)) orelse return false;
    const out_ptr = memory.cardinal_calloc(assets_allocator, 4, @sizeOf(f32)) orelse {
        memory.cardinal_free(assets_allocator, in_ptr);
        return false;
    };
    sampler.input = @ptrCast(@alignCast(in_ptr));
    sampler.output = @ptrCast(@alignCast(out_ptr));
    sampler.input.?[0] = 0.0;
    sampler.output.?[0] = q[0];
    sampler.output.?[1] = q[1];
    sampler.output.?[2] = q[2];
    sampler.output.?[3] = q[3];
    return true;
}

fn fill_constant_sampler_scale(assets_allocator: *memory.CardinalAllocator, sampler: *animation.CardinalAnimationSampler, scale_val: f32) bool {
    return fill_constant_sampler_vec3(assets_allocator, sampler, .{ scale_val, scale_val, scale_val });
}

fn try_fill_samplers_from_transform_data(
    assets_allocator: *memory.CardinalAllocator,
    reader: *const NifReader,
    data_ref: i32,
    start_time: f32,
    t_sampler: *animation.CardinalAnimationSampler,
    r_sampler: *animation.CardinalAnimationSampler,
    s_sampler: *animation.CardinalAnimationSampler,
) bool {
    var success = false;
    defer {
        if (!success) {
            if (t_sampler.input) |p| memory.cardinal_free(assets_allocator, p);
            if (t_sampler.output) |p| memory.cardinal_free(assets_allocator, p);
            if (r_sampler.input) |p| memory.cardinal_free(assets_allocator, p);
            if (r_sampler.output) |p| memory.cardinal_free(assets_allocator, p);
            if (s_sampler.input) |p| memory.cardinal_free(assets_allocator, p);
            if (s_sampler.output) |p| memory.cardinal_free(assets_allocator, p);

            t_sampler.* = std.mem.zeroes(animation.CardinalAnimationSampler);
            r_sampler.* = std.mem.zeroes(animation.CardinalAnimationSampler);
            s_sampler.* = std.mem.zeroes(animation.CardinalAnimationSampler);
        }
    }

    if (data_ref < 0 or data_ref >= reader.header.num_blocks) return false;
    const block = &reader.blocks[@as(usize, @intCast(data_ref))];
    const end_pos = block.data_offset + block.size;
    if (end_pos > reader.buffer.len) return false;

    var br: BlockReader = .{
        .buf = reader.buffer,
        .pos = block.data_offset,
        .end = end_pos,
    };

    const rot_key_count = br.readInt(u32) catch return false;
    var rot_key_type: u32 = @intFromEnum(nif_schema.KeyType.LINEAR_KEY);
    var rot_is_xyz = false;
    if (rot_key_count > 0) {
        rot_key_type = br.readInt(u32) catch return false;
        rot_is_xyz = rot_key_type == 4;
    }

    var rot_times: ?[*]f32 = null;
    var rot_out: ?[*]f32 = null;
    var rot_count: u32 = 0;
    var rot_interp: animation.CardinalAnimationInterpolation = .LINEAR;

    if (rot_key_count > 0 and !rot_is_xyz) {
        rot_count = rot_key_count;
        rot_interp = interpolation_from_key_type(rot_key_type);
        const in_ptr = memory.cardinal_alloc(assets_allocator, @as(usize, rot_count) * @sizeOf(f32)) orelse return false;
        const out_ptr = memory.cardinal_alloc(assets_allocator, @as(usize, rot_count) * 4 * @sizeOf(f32)) orelse {
            memory.cardinal_free(assets_allocator, in_ptr);
            return false;
        };
        rot_times = @ptrCast(@alignCast(in_ptr));
        rot_out = @ptrCast(@alignCast(out_ptr));
        r_sampler.input = rot_times;
        r_sampler.output = rot_out;

        var i: u32 = 0;
        while (i < rot_count) : (i += 1) {
            const time = br.readF32() catch return false;
            const w = br.readF32() catch return false;
            const x = br.readF32() catch return false;
            const y = br.readF32() catch return false;
            const z = br.readF32() catch return false;
            const out_base: usize = @as(usize, i) * 4;
            rot_times.?[i] = time - start_time;
            var q: [4]f32 = .{ x, y, z, w };
            if (!std.math.isFinite(q[0]) or !std.math.isFinite(q[1]) or !std.math.isFinite(q[2]) or !std.math.isFinite(q[3])) return false;
            transform.cardinal_quaternion_normalize(&q);
            rot_out.?[out_base + 0] = q[0];
            rot_out.?[out_base + 1] = q[1];
            rot_out.?[out_base + 2] = q[2];
            rot_out.?[out_base + 3] = q[3];
            skip_key_extras(&br, rot_key_type, 4) catch return false;
        }
    } else if (rot_key_count > 0 and rot_is_xyz) {
        if (reader.header.version < 0x0A010000) {
            _ = br.readF32() catch return false;
        }
        var axis_times: [3]?[]f32 = .{ null, null, null };
        var axis_vals: [3]?[]f32 = .{ null, null, null };
        var axis_counts: [3]u32 = .{ 0, 0, 0 };
        var axis_key_type: [3]u32 = .{
            1,
            1,
            1,
        };

        var axis: u32 = 0;
        while (axis < 3) : (axis += 1) {
            const hdr = read_key_group_header(&br) catch return false;
            axis_counts[axis] = hdr.count;
            axis_key_type[axis] = hdr.key_type;
            if (hdr.count == 0) continue;

            const t_ptr = memory.cardinal_alloc(assets_allocator, @as(usize, hdr.count) * @sizeOf(f32)) orelse return false;
            const v_ptr = memory.cardinal_alloc(assets_allocator, @as(usize, hdr.count) * @sizeOf(f32)) orelse {
                memory.cardinal_free(assets_allocator, t_ptr);
                return false;
            };
            axis_times[axis] = @as([*]f32, @ptrCast(@alignCast(t_ptr)))[0..hdr.count];
            axis_vals[axis] = @as([*]f32, @ptrCast(@alignCast(v_ptr)))[0..hdr.count];

            var k: u32 = 0;
            while (k < hdr.count) : (k += 1) {
                const time = br.readF32() catch return false;
                const val = br.readF32() catch return false;
                if (!std.math.isFinite(val)) return false;
                if (@abs(val) > 1000.0) return false;
                axis_times[axis].?[k] = time - start_time;
                axis_vals[axis].?[k] = val;
                skip_key_extras(&br, hdr.key_type, 1) catch return false;
            }
        }

        const merged_len: usize = @as(usize, axis_counts[0] + axis_counts[1] + axis_counts[2]);
        if (merged_len > 0) {
            const times_ptr = memory.cardinal_alloc(assets_allocator, merged_len * @sizeOf(f32)) orelse return false;
            var merged = @as([*]f32, @ptrCast(@alignCast(times_ptr)))[0..merged_len];
            var cursor: usize = 0;
            var a: usize = 0;
            while (a < 3) : (a += 1) {
                if (axis_times[a]) |ts| {
                    @memcpy(merged[cursor .. cursor + ts.len], ts);
                    cursor += ts.len;
                }
            }
            merged = merged[0..cursor];
            sort_f32_in_place(merged);
            const unique = unique_sorted_f32_in_place(merged);

            rot_count = @intCast(unique.len);
            rot_interp = .LINEAR;
            rot_times = @ptrCast(@alignCast(times_ptr));
            const out_ptr = memory.cardinal_alloc(assets_allocator, @as(usize, rot_count) * 4 * @sizeOf(f32)) orelse {
                memory.cardinal_free(assets_allocator, times_ptr);
                return false;
            };
            rot_out = @ptrCast(@alignCast(out_ptr));
            r_sampler.input = rot_times;
            r_sampler.output = rot_out;

            const axis_x = math.Vec3{ .x = 1, .y = 0, .z = 0 };
            const axis_y = math.Vec3{ .x = 0, .y = 1, .z = 0 };
            const axis_z = math.Vec3{ .x = 0, .y = 0, .z = 1 };

            var idx: usize = 0;
            while (idx < unique.len) : (idx += 1) {
                const t = unique[idx];
                const x = if (axis_times[0] != null) sample_curve(axis_times[0].?, axis_vals[0].?, t) else 0;
                const y = if (axis_times[1] != null) sample_curve(axis_times[1].?, axis_vals[1].?, t) else 0;
                const z = if (axis_times[2] != null) sample_curve(axis_times[2].?, axis_vals[2].?, t) else 0;

                const qx = math.Quat.fromAxisAngle(axis_x, x);
                const qy = math.Quat.fromAxisAngle(axis_y, y);
                const qz = math.Quat.fromAxisAngle(axis_z, z);
                const q = qz.mul(qy).mul(qx).normalize();

                const base: usize = idx * 4;
                rot_out.?[base + 0] = q.x;
                rot_out.?[base + 1] = q.y;
                rot_out.?[base + 2] = q.z;
                rot_out.?[base + 3] = q.w;
            }

            var free_axis: usize = 0;
            while (free_axis < 3) : (free_axis += 1) {
                if (axis_times[free_axis]) |ts| memory.cardinal_free(assets_allocator, @ptrCast(ts.ptr));
                if (axis_vals[free_axis]) |vs| memory.cardinal_free(assets_allocator, @ptrCast(vs.ptr));
            }
        }
    }

    const trans_hdr = read_key_group_header(&br) catch return false;
    var trans_times: ?[*]f32 = null;
    var trans_out: ?[*]f32 = null;
    var trans_count: u32 = 0;
    var trans_interp: animation.CardinalAnimationInterpolation = .LINEAR;
    if (trans_hdr.count > 0) {
        trans_count = trans_hdr.count;
        trans_interp = interpolation_from_key_type(trans_hdr.key_type);
        const in_ptr = memory.cardinal_alloc(assets_allocator, @as(usize, trans_count) * @sizeOf(f32)) orelse return false;
        const out_ptr = memory.cardinal_alloc(assets_allocator, @as(usize, trans_count) * 3 * @sizeOf(f32)) orelse {
            memory.cardinal_free(assets_allocator, in_ptr);
            return false;
        };
        trans_times = @ptrCast(@alignCast(in_ptr));
        trans_out = @ptrCast(@alignCast(out_ptr));
        t_sampler.input = trans_times;
        t_sampler.output = trans_out;

        var i: u32 = 0;
        while (i < trans_count) : (i += 1) {
            const time = br.readF32() catch return false;
            const x = br.readF32() catch return false;
            const y = br.readF32() catch return false;
            const z = br.readF32() catch return false;
            if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(z)) return false;
            if (@abs(x) > 10000.0 or @abs(y) > 10000.0 or @abs(z) > 10000.0) return false;
            const base: usize = @as(usize, i) * 3;
            trans_times.?[i] = time - start_time;
            trans_out.?[base + 0] = x;
            trans_out.?[base + 1] = y;
            trans_out.?[base + 2] = z;
            skip_key_extras(&br, trans_hdr.key_type, 3) catch return false;
        }
    }

    const scale_hdr = read_key_group_header(&br) catch return false;
    var scale_times: ?[*]f32 = null;
    var scale_out: ?[*]f32 = null;
    var scale_count: u32 = 0;
    var scale_interp: animation.CardinalAnimationInterpolation = .LINEAR;
    if (scale_hdr.count > 0) {
        scale_count = scale_hdr.count;
        scale_interp = interpolation_from_key_type(scale_hdr.key_type);
        const in_ptr = memory.cardinal_alloc(assets_allocator, @as(usize, scale_count) * @sizeOf(f32)) orelse return false;
        const out_ptr = memory.cardinal_alloc(assets_allocator, @as(usize, scale_count) * 3 * @sizeOf(f32)) orelse {
            memory.cardinal_free(assets_allocator, in_ptr);
            return false;
        };
        scale_times = @ptrCast(@alignCast(in_ptr));
        scale_out = @ptrCast(@alignCast(out_ptr));
        s_sampler.input = scale_times;
        s_sampler.output = scale_out;

        var i: u32 = 0;
        while (i < scale_count) : (i += 1) {
            const time = br.readF32() catch return false;
            const val = br.readF32() catch return false;
            if (!std.math.isFinite(val)) return false;
            if (val <= 0.0 or val > 10000.0) return false;
            const base: usize = @as(usize, i) * 3;
            scale_times.?[i] = time - start_time;
            scale_out.?[base + 0] = val;
            scale_out.?[base + 1] = val;
            scale_out.?[base + 2] = val;
            skip_key_extras(&br, scale_hdr.key_type, 1) catch return false;
        }
    }

    if (br.pos != br.end) return false;

    if (trans_count > 0) {
        t_sampler.input = trans_times;
        t_sampler.output = trans_out;
        t_sampler.input_count = trans_count;
        t_sampler.output_count = trans_count * 3;
        t_sampler.interpolation = trans_interp;
        t_sampler.last_index = 0;
    }
    if (rot_count > 0) {
        r_sampler.input = rot_times;
        r_sampler.output = rot_out;
        r_sampler.input_count = rot_count;
        r_sampler.output_count = rot_count * 4;
        r_sampler.interpolation = rot_interp;
        r_sampler.last_index = 0;
    }
    if (scale_count > 0) {
        s_sampler.input = scale_times;
        s_sampler.output = scale_out;
        s_sampler.input_count = scale_count;
        s_sampler.output_count = scale_count * 3;
        s_sampler.interpolation = scale_interp;
        s_sampler.last_index = 0;
    }

    success = true;
    return trans_count > 0 or rot_count > 0 or scale_count > 0;
}

/// Ensures `out_scene.animation_system` is initialized for KF merge.
fn ensure_animation_system_for_kf_merge(out_scene: *scene.CardinalScene, seq_count: usize) ?*animation.CardinalAnimationSystem {
    const desired_anims: u32 = @intCast(seq_count + 10);
    const desired_skins: u32 = if (out_scene.skin_count > 0) out_scene.skin_count else 10;

    if (out_scene.animation_system) |anim_sys_opaque| {
        const sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(anim_sys_opaque)));
        if (sys.animations != null) return sys;
        animation.cardinal_animation_system_destroy(sys);
        out_scene.animation_system = null;
    }

    out_scene.animation_system = @ptrCast(animation.cardinal_animation_system_create(desired_anims, desired_skins));
    if (out_scene.animation_system == null) return null;

    const sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(out_scene.animation_system.?)));
    if (out_scene.skins != null and out_scene.skin_count > 0) {
        const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(out_scene.skins.?)))[0..@as(usize, @intCast(out_scene.skin_count))];
        for (skins) |*skin| {
            _ = animation.cardinal_animation_system_add_skin(sys, skin);
        }
    }
    return sys;
}

fn add_controller_sequences_to_animation_system(
    reader: *const NifReader,
    out_scene: *scene.CardinalScene,
    anim_sys: *animation.CardinalAnimationSystem,
    assets_allocator: *memory.CardinalAllocator,
    assets_alloc: std.mem.Allocator,
) bool {
    var i: usize = 0;
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

                var anim_desc = std.mem.zeroes(animation.CardinalAnimation);

                const name_src = if (seq_name.len > 0) seq_name else "Unknown";
                const name_z = assets_alloc.dupeZ(u8, name_src) catch return false;
                defer assets_alloc.free(name_z);
                anim_desc.name = name_z.ptr;

                const start = seq.Start_Time orelse 0.0;
                const stop = seq.Stop_Time orelse 0.0;
                anim_desc.duration = stop - start;
                if (anim_desc.duration < 0) anim_desc.duration = 0;

                const blocks = seq.base.Controlled_Blocks;
                var usable: usize = 0;
                for (blocks) |cb| {
                    const node_name = resolve_controlled_block_node_name(cb, reader.header.strings);
                    const node_index = find_scene_node_index_by_name(out_scene, node_name) orelse continue;
                    _ = node_index;
                    if (resolve_transform_interpolator(reader, cb) != null) {
                        usable += 1;
                    }
                }

                const sampler_count: u32 = @intCast(usable * 3);
                const channel_count: u32 = @intCast(usable * 3);

                if (sampler_count > 0) {
                    const samplers_ptr = memory.cardinal_calloc(assets_allocator, sampler_count, @sizeOf(animation.CardinalAnimationSampler)) orelse return false;
                    const channels_ptr = memory.cardinal_calloc(assets_allocator, channel_count, @sizeOf(animation.CardinalAnimationChannel)) orelse {
                        memory.cardinal_free(assets_allocator, samplers_ptr);
                        return false;
                    };

                    anim_desc.samplers = @ptrCast(@alignCast(samplers_ptr));
                    anim_desc.sampler_count = sampler_count;
                    anim_desc.channels = @ptrCast(@alignCast(channels_ptr));
                    anim_desc.channel_count = channel_count;

                    errdefer {
                        if (anim_desc.samplers) |samplers| {
                            var s_idx: u32 = 0;
                            while (s_idx < anim_desc.sampler_count) : (s_idx += 1) {
                                if (samplers[s_idx].input) |p| memory.cardinal_free(assets_allocator, p);
                                if (samplers[s_idx].output) |p| memory.cardinal_free(assets_allocator, p);
                            }
                            memory.cardinal_free(assets_allocator, samplers);
                        }
                        if (anim_desc.channels) |chs| {
                            memory.cardinal_free(assets_allocator, chs);
                        }
                        anim_desc.samplers = null;
                        anim_desc.channels = null;
                        anim_desc.sampler_count = 0;
                        anim_desc.channel_count = 0;
                    }

                    var out_s: u32 = 0;
                    var out_c: u32 = 0;
                    for (blocks) |cb| {
                        const node_name = resolve_controlled_block_node_name(cb, reader.header.strings);
                        const node_index = find_scene_node_index_by_name(out_scene, node_name) orelse continue;
                        const interp = resolve_transform_interpolator(reader, cb) orelse continue;
                        const data_ref = resolve_transform_data_ref(reader, cb);

                        const t = interp.Transform.Translation;
                        const r = interp.Transform.Rotation;
                        const scale_val = interp.Transform.Scale;

                        const t_sampler = &anim_desc.samplers.?[out_s + 0];
                        const r_sampler = &anim_desc.samplers.?[out_s + 1];
                        const s_sampler = &anim_desc.samplers.?[out_s + 2];

                        var did_parse = false;
                        if (data_ref) |dr| {
                            did_parse = try_fill_samplers_from_transform_data(assets_allocator, reader, dr, start, t_sampler, r_sampler, s_sampler);
                        }

                        if (!did_parse or t_sampler.input_count == 0) {
                            if (!fill_constant_sampler_vec3(assets_allocator, t_sampler, .{ t.x, t.y, t.z })) return false;
                        }
                        if (!did_parse or r_sampler.input_count == 0) {
                            if (!fill_constant_sampler_quat(assets_allocator, r_sampler, .{ r.x, r.y, r.z, r.w })) return false;
                        }
                        if (!did_parse or s_sampler.input_count == 0) {
                            if (!fill_constant_sampler_scale(assets_allocator, s_sampler, scale_val)) return false;
                        }

                        {
                            const ch = &anim_desc.channels.?[out_c + 0];
                            ch.sampler_index = out_s + 0;
                            ch.target.node_index = node_index;
                            ch.target.path = .TRANSLATION;
                        }
                        {
                            const ch = &anim_desc.channels.?[out_c + 1];
                            ch.sampler_index = out_s + 1;
                            ch.target.node_index = node_index;
                            ch.target.path = .ROTATION;
                        }
                        {
                            const ch = &anim_desc.channels.?[out_c + 2];
                            ch.sampler_index = out_s + 2;
                            ch.target.node_index = node_index;
                            ch.target.path = .SCALE;
                        }

                        out_s += 3;
                        out_c += 3;
                    }
                }

                _ = animation.cardinal_animation_system_add_animation(anim_sys, &anim_desc);

                if (anim_desc.samplers) |samplers| {
                    var s_idx: u32 = 0;
                    while (s_idx < anim_desc.sampler_count) : (s_idx += 1) {
                        if (samplers[s_idx].input) |p| memory.cardinal_free(assets_allocator, p);
                        if (samplers[s_idx].output) |p| memory.cardinal_free(assets_allocator, p);
                    }
                    memory.cardinal_free(assets_allocator, samplers);
                    anim_desc.samplers = null;
                    anim_desc.sampler_count = 0;
                }

                if (anim_desc.channels) |chs| {
                    memory.cardinal_free(assets_allocator, chs);
                    anim_desc.channels = null;
                    anim_desc.channel_count = 0;
                }
            }
        }
    }
    return true;
}

fn count_transform_controllers(reader: *const NifReader) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < reader.header.num_blocks) : (i += 1) {
        const block = &reader.blocks[i];
        if (block.parsed) |parsed| {
            switch (std.meta.activeTag(parsed)) {
                .NiTransformController, .NiKeyframeController, .BSKeyframeController => count += 1,
                else => {},
            }
        }
    }
    return count;
}

fn add_embedded_controller_animation(
    reader: *const NifReader,
    out_scene: *scene.CardinalScene,
    anim_sys: *animation.CardinalAnimationSystem,
    assets_allocator: *memory.CardinalAllocator,
    assets_alloc: std.mem.Allocator,
) bool {
    if (out_scene.all_nodes == null or out_scene.all_node_count == 0) return true;

    const nodes = out_scene.all_nodes.?[0..@as(usize, @intCast(out_scene.all_node_count))];
    const restrict_to_bones = out_scene.skin_count > 0;
    const channels_per_target: u32 = if (restrict_to_bones) 1 else 3;

    var usable: usize = 0;
    var i: usize = 0;
    while (i < reader.header.num_blocks) : (i += 1) {
        const block = &reader.blocks[i];
        if (block.parsed) |parsed| {
            var controller_ref: ?i32 = null;
            switch (parsed) {
                .NiNode => |n| controller_ref = n.base.base.Controller,
                .NiTriShape => |s| controller_ref = s.base.base.base.base.Controller,
                else => {},
            }

            const start_ref = controller_ref orelse continue;
            if (start_ref < 0) continue;
            if (i >= nodes.len or nodes[i] == null) continue;
            if (restrict_to_bones and !nodes[i].?.is_bone) continue;

            var c_ref: i32 = start_ref;
            var guard: usize = 0;
            while (c_ref >= 0 and c_ref < reader.header.num_blocks and guard < 2048) : (guard += 1) {
                const c_block = &reader.blocks[@as(usize, @intCast(c_ref))];
                const c_parsed = c_block.parsed orelse break;

                switch (std.meta.activeTag(c_parsed)) {
                    .NiTransformController, .NiKeyframeController, .BSKeyframeController => {
                        usable += 1;
                        break;
                    },
                    else => {},
                }

                var next: i32 = -1;
                switch (c_parsed) {
                    .NiTransformController => |ctrl| next = ctrl.base.base.base.base.Next_Controller,
                    .NiKeyframeController => |ctrl| next = ctrl.base.base.base.Next_Controller,
                    .BSKeyframeController => |ctrl| next = ctrl.base.base.base.base.Next_Controller,
                    else => break,
                }
                if (next == c_ref) break;
                c_ref = next;
            }
        }
    }

    if (usable == 0) return true;

    var anim_desc = std.mem.zeroes(animation.CardinalAnimation);
    const name_z = assets_alloc.dupeZ(u8, "Embedded") catch return false;
    defer assets_alloc.free(name_z);
    anim_desc.name = name_z.ptr;

    const sampler_count: u32 = @intCast(usable * channels_per_target);
    const channel_count: u32 = @intCast(usable * channels_per_target);

    const samplers_ptr = memory.cardinal_calloc(assets_allocator, sampler_count, @sizeOf(animation.CardinalAnimationSampler)) orelse return false;
    const channels_ptr = memory.cardinal_calloc(assets_allocator, channel_count, @sizeOf(animation.CardinalAnimationChannel)) orelse {
        memory.cardinal_free(assets_allocator, samplers_ptr);
        return false;
    };

    anim_desc.samplers = @ptrCast(@alignCast(samplers_ptr));
    anim_desc.sampler_count = sampler_count;
    anim_desc.channels = @ptrCast(@alignCast(channels_ptr));
    anim_desc.channel_count = channel_count;

    errdefer {
        if (anim_desc.samplers) |samplers| {
            var s_idx: u32 = 0;
            while (s_idx < anim_desc.sampler_count) : (s_idx += 1) {
                if (samplers[s_idx].input) |p| memory.cardinal_free(assets_allocator, p);
                if (samplers[s_idx].output) |p| memory.cardinal_free(assets_allocator, p);
            }
            memory.cardinal_free(assets_allocator, samplers);
        }
        if (anim_desc.channels) |chs| {
            memory.cardinal_free(assets_allocator, chs);
        }
        anim_desc.samplers = null;
        anim_desc.channels = null;
        anim_desc.sampler_count = 0;
        anim_desc.channel_count = 0;
    }

    var out_s: u32 = 0;
    var out_c: u32 = 0;
    i = 0;
    while (i < reader.header.num_blocks) : (i += 1) {
        const block = &reader.blocks[i];
        const parsed = block.parsed orelse continue;

        var controller_ref: ?i32 = null;
        switch (parsed) {
            .NiNode => |n| controller_ref = n.base.base.Controller,
            .NiTriShape => |s| controller_ref = s.base.base.base.base.Controller,
            else => {},
        }

        const start_ref = controller_ref orelse continue;
        if (start_ref < 0) continue;
        if (i >= nodes.len or nodes[i] == null) continue;
        if (restrict_to_bones and !nodes[i].?.is_bone) continue;

        var chosen_ref: ?i32 = null;
        var c_ref: i32 = start_ref;
        var guard: usize = 0;
        while (c_ref >= 0 and c_ref < reader.header.num_blocks and guard < 2048) : (guard += 1) {
            const c_block = &reader.blocks[@as(usize, @intCast(c_ref))];
            const c_parsed = c_block.parsed orelse break;
            switch (std.meta.activeTag(c_parsed)) {
                .NiTransformController, .NiKeyframeController, .BSKeyframeController => {
                    chosen_ref = c_ref;
                    break;
                },
                else => {},
            }

            var next: i32 = -1;
            switch (c_parsed) {
                .NiTransformController => |ctrl| next = ctrl.base.base.base.base.Next_Controller,
                .NiKeyframeController => |ctrl| next = ctrl.base.base.base.Next_Controller,
                .BSKeyframeController => |ctrl| next = ctrl.base.base.base.base.Next_Controller,
                else => break,
            }
            if (next == c_ref) break;
            c_ref = next;
        }

        const picked = chosen_ref orelse continue;
        const ctrl_block = &reader.blocks[@as(usize, @intCast(picked))];
        const ctrl_parsed = ctrl_block.parsed orelse continue;

        var interp_ref: ?i32 = null;
        var data_ref: ?i32 = null;
        var start_time: f32 = 0.0;
        var t_const: [3]f32 = .{ 0, 0, 0 };
        var r_const: [4]f32 = .{ 0, 0, 0, 1 };
        var s_const: f32 = 1.0;

        switch (ctrl_parsed) {
            .NiTransformController => |ctrl| {
                const tc = ctrl.base.base.base.base;
                start_time = tc.Start_Time;
                interp_ref = ctrl.base.base.Interpolator;
                if (data_ref == null) {
                    if (ctrl.base.Data) |d| {
                        if (d >= 0) data_ref = d;
                    }
                }
            },
            .NiKeyframeController => |ctrl| {
                const tc = ctrl.base.base.base;
                start_time = tc.Start_Time;
                interp_ref = ctrl.base.Interpolator;
                if (data_ref == null) {
                    if (ctrl.Data) |d| {
                        if (d >= 0) data_ref = d;
                    }
                }
            },
            .BSKeyframeController => |ctrl| {
                const tc = ctrl.base.base.base.base;
                start_time = tc.Start_Time;
                interp_ref = ctrl.base.base.Interpolator;
                if (data_ref == null) {
                    if (ctrl.base.Data) |d| {
                        if (d >= 0) data_ref = d;
                    }
                    if (ctrl.Data_2 >= 0) data_ref = ctrl.Data_2;
                }
            },
            else => continue,
        }

        if (interp_ref) |r| {
            if (r >= 0 and r < reader.header.num_blocks) {
                const ib = &reader.blocks[@as(usize, @intCast(r))];
                if (ib.parsed) |ip| {
                    if (std.meta.activeTag(ip) == .NiTransformInterpolator) {
                        const interp = ip.NiTransformInterpolator;
                        const t = interp.Transform.Translation;
                        const q = interp.Transform.Rotation;
                        const sc = interp.Transform.Scale;
                        t_const = .{ t.x, t.y, t.z };
                        r_const = .{ q.x, q.y, q.z, q.w };
                        s_const = sc;
                        if (interp.Data >= 0) data_ref = interp.Data;
                    }
                }
            }
        }

        const node_index_u32: u32 = @intCast(i);
        const update_dur = struct {
            fn f(anim: *animation.CardinalAnimation, sampler: *const animation.CardinalAnimationSampler) void {
                if (sampler.input == null or sampler.input_count == 0) return;
                const last = sampler.input.?[sampler.input_count - 1];
                if (last > anim.duration) anim.duration = last;
            }
        }.f;

        if (restrict_to_bones) {
            const r_sampler = &anim_desc.samplers.?[out_s + 0];

            var tmp_t = std.mem.zeroes(animation.CardinalAnimationSampler);
            var tmp_s = std.mem.zeroes(animation.CardinalAnimationSampler);

            var did_parse = false;
            if (data_ref) |dr| {
                did_parse = try_fill_samplers_from_transform_data(assets_allocator, reader, dr, start_time, &tmp_t, r_sampler, &tmp_s);
            }

            if (tmp_t.input) |p| memory.cardinal_free(assets_allocator, p);
            if (tmp_t.output) |p| memory.cardinal_free(assets_allocator, p);
            if (tmp_s.input) |p| memory.cardinal_free(assets_allocator, p);
            if (tmp_s.output) |p| memory.cardinal_free(assets_allocator, p);

            if (!did_parse or r_sampler.input_count == 0) {
                if (!fill_constant_sampler_quat(assets_allocator, r_sampler, r_const)) return false;
            }

            update_dur(&anim_desc, r_sampler);

            const ch = &anim_desc.channels.?[out_c + 0];
            ch.sampler_index = out_s + 0;
            ch.target.node_index = node_index_u32;
            ch.target.path = .ROTATION;

            out_s += 1;
            out_c += 1;
        } else {
            const t_sampler = &anim_desc.samplers.?[out_s + 0];
            const r_sampler = &anim_desc.samplers.?[out_s + 1];
            const s_sampler = &anim_desc.samplers.?[out_s + 2];

            var did_parse = false;
            if (data_ref) |dr| {
                did_parse = try_fill_samplers_from_transform_data(assets_allocator, reader, dr, start_time, t_sampler, r_sampler, s_sampler);
            }

            if (!did_parse or t_sampler.input_count == 0) {
                if (!fill_constant_sampler_vec3(assets_allocator, t_sampler, t_const)) return false;
            }
            if (!did_parse or r_sampler.input_count == 0) {
                if (!fill_constant_sampler_quat(assets_allocator, r_sampler, r_const)) return false;
            }
            if (!did_parse or s_sampler.input_count == 0) {
                if (!fill_constant_sampler_scale(assets_allocator, s_sampler, s_const)) return false;
            }

            update_dur(&anim_desc, t_sampler);
            update_dur(&anim_desc, r_sampler);
            update_dur(&anim_desc, s_sampler);

            {
                const ch = &anim_desc.channels.?[out_c + 0];
                ch.sampler_index = out_s + 0;
                ch.target.node_index = node_index_u32;
                ch.target.path = .TRANSLATION;
            }
            {
                const ch = &anim_desc.channels.?[out_c + 1];
                ch.sampler_index = out_s + 1;
                ch.target.node_index = node_index_u32;
                ch.target.path = .ROTATION;
            }
            {
                const ch = &anim_desc.channels.?[out_c + 2];
                ch.sampler_index = out_s + 2;
                ch.target.node_index = node_index_u32;
                ch.target.path = .SCALE;
            }

            out_s += 3;
            out_c += 3;
        }

        if (out_s >= sampler_count or out_c >= channel_count) break;
    }

    anim_desc.sampler_count = out_s;
    anim_desc.channel_count = out_c;

    _ = animation.cardinal_animation_system_add_animation(anim_sys, &anim_desc);
    const targets = if (channels_per_target > 0) (out_c / channels_per_target) else 0;
    nif_log.warn("Imported embedded controllers: {d} targets, duration={d:.2}s", .{ targets, anim_desc.duration });

    if (anim_desc.samplers) |samplers| {
        var s_idx: u32 = 0;
        while (s_idx < sampler_count) : (s_idx += 1) {
            if (samplers[s_idx].input) |p| memory.cardinal_free(assets_allocator, p);
            if (samplers[s_idx].output) |p| memory.cardinal_free(assets_allocator, p);
        }
        memory.cardinal_free(assets_allocator, samplers);
        anim_desc.samplers = null;
    }
    if (anim_desc.channels) |chs| {
        memory.cardinal_free(assets_allocator, chs);
        anim_desc.channels = null;
    }
    return true;
}

/// Applies `NiAlphaProperty` state to a material, using `mat_alpha` as a fallback opacity hint.
fn apply_alpha_property(mat: *scene.CardinalMaterial, mat_alpha: f32, alpha_prop: *const nif_schema.NiAlphaProperty) void {
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
        mat.alpha_mode = if (mat_alpha < 0.99) .BLEND else .OPAQUE;
    } else {
        mat.alpha_mode = .OPAQUE;
    }
}

/// Applies `NiStencilProperty` culling hints to a material.
fn apply_stencil_property(mat: *scene.CardinalMaterial, stencil_prop: *const nif_schema.NiStencilProperty) void {
    const flags = stencil_prop.Flags orelse 0;
    const cull_mode = (flags >> 10) & 0x3;
    if (cull_mode == 0) mat.double_sided = true;
}

/// Parses a KF file and merges any controller sequences into `out_scene.animation_system`.
pub export fn cardinal_nif_merge_kf(path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool {
    const file_path = std.mem.span(path);
    nif_log.info("Merging KF: {s}", .{file_path});
    const assets_allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const assets_alloc = memory.cardinal_get_allocator_for_category(.ASSETS).as_allocator();

    var file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        nif_log.err("Failed to open KF file: {s} ({})", .{ file_path, err });
        return false;
    };
    defer file.close();

    const file_size = file.getEndPos() catch 0;
    const buffer = assets_alloc.alloc(u8, file_size) catch return false;
    defer assets_alloc.free(buffer);
    _ = file.readAll(buffer) catch return false;

    var reader = NifReader.init(assets_alloc, buffer);
    defer reader.deinit();

    reader.parse_header() catch |err| {
        nif_log.err("Failed to parse KF header: {}", .{err});
        return false;
    };

    reader.parse_blocks() catch |err| {
        nif_log.err("Failed to parse KF blocks: {}", .{err});
        return false;
    };

    const seq_count = count_controller_sequences(&reader);

    if (seq_count == 0) {
        nif_log.warn("No sequences found in KF.", .{});
        return true;
    }

    const anim_sys = ensure_animation_system_for_kf_merge(out_scene, seq_count) orelse return false;
    return add_controller_sequences_to_animation_system(&reader, out_scene, anim_sys, assets_allocator, assets_alloc);
}

/// Parses a NIF file and populates `out_scene` with meshes/materials/textures/nodes and skins.
pub export fn cardinal_nif_load_scene(path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool {
    @setEvalBranchQuota(100000);
    const file_path = std.mem.span(path);
    nif_log.info("Loading NIF: {s}", .{file_path});
    const assets_allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const assets_alloc = assets_allocator.as_allocator();
    out_scene.* = std.mem.zeroes(scene.CardinalScene);
    var success = false;
    errdefer if (!success) scene.cardinal_scene_destroy(out_scene);

    var file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        nif_log.err("Failed to open file: {s} ({})", .{ file_path, err });
        return false;
    };
    defer file.close();

    const file_size = file.getEndPos() catch 0;
    const buffer = assets_alloc.alloc(u8, file_size) catch return false;
    defer assets_alloc.free(buffer);
    _ = file.readAll(buffer) catch return false;

    var reader = NifReader.init(assets_alloc, buffer);
    defer reader.deinit();

    reader.parse_header() catch |err| {
        nif_log.err("Failed to parse header: {}", .{err});
        return false;
    };

    reader.parse_blocks() catch |err| {
        nif_log.err("Failed to parse blocks: {}", .{err});
        return false;
    };

    const seq_count = count_controller_sequences(&reader);
    const ctrl_count = count_transform_controllers(&reader);

    var nodes = std.ArrayListUnmanaged(?*scene.CardinalSceneNode){};
    defer nodes.deinit(assets_alloc);

    nodes.appendNTimes(assets_alloc, null, reader.header.num_blocks) catch return false;

    var meshes = std.ArrayListUnmanaged(scene.CardinalMesh){};
    defer meshes.deinit(assets_alloc);

    var mesh_skin_refs = std.ArrayListUnmanaged(?i32){};
    defer mesh_skin_refs.deinit(assets_alloc);

    var materials = std.ArrayListUnmanaged(scene.CardinalMaterial){};
    defer materials.deinit(assets_alloc);

    var textures = std.ArrayListUnmanaged(scene.CardinalTexture){};
    defer textures.deinit(assets_alloc);

    var texture_index_by_path = std.StringHashMapUnmanaged(u32){};
    defer texture_index_by_path.deinit(assets_alloc);

    var i: usize = 0;
    while (i < reader.header.num_blocks) : (i += 1) {
        const block = &reader.blocks[i];
        if (block.parsed) |parsed_data| {
            var is_node = false;
            var node_name_str: []const u8 = "";
            var translation: [3]f32 = .{ 0, 0, 0 };
            var rotation: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
            var scale: f32 = 1.0;
            var properties: ?[]i32 = null;

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
                defer if (s_z) |s| assets_alloc.free(s);

                if (node_name_str.len > 0) {
                    s_z = assets_alloc.dupeZ(u8, node_name_str) catch return false;
                } else {
                    s_z = assets_alloc.dupeZ(u8, "Node") catch return false;
                }

                const sn = scene.cardinal_scene_node_create(s_z.?) orelse return false;

                nodes.items[i] = sn;

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

                var mat_index: i32 = -1;

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
                    mat.roughness_factor = std.math.clamp(1.0 - (mat_prop.Glossiness / 100.0), 0.0, 1.0);
                    nif_log.info("Mesh 3 has MaterialProperty: Alpha={d}", .{mat_prop.Alpha});
                    if (mat_prop.Diffuse_Color) |dc| {
                        nif_log.info("  Diffuse({d},{d},{d})", .{ dc.r, dc.g, dc.b });
                    }
                    if (findProperty(&reader, properties, .NiAlphaProperty)) |alpha_prop| {
                        has_mat_prop = true;
                        apply_alpha_property(&mat, mat_prop.Alpha, alpha_prop);
                    }

                    if (findProperty(&reader, properties, .NiStencilProperty)) |stencil_prop| {
                        apply_stencil_property(&mat, stencil_prop);
                        if (mat.double_sided) nif_log.info("Mesh {d} is Double Sided (Stencil Cull Mode 0)", .{i});
                    }

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
                                                raw_path = nif_paths.resolveFilePath(reader.header.strings, source.File_Name);
                                            } else if (source.File_Name_1 != null) {
                                                raw_path = nif_paths.resolveFilePath(reader.header.strings, source.File_Name_1);
                                            }

                                            if (raw_path) |p| {
                                                const norm_path = nif_paths.resolve_texture_path(assets_alloc, file_path, p);
                                                if (norm_path) |np| {
                                                    var tex = std.mem.zeroes(scene.CardinalTexture);
                                                    tex.path = @ptrCast(np.ptr);

                                                    var path_owned = true;
                                                    defer if (path_owned) assets_allocator.as_allocator().free(np);

                                                    if (texture_index_by_path.get(np)) |existing_idx| {
                                                        mat.albedo_texture = .{ .index = existing_idx, .generation = 0 };
                                                        const uv_set_raw: u32 = desc.UV_Set orelse 0;
                                                        mat.uv_indices[0] = @intCast(if (uv_set_raw > 1) 1 else uv_set_raw);
                                                    } else {
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

                                                        textures.append(assets_alloc, tex) catch return false;
                                                        path_owned = false;
                                                        const idx: u32 = @intCast(textures.items.len - 1);
                                                        texture_index_by_path.put(assets_alloc, np, idx) catch {};
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
                    }

                    if (has_mat_prop or has_tex_prop) {
                        materials.append(assets_alloc, mat) catch return false;
                        mat_index = @as(i32, @intCast(materials.items.len - 1));
                    }

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
                                        mesh.visible = true;

                                        if (mat_index >= 0) {
                                            mesh.material_index = @as(u32, @intCast(mat_index));
                                        }

                                        if (data.base.base.Vertices) |verts| {
                                            nif_log.debug("NiTriShapeData: Has {d} vertices", .{verts.len});
                                            mesh.vertex_count = @intCast(verts.len);
                                            const c_verts_ptr = memory.cardinal_alloc(assets_allocator, mesh.vertex_count * @sizeOf(scene.CardinalVertex)) orelse return false;
                                            const c_verts = @as([*]scene.CardinalVertex, @ptrCast(@alignCast(c_verts_ptr)))[0..mesh.vertex_count];

                                            var min_pt = @import("../core/math.zig").Vec3{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32), .z = std.math.floatMax(f32) };
                                            var max_pt = @import("../core/math.zig").Vec3{ .x = -std.math.floatMax(f32), .y = -std.math.floatMax(f32), .z = -std.math.floatMax(f32) };

                                            for (c_verts, 0..) |*v, v_idx| {
                                                v.* = std.mem.zeroes(scene.CardinalVertex);
                                                v.px = verts[v_idx].x;
                                                v.py = verts[v_idx].y;
                                                v.pz = verts[v_idx].z;
                                                v.color = .{ 1, 1, 1, 1 };

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

                                            if (data.base.base.Normals) |norms| {
                                                for (c_verts, 0..) |*v, v_idx| {
                                                    if (v_idx < norms.len) {
                                                        v.nx = norms[v_idx].x;
                                                        v.ny = norms[v_idx].y;
                                                        v.nz = norms[v_idx].z;
                                                    }
                                                }
                                            }

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
                                                            materials.append(assets_alloc, m2) catch return false;
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

                                        var skin_inst_ref_final: ?i32 = shape.base.base.Skin_Instance;
                                        if (skin_inst_ref_final) |si| {
                                            if (si < 0) skin_inst_ref_final = null;
                                        }

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

                                        if (mesh.index_count == 0 and skin_inst_ref_final == null) {
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
                                                                                                    const part_bone = bones[local_bone_idx];
                                                                                                    var bone_list_index: ?u16 = null;
                                                                                                    if (part_bone < skin_inst.Bones.len) {
                                                                                                        bone_list_index = part_bone;
                                                                                                    } else {
                                                                                                        var bi: usize = 0;
                                                                                                        while (bi < skin_inst.Bones.len) : (bi += 1) {
                                                                                                            const bref = skin_inst.Bones[bi];
                                                                                                            if (bref >= 0 and @as(u16, @intCast(bref)) == part_bone) {
                                                                                                                bone_list_index = @intCast(bi);
                                                                                                                break;
                                                                                                            }
                                                                                                        }
                                                                                                    }
                                                                                                    if (bone_list_index == null) continue;
                                                                                                    verts[orig_idx].bone_weights[slot] = w;
                                                                                                    verts[orig_idx].bone_indices[slot] = @intCast(bone_list_index.?);
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
                                            var max_bones: u16 = 256;
                                            if (skin_inst_ref_final) |skin_inst_ref| {
                                                if (skin_inst_ref >= 0 and skin_inst_ref < reader.header.num_blocks) {
                                                    const skin_inst_block = &reader.blocks[@as(usize, @intCast(skin_inst_ref))];
                                                    if (skin_inst_block.parsed) |skin_inst_parsed| {
                                                        if (std.meta.activeTag(skin_inst_parsed) == .NiSkinInstance) {
                                                            const skin_inst = skin_inst_parsed.NiSkinInstance;
                                                            max_bones = @intCast(@min(@as(usize, skin_inst.Bones.len), 256));
                                                            fixup_skinned_vertex_weights(&mesh, max_bones);
                                                        } else {
                                                            fixup_skinned_vertex_weights(&mesh, 256);
                                                        }
                                                    } else {
                                                        fixup_skinned_vertex_weights(&mesh, 256);
                                                    }
                                                } else {
                                                    fixup_skinned_vertex_weights(&mesh, 256);
                                                }
                                            }

                                            if (mesh.vertices != null and mesh.vertex_count > 0) {
                                                const verts = mesh.vertices.?;
                                                var influenced: u32 = 0;
                                                var fallback: u32 = 0;
                                                var max_joint: u16 = 0;
                                                var vi: u32 = 0;
                                                while (vi < mesh.vertex_count) : (vi += 1) {
                                                    var sum: f32 = 0;
                                                    var k: usize = 0;
                                                    while (k < 4) : (k += 1) {
                                                        const w = verts[vi].bone_weights[k];
                                                        if (w > 0.0) {
                                                            sum += w;
                                                            const j: u16 = @intCast(@min(verts[vi].bone_indices[k], std.math.maxInt(u16)));
                                                            if (j > max_joint) max_joint = j;
                                                        }
                                                    }
                                                    if (sum < 0.0001) fallback += 1 else influenced += 1;
                                                }
                                                nif_log.warn(
                                                    "Mesh {d} skin stats: v={d} influenced={d} fallback={d} maxJoint={d} maxBones={d}",
                                                    .{ meshes.items.len, mesh.vertex_count, influenced, fallback, max_joint, max_bones },
                                                );
                                            }
                                        }

                                        if (mesh.vertex_count > 0 and mesh.vertices != null) {
                                            const v0 = mesh.vertices.?[0];
                                            nif_log.info("Vertex 0 Weights: {d}, {d}, {d}, {d}", .{ v0.bone_weights[0], v0.bone_weights[1], v0.bone_weights[2], v0.bone_weights[3] });
                                            nif_log.info("Vertex 0 Joints: {d}, {d}, {d}, {d}", .{ v0.bone_indices[0], v0.bone_indices[1], v0.bone_indices[2], v0.bone_indices[3] });
                                        }

                                        nif_log.debug("About to append mesh with {d} vertices and {d} indices", .{ mesh.vertex_count, mesh.index_count });
                                        meshes.append(assets_alloc, mesh) catch return false;
                                        mesh_skin_refs.append(assets_alloc, skin_inst_ref_final) catch return false;
                                        nif_log.info("Added mesh {d} with {d} vertices and {d} indices", .{ meshes.items.len - 1, mesh.vertex_count, mesh.index_count });

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

        for (meshes.items, 0..) |*m, mesh_i| {
            if (m.indices == null or m.index_count < 3 or m.vertices == null or m.vertex_count == 0) continue;

            const t = m.transform;
            const m00 = t[0];
            const m01 = t[4];
            const m02 = t[8];
            const m10 = t[1];
            const m11 = t[5];
            const m12 = t[9];
            const m20 = t[2];
            const m21 = t[6];
            const m22 = t[10];

            const det = m00 * (m11 * m22 - m12 * m21) - m01 * (m10 * m22 - m12 * m20) + m02 * (m10 * m21 - m11 * m20);
            const indices = m.indices.?[0..@intCast(m.index_count)];
            const verts = m.vertices.?[0..@intCast(m.vertex_count)];

            if (det < 0.0) {
                var ii: usize = 0;
                while (ii + 2 < indices.len) : (ii += 3) {
                    const tmp = indices[ii + 1];
                    indices[ii + 1] = indices[ii + 2];
                    indices[ii + 2] = tmp;
                }

                for (verts) |*v| {
                    v.nx = -v.nx;
                    v.ny = -v.ny;
                    v.nz = -v.nz;
                }
            }

            var pos_count: u32 = 0;
            var neg_count: u32 = 0;
            const sample_tris: usize = @min(indices.len / 3, 512);
            var tri_i: usize = 0;
            while (tri_i < sample_tris) : (tri_i += 1) {
                const base = tri_i * 3;
                const ia = indices[base + 0];
                const ib = indices[base + 1];
                const ic = indices[base + 2];
                if (ia >= verts.len or ib >= verts.len or ic >= verts.len) continue;

                const a = verts[ia];
                const b = verts[ib];
                const vc = verts[ic];

                const abx = b.px - a.px;
                const aby = b.py - a.py;
                const abz = b.pz - a.pz;
                const acx = vc.px - a.px;
                const acy = vc.py - a.py;
                const acz = vc.pz - a.pz;

                const fnx = aby * acz - abz * acy;
                const fny = abz * acx - abx * acz;
                const fnz = abx * acy - aby * acx;

                const vnx = a.nx + b.nx + vc.nx;
                const vny = a.ny + b.ny + vc.ny;
                const vnz = a.nz + b.nz + vc.nz;

                const d = fnx * vnx + fny * vny + fnz * vnz;
                if (d < 0.0) {
                    neg_count += 1;
                } else {
                    pos_count += 1;
                }
            }

            if (pos_count + neg_count > 0) {
                const flip_all = neg_count > pos_count;
                if (flip_all) {
                    var ii: usize = 0;
                    while (ii + 2 < indices.len) : (ii += 3) {
                        const tmp = indices[ii + 1];
                        indices[ii + 1] = indices[ii + 2];
                        indices[ii + 2] = tmp;
                    }

                    for (verts) |*v| {
                        v.nx = -v.nx;
                        v.ny = -v.ny;
                        v.nz = -v.nz;
                    }
                } else {
                    var ii: usize = 0;
                    while (ii + 2 < indices.len) : (ii += 3) {
                        const ia = indices[ii + 0];
                        const ib = indices[ii + 1];
                        const ic = indices[ii + 2];
                        if (ia >= verts.len or ib >= verts.len or ic >= verts.len) continue;

                        const a = verts[ia];
                        const b = verts[ib];
                        const vc = verts[ic];

                        const abx = b.px - a.px;
                        const aby = b.py - a.py;
                        const abz = b.pz - a.pz;
                        const acx = vc.px - a.px;
                        const acy = vc.py - a.py;
                        const acz = vc.pz - a.pz;

                        const fnx = aby * acz - abz * acy;
                        const fny = abz * acx - abx * acz;
                        const fnz = abx * acy - aby * acx;

                        const vnx = a.nx + b.nx + vc.nx;
                        const vny = a.ny + b.ny + vc.ny;
                        const vnz = a.nz + b.nz + vc.nz;

                        const d = fnx * vnx + fny * vny + fnz * vnz;
                        if (d < 0.0) {
                            indices[ii + 1] = ic;
                            indices[ii + 2] = ib;
                        }
                    }
                }
            }

            if (m.vertex_count == 24 and m.index_count <= 36) {
                nif_log.warn("Mesh {d} small mesh topology: VCount={d} ICount={d} det={d:.3} dotNeg={d} dotPos={d}", .{ mesh_i, m.vertex_count, m.index_count, det, neg_count, pos_count });
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

    if (nodes.items.len > 0) {
        const all_nodes_ptr = memory.cardinal_alloc(assets_allocator, nodes.items.len * @sizeOf(?*scene.CardinalSceneNode)) orelse return false;
        const all_nodes = @as([*]?*scene.CardinalSceneNode, @ptrCast(@alignCast(all_nodes_ptr)))[0..nodes.items.len];
        @memcpy(all_nodes, nodes.items);
        out_scene.all_nodes = all_nodes.ptr;
        out_scene.all_node_count = @intCast(nodes.items.len);
        nif_log.info("Populated all_nodes with {d} entries", .{out_scene.all_node_count});
    }

    var skins = std.ArrayListUnmanaged(animation.CardinalSkin){};
    defer skins.deinit(assets_alloc);

    var b_idx: usize = 0;
    while (b_idx < reader.header.num_blocks) : (b_idx += 1) {
        const block = &reader.blocks[b_idx];
        if (block.parsed) |parsed| {
            if (std.meta.activeTag(parsed) == .NiSkinInstance) {
                const skin_inst = parsed.NiSkinInstance;
                var new_skin = std.mem.zeroes(animation.CardinalSkin);

                var name_buf: [64]u8 = undefined;
                const name_slice = std.fmt.bufPrint(&name_buf, "Skin_{d}", .{b_idx}) catch "Skin";
                const skin_name_ptr = memory.cardinal_alloc(assets_allocator, name_slice.len + 1) orelse return false;
                const skin_name = @as([*]u8, @ptrCast(@alignCast(skin_name_ptr)))[0 .. name_slice.len + 1];
                @memcpy(skin_name[0..name_slice.len], name_slice);
                skin_name[name_slice.len] = 0;
                new_skin.name = @ptrCast(skin_name.ptr);

                var skin_mesh_indices = std.ArrayListUnmanaged(u32){};
                defer skin_mesh_indices.deinit(assets_alloc);

                var m_idx: usize = 0;
                while (m_idx < mesh_skin_refs.items.len) : (m_idx += 1) {
                    if (mesh_skin_refs.items[m_idx]) |ref| {
                        if (ref == @as(i32, @intCast(b_idx))) {
                            skin_mesh_indices.append(assets_alloc, @intCast(m_idx)) catch continue;
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

                {
                    const desired_bone_count: usize = @min(@as(usize, skin_inst.Bones.len), 256);
                    new_skin.bone_count = @intCast(desired_bone_count);
                    if (desired_bone_count > 0) {
                        const bones_ptr = memory.cardinal_alloc(assets_allocator, desired_bone_count * @sizeOf(animation.CardinalBone)) orelse return false;
                        const bones_arr = @as([*]animation.CardinalBone, @ptrCast(@alignCast(bones_ptr)))[0..desired_bone_count];

                        var skin_bind: ?[16]f32 = null;
                        var bone_list: ?[]const nif_schema.BoneData = null;
                        if (skin_inst.Data >= 0 and skin_inst.Data < reader.header.num_blocks) {
                            const data_block = &reader.blocks[@as(usize, @intCast(skin_inst.Data))];
                            if (data_block.parsed) |data_parsed| {
                                if (std.meta.activeTag(data_parsed) == .NiSkinData) {
                                    const sd = data_parsed.NiSkinData;
                                    skin_bind = nif_transform_to_mat(sd.Skin_Transform);
                                    bone_list = sd.Bone_List;
                                }
                            }
                        }

                        var skin_world_bind: [16]f32 = skin_bind orelse [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
                        if (new_skin.mesh_count > 0 and new_skin.mesh_indices != null) {
                            const mesh_idx: usize = @intCast(new_skin.mesh_indices.?[0]);
                            if (mesh_idx < meshes.items.len) {
                                skin_world_bind = meshes.items[mesh_idx].transform;
                            }
                        }

                        var k: usize = 0;
                        while (k < desired_bone_count) : (k += 1) {
                            var bone = std.mem.zeroes(animation.CardinalBone);
                            bone.node_index = @intCast(skin_inst.Bones[k]);

                            const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
                            bone.inverse_bind_matrix = identity;
                            bone.current_matrix = identity;

                            const bone_node_idx: usize = @intCast(bone.node_index);
                            if (bone_node_idx < nodes.items.len) {
                                if (nodes.items[bone_node_idx]) |bone_node| {
                                    bone_node.is_bone = true;
                                    bone_node.bone_index = @intCast(k);

                                    var bone_world_bind_inv: [16]f32 = undefined;
                                    if (transform.cardinal_matrix_invert(&bone_node.world_transform, &bone_world_bind_inv)) {
                                        transform.cardinal_matrix_multiply(&bone_world_bind_inv, &skin_world_bind, &bone.inverse_bind_matrix);
                                    } else if (bone_list) |bl| {
                                        if (k < bl.len and skin_bind != null) {
                                            const bt = bl[k].Skin_Transform;
                                            const bone_bind = nif_transform_to_mat(bt);
                                            var bone_bind_inv: [16]f32 = undefined;
                                            if (transform.cardinal_matrix_invert(&bone_bind, &bone_bind_inv)) {
                                                transform.cardinal_matrix_multiply(&bone_bind_inv, &skin_bind.?, &bone.inverse_bind_matrix);
                                            }
                                        }
                                    }
                                }
                            } else if (bone_list) |bl| {
                                if (k < bl.len and skin_bind != null) {
                                    const bt = bl[k].Skin_Transform;
                                    const bone_bind = nif_transform_to_mat(bt);
                                    var bone_bind_inv: [16]f32 = undefined;
                                    if (transform.cardinal_matrix_invert(&bone_bind, &bone_bind_inv)) {
                                        transform.cardinal_matrix_multiply(&bone_bind_inv, &skin_bind.?, &bone.inverse_bind_matrix);
                                    }
                                }
                            }

                            bones_arr[k] = bone;
                        }
                        new_skin.bones = bones_arr.ptr;
                    }
                }

                skins.append(assets_alloc, new_skin) catch return false;
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
    }

    const needs_anim_sys = (out_scene.skin_count > 0) or (seq_count > 0) or (ctrl_count > 0);
    if (needs_anim_sys) {
        const max_anims: u32 = if (seq_count > 0) @intCast(seq_count + 10) else 16;
        const anim_sys_ptr = animation.cardinal_animation_system_create(max_anims, out_scene.skin_count);
        if (anim_sys_ptr) |sys| {
            if (out_scene.skin_count > 0) {
                for (skins.items) |*skin| {
                    _ = animation.cardinal_animation_system_add_skin(sys, skin);
                }
            }
            out_scene.animation_system = @ptrCast(sys);

            if (seq_count > 0) {
                if (!add_controller_sequences_to_animation_system(&reader, out_scene, sys, assets_allocator, assets_alloc)) return false;
            } else if (ctrl_count > 0) {
                if (out_scene.skin_count > 0) {
                    nif_log.warn("Skipping embedded NIF controller animation for skinned scene.", .{});
                } else {
                    if (!add_embedded_controller_animation(&reader, out_scene, sys, assets_allocator, assets_alloc)) return false;
                }
            }

            nif_log.info("Created Animation System with {d} animations and {d} skins", .{ sys.animation_count, sys.skin_count });
        }
    }

    if (skins.items.len > 0) {
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

    success = true;
    return true;
}
