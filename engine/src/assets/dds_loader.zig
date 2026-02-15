const std = @import("std");
const log = @import("../core/log.zig");
const texture_loader = @import("texture_loader.zig");

const dds_log = log.ScopedLogger("DDS");

// DDS Header Constants
const DDS_MAGIC: u32 = 0x20534444; // "DDS "

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

// Vulkan Formats (from vulkan_core.h)
const VK_FORMAT_UNDEFINED = 0;
const VK_FORMAT_R8G8B8A8_UNORM = 37;
const VK_FORMAT_R8G8B8A8_SRGB = 43;
const VK_FORMAT_B8G8R8A8_UNORM = 44;
const VK_FORMAT_B8G8R8A8_SRGB = 50;
const VK_FORMAT_BC1_RGB_UNORM_BLOCK = 131;
const VK_FORMAT_BC1_RGB_SRGB_BLOCK = 132;
const VK_FORMAT_BC1_RGBA_UNORM_BLOCK = 133;
const VK_FORMAT_BC1_RGBA_SRGB_BLOCK = 134;
const VK_FORMAT_BC2_UNORM_BLOCK = 135;
const VK_FORMAT_BC2_SRGB_BLOCK = 136;
const VK_FORMAT_BC3_UNORM_BLOCK = 137;
const VK_FORMAT_BC3_SRGB_BLOCK = 138;
const VK_FORMAT_BC4_UNORM_BLOCK = 139;
const VK_FORMAT_BC4_SNORM_BLOCK = 140;
const VK_FORMAT_BC5_UNORM_BLOCK = 141;
const VK_FORMAT_BC5_SNORM_BLOCK = 142;

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

fn makeFourCC(ch0: u8, ch1: u8, ch2: u8, ch3: u8) u32 {
    return @as(u32, ch0) | (@as(u32, ch1) << 8) | (@as(u32, ch2) << 16) | (@as(u32, ch3) << 24);
}

pub fn load_dds_from_memory(buffer: []const u8, out_data: *texture_loader.TextureData) bool {
    if (buffer.len < 4 + @sizeOf(DDS_HEADER)) {
        dds_log.err("Buffer too small for DDS header", .{});
        return false;
    }

    const magic = std.mem.readInt(u32, buffer[0..4], .little);
    if (magic != DDS_MAGIC) {
        return false; // Not a DDS file
    }

    const header = @as(*const DDS_HEADER, @ptrCast(@alignCast(buffer.ptr + 4)));

    if (header.dwSize != 124) {
        dds_log.err("Invalid DDS header size: {d}", .{header.dwSize});
        return false;
    }

    var format: u32 = VK_FORMAT_UNDEFINED;

    if ((header.ddspf.dwFlags & DDPF_FOURCC) != 0) {
        const fourCC = header.ddspf.dwFourCC;

        if (fourCC == makeFourCC('D', 'X', 'T', '1')) {
            format = VK_FORMAT_BC1_RGBA_SRGB_BLOCK;
        } else if (fourCC == makeFourCC('D', 'X', 'T', '3')) {
            format = VK_FORMAT_BC2_SRGB_BLOCK;
        } else if (fourCC == makeFourCC('D', 'X', 'T', '5')) {
            format = VK_FORMAT_BC3_SRGB_BLOCK;
        } else if (fourCC == makeFourCC('B', 'C', '4', 'U')) {
            format = VK_FORMAT_BC4_UNORM_BLOCK;
        } else if (fourCC == makeFourCC('B', 'C', '4', 'S')) {
            format = VK_FORMAT_BC4_SNORM_BLOCK;
        } else if (fourCC == makeFourCC('A', 'T', 'I', '2')) {
            format = VK_FORMAT_BC5_UNORM_BLOCK;
        } else if (fourCC == makeFourCC('B', 'C', '5', 'S')) {
            format = VK_FORMAT_BC5_SNORM_BLOCK;
        } else {
            return false;
        }
    } else if ((header.ddspf.dwFlags & DDPF_RGB) != 0) {
        // Uncompressed RGB/RGBA
        const rMask = header.ddspf.dwRBitMask;
        const gMask = header.ddspf.dwGBitMask;
        const bMask = header.ddspf.dwBBitMask;
        const aMask = header.ddspf.dwABitMask;
        const bitCount = header.ddspf.dwRGBBitCount;

        if (bitCount == 32) {
            // Check for BGRA (most common)
            if (rMask == 0x00FF0000 and gMask == 0x0000FF00 and bMask == 0x000000FF and aMask == 0xFF000000) {
                format = VK_FORMAT_B8G8R8A8_UNORM;
            }
            // Check for RGBA
            else if (rMask == 0x000000FF and gMask == 0x0000FF00 and bMask == 0x00FF0000 and aMask == 0xFF000000) {
                format = VK_FORMAT_R8G8B8A8_UNORM;
            }
            // Check for BGRX (ignore alpha)
            else if (rMask == 0x00FF0000 and gMask == 0x0000FF00 and bMask == 0x000000FF and aMask == 0x00000000) {
                // Treat as B8G8R8A8 but we might need to set alpha to 1 manually if renderer doesn't ignore it
                // For now map to B8G8R8A8
                format = VK_FORMAT_B8G8R8A8_UNORM;
            } else {
                dds_log.err("Unsupported 32-bit RGB mask: R={x} G={x} B={x} A={x}", .{ rMask, gMask, bMask, aMask });
                return false;
            }
        } else if (bitCount == 24) {
            // 24-bit RGB/BGR -> Convert to 32-bit RGBA
            // Calculate offsets
            const data_offset = 4 + header.dwSize;
            const width = header.dwWidth;
            const height = header.dwHeight;
            const pixel_count = width * height;
            const src_data_size = pixel_count * 3;

            if (data_offset + src_data_size > buffer.len) {
                dds_log.err("Buffer too small for 24-bit DDS data", .{});
                return false;
            }

            const new_data_size = pixel_count * 4;
            const ptr = std.c.malloc(new_data_size);
            if (ptr == null) {
                dds_log.err("Failed to allocate memory for converted 24-bit DDS data", .{});
                return false;
            }

            const src = buffer[data_offset..];
            const dst = @as([*]u8, @ptrCast(ptr))[0..new_data_size];

            // Check masks for BGR vs RGB
            const is_bgr = (rMask == 0xFF0000 and gMask == 0xFF00 and bMask == 0xFF);
            const is_rgb = (rMask == 0xFF and gMask == 0xFF00 and bMask == 0xFF0000);

            if (is_bgr) {
                // Source: B G R -> Dest: R G B A (using VK_FORMAT_R8G8B8A8_UNORM)
                // Wait, if we use VK_FORMAT_R8G8B8A8_UNORM, memory is R G B A
                // Source BGR: Byte0=B, Byte1=G, Byte2=R
                // So we write: R(2), G(1), B(0), A(255)
                var i: usize = 0;
                while (i < pixel_count) : (i += 1) {
                    dst[i * 4 + 0] = src[i * 3 + 2]; // R
                    dst[i * 4 + 1] = src[i * 3 + 1]; // G
                    dst[i * 4 + 2] = src[i * 3 + 0]; // B
                    dst[i * 4 + 3] = 255; // A
                }
                format = VK_FORMAT_R8G8B8A8_UNORM;
            } else if (is_rgb) {
                // Source: R G B -> Dest: R G B A
                var i: usize = 0;
                while (i < pixel_count) : (i += 1) {
                    dst[i * 4 + 0] = src[i * 3 + 0]; // R
                    dst[i * 4 + 1] = src[i * 3 + 1]; // G
                    dst[i * 4 + 2] = src[i * 3 + 2]; // B
                    dst[i * 4 + 3] = 255; // A
                }
                format = VK_FORMAT_R8G8B8A8_UNORM;
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

    // Calculate data offset and size (Standard path for non-converted formats)
    const data_offset = 4 + header.dwSize;
    const data_size = buffer.len - data_offset;

    const ptr = std.c.malloc(data_size);
    if (ptr == null) {
        dds_log.err("Failed to allocate memory for DDS data", .{});
        return false;
    }

    @memcpy(@as([*]u8, @ptrCast(ptr))[0..data_size], buffer[data_offset..]);

    out_data.width = header.dwWidth;
    out_data.height = header.dwHeight;
    out_data.channels = 4; // Compressed textures effectively have alpha usually
    out_data.is_hdr = 0;
    out_data.format = format;
    out_data.data = @ptrCast(ptr);
    out_data.data_size = data_size;

    return true;
}
