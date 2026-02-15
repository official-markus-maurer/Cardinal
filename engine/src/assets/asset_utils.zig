const std = @import("std");

pub fn find_extension(path: ?[*:0]const u8) ?[*:0]const u8 {
    if (path == null) return null;
    const p = std.mem.span(path.?);
    var last_dot: ?usize = null;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] == '.') {
            last_dot = i;
        }
    }
    if (last_dot) |idx| {
        return @as([*:0]const u8, @ptrCast(path.?)) + idx + 1;
    }
    return null;
}

pub fn to_lower_inplace(s: ?[*:0]u8) void {
    if (s == null) return;
    var ptr = s.?;
    while (ptr[0] != 0) : (ptr += 1) {
        ptr[0] = std.ascii.toLower(ptr[0]);
    }
}
