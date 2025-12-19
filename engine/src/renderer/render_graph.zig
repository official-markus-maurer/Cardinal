const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const log = @import("../core/log.zig");

pub const RenderPassCallback = *const fn (cmd: c.VkCommandBuffer, state: *types.VulkanState) void;

pub const RenderPass = struct {
    name: []const u8,
    execute_fn: RenderPassCallback,
    
    // Future: Dependencies, Inputs, Outputs
    
    pub fn init(name: []const u8, callback: RenderPassCallback) RenderPass {
        return .{
            .name = name,
            .execute_fn = callback,
        };
    }

    pub fn execute(self: RenderPass, cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
        // log.cardinal_log_debug("Executing Pass: {s}", .{self.name});
        self.execute_fn(cmd, state);
    }
};

pub const RenderGraph = struct {
    passes: std.ArrayListUnmanaged(RenderPass),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return .{
            .passes = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderGraph) void {
        self.passes.deinit(self.allocator);
    }

    pub fn add_pass(self: *RenderGraph, pass: RenderPass) !void {
        try self.passes.append(self.allocator, pass);
    }

    pub fn clear(self: *RenderGraph) void {
        self.passes.clearRetainingCapacity();
    }

    pub fn execute(self: *RenderGraph, cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
        for (self.passes.items) |pass| {
            pass.execute(cmd, state);
        }
    }
};
