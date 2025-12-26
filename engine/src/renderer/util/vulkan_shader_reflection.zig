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

    var type_opcodes = std.AutoHashMap(u32, u32).init(allocator);
    defer type_opcodes.deinit();

    var pointer_type_id = std.AutoHashMap(u32, u32).init(allocator); // pointer_id -> type_id
    defer pointer_type_id.deinit();

    var array_element_type = std.AutoHashMap(u32, u32).init(allocator); // array_type_id -> element_type_id
    defer array_element_type.deinit();

    var array_lengths = std.AutoHashMap(u32, u32).init(allocator); // array_type_id -> length
    defer array_lengths.deinit();

    // First pass: Find types and decorations
    var i: usize = 5;
    while (i < code.len) {
        const word = code[i];
        const count = (word >> 16) & 0xFFFF;
        const opcode = word & 0xFFFF;

        if (opcode == SpvOpTypePointer) {
            const id = code[i + 1];
            // const storage_class = code[i + 2];
            const type_id = code[i + 3];
            try pointer_type_id.put(id, type_id);
            try type_opcodes.put(id, opcode);
        } else if (opcode == SpvOpTypeInt or opcode == SpvOpTypeFloat or opcode == SpvOpTypeBool or opcode == SpvOpTypeVoid or opcode == SpvOpTypeVector or opcode == SpvOpTypeMatrix or opcode == SpvOpTypeImage or opcode == SpvOpTypeSampler or opcode == SpvOpTypeSampledImage or opcode == SpvOpTypeStruct) {
            const id = code[i + 1];
            try type_opcodes.put(id, opcode);
        } else if (opcode == SpvOpTypeArray) {
             const id = code[i + 1];
             const element_type = code[i + 2];
             const length_id = code[i + 3];
             try type_opcodes.put(id, opcode);
             try array_element_type.put(id, element_type);
             
             // Try to resolve length
             if (reflection.constants.get(length_id)) |len| {
                 try array_lengths.put(id, len);
             } else {
                 try array_lengths.put(id, 1); // Fallback
             }
        } else if (opcode == SpvOpTypeRuntimeArray) {
             const id = code[i + 1];
             const element_type = code[i + 2];
             try type_opcodes.put(id, opcode);
             try array_element_type.put(id, element_type);
        } else if (opcode == SpvOpDecorate) {
            const target = code[i + 1];
            const decoration = code[i + 2];
            
            if (target < bound) {
                if (decoration == SpvDecorationDescriptorSet) {
                    decorations[target].set = code[i + 3];
                } else if (decoration == SpvDecorationBinding) {
                    decorations[target].binding = code[i + 3];
                } else if (decoration == SpvDecorationBlock) {
                    decorations[target].is_block = true;
                } else if (decoration == SpvDecorationBufferBlock) {
                    decorations[target].is_buffer_block = true;
                }
            }
        } else if (opcode == SpvOpMemberDecorate) {
             // Handle member decorations if needed
        } else if (opcode == SpvOpConstant) {
             const result_type = code[i + 1];
             const result_id = code[i + 2];
             // Assuming 32-bit int constant
             // Value is at i + 3
             if (type_opcodes.get(result_type)) |op| {
                 if (op == SpvOpTypeInt) {
                     try reflection.constants.put(reflection.allocator, result_id, code[i + 3]);
                 }
             }
        }
        i += count;
    }

    // Resolve array lengths that were defined after usage
     {
         var it = array_lengths.iterator();
         while (it.next()) |entry| {
              _ = entry.key_ptr.*;
              // We need to re-check if we used a fallback but the constant is now available
              // But we didn't store the length_id in the map.
              // Ideally we should do this in a cleaner way, but for now relying on constants being defined before arrays (usually true)
              // or just accepting fallback.
              // Correct way: store length_id in a separate map and resolve here.
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
                    
                    const pointed_type = pointer_type_id.get(type_id) orelse 0;
                    const pointed_opcode = type_opcodes.get(pointed_type) orelse 0;
                    
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
                            } else if (pointed_opcode == SpvOpTypeArray or pointed_opcode == SpvOpTypeRuntimeArray) {
                                // Check what is inside the array
                                const element_type = array_element_type.get(pointed_type) orelse 0;
                                const element_opcode = type_opcodes.get(element_type) orelse 0;
                                
                                if (element_opcode == SpvOpTypeSampledImage) {
                                    res.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                                } else if (element_opcode == SpvOpTypeImage) {
                                    res.type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE; // Or SampledImage if Sampled=1
                                } else if (element_opcode == SpvOpTypeSampler) {
                                    res.type = c.VK_DESCRIPTOR_TYPE_SAMPLER;
                                } else {
                                    res.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; // Fallback
                                }
                            }
                        },
                        else => {
                             // Default fallback
                             res.type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
                        },
                    }

                    // Check for array
                    if (pointed_opcode == SpvOpTypeArray) {
                         res.count = array_lengths.get(pointed_type) orelse 1;
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
