//! ECS system descriptors.
//!
//! A system is described by an update callback and the component type IDs it reads/writes.
const std = @import("std");
const registry_pkg = @import("registry.zig");
const command_buffer_pkg = @import("command_buffer.zig");

/// System update callback signature.
pub const SystemFn = *const fn (registry: *registry_pkg.Registry, ecb: *command_buffer_pkg.CommandBuffer, delta_time: f32) void;

/// Describes a system for scheduling and execution.
pub const System = struct {
    /// Stable system name for diagnostics and profiling.
    name: []const u8,
    /// Called once per frame when scheduled.
    update: SystemFn,
    /// Lower runs earlier; higher runs later.
    priority: i32 = 0,
    /// Component type IDs read by the system.
    reads: []const u64 = &.{},
    /// Component type IDs written by the system.
    writes: []const u64 = &.{},
};
