const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const log = @import("../core/log.zig");
const vk_allocator = @import("vulkan_allocator.zig");

const rg_log = log.ScopedLogger("RENDER_GRAPH");

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

// Resource Definitions for Transient Resources
pub const ImageDesc = struct {
    format: c.VkFormat,
    width: u32,
    height: u32,
    usage: c.VkImageUsageFlags,
    aspect_mask: c.VkImageAspectFlags = c.VK_IMAGE_ASPECT_COLOR_BIT,
};

pub const BufferDesc = struct {
    size: u64,
    usage: c.VkBufferUsageFlags,
};

pub const ResourceDesc = union(ResourceType) {
    Buffer: BufferDesc,
    Image: ImageDesc,
};

pub const ResourceLifecycle = enum {
    External,
    Transient,
};

const PooledImage = struct {
    image: c.VkImage,
    allocation: c.VmaAllocation,
    memory: c.VkDeviceMemory,
    image_view: ?c.VkImageView,
    desc: ImageDesc,
};

const PooledBuffer = struct {
    buffer: c.VkBuffer,
    allocation: c.VmaAllocation,
    memory: c.VkDeviceMemory,
    desc: BufferDesc,
};

pub const RenderGraphResource = struct {
    id: ResourceId,
    lifecycle: ResourceLifecycle,
    desc: ?ResourceDesc, // Only for transient
    handle: ?ResourceHandle = null,

    // Internal state for allocation
    allocation: ?c.VmaAllocation = null,
    memory: ?c.VkDeviceMemory = null,
    image_view: ?c.VkImageView = null,
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

    // Async Compute
    queue_family: u32 = c.VK_QUEUE_FAMILY_IGNORED,

    // Culling
    is_active: bool = true,
    can_be_culled: bool = true, // Force active if false (e.g. swapchain present)

    pub fn init(allocator: std.mem.Allocator, name: []const u8, callback: RenderPassCallback) RenderPass {
        _ = allocator;
        return .{
            .name = name,
            .execute_fn = callback,
            .inputs = .{},
            .outputs = .{},
            .is_active = true,
            .can_be_culled = true,
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
    resources: std.AutoHashMapUnmanaged(ResourceId, RenderGraphResource),
    // Track current state of resources during execution
    resource_states: std.AutoHashMapUnmanaged(ResourceId, ResourceState),

    // Resource Pools
    image_pool: std.ArrayListUnmanaged(PooledImage),
    buffer_pool: std.ArrayListUnmanaged(PooledBuffer),

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return .{
            .passes = .{},
            .allocator = allocator,
            .resources = .{},
            .resource_states = .{},
            .image_pool = .{},
            .buffer_pool = .{},
        };
    }

    pub fn deinit(self: *RenderGraph) void {
        for (self.passes.items) |*pass| {
            pass.deinit(self.allocator);
        }
        self.passes.deinit(self.allocator);
        self.resources.deinit(self.allocator);
        self.resource_states.deinit(self.allocator);
        self.image_pool.deinit(self.allocator);
        self.buffer_pool.deinit(self.allocator);
    }

    pub fn register_image(self: *RenderGraph, id: ResourceId, image: c.VkImage) !void {
        // Check if handle changed to reset state
        var handle_changed = true;
        if (self.resources.get(id)) |res| {
            if (res.handle) |h| {
                if (h.Image == image) {
                    handle_changed = false;
                }
            }
        }

        try self.resources.put(self.allocator, id, .{ .id = id, .lifecycle = .External, .desc = null, .handle = .{ .Image = image } });

        // Initialize state if not present or handle changed
        if (handle_changed or !self.resource_states.contains(id)) {
            try self.resource_states.put(self.allocator, id, .{
                .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .access_mask = c.VK_ACCESS_2_NONE,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            });
        }
    }

    pub fn register_buffer(self: *RenderGraph, id: ResourceId, buffer: c.VkBuffer) !void {
        try self.resources.put(self.allocator, id, .{ .id = id, .lifecycle = .External, .desc = null, .handle = .{ .Buffer = buffer } });

        if (!self.resource_states.contains(id)) {
            try self.resource_states.put(self.allocator, id, .{
                .access_mask = c.VK_ACCESS_2_NONE,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            });
        }
    }

    fn acquire_pooled_image(self: *RenderGraph, desc: ImageDesc) ?PooledImage {
        var i: usize = 0;
        while (i < self.image_pool.items.len) : (i += 1) {
            const item = self.image_pool.items[i];
            if (item.desc.format == desc.format and
                item.desc.width == desc.width and
                item.desc.height == desc.height and
                item.desc.usage == desc.usage and
                item.desc.aspect_mask == desc.aspect_mask)
            {
                return self.image_pool.swapRemove(i);
            }
        }
        return null;
    }

    fn release_image_to_pool(self: *RenderGraph, image: PooledImage) !void {
        try self.image_pool.append(self.allocator, image);
    }

    fn acquire_pooled_buffer(self: *RenderGraph, desc: BufferDesc) ?PooledBuffer {
        var i: usize = 0;
        while (i < self.buffer_pool.items.len) : (i += 1) {
            const item = self.buffer_pool.items[i];
            if (item.desc.size == desc.size and
                item.desc.usage == desc.usage)
            {
                return self.buffer_pool.swapRemove(i);
            }
        }
        return null;
    }

    fn release_buffer_to_pool(self: *RenderGraph, buffer: PooledBuffer) !void {
        try self.buffer_pool.append(self.allocator, buffer);
    }

    pub fn add_transient_image(self: *RenderGraph, id: ResourceId, desc: ImageDesc) !void {
        try self.resources.put(self.allocator, id, .{
            .id = id,
            .lifecycle = .Transient,
            .desc = .{ .Image = desc },
            .handle = null,
        });

        if (!self.resource_states.contains(id)) {
            try self.resource_states.put(self.allocator, id, .{
                .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .access_mask = c.VK_ACCESS_2_NONE,
                .stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            });
        }
    }

    pub fn update_transient_image(self: *RenderGraph, id: ResourceId, desc: ImageDesc, state: *types.VulkanState) !void {
        const existing = self.resources.getPtr(id);
        if (existing) |res| {
            // Check if description matches
            var match = false;
            if (res.desc) |d| {
                switch (d) {
                    .Image => |img| {
                        match = (img.width == desc.width and img.height == desc.height and img.format == desc.format);
                    },
                    else => {},
                }
            }

            if (match) return; // No change needed

            // Release old resource to pool if allocated
            if (res.handle != null) {
                switch (res.handle.?) {
                    .Image => |image| {
                        if (res.desc) |d| {
                            switch (d) {
                                .Image => |old_desc| {
                                    const pooled = PooledImage{
                                        .image = image,
                                        .allocation = res.allocation.?,
                                        .memory = res.memory.?,
                                        .image_view = res.image_view,
                                        .desc = old_desc,
                                    };
                                    self.release_image_to_pool(pooled) catch {
                                        // Fallback to destroy if pool fails
                                        if (res.image_view) |view| {
                                            c.vkDestroyImageView(state.context.device, view, null);
                                        }
                                        vk_allocator.free_image(&state.allocator, image, res.allocation.?);
                                    };
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
                res.handle = null;
                res.allocation = null;
                res.memory = null;
                res.image_view = null;

                // Reset state to UNDEFINED since we destroyed the underlying resource
                if (self.resource_states.getPtr(id)) |res_state| {
                    res_state.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
                    res_state.access_mask = c.VK_ACCESS_2_NONE;
                    res_state.stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
                    res_state.queue_family = c.VK_QUEUE_FAMILY_IGNORED;
                }
            }
        }

        // Update or add (overwrites desc, resets handle if we didn't already)
        // If we didn't find it, this adds it. If we found it, we freed handle so it's safe to overwrite.
        try self.add_transient_image(id, desc);
    }

    pub fn destroy_transient_resources(self: *RenderGraph, state: *types.VulkanState) void {
        var it = self.resources.iterator();
        while (it.next()) |entry| {
            var res = entry.value_ptr;
            if (res.lifecycle == .Transient and res.handle != null) {
                switch (res.handle.?) {
                    .Image => |image| {
                        if (res.image_view) |view| {
                            c.vkDestroyImageView(state.context.device, view, null);
                            res.image_view = null;
                        }
                        if (res.allocation) |allocation| {
                            vk_allocator.free_image(&state.allocator, image, allocation);
                        }
                    },
                    .Buffer => |buffer| {
                        if (res.allocation) |allocation| {
                            vk_allocator.free_buffer(&state.allocator, buffer, allocation);
                        }
                    },
                }
                res.handle = null;
                res.allocation = null;
                res.memory = null;

                // Reset state to UNDEFINED
                if (self.resource_states.getPtr(res.id)) |res_state| {
                    res_state.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
                    res_state.access_mask = c.VK_ACCESS_2_NONE;
                    res_state.stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
                    res_state.queue_family = c.VK_QUEUE_FAMILY_IGNORED;
                }
            }
        }

        // Destroy pooled resources
        for (self.image_pool.items) |pooled| {
            if (pooled.image_view) |view| {
                c.vkDestroyImageView(state.context.device, view, null);
            }
            if (pooled.allocation) |alloc| {
                vk_allocator.free_image(&state.allocator, pooled.image, alloc);
            }
        }
        self.image_pool.clearRetainingCapacity();

        for (self.buffer_pool.items) |pooled| {
            if (pooled.allocation) |alloc| {
                vk_allocator.free_buffer(&state.allocator, pooled.buffer, alloc);
            }
        }
        self.buffer_pool.clearRetainingCapacity();
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

    // Culling and Planning
    pub fn compile(self: *RenderGraph) !void {
        // 1. Reset active state
        for (self.passes.items) |*pass| {
            pass.is_active = !pass.can_be_culled; // If can't be culled, it's active by default (e.g. Present)
        }

        // 2. Identify producers for resources
        // We need a map: ResourceID -> Producer Pass Index
        var producers = std.AutoHashMap(ResourceId, usize).init(self.allocator);
        defer producers.deinit();

        for (self.passes.items, 0..) |pass, i| {
            for (pass.outputs.items) |output| {
                try producers.put(output.id, i);
            }
        }

        // 3. Mark passes reachable from active passes (or external outputs like Backbuffer)
        // For now, we assume Backbuffer (ID 1) is the main output.
        // A better way is to explicitly mark the "Present" pass or passes writing to swapchain.

        // Let's implement a simple backward traversal
        // Queue of passes to process
        var queue = std.ArrayListUnmanaged(usize){};
        defer queue.deinit(self.allocator);

        // Start with passes that are already active (uncullable) or write to Backbuffer
        for (self.passes.items, 0..) |*pass, i| {
            var writes_backbuffer = false;
            for (pass.outputs.items) |output| {
                if (output.id == types.RESOURCE_ID_BACKBUFFER) {
                    writes_backbuffer = true;
                    break;
                }
            }

            if (pass.is_active or writes_backbuffer) {
                pass.is_active = true;
                try queue.append(self.allocator, i);
            }
        }

        // BFS Traversal
        var processed_idx: usize = 0;
        while (processed_idx < queue.items.len) {
            const pass_idx = queue.items[processed_idx];
            processed_idx += 1;

            const pass = &self.passes.items[pass_idx];

            // For each input of this active pass, activate the producer
            for (pass.inputs.items) |input| {
                if (producers.get(input.id)) |producer_idx| {
                    if (!self.passes.items[producer_idx].is_active) {
                        self.passes.items[producer_idx].is_active = true;
                        try queue.append(self.allocator, producer_idx);
                    }
                }
            }
        }
    }

    // Helper to insert barriers
    fn insert_barrier(cmd: c.VkCommandBuffer, handle: ResourceHandle, old_state: ResourceState, new_access: ResourceAccess, state: *types.VulkanState) void {
        switch (handle) {
            .Image => |image| {
                // Skip if state matches exactly and layout is same (and not undefined transition)
                // BUT if queue families differ, we MUST insert barrier for ownership transfer
                const queue_changed = (old_state.queue_family != c.VK_QUEUE_FAMILY_IGNORED and
                    new_access.queue_family != c.VK_QUEUE_FAMILY_IGNORED and
                    old_state.queue_family != new_access.queue_family);

                if (!queue_changed and
                    old_state.layout == new_access.layout and
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

                // Queue Ownership Transfer
                if (queue_changed) {
                    barrier.srcQueueFamilyIndex = old_state.queue_family;
                    barrier.dstQueueFamilyIndex = new_access.queue_family;
                } else {
                    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                }

                barrier.image = image;
                barrier.subresourceRange.aspectMask = new_access.aspect_mask;
                barrier.subresourceRange.baseMipLevel = 0;
                barrier.subresourceRange.levelCount = 1;
                barrier.subresourceRange.baseArrayLayer = 0;
                barrier.subresourceRange.layerCount = 1;

                var dependency = std.mem.zeroes(c.VkDependencyInfo);
                dependency.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
                dependency.dependencyFlags = 0; // Global dependency
                dependency.imageMemoryBarrierCount = 1;
                dependency.pImageMemoryBarriers = &barrier;

                if (state.context.vkCmdPipelineBarrier2) |func| {
                    rg_log.debug("Inserting Image Barrier: {any} -> {any} (Layout: {any} -> {any})", .{ old_state.stage_mask, new_access.stage_mask, old_state.layout, new_access.layout });
                    func(cmd, &dependency);
                } else {
                    rg_log.err("vkCmdPipelineBarrier2 function pointer is NULL!", .{});
                }
            },
            .Buffer => |buffer| {
                const queue_changed = (old_state.queue_family != c.VK_QUEUE_FAMILY_IGNORED and
                    new_access.queue_family != c.VK_QUEUE_FAMILY_IGNORED and
                    old_state.queue_family != new_access.queue_family);

                if (!queue_changed and
                    old_state.access_mask == new_access.access_mask and
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

                if (queue_changed) {
                    barrier.srcQueueFamilyIndex = old_state.queue_family;
                    barrier.dstQueueFamilyIndex = new_access.queue_family;
                } else {
                    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                }

                barrier.buffer = buffer;
                barrier.offset = 0;
                barrier.size = c.VK_WHOLE_SIZE;

                var dependency = std.mem.zeroes(c.VkDependencyInfo);
                dependency.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
                dependency.dependencyFlags = 0;
                dependency.bufferMemoryBarrierCount = 1;
                dependency.pBufferMemoryBarriers = &barrier;

                if (state.context.vkCmdPipelineBarrier2) |func| {
                    func(cmd, &dependency);
                } else {
                    rg_log.err("vkCmdPipelineBarrier2 function pointer is NULL!", .{});
                }
            },
        }
    }

    pub fn execute(self: *RenderGraph, cmd: c.VkCommandBuffer, state: *types.VulkanState) void {
        // Allocate transient resources (simplified: allocate on demand if needed, or upfront)
        // For this implementation, we'll iterate and allocate any missing transients
        var res_it = self.resources.iterator();
        while (res_it.next()) |entry| {
            const res = entry.value_ptr;
            if (res.lifecycle == .Transient and res.handle == null) {
                // Allocation logic here
                switch (res.desc.?) {
                    .Image => |img_desc| {
                        // Try to acquire from pool
                        if (self.acquire_pooled_image(img_desc)) |pooled| {
                            res.handle = .{ .Image = pooled.image };
                            res.allocation = pooled.allocation;
                            res.memory = pooled.memory;
                            res.image_view = pooled.image_view;
                        } else {
                            var imageInfo = std.mem.zeroes(c.VkImageCreateInfo);
                            imageInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
                            imageInfo.imageType = c.VK_IMAGE_TYPE_2D;
                            imageInfo.extent.width = img_desc.width;
                            imageInfo.extent.height = img_desc.height;
                            imageInfo.extent.depth = 1;
                            imageInfo.mipLevels = 1;
                            imageInfo.arrayLayers = 1;
                            imageInfo.format = img_desc.format;
                            imageInfo.tiling = c.VK_IMAGE_TILING_OPTIMAL;
                            imageInfo.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
                            imageInfo.usage = img_desc.usage;
                            imageInfo.samples = c.VK_SAMPLE_COUNT_1_BIT;
                            imageInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

                            var image: c.VkImage = null;
                            var memory: c.VkDeviceMemory = null;
                            var allocation: c.VmaAllocation = null;

                            // If we allocate a fresh image, we MUST ensure the logical state tracks it as UNDEFINED
                            if (self.resource_states.getPtr(res.id)) |res_state| {
                                res_state.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
                                res_state.access_mask = c.VK_ACCESS_2_NONE;
                                res_state.stage_mask = c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
                                res_state.queue_family = c.VK_QUEUE_FAMILY_IGNORED;
                            }

                            if (vk_allocator.allocate_image(&state.allocator, &imageInfo, &image, &memory, &allocation, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
                                res.handle = .{ .Image = image };
                                res.allocation = allocation;
                                res.memory = memory;

                                // Create view if needed
                                var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
                                viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
                                viewInfo.image = image;
                                viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
                                viewInfo.format = img_desc.format;
                                viewInfo.subresourceRange.aspectMask = img_desc.aspect_mask;
                                viewInfo.subresourceRange.levelCount = 1;
                                viewInfo.subresourceRange.layerCount = 1;

                                var view: c.VkImageView = null;
                                if (c.vkCreateImageView(state.context.device, &viewInfo, null, &view) == c.VK_SUCCESS) {
                                    res.image_view = view;
                                } else {
                                    log.cardinal_log_error("RG: Failed to create image view for transient image {d}", .{res.id});
                                }
                            } else {
                                rg_log.err("RG: Failed to allocate transient image {d}", .{res.id});
                            }
                        }
                    },
                    .Buffer => |buf_desc| {
                        if (self.acquire_pooled_buffer(buf_desc)) |pooled| {
                            res.handle = .{ .Buffer = pooled.buffer };
                            res.allocation = pooled.allocation;
                            res.memory = pooled.memory;
                        } else {
                            var bufferInfo = std.mem.zeroes(c.VkBufferCreateInfo);
                            bufferInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
                            bufferInfo.size = buf_desc.size;
                            bufferInfo.usage = buf_desc.usage;
                            bufferInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

                            var buffer: c.VkBuffer = null;
                            var memory: c.VkDeviceMemory = null;
                            var allocation: c.VmaAllocation = null;

                            if (vk_allocator.allocate_buffer(&state.allocator, &bufferInfo, &buffer, &memory, &allocation, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, false, null)) {
                                res.handle = .{ .Buffer = buffer };
                                res.allocation = allocation;
                                res.memory = memory;
                            } else {
                                rg_log.err("Failed to allocate transient buffer {d}", .{res.id});
                            }
                        }
                    },
                }
            }
        }

        for (self.passes.items) |pass| {
            if (!pass.is_active) continue;

            // Process inputs (Transition to read state)
            for (pass.inputs.items) |input| {
                if (self.resources.get(input.id)) |res| {
                    if (res.handle) |handle| {
                        if (self.resource_states.get(input.id)) |current_state| {
                            insert_barrier(cmd, handle, current_state, input, state);

                            // Update state
                            var new_state = current_state;
                            new_state.access_mask = input.access_mask;
                            new_state.stage_mask = input.stage_mask;
                            new_state.queue_family = input.queue_family;
                            if (input.type == .Image) {
                                new_state.layout = input.layout;
                            }
                            self.resource_states.put(self.allocator, input.id, new_state) catch {};
                        }
                    }
                }
            }

            // Process outputs (Transition to write state)
            for (pass.outputs.items) |output| {
                if (self.resources.get(output.id)) |res| {
                    if (res.handle) |handle| {
                        if (self.resource_states.get(output.id)) |current_state| {
                            insert_barrier(cmd, handle, current_state, output, state);

                            // Update state
                            var new_state = current_state;
                            new_state.access_mask = output.access_mask;
                            new_state.stage_mask = output.stage_mask;
                            new_state.queue_family = output.queue_family;
                            if (output.type == .Image) {
                                new_state.layout = output.layout;
                            }
                            self.resource_states.put(self.allocator, output.id, new_state) catch {};
                        }
                    }
                }
            }

            // Execute pass
            pass.execute_fn(cmd, state);
        }
    }
};
