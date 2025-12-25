const std = @import("std");
const c = @import("../vulkan_c.zig").c;
const log = @import("../../core/log.zig");

// SPIR-V Opcodes
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

// SPIR-V Decorations
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

// SPIR-V Storage Classes
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

pub const ShaderResource = struct {
    set: u32,
    binding: u32,
    type: c.VkDescriptorType,
    count: u32,
    stage_flags: c.VkShaderStageFlags,
    name: []const u8,
    is_runtime_array: bool,
};

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

const IdDecoration = struct {
    set: ?u32 = null,
    binding: ?u32 = null,
    location: ?u32 = null,
    is_block: bool = false,
    is_buffer_block: bool = false,
};

pub fn reflect_shader(allocator: std.mem.Allocator, code: []const u32, stage: c.VkShaderStageFlags) !ShaderReflection {
    var reflection = ShaderReflection.init(allocator);
    errdefer reflection.deinit();

    // Basic validation
    if (code.len < 5 or code[0] != 0x07230203) {
        log.cardinal_log_error("Invalid SPIR-V magic number", .{});
        return error.InvalidSpirv;
    }

    const bound = code[3];
    var decorations = try allocator.alloc(IdDecoration, bound);
    defer allocator.free(decorations);
    @memset(decorations, .{});

    // Store type information: id -> opcode
    var type_opcodes = try allocator.alloc(u16, bound);
    defer allocator.free(type_opcodes);
    @memset(type_opcodes, 0);

    // Store storage class for pointers: id -> storage_class
    var pointer_storage_class = try allocator.alloc(u32, bound);
    defer allocator.free(pointer_storage_class);
    @memset(pointer_storage_class, 0);

    // Store pointed type for pointers: id -> type_id
    var pointer_type_id = try allocator.alloc(u32, bound);
    defer allocator.free(pointer_type_id);
    @memset(pointer_type_id, 0);

    // Store array element count: id -> count (if array)
    var array_lengths = try allocator.alloc(u32, bound);
    defer allocator.free(array_lengths);
    @memset(array_lengths, 0);

    // First pass: Collect decorations, types, and constants
    var i: usize = 5;
    while (i < code.len) {
        const word = code[i];
        const count = (word >> 16) & 0xFFFF;
        const opcode = word & 0xFFFF;

        if (i + count > code.len) break;

        switch (opcode) {
            SpvOpDecorate => {
                const target = code[i + 1];
                const decoration = code[i + 2];
                if (target < bound) {
                    switch (decoration) {
                        SpvDecorationDescriptorSet => decorations[target].set = code[i + 3],
                        SpvDecorationBinding => decorations[target].binding = code[i + 3],
                        SpvDecorationLocation => decorations[target].location = code[i + 3],
                        SpvDecorationBlock => decorations[target].is_block = true,
                        SpvDecorationBufferBlock => decorations[target].is_buffer_block = true,
                        else => {},
                    }
                }
            },
            SpvOpTypeStruct, SpvOpTypeImage, SpvOpTypeSampledImage, SpvOpTypeSampler, SpvOpTypeRuntimeArray => {
                const id = code[i + 1];
                if (id < bound) {
                    type_opcodes[id] = @intCast(opcode);
                }
            },
            SpvOpTypeArray => {
                const id = code[i + 1];
                // const element_type = code[i + 2];
                const length_id = code[i + 3];
                if (id < bound) {
                    type_opcodes[id] = @intCast(opcode);
                    // Defer length resolution until we have constants
                    array_lengths[id] = length_id; 
                }
            },
            SpvOpTypePointer => {
                const id = code[i + 1];
                const storage_class = code[i + 2];
                const type_id = code[i + 3];
                if (id < bound) {
                    type_opcodes[id] = SpvOpTypePointer;
                    pointer_storage_class[id] = storage_class;
                    pointer_type_id[id] = type_id;
                }
            },
            SpvOpConstant => {
                // ResultType = code[i+1]
                const id = code[i + 2];
                const val = code[i + 3]; // Assuming 32-bit int
                try reflection.constants.put(reflection.allocator, id, val);
            },
            else => {},
        }
        i += count;
    }

    // Resolve array lengths
    for (type_opcodes, 0..) |op, id| {
        if (op == SpvOpTypeArray) {
             const len_id = array_lengths[id];
             if (reflection.constants.get(len_id)) |len| {
                 array_lengths[id] = len;
             } else {
                 array_lengths[id] = 1; // Fallback
             }
        }
    }

    // Second pass: Find variables
    i = 5;
    while (i < code.len) {
        const word = code[i];
        const count = (word >> 16) & 0xFFFF;
        const opcode = word & 0xFFFF;

        if (opcode == SpvOpVariable) {
            const type_id = code[i + 1];
            const id = code[i + 2];
            const storage_class = code[i + 3];

            if (id < bound and type_id < bound) {
                const dec = decorations[id];
                if (dec.set != null and dec.binding != null) {
                    // It's a resource
                    var res = std.mem.zeroes(ShaderResource);
                    res.set = dec.set.?;
                    res.binding = dec.binding.?;
                    res.stage_flags = stage;
                    res.count = 1; // Default to 1

                    // Determine descriptor type
                    // const storage_class = pointer_storage_class[type_id]; // This was from pointer type, but variable has storage class too
                    // Actually SpvOpVariable has storage class operand.
                    // pointer_storage_class map was built from SpvOpTypePointer.
                    // type_id of Variable is a Pointer Type.
                    
                    const pointed_type = pointer_type_id[type_id];
                    const pointed_opcode = if (pointed_type < bound) type_opcodes[pointed_type] else 0;
                    
                    // Check for block decoration on struct
                    const is_buffer_block = if (pointed_type < bound) decorations[pointed_type].is_buffer_block else false;

                    switch (storage_class) {
                        SpvStorageClassUniform => {
                            if (is_buffer_block) {
                                res.type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
                            } else {
                                res.type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
                            }
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
                            } else if (pointed_opcode == SpvOpTypeArray) {
                                // Check what is inside the array
                                // pointer_type_id[type_id] is the array type
                                // We need the element type of the array
                                // For now, let's assume Combined Image Sampler array as it is the most common
                                res.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                            }
                        },
                        else => {
                             // Default fallback
                             res.type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
                        },
                    }

                    // Check for array
                    if (pointed_opcode == SpvOpTypeArray) {
                         res.count = array_lengths[pointed_type];
                    } else if (pointed_opcode == SpvOpTypeRuntimeArray) {
                         // Bindless/Runtime array
                         res.count = 4096; // Default large size for bindless
                         res.is_runtime_array = true;
                    }

                    try reflection.resources.append(reflection.allocator, res);
                } else if (storage_class == SpvStorageClassPushConstant) {
                    reflection.push_constant_stages |= stage;
                    // Ideally calculate size, but for now we just mark stage
                    // and use a default size if we can't calculate it easily.
                    // Or we can update the size if we find a larger one.
                    if (reflection.push_constant_size == 0) reflection.push_constant_size = 256; // Default safe size
                }
            }
        }
        i += count;
    }

    return reflection;
}
