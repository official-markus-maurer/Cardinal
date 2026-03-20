//! Vulkan maintenance8 synchronization helpers.
//!
//! Builds `Vk*MemoryBarrier2` structures for queue-family ownership transfers and records the
//! corresponding `vkCmdPipelineBarrier2` calls, optionally enabling the maintenance8
//! "use all stages" enhancement when available.
const std = @import("std");
const log = @import("../core/log.zig");
const maint8_log = log.ScopedLogger("MAINT8_SYNC");
const types = @import("vulkan_types.zig");
const vk_barrier_validation = @import("vulkan_barrier_validation.zig");
const platform = @import("../core/platform.zig");

const c = @import("vulkan_c.zig").c;

/// Fills `out_barrier` for an image ownership transfer + layout transition.
pub export fn vk_create_enhanced_image_barrier(transfer_info: ?*const types.VkQueueFamilyOwnershipTransferInfo, image: c.VkImage, old_layout: c.VkImageLayout, new_layout: c.VkImageLayout, subresource_range: c.VkImageSubresourceRange, out_barrier: ?*c.VkImageMemoryBarrier2) callconv(.c) bool {
    if (transfer_info == null or out_barrier == null) {
        maint8_log.err("Invalid parameters for enhanced image barrier creation", .{});
        return false;
    }

    out_barrier.?.* = std.mem.zeroes(c.VkImageMemoryBarrier2);
    out_barrier.?.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    out_barrier.?.pNext = null;

    out_barrier.?.srcStageMask = transfer_info.?.src_stage_mask;
    out_barrier.?.dstStageMask = transfer_info.?.dst_stage_mask;
    out_barrier.?.srcAccessMask = transfer_info.?.src_access_mask;
    out_barrier.?.dstAccessMask = transfer_info.?.dst_access_mask;

    out_barrier.?.oldLayout = old_layout;
    out_barrier.?.newLayout = new_layout;

    out_barrier.?.srcQueueFamilyIndex = transfer_info.?.src_queue_family;
    out_barrier.?.dstQueueFamilyIndex = transfer_info.?.dst_queue_family;

    out_barrier.?.image = image;
    out_barrier.?.subresourceRange = subresource_range;

    maint8_log.debug("[Thread {d}] Enhanced image barrier: queue families {d}->{d}, stages 0x{x}->0x{x}", .{ platform.get_current_thread_id(), transfer_info.?.src_queue_family, transfer_info.?.dst_queue_family, transfer_info.?.src_stage_mask, transfer_info.?.dst_stage_mask });

    return true;
}

/// Fills `out_barrier` for a buffer ownership transfer.
pub export fn vk_create_enhanced_buffer_barrier(transfer_info: ?*const types.VkQueueFamilyOwnershipTransferInfo, buffer: c.VkBuffer, offset: c.VkDeviceSize, size: c.VkDeviceSize, out_barrier: ?*c.VkBufferMemoryBarrier2) callconv(.c) bool {
    if (transfer_info == null or out_barrier == null) {
        maint8_log.err("Invalid parameters for enhanced buffer barrier creation", .{});
        return false;
    }

    out_barrier.?.* = std.mem.zeroes(c.VkBufferMemoryBarrier2);
    out_barrier.?.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2;
    out_barrier.?.pNext = null;

    out_barrier.?.srcStageMask = transfer_info.?.src_stage_mask;
    out_barrier.?.dstStageMask = transfer_info.?.dst_stage_mask;
    out_barrier.?.srcAccessMask = transfer_info.?.src_access_mask;
    out_barrier.?.dstAccessMask = transfer_info.?.dst_access_mask;

    out_barrier.?.srcQueueFamilyIndex = transfer_info.?.src_queue_family;
    out_barrier.?.dstQueueFamilyIndex = transfer_info.?.dst_queue_family;

    out_barrier.?.buffer = buffer;
    out_barrier.?.offset = offset;
    out_barrier.?.size = size;

    maint8_log.debug("[Thread {d}] Enhanced buffer barrier: queue families {d}->{d}, stages 0x{x}->0x{x}", .{ platform.get_current_thread_id(), transfer_info.?.src_queue_family, transfer_info.?.dst_queue_family, transfer_info.?.src_stage_mask, transfer_info.?.dst_stage_mask });

    return true;
}

/// Records a queue-family ownership transfer pipeline barrier using `vkCmdPipelineBarrier2_func`.
pub export fn vk_record_enhanced_ownership_transfer(cmd: c.VkCommandBuffer, transfer_info: ?*const types.VkQueueFamilyOwnershipTransferInfo, image_barrier_count: u32, image_barriers: ?[*]const c.VkImageMemoryBarrier2, buffer_barrier_count: u32, buffer_barriers: ?[*]const c.VkBufferMemoryBarrier2, vkCmdPipelineBarrier2_func: c.PFN_vkCmdPipelineBarrier2) callconv(.c) bool {
    if (cmd == null or transfer_info == null or vkCmdPipelineBarrier2_func == null) {
        maint8_log.err("Invalid parameters for enhanced ownership transfer", .{});
        return false;
    }

    if (image_barrier_count == 0 and buffer_barrier_count == 0) {
        maint8_log.warn("No barriers specified for ownership transfer", .{});
        return true;
    }

    var dependency_info = std.mem.zeroes(c.VkDependencyInfo);
    dependency_info.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dependency_info.pNext = null;

    if (transfer_info.?.use_maintenance8_enhancement and transfer_info.?.src_queue_family != transfer_info.?.dst_queue_family) {
        dependency_info.dependencyFlags = c.VK_DEPENDENCY_QUEUE_FAMILY_OWNERSHIP_TRANSFER_USE_ALL_STAGES_BIT_KHR;
        maint8_log.debug("Using maintenance8 enhanced synchronization for queue family ownership transfer", .{});
    } else {
        dependency_info.dependencyFlags = 0;
        if (transfer_info.?.src_queue_family != transfer_info.?.dst_queue_family) {
            maint8_log.debug("Using standard synchronization for queue family ownership transfer", .{});
        }
    }

    dependency_info.imageMemoryBarrierCount = image_barrier_count;
    dependency_info.pImageMemoryBarriers = image_barriers;
    dependency_info.bufferMemoryBarrierCount = buffer_barrier_count;
    dependency_info.pBufferMemoryBarriers = buffer_barriers;

    maint8_log.debug("[Thread {d}] Recording enhanced ownership transfer: {d} images, {d} buffers", .{ platform.get_current_thread_id(), image_barrier_count, buffer_barrier_count });

    if (!vk_barrier_validation.cardinal_barrier_validation_validate_pipeline_barrier(&dependency_info, cmd, platform.get_current_thread_id())) {
        maint8_log.warn("Pipeline barrier validation failed for enhanced ownership transfer", .{});
    }

    vkCmdPipelineBarrier2_func.?(cmd, &dependency_info);

    maint8_log.info("Recorded enhanced ownership transfer: {d} image barriers, {d} buffer barriers, maintenance8={s}", .{ image_barrier_count, buffer_barrier_count, if (transfer_info.?.use_maintenance8_enhancement) "enabled" else "disabled" });

    return true;
}

/// Initializes `out_transfer_info` with stage/access masks and optional maintenance8 flags.
pub export fn vk_create_queue_family_transfer_info(src_queue_family: u32, dst_queue_family: u32, src_stage_mask: c.VkPipelineStageFlags2, dst_stage_mask: c.VkPipelineStageFlags2, src_access_mask: c.VkAccessFlags2, dst_access_mask: c.VkAccessFlags2, supports_maintenance8: bool, out_transfer_info: ?*types.VkQueueFamilyOwnershipTransferInfo) callconv(.c) bool {
    if (out_transfer_info == null) {
        maint8_log.err("Invalid output parameter for transfer info creation", .{});
        return false;
    }

    out_transfer_info.?.* = std.mem.zeroes(types.VkQueueFamilyOwnershipTransferInfo);
    out_transfer_info.?.src_queue_family = src_queue_family;
    out_transfer_info.?.dst_queue_family = dst_queue_family;
    out_transfer_info.?.src_stage_mask = src_stage_mask;
    out_transfer_info.?.dst_stage_mask = dst_stage_mask;
    out_transfer_info.?.src_access_mask = src_access_mask;
    out_transfer_info.?.dst_access_mask = dst_access_mask;
    out_transfer_info.?.use_maintenance8_enhancement = supports_maintenance8 and (src_queue_family != dst_queue_family);

    maint8_log.debug("Created queue family transfer info: {d} -> {d}, maintenance8={s}", .{ src_queue_family, dst_queue_family, if (out_transfer_info.?.use_maintenance8_enhancement) "enabled" else "disabled" });

    return true;
}
