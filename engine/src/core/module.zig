const std = @import("std");
const errors = @import("errors.zig");

pub const ModuleFn = *const fn (ctx: ?*anyopaque) anyerror!void;
pub const ModuleUpdateFn = *const fn (ctx: ?*anyopaque, delta_time: f32) anyerror!void;

pub const Module = struct {
    name: []const u8,
    dependencies: []const []const u8 = &.{},
    init_fn: ?ModuleFn = null,
    update_fn: ?ModuleUpdateFn = null,
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
        // Topological sort modules based on dependencies
        var sorted_modules = try std.ArrayList(Module).initCapacity(self.allocator, self.modules.items.len);
        defer sorted_modules.deinit(self.allocator);

        var name_to_index = std.StringHashMap(usize).init(self.allocator);
        defer name_to_index.deinit();

        for (self.modules.items, 0..) |mod, i| {
            try name_to_index.put(mod.name, i);
        }

        var in_degree = try std.ArrayList(usize).initCapacity(self.allocator, self.modules.items.len);
        defer in_degree.deinit(self.allocator);
        try in_degree.appendNTimes(self.allocator, 0, self.modules.items.len);

        var adj = try std.ArrayList(std.ArrayList(usize)).initCapacity(self.allocator, self.modules.items.len);
        defer {
            for (adj.items) |*list| list.deinit(self.allocator);
            adj.deinit(self.allocator);
        }
        for (0..self.modules.items.len) |_| {
            try adj.append(self.allocator, try std.ArrayList(usize).initCapacity(self.allocator, 0));
        }

        // Build graph
        for (self.modules.items, 0..) |mod, i| {
            for (mod.dependencies) |dep_name| {
                if (name_to_index.get(dep_name)) |dep_idx| {
                    try adj.items[dep_idx].append(self.allocator, i);
                    in_degree.items[i] += 1;
                } else {
                    std.log.err("Module {s} depends on unknown module {s}", .{ mod.name, dep_name });
                    return error.UnknownDependency;
                }
            }
        }

        // Kahn's algorithm
        var queue = try std.ArrayList(usize).initCapacity(self.allocator, self.modules.items.len);
        defer queue.deinit(self.allocator);

        for (in_degree.items, 0..) |degree, i| {
            if (degree == 0) {
                try queue.append(self.allocator, i);
            }
        }

        while (queue.items.len > 0) {
            const u = queue.orderedRemove(0);
            try sorted_modules.append(self.allocator, self.modules.items[u]);

            for (adj.items[u].items) |v| {
                in_degree.items[v] -= 1;
                if (in_degree.items[v] == 0) {
                    try queue.append(self.allocator, v);
                }
            }
        }

        if (sorted_modules.items.len != self.modules.items.len) {
            std.log.err("Circular dependency detected in modules!", .{});
            return error.CircularDependency;
        }


        // Replace modules with sorted list
        self.modules.clearRetainingCapacity();
        try self.modules.appendSlice(self.allocator, sorted_modules.items);

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

    pub fn update(self: *ModuleManager, delta_time: f32) !void {
        for (self.modules.items) |mod| {
            if (mod.update_fn) |func| {
                func(mod.ctx, delta_time) catch |err| {
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
