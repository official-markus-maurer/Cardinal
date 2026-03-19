//! DDS texture decoding.
//!
//! Parses DDS headers and maps a subset of formats to Vulkan format constants. Some paths convert
//! to RGBA8 when the source is 24-bit.
const std = @import("std");
const log = @import("../core/log.zig");
const texture_types = @import("texture_types.zig");
const vk_formats = @import("../renderer/vulkan_format_constants.zig");

const dds_log = log.ScopedLogger("DDS");

/// DDS file magic ("DDS ").
const DDS_MAGIC: u32 = 0x20534444;

const DDSD_CAPS: u32 = 0x00000001;
const DDSD_HEIGHT: u32 = 0x00000002;
const DDSD_WIDTH: u32 = 0x00000004;
const DDSD_PITCH: u32 = 0x00000008;
const DDSD_PIXELFORMAT: u32 = 0x00001000;
const DDSD_MIPMAPCOUNT: u32 = 0x00020000;
const DDSD_LINEARSIZE: u32 = 0x00080000;
const DDSD_DEPTH: u32 = 0x00800000;

const DDPF_ALPHAPIXELS: u32 = 0x00000001;
const DDPF_ALPHA: u32 = 0x00000002;
const DDPF_FOURCC: u32 = 0x00000004;
const DDPF_RGB: u32 = 0x00000040;
const DDPF_YUV: u32 = 0x00000200;
const DDPF_LUMINANCE: u32 = 0x00020000;

const DDS_PIXELFORMAT = extern struct {
    dwSize: u32,
    dwFlags: u32,
    dwFourCC: u32,
    dwRGBBitCount: u32,
    dwRBitMask: u32,
    dwGBitMask: u32,
    dwBBitMask: u32,
    dwABitMask: u32,
};

const DDS_HEADER = extern struct {
    dwSize: u32,
    dwFlags: u32,
    dwHeight: u32,
    dwWidth: u32,
    dwPitchOrLinearSize: u32,
    dwDepth: u32,
    dwMipMapCount: u32,
    dwReserved1: [11]u32,
    ddspf: DDS_PIXELFORMAT,
    dwCaps: u32,
    dwCaps2: u32,
    dwCaps3: u32,
    dwCaps4: u32,
    dwReserved2: u32,
};

/// Optional DX10 header present when the pixel format FourCC is "DX10".
///
/// Only a minimal subset of DXGI formats is supported.
/// TODO: Expand DXGI format mapping (BC6H/BC7 variants, RG formats, arrays/cubemaps).
const DDS_HEADER_DXT10 = extern struct {
    dxgiFormat: u32,
    resourceDimension: u32,
    miscFlag: u32,
    arraySize: u32,
    miscFlags2: u32,
};

fn makeFourCC(ch0: u8, ch1: u8, ch2: u8, ch3: u8) u32 {
    return @as(u32, ch0) | (@as(u32, ch1) << 8) | (@as(u32, ch2) << 16) | (@as(u32, ch3) << 24);
}

/// Loads DDS pixel data from a memory buffer into `out_data`.
///
/// When the source is 24-bit RGB/BGR, this allocates a new RGBA8 buffer (alpha=255).
pub fn load_dds_from_memory(buffer: []const u8, out_data: *texture_types.TextureData) bool {
    if (buffer.len < 4 + @sizeOf(DDS_HEADER)) {
        dds_log.err("Buffer too small for DDS header", .{});
        return false;
    }

    const magic = std.mem.readInt(u32, buffer[0..4], .little);
    if (magic != DDS_MAGIC) {
        return false;
    }

    const header = @as(*const DDS_HEADER, @ptrCast(@alignCast(buffer.ptr + 4)));

    if (header.dwSize != 124) {
        dds_log.err("Invalid DDS header size: {d}", .{header.dwSize});
        return false;
    }

    var format: u32 = vk_formats.VK_FORMAT_UNDEFINED;
    var data_offset: usize = 4 + header.dwSize;

    if ((header.ddspf.dwFlags & DDPF_FOURCC) != 0) {
        const fourCC = header.ddspf.dwFourCC;

        if (fourCC == makeFourCC('D', 'X', '1', '0')) {
            if (buffer.len < data_offset + @sizeOf(DDS_HEADER_DXT10)) return false;
            const dx10 = @as(*const DDS_HEADER_DXT10, @ptrCast(@alignCast(buffer.ptr + data_offset)));
            data_offset += @sizeOf(DDS_HEADER_DXT10);

            switch (dx10.dxgiFormat) {
                98 => format = vk_formats.VK_FORMAT_BC7_UNORM_BLOCK,
                99 => format = vk_formats.VK_FORMAT_BC7_SRGB_BLOCK,
                71 => format = vk_formats.VK_FORMAT_BC1_RGBA_UNORM_BLOCK,
                72 => format = vk_formats.VK_FORMAT_BC1_RGBA_SRGB_BLOCK,
                74 => format = vk_formats.VK_FORMAT_BC2_UNORM_BLOCK,
                75 => format = vk_formats.VK_FORMAT_BC2_SRGB_BLOCK,
                77 => format = vk_formats.VK_FORMAT_BC3_UNORM_BLOCK,
                78 => format = vk_formats.VK_FORMAT_BC3_SRGB_BLOCK,
                80 => format = vk_formats.VK_FORMAT_BC4_UNORM_BLOCK,
                83 => format = vk_formats.VK_FORMAT_BC5_UNORM_BLOCK,
                else => return false,
            }
        } else if (fourCC == makeFourCC('D', 'X', 'T', '1')) {
            format = vk_formats.VK_FORMAT_BC1_RGBA_SRGB_BLOCK;
        } else if (fourCC == makeFourCC('D', 'X', 'T', '3')) {
            format = vk_formats.VK_FORMAT_BC2_SRGB_BLOCK;
        } else if (fourCC == makeFourCC('D', 'X', 'T', '5')) {
            format = vk_formats.VK_FORMAT_BC3_SRGB_BLOCK;
        } else if (fourCC == makeFourCC('B', 'C', '4', 'U')) {
            format = vk_formats.VK_FORMAT_BC4_UNORM_BLOCK;
        } else if (fourCC == makeFourCC('B', 'C', '4', 'S')) {
            format = vk_formats.VK_FORMAT_BC4_SNORM_BLOCK;
        } else if (fourCC == makeFourCC('A', 'T', 'I', '2')) {
            format = vk_formats.VK_FORMAT_BC5_UNORM_BLOCK;
        } else if (fourCC == makeFourCC('B', 'C', '5', 'S')) {
            format = vk_formats.VK_FORMAT_BC5_SNORM_BLOCK;
        } else {
            return false;
        }
    } else if ((header.ddspf.dwFlags & DDPF_RGB) != 0) {
        const rMask = header.ddspf.dwRBitMask;
        const gMask = header.ddspf.dwGBitMask;
        const bMask = header.ddspf.dwBBitMask;
        const aMask = header.ddspf.dwABitMask;
        const bitCount = header.ddspf.dwRGBBitCount;

        if (bitCount == 32) {
            if (rMask == 0x00FF0000 and gMask == 0x0000FF00 and bMask == 0x000000FF and aMask == 0xFF000000) {
                format = vk_formats.VK_FORMAT_B8G8R8A8_UNORM;
            } else if (rMask == 0x000000FF and gMask == 0x0000FF00 and bMask == 0x00FF0000 and aMask == 0xFF000000) {
                format = vk_formats.VK_FORMAT_R8G8B8A8_UNORM;
            } else if (rMask == 0x00FF0000 and gMask == 0x0000FF00 and bMask == 0x000000FF and aMask == 0x00000000) {
                format = vk_formats.VK_FORMAT_B8G8R8A8_UNORM;
            } else {
                dds_log.err("Unsupported 32-bit RGB mask: R={x} G={x} B={x} A={x}", .{ rMask, gMask, bMask, aMask });
                return false;
            }
        } else if (bitCount == 24) {
            const rgb_data_offset = 4 + header.dwSize;
            const width = header.dwWidth;
            const height = header.dwHeight;
            const pixel_count = width * height;
            const src_data_size = pixel_count * 3;

            if (rgb_data_offset + src_data_size > buffer.len) {
                dds_log.err("Buffer too small for 24-bit DDS data", .{});
                return false;
            }

            const new_data_size = pixel_count * 4;
            const ptr = std.c.malloc(new_data_size);
            if (ptr == null) {
                dds_log.err("Failed to allocate memory for converted 24-bit DDS data", .{});
                return false;
            }

            const src = buffer[rgb_data_offset..];
            const dst = @as([*]u8, @ptrCast(ptr))[0..new_data_size];

            const is_bgr = (rMask == 0xFF0000 and gMask == 0xFF00 and bMask == 0xFF);
            const is_rgb = (rMask == 0xFF and gMask == 0xFF00 and bMask == 0xFF0000);

            if (is_bgr) {
                var i: usize = 0;
                while (i < pixel_count) : (i += 1) {
                    dst[i * 4 + 0] = src[i * 3 + 2];
                    dst[i * 4 + 1] = src[i * 3 + 1];
                    dst[i * 4 + 2] = src[i * 3 + 0];
                    dst[i * 4 + 3] = 255;
                }
                format = vk_formats.VK_FORMAT_R8G8B8A8_UNORM;
            } else if (is_rgb) {
                var i: usize = 0;
                while (i < pixel_count) : (i += 1) {
                    dst[i * 4 + 0] = src[i * 3 + 0];
                    dst[i * 4 + 1] = src[i * 3 + 1];
                    dst[i * 4 + 2] = src[i * 3 + 2];
                    dst[i * 4 + 3] = 255;
                }
                format = vk_formats.VK_FORMAT_R8G8B8A8_UNORM;
            } else {
                dds_log.err("Unsupported 24-bit RGB mask: R={x} G={x} B={x}", .{ rMask, gMask, bMask });
                std.c.free(ptr);
                return false;
            }

            out_data.width = width;
            out_data.height = height;
            out_data.channels = 4;
            out_data.is_hdr = 0;
            out_data.format = format;
            out_data.data = @ptrCast(ptr);
            out_data.data_size = new_data_size;
            return true;
        } else {
            dds_log.err("Unsupported bit count: {d}", .{bitCount});
            return false;
        }
    } else {
        dds_log.err("Unsupported DDS format (only DXT/BC and 32/24-bit RGB supported)", .{});
        return false;
    }

    if (data_offset > buffer.len) return false;
    const data_size = buffer.len - data_offset;

    const ptr = std.c.malloc(data_size);
    if (ptr == null) {
        dds_log.err("Failed to allocate memory for DDS data", .{});
        return false;
    }

    @memcpy(@as([*]u8, @ptrCast(ptr))[0..data_size], buffer[data_offset..]);

    out_data.width = header.dwWidth;
    out_data.height = header.dwHeight;
    out_data.channels = 4;
    out_data.is_hdr = 0;
    out_data.format = format;
    out_data.data = @ptrCast(ptr);
    out_data.data_size = data_size;

    return true;
}
