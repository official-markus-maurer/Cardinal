//! Minimal SPIR-V parsing utilities.
//!
//! Provides header validation and an instruction iterator over SPIR-V wordcode.
const std = @import("std");

pub const Header = struct {
    /// Upper bound for result IDs used by the module.
    bound: u32,
};

/// Decoded SPIR-V instruction header + operand view.
pub const Instruction = struct {
    /// SPIR-V opcode (lower 16 bits of the first word).
    opcode: u16,
    /// Total instruction length in 32-bit words (including the header word).
    word_count: u16,
    /// Operand words (excluding the header word).
    operands: []const u32,
};

/// Validates the SPIR-V magic number and returns a parsed header.
pub fn validate(code: []const u32) !Header {
    if (code.len < 5 or code[0] != 0x07230203) return error.InvalidSpirv;
    return .{ .bound = code[3] };
}

/// Iterates SPIR-V instructions starting after the 5-word header.
pub const Iterator = struct {
    code: []const u32,
    index: usize = 5,

    /// Creates an iterator for `code`.
    pub fn init(code: []const u32) Iterator {
        return .{ .code = code, .index = 5 };
    }

    /// Returns the next instruction, or null on end-of-stream or malformed input.
    pub fn next(self: *Iterator) ?Instruction {
        if (self.index >= self.code.len) return null;
        const word = self.code[self.index];
        const count: u16 = @intCast((word >> 16) & 0xFFFF);
        const opcode: u16 = @intCast(word & 0xFFFF);
        if (count == 0) return null;
        const start = self.index + 1;
        const end = self.index + @as(usize, count);
        if (end > self.code.len) return null;
        self.index = end;
        return .{
            .opcode = opcode,
            .word_count = count,
            .operands = self.code[start..end],
        };
    }
};
