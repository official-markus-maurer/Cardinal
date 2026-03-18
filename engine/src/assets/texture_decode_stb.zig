//! stb_image-backed texture decoding.
//!
//! Decodes common LDR/HDR image formats from an in-memory buffer into RGBA8 or RGBA32F.
//! The returned pixel pointer is owned by stb and must be released with `free_pixels`.
const std = @import("std");
const log = @import("../core/log.zig");
const types = @import("texture_types.zig");
const vk_formats = @import("../renderer/vulkan_format_constants.zig");

const decode_log = log.ScopedLogger("TEX_STB");

extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbi_failure_reason() ?[*]const u8;
extern fn stbi_is_hdr_from_memory(buffer: [*]const u8, len: c_int) c_int;
extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_loadf_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]f32;

/// Frees a pixel buffer returned by `decode_from_memory`.
pub fn free_pixels(pixels: ?*anyopaque) void {
    stbi_image_free(pixels);
}

/// Decodes an image blob into `out_texture`.
///
/// The returned `out_texture.data` is stb-owned and must be freed with `free_pixels`.
pub fn decode_from_memory(data: [*]const u8, size: usize, out_texture: *types.TextureData) bool {
    var w: c_int = 0;
    var h: c_int = 0;
    var c: c_int = 0;

    const is_hdr = (stbi_is_hdr_from_memory(data, @intCast(size)) != 0);

    var pixels: ?*anyopaque = null;
    if (is_hdr) {
        pixels = @ptrCast(stbi_loadf_from_memory(data, @intCast(size), &w, &h, &c, 4));
    } else {
        pixels = @ptrCast(stbi_load_from_memory(data, @intCast(size), &w, &h, &c, 4));
    }

    if (pixels == null) {
        const reason = stbi_failure_reason();
        decode_log.err("Failed to load texture from memory (Size: {d})", .{size});
        if (reason) |r| {
            const r_c: [*:0]const u8 = @ptrCast(r);
            decode_log.err("STB failure reason: {s}", .{std.mem.span(r_c)});
        }
        return false;
    }

    if (w <= 0 or h <= 0 or w > 16384 or h > 16384) {
        decode_log.err("Invalid dimensions from memory load: {d}x{d}", .{ w, h });
        stbi_image_free(pixels);
        return false;
    }

    out_texture.data = @ptrCast(pixels);
    out_texture.width = @intCast(w);
    out_texture.height = @intCast(h);
    out_texture.channels = 4;
    out_texture.is_hdr = if (is_hdr) 1 else 0;
    out_texture.format = if (is_hdr) vk_formats.VK_FORMAT_R32G32B32A32_SFLOAT else vk_formats.VK_FORMAT_R8G8B8A8_SRGB;
    const pixel_size: u64 = if (is_hdr) 16 else 4;
    out_texture.data_size = @as(u64, out_texture.width) * out_texture.height * pixel_size;
    return true;
}
