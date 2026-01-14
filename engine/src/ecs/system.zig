const std = @import("std");
const registry_pkg = @import("registry.zig");

pub const SystemFn = *const fn (registry: *registry_pkg.Registry, delta_time: f32) void;

pub const System = struct {
    name: []const u8,
    update: SystemFn,
    priority: i32 = 0,
};
