const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");

const c = @import("vulkan_c.zig").c;

fn get_current_thread_id() u32 {
    if (builtin.os.tag == .windows) {
        return c.GetCurrentThreadId();
    } else {
        return @intCast(c.syscall(c.SYS_gettid));
    }
}

pub export fn vk_create_enhanced_image_barrier(
    transfer_info: ?*const types.VkQueueFamilyOwnershipTransferInfo,
    image: c.VkImage,
    old_layout: c.VkImageLayout,
    new_layout: c.VkImageLayout,
    subresource_range: c.VkImageSubresourceRange,
    out_barrier: ?*c.VkImageMemoryBarrier2
) callconv(.c) bool {
    if (transfer_info == null or out_barrier == null) {
        log.cardinal_log_error("[MAINTENANCE8_SYNC] Invalid parameters for enhanced image barrier creation", .{});
        return false;
    }

    // Initialize the barrier structure
    out_barrier.?.* = std.mem.zeroes(c.VkImageMemoryBarrier2);
    out_barrier.?.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    out_barrier.?.pNext = null;

    // Set stage and access masks
    out_barrier.?.srcStageMask = transfer_info.?.src_stage_mask;
    out_barrier.?.dstStageMask = transfer_info.?.dst_stage_mask;
    out_barrier.?.srcAccessMask = transfer_info.?.src_access_mask;
    out_barrier.?.dstAccessMask = transfer_info.?.dst_access_mask;

    // Set layout transition
    out_barrier.?.oldLayout = old_layout;
    out_barrier.?.newLayout = new_layout;

    // Set queue family ownership transfer
    out_barrier.?.srcQueueFamilyIndex = transfer_info.?.src_queue_family;
    out_barrier.?.dstQueueFamilyIndex = transfer_info.?.dst_queue_family;

    // Set image and subresource range
    out_barrier.?.image = image;
    out_barrier.?.subresourceRange = subresource_range;

    log.cardinal_log_debug("[Thread {d}] Enhanced image barrier: queue families {d}->{d}, stages 0x{x}->0x{x}", .{
        get_current_thread_id(),
        transfer_info.?.src_queue_family,
        transfer_info.?.dst_queue_family,
        transfer_info.?.src_stage_mask,
        transfer_info.?.dst_stage_mask
    });

    return true;
}

pub export fn vk_create_enhanced_buffer_barrier(
    transfer_info: ?*const types.VkQueueFamilyOwnershipTransferInfo,
    buffer: c.VkBuffer,
    offset: c.VkDeviceSize,
    size: c.VkDeviceSize,
    out_barrier: ?*c.VkBufferMemoryBarrier2
) callconv(.c) bool {
    if (transfer_info == null or out_barrier == null) {
        log.cardinal_log_error("[MAINTENANCE8_SYNC] Invalid parameters for enhanced buffer barrier creation", .{});
        return false;
    }

    // Initialize the barrier structure
    out_barrier.?.* = std.mem.zeroes(c.VkBufferMemoryBarrier2);
    out_barrier.?.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2;
    out_barrier.?.pNext = null;

    // Set stage and access masks
    out_barrier.?.srcStageMask = transfer_info.?.src_stage_mask;
    out_barrier.?.dstStageMask = transfer_info.?.dst_stage_mask;
    out_barrier.?.srcAccessMask = transfer_info.?.src_access_mask;
    out_barrier.?.dstAccessMask = transfer_info.?.dst_access_mask;

    // Set queue family ownership transfer
    out_barrier.?.srcQueueFamilyIndex = transfer_info.?.src_queue_family;
    out_barrier.?.dstQueueFamilyIndex = transfer_info.?.dst_queue_family;

    // Set buffer and range
    out_barrier.?.buffer = buffer;
    out_barrier.?.offset = offset;
    out_barrier.?.size = size;

    log.cardinal_log_debug("[Thread {d}] Enhanced buffer barrier: queue families {d}->{d}, stages 0x{x}->0x{x}", .{
        get_current_thread_id(),
        transfer_info.?.src_queue_family,
        transfer_info.?.dst_queue_family,
        transfer_info.?.src_stage_mask,
        transfer_info.?.dst_stage_mask
    });

    return true;
}

pub export fn vk_record_enhanced_ownership_transfer(
    cmd: c.VkCommandBuffer,
    transfer_info: ?*const types.VkQueueFamilyOwnershipTransferInfo,
    image_barrier_count: u32,
    image_barriers: ?[*]const c.VkImageMemoryBarrier2,
    buffer_barrier_count: u32,
    buffer_barriers: ?[*]const c.VkBufferMemoryBarrier2,
    vkCmdPipelineBarrier2_func: c.PFN_vkCmdPipelineBarrier2
) callconv(.c) bool {
    if (cmd == null or transfer_info == null or vkCmdPipelineBarrier2_func == null) {
        log.cardinal_log_error("[MAINTENANCE8_SYNC] Invalid parameters for enhanced ownership transfer", .{});
        return false;
    }

    if (image_barrier_count == 0 and buffer_barrier_count == 0) {
        log.cardinal_log_warn("[MAINTENANCE8_SYNC] No barriers specified for ownership transfer", .{});
        return true;
    }

    var dependency_info = std.mem.zeroes(c.VkDependencyInfo);
    dependency_info.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dependency_info.pNext = null;

    // Set dependency flags based on maintenance8 support
    if (transfer_info.?.use_maintenance8_enhancement and transfer_info.?.src_queue_family != transfer_info.?.dst_queue_family) {
        // Use maintenance8 enhancement for meaningful stage masks in queue family ownership transfers
        dependency_info.dependencyFlags = c.VK_DEPENDENCY_QUEUE_FAMILY_OWNERSHIP_TRANSFER_USE_ALL_STAGES_BIT_KHR;
        log.cardinal_log_debug("[MAINTENANCE8_SYNC] Using maintenance8 enhanced synchronization for queue family ownership transfer", .{});
    } else {
        dependency_info.dependencyFlags = 0;
        if (transfer_info.?.src_queue_family != transfer_info.?.dst_queue_family) {
            log.cardinal_log_debug("[MAINTENANCE8_SYNC] Using standard synchronization for queue family ownership transfer", .{});
        }
    }

    dependency_info.imageMemoryBarrierCount = image_barrier_count;
    dependency_info.pImageMemoryBarriers = image_barriers;
    dependency_info.bufferMemoryBarrierCount = buffer_barrier_count;
    dependency_info.pBufferMemoryBarriers = buffer_barriers;

    log.cardinal_log_debug("[Thread {d}] Recording enhanced ownership transfer: {d} images, {d} buffers", .{
        get_current_thread_id(), image_barrier_count, buffer_barrier_count
    });

    // Validate the pipeline barrier before execution
    if (!c.cardinal_barrier_validation_validate_pipeline_barrier(&dependency_info, cmd, get_current_thread_id())) {
        log.cardinal_log_warn("[MAINTENANCE8_SYNC] Pipeline barrier validation failed for enhanced ownership transfer", .{});
    }

    // Record the pipeline barrier
    vkCmdPipelineBarrier2_func.?(cmd, &dependency_info);

    log.cardinal_log_info("[MAINTENANCE8_SYNC] Recorded enhanced ownership transfer: {d} image barriers, {d} buffer barriers, maintenance8={s}", .{
        image_barrier_count,
        buffer_barrier_count,
        if (transfer_info.?.use_maintenance8_enhancement) "enabled" else "disabled"
    });

    return true;
}

pub export fn vk_create_queue_family_transfer_info(
    src_queue_family: u32,
    dst_queue_family: u32,
    src_stage_mask: c.VkPipelineStageFlags2,
    dst_stage_mask: c.VkPipelineStageFlags2,
    src_access_mask: c.VkAccessFlags2,
    dst_access_mask: c.VkAccessFlags2,
    supports_maintenance8: bool,
    out_transfer_info: ?*types.VkQueueFamilyOwnershipTransferInfo
) callconv(.c) bool {
    if (out_transfer_info == null) {
        log.cardinal_log_error("[MAINTENANCE8_SYNC] Invalid output parameter for transfer info creation", .{});
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

    log.cardinal_log_debug("[MAINTENANCE8_SYNC] Created queue family transfer info: {d} -> {d}, maintenance8={s}", .{
        src_queue_family,
        dst_queue_family,
        if (out_transfer_info.?.use_maintenance8_enhancement) "enabled" else "disabled"
    });

    return true;
}
