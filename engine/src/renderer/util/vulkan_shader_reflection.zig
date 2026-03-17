//! SPIR-V shader reflection utilities.
//!
//! Implements a small SPIR-V parser that extracts descriptor set/binding usage, push constant
//! ranges, and specialization constants without relying on external reflection libraries.
const std = @import("std");
const c = @import("../vulkan_c.zig").c;
const log = @import("../../core/log.zig");
const spirv = @import("spirv_parser.zig");

const reflect_log = log.ScopedLogger("SHADER_REFLECT");

/// SPIR-V opcodes used by the parser.
const SpvOpName = 5;
const SpvOpMemberName = 6;
const SpvOpEntryPoint = 15;
const SpvOpTypeVoid = 19;
const SpvOpTypeBool = 20;
const SpvOpTypeInt = 21;
const SpvOpTypeFloat = 22;
const SpvOpTypeVector = 23;
const SpvOpTypeMatrix = 24;
const SpvOpTypeImage = 25;
const SpvOpTypeSampler = 26;
const SpvOpTypeSampledImage = 27;
const SpvOpTypeArray = 28;
const SpvOpTypeRuntimeArray = 29;
const SpvOpTypeStruct = 30;
const SpvOpTypePointer = 32;
const SpvOpConstant = 43;
const SpvOpVariable = 59;
const SpvOpDecorate = 71;
const SpvOpMemberDecorate = 72;

/// SPIR-V decoration enums used by the parser.
const SpvDecorationSpecId = 1;
const SpvDecorationBlock = 2;
const SpvDecorationBufferBlock = 3;
const SpvDecorationRowMajor = 4;
const SpvDecorationColMajor = 5;
const SpvDecorationArrayStride = 6;
const SpvDecorationMatrixStride = 7;
const SpvDecorationBuiltIn = 11;
const SpvDecorationNoPerspective = 13;
const SpvDecorationFlat = 14;
const SpvDecorationPatch = 15;
const SpvDecorationLocation = 30;
const SpvDecorationBinding = 33;
const SpvDecorationDescriptorSet = 34;
const SpvDecorationOffset = 35;

/// SPIR-V storage class enums used by the parser.
const SpvStorageClassUniformConstant = 0;
const SpvStorageClassInput = 1;
const SpvStorageClassUniform = 2;
const SpvStorageClassOutput = 3;
const SpvStorageClassWorkgroup = 4;
const SpvStorageClassCrossWorkgroup = 5;
const SpvStorageClassPrivate = 6;
const SpvStorageClassFunction = 7;
const SpvStorageClassGeneric = 8;
const SpvStorageClassPushConstant = 9;
const SpvStorageClassAtomicCounter = 10;
const SpvStorageClassImage = 11;
const SpvStorageClassStorageBuffer = 12;

/// One descriptor-backed shader resource (descriptor sets/bindings).
pub const ShaderResource = struct {
    set: u32,
    binding: u32,
    type: c.VkDescriptorType,
    count: u32,
    stage_flags: c.VkShaderStageFlags,
    name: []const u8,
    is_runtime_array: bool,
};

/// Reflection results extracted from SPIR-V bytecode.
pub const ShaderReflection = struct {
    resources: std.ArrayListUnmanaged(ShaderResource),
    push_constant_size: u32,
    push_constant_stages: c.VkShaderStageFlags,
    constants: std.AutoHashMapUnmanaged(u32, u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShaderReflection {
        return .{
            .resources = .{},
            .push_constant_size = 0,
            .push_constant_stages = 0,
            .constants = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ShaderReflection) void {
        self.resources.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }
};

/// Controls reflection defaults for runtime arrays and fallback sizes.
pub const ShaderReflectionOptions = struct {
    runtime_array_max_count: u32 = 4096,
    fallback_push_constant_size: u32 = 256,
};

const IdDecoration = struct {
    set: ?u32 = null,
    binding: ?u32 = null,
    location: ?u32 = null,
    is_block: bool = false,
    is_buffer_block: bool = false,
};

const MemberKey = u64;

const VectorType = struct { component_type: u32, count: u32 };
const MatrixType = struct { column_type: u32, count: u32 };

fn member_key(type_id: u32, member_index: u32) MemberKey {
    return (@as(u64, type_id) << 32) | @as(u64, member_index);
}

fn type_size_bytes(
    type_id: u32,
    type_opcodes_map: *const std.AutoHashMap(u32, u32),
    type_int_width_map: *const std.AutoHashMap(u32, u32),
    type_float_width_map: *const std.AutoHashMap(u32, u32),
    type_vector_map: *const std.AutoHashMap(u32, VectorType),
    type_matrix_map: *const std.AutoHashMap(u32, MatrixType),
    struct_members_map: *const std.AutoHashMap(u32, []const u32),
    array_elem_map: *const std.AutoHashMap(u32, u32),
    array_len_map: *const std.AutoHashMap(u32, u32),
    array_stride_map: *const std.AutoHashMap(u32, u32),
    member_offsets_map: *const std.AutoHashMap(MemberKey, u32),
    member_matrix_stride_map: *const std.AutoHashMap(MemberKey, u32),
) u32 {
    const opcode = type_opcodes_map.get(type_id) orelse 0;
    if (opcode == SpvOpTypeBool) return 4;
    if (opcode == SpvOpTypeInt) {
        const w = type_int_width_map.get(type_id) orelse 32;
        return @intCast((w + 7) / 8);
    }
    if (opcode == SpvOpTypeFloat) {
        const w = type_float_width_map.get(type_id) orelse 32;
        return @intCast((w + 7) / 8);
    }
    if (opcode == SpvOpTypeVector) {
        const v = type_vector_map.get(type_id) orelse return 0;
        const elem = type_size_bytes(v.component_type, type_opcodes_map, type_int_width_map, type_float_width_map, type_vector_map, type_matrix_map, struct_members_map, array_elem_map, array_len_map, array_stride_map, member_offsets_map, member_matrix_stride_map);
        return elem * v.count;
    }
    if (opcode == SpvOpTypeMatrix) {
        const m = type_matrix_map.get(type_id) orelse return 0;
        const col_size = type_size_bytes(m.column_type, type_opcodes_map, type_int_width_map, type_float_width_map, type_vector_map, type_matrix_map, struct_members_map, array_elem_map, array_len_map, array_stride_map, member_offsets_map, member_matrix_stride_map);
        return col_size * m.count;
    }
    if (opcode == SpvOpTypeArray) {
        const elem = array_elem_map.get(type_id) orelse 0;
        const len = array_len_map.get(type_id) orelse 0;
        const elem_size = type_size_bytes(elem, type_opcodes_map, type_int_width_map, type_float_width_map, type_vector_map, type_matrix_map, struct_members_map, array_elem_map, array_len_map, array_stride_map, member_offsets_map, member_matrix_stride_map);
        if (array_stride_map.get(type_id)) |stride| {
            return stride * len;
        }
        return elem_size * len;
    }
    if (opcode == SpvOpTypeStruct) {
        const members = struct_members_map.get(type_id) orelse return 0;
        var max_end: u32 = 0;
        var mi: u32 = 0;
        while (mi < members.len) : (mi += 1) {
            const member_type = members[mi];
            const base_off = member_offsets_map.get(member_key(type_id, mi)) orelse 0;
            var member_size = type_size_bytes(member_type, type_opcodes_map, type_int_width_map, type_float_width_map, type_vector_map, type_matrix_map, struct_members_map, array_elem_map, array_len_map, array_stride_map, member_offsets_map, member_matrix_stride_map);
            if (member_matrix_stride_map.get(member_key(type_id, mi))) |stride| {
                const mop = type_opcodes_map.get(member_type) orelse 0;
                if (mop == SpvOpTypeMatrix) {
                    const mat = type_matrix_map.get(member_type) orelse return 0;
                    member_size = stride * mat.count;
                }
            }
            const end = base_off + member_size;
            if (end > max_end) max_end = end;
        }
        return max_end;
    }
    return 0;
}

/// Reflects descriptor usage and push constants from SPIR-V `code`.
pub fn reflect_shader(allocator: std.mem.Allocator, code: []const u32, stage: c.VkShaderStageFlags) !ShaderReflection {
    return reflect_shader_with_options(allocator, code, stage, .{});
}

/// Reflects shader resources using explicit options for runtime arrays and fallbacks.
pub fn reflect_shader_with_options(allocator: std.mem.Allocator, code: []const u32, stage: c.VkShaderStageFlags, options: ShaderReflectionOptions) !ShaderReflection {
    var reflection = ShaderReflection.init(allocator);
    errdefer reflection.deinit();

    const header = spirv.validate(code) catch {
        reflect_log.err("Invalid SPIR-V magic number", .{});
        return error.InvalidSpirv;
    };
    const bound = header.bound;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tmp_alloc = arena.allocator();

    var decorations = try tmp_alloc.alloc(IdDecoration, bound);
    @memset(decorations, .{});

    var type_opcodes = std.AutoHashMap(u32, u32).init(tmp_alloc);
    var pointer_type_id = std.AutoHashMap(u32, u32).init(tmp_alloc);
    var pointer_storage_class = std.AutoHashMap(u32, u32).init(tmp_alloc);
    var array_element_type = std.AutoHashMap(u32, u32).init(tmp_alloc);
    var array_length_ids = std.AutoHashMap(u32, u32).init(tmp_alloc);
    var struct_member_types = std.AutoHashMap(u32, []const u32).init(tmp_alloc);

    var member_offsets = std.AutoHashMap(MemberKey, u32).init(tmp_alloc);
    var member_matrix_stride = std.AutoHashMap(MemberKey, u32).init(tmp_alloc);
    var array_stride = std.AutoHashMap(u32, u32).init(tmp_alloc);

    var type_int_width = std.AutoHashMap(u32, u32).init(tmp_alloc);
    var type_float_width = std.AutoHashMap(u32, u32).init(tmp_alloc);
    var type_vector = std.AutoHashMap(u32, VectorType).init(tmp_alloc);
    var type_matrix = std.AutoHashMap(u32, MatrixType).init(tmp_alloc);

    var it = spirv.Iterator.init(code);
    while (it.next()) |ins| {
        const opcode = ins.opcode;
        const ops = ins.operands;

        if (opcode == SpvOpTypePointer and ops.len >= 3) {
            const id = ops[0];
            const storage_class = ops[1];
            const type_id = ops[2];
            try pointer_type_id.put(id, type_id);
            try pointer_storage_class.put(id, storage_class);
            try type_opcodes.put(id, opcode);
        } else if (opcode == SpvOpTypeInt and ops.len >= 3) {
            const id = ops[0];
            try type_opcodes.put(id, opcode);
            try type_int_width.put(id, ops[1]);
        } else if (opcode == SpvOpTypeFloat and ops.len >= 2) {
            const id = ops[0];
            try type_opcodes.put(id, opcode);
            try type_float_width.put(id, ops[1]);
        } else if (opcode == SpvOpTypeBool or opcode == SpvOpTypeVoid or opcode == SpvOpTypeImage or opcode == SpvOpTypeSampler or opcode == SpvOpTypeSampledImage) {
            if (ops.len >= 1) try type_opcodes.put(ops[0], opcode);
        } else if (opcode == SpvOpTypeVector and ops.len >= 3) {
            const id = ops[0];
            try type_opcodes.put(id, opcode);
            try type_vector.put(id, .{ .component_type = ops[1], .count = ops[2] });
        } else if (opcode == SpvOpTypeMatrix and ops.len >= 3) {
            const id = ops[0];
            try type_opcodes.put(id, opcode);
            try type_matrix.put(id, .{ .column_type = ops[1], .count = ops[2] });
        } else if (opcode == SpvOpTypeStruct and ops.len >= 1) {
            const id = ops[0];
            try type_opcodes.put(id, opcode);
            const members = try tmp_alloc.dupe(u32, ops[1..]);
            try struct_member_types.put(id, members);
        } else if (opcode == SpvOpTypeArray and ops.len >= 3) {
            const id = ops[0];
            try type_opcodes.put(id, opcode);
            try array_element_type.put(id, ops[1]);
            try array_length_ids.put(id, ops[2]);
        } else if (opcode == SpvOpTypeRuntimeArray and ops.len >= 2) {
            const id = ops[0];
            try type_opcodes.put(id, opcode);
            try array_element_type.put(id, ops[1]);
        } else if (opcode == SpvOpDecorate and ops.len >= 3) {
            const target = ops[0];
            const decoration = ops[1];
            if (target < bound) {
                if (decoration == SpvDecorationDescriptorSet) {
                    decorations[target].set = ops[2];
                } else if (decoration == SpvDecorationBinding) {
                    decorations[target].binding = ops[2];
                } else if (decoration == SpvDecorationBlock) {
                    decorations[target].is_block = true;
                } else if (decoration == SpvDecorationBufferBlock) {
                    decorations[target].is_buffer_block = true;
                } else if (decoration == SpvDecorationArrayStride) {
                    try array_stride.put(target, ops[2]);
                }
            }
        } else if (opcode == SpvOpMemberDecorate and ops.len >= 4) {
            const struct_id = ops[0];
            const member = ops[1];
            const decoration = ops[2];
            if (decoration == SpvDecorationOffset) {
                try member_offsets.put(member_key(struct_id, member), ops[3]);
            } else if (decoration == SpvDecorationMatrixStride) {
                try member_matrix_stride.put(member_key(struct_id, member), ops[3]);
            }
        } else if (opcode == SpvOpConstant and ops.len >= 3) {
            const result_id = ops[1];
            try reflection.constants.put(reflection.allocator, result_id, ops[2]);
        }
    }

    var array_lengths = std.AutoHashMap(u32, u32).init(tmp_alloc);
    var al_it = array_length_ids.iterator();
    while (al_it.next()) |kv| {
        const array_id = kv.key_ptr.*;
        const len_id = kv.value_ptr.*;
        if (reflection.constants.get(len_id)) |len| {
            try array_lengths.put(array_id, len);
        }
    }

    it = spirv.Iterator.init(code);
    while (it.next()) |ins| {
        if (ins.opcode != SpvOpVariable or ins.operands.len < 3) continue;
        const type_id = ins.operands[0];
        const id = ins.operands[1];
        const storage_class = ins.operands[2];

        if (id >= bound) continue;
        const dec = decorations[id];

        if (dec.set != null and dec.binding != null) {
            var res = std.mem.zeroes(ShaderResource);
            res.set = dec.set.?;
            res.binding = dec.binding.?;
            res.stage_flags = stage;
            res.count = 1;

            const pointed_type = pointer_type_id.get(type_id) orelse 0;
            const pointed_opcode = type_opcodes.get(pointed_type) orelse 0;
            const is_buffer_block = if (pointed_type < bound) decorations[pointed_type].is_buffer_block else false;

            switch (storage_class) {
                SpvStorageClassUniform => {
                    res.type = if (is_buffer_block) c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER else c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
                },
                SpvStorageClassStorageBuffer => {
                    res.type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
                },
                SpvStorageClassUniformConstant => {
                    if (pointed_opcode == SpvOpTypeImage) {
                        res.type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
                    } else if (pointed_opcode == SpvOpTypeSampledImage) {
                        res.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                    } else if (pointed_opcode == SpvOpTypeSampler) {
                        res.type = c.VK_DESCRIPTOR_TYPE_SAMPLER;
                    } else if (pointed_opcode == SpvOpTypeArray or pointed_opcode == SpvOpTypeRuntimeArray) {
                        const element_type = array_element_type.get(pointed_type) orelse 0;
                        const element_opcode = type_opcodes.get(element_type) orelse 0;

                        if (element_opcode == SpvOpTypeSampledImage) {
                            res.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                        } else if (element_opcode == SpvOpTypeImage) {
                            res.type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
                        } else if (element_opcode == SpvOpTypeSampler) {
                            res.type = c.VK_DESCRIPTOR_TYPE_SAMPLER;
                        } else {
                            res.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                        }
                    }
                },
                else => {
                    res.type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
                },
            }

            if (pointed_opcode == SpvOpTypeArray) {
                res.count = array_lengths.get(pointed_type) orelse 1;
            } else if (pointed_opcode == SpvOpTypeRuntimeArray) {
                res.count = options.runtime_array_max_count;
                res.is_runtime_array = true;
            }

            try reflection.resources.append(reflection.allocator, res);
            continue;
        }

        const pointer_storage = pointer_storage_class.get(type_id) orelse storage_class;
        if (pointer_storage == SpvStorageClassPushConstant) {
            reflection.push_constant_stages |= stage;
            const pointed_type = pointer_type_id.get(type_id) orelse 0;
            const computed = type_size_bytes(pointed_type, &type_opcodes, &type_int_width, &type_float_width, &type_vector, &type_matrix, &struct_member_types, &array_element_type, &array_lengths, &array_stride, &member_offsets, &member_matrix_stride);
            const final_size = if (computed != 0) computed else options.fallback_push_constant_size;
            if (final_size > reflection.push_constant_size) reflection.push_constant_size = final_size;
        }
    }

    return reflection;
}
