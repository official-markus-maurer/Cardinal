const std = @import("std");
const scene = @import("scene.zig");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const math = @import("../core/math.zig");
const transform = @import("../core/transform.zig");
const animation = @import("animation.zig");
const texture_loader = @import("texture_loader.zig");
const resource_state = @import("../core/resource_state.zig");
const handles = @import("../core/handles.zig");
const builtin = @import("builtin");

const nif_log = log.ScopedLogger("NIF");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

// --- NIF Data Structures ---

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

const NifBlock = struct {
    type_index: u16, // Index into header.block_types
    data_offset: usize, // Offset in file
    size: u32,

    // Parsed Data (Generic)
    parsed: ?*anyopaque,
};

// Common NIF Blocks
const NiNode = struct {
    name_index: i32,
    flags: u16,
    translation: [3]f32,
    rotation: [9]f32,
    scale: f32,
    num_props: u32,
    props: []i32,
    num_children: u32,
    children: []i32,
};

const NiTriShape = struct {
    name_index: i32,
    flags: u16,
    translation: [3]f32,
    rotation: [9]f32,
    scale: f32,
    num_props: u32,
    props: []i32,
    data_ref: i32,
    skin_instance_ref: i32,
    material_data_ref: i32, // Shader property or similar
};

const NiTriShapeData = struct {
    num_vertices: u32,
    vertices: [][3]f32,
    normals: [][3]f32,
    colors: [][4]f32,
    uvs: [][2]f32,
    num_indices: u32, // num_triangles * 3
    indices: []u32,
};

const NiControllerManager = struct {
    flags: u16,
    num_sequences: u32,
    sequences: []i32,
};

const NiControllerSequence = struct {
    name_index: i32,
    num_controlled_blocks: u32,
    controlled_blocks: []ControlledBlock,
    weight: f32,
    cycle_type: u32,
    frequency: f32,
    start_time: f32,
    stop_time: f32,
};

const ControlledBlock = struct {
    interpolator_ref: i32,
    controller_ref: i32,
    node_name_index: i32,
};

const NiTransformInterpolator = struct {
    translation: [3]f32,
    rotation: [4]f32,
    scale: f32,
    data_ref: i32,
};

const NiTransformData = struct {
    num_rot_keys: u32,
    rot_keys: [][5]f32, // Time + Quat
    num_trans_keys: u32,
    trans_keys: [][4]f32, // Time + Vec3
    num_scale_keys: u32,
    scale_keys: [][2]f32, // Time + Float
};

const NiSkinInstance = struct {
    data_ref: i32,
    skin_partition_ref: i32,
    root_parent_ref: i32,
    num_bones: u32,
    bone_refs: []i32,
};

const NiSkinData = struct {
    rotation: [9]f32,
    translation: [3]f32,
    scale: f32,
    num_bones: u32,
    bone_list: []NiSkinBoneData,
};

const NiSkinBoneData = struct {
    rotation: [9]f32,
    translation: [3]f32,
    scale: f32,
    bounding_sphere_center: [3]f32,
    bounding_sphere_radius: f32,
    num_vertices: u32,
    vertex_weights: []NiSkinWeight,
};

const NiSkinWeight = struct {
    index: u16,
    weight: f32,
};

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

    // --- Basic Readers ---

    pub fn read(self: *NifReader, comptime T: type) !T {
        if (self.pos + @sizeOf(T) > self.buffer.len) return error.EndOfBuffer;
        var val: T = undefined;
        @memcpy(std.mem.asBytes(&val), self.buffer[self.pos .. self.pos + @sizeOf(T)]);
        self.pos += @sizeOf(T);
        return val;
    }

    pub fn read_bytes(self: *NifReader, count: usize) ![]const u8 {
        if (self.pos + count > self.buffer.len) return error.EndOfBuffer;
        const slice = self.buffer[self.pos .. self.pos + count];
        self.pos += count;
        return slice;
    }

    pub fn read_string_lf(self: *NifReader) ![]u8 {
        // Read until \n
        var end = self.pos;
        while (end < self.buffer.len and self.buffer[end] != 0x0A) : (end += 1) {}
        const slice = try self.allocator.dupe(u8, self.buffer[self.pos..end]);
        self.pos = end + 1; // Skip \n
        return slice;
    }

    pub fn read_short_string(self: *NifReader) ![]u8 {
        const len = try self.read(u8);
        const slice = try self.allocator.dupe(u8, self.buffer[self.pos .. self.pos + len]);
        self.pos += len;
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
            // Peek at next 6 bytes (u16 num_types, u32 str_len)
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
                // If we skip UserVer2, we likely also skip MetaData because we are already at Block Types
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
            // Heuristic: Check if MetaData should be skipped
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
                // We don't support parsing metadata yet, so we just skip the count.
                // If there IS metadata, we might crash later because we don't consume it.
                // But usually it's 0.
            }
        }

        // Parse Block Types (Version >= 20.0.0.5)
        if (self.header.version >= 0x14000005) {
            self.header.num_block_types = try self.read(u16);
            nif_log.warn("Num Block Types: {d} (Pos: {d})", .{ self.header.num_block_types, self.pos });

            self.header.block_types = try self.allocator.alloc([]u8, self.header.num_block_types);
            for (self.header.block_types) |*s| s.* = &.{}; // Zero init

            var i: usize = 0;
            while (i < self.header.num_block_types) : (i += 1) {
                self.header.block_types[i] = try self.read_sized_string();
                // nif_log.debug("Block Type [{d}]: {s}", .{i, self.header.block_types[i]});
            }

            self.header.block_type_indices = try self.allocator.alloc(u16, self.header.num_blocks);
            i = 0;
            while (i < self.header.num_blocks) : (i += 1) {
                self.header.block_type_indices[i] = try self.read(u16);
            }

            self.header.block_sizes = try self.allocator.alloc(u32, self.header.num_blocks);
            i = 0;
            nif_log.warn("Reading Block Sizes at Pos: {d}", .{self.pos});
            while (i < self.header.num_blocks) : (i += 1) {
                self.header.block_sizes[i] = try self.read(u32);
            }

            self.header.num_strings = try self.read(u32);
            nif_log.warn("Num Strings: {d} (Pos: {d})", .{ self.header.num_strings, self.pos });

            const max_str_len = try self.read(u32);
            nif_log.warn("Max String Length: {d} (Pos: {d})", .{ max_str_len, self.pos });

            self.header.strings = try self.allocator.alloc([]u8, self.header.num_strings);
            for (self.header.strings) |*s| s.* = &.{}; // Zero init
            // self.header.groups = try self.allocator.alloc(u32, self.header.num_blocks);

            // Max string length check to avoid huge allocs on bad reads
            const MAX_STR_LEN = 1024 * 4;

            i = 0;
            while (i < self.header.num_strings) : (i += 1) {
                const len = try self.read(u32);
                nif_log.warn("String {d} Length: {d} (Pos: {d})", .{ i, len, self.pos });
                if (len > MAX_STR_LEN) {
                    nif_log.err("String too long at index {d}: {d} bytes (Max: {d}) (Pos: {d})", .{ i, len, MAX_STR_LEN, self.pos });
                    // Peek at bytes to see what we are reading
                    const peek_len = @min(16, self.buffer.len - self.pos);
                    nif_log.err("Peek bytes at {d}: {any}", .{ self.pos, self.buffer[self.pos..][0..peek_len] });
                    return error.StringTooLong;
                }
                const slice = try self.allocator.dupe(u8, self.buffer[self.pos .. self.pos + len]);
                self.pos += len;
                self.header.strings[i] = slice;
                nif_log.warn("String {d}: {s}", .{ i, slice });
            }

            // Groups (Num Groups + Array)
            const num_groups = try self.read(u32);
            nif_log.warn("Num Groups: {d} (Pos: {d})", .{ num_groups, self.pos });

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
            // Old versions not supported yet (too different)
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
            nif_log.warn("Parsing Block {d}: {s} (Size: {d}, Offset: {d})", .{ i, type_name, block.size, block.data_offset });

            // Safe parsing: always restore position to end of block
            const end_pos = block.data_offset + block.size;
            defer self.pos = end_pos;

            // Debug Dump for Texture related blocks
            // if (std.mem.eql(u8, type_name, "NiTexturingProperty") or std.mem.eql(u8, type_name, "NiSourceTexture")) {
            //     const dump_len = @min(block.size, 64);
            //     if (block.data_offset + dump_len <= self.buffer.len) {
            //         nif_log.warn("HEX DUMP Block {d} ({s}): {any}", .{ i, type_name, self.buffer[block.data_offset .. block.data_offset + dump_len] });
            //     }
            // }

            if (std.mem.eql(u8, type_name, "NiNode")) {
                const node = try self.allocator.create(NiNode);
                // NiObjectNET
                node.name_index = try self.read(i32);
                const num_extra = try self.read(u32);
                self.pos += num_extra * 4; // refs
                _ = try self.read(i32); // controller_ref

                // NiAVObject
                node.flags = try self.read(u16);
                node.translation = try self.read([3]f32);
                node.rotation = try self.read([9]f32);
                node.scale = try self.read(f32);
                node.num_props = try self.read(u32);
                node.props = try self.allocator.alloc(i32, node.num_props);
                for (node.props) |*prop| prop.* = try self.read(i32);
                _ = try self.read(i32); // collision_ref

                // NiNode
                node.num_children = try self.read(u32);
                node.children = try self.allocator.alloc(i32, node.num_children);
                for (node.children) |*child| child.* = try self.read(i32);

                block.parsed = node;
            } else if (std.mem.eql(u8, type_name, "NiTriShape")) {
                const shape = try self.allocator.create(NiTriShape);
                // NiObjectNET
                shape.name_index = try self.read(i32);
                const num_extra = try self.read(u32);
                self.pos += num_extra * 4;
                _ = try self.read(i32); // controller

                // NiAVObject
                shape.flags = try self.read(u16);
                shape.translation = try self.read([3]f32);
                shape.rotation = try self.read([9]f32);
                shape.scale = try self.read(f32);
                shape.num_props = try self.read(u32);
                shape.props = try self.allocator.alloc(i32, shape.num_props);
                for (shape.props) |*prop| prop.* = try self.read(i32);
                _ = try self.read(i32); // collision

                // NiTriShape
                shape.data_ref = try self.read(i32);
                shape.skin_instance_ref = try self.read(i32);

                block.parsed = shape;
            } else if (std.mem.eql(u8, type_name, "NiTriShapeData")) {
                const data = try self.allocator.create(NiTriShapeData);
                // NiGeometryData (Base)
                _ = try self.read(i32); // Group ID
                data.num_vertices = try self.read(u16);
                _ = try self.read(u8); // Keep Flags
                _ = try self.read(u8); // Compress Flags
                const has_vertices = (try self.read(u8) != 0);

                if (has_vertices) {
                    data.vertices = try self.allocator.alloc([3]f32, data.num_vertices);
                    for (data.vertices) |*v| v.* = try self.read([3]f32);
                } else {
                    data.vertices = &.{};
                }

                // 20.2.0.7+ Num UV Sets is u16 (lower 6 bits), bit 12 is Tangents
                var num_uv_sets: u32 = 0;
                var has_tangents = false;

                // NIF Version check for UV Sets position
                // 4.2.2.0 (0x04020200) seems to be when Num UV Sets appeared here
                const has_early_uv_sets = (self.header.version >= 0x04020200);

                nif_log.warn("NiTriShapeData: Version=0x{x}, HasEarlyUVSets={any}, Pos={d}", .{ self.header.version, has_early_uv_sets, self.pos });

                if (has_early_uv_sets) {
                    if (self.header.version >= 0x14020007) {
                        // 20.2.0.7+ uses u16 (Data Flags or Count)
                        const val = try self.read(u16);
                        if (self.header.user_version_2 > 34) {
                            // Bethesda Data Flags
                            num_uv_sets = val & 63;
                            has_tangents = (val & 0x1000) != 0;
                        } else {
                            // Standard NIF u16 count
                            num_uv_sets = val;
                        }

                        // Force fix for 20.2.0.7 w/ user version 11/12 (Skyrim/Fallout) sometimes having weird flags
                        // If we read 0 but it's a shape, it usually has 1 UV set.
                        if (num_uv_sets == 0 and (self.header.user_version_2 == 12 or self.header.user_version_2 == 11)) {
                            nif_log.warn("Force fixing NumUVSets 0 -> 1 for Bethesda NIF", .{});
                            num_uv_sets = 1;
                        }

                        nif_log.warn("Read NumUVSets (u16/Flags): {d}, Tangents: {any}", .{ num_uv_sets, has_tangents });
                    } else if (self.header.version >= 0x0A010000) {
                        // 10.1.0.0+ uses u32
                        num_uv_sets = try self.read(u32);
                        nif_log.warn("Read NumUVSets (u32): {d}", .{num_uv_sets});
                    } else {
                        // Older uses u8
                        num_uv_sets = try self.read(u8);
                        nif_log.warn("Read NumUVSets (u8): {d}", .{num_uv_sets});
                    }
                }

                nif_log.warn("NiTriShapeData: Verts={d}, UVSets={d}, Tangents={any}", .{ data.num_vertices, num_uv_sets, has_tangents });

                const has_normals = (try self.read(u8) != 0);
                if (has_normals) {
                    data.normals = try self.allocator.alloc([3]f32, data.num_vertices);
                    for (data.normals) |*n| n.* = try self.read([3]f32);

                    if (has_tangents) {
                        // Skip Tangents (Vec3) and Bitangents (Vec3)
                        self.pos += @as(usize, data.num_vertices) * 12 * 2;
                    }
                } else {
                    data.normals = &.{};
                }

                // Center/Radius
                _ = try self.read([3]f32); // Center
                _ = try self.read(f32); // Radius

                const has_vertex_colors = (try self.read(u8) != 0);
                if (has_vertex_colors) {
                    data.colors = try self.allocator.alloc([4]f32, data.num_vertices);
                    for (data.colors) |*col| col.* = try self.read([4]f32);
                } else {
                    data.colors = &.{};
                }

                if (!has_early_uv_sets) {
                    // Legacy UV (4.0.0.2 etc)
                    const has_uv = (try self.read(u8) != 0);
                    if (has_uv) num_uv_sets = 1;
                    nif_log.warn("Legacy HasUV: {any}, New UVSets: {d}", .{ has_uv, num_uv_sets });
                }

                if (num_uv_sets > 0) {
                    // Read Set 0
                    data.uvs = try self.allocator.alloc([2]f32, data.num_vertices);
                    for (data.uvs) |*uv| uv.* = try self.read([2]f32);

                    // Skip remaining sets
                    if (num_uv_sets > 1) {
                        self.pos += @as(usize, (num_uv_sets - 1)) * @as(usize, data.num_vertices) * 8;
                    }
                } else {
                    data.uvs = &.{};
                }

                // Consistency Flags (u16)
                _ = try self.read(u16);
                // Additional Data Ref (i32)
                _ = try self.read(i32);

                // Check for texture but missing UV sets
                if (num_uv_sets == 0 and !has_vertex_colors) {
                    // Heuristic: If mesh has Vertices but No UVs and No Vertex Colors,
                    // it is likely a billboard or crossed-quad plant that relies on implicit UVs (0-1).
                    // We can generate them later if we detect this pattern.
                    // Do NOT allocate empty UVs here, so the loader knows to auto-generate them.
                    nif_log.warn("Mesh has 0 UV sets. Will attempt to auto-generate UVs later.", .{});
                }

                // NiTriShapeData Specific
                const num_triangles = try self.read(u16);
                data.num_indices = @as(u32, num_triangles) * 3;
                const num_triangle_points = try self.read(u32); // Usually num_indices?
                _ = num_triangle_points;
                const has_triangles = (try self.read(u8) != 0);

                if (has_triangles) {
                    data.indices = try self.allocator.alloc(u32, data.num_indices);
                    var t_i: usize = 0;
                    while (t_i < num_triangles) : (t_i += 1) {
                        const idx1 = try self.read(u16);
                        const idx2 = try self.read(u16);
                        const idx3 = try self.read(u16);
                        data.indices[t_i * 3 + 0] = idx1;
                        data.indices[t_i * 3 + 1] = idx2;
                        data.indices[t_i * 3 + 2] = idx3;
                    }
                } else {
                    data.indices = &.{};
                }

                // Match Groups (if version >= 20.2.0.7?)
                // Assuming yes for 20.2.0.8
                const num_match_groups = try self.read(u16);
                var mg_i: usize = 0;
                while (mg_i < num_match_groups) : (mg_i += 1) {
                    const num_verts_in_group = try self.read(u16);
                    self.pos += @as(usize, num_verts_in_group) * 2; // u16 indices
                }

                block.parsed = data;
            } else if (std.mem.eql(u8, type_name, "NiControllerManager")) {
                const mgr = try self.allocator.create(NiControllerManager);
                // NiTimeController
                _ = try self.read(i32); // next_controller
                _ = try self.read(u16); // flags
                _ = try self.read(f32); // frequency
                _ = try self.read(f32); // phase
                _ = try self.read(f32); // start_time
                _ = try self.read(f32); // stop_time
                _ = try self.read(i32); // target

                // NiControllerManager
                mgr.flags = try self.read(u16); // cumulative
                mgr.num_sequences = try self.read(u32);
                mgr.sequences = try self.allocator.alloc(i32, mgr.num_sequences);
                for (mgr.sequences) |*s| s.* = try self.read(i32);

                block.parsed = mgr;
            } else if (std.mem.eql(u8, type_name, "NiControllerSequence")) {
                const seq = try self.allocator.create(NiControllerSequence);
                seq.name_index = try self.read(i32);
                seq.num_controlled_blocks = try self.read(u32);
                _ = try self.read(u32); // array grow by

                seq.controlled_blocks = try self.allocator.alloc(ControlledBlock, seq.num_controlled_blocks);
                for (seq.controlled_blocks) |*cb| {
                    cb.interpolator_ref = try self.read(i32);
                    cb.controller_ref = try self.read(i32);
                    // NiStringPalette ref? or Node Name?
                    // In >= 20.1.0.3:
                    //   look at version.
                    // Assuming < 20.1:
                    //   node_name (string ref)
                    //   prop_type (string ref)
                    //   ctlr_type (string ref)
                    //   ctlr_id (string ref)
                    //   interpolator_id (string ref)
                    // This is version dependent!
                    // Let's assume typical Gamebryo (20.0.0.5):
                    //   Target Name (string ref) -> node_name_index
                    //   Property Type (string ref)
                    //   Controller Type (string ref)
                    //   Controller ID (string ref)
                    //   Interpolator ID (string ref)

                    cb.node_name_index = try self.read(i32);
                    _ = try self.read(i32); // prop type
                    _ = try self.read(i32); // ctlr type
                    _ = try self.read(i32); // ctlr id
                    _ = try self.read(i32); // interp id
                }

                seq.weight = try self.read(f32);
                _ = try self.read(i32); // text_key_ref
                seq.cycle_type = try self.read(u32); // cycle type (enum)
                seq.frequency = try self.read(f32);
                seq.start_time = try self.read(f32);
                seq.stop_time = try self.read(f32);

                block.parsed = seq;
            } else if (std.mem.eql(u8, type_name, "NiTransformInterpolator")) {
                const interp = try self.allocator.create(NiTransformInterpolator);
                // NiKeyBasedInterpolator? No, just fields?
                // Version dependent. 20.0.0.5:
                // translation (vec3)
                // rotation (quat)
                // scale (float)
                // data_ref (ref)

                interp.translation = try self.read([3]f32);
                interp.rotation = try self.read([4]f32);
                interp.scale = try self.read(f32);
                interp.data_ref = try self.read(i32);

                block.parsed = interp;
            } else if (std.mem.eql(u8, type_name, "NiTransformData")) {
                const data = try self.allocator.create(NiTransformData);
                // Key Groups
                // Rotation
                data.num_rot_keys = try self.read(u32);
                if (data.num_rot_keys > 0) {
                    const rot_type = try self.read(u32); // Key type (1=linear, 2=quad)
                    if (rot_type != 0) { // XYZ Rotation? No, Quat keys usually.
                        // This is complex. NiTransformData has separate Rot vs XYZ Rot.
                        // Let's assume standard Quat keys for now.
                        // If rot_type == 4 (XYZ), it's different.
                        // Assuming Quat (type 1 or 2):
                        // keys: time + quat
                        data.rot_keys = try self.allocator.alloc([5]f32, data.num_rot_keys);
                        for (data.rot_keys) |*k| {
                            k.*[0] = try self.read(f32); // time
                            k.*[1] = try self.read(f32); // x
                            k.*[2] = try self.read(f32); // y
                            k.*[3] = try self.read(f32); // z
                            k.*[4] = try self.read(f32); // w
                        }
                    }
                } else {
                    data.rot_keys = &.{};
                }

                // Translation
                data.num_trans_keys = try self.read(u32);
                if (data.num_trans_keys > 0) {
                    const trans_type = try self.read(u32);
                    _ = trans_type;
                    data.trans_keys = try self.allocator.alloc([4]f32, data.num_trans_keys);
                    for (data.trans_keys) |*k| {
                        k.*[0] = try self.read(f32); // time
                        k.*[1] = try self.read(f32); // x
                        k.*[2] = try self.read(f32); // y
                        k.*[3] = try self.read(f32); // z
                    }
                } else {
                    data.trans_keys = &.{};
                }

                // Scale
                data.num_scale_keys = try self.read(u32);
                if (data.num_scale_keys > 0) {
                    const scale_type = try self.read(u32);
                    _ = scale_type;
                    data.scale_keys = try self.allocator.alloc([2]f32, data.num_scale_keys);
                    for (data.scale_keys) |*k| {
                        k.*[0] = try self.read(f32); // time
                        k.*[1] = try self.read(f32); // val
                    }
                } else {
                    data.scale_keys = &.{};
                }

                block.parsed = data;
            } else if (std.mem.eql(u8, type_name, "NiSkinInstance")) {
                const skin = try self.allocator.create(NiSkinInstance);
                skin.data_ref = try self.read(i32);
                skin.skin_partition_ref = try self.read(i32);
                skin.root_parent_ref = try self.read(i32);
                skin.num_bones = try self.read(u32);
                skin.bone_refs = try self.allocator.alloc(i32, skin.num_bones);
                for (skin.bone_refs) |*b| b.* = try self.read(i32);
                block.parsed = skin;
            } else if (std.mem.eql(u8, type_name, "NiSourceTexture")) {
                const tex = try self.allocator.create(NiSourceTexture);
                // NiObjectNET (NiTexture inherits NiObjectNET)
                _ = try self.read(i32); // name
                const num_extra = try self.read(u32);
                self.pos += num_extra * 4; // refs
                _ = try self.read(i32); // controller

                tex.use_external = try self.read(u8);
                tex.file_name_index = try self.read(i32);
                tex.pixel_layout = try self.read(u32);
                tex.use_mipmaps = try self.read(u32);
                tex.alpha_format = try self.read(u32);
                tex.is_static = try self.read(u8);
                // Direct render support bool (usually 1 byte)
                _ = try self.read(u8);
                // Persistence bool (usually 1 byte)
                _ = try self.read(u8);

                block.parsed = tex;
            } else if (std.mem.eql(u8, type_name, "NiTexturingProperty")) {
                const prop = try self.allocator.create(NiTexturingProperty);
                // NiObjectNET (NiProperty inherits NiObjectNET)
                _ = try self.read(i32); // name
                const num_extra = try self.read(u32);
                self.pos += num_extra * 4; // refs
                _ = try self.read(i32); // controller

                prop.flags = try self.read(u16);
                prop.apply_mode = try self.read(u32);

                // Version 20.1.0.3+ does not have texture_count (fixed at 7)
                if (self.header.version >= 0x14010003) {
                    prop.texture_count = 7;
                    nif_log.warn("  Skipped texture_count for version 0x{x}", .{self.header.version});
                } else {
                    prop.texture_count = try self.read(u32);
                    nif_log.warn("  Read texture_count: {d}", .{prop.texture_count});
                }

                nif_log.warn("  Reading Base Texture at {d}", .{self.pos});
                prop.base_texture = try read_texture_desc(self);

                nif_log.warn("  Reading Dark Texture at {d}", .{self.pos});
                prop.dark_texture = try read_texture_desc(self);
                prop.detail_texture = try read_texture_desc(self);
                prop.gloss_texture = try read_texture_desc(self);
                prop.glow_texture = try read_texture_desc(self);
                prop.bump_map_texture = try read_texture_desc(self);

                if (prop.texture_count > 6) {
                    prop.decal_0_texture = try read_texture_desc(self);
                } else {
                    prop.decal_0_texture = null;
                }

                if (prop.texture_count > 7) {
                    prop.decal_1_texture = try read_texture_desc(self);
                } else {
                    prop.decal_1_texture = null;
                }

                block.parsed = prop;
            } else if (std.mem.eql(u8, type_name, "NiSkinData")) {
                const data = try self.allocator.create(NiSkinData);
                data.rotation = try self.read([9]f32);
                data.translation = try self.read([3]f32);
                data.scale = try self.read(f32);
                data.num_bones = try self.read(u32);
                data.bone_list = try self.allocator.alloc(NiSkinBoneData, data.num_bones);

                // Has Vertex Weights? (bool) - Nif.xml says this exists in NiSkinData
                _ = try self.read(u8); // has_vertex_weights (usually 1)

                for (data.bone_list) |*bone| {
                    bone.rotation = try self.read([9]f32);
                    bone.translation = try self.read([3]f32);
                    bone.scale = try self.read(f32);
                    bone.bounding_sphere_center = try self.read([3]f32);
                    bone.bounding_sphere_radius = try self.read(f32);

                    const num_verts = try self.read(u16);
                    bone.num_vertices = num_verts;

                    bone.vertex_weights = try self.allocator.alloc(NiSkinWeight, num_verts);
                    for (bone.vertex_weights) |*vw| {
                        vw.index = try self.read(u16);
                        vw.weight = try self.read(f32);
                    }
                }
                block.parsed = data;
            } else if (std.mem.eql(u8, type_name, "NiAlphaProperty")) {
                const prop = try self.allocator.create(NiAlphaProperty);
                // NiObjectNET
                _ = try self.read(i32); // name
                const num_extra = try self.read(u32);
                self.pos += num_extra * 4; // refs
                _ = try self.read(i32); // controller

                prop.flags = try self.read(u16);
                prop.threshold = try self.read(u8);

                nif_log.debug("NiAlphaProperty: Flags=0x{x}, Threshold={d}", .{ prop.flags, prop.threshold });

                block.parsed = prop;
            } else if (std.mem.eql(u8, type_name, "NiMaterialProperty")) {
                const prop = try self.allocator.create(NiMaterialProperty);
                // NiObjectNET
                _ = try self.read(i32); // name
                const num_extra = try self.read(u32);
                self.pos += num_extra * 4; // refs
                _ = try self.read(i32); // controller

                prop.flags = try self.read(u16);
                prop.ambient = try self.read([3]f32);
                prop.diffuse = try self.read([3]f32);
                prop.specular = try self.read([3]f32);
                prop.emissive = try self.read([3]f32);
                prop.glossiness = try self.read(f32);
                prop.alpha = try self.read(f32);

                nif_log.debug("NiMaterialProperty {d}: Amb={any}, Diff={any}, Spec={any}, Emis={any}", .{ i, prop.ambient, prop.diffuse, prop.specular, prop.emissive });

                block.parsed = prop;
            } else if (std.mem.eql(u8, type_name, "NiStencilProperty")) {
                const prop = try self.allocator.create(NiStencilProperty);
                // NiObjectNET
                _ = try self.read(i32); // name
                const num_extra = try self.read(u32);
                self.pos += num_extra * 4; // refs
                _ = try self.read(i32); // controller

                // In some versions (<= 20.0.0.5) flags is u16?
                // In >= 20.1.0.3, it is flags(u16) + ...
                // Let's assume u16 for now as per Nif.xml common
                prop.flags = try self.read(u16);
                // Might be more data (Ref)
                // Just stop here, we only care about flags (double sided)
                block.parsed = prop;
            }
        }
    }
};

// --- Integration ---

// Define Structs for Texture Parsing
const NiAlphaProperty = struct {
    flags: u16,
    threshold: u8,
};

const NiMaterialProperty = struct {
    flags: u16,
    ambient: [3]f32,
    diffuse: [3]f32,
    specular: [3]f32,
    emissive: [3]f32,
    glossiness: f32,
    alpha: f32,
};

const NiStencilProperty = struct {
    flags: u16,
};

const NiSourceTexture = struct {
    use_external: u8,
    file_name_index: i32,
    pixel_layout: u32,
    use_mipmaps: u32,
    alpha_format: u32,
    is_static: u8,
};

const NiTexturingProperty = struct {
    flags: u16,
    apply_mode: u32,
    texture_count: u32,
    base_texture: ?TextureDesc,
    dark_texture: ?TextureDesc,
    detail_texture: ?TextureDesc,
    gloss_texture: ?TextureDesc,
    glow_texture: ?TextureDesc,
    bump_map_texture: ?TextureDesc,
    decal_0_texture: ?TextureDesc,
    decal_1_texture: ?TextureDesc,
};

const TextureDesc = struct {
    source_texture_ref: i32,
    clamp_mode: u16,
    filter_mode: u16,
    uv_set: u32,
    ps2_l: i16,
    ps2_k: i16,
    has_texture_transform: u8,
    // Texture Transform (if has_texture_transform)
    translation: [2]f32,
    tiling: [2]f32,
    w_rotation: f32,
    transform_type: u32,
    center_offset: [2]f32,
};

fn read_texture_desc(reader: *NifReader) !?TextureDesc {
    const start_pos = reader.pos;
    const has_texture_byte = try reader.read(u8);
    const has_texture = (has_texture_byte != 0);

    nif_log.warn("  TextureDesc at {d}: Has={d}", .{ start_pos, has_texture_byte });

    if (!has_texture) return null;

    var desc: TextureDesc = undefined;
    desc.source_texture_ref = try reader.read(i32);
    desc.clamp_mode = try reader.read(u16);
    desc.filter_mode = try reader.read(u16);
    desc.uv_set = try reader.read(u32);

    // Version checks: PS2 L/K removed in 20.0.0.5+
    // desc.ps2_l = try reader.read(i16);
    // desc.ps2_k = try reader.read(i16);

    desc.has_texture_transform = try reader.read(u8);

    nif_log.warn("    Ref: {d}, Clamp: {d}, Filter: {d}, UV: {d}", .{ desc.source_texture_ref, desc.clamp_mode, desc.filter_mode, desc.uv_set });

    if (desc.has_texture_transform != 0) {
        desc.translation = try reader.read([2]f32);
        desc.tiling = try reader.read([2]f32);
        desc.w_rotation = try reader.read(f32);
        desc.transform_type = try reader.read(u32);
        desc.center_offset = try reader.read([2]f32);
    } else {
        desc.translation = .{ 0, 0 };
        desc.tiling = .{ 1, 1 };
        desc.w_rotation = 0;
        desc.transform_type = 0;
        desc.center_offset = .{ 0, 0 };
    }

    return desc;
}

fn normalize_texture_path(allocator: std.mem.Allocator, path: []const u8) ?[:0]u8 {
    const buf = allocator.alloc(u8, path.len + 1) catch return null;
    @memcpy(buf[0..path.len], path);
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (buf[i] == '\\') buf[i] = '/';
        if (builtin.os.tag == .windows) {
            buf[i] = std.ascii.toLower(buf[i]);
        }
    }
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub export fn cardinal_nif_load_scene(path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool {
    nif_log.warn("Loading NIF scene: {s}", .{path});

    // Zero initialize the scene
    out_scene.* = std.mem.zeroes(scene.CardinalScene);

    // 1. Read file
    const file = std.fs.cwd().openFileZ(path, .{}) catch |err| {
        nif_log.err("Failed to open file: {s}", .{@errorName(err)});
        return false;
    };
    defer file.close();

    const size = file.getEndPos() catch 0;
    if (size == 0) return false;

    // Use Engine allocator (thread-safe, usually)
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const asset_allocator = memory.cardinal_get_allocator_for_category(.ASSETS).as_allocator();

    const buffer = allocator.alloc(u8, size) catch return false;
    defer allocator.free(buffer);

    _ = file.readAll(buffer) catch return false;

    // 2. Parse
    var reader = NifReader.init(allocator, buffer);
    defer reader.deinit();

    reader.parse_header() catch |err| {
        nif_log.err("Failed to parse NIF header: {s}", .{@errorName(err)});
        return false;
    };

    reader.parse_blocks() catch |err| {
        nif_log.err("Failed to parse NIF blocks: {s}", .{@errorName(err)});
        return false;
    };

    // 3. Convert to Scene
    // For now, just create a root node
    // Find the root (Block 0 is usually root)
    if (reader.header.num_blocks > 0) {
        // We need to build the hierarchy recursively
        // Allocate node pointers array
        const all_nodes_ptr = memory.cardinal_calloc(memory.cardinal_get_allocator_for_category(.ASSETS), reader.header.num_blocks, @sizeOf(?*scene.CardinalSceneNode));
        out_scene.all_nodes = @ptrCast(@alignCast(all_nodes_ptr));
        out_scene.all_node_count = reader.header.num_blocks;

        // Pass 1: Create Nodes
        var i: usize = 0;
        while (i < reader.header.num_blocks) : (i += 1) {
            const block = &reader.blocks[i];
            const type_name = reader.header.block_types[block.type_index];

            if (block.parsed) |p| {
                if (std.mem.eql(u8, type_name, "NiNode") or std.mem.eql(u8, type_name, "NiTriShape")) {
                    // It's a node
                    var name_index: i32 = -1;
                    if (std.mem.eql(u8, type_name, "NiNode")) {
                        const av = @as(*NiNode, @ptrCast(@alignCast(p)));
                        name_index = av.name_index;
                    } else {
                        const av = @as(*NiTriShape, @ptrCast(@alignCast(p)));
                        name_index = av.name_index;
                    }

                    var node_name: ?[*:0]const u8 = null;
                    // We need a null-terminated string for create, but header strings are slices.
                    var name_buf: [256]u8 = undefined;
                    if (name_index >= 0 and name_index < reader.header.num_strings) {
                        const s = reader.header.strings[@intCast(name_index)];
                        const len = @min(s.len, 255);
                        @memcpy(name_buf[0..len], s[0..len]);
                        name_buf[len] = 0;
                        node_name = @ptrCast(&name_buf);
                    } else {
                        // Fallback
                        const default_name = if (std.mem.eql(u8, type_name, "NiNode")) "NiNode" else "NiTriShape";
                        const len = default_name.len;
                        @memcpy(name_buf[0..len], default_name);
                        name_buf[len] = 0;
                        node_name = @ptrCast(&name_buf);
                    }

                    const node = scene.cardinal_scene_node_create(node_name);
                    out_scene.all_nodes.?[i] = node;

                    // Set transform
                    const av = @as(*NiNode, @ptrCast(@alignCast(p)));
                    var transform_mat: [16]f32 = undefined;
                    var r: [9]f32 = av.rotation;
                    var t: [3]f32 = av.translation;
                    const s: f32 = av.scale;

                    // Mat4 from TRS
                    transform.cardinal_matrix_from_rt_s(&r, &t, s, &transform_mat);
                    scene.cardinal_scene_node_set_local_transform(node.?, &transform_mat);
                }
            }
        }

        // Pass 2: Link Hierarchy
        i = 0;
        while (i < reader.header.num_blocks) : (i += 1) {
            const block = &reader.blocks[i];
            const type_name = reader.header.block_types[block.type_index];
            const parent_node = out_scene.all_nodes.?[i];

            if (parent_node != null and block.parsed != null) {
                if (std.mem.eql(u8, type_name, "NiNode")) {
                    const node_data = @as(*NiNode, @ptrCast(@alignCast(block.parsed.?)));
                    for (node_data.children) |child_idx| {
                        if (child_idx >= 0 and child_idx < reader.header.num_blocks) {
                            if (out_scene.all_nodes.?[@intCast(child_idx)]) |child_node| {
                                _ = scene.cardinal_scene_node_add_child(parent_node.?, child_node);
                            }
                        }
                    }
                } else if (std.mem.eql(u8, type_name, "NiTriShape")) {
                    const shape_data = @as(*NiTriShape, @ptrCast(@alignCast(block.parsed.?)));
                    // Handle Mesh Data
                    if (shape_data.data_ref >= 0 and shape_data.data_ref < reader.header.num_blocks) {
                        const data_block = &reader.blocks[@intCast(shape_data.data_ref)];
                        if (data_block.parsed != null and std.mem.eql(u8, reader.header.block_types[data_block.type_index], "NiTriShapeData")) {
                            // Valid data block
                        }
                    }
                }
            }
        }

        // Pass 3: Collect Meshes
        var mesh_count: u32 = 0;
        i = 0;
        while (i < reader.header.num_blocks) : (i += 1) {
            const type_name = reader.header.block_types[reader.blocks[i].type_index];
            if (std.mem.eql(u8, type_name, "NiTriShape")) mesh_count += 1;
        }

        if (mesh_count > 0) {
            out_scene.mesh_count = mesh_count;
            const meshes_ptr = memory.cardinal_calloc(memory.cardinal_get_allocator_for_category(.ASSETS), mesh_count, @sizeOf(scene.CardinalMesh));
            out_scene.meshes = @ptrCast(@alignCast(meshes_ptr));

            // Create Materials (allocate max potential, shrink later or just use count)
            // For simplicity, we can just allocate one material per mesh, but that's wasteful.
            // Better: allocate a list, and reuse.
            // For now, let's create a list of Materials found in the NIF.

            var material_list = std.ArrayListUnmanaged(scene.CardinalMaterial){};
            defer material_list.deinit(allocator);

            var texture_list = std.ArrayListUnmanaged(scene.CardinalTexture){};
            defer texture_list.deinit(allocator);

            // Add default material
            var default_mat = std.mem.zeroes(scene.CardinalMaterial);
            default_mat.albedo_factor = .{ 1, 1, 1, 1 };
            default_mat.roughness_factor = 1.0;
            default_mat.metallic_factor = 0.0;
            default_mat.alpha_cutoff = 0.5;
            default_mat.double_sided = true;
            default_mat.albedo_texture = handles.TextureHandle.INVALID;
            default_mat.normal_texture = handles.TextureHandle.INVALID;
            default_mat.metallic_roughness_texture = handles.TextureHandle.INVALID;
            default_mat.ao_texture = handles.TextureHandle.INVALID;
            default_mat.emissive_texture = handles.TextureHandle.INVALID;

            // Initialize transforms to identity
            default_mat.albedo_transform.scale = .{ 1.0, 1.0 };
            default_mat.normal_transform.scale = .{ 1.0, 1.0 };
            default_mat.metallic_roughness_transform.scale = .{ 1.0, 1.0 };
            default_mat.ao_transform.scale = .{ 1.0, 1.0 };
            default_mat.emissive_transform.scale = .{ 1.0, 1.0 };

            material_list.append(allocator, default_mat) catch return false;

            var mesh_idx: usize = 0;
            i = 0;
            while (i < reader.header.num_blocks) : (i += 1) {
                const block = &reader.blocks[i];
                const type_name = reader.header.block_types[block.type_index];

                if (std.mem.eql(u8, type_name, "NiTriShape") and block.parsed != null) {
                    const shape = @as(*NiTriShape, @ptrCast(@alignCast(block.parsed.?)));

                    // Initialize Mesh in-place
                    const mesh = &out_scene.meshes.?[mesh_idx];
                    mesh.* = std.mem.zeroes(scene.CardinalMesh);
                    // Bit 0 of flags is 'Hidden'
                    mesh.visible = (shape.flags & 1) == 0;

                    // Determine Material
                    var mat_index: u32 = 0;
                    var has_alpha_property = false;
                    var has_material_property = false;
                    var has_stencil_property = false;

                    // Temp pointers to properties
                    var p_alpha: ?*NiAlphaProperty = null;
                    var p_material: ?*NiMaterialProperty = null;
                    var p_stencil: ?*NiStencilProperty = null;
                    var p_texturing: ?*NiTexturingProperty = null;

                    // First pass: gather properties
                    if (shape.props.len > 0) {
                        for (shape.props) |prop_ref| {
                            if (prop_ref >= 0 and prop_ref < reader.header.num_blocks) {
                                const prop_block = &reader.blocks[@intCast(prop_ref)];
                                const prop_type = reader.header.block_types[prop_block.type_index];

                                if (prop_block.parsed) |parsed| {
                                    if (std.mem.eql(u8, prop_type, "NiTexturingProperty")) {
                                        p_texturing = @as(*NiTexturingProperty, @ptrCast(@alignCast(parsed)));
                                    } else if (std.mem.eql(u8, prop_type, "NiAlphaProperty")) {
                                        p_alpha = @as(*NiAlphaProperty, @ptrCast(@alignCast(parsed)));
                                        has_alpha_property = true;
                                    } else if (std.mem.eql(u8, prop_type, "NiMaterialProperty")) {
                                        p_material = @as(*NiMaterialProperty, @ptrCast(@alignCast(parsed)));
                                        has_material_property = true;
                                    } else if (std.mem.eql(u8, prop_type, "NiStencilProperty")) {
                                        p_stencil = @as(*NiStencilProperty, @ptrCast(@alignCast(parsed)));
                                        has_stencil_property = true;
                                    }
                                }
                            }
                        }
                    }

                    // Create new material based on gathered properties
                    // Start with default
                    var new_mat = default_mat;

                    // IMPORTANT: Force default albedo to WHITE if no material property exists
                    // Default was 1,1,1,1 but we should be explicit
                    // If p_material exists, it overwrites. If not, we have 1,1,1,1.
                    // However, if we have textures but no material property, we must ensure we don't end up with 0 alpha or black color.

                    // Apply Material Property
                    if (p_material) |m| {
                        // Heuristic: If material diffuse is black (0,0,0), force it to white.
                        // This fixes legacy assets where the material color was zeroed out but textures were expected to provide color.
                        if (m.diffuse[0] < 0.001 and m.diffuse[1] < 0.001 and m.diffuse[2] < 0.001) {
                            nif_log.warn("Material {d} has BLACK diffuse color. Forcing to WHITE.", .{mat_index});
                            new_mat.albedo_factor = .{ 1.0, 1.0, 1.0, m.alpha };
                        } else {
                            new_mat.albedo_factor = .{ m.diffuse[0], m.diffuse[1], m.diffuse[2], m.alpha };
                        }

                        new_mat.emissive_factor = m.emissive;
                        // Rough approximation of PBR from Phong
                        // Specular power (glossiness) -> roughness
                        // Low gloss (small) -> rough (1.0)
                        // High gloss (large) -> smooth (0.0)
                        // Roughness = 1 - (log(glossiness) / log(max_gloss))?
                        // Or just inverse.
                        // Typical glossiness 10-50.
                        if (m.glossiness > 0) {
                            new_mat.roughness_factor = 1.0 - std.math.clamp(m.glossiness / 100.0, 0.0, 1.0);
                        }
                        // Metallic? Gamebryo usually non-metallic unless environment map.
                        new_mat.metallic_factor = 0.0;
                    } else {
                        // No material property: Default to white opaque
                        new_mat.albedo_factor = .{ 1.0, 1.0, 1.0, 1.0 };
                        new_mat.roughness_factor = 1.0;
                        new_mat.metallic_factor = 0.0;
                    }

                    // Apply Alpha Property
                    if (p_alpha) |a| {
                        // Flags:
                        // Bit 0: Blend Enable
                        // Bit 9: Test Enable (Alpha Cutoff)
                        const blend_enabled = (a.flags & 1) != 0;
                        const test_enabled = (a.flags & 512) != 0; // 0x200

                        nif_log.warn("Mesh {d} Alpha: Flags=0x{x}, Blend={any}, Test={any}, Thresh={d}", .{ mesh_idx, a.flags, blend_enabled, test_enabled, a.threshold });

                        // Prioritize MASK (Alpha Test) because it handles cutouts (leaves/fences) better than BLEND in our PBR pipeline.
                        // If both are enabled, it's usually "Alpha Test AND Blend", but we can only pick one mode for glTF.
                        // MASK ensures depth write and proper sorting for cutouts.
                        if (test_enabled) {
                            new_mat.alpha_mode = .MASK;
                            new_mat.alpha_cutoff = @as(f32, @floatFromInt(a.threshold)) / 255.0;
                            // Ensure cutoff is reasonable
                            if (new_mat.alpha_cutoff == 0.0) new_mat.alpha_cutoff = 0.5;
                            nif_log.warn("Mesh {d} Mode -> MASK (Cutoff: {d:.2})", .{ mesh_idx, new_mat.alpha_cutoff });
                        } else if (blend_enabled) {
                            new_mat.alpha_mode = .BLEND;
                            nif_log.warn("Mesh {d} Mode -> BLEND", .{mesh_idx});
                        } else {
                            new_mat.alpha_mode = .OPAQUE;
                        }
                    } else {
                        // No alpha property usually means OPAQUE, unless texture has alpha?
                        // If material alpha < 1.0, set to BLEND?
                        if (new_mat.albedo_factor[3] < 0.99) {
                            new_mat.alpha_mode = .BLEND;
                        }
                    }

                    // Apply Stencil Property (Double Sided)
                    if (p_stencil) |s| {
                        // DRAW_MODE_CCW = 2 (standard)
                        // DRAW_MODE_BOTH = 3 (double sided)
                        // Mask bits 11-10-9 ? No, usually an enum.
                        // Standard Gamebryo:
                        // Bit 0: Enable
                        // Bit 1: Fail Action
                        // ...
                        // Wait, Double Sided is usually in NiStencilProperty flags?
                        // Or NiProperty flags.
                        // Actually NiStencilProperty controls stencil buffer.
                        // DOUBLE SIDED is often in NiStencilProperty OR specific shader flags.
                        // Nif.xml says:
                        // Bit 9-11: Draw Mode
                        // 0 = DRAW_CCW (Standard)
                        // 1 = DRAW_CCW ?
                        // 2 = DRAW_BOTH ?
                        // Let's assume standard behavior:
                        const draw_mode = (s.flags >> 9) & 7;
                        if (draw_mode == 2 or draw_mode == 3) {
                            new_mat.double_sided = true;
                        } else {
                            new_mat.double_sided = false;
                        }
                    }

                    // Apply Textures (if present)
                    if (p_texturing) |tex_prop| {
                        // ... existing texture logic ...
                        // We need to move the existing texture logic here and use p_texturing
                        // Debug log for property linkage
                        nif_log.debug("Mesh {d} references NiTexturingProperty", .{mesh_idx});

                        if (tex_prop.base_texture) |base_tex| {
                            nif_log.debug("  Has Base Texture. Ref: {d}", .{base_tex.source_texture_ref});
                            if (base_tex.source_texture_ref >= 0 and base_tex.source_texture_ref < reader.header.num_blocks) {
                                const src_block = &reader.blocks[@intCast(base_tex.source_texture_ref)];
                                const src_type = reader.header.block_types[src_block.type_index];
                                nif_log.debug("  Texture Block Type: {s}", .{src_type});

                                if (std.mem.eql(u8, src_type, "NiSourceTexture") and src_block.parsed != null) {
                                    const src_tex = @as(*NiSourceTexture, @ptrCast(@alignCast(src_block.parsed.?)));
                                    if (src_tex.file_name_index >= 0 and src_tex.file_name_index < reader.header.num_strings) {
                                        const tex_name = reader.header.strings[@intCast(src_tex.file_name_index)];
                                        // Found texture name!
                                        nif_log.debug("Found texture for mesh {d}: {s}", .{ mesh_idx, tex_name });

                                        // Resolve path
                                        const nif_dir = std.fs.path.dirname(std.mem.span(path)) orelse ".";

                                        // Sanitize basename (handle both / and \)
                                        var clean_basename_buf: [256]u8 = undefined;
                                        var clean_len: usize = 0;
                                        var last_sep: isize = -1;
                                        for (tex_name, 0..) |char, idx| {
                                            if (char == '/' or char == '\\') last_sep = @intCast(idx);
                                        }
                                        if (last_sep != -1) {
                                            const start = @as(usize, @intCast(last_sep + 1));
                                            const len = tex_name.len - start;
                                            if (len < 256) {
                                                @memcpy(clean_basename_buf[0..len], tex_name[start..]);
                                                clean_len = len;
                                            }
                                        } else {
                                            const len = tex_name.len;
                                            if (len < 256) {
                                                @memcpy(clean_basename_buf[0..len], tex_name);
                                                clean_len = len;
                                            }
                                        }
                                        const clean_basename = clean_basename_buf[0..clean_len];
                                        const stem = std.fs.path.stem(clean_basename);

                                        var full_tex_path: ?[]u8 = null;

                                        // Extensions to try (Prioritize supported formats)
                                        const extensions = [_][]const u8{ ".dds", ".png", ".tga", ".jpg", ".bmp", "" };

                                        // Strategy 1: Try using the relative path from NIF (if not absolute)
                                        // This handles cases like "textures/hero.dds" relative to NIF location
                                        if (!std.fs.path.isAbsolute(tex_name) and tex_name.len < 256) {
                                            // Normalize separators
                                            var rel_buf: [256]u8 = undefined;
                                            @memcpy(rel_buf[0..tex_name.len], tex_name);
                                            for (rel_buf[0..tex_name.len]) |*char_ptr| {
                                                if (char_ptr.* == '\\') char_ptr.* = '/';
                                            }
                                            const rel_path = rel_buf[0..tex_name.len];

                                            // If it has directory components
                                            if (std.mem.indexOf(u8, rel_path, "/") != null) {
                                                const rel_stem = std.fs.path.stem(rel_path);
                                                const rel_dir = std.fs.path.dirname(rel_path) orelse "";

                                                for (extensions) |ext| {
                                                    var test_name_buf: [256]u8 = undefined;
                                                    var test_rel_path: []const u8 = undefined;

                                                    if (ext.len == 0) {
                                                        test_rel_path = rel_path;
                                                    } else {
                                                        // Replace extension or append if none
                                                        test_rel_path = std.fmt.bufPrint(&test_name_buf, "{s}/{s}{s}", .{ rel_dir, rel_stem, ext }) catch continue;
                                                    }

                                                    const test_path = std.fs.path.resolve(allocator, &.{ nif_dir, test_rel_path }) catch continue;

                                                    // Check existence
                                                    const f = std.fs.cwd().openFile(test_path, .{}) catch {
                                                        allocator.free(test_path);
                                                        continue;
                                                    };
                                                    f.close();

                                                    full_tex_path = test_path;
                                                    nif_log.debug("Found texture using relative path: {s}", .{test_path});
                                                    break;
                                                }
                                            }
                                        }

                                        // Strategy 2: Search suffixes relative to NIF dir (Fallback)
                                        if (full_tex_path == null) {
                                            const dir_suffixes = [_][]const u8{ "", "textures", "texture", "../textures", "../texture", "..", "../..", "../../textures", "../../texture" };

                                            outer: for (dir_suffixes) |suffix| {
                                                var search_dir: []u8 = undefined;
                                                if (suffix.len == 0) {
                                                    search_dir = allocator.dupe(u8, nif_dir) catch continue;
                                                } else {
                                                    search_dir = std.fs.path.join(allocator, &.{ nif_dir, suffix }) catch continue;
                                                }
                                                defer allocator.free(search_dir);

                                                for (extensions) |ext| {
                                                    var test_name_buf: [256]u8 = undefined;
                                                    var test_name: []const u8 = undefined;

                                                    if (ext.len == 0) {
                                                        test_name = clean_basename;
                                                    } else {
                                                        test_name = std.fmt.bufPrint(&test_name_buf, "{s}{s}", .{ stem, ext }) catch continue;
                                                    }

                                                    // Use resolve to get canonical path
                                                    const test_path = std.fs.path.resolve(allocator, &.{ search_dir, test_name }) catch continue;

                                                    // nif_log.warn("Trying texture path: {s}", .{test_path});

                                                    // Check existence
                                                    const f = std.fs.cwd().openFile(test_path, .{}) catch {
                                                        allocator.free(test_path);
                                                        continue;
                                                    };
                                                    f.close();

                                                    full_tex_path = test_path; // Ownership passed
                                                    break :outer;
                                                }
                                            }
                                        }

                                        if (full_tex_path) |ftp| {
                                            nif_log.debug("Resolved texture path: {s}", .{ftp});

                                            const ext = std.fs.path.extension(ftp);
                                            if (std.ascii.eqlIgnoreCase(ext, ".dds")) {
                                                nif_log.debug("DDS texture detected: {s}", .{ftp});
                                            }

                                            const normalized_path = normalize_texture_path(asset_allocator, ftp) orelse {
                                                allocator.free(ftp);
                                                continue;
                                            };
                                            const normalized_path_slice = normalized_path;

                                            var tex_idx: i32 = -1;
                                            for (texture_list.items, 0..) |t, ti| {
                                                if (t.path) |tp| {
                                                    const existing_path = std.mem.span(tp);
                                                    const matches = if (builtin.os.tag == .windows)
                                                        std.ascii.eqlIgnoreCase(existing_path, normalized_path_slice)
                                                    else
                                                        std.mem.eql(u8, existing_path, normalized_path_slice);
                                                    if (matches) {
                                                        tex_idx = @intCast(ti);
                                                        break;
                                                    }
                                                }
                                            }

                                            if (tex_idx == -1) {
                                                var tex_data = std.mem.zeroes(texture_loader.TextureData);
                                                const tex_path_z: [:0]u8 = normalized_path;

                                                const ref = texture_loader.texture_load_with_ref_counting(tex_path_z.ptr, &tex_data);

                                                if (ref != null) {
                                                    nif_log.debug("Texture load started/ref created for {s}", .{ftp});
                                                } else {
                                                    nif_log.err("Failed to create texture ref for {s}", .{ftp});
                                                }

                                                var new_tex = std.mem.zeroes(scene.CardinalTexture);
                                                new_tex.path = @ptrCast(tex_path_z);
                                                new_tex.ref_resource = ref;
                                                if (ref != null and ref.?.identifier != null) {
                                                    const state = resource_state.cardinal_resource_state_get(ref.?.identifier.?);
                                                    if (state == .LOADED) {
                                                        new_tex.data = tex_data.data;
                                                        new_tex.width = tex_data.width;
                                                        new_tex.height = tex_data.height;
                                                        new_tex.channels = tex_data.channels;
                                                        new_tex.is_hdr = tex_data.is_hdr;
                                                        new_tex.format = tex_data.format;
                                                        new_tex.data_size = tex_data.data_size;
                                                    }
                                                }

                                                texture_list.append(allocator, new_tex) catch return false;
                                                tex_idx = @intCast(texture_list.items.len - 1);
                                            } else {
                                                asset_allocator.free(normalized_path);
                                            }

                                            new_mat.albedo_texture = .{ .index = @intCast(tex_idx), .generation = 1 };

                                            // Copy texture transform
                                            if (base_tex.has_texture_transform != 0) {
                                                new_mat.albedo_transform.offset = base_tex.translation;
                                                new_mat.albedo_transform.scale = base_tex.tiling;
                                                new_mat.albedo_transform.rotation = base_tex.w_rotation;
                                                // Center offset/transform type not fully supported yet, using basic TRS
                                            }

                                            allocator.free(ftp);
                                        } else {
                                            nif_log.warn("Could not resolve texture: {s}", .{tex_name});
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Add material to list
                    material_list.append(allocator, new_mat) catch return false;
                    mat_index = @intCast(material_list.items.len - 1);

                    mesh.material_index = mat_index;
                    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
                    @memcpy(&mesh.transform, &identity);

                    // Link to Node
                    if (out_scene.all_nodes.?[i]) |node| {
                        const indices_arr = memory.cardinal_alloc(memory.cardinal_get_allocator_for_category(.ASSETS), 4);
                        if (indices_arr) |ia| {
                            node.mesh_indices = @ptrCast(@alignCast(ia));
                            node.mesh_indices.?[0] = @intCast(mesh_idx);
                            node.mesh_count = 1;
                        }
                    }

                    // Geometry Data
                    if (shape.data_ref >= 0 and shape.data_ref < reader.header.num_blocks) {
                        const data_block = &reader.blocks[@intCast(shape.data_ref)];
                        if (data_block.parsed != null and std.mem.eql(u8, reader.header.block_types[data_block.type_index], "NiTriShapeData")) {
                            const data = @as(*NiTriShapeData, @ptrCast(@alignCast(data_block.parsed.?)));

                            // Vertices (Interleaved)
                            const vertex_count = data.num_vertices;
                            if (vertex_count > 0) {
                                const v_mem = memory.cardinal_alloc(memory.cardinal_get_allocator_for_category(.ASSETS), @as(usize, vertex_count) * @sizeOf(scene.CardinalVertex));
                                if (v_mem) |vm| {
                                    const vertices_ptr = @as([*]scene.CardinalVertex, @ptrCast(@alignCast(vm)));
                                    var v_i: usize = 0;
                                    while (v_i < vertex_count) : (v_i += 1) {
                                        var v = &vertices_ptr[v_i];
                                        // Pos
                                        if (data.vertices.len > v_i) {
                                            v.px = data.vertices[v_i][0];
                                            v.py = data.vertices[v_i][1];
                                            v.pz = data.vertices[v_i][2];
                                        }
                                        v._pad0 = 0.0;
                                        // Normal
                                        if (data.normals.len > v_i) {
                                            v.nx = data.normals[v_i][0];
                                            v.ny = data.normals[v_i][1];
                                            v.nz = data.normals[v_i][2];
                                        } else {
                                            v.nx = 0;
                                            v.ny = 1;
                                            v.nz = 0;
                                        }
                                        v._pad1 = 0.0;
                                        // UV
                                        if (data.uvs.len > v_i) {
                                            v.u = data.uvs[v_i][0];
                                            v.v = data.uvs[v_i][1];
                                        } else {
                                            // Auto-generate planar/billboard UVs for small meshes (e.g. leaves) if missing
                                            // Assuming quads (4 verts per quad) or standard winding
                                            if (vertex_count <= 256 and (vertex_count % 4) == 0) {
                                                const corner = v_i % 4;
                                                switch (corner) {
                                                    0 => {
                                                        // Bottom-Left
                                                        v.u = 0.0;
                                                        v.v = 1.0;
                                                    },
                                                    1 => {
                                                        // Bottom-Right
                                                        v.u = 1.0;
                                                        v.v = 1.0;
                                                    },
                                                    2 => {
                                                        // Top-Right
                                                        v.u = 1.0;
                                                        v.v = 0.0;
                                                    },
                                                    3 => {
                                                        // Top-Left
                                                        v.u = 0.0;
                                                        v.v = 0.0;
                                                    },
                                                    else => {
                                                        v.u = 0.0;
                                                        v.v = 0.0;
                                                    },
                                                }
                                            } else {
                                                v.u = 0;
                                                v.v = 0;
                                            }
                                        }

                                        // Colors
                                        if (data.colors.len > v_i) {
                                            v.color = data.colors[v_i];
                                        } else {
                                            v.color = .{ 1.0, 1.0, 1.0, 1.0 };
                                        }

                                        // Defaults
                                        v.u1 = 0;
                                        v.v1 = 0;
                                        v.bone_weights = .{ 0, 0, 0, 0 };
                                        v.bone_indices = .{ 0, 0, 0, 0 };
                                    }

                                    // Heuristic: Check for all-black vertex colors (common in some legacy NIFs/KFMs)
                                    // If all vertices have 0 alpha or are completely black, we force them to white
                                    // so the textures are visible.
                                    if (data.colors.len > 0 and vertex_count > 0) {
                                        var all_black = true;
                                        var v_check: usize = 0;
                                        while (v_check < vertex_count) : (v_check += 1) {
                                            const v = vertices_ptr[v_check];
                                            // Check if color is non-black (ignore alpha for now, or check alpha too?)
                                            // Usually if it's uninitialized it's 0,0,0,0.
                                            // If it's just black (0,0,0,1), it might be intentional?
                                            // But for legacy assets, 0,0,0,0 is the common failure mode.
                                            if (v.color[0] > 0.001 or v.color[1] > 0.001 or v.color[2] > 0.001) {
                                                all_black = false;
                                                break;
                                            }
                                        }
                                        if (all_black) {
                                            nif_log.warn("Mesh {d} has ALL BLACK vertex colors. Forcing to WHITE.", .{mesh_idx});
                                            var v_fix: usize = 0;
                                            while (v_fix < vertex_count) : (v_fix += 1) {
                                                vertices_ptr[v_fix].color = .{ 1.0, 1.0, 1.0, 1.0 };
                                            }
                                        }
                                    }

                                    mesh.vertices = vertices_ptr;
                                    mesh.vertex_count = @intCast(vertex_count);

                                    // Debug UVs
                                    if (vertex_count > 0) {
                                        const v0 = vertices_ptr[0];
                                        nif_log.info("Mesh {d} UV[0]: {d:.3}, {d:.3}", .{ mesh_idx, v0.u, v0.v });

                                        var found_nonzero = false;
                                        var v_check: usize = 0;
                                        while (v_check < vertex_count) : (v_check += 1) {
                                            const v = vertices_ptr[v_check];
                                            if (v.u != 0.0 or v.v != 0.0) {
                                                nif_log.info("Mesh {d} Found Non-Zero UV at [{d}]: {d:.3}, {d:.3}", .{ mesh_idx, v_check, v.u, v.v });
                                                found_nonzero = true;
                                                break;
                                            }
                                        }
                                        if (!found_nonzero) {
                                            nif_log.warn("Mesh {d} has ALL ZERO UVs!", .{mesh_idx});
                                        }
                                    }
                                }
                            }

                            // Indices
                            const index_count = data.indices.len;
                            if (index_count > 0) {
                                const i_mem = memory.cardinal_alloc(memory.cardinal_get_allocator_for_category(.ASSETS), index_count * 4);
                                if (i_mem) |im| {
                                    const indices_ptr = @as([*]u32, @ptrCast(@alignCast(im)));
                                    @memcpy(indices_ptr[0..index_count], data.indices);
                                    mesh.indices = indices_ptr;
                                    mesh.index_count = @intCast(index_count);
                                }
                            }
                        }
                    }
                    mesh_idx += 1;
                }
            }

            // Copy materials to scene
            out_scene.material_count = @intCast(material_list.items.len);
            const mats_ptr = memory.cardinal_calloc(memory.cardinal_get_allocator_for_category(.ASSETS), out_scene.material_count, @sizeOf(scene.CardinalMaterial));
            out_scene.materials = @ptrCast(@alignCast(mats_ptr));
            if (out_scene.materials) |mats| {
                for (material_list.items, 0..) |m, mi| {
                    mats[mi] = m;
                }
            }

            // Copy textures to scene
            out_scene.texture_count = @intCast(texture_list.items.len);
            if (out_scene.texture_count > 0) {
                const texs_ptr = memory.cardinal_calloc(memory.cardinal_get_allocator_for_category(.ASSETS), out_scene.texture_count, @sizeOf(scene.CardinalTexture));
                out_scene.textures = @ptrCast(@alignCast(texs_ptr));
                if (out_scene.textures) |texs| {
                    for (texture_list.items, 0..) |t, ti| {
                        texs[ti] = t;
                    }
                }
            }
        }
    }

    if (out_scene.root_node_count == 0 and out_scene.mesh_count == 0) {
        nif_log.warn("NIF load resulted in empty scene (no nodes or meshes)", .{});
        return false;
    }
    return true;
}

pub export fn cardinal_nif_merge_kf(path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool {
    nif_log.warn("Merging KF animation: {s}", .{path});

    const file = std.fs.cwd().openFileZ(path, .{}) catch |err| {
        nif_log.err("Failed to open KF file: {s}", .{@errorName(err)});
        return false;
    };
    defer file.close();

    const size = file.getEndPos() catch 0;
    if (size == 0) return false;

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const asset_allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    const buffer = allocator.alloc(u8, size) catch return false;
    defer allocator.free(buffer);

    _ = file.readAll(buffer) catch return false;

    var reader = NifReader.init(allocator, buffer);
    defer reader.deinit();

    reader.parse_header() catch |err| {
        nif_log.err("Failed to parse KF header: {s}", .{@errorName(err)});
        return false;
    };

    reader.parse_blocks() catch |err| {
        nif_log.err("Failed to parse KF blocks: {s}", .{@errorName(err)});
        return false;
    };

    // Initialize Animation System if needed
    if (out_scene.animation_system == null) {
        const sys = memory.cardinal_alloc(asset_allocator, @sizeOf(animation.CardinalAnimationSystem));
        if (sys) |s| {
            const system = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(s)));
            system.* = std.mem.zeroes(animation.CardinalAnimationSystem);
            out_scene.animation_system = @ptrCast(system);
        } else {
            return false;
        }
    }
    const anim_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(out_scene.animation_system.?)));

    // Collect Sequences
    var anim_list = std.ArrayListUnmanaged(animation.CardinalAnimation){};
    defer anim_list.deinit(allocator);

    // If we already have animations, we should copy them?
    // For now, assuming fresh start or append.

    var i: usize = 0;
    while (i < reader.header.num_blocks) : (i += 1) {
        const block = &reader.blocks[i];
        const type_name = reader.header.block_types[block.type_index];

        if (std.mem.eql(u8, type_name, "NiControllerSequence") and block.parsed != null) {
            const seq = @as(*NiControllerSequence, @ptrCast(@alignCast(block.parsed.?)));

            var card_anim = std.mem.zeroes(animation.CardinalAnimation);

            // Name
            if (seq.name_index >= 0 and seq.name_index < reader.header.num_strings) {
                const s = reader.header.strings[@intCast(seq.name_index)];
                const name_ptr = memory.cardinal_alloc(asset_allocator, s.len + 1);
                if (name_ptr) |np| {
                    const name_slice = @as([*]u8, @ptrCast(np))[0 .. s.len + 1];
                    @memcpy(name_slice[0..s.len], s);
                    name_slice[s.len] = 0;
                    card_anim.name = @ptrCast(np);
                }
            }
            card_anim.duration = seq.stop_time - seq.start_time;

            // Channels/Samplers
            var samplers = std.ArrayListUnmanaged(animation.CardinalAnimationSampler){};
            defer samplers.deinit(allocator);
            var channels = std.ArrayListUnmanaged(animation.CardinalAnimationChannel){};
            defer channels.deinit(allocator);

            for (seq.controlled_blocks) |cb| {
                // Find Target Node
                var target_node_index: u32 = 0xFFFFFFFF;
                if (cb.node_name_index >= 0 and cb.node_name_index < reader.header.num_strings) {
                    const node_name = reader.header.strings[@intCast(cb.node_name_index)];

                    // Search in scene
                    // This is slow (O(N)), but scene load is one-time.
                    if (out_scene.all_nodes) |nodes| {
                        var n_i: u32 = 0;
                        while (n_i < out_scene.all_node_count) : (n_i += 1) {
                            if (nodes[n_i]) |node| {
                                if (node.name) |nn| {
                                    if (std.mem.eql(u8, std.mem.span(nn), node_name)) {
                                        target_node_index = n_i;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                if (target_node_index != 0xFFFFFFFF) {
                    // Found node. Now get interpolator data.
                    if (cb.interpolator_ref >= 0 and cb.interpolator_ref < reader.header.num_blocks) {
                        const interp_block = &reader.blocks[@intCast(cb.interpolator_ref)];
                        // Assuming NiTransformInterpolator
                        if (std.mem.eql(u8, reader.header.block_types[interp_block.type_index], "NiTransformInterpolator") and interp_block.parsed != null) {
                            const interp = @as(*NiTransformInterpolator, @ptrCast(@alignCast(interp_block.parsed.?)));

                            if (interp.data_ref >= 0 and interp.data_ref < reader.header.num_blocks) {
                                const data_block = &reader.blocks[@intCast(interp.data_ref)];
                                if (std.mem.eql(u8, reader.header.block_types[data_block.type_index], "NiTransformData") and data_block.parsed != null) {
                                    const data = @as(*NiTransformData, @ptrCast(@alignCast(data_block.parsed.?)));

                                    // Create Samplers
                                    // Translation
                                    if (data.num_trans_keys > 0) {
                                        const s_idx = samplers.items.len;
                                        var sampler = std.mem.zeroes(animation.CardinalAnimationSampler);
                                        sampler.input_count = data.num_trans_keys;
                                        sampler.output_count = data.num_trans_keys * 3; // Vec3

                                        // Allocate data in asset memory
                                        const input_ptr = memory.cardinal_alloc(asset_allocator, sampler.input_count * 4);
                                        const output_ptr = memory.cardinal_alloc(asset_allocator, sampler.output_count * 4);

                                        if (input_ptr != null and output_ptr != null) {
                                            const inputs = @as([*]f32, @ptrCast(@alignCast(input_ptr)));
                                            const outputs = @as([*]f32, @ptrCast(@alignCast(output_ptr)));

                                            for (data.trans_keys, 0..) |k, ki| {
                                                inputs[ki] = k[0]; // Time
                                                outputs[ki * 3 + 0] = k[1];
                                                outputs[ki * 3 + 1] = k[2];
                                                outputs[ki * 3 + 2] = k[3];
                                            }
                                            sampler.input = inputs;
                                            sampler.output = outputs;

                                            samplers.append(allocator, sampler) catch continue;

                                            var channel = std.mem.zeroes(animation.CardinalAnimationChannel);
                                            channel.sampler_index = @intCast(s_idx);
                                            channel.target.node_index = target_node_index;
                                            channel.target.path = .TRANSLATION;
                                            channels.append(allocator, channel) catch continue;
                                        }
                                    }

                                    // Rotation (Quat)
                                    if (data.num_rot_keys > 0) {
                                        const s_idx = samplers.items.len;
                                        var sampler = std.mem.zeroes(animation.CardinalAnimationSampler);
                                        sampler.input_count = data.num_rot_keys;
                                        sampler.output_count = data.num_rot_keys * 4; // Quat

                                        const input_ptr = memory.cardinal_alloc(asset_allocator, sampler.input_count * 4);
                                        const output_ptr = memory.cardinal_alloc(asset_allocator, sampler.output_count * 4);

                                        if (input_ptr != null and output_ptr != null) {
                                            const inputs = @as([*]f32, @ptrCast(@alignCast(input_ptr)));
                                            const outputs = @as([*]f32, @ptrCast(@alignCast(output_ptr)));

                                            for (data.rot_keys, 0..) |k, ki| {
                                                inputs[ki] = k[0]; // Time
                                                // NIF Quat is w,x,y,z? No, usually x,y,z,w.
                                                // My parser reads: time, x, y, z, w.
                                                outputs[ki * 4 + 0] = k[1];
                                                outputs[ki * 4 + 1] = k[2];
                                                outputs[ki * 4 + 2] = k[3];
                                                outputs[ki * 4 + 3] = k[4];
                                            }
                                            sampler.input = inputs;
                                            sampler.output = outputs;

                                            samplers.append(allocator, sampler) catch continue;

                                            var channel = std.mem.zeroes(animation.CardinalAnimationChannel);
                                            channel.sampler_index = @intCast(s_idx);
                                            channel.target.node_index = target_node_index;
                                            channel.target.path = .ROTATION;
                                            channels.append(allocator, channel) catch continue;
                                        }
                                    }

                                    // Scale
                                    if (data.num_scale_keys > 0) {
                                        const s_idx = samplers.items.len;
                                        var sampler = std.mem.zeroes(animation.CardinalAnimationSampler);
                                        sampler.input_count = data.num_scale_keys;
                                        sampler.output_count = data.num_scale_keys; // Float

                                        const input_ptr = memory.cardinal_alloc(asset_allocator, sampler.input_count * 4);
                                        const output_ptr = memory.cardinal_alloc(asset_allocator, sampler.output_count * 4);

                                        if (input_ptr != null and output_ptr != null) {
                                            const inputs = @as([*]f32, @ptrCast(@alignCast(input_ptr)));
                                            const outputs = @as([*]f32, @ptrCast(@alignCast(output_ptr)));

                                            for (data.scale_keys, 0..) |k, ki| {
                                                inputs[ki] = k[0]; // Time
                                                outputs[ki] = k[1];
                                            }
                                            sampler.input = inputs;
                                            sampler.output = outputs;

                                            samplers.append(allocator, sampler) catch continue;

                                            var channel = std.mem.zeroes(animation.CardinalAnimationChannel);
                                            channel.sampler_index = @intCast(s_idx);
                                            channel.target.node_index = target_node_index;
                                            channel.target.path = .SCALE;
                                            channels.append(allocator, channel) catch continue;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Copy Samplers/Channels to Asset Memory
            if (samplers.items.len > 0) {
                const s_ptr = memory.cardinal_alloc(asset_allocator, samplers.items.len * @sizeOf(animation.CardinalAnimationSampler));
                if (s_ptr) |sp| {
                    const s_dest = @as([*]animation.CardinalAnimationSampler, @ptrCast(@alignCast(sp)));
                    @memcpy(s_dest[0..samplers.items.len], samplers.items);
                    card_anim.samplers = s_dest;
                    card_anim.sampler_count = @intCast(samplers.items.len);
                }
            }
            if (channels.items.len > 0) {
                const c_ptr = memory.cardinal_alloc(asset_allocator, channels.items.len * @sizeOf(animation.CardinalAnimationChannel));
                if (c_ptr) |cp| {
                    const c_dest = @as([*]animation.CardinalAnimationChannel, @ptrCast(@alignCast(cp)));
                    @memcpy(c_dest[0..channels.items.len], channels.items);
                    card_anim.channels = c_dest;
                    card_anim.channel_count = @intCast(channels.items.len);
                }
            }

            anim_list.append(allocator, card_anim) catch continue;
        }
    }

    // Add to System
    if (anim_list.items.len > 0) {
        // Extend existing?
        // For now, just replace or add if empty
        if (anim_sys.animation_count == 0) {
            const a_ptr = memory.cardinal_alloc(asset_allocator, anim_list.items.len * @sizeOf(animation.CardinalAnimation));
            if (a_ptr) |ap| {
                const a_dest = @as([*]animation.CardinalAnimation, @ptrCast(@alignCast(ap)));
                @memcpy(a_dest[0..anim_list.items.len], anim_list.items);
                anim_sys.animations = a_dest;
                anim_sys.animation_count = @intCast(anim_list.items.len);
            }
        } else {
            // Append
            const old_count = anim_sys.animation_count;
            const new_count = old_count + @as(u32, @intCast(anim_list.items.len));

            const a_ptr = memory.cardinal_alloc(asset_allocator, new_count * @sizeOf(animation.CardinalAnimation));
            if (a_ptr) |ap| {
                const a_dest = @as([*]animation.CardinalAnimation, @ptrCast(@alignCast(ap)));
                // Copy old
                if (anim_sys.animations) |old| {
                    @memcpy(a_dest[0..old_count], old[0..old_count]);
                    // Free old array? (Assuming allocated with same allocator)
                    memory.cardinal_free(asset_allocator, @ptrCast(old));
                }
                // Copy new
                @memcpy(a_dest[old_count..new_count], anim_list.items);

                anim_sys.animations = a_dest;
                anim_sys.animation_count = new_count;
            }
        }
    }

    return true;
}
