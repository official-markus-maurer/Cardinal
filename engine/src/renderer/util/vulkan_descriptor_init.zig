//! Descriptor manager creation helpers.
//!
//! Provides small utilities to build `VulkanDescriptorManager` instances from binding maps.
const std = @import("std");
const memory = @import("../../core/memory.zig");
const types = @import("../vulkan_types.zig");
const descriptor_mgr = @import("../vulkan_descriptor_manager.zig");
const c = @import("../vulkan_c.zig").c;

pub fn create_descriptor_manager_from_binding_map(alloc: std.mem.Allocator, out_manager: *?*types.VulkanDescriptorManager, device: c.VkDevice, allocator: *types.VulkanAllocator, vulkan_state: ?*types.VulkanState, map: anytype, max_sets: u32, prefer_descriptor_buffers: bool) bool {
    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(mem_alloc, @sizeOf(types.VulkanDescriptorManager));
    if (ptr == null) return false;
    const mgr = @as(*types.VulkanDescriptorManager, @ptrCast(@alignCast(ptr)));
    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(types.VulkanDescriptorManager)], 0);

    var builder = descriptor_mgr.DescriptorBuilder.init(alloc);
    defer builder.deinit();

    var keys = std.ArrayListUnmanaged(u32){};
    defer keys.deinit(alloc);

    var kit = map.keyIterator();
    while (kit.next()) |k| {
        keys.append(alloc, k.*) catch {
            memory.cardinal_free(mem_alloc, ptr);
            return false;
        };
    }
    std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));

    for (keys.items) |k| {
        const entry = map.get(k) orelse {
            memory.cardinal_free(mem_alloc, ptr);
            return false;
        };
        const b: c.VkDescriptorSetLayoutBinding = blk: {
            if (@TypeOf(entry) == c.VkDescriptorSetLayoutBinding) break :blk entry;
            const EntryT = @TypeOf(entry);
            if (@hasField(EntryT, "binding") and @TypeOf(@field(entry, "binding")) == c.VkDescriptorSetLayoutBinding) {
                break :blk @field(entry, "binding");
            }
            @compileError("Unsupported binding map value type");
        };
        builder.add_binding(b.binding, b.descriptorType, b.descriptorCount, b.stageFlags) catch {
            memory.cardinal_free(mem_alloc, ptr);
            return false;
        };
    }

    if (!builder.build(mgr, device, allocator, vulkan_state, max_sets, prefer_descriptor_buffers)) {
        memory.cardinal_free(mem_alloc, ptr);
        return false;
    }

    out_manager.* = mgr;
    return true;
}
