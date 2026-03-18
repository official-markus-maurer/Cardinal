//! Texture loader shared ABI types.
//!
//! These structs are used by the C-facing texture loaders and passed across subsystem
//! boundaries, so their layout should remain stable.

/// Decoded texture payload with metadata and a raw byte buffer.
pub const TextureData = extern struct {
    /// Pointer to decoded pixel data (owned by the loader that produced it).
    data: ?[*]u8,
    width: u32,
    height: u32,
    /// Number of channels in the decoded buffer.
    channels: u32,
    /// Non-zero when the decoded buffer contains HDR data.
    is_hdr: u32,
    /// Vulkan `VkFormat` encoded as `u32`.
    format: u32,
    /// Total size in bytes of `data`.
    data_size: u64,
};
