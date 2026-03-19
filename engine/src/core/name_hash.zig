//! Shared name hashing helpers.
//!
//! Centralizes string hashing so systems can agree on identifiers and avoid
//! duplicating hash implementations.
const std = @import("std");

/// Returns a 64-bit Wyhash of `name` (seed 0).
pub fn hash_u64_wyhash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}

/// Returns a 32-bit Wyhash of `name` (seed 0, truncated).
pub fn hash_u32_wyhash(name: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, name));
}

/// Returns a 32-bit FNV-1a hash of `name`.
pub fn hash_u32_fnv1a(name: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (name) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return hash;
}
