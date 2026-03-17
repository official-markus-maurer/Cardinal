//! TinyEXR-backed decoding.
const std = @import("std");
const log = @import("../core/log.zig");
const types = @import("texture_types.zig");

const decode_log = log.ScopedLogger("TEX_EXR");

extern fn LoadEXRFromMemory(out_rgba: *?[*]f32, width: *c_int, height: *c_int, memory: [*]const u8, size: usize, err: *?[*]const u8) c_int;
extern fn FreeEXRErrorMessage(msg: [*]const u8) void;

pub fn decode_from_memory(data: [*]const u8, size: usize, out_texture: *types.TextureData) bool {
    var w: c_int = 0;
    var h: c_int = 0;

    var exr_data: ?[*]f32 = null;
    var err: ?[*]const u8 = null;
    const res = LoadEXRFromMemory(&exr_data, &w, &h, data, size, &err);

    if (res != 0) {
        if (err) |e| {
            const e_span = @as([*:0]const u8, @ptrCast(e));
            decode_log.err("TinyEXR memory load failed: {s}", .{std.mem.span(e_span)});
            FreeEXRErrorMessage(e);
        }
        return false;
    }

    if (w <= 0 or h <= 0 or w > 16384 or h > 16384) {
        decode_log.err("Invalid dimensions from EXR memory load: {d}x{d}", .{ w, h });
        if (exr_data) |ptr| std.c.free(ptr);
        return false;
    }

    out_texture.data = @ptrCast(exr_data);
    out_texture.width = @intCast(w);
    out_texture.height = @intCast(h);
    out_texture.channels = 4;
    out_texture.is_hdr = 1;
    out_texture.data_size = @as(u64, out_texture.width) * out_texture.height * 16;
    return true;
}

