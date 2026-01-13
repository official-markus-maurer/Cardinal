const std = @import("std");

test "ArrayList deinit check" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u32).init(allocator);
    defer list.deinit(); // Check if this compiles
    try list.append(1);
}
