const std = @import("std");
const registry_pkg = @import("registry.zig");
const command_buffer_pkg = @import("command_buffer.zig");

pub const SystemFn = *const fn (registry: *registry_pkg.Registry, ecb: *command_buffer_pkg.CommandBuffer, delta_time: f32) void;

pub const System = struct {
    name: []const u8,
    update: SystemFn,
    priority: i32 = 0,
    reads: []const u64 = &.{},
    writes: []const u64 = &.{},
};
