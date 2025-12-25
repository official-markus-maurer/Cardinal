const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const log = @import("../core/log.zig");

// Use 64-bit ID for resources (could be a pointer or hash)
pub const ResourceId = u64;

pub const ResourceType = enum {
    Buffer,
    Image,
};

pub const ResourceHandle = union(ResourceType) {
    Buffer: c.VkBuffer,
    Image: c.VkImage,
};

// Current state of a resource
pub const ResourceState = struct {
    layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    access_mask: c.VkAccessFlags2 = c.VK_ACCESS_2_NONE,
    stage_mask: c.VkPipelineStageFlags2 = c.VK_PIPELINE_STAGE_2_NONE,
    queue_family: u32 = c.VK_QUEUE_FAMILY_IGNORED,
};

// Desired access for a pass
pub const ResourceAccess = struct {
    id: ResourceId,
    type: ResourceType,
    access_mask: c.VkAccessFlags2,
    stage_mask: c.VkPipelineStageFlags2,
    layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, // Ignored for buffers
    queue_family: u32 = c.VK_QUEUE_FAMILY_IGNORED,
    
    // For images, we might need subresource range. 
    // For now, assume full resource or specific aspect.
    aspect_mask: c.VkImageAspectFlags = c.VK_IMAGE_ASPECT_COLOR_BIT,
};

pub const RenderPassCallback = *const fn (cmd: c.VkCommandBuffer, state: *types.VulkanState) void;

pub const RenderPass = struct {
    name: []const u8,
    execute_fn: RenderPassCallback,
    inputs: std.ArrayListUnmanaged(ResourceAccess),
    outputs: std.ArrayListUnmanaged(ResourceAccess),

    pub fn init(allocator: std.mem.Allocator, name: []const u8, callback: RenderPassCallback) RenderPass {
        _ = allocator;
        return .{
            .name = name,
            .execute_fn = callback,
            .inputs = .{},
            .outputs = .{},
        };
    }

    pub fn deinit(self: *RenderPass, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
        self.outputs.deinit(allocator);
    }

    pub fn add_input(self: *RenderPass, allocator: std.mem.Allocator, access: ResourceAccess) !void {
        try self.inputs.append(allocator, access);
    }

    pub fn add_output(self: *RenderPass, allocator: std.mem.Allocator, access: ResourceAccess) !void {
        try self.outputs.append(allocator, access);
    }
};

pub const RenderGraph = struct {
    passes: std.ArrayListUnmanaged(RenderPass),
    allocator: std.mem.Allocator,
    
    // Track registered resources
    resources: std.AutoHashMapUnmanaged(ResourceId, ResourceHandle),
    // Track current state of resources during execution
    resource_states: std.AutoHashMapUnmanaged(ResourceId, ResourceState),

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return .{
            .passes = .{},
            .allocator = allocator,
            .resources = .{},
            .resource_states = .{},
        };
    }

    pub fn deinit(self: *RenderGraph) void {
        for (self.passes.items) |*pass| {
            pass.deinit(self.allocator);
        }
        self.passes.deinit(self.allocator);
        self.resources.deinit(self.allocator);
        self.resource_states.deinit(self.allocator);
    }

    pub fn register_image(self: *RenderGraph, id: ResourceId, image: c.VkImage) !void {
        try self.resources.put(self.allocator, id, .{ .Image = image });
        // Initialize state if not present
        if (!self.resource_states.contains(id)) {
            try self.resource_states.put(self.allocator, id, .{
                .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .access_mask = c.VK_ACCESS_2_NONE,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            });
        }
    }

    pub fn register_buffer(self: *RenderGraph, id: ResourceId, buffer: c.VkBuffer) !void {
        try self.resources.put(self.allocator, id, .{ .Buffer = buffer });
        if (!self.resource_states.contains(id)) {
            try self.resource_states.put(self.allocator, id, .{
                .access_mask = c.VK_ACCESS_2_NONE,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            });
        }
    }

    pub fn set_resource_state(self: *RenderGraph, id: ResourceId, state: ResourceState) !void {
        try self.resource_states.put(self.allocator, id, state);
    }

    pub fn add_pass(self: *RenderGraph, pass: RenderPass) !void {
        try self.passes.append(self.allocator, pass);
    }

    pub fn clear(self: *RenderGraph) void {
        for (self.passes.items) |*pass| {
            pass.deinit(self.allocator);
        }
        self.passes.clearRetainingCapacity();
    }
    
    // Helper to insert barriers
    fn insert_barrier(
        cmd: c.VkCommandBuffer, 
        handle: ResourceHandle, 
        old_state: ResourceState, 
        new_access: ResourceAccess
    ) void {
        switch (handle) {
            .Image => |image| {
                // Skip if state matches exactly and layout is same (and not undefined transition)
                if (old_state.layout == new_access.layout and 
                    old_state.access_mask == new_access.access_mask and 
                    old_state.stage_mask == new_access.stage_mask and
                    old_state.layout != c.VK_IMAGE_LAYOUT_UNDEFINED) 
                {
                    return;
                }

                var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
                barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
                barrier.srcStageMask = old_state.stage_mask;
                barrier.srcAccessMask = old_state.access_mask;
                barrier.dstStageMask = new_access.stage_mask;
                barrier.dstAccessMask = new_access.access_mask;
                barrier.oldLayout = old_state.layout;
                barrier.newLayout = new_access.layout;
                barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                barrier.image = image;
                barrier.subresourceRange.aspectMask = new_access.aspect_mask;
                barrier.subresourceRange.baseMipLevel = 0;
                barrier.subresourceRange.levelCount = c.VK_REMAINING_MIP_LEVELS;
                barrier.subresourceRange.baseArrayLayer = 0;
                barrier.subresourceRange.layerCount = c.VK_REMAINING_ARRAY_LAYERS;

                // Handle queue ownership transfer if needed (not implemented yet)
                
                var dependency = std.mem.zeroes(c.VkDependencyInfo);
                dependency.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
                dependency.imageMemoryBarrierCount = 1;
                dependency.pImageMemoryBarriers = &barrier;

                c.vkCmdPipelineBarrier2(cmd, &dependency);
            },
            .Buffer => |buffer| {
                if (old_state.access_mask == new_access.access_mask and 
                    old_state.stage_mask == new_access.stage_mask)
                {
                    return;
                }

                var barrier = std.mem.zeroes(c.VkBufferMemoryBarrier2);
                barrier.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2;
                barrier.srcStageMask = old_state.stage_mask;
                barrier.srcAccessMask = old_state.access_mask;
                barrier.dstStageMask = new_access.stage_mask;
                barrier.dstAccessMask = new_access.access_mask;
                barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                barrier.buffer = buffer;
                barrier.offset = 0;
                barrier.size = c.VK_WHOLE_SIZE;

                var dependency = std.mem.zeroes(c.VkDependencyInfo);
                dependency.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
                dependency.bufferMemoryBarrierCount = 1;
                dependency.pBufferMemoryBarriers = &barrier;

                c.vkCmdPipelineBarrier2(cmd, &dependency);
            },
        }
    }

    pub fn execute(self: *RenderGraph, cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
        for (self.passes.items) |pass| {
            // Process inputs (Transition to read state)
            for (pass.inputs.items) |input| {
                if (self.resources.get(input.id)) |handle| {
                    if (self.resource_states.get(input.id)) |current_state| {
                        insert_barrier(cmd, handle, current_state, input);
                        
                        // Update state
                        var new_state = current_state;
                        new_state.access_mask = input.access_mask;
                        new_state.stage_mask = input.stage_mask;
                        if (input.type == .Image) {
                            new_state.layout = input.layout;
                        }
                        self.resource_states.put(self.allocator, input.id, new_state) catch {};
                    }
                }
            }

            // Process outputs (Transition to write state)
            for (pass.outputs.items) |output| {
                if (self.resources.get(output.id)) |handle| {
                    if (self.resource_states.get(output.id)) |current_state| {
                        insert_barrier(cmd, handle, current_state, output);
                        
                        // Update state
                        var new_state = current_state;
                        new_state.access_mask = output.access_mask;
                        new_state.stage_mask = output.stage_mask;
                        if (output.type == .Image) {
                            new_state.layout = output.layout;
                        }
                        self.resource_states.put(self.allocator, output.id, new_state) catch {};
                    }
                }
            }

            // Execute pass
            // log.cardinal_log_debug("Executing Pass: {s}", .{pass.name});
            pass.execute_fn(cmd, state);
        }
    }
};
