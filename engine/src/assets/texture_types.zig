//! Texture loader shared ABI types.
pub const TextureData = extern struct {
    data: ?[*]u8,
    width: u32,
    height: u32,
    channels: u32,
    is_hdr: u32,
    format: u32,
    data_size: u64,
};
