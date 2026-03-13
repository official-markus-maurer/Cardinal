//! Stable handle types used across engine systems.
//!
//! Handles are plain-data (C-ABI-friendly) and typically refer to entries stored in a typed
//! registry (e.g. texture manager or asset manager). Each handle contains an index plus a
//! generation counter to invalidate stale references.
const std = @import("std");

/// Handle to a texture entry.
pub const TextureHandle = extern struct {
    index: u32,
    generation: u32,

    pub const INVALID = TextureHandle{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn is_valid(self: TextureHandle) bool {
        return self.index != std.math.maxInt(u32);
    }
};

/// Handle to a mesh entry.
pub const MeshHandle = extern struct {
    index: u32,
    generation: u32,

    pub const INVALID = MeshHandle{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn is_valid(self: MeshHandle) bool {
        return self.index != std.math.maxInt(u32);
    }
};

/// Handle to a material entry.
pub const MaterialHandle = extern struct {
    index: u32,
    generation: u32,

    pub const INVALID = MaterialHandle{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn is_valid(self: MaterialHandle) bool {
        return self.index != std.math.maxInt(u32);
    }
};

/// Handle for tracking async operations in handle-based systems.
pub const AsyncHandle = extern struct {
    index: u32,
    generation: u32,

    pub const INVALID = AsyncHandle{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn is_valid(self: AsyncHandle) bool {
        return self.index != std.math.maxInt(u32);
    }
};
