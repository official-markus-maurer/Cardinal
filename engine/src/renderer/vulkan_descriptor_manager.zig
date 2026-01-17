const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_types.zig");
const vk_allocator = @import("vulkan_allocator.zig");

const desc_log = log.ScopedLogger("DESC_MGR");

const c = @import("vulkan_c.zig").c;

const SetPoolMap = std.AutoHashMapUnmanaged(c.VkDescriptorSet, c.VkDescriptorPool);

pub const VulkanDescriptorManagerCreateInfo = extern struct {
    bindings: ?[*]types.VulkanDescriptorBinding,
    bindingCount: u32,
    maxSets: u32,
    preferDescriptorBuffers: bool,
    poolFlags: c.VkDescriptorPoolCreateFlags,
};

// --- Zig Builder API ---

pub const DescriptorBuilder = struct {
    bindings: std.ArrayListUnmanaged(types.VulkanDescriptorBinding),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DescriptorBuilder {
        return .{
            .bindings = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DescriptorBuilder) void {
        self.bindings.deinit(self.allocator);
    }

    pub fn clear(self: *DescriptorBuilder) void {
        self.bindings.clearRetainingCapacity();
    }

    pub fn add_binding(self: *DescriptorBuilder, binding: u32, descriptor_type: c.VkDescriptorType, count: u32, stage_flags: c.VkShaderStageFlags) !void {
        try self.bindings.append(self.allocator, .{
            .binding = binding,
            .descriptorType = descriptor_type,
            .descriptorCount = count,
            .stageFlags = stage_flags,
            .pImmutableSamplers = null,
        });
    }

    pub fn build(self: *const DescriptorBuilder, manager: *types.VulkanDescriptorManager, device: c.VkDevice, allocator: *types.VulkanAllocator, vulkan_state: ?*types.VulkanState, max_sets: u32, prefer_buffers: bool) bool {
        var createInfo = std.mem.zeroes(VulkanDescriptorManagerCreateInfo);
        createInfo.bindings = self.bindings.items.ptr;
        createInfo.bindingCount = @intCast(self.bindings.items.len);
        createInfo.maxSets = max_sets;
        createInfo.preferDescriptorBuffers = prefer_buffers;
        createInfo.poolFlags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT | c.VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT;

        return vk_descriptor_manager_create(manager, device, allocator, &createInfo, vulkan_state);
    }
};

// Helper functions
fn get_binding_descriptor_type(manager: *const types.VulkanDescriptorManager, binding: u32) c.VkDescriptorType {
    if (manager.bindings == null or manager.bindingCount == 0) {
        return c.VK_DESCRIPTOR_TYPE_MAX_ENUM;
    }
    var i: u32 = 0;
    while (i < manager.bindingCount) : (i += 1) {
        if (manager.bindings.?[i].binding == binding) {
            return manager.bindings.?[i].descriptorType;
        }
    }
    return c.VK_DESCRIPTOR_TYPE_MAX_ENUM;
}

fn get_descriptor_size_for_type(state: *const types.VulkanState, dtype: c.VkDescriptorType) c.VkDeviceSize {
    return switch (dtype) {
        c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER => state.context.descriptor_buffer_uniform_buffer_size,
        c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER => state.context.descriptor_buffer_storage_buffer_size,
        c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER => state.context.descriptor_buffer_combined_image_sampler_size,
        else => 0,
    };
}

fn create_descriptor_pool(manager: *types.VulkanDescriptorManager, maxSets: u32, flags: c.VkDescriptorPoolCreateFlags) bool {
    var poolSizes: [16]c.VkDescriptorPoolSize = undefined;
    var poolSizeCount: u32 = 0;

    var i: u32 = 0;
    while (i < manager.bindingCount) : (i += 1) {
        const dtype = manager.bindings.?[i].descriptorType;

        var found = false;
        var j: u32 = 0;
        while (j < poolSizeCount) : (j += 1) {
            if (poolSizes[j].type == dtype) {
                poolSizes[j].descriptorCount += manager.bindings.?[i].descriptorCount * maxSets;
                found = true;
                break;
            }
        }

        if (!found and poolSizeCount < 16) {
            poolSizes[poolSizeCount].type = dtype;
            poolSizes[poolSizeCount].descriptorCount = manager.bindings.?[i].descriptorCount * maxSets;
            poolSizeCount += 1;
        }
    }

    if (poolSizeCount == 0) {
        desc_log.err("No descriptor types found for pool creation", .{});
        return false;
    }

    var poolInfo = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    poolInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.flags = flags;
    poolInfo.maxSets = maxSets;
    poolInfo.poolSizeCount = poolSizeCount;
    poolInfo.pPoolSizes = &poolSizes;

    if (c.vkCreateDescriptorPool(manager.device, &poolInfo, null, &manager.descriptorPool) != c.VK_SUCCESS) {
        desc_log.err("Failed to create descriptor pool", .{});
        return false;
    }

    desc_log.debug("Created descriptor pool with {d} sets and {d} pool sizes", .{ maxSets, poolSizeCount });
    return true;
}

fn create_descriptor_set_layout(manager: *types.VulkanDescriptorManager) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, manager.bindingCount * @sizeOf(c.VkDescriptorSetLayoutBinding));
    if (ptr == null) {
        desc_log.err("Failed to allocate memory for layout bindings", .{});
        return false;
    }
    const layoutBindings = @as([*]c.VkDescriptorSetLayoutBinding, @ptrCast(@alignCast(ptr.?)));
    defer memory.cardinal_free(mem_alloc, ptr.?);

    var i: u32 = 0;
    while (i < manager.bindingCount) : (i += 1) {
        layoutBindings[i].binding = manager.bindings.?[i].binding;
        layoutBindings[i].descriptorType = manager.bindings.?[i].descriptorType;
        layoutBindings[i].descriptorCount = manager.bindings.?[i].descriptorCount;
        layoutBindings[i].stageFlags = manager.bindings.?[i].stageFlags;
        layoutBindings[i].pImmutableSamplers = manager.bindings.?[i].pImmutableSamplers;
    }

    var layoutInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layoutInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = manager.bindingCount;
    layoutInfo.pBindings = layoutBindings;

    const ptr2 = memory.cardinal_calloc(mem_alloc, manager.bindingCount, @sizeOf(c.VkDescriptorBindingFlags));
    const bindingFlags = if (ptr2) |p| @as([*]c.VkDescriptorBindingFlags, @ptrCast(@alignCast(p))) else null;

    var hasUpdateAfterBind = false;

    if (bindingFlags != null) {
        defer memory.cardinal_free(mem_alloc, ptr2);

        i = 0;
        while (i < manager.bindingCount) : (i += 1) {
            if (manager.bindings.?[i].descriptorType == c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER and
                manager.bindings.?[i].descriptorCount > 1)
            {
                bindingFlags.?[i] = c.VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT |
                    c.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT;
                if (!manager.useDescriptorBuffers) {
                    bindingFlags.?[i] |= c.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT;
                    hasUpdateAfterBind = true;
                }
            } else {
                bindingFlags.?[i] = 0;
            }
        }

        var flagsInfo = std.mem.zeroes(c.VkDescriptorSetLayoutBindingFlagsCreateInfo);
        flagsInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
        flagsInfo.bindingCount = manager.bindingCount;
        flagsInfo.pBindingFlags = bindingFlags;
        layoutInfo.pNext = &flagsInfo;

        if (manager.useDescriptorBuffers) {
            layoutInfo.flags |= c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        } else if (hasUpdateAfterBind) {
            layoutInfo.flags |= c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT;
        }

        const result = c.vkCreateDescriptorSetLayout(manager.device, &layoutInfo, null, &manager.descriptorSetLayout);
        if (result != c.VK_SUCCESS) {
            desc_log.err("Failed to create descriptor set layout", .{});
            return false;
        }
    } else {
        // Fallback if allocation failed, though unlikely
        if (manager.useDescriptorBuffers) {
            layoutInfo.flags |= c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT;
        }
        const result = c.vkCreateDescriptorSetLayout(manager.device, &layoutInfo, null, &manager.descriptorSetLayout);
        if (result != c.VK_SUCCESS) {
            desc_log.err("Failed to create descriptor set layout", .{});
            return false;
        }
    }

    desc_log.debug("Created descriptor set layout with {d} bindings", .{manager.bindingCount});
    return true;
}

fn setup_descriptor_buffer(manager: *types.VulkanDescriptorManager, maxSets: u32, vulkan_state: *types.VulkanState) bool {
    if (vulkan_state.context.vkGetDescriptorSetLayoutSizeEXT == null) {
        desc_log.err("Descriptor buffer extension not available", .{});
        return false;
    }

    vulkan_state.context.vkGetDescriptorSetLayoutSizeEXT.?(manager.device, manager.descriptorSetLayout, &manager.descriptorSetSize);

    var descriptorBufferProps = std.mem.zeroes(c.VkPhysicalDeviceDescriptorBufferPropertiesEXT);
    descriptorBufferProps.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT;

    var deviceProps = std.mem.zeroes(c.VkPhysicalDeviceProperties2);
    deviceProps.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    deviceProps.pNext = &descriptorBufferProps;

    c.vkGetPhysicalDeviceProperties2(vulkan_state.context.physical_device, &deviceProps);

    const alignment = descriptorBufferProps.descriptorBufferOffsetAlignment;
    manager.descriptorSetSize = (manager.descriptorSetSize + alignment - 1) & ~(alignment - 1);

    manager.descriptorBufferSize = manager.descriptorSetSize * maxSets;

    var bufferInfo = std.mem.zeroes(c.VkBufferCreateInfo);
    bufferInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = manager.descriptorBufferSize;
    bufferInfo.usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    bufferInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    if (!vk_allocator.allocate_buffer(manager.allocator, &bufferInfo, &manager.descriptorBuffer.handle, &manager.descriptorBuffer.memory, &manager.descriptorBuffer.allocation, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, true, &manager.descriptorBuffer.mapped)) {
        desc_log.err("Failed to create and allocate descriptor buffer", .{});
        return false;
    }

    if (manager.descriptorBuffer.mapped == null) {
        desc_log.err("Failed to map descriptor buffer memory", .{});
        vk_allocator.free_buffer(manager.allocator, manager.descriptorBuffer.handle, manager.descriptorBuffer.allocation);
        return false;
    }

    var max_binding: u32 = 0;
    var i: u32 = 0;
    while (i < manager.bindingCount) : (i += 1) {
        if (manager.bindings.?[i].binding > max_binding) {
            max_binding = manager.bindings.?[i].binding;
        }
    }
    manager.bindingOffsetCount = max_binding + 1;
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_calloc(mem_alloc, manager.bindingOffsetCount, @sizeOf(c.VkDeviceSize));
    manager.bindingOffsets = if (ptr) |p| @as([*]c.VkDeviceSize, @ptrCast(@alignCast(p))) else null;

    if (manager.bindingOffsets == null) {
        desc_log.err("Failed to allocate binding offsets array", .{});
        vk_allocator.free_buffer(@ptrCast(manager.allocator), manager.descriptorBuffer.handle, manager.descriptorBuffer.allocation);
        manager.descriptorBuffer = std.mem.zeroes(types.VulkanBuffer);
        return false;
    }

    if (vulkan_state.context.vkGetDescriptorSetLayoutBindingOffsetEXT == null) {
        desc_log.err("vkGetDescriptorSetLayoutBindingOffsetEXT not loaded", .{});
        return false;
    }

    i = 0;
    while (i < manager.bindingCount) : (i += 1) {
        const b = manager.bindings.?[i].binding;
        var offset: c.VkDeviceSize = 0;
        vulkan_state.context.vkGetDescriptorSetLayoutBindingOffsetEXT.?(manager.device, manager.descriptorSetLayout, b, &offset);
        manager.bindingOffsets.?[b] = offset;
    }

    desc_log.debug("Created descriptor buffer: size={d}, set_size={d}, max_sets={d}", .{ manager.descriptorBufferSize, manager.descriptorSetSize, maxSets });
    return true;
}

fn add_retired_pool(manager: *types.VulkanDescriptorManager, pool: c.VkDescriptorPool) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);

    if (manager.retiredPoolCount >= manager.retiredPoolCapacity) {
        const new_capacity = if (manager.retiredPoolCapacity == 0) 4 else manager.retiredPoolCapacity * 2;
        const new_size = new_capacity * @sizeOf(c.VkDescriptorPool);
        const new_ptr = memory.cardinal_alloc(mem_alloc, new_size);

        if (new_ptr == null) {
            desc_log.err("Failed to grow retired pools array", .{});
            return false;
        }

        const new_pools = @as([*]c.VkDescriptorPool, @ptrCast(@alignCast(new_ptr)));

        if (manager.retiredPools != null) {
            @memcpy(new_pools[0..manager.retiredPoolCount], manager.retiredPools.?[0..manager.retiredPoolCount]);
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(manager.retiredPools)));
        }

        manager.retiredPools = new_pools;
        manager.retiredPoolCapacity = new_capacity;
    }

    manager.retiredPools.?[manager.retiredPoolCount] = pool;
    manager.retiredPoolCount += 1;
    return true;
}

// Exported functions

pub export fn vk_descriptor_manager_create(manager: ?*types.VulkanDescriptorManager, device: c.VkDevice, allocator: ?*types.VulkanAllocator, createInfo: ?*const VulkanDescriptorManagerCreateInfo, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (manager == null or device == null or allocator == null or createInfo == null or createInfo.?.bindings == null or createInfo.?.bindingCount == 0) {
        desc_log.err("Invalid parameters for descriptor manager creation", .{});
        return false;
    }
    const mgr = manager.?;
    const info = createInfo.?;

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(types.VulkanDescriptorManager)], 0);

    mgr.device = device;
    mgr.allocator = allocator;
    mgr.bindingCount = info.bindingCount;
    mgr.maxSets = info.maxSets;
    mgr.poolFlags = info.poolFlags;
    mgr.vulkan_state = vulkan_state;

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);

    const map_ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(SetPoolMap));
    if (map_ptr != null) {
        const map = @as(*SetPoolMap, @ptrCast(@alignCast(map_ptr)));
        map.* = .{};
        mgr.setPoolMapping = map;
    } else {
        desc_log.err("Failed to allocate setPoolMapping", .{});
        return false;
    }

    const ptr = memory.cardinal_alloc(mem_alloc, info.bindingCount * @sizeOf(types.VulkanDescriptorBinding));
    if (ptr == null) {
        desc_log.err("Failed to allocate memory for descriptor bindings", .{});
        return false;
    }
    mgr.bindings = @as([*]const types.VulkanDescriptorBinding, @ptrCast(@alignCast(ptr)));
    @memcpy(@as([*]u8, @ptrCast(@constCast(mgr.bindings.?)))[0 .. info.bindingCount * @sizeOf(types.VulkanDescriptorBinding)], @as([*]const u8, @ptrCast(info.bindings.?))[0 .. info.bindingCount * @sizeOf(types.VulkanDescriptorBinding)]);

    mgr.useDescriptorBuffers = info.preferDescriptorBuffers and vulkan_state != null and
        vulkan_state.?.context.vkGetDescriptorSetLayoutSizeEXT != null;

    if (!create_descriptor_set_layout(mgr)) {
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(@constCast(mgr.bindings))));
        return false;
    }

    if (mgr.useDescriptorBuffers) {
        if (!setup_descriptor_buffer(mgr, info.maxSets, vulkan_state.?)) {
            desc_log.err("Failed to setup descriptor buffer", .{});
            return false;
        }

        // Initialize free list for descriptor buffers
        const indices_ptr = memory.cardinal_alloc(mem_alloc, info.maxSets * @sizeOf(u32));
        if (indices_ptr != null) {
            mgr.freeIndices = @as([*]u32, @ptrCast(@alignCast(indices_ptr)));
            mgr.freeCount = 0;
            mgr.freeCapacity = info.maxSets;
        } else {
            desc_log.err("Failed to allocate free list for descriptor manager", .{});
            // Continue but without free list capability (append-only)
            mgr.freeIndices = null;
            mgr.freeCount = 0;
            mgr.freeCapacity = 0;
        }
    } else {
        desc_log.err("Descriptor buffers are required but not supported/enabled", .{});
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(@constCast(mgr.bindings))));
        return false;
    }

    mgr.initialized = true;
    desc_log.info("Created descriptor manager: descriptor buffers, {d} bindings, max {d} sets", .{ mgr.bindingCount, info.maxSets });
    return true;
}

pub export fn vk_descriptor_manager_destroy(manager: ?*types.VulkanDescriptorManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized) return;

    if (mgr.useDescriptorBuffers) {
        if (mgr.descriptorBuffer.mapped != null) {
            mgr.descriptorBuffer.mapped = null;
        }
        if (mgr.descriptorBuffer.handle != null) {
            vk_allocator.free_buffer(mgr.allocator, mgr.descriptorBuffer.handle, mgr.descriptorBuffer.allocation);
        }
        if (mgr.bindingOffsets != null) {
            const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(mgr.bindingOffsets)));
            mgr.bindingOffsets = null;
        }
        if (mgr.freeIndices != null) {
            const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(mgr.freeIndices)));
            mgr.freeIndices = null;
        }
    } else {
        // Legacy cleanup (should not happen if creation enforces buffers)
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        if (mgr.descriptorSets != null) {
            memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(mgr.descriptorSets)));
        }
        if (mgr.descriptorPool != null) {
            c.vkDestroyDescriptorPool(mgr.device, mgr.descriptorPool, null);
        }
    }

    if (mgr.descriptorSetLayout != null) {
        c.vkDestroyDescriptorSetLayout(mgr.device, mgr.descriptorSetLayout, null);
    }

    if (mgr.bindings != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(@constCast(mgr.bindings))));
    }

    if (mgr.setPoolMapping != null) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        const map = @as(*SetPoolMap, @ptrCast(@alignCast(mgr.setPoolMapping)));
        map.deinit(mem_alloc.as_allocator());
        memory.cardinal_free(mem_alloc, map);
        mgr.setPoolMapping = null;
    }

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(types.VulkanDescriptorManager)], 0);
    desc_log.debug("Descriptor manager destroyed", .{});
}

pub export fn vk_descriptor_manager_allocate_sets(manager: ?*types.VulkanDescriptorManager, setCount: u32, pDescriptorSets: ?[*]c.VkDescriptorSet) callconv(.c) bool {
    if (manager == null or pDescriptorSets == null) return false;
    if (setCount == 0) return true;
    const mgr = manager.?;
    if (!mgr.initialized) {
        desc_log.err("Manager not initialized", .{});
        return false;
    }

    if (mgr.useDescriptorBuffers) {
        var i: u32 = 0;
        while (i < setCount) : (i += 1) {
            var setIndex: u32 = 0;
            // Check free list first
            if (mgr.freeCount > 0 and mgr.freeIndices != null) {
                mgr.freeCount -= 1;
                setIndex = mgr.freeIndices.?[mgr.freeCount];
            } else {
                // Allocate new
                if (mgr.descriptorSetCount >= mgr.maxSets) {
                    desc_log.err("Descriptor buffer out of memory", .{});
                    return false;
                }
                setIndex = mgr.descriptorSetCount;
                mgr.descriptorSetCount += 1;
            }
            // Cast index to pseudo-handle
            // VkDescriptorSet is a pointer, so we cast the index to a pointer
            // We offset by 1 to ensure we never return NULL (0) which is considered an invalid handle
            pDescriptorSets.?[i] = @ptrFromInt(setIndex + 1);
        }
        return true;
    }

    if (mgr.device == null or mgr.descriptorPool == null) {
        desc_log.err("Invalid device or descriptor pool for allocation", .{});
        return false;
    }

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, setCount * @sizeOf(c.VkDescriptorSetLayout));
    if (ptr == null) {
        desc_log.err("Failed to allocate memory for descriptor set layouts", .{});
        return false;
    }
    const layouts = @as([*]c.VkDescriptorSetLayout, @ptrCast(@alignCast(ptr)));
    defer memory.cardinal_free(mem_alloc, ptr);

    var i: u32 = 0;
    while (i < setCount) : (i += 1) {
        layouts[i] = mgr.descriptorSetLayout;
    }

    var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool = mgr.descriptorPool;
    allocInfo.descriptorSetCount = setCount;
    allocInfo.pSetLayouts = layouts;

    var result = c.vkAllocateDescriptorSets(mgr.device, &allocInfo, pDescriptorSets);

    if (result == c.VK_ERROR_OUT_OF_POOL_MEMORY or result == c.VK_ERROR_FRAGMENTATION) {
        // Pool is full or fragmented, create a new one
        if (add_retired_pool(mgr, mgr.descriptorPool)) {
            // Create new pool with same configuration
            // Note: This overwrites mgr.descriptorPool with the new handle
            if (create_descriptor_pool(mgr, mgr.maxSets, mgr.poolFlags)) {
                allocInfo.descriptorPool = mgr.descriptorPool;
                result = c.vkAllocateDescriptorSets(mgr.device, &allocInfo, pDescriptorSets);
            }
        }
    }

    if (result != c.VK_SUCCESS) {
        desc_log.err("Failed to allocate descriptor sets: error {d}", .{result});
        return false;
    }

    i = 0;
    while (i < setCount) : (i += 1) {
        if (mgr.descriptorSetCount < mgr.maxSets) {
            // Ensure descriptorSets array is allocated before accessing
            if (mgr.descriptorSets == null) {
                const descriptor_sets_ptr = memory.cardinal_alloc(mem_alloc, mgr.maxSets * @sizeOf(c.VkDescriptorSet));
                if (descriptor_sets_ptr == null) {
                    desc_log.err("Failed to allocate memory for descriptor sets array", .{});
                    return false;
                }
                mgr.descriptorSets = @as([*]c.VkDescriptorSet, @ptrCast(@alignCast(descriptor_sets_ptr)));
            }
            mgr.descriptorSets.?[mgr.descriptorSetCount] = pDescriptorSets.?[i];
            mgr.descriptorSetCount += 1;
        } else {
            desc_log.warn("Descriptor set limit reached ({d}), not tracking new set", .{mgr.maxSets});
        }
    }

    if (mgr.setPoolMapping != null) {
        const map = @as(*SetPoolMap, @ptrCast(@alignCast(mgr.setPoolMapping)));
        i = 0;
        while (i < setCount) : (i += 1) {
            // Ensure we track which pool this set came from!
            // allocInfo.descriptorPool was updated if we created a new pool.
            // desc_log.debug("Mapping set 0x{x} to pool 0x{x}", .{ @intFromPtr(pDescriptorSets.?[i]), @intFromPtr(allocInfo.descriptorPool) });
            map.put(std.heap.c_allocator, pDescriptorSets.?[i], allocInfo.descriptorPool) catch {};
        }
    }

    desc_log.debug("Allocated {d} descriptor sets", .{setCount});
    return true;
}

pub export fn vk_descriptor_manager_allocate(manager: ?*types.VulkanDescriptorManager) callconv(.c) bool {
    if (manager == null) return false;
    var set: c.VkDescriptorSet = null;
    return vk_descriptor_manager_allocate_sets(manager, 1, @ptrCast(&set));
}

pub export fn vk_descriptor_manager_update_buffer(manager: ?*types.VulkanDescriptorManager, set: c.VkDescriptorSet, binding: u32, buffer: c.VkBuffer, offset: c.VkDeviceSize, range: c.VkDeviceSize) callconv(.c) bool {
    if (manager == null) return false;
    const mgr = manager.?;
    if (!mgr.initialized) return false;

    const dtype = get_binding_descriptor_type(mgr, binding);
    if (dtype == c.VK_DESCRIPTOR_TYPE_MAX_ENUM) {
        desc_log.err("Unknown descriptor type for binding {d}", .{binding});
        return false;
    }

    if (mgr.useDescriptorBuffers) {
        // Adjust for 1-based index
        const setHandle = @as(u32, @intCast(@intFromPtr(set)));
        if (setHandle == 0) return false;
        const setIndex = setHandle - 1;

        if (dtype != c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER and dtype != c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER) {
            desc_log.warn("Descriptor buffer update only implemented for UNIFORM_BUFFER and STORAGE_BUFFER", .{});
            return false;
        }

        if (mgr.vulkan_state == null) {
            desc_log.err("Descriptor buffer extension not available for updates", .{});
            return false;
        }
        const vs = @as(*types.VulkanState, @ptrCast(@alignCast(mgr.vulkan_state)));
        if (vs.context.vkGetDescriptorEXT == null) {
            desc_log.err("Descriptor buffer extension not available for updates", .{});
            return false;
        }

        var addrInfo = std.mem.zeroes(c.VkBufferDeviceAddressInfo);
        addrInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
        addrInfo.buffer = buffer;

        const bufferAddress = vs.context.vkGetBufferDeviceAddress.?(mgr.device, &addrInfo);

        var addressDesc = std.mem.zeroes(c.VkDescriptorAddressInfoEXT);
        addressDesc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT;
        addressDesc.address = bufferAddress + offset;
        addressDesc.range = range;

        var getInfo = std.mem.zeroes(c.VkDescriptorGetInfoEXT);
        getInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
        getInfo.type = dtype;
        if (dtype == c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            getInfo.data.pUniformBuffer = &addressDesc;
        } else {
            getInfo.data.pStorageBuffer = &addressDesc;
        }

        const setOffset = mgr.descriptorSetSize * setIndex;
        const bindingOffset = if (binding < mgr.bindingOffsetCount) mgr.bindingOffsets.?[binding] else 0;
        const dstOffset = setOffset + bindingOffset;

        const descSize = get_descriptor_size_for_type(vs, dtype);
        if (descSize == 0) return false;

        const dstPtr = @as([*]u8, @ptrCast(mgr.descriptorBuffer.mapped)) + dstOffset;
        vs.context.vkGetDescriptorEXT.?(mgr.device, &getInfo, descSize, @ptrCast(dstPtr));

        return true;
    } else {
        var bufferInfo = std.mem.zeroes(c.VkDescriptorBufferInfo);
        bufferInfo.buffer = buffer;
        bufferInfo.offset = offset;
        bufferInfo.range = range;

        var descriptorWrite = std.mem.zeroes(c.VkWriteDescriptorSet);
        descriptorWrite.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        descriptorWrite.dstSet = set;
        descriptorWrite.dstBinding = binding;
        descriptorWrite.dstArrayElement = 0;
        descriptorWrite.descriptorType = dtype;
        descriptorWrite.descriptorCount = 1;
        descriptorWrite.pBufferInfo = &bufferInfo;

        c.vkUpdateDescriptorSets(mgr.device, 1, &descriptorWrite, 0, null);
        return true;
    }
}

pub export fn vk_descriptor_manager_update_image(manager: ?*types.VulkanDescriptorManager, set: c.VkDescriptorSet, binding: u32, imageView: c.VkImageView, sampler: c.VkSampler, imageLayout: c.VkImageLayout) callconv(.c) bool {
    if (manager == null) return false;
    const mgr = manager.?;
    if (!mgr.initialized) return false;

    const dtype = get_binding_descriptor_type(mgr, binding);
    if (dtype == c.VK_DESCRIPTOR_TYPE_MAX_ENUM) return false;

    if (mgr.useDescriptorBuffers) {
        // Adjust for 1-based index
        const setHandle = @as(u32, @intCast(@intFromPtr(set)));
        if (setHandle == 0) return false;
        const setIndex = setHandle - 1;

        if (dtype != c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) return false;
        if (mgr.vulkan_state == null) return false;
        const vs = @as(*types.VulkanState, @ptrCast(@alignCast(mgr.vulkan_state)));

        var imageInfo = std.mem.zeroes(c.VkDescriptorImageInfo);
        imageInfo.imageLayout = imageLayout;
        imageInfo.imageView = imageView;
        imageInfo.sampler = sampler;

        var getInfo = std.mem.zeroes(c.VkDescriptorGetInfoEXT);
        getInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
        getInfo.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        getInfo.data.pCombinedImageSampler = &imageInfo;

        const setOffset = mgr.descriptorSetSize * setIndex;
        const bindingOffset = if (binding < mgr.bindingOffsetCount) mgr.bindingOffsets.?[binding] else 0;
        const dstOffset = setOffset + bindingOffset;
        const descSize = get_descriptor_size_for_type(vs, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);

        const dstPtr = @as([*]u8, @ptrCast(mgr.descriptorBuffer.mapped)) + dstOffset;
        vs.context.vkGetDescriptorEXT.?(mgr.device, &getInfo, descSize, @ptrCast(dstPtr));
        return true;
    }

    return false;
}

// Internal helper for textures update
fn update_textures_internal(manager: *types.VulkanDescriptorManager, set: c.VkDescriptorSet, binding: u32, imageViews: [*]c.VkImageView, samplers: ?[*]c.VkSampler, singleSampler: c.VkSampler, imageLayout: c.VkImageLayout, count: u32, dtype: c.VkDescriptorType) bool {
    if (manager.useDescriptorBuffers) {
        // Adjust for 1-based index
        const setHandle = @as(u32, @intCast(@intFromPtr(set)));
        if (setHandle == 0) return false;
        const setIndex = setHandle - 1;

        if (manager.vulkan_state == null) return false;
        const vs = @as(*types.VulkanState, @ptrCast(@alignCast(manager.vulkan_state)));

        const setOffset = manager.descriptorSetSize * setIndex;
        const bindingOffset = if (binding < manager.bindingOffsetCount) manager.bindingOffsets.?[binding] else 0;
        const descSize = get_descriptor_size_for_type(vs, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var imageInfo = std.mem.zeroes(c.VkDescriptorImageInfo);
            imageInfo.imageLayout = imageLayout;
            imageInfo.imageView = imageViews[i];
            imageInfo.sampler = if (samplers) |s| s[i] else singleSampler;

            var getInfo = std.mem.zeroes(c.VkDescriptorGetInfoEXT);
            getInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
            getInfo.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            getInfo.data.pCombinedImageSampler = &imageInfo;

            const dstOffset = setOffset + bindingOffset + (i * descSize);
            const dstPtr = @as([*]u8, @ptrCast(manager.descriptorBuffer.mapped)) + dstOffset;
            vs.context.vkGetDescriptorEXT.?(manager.device, &getInfo, descSize, @ptrCast(dstPtr));
        }
        return true;
    } else {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        const ptr = memory.cardinal_alloc(mem_alloc, count * @sizeOf(c.VkDescriptorImageInfo));
        if (ptr == null) return false;
        const imageInfos = @as([*]c.VkDescriptorImageInfo, @ptrCast(@alignCast(ptr)));
        defer memory.cardinal_free(mem_alloc, ptr);

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            imageInfos[i].imageLayout = imageLayout;
            imageInfos[i].imageView = imageViews[i];
            imageInfos[i].sampler = if (samplers) |s| s[i] else singleSampler;
        }

        var descriptorWrite = std.mem.zeroes(c.VkWriteDescriptorSet);
        descriptorWrite.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        descriptorWrite.dstSet = set;
        descriptorWrite.dstBinding = binding;
        descriptorWrite.descriptorType = dtype;
        descriptorWrite.descriptorCount = count;
        descriptorWrite.pImageInfo = imageInfos;

        c.vkUpdateDescriptorSets(manager.device, 1, &descriptorWrite, 0, null);
        return true;
    }
}

// Re-implement exports using helper
pub export fn vk_descriptor_manager_update_textures(manager: ?*types.VulkanDescriptorManager, set: c.VkDescriptorSet, binding: u32, imageViews: ?[*]c.VkImageView, sampler: c.VkSampler, imageLayout: c.VkImageLayout, count: u32) callconv(.c) bool {
    if (manager == null or imageViews == null or count == 0) return false;
    const mgr = manager.?;
    if (!mgr.initialized) return false;
    const dtype = get_binding_descriptor_type(mgr, binding);
    if (dtype == c.VK_DESCRIPTOR_TYPE_MAX_ENUM) return false;
    return update_textures_internal(mgr, set, binding, imageViews.?, null, sampler, imageLayout, count, dtype);
}

pub export fn vk_descriptor_manager_update_textures_with_samplers(manager: ?*types.VulkanDescriptorManager, set: c.VkDescriptorSet, binding: u32, imageViews: ?[*]c.VkImageView, samplers: ?[*]c.VkSampler, imageLayout: c.VkImageLayout, count: u32) callconv(.c) bool {
    if (manager == null or imageViews == null or count == 0) return false;
    const mgr = manager.?;
    if (!mgr.initialized) return false;
    const dtype = get_binding_descriptor_type(mgr, binding);
    if (dtype == c.VK_DESCRIPTOR_TYPE_MAX_ENUM) return false;
    return update_textures_internal(mgr, set, binding, imageViews.?, samplers, null, imageLayout, count, dtype);
}

pub export fn vk_descriptor_manager_bind_sets(manager: ?*types.VulkanDescriptorManager, commandBuffer: c.VkCommandBuffer, pipelineLayout: c.VkPipelineLayout, firstSet: u32, setCount: u32, pDescriptorSets: ?[*]const c.VkDescriptorSet, dynamicOffsetCount: u32, pDynamicOffsets: ?[*]const u32) callconv(.c) void {
    vk_descriptor_manager_bind_sets_with_buffer_index(manager, commandBuffer, pipelineLayout, firstSet, setCount, pDescriptorSets, dynamicOffsetCount, pDynamicOffsets, 0);
}

pub export fn vk_descriptor_manager_bind_sets_with_buffer_index(manager: ?*types.VulkanDescriptorManager, commandBuffer: c.VkCommandBuffer, pipelineLayout: c.VkPipelineLayout, firstSet: u32, setCount: u32, pDescriptorSets: ?[*]const c.VkDescriptorSet, dynamicOffsetCount: u32, pDynamicOffsets: ?[*]const u32, bufferIndex: u32) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or setCount == 0) return;

    if (mgr.useDescriptorBuffers) {
        if (mgr.vulkan_state == null) return;
        const vs = @as(*types.VulkanState, @ptrCast(@alignCast(mgr.vulkan_state)));

        if (bufferIndex == 0) {
            var addressInfo = std.mem.zeroes(c.VkBufferDeviceAddressInfo);
            addressInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
            addressInfo.buffer = mgr.descriptorBuffer.handle;

            const baseAddress = vs.context.vkGetBufferDeviceAddress.?(mgr.device, &addressInfo);

            var bindingInfo = std.mem.zeroes(c.VkDescriptorBufferBindingInfoEXT);
            bindingInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT;
            bindingInfo.address = baseAddress;
            bindingInfo.usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT;

            vs.context.vkCmdBindDescriptorBuffersEXT.?(commandBuffer, 1, &bindingInfo);
        }

        vk_descriptor_manager_set_offsets(manager, commandBuffer, pipelineLayout, firstSet, setCount, pDescriptorSets, bufferIndex);
    } else {
        if (pDescriptorSets == null) return;
        c.vkCmdBindDescriptorSets(commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, firstSet, setCount, pDescriptorSets, dynamicOffsetCount, pDynamicOffsets);
    }
}

pub export fn vk_descriptor_manager_get_buffer_handle(manager: ?*types.VulkanDescriptorManager) callconv(.c) c.VkBuffer {
    if (manager) |mgr| {
        if (mgr.useDescriptorBuffers) return mgr.descriptorBuffer.handle;
    }
    return null;
}

pub export fn vk_descriptor_manager_get_binding_info(manager: ?*types.VulkanDescriptorManager, outInfo: *c.VkDescriptorBufferBindingInfoEXT) callconv(.c) bool {
    if (manager == null) return false;
    const mgr = manager.?;
    if (!mgr.initialized or !mgr.useDescriptorBuffers or mgr.vulkan_state == null) return false;

    const vs = @as(*types.VulkanState, @ptrCast(@alignCast(mgr.vulkan_state)));

    var addressInfo = std.mem.zeroes(c.VkBufferDeviceAddressInfo);
    addressInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO;
    addressInfo.buffer = mgr.descriptorBuffer.handle;

    const baseAddress = vs.context.vkGetBufferDeviceAddress.?(mgr.device, &addressInfo);

    outInfo.* = std.mem.zeroes(c.VkDescriptorBufferBindingInfoEXT);
    outInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT;
    outInfo.address = baseAddress;
    outInfo.usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT;

    return true;
}

pub export fn vk_descriptor_manager_set_offsets(manager: ?*types.VulkanDescriptorManager, commandBuffer: c.VkCommandBuffer, pipelineLayout: c.VkPipelineLayout, firstSet: u32, setCount: u32, pDescriptorSets: ?[*]const c.VkDescriptorSet, bufferIndex: u32) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized or !mgr.useDescriptorBuffers or mgr.vulkan_state == null) return;

    const vs = @as(*types.VulkanState, @ptrCast(@alignCast(mgr.vulkan_state)));

    // Use stack buffer for small counts to avoid malloc
    var stack_indices: [8]u32 = undefined;
    var stack_offsets: [8]c.VkDeviceSize = undefined;

    var bufferIndices: [*]u32 = &stack_indices;
    var offsets: [*]c.VkDeviceSize = &stack_offsets;

    // Heap allocation fallback for large counts
    var ptr1: ?*anyopaque = null;
    var ptr2: ?*anyopaque = null;

    if (setCount > 8) {
        ptr1 = c.malloc(setCount * @sizeOf(u32));
        ptr2 = c.malloc(setCount * @sizeOf(c.VkDeviceSize));
        if (ptr1 == null or ptr2 == null) {
            if (ptr1) |p| c.free(p);
            if (ptr2) |p| c.free(p);
            return;
        }
        bufferIndices = @as([*]u32, @ptrCast(@alignCast(ptr1)));
        offsets = @as([*]c.VkDeviceSize, @ptrCast(@alignCast(ptr2)));
    }
    defer {
        if (ptr1) |p| c.free(p);
        if (ptr2) |p| c.free(p);
    }

    var i: u32 = 0;
    while (i < setCount) : (i += 1) {
        bufferIndices[i] = bufferIndex;
        // Extract index from pseudo-handle if provided
        if (pDescriptorSets) |sets| {
            const setHandle = @intFromPtr(sets[i]);
            if (setHandle > 0) {
                const setIndex = setHandle - 1;
                offsets[i] = mgr.descriptorSetSize * @as(u32, @intCast(setIndex));
            } else {
                offsets[i] = 0;
            }
        } else {
            offsets[i] = mgr.descriptorSetSize * (firstSet + i);
        }
    }

    vs.context.vkCmdSetDescriptorBufferOffsetsEXT.?(commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, firstSet, setCount, bufferIndices, offsets);
}

pub export fn vk_descriptor_manager_get_layout(manager: ?*const types.VulkanDescriptorManager) callconv(.c) c.VkDescriptorSetLayout {
    return if (manager) |mgr| mgr.descriptorSetLayout else null;
}

pub export fn vk_descriptor_manager_uses_buffers(manager: ?*const types.VulkanDescriptorManager) callconv(.c) bool {
    return if (manager) |mgr| mgr.useDescriptorBuffers else false;
}

pub export fn vk_descriptor_manager_get_set_size(manager: ?*const types.VulkanDescriptorManager) callconv(.c) c.VkDeviceSize {
    return if (manager) |mgr| mgr.descriptorSetSize else 0;
}

pub export fn vk_descriptor_manager_get_set_data(manager: ?*types.VulkanDescriptorManager, setIndex: u32) callconv(.c) ?*anyopaque {
    if (manager == null) return null;
    const mgr = manager.?;
    if (!mgr.useDescriptorBuffers or mgr.descriptorBuffer.mapped == null) return null;

    const offset = setIndex * mgr.descriptorSetSize;
    return @ptrCast(@as([*]u8, @ptrCast(mgr.descriptorBuffer.mapped)) + offset);
}

pub export fn vk_descriptor_manager_free_set(manager: ?*types.VulkanDescriptorManager, descriptorSet: c.VkDescriptorSet) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized) return;

    if (mgr.useDescriptorBuffers) {
        if (mgr.freeIndices != null and mgr.freeCount < mgr.freeCapacity) {
            const setHandle = @as(u32, @intCast(@intFromPtr(descriptorSet)));
            if (setHandle > 0) {
                const setIndex = setHandle - 1;
                mgr.freeIndices.?[mgr.freeCount] = setIndex;
                mgr.freeCount += 1;
            }
        }
    }
}

pub export fn vk_descriptor_manager_reset(manager: ?*types.VulkanDescriptorManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;
    if (!mgr.initialized) return;

    if (mgr.useDescriptorBuffers) {
        mgr.descriptorSetCount = 0;
        mgr.freeCount = 0;
    } else {
        if (mgr.retiredPools != null) {
            var i: u32 = 0;
            while (i < mgr.retiredPoolCount) : (i += 1) {
                c.vkDestroyDescriptorPool(mgr.device, mgr.retiredPools.?[i], null);
            }
            mgr.retiredPoolCount = 0;
        }
        _ = c.vkResetDescriptorPool(mgr.device, mgr.descriptorPool, 0);

        if (mgr.setPoolMapping != null) {
            const map = @as(*SetPoolMap, @ptrCast(@alignCast(mgr.setPoolMapping)));
            map.clearAndFree(std.heap.c_allocator);
        }

        mgr.descriptorSetCount = 0;
    }
}
