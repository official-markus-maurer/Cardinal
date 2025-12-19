const std = @import("std");

pub const TextureHandle = extern struct {
    index: u32,
    generation: u32,

    pub const INVALID = TextureHandle{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn is_valid(self: TextureHandle) bool {
        return self.index != std.math.maxInt(u32);
    }
};

pub const MeshHandle = extern struct {
    index: u32,
    generation: u32,

    pub const INVALID = MeshHandle{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn is_valid(self: MeshHandle) bool {
        return self.index != std.math.maxInt(u32);
    }
};

pub const MaterialHandle = extern struct {
    index: u32,
    generation: u32,

    pub const INVALID = MaterialHandle{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn is_valid(self: MaterialHandle) bool {
        return self.index != std.math.maxInt(u32);
    }
};
