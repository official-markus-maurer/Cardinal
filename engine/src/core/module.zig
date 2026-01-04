const std = @import("std");
const errors = @import("errors.zig");

pub const ModuleFn = *const fn (ctx: ?*anyopaque) anyerror!void;

pub const Module = struct {
    name: []const u8,
    init_fn: ?ModuleFn = null,
    update_fn: ?ModuleFn = null,
    shutdown_fn: ?ModuleFn = null,
    ctx: ?*anyopaque = null,
};

pub const ModuleManager = struct {
    modules: std.ArrayListUnmanaged(Module) = .{},
    allocator: std.mem.Allocator,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator) ModuleManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ModuleManager) void {
        if (self.initialized) {
            self.shutdown();
        }
        self.modules.deinit(self.allocator);
    }

    pub fn register(self: *ModuleManager, module: Module) !void {
        try self.modules.append(self.allocator, module);
    }

    pub fn startup(self: *ModuleManager) !void {
        for (self.modules.items) |mod| {
            if (mod.init_fn) |func| {
                std.log.info("Initializing module: {s}", .{mod.name});
                func(mod.ctx) catch |err| {
                    std.log.err("Failed to initialize module {s}: {}", .{mod.name, err});
                    return err;
                };
            }
        }
        self.initialized = true;
    }

    pub fn update(self: *ModuleManager) !void {
        for (self.modules.items) |mod| {
            if (mod.update_fn) |func| {
                func(mod.ctx) catch |err| {
                    std.log.err("Error updating module {s}: {}", .{mod.name, err});
                    return err;
                };
            }
        }
    }

    pub fn shutdown(self: *ModuleManager) void {
        // Shutdown in reverse order
        var i = self.modules.items.len;
        while (i > 0) {
            i -= 1;
            const mod = self.modules.items[i];
            if (mod.shutdown_fn) |func| {
                std.log.info("Shutting down module: {s}", .{mod.name});
                func(mod.ctx) catch |err| {
                    std.log.err("Error shutting down module {s}: {}", .{mod.name, err});
                };
            }
        }
        self.initialized = false;
    }
};
