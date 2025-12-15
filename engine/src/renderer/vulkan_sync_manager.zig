const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");

const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("cardinal/renderer/vulkan_sync_manager.h");
    
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
    } else {
        @cInclude("stdatomic.h");
    }
});

// Helper to cast u64/u32 to atomic value pointer
fn atomic(ptr: anytype) *std.atomic.Value(@TypeOf(ptr.*)) {
    return @ptrCast(ptr);
}

pub export fn vulkan_sync_manager_init(sync_manager: ?*c.VulkanSyncManager, device: c.VkDevice,
                                       graphics_queue: c.VkQueue, max_frames_in_flight: u32) callconv(.c) bool {
    if (sync_manager == null or device == null or max_frames_in_flight == 0) {
        log.cardinal_log_error("[SYNC_MANAGER] Invalid parameters for initialization", .{});
        return false;
    }
    const mgr = sync_manager.?;

    // Clear struct
    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(c.VulkanSyncManager)], 0);
    
    mgr.device = device;
    mgr.graphics_queue = graphics_queue;
    mgr.max_frames_in_flight = max_frames_in_flight;
    mgr.current_frame = 0;

    // Allocate arrays
    const sem_size = @sizeOf(c.VkSemaphore);
    const fence_size = @sizeOf(c.VkFence);
    
    const ptr1 = c.calloc(max_frames_in_flight, sem_size) orelse {
        log.cardinal_log_error("[SYNC_MANAGER] Failed to allocate image acquired semaphores", .{});
        return false;
    };
    mgr.image_acquired_semaphores = @ptrCast(@alignCast(ptr1));

    const ptr2 = c.calloc(max_frames_in_flight, sem_size) orelse {
        log.cardinal_log_error("[SYNC_MANAGER] Failed to allocate render finished semaphores", .{});
        c.free(@ptrCast(mgr.image_acquired_semaphores));
        return false;
    };
    mgr.render_finished_semaphores = @ptrCast(@alignCast(ptr2));

    const ptr3 = c.calloc(max_frames_in_flight, fence_size) orelse {
        log.cardinal_log_error("[SYNC_MANAGER] Failed to allocate in-flight fences", .{});
        c.free(@ptrCast(mgr.image_acquired_semaphores));
        c.free(@ptrCast(mgr.render_finished_semaphores));
        return false;
    };
    mgr.in_flight_fences = @ptrCast(@alignCast(ptr3));

    // Create semaphores and fences
    var i: u32 = 0;
    while (i < max_frames_in_flight) : (i += 1) {
        var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        
        if (c.vkCreateSemaphore(device, &semaphore_info, null, &mgr.image_acquired_semaphores[i]) != c.VK_SUCCESS) {
            log.cardinal_log_error("[SYNC_MANAGER] Failed to create image acquired semaphore for frame {d}", .{i});
            vulkan_sync_manager_destroy(mgr);
            return false;
        }

        if (c.vkCreateSemaphore(device, &semaphore_info, null, &mgr.render_finished_semaphores[i]) != c.VK_SUCCESS) {
            log.cardinal_log_error("[SYNC_MANAGER] Failed to create render finished semaphore for frame {d}", .{i});
            vulkan_sync_manager_destroy(mgr);
            return false;
        }

        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;

        if (c.vkCreateFence(device, &fence_info, null, &mgr.in_flight_fences[i]) != c.VK_SUCCESS) {
            log.cardinal_log_error("[SYNC_MANAGER] Failed to create in-flight fence for frame {d}", .{i});
            vulkan_sync_manager_destroy(mgr);
            return false;
        }
    }

    // Timeline semaphore
    var timeline_type_info = std.mem.zeroes(c.VkSemaphoreTypeCreateInfo);
    timeline_type_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
    timeline_type_info.semaphoreType = c.VK_SEMAPHORE_TYPE_TIMELINE;
    timeline_type_info.initialValue = 0;

    var timeline_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    timeline_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    timeline_info.pNext = &timeline_type_info;

    if (c.vkCreateSemaphore(device, &timeline_info, null, &mgr.timeline_semaphore) != c.VK_SUCCESS) {
        log.cardinal_log_error("[SYNC_MANAGER] Failed to create timeline semaphore", .{});
        vulkan_sync_manager_destroy(mgr);
        return false;
    }

    // Initialize atomics
    atomic(&mgr.current_frame_value).store(0, .seq_cst);
    atomic(&mgr.image_available_value).store(0, .seq_cst);
    atomic(&mgr.render_complete_value).store(0, .seq_cst);
    atomic(&mgr.global_timeline_counter).store(0, .seq_cst);
    atomic(&mgr.timeline_wait_count).store(0, .seq_cst);
    atomic(&mgr.timeline_signal_count).store(0, .seq_cst);

    _ = vulkan_sync_manager_init_value_strategy(mgr, 1, true);

    mgr.initialized = true;
    log.cardinal_log_info("[SYNC_MANAGER] Initialized with {d} frames in flight", .{max_frames_in_flight});

    return true;
}

pub export fn vulkan_sync_manager_destroy(sync_manager: ?*c.VulkanSyncManager) callconv(.c) void {
    if (sync_manager == null) return;
    const mgr = sync_manager.?;
    
    if (mgr.device == null) return;

    // Wait for device to be idle
    _ = c.vkDeviceWaitIdle(mgr.device);

    // Destroy timeline semaphore
    if (mgr.timeline_semaphore != null) {
        c.vkDestroySemaphore(mgr.device, mgr.timeline_semaphore, null);
        mgr.timeline_semaphore = null;
    }

    // Destroy per-frame semaphores and fences
    if (mgr.image_acquired_semaphores != null) {
        var i: u32 = 0;
        while (i < mgr.max_frames_in_flight) : (i += 1) {
            if (mgr.image_acquired_semaphores[i] != null) {
                c.vkDestroySemaphore(mgr.device, mgr.image_acquired_semaphores[i], null);
            }
        }
        c.free(@ptrCast(mgr.image_acquired_semaphores));
        mgr.image_acquired_semaphores = null;
    }

    if (mgr.render_finished_semaphores != null) {
        var i: u32 = 0;
        while (i < mgr.max_frames_in_flight) : (i += 1) {
            if (mgr.render_finished_semaphores[i] != null) {
                c.vkDestroySemaphore(mgr.device, mgr.render_finished_semaphores[i], null);
            }
        }
        c.free(@ptrCast(mgr.render_finished_semaphores));
        mgr.render_finished_semaphores = null;
    }

    if (mgr.in_flight_fences != null) {
        var i: u32 = 0;
        while (i < mgr.max_frames_in_flight) : (i += 1) {
            if (mgr.in_flight_fences[i] != null) {
                c.vkDestroyFence(mgr.device, mgr.in_flight_fences[i], null);
            }
        }
        c.free(@ptrCast(mgr.in_flight_fences));
        mgr.in_flight_fences = null;
    }

    mgr.initialized = false;
    log.cardinal_log_info("[SYNC_MANAGER] Destroyed", .{});
}

pub export fn vulkan_sync_manager_wait_for_frame(sync_manager: ?*c.VulkanSyncManager, timeout_ns: u64) callconv(.c) c.VkResult {
    if (sync_manager == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    const current_fence = mgr.in_flight_fences[mgr.current_frame];

    // Check status first
    const status = c.vkGetFenceStatus(mgr.device, current_fence);
    if (status == c.VK_SUCCESS) {
        return c.VK_SUCCESS;
    } else if (status != c.VK_NOT_READY) {
        return status;
    }

    return c.vkWaitForFences(mgr.device, 1, &current_fence, c.VK_TRUE, timeout_ns);
}

pub export fn vulkan_sync_manager_reset_frame_fence(sync_manager: ?*c.VulkanSyncManager) callconv(.c) c.VkResult {
    if (sync_manager == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    const current_fence = mgr.in_flight_fences[mgr.current_frame];
    return c.vkResetFences(mgr.device, 1, &current_fence);
}

pub export fn vulkan_sync_manager_advance_frame(sync_manager: ?*c.VulkanSyncManager) callconv(.c) void {
    if (sync_manager == null) return;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return;

    mgr.current_frame = (mgr.current_frame + 1) % mgr.max_frames_in_flight;

    const base_value = atomic(&mgr.global_timeline_counter).fetchAdd(2, .seq_cst);
    
    atomic(&mgr.current_frame_value).store(base_value, .seq_cst);
    atomic(&mgr.image_available_value).store(base_value + 1, .seq_cst);
    atomic(&mgr.render_complete_value).store(base_value + 2, .seq_cst);
}

pub export fn vulkan_sync_manager_get_frame_sync_info(sync_manager: ?*c.VulkanSyncManager,
                                                      sync_info: ?*c.VulkanFrameSyncInfo) callconv(.c) void {
    if (sync_manager == null or sync_info == null) return;
    const mgr = sync_manager.?;
    const info = sync_info.?;
    if (!mgr.initialized) return;

    const frame = mgr.current_frame;

    info.wait_semaphore = mgr.image_acquired_semaphores[frame];
    info.signal_semaphore = mgr.render_finished_semaphores[frame];
    info.fence = mgr.in_flight_fences[frame];
    info.timeline_value = atomic(&mgr.render_complete_value).load(.seq_cst);
    info.wait_stage = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
}

pub export fn vulkan_sync_manager_create_semaphore(sync_manager: ?*c.VulkanSyncManager, semaphore: ?*c.VkSemaphore) callconv(.c) bool {
    if (sync_manager == null or semaphore == null) return false;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return false;

    var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;

    return c.vkCreateSemaphore(mgr.device, &semaphore_info, null, semaphore) == c.VK_SUCCESS;
}

pub export fn vulkan_sync_manager_create_fence(sync_manager: ?*c.VulkanSyncManager, signaled: bool,
                                      fence: ?*c.VkFence) callconv(.c) bool {
    if (sync_manager == null or fence == null) return false;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return false;

    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fence_info.flags = if (signaled) c.VK_FENCE_CREATE_SIGNALED_BIT else 0;

    return c.vkCreateFence(mgr.device, &fence_info, null, fence) == c.VK_SUCCESS;
}

pub export fn vulkan_sync_manager_destroy_semaphore(sync_manager: ?*c.VulkanSyncManager, semaphore: c.VkSemaphore) callconv(.c) void {
    if (sync_manager == null or semaphore == null) return;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return;

    c.vkDestroySemaphore(mgr.device, semaphore, null);
}

pub export fn vulkan_sync_manager_destroy_fence(sync_manager: ?*c.VulkanSyncManager, fence: c.VkFence) callconv(.c) void {
    if (sync_manager == null or fence == null) return;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return;

    c.vkDestroyFence(mgr.device, fence, null);
}

pub export fn vulkan_sync_manager_wait_timeline(sync_manager: ?*c.VulkanSyncManager, value: u64,
                                           timeout_ns: u64) callconv(.c) c.VkResult {
    if (sync_manager == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    var wait_val = value;
    var wait_info = std.mem.zeroes(c.VkSemaphoreWaitInfo);
    wait_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
    wait_info.semaphoreCount = 1;
    wait_info.pSemaphores = &mgr.timeline_semaphore;
    wait_info.pValues = &wait_val;

    const result = c.vkWaitSemaphores(mgr.device, &wait_info, timeout_ns);
    if (result == c.VK_SUCCESS) {
        _ = atomic(&mgr.timeline_wait_count).fetchAdd(1, .seq_cst);
    }

    return result;
}

pub export fn vulkan_sync_manager_signal_timeline(sync_manager: ?*c.VulkanSyncManager, value: u64) callconv(.c) c.VkResult {
    if (sync_manager == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    var optimized_value = vulkan_sync_manager_get_optimized_next_value(mgr, value);

    var timeline_info = std.mem.zeroes(c.VkTimelineSemaphoreSubmitInfo);
    timeline_info.sType = c.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO;
    timeline_info.signalSemaphoreValueCount = 1;
    timeline_info.pSignalSemaphoreValues = &optimized_value;

    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.pNext = &timeline_info;
    submit_info.signalSemaphoreCount = 1;
    submit_info.pSignalSemaphores = &mgr.timeline_semaphore;

    const result = c.vkQueueSubmit(mgr.graphics_queue, 1, &submit_info, null);
    if (result == c.VK_SUCCESS) {
        _ = atomic(&mgr.timeline_signal_count).fetchAdd(1, .seq_cst);
    }

    return result;
}

pub export fn vulkan_sync_manager_get_timeline_value(sync_manager: ?*c.VulkanSyncManager, value: ?*u64) callconv(.c) c.VkResult {
    if (sync_manager == null or value == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    return c.vkGetSemaphoreCounterValue(mgr.device, mgr.timeline_semaphore, value);
}

pub export fn vulkan_sync_manager_get_next_timeline_value(sync_manager: ?*c.VulkanSyncManager) callconv(.c) u64 {
    if (sync_manager == null) return 0;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return 0;

    // Get current value from device to ensure we are ahead
    var current_device_value: u64 = 0;
    const result = c.vkGetSemaphoreCounterValue(mgr.device, mgr.timeline_semaphore, &current_device_value);
    
    const atom_ptr = atomic(&mgr.global_timeline_counter);
    
    while (true) {
        const old_val = atom_ptr.load(.seq_cst);
        
        // Determine the next value: strictly greater than both current counter and device value
        const target_val = if (result == c.VK_SUCCESS and current_device_value >= old_val) 
                           current_device_value + 1 
                           else old_val + 1;
        
        // Attempt to atomically update the counter
        const cas_res = atom_ptr.cmpxchgWeak(old_val, target_val, .seq_cst, .seq_cst);
        if (cas_res) |_| {
            // CAS failed (value changed by another thread), retry loop
            continue;
        } else {
            // CAS succeeded, we successfully claimed target_val
            return target_val;
        }
    }
}

pub export fn vulkan_sync_manager_is_frame_ready(sync_manager: ?*c.VulkanSyncManager) callconv(.c) bool {
    if (sync_manager == null) return false;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return false;

    const current_fence = mgr.in_flight_fences[mgr.current_frame];
    return c.vkGetFenceStatus(mgr.device, current_fence) == c.VK_SUCCESS;
}

pub export fn vulkan_sync_manager_get_current_frame(sync_manager: ?*c.VulkanSyncManager) callconv(.c) u32 {
    if (sync_manager == null) return 0;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return 0;

    return mgr.current_frame;
}

pub export fn vulkan_sync_manager_get_max_frames(sync_manager: ?*c.VulkanSyncManager) callconv(.c) u32 {
    if (sync_manager == null) return 0;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return 0;

    return mgr.max_frames_in_flight;
}

pub export fn vulkan_sync_manager_wait_timeline_batch(sync_manager: ?*c.VulkanSyncManager,
                                                 values: ?[*]const u64, count: u32,
                                                 timeout_ns: u64) callconv(.c) c.VkResult {
    if (sync_manager == null or values == null or count == 0) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    // Create array of semaphores
    const ptr = c.malloc(count * @sizeOf(c.VkSemaphore));
    if (ptr == null) return c.VK_ERROR_OUT_OF_HOST_MEMORY;
    const semaphores = @as([*]c.VkSemaphore, @ptrCast(@alignCast(ptr)));

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        semaphores[i] = mgr.timeline_semaphore;
    }

    var wait_info = std.mem.zeroes(c.VkSemaphoreWaitInfo);
    wait_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
    wait_info.semaphoreCount = count;
    wait_info.pSemaphores = semaphores;
    wait_info.pValues = values;

    const result = c.vkWaitSemaphores(mgr.device, &wait_info, timeout_ns);
    if (result == c.VK_SUCCESS) {
        _ = atomic(&mgr.timeline_wait_count).fetchAdd(count, .seq_cst);
    }

    c.free(@ptrCast(semaphores));
    return result;
}

pub export fn vulkan_sync_manager_signal_timeline_batch(sync_manager: ?*c.VulkanSyncManager,
                                                   values: ?[*]const u64, count: u32) callconv(.c) c.VkResult {
    if (sync_manager == null or values == null or count == 0) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = sync_manager.?;
    const vals = values.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var signal_info = std.mem.zeroes(c.VkSemaphoreSignalInfo);
        signal_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO;
        signal_info.semaphore = mgr.timeline_semaphore;
        signal_info.value = vals[i];

        const result = c.vkSignalSemaphore(mgr.device, &signal_info);
        if (result != c.VK_SUCCESS) return result;

        _ = atomic(&mgr.timeline_signal_count).fetchAdd(1, .seq_cst);
    }

    return c.VK_SUCCESS;
}

pub export fn vulkan_timeline_error_to_string(err: c.VulkanTimelineError) callconv(.c) [*:0]const u8 {
    return switch (err) {
        c.VULKAN_TIMELINE_ERROR_NONE => "No error",
        c.VULKAN_TIMELINE_ERROR_TIMEOUT => "Timeline semaphore wait timeout",
        c.VULKAN_TIMELINE_ERROR_DEVICE_LOST => "Vulkan device lost",
        c.VULKAN_TIMELINE_ERROR_OUT_OF_MEMORY => "Out of memory",
        c.VULKAN_TIMELINE_ERROR_INVALID_VALUE => "Invalid timeline value",
        c.VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID => "Timeline semaphore is invalid",
        else => "Unknown error",
    };
}

fn vulkan_result_to_timeline_error(result: c.VkResult) c.VulkanTimelineError {
    return switch (result) {
        c.VK_SUCCESS => c.VULKAN_TIMELINE_ERROR_NONE,
        c.VK_TIMEOUT => c.VULKAN_TIMELINE_ERROR_TIMEOUT,
        c.VK_ERROR_DEVICE_LOST => c.VULKAN_TIMELINE_ERROR_DEVICE_LOST,
        c.VK_ERROR_OUT_OF_HOST_MEMORY, c.VK_ERROR_OUT_OF_DEVICE_MEMORY => c.VULKAN_TIMELINE_ERROR_OUT_OF_MEMORY,
        else => c.VULKAN_TIMELINE_ERROR_UNKNOWN,
    };
}

pub export fn vulkan_sync_manager_wait_timeline_safe(sync_manager: ?*c.VulkanSyncManager,
                                                           value: u64, timeout_ns: u64,
                                                           error_info: ?*c.VulkanTimelineErrorInfo) callconv(.c) c.VulkanTimelineError {
    if (sync_manager == null) {
        if (error_info) |info| {
            info.error_type = c.VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
            info.vulkan_result = c.VK_ERROR_UNKNOWN;
            info.timeline_value = value;
            info.timeout_ns = timeout_ns;
            _ = std.fmt.bufPrint(info.error_message[0..], "Invalid sync manager or timeline semaphore", .{}) catch {};
        }
        return c.VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
    }
    const mgr = sync_manager.?;
    if (mgr.timeline_semaphore == null) {
        if (error_info) |info| {
             // ... same error logic
            info.error_type = c.VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
            info.vulkan_result = c.VK_ERROR_UNKNOWN;
            info.timeline_value = value;
            info.timeout_ns = timeout_ns;
            _ = std.fmt.bufPrint(info.error_message[0..], "Invalid sync manager or timeline semaphore", .{}) catch {};
        }
        return c.VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
    }

    const current_value = atomic(&mgr.global_timeline_counter).load(.seq_cst);
    if (value > current_value + 1000000) {
        if (error_info) |info| {
            info.error_type = c.VULKAN_TIMELINE_ERROR_INVALID_VALUE;
            info.vulkan_result = c.VK_ERROR_UNKNOWN;
            info.timeline_value = value;
            info.timeout_ns = timeout_ns;
            _ = std.fmt.bufPrint(info.error_message[0..], "Timeline value {d} is too far in the future (current: {d})", .{value, current_value}) catch {};
        }
        return c.VULKAN_TIMELINE_ERROR_INVALID_VALUE;
    }

    var wait_val = value;
    var wait_info = std.mem.zeroes(c.VkSemaphoreWaitInfo);
    wait_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
    wait_info.semaphoreCount = 1;
    wait_info.pSemaphores = &mgr.timeline_semaphore;
    wait_info.pValues = &wait_val;

    const result = c.vkWaitSemaphores(mgr.device, &wait_info, timeout_ns);
    const timeline_error = vulkan_result_to_timeline_error(result);

    if (error_info) |info| {
        info.error_type = timeline_error;
        info.vulkan_result = result;
        info.timeline_value = value;
        info.timeout_ns = timeout_ns;

        if (timeline_error != c.VULKAN_TIMELINE_ERROR_NONE) {
             _ = std.fmt.bufPrint(info.error_message[0..], "Timeline wait failed: {s} (VkResult: {d})",
                     .{vulkan_timeline_error_to_string(timeline_error), result}) catch {};
        } else {
             _ = std.fmt.bufPrint(info.error_message[0..], "Timeline wait successful", .{}) catch {};
        }
    }

    if (result == c.VK_SUCCESS) {
        _ = atomic(&mgr.timeline_wait_count).fetchAdd(1, .seq_cst);
    }

    return timeline_error;
}

pub export fn vulkan_sync_manager_signal_timeline_safe(sync_manager: ?*c.VulkanSyncManager,
                                                             value: u64,
                                                             error_info: ?*c.VulkanTimelineErrorInfo) callconv(.c) c.VulkanTimelineError {
    if (sync_manager == null) return c.VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
    const mgr = sync_manager.?;
    if (mgr.timeline_semaphore == null) {
        if (error_info) |info| {
            info.error_type = c.VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
            info.vulkan_result = c.VK_ERROR_UNKNOWN;
            info.timeline_value = value;
            info.timeout_ns = 0;
            _ = std.fmt.bufPrint(info.error_message[0..], "Invalid sync manager or timeline semaphore", .{}) catch {};
        }
        return c.VULKAN_TIMELINE_ERROR_SEMAPHORE_INVALID;
    }

    var current_value: u64 = 0;
    const get_result = c.vkGetSemaphoreCounterValue(mgr.device, mgr.timeline_semaphore, &current_value);
    if (get_result != c.VK_SUCCESS) {
        const timeline_error = vulkan_result_to_timeline_error(get_result);
        if (error_info) |info| {
            info.error_type = timeline_error;
            info.vulkan_result = get_result;
            info.timeline_value = value;
            info.timeout_ns = 0;
            _ = std.fmt.bufPrint(info.error_message[0..], "Failed to get current timeline value: {s} (VkResult: {d})",
                     .{vulkan_timeline_error_to_string(timeline_error), get_result}) catch {};
        }
        return timeline_error;
    }

    if (value <= current_value) {
        if (error_info) |info| {
            info.error_type = c.VULKAN_TIMELINE_ERROR_INVALID_VALUE;
            info.vulkan_result = c.VK_ERROR_UNKNOWN;
            info.timeline_value = value;
            info.timeout_ns = 0;
            _ = std.fmt.bufPrint(info.error_message[0..], "Timeline value {d} must be greater than current value {d}", .{value, current_value}) catch {};
        }
        return c.VULKAN_TIMELINE_ERROR_INVALID_VALUE;
    }

    var signal_info = std.mem.zeroes(c.VkSemaphoreSignalInfo);
    signal_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO;
    signal_info.semaphore = mgr.timeline_semaphore;
    signal_info.value = value;

    const result = c.vkSignalSemaphore(mgr.device, &signal_info);
    const timeline_error = vulkan_result_to_timeline_error(result);

    if (error_info) |info| {
        info.error_type = timeline_error;
        info.vulkan_result = result;
        info.timeline_value = value;
        info.timeout_ns = 0;

        if (timeline_error != c.VULKAN_TIMELINE_ERROR_NONE) {
            _ = std.fmt.bufPrint(info.error_message[0..], "Timeline signal failed: {s} (VkResult: {d})",
                     .{vulkan_timeline_error_to_string(timeline_error), result}) catch {};
        } else {
            _ = std.fmt.bufPrint(info.error_message[0..], "Timeline signal successful", .{}) catch {};
        }
    }

    if (result == c.VK_SUCCESS) {
        _ = atomic(&mgr.timeline_signal_count).fetchAdd(1, .seq_cst);
    }

    return timeline_error;
}

pub export fn vulkan_sync_manager_validate_timeline_state(sync_manager: ?*c.VulkanSyncManager) callconv(.c) bool {
    if (sync_manager == null) {
        log.cardinal_log_error("[SYNC_MANAGER] Invalid sync manager or timeline semaphore", .{});
        return false;
    }
    const mgr = sync_manager.?;
    if (mgr.timeline_semaphore == null) {
        log.cardinal_log_error("[SYNC_MANAGER] Invalid sync manager or timeline semaphore", .{});
        return false;
    }

    var current_value: u64 = 0;
    const result = c.vkGetSemaphoreCounterValue(mgr.device, mgr.timeline_semaphore, &current_value);

    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SYNC_MANAGER] Timeline semaphore validation failed: {d}", .{result});
        return false;
    }

    const atomic_value = atomic(&mgr.global_timeline_counter).load(.seq_cst);
    if (current_value > atomic_value + 1000000) {
        log.cardinal_log_warn("[SYNC_MANAGER] Timeline value inconsistency: semaphore={d}, atomic={d}",
            .{current_value, atomic_value});
    }

    return true;
}

pub export fn vulkan_sync_manager_recover_timeline_semaphore(sync_manager: ?*c.VulkanSyncManager,
                                                    error_info: ?*c.VulkanTimelineErrorInfo) callconv(.c) bool {
    if (sync_manager == null) return false;
    const mgr = sync_manager.?;

    log.cardinal_log_warn("[SYNC_MANAGER] Attempting timeline semaphore recovery", .{});

    if (error_info) |info| {
        if (info.error_type == c.VULKAN_TIMELINE_ERROR_DEVICE_LOST) {
            log.cardinal_log_error("[SYNC_MANAGER] Cannot recover from device lost error", .{});
            return false;
        }
    }

    if (mgr.timeline_semaphore != null) {
        c.vkDestroySemaphore(mgr.device, mgr.timeline_semaphore, null);
        mgr.timeline_semaphore = null;
    }

    var timeline_type_info = std.mem.zeroes(c.VkSemaphoreTypeCreateInfo);
    timeline_type_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
    timeline_type_info.semaphoreType = c.VK_SEMAPHORE_TYPE_TIMELINE;
    timeline_type_info.initialValue = 0;

    var create_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    create_info.pNext = &timeline_type_info;

    if (c.vkCreateSemaphore(mgr.device, &create_info, null, &mgr.timeline_semaphore) != c.VK_SUCCESS) {
        log.cardinal_log_error("[SYNC_MANAGER] Failed to recreate timeline semaphore", .{});
        return false;
    }

    atomic(&mgr.global_timeline_counter).store(0, .seq_cst);
    atomic(&mgr.current_frame_value).store(0, .seq_cst);
    atomic(&mgr.image_available_value).store(0, .seq_cst);
    atomic(&mgr.render_complete_value).store(0, .seq_cst);

    log.cardinal_log_info("[SYNC_MANAGER] Timeline semaphore recovery successful", .{});
    return true;
}

pub export fn vulkan_sync_manager_init_value_strategy(sync_manager: ?*c.VulkanSyncManager,
                                             increment_step: u64, auto_reset_enabled: bool) callconv(.c) bool {
    if (sync_manager == null) return false;
    const mgr = sync_manager.?;

    mgr.value_strategy.base_value = 0;
    mgr.value_strategy.increment_step = if (increment_step > 0) increment_step else 1;
    mgr.value_strategy.max_safe_value = std.math.maxInt(u64) / 2;
    mgr.value_strategy.overflow_threshold = mgr.value_strategy.max_safe_value - (increment_step * 1000);
    mgr.value_strategy.auto_reset_enabled = auto_reset_enabled;

    log.cardinal_log_info("[SYNC_MANAGER] Timeline value strategy initialized: step={d}, auto_reset={s}",
        .{increment_step, if (auto_reset_enabled) "enabled" else "disabled"});

    return true;
}

pub export fn vulkan_sync_manager_get_optimized_next_value(sync_manager: ?*c.VulkanSyncManager,
                                                      min_increment: u64) callconv(.c) u64 {
    if (sync_manager == null) return 0;
    const mgr = sync_manager.?;

    const increment = if (min_increment > mgr.value_strategy.increment_step) min_increment else mgr.value_strategy.increment_step;

    const old_value = atomic(&mgr.global_timeline_counter).fetchAdd(increment, .seq_cst);
    var next_value = old_value + increment;

    if (next_value > mgr.value_strategy.overflow_threshold) {
        if (mgr.value_strategy.auto_reset_enabled) {
            log.cardinal_log_warn("[SYNC_MANAGER] Timeline value approaching overflow, triggering reset", .{});
            if (vulkan_sync_manager_reset_timeline_values(mgr)) {
                next_value = increment;
            } else {
                log.cardinal_log_error("[SYNC_MANAGER] Failed to reset timeline values, continuing with risky value", .{});
            }
        } else {
            log.cardinal_log_warn("[SYNC_MANAGER] Timeline value {d} approaching overflow threshold {d}",
                .{next_value, mgr.value_strategy.overflow_threshold});
        }
    }

    return next_value;
}

pub export fn vulkan_sync_manager_check_overflow_risk(sync_manager: ?*c.VulkanSyncManager,
                                             remaining_values: ?*u64) callconv(.c) bool {
    if (sync_manager == null) return false;
    const mgr = sync_manager.?;

    const current_value = atomic(&mgr.global_timeline_counter).load(.seq_cst);
    const threshold = mgr.value_strategy.overflow_threshold;

    if (remaining_values) |rem| {
        rem.* = if (threshold > current_value) (threshold - current_value) else 0;
    }

    const at_risk = current_value >= threshold;
    if (at_risk) {
        log.cardinal_log_warn("[SYNC_MANAGER] Timeline overflow risk detected: current={d}, threshold={d}",
            .{current_value, threshold});
    }

    return at_risk;
}

pub export fn vulkan_sync_manager_reset_timeline_values(sync_manager: ?*c.VulkanSyncManager) callconv(.c) bool {
    if (sync_manager == null) return false;
    const mgr = sync_manager.?;
    if (mgr.timeline_semaphore == null) return false;

    log.cardinal_log_info("[SYNC_MANAGER] Resetting timeline values to prevent overflow", .{});

    var current_value: u64 = 0;
    var result = c.vkGetSemaphoreCounterValue(mgr.device, mgr.timeline_semaphore, &current_value);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SYNC_MANAGER] Failed to get current timeline value for reset: {d}", .{result});
        return false;
    }

    var wait_info = std.mem.zeroes(c.VkSemaphoreWaitInfo);
    wait_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
    wait_info.semaphoreCount = 1;
    wait_info.pSemaphores = &mgr.timeline_semaphore;
    wait_info.pValues = &current_value;

    result = c.vkWaitSemaphores(mgr.device, &wait_info, std.math.maxInt(u64));
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SYNC_MANAGER] Failed to wait for timeline completion before reset: {d}", .{result});
        return false;
    }

    c.vkDestroySemaphore(mgr.device, mgr.timeline_semaphore, null);

    var timeline_type_info = std.mem.zeroes(c.VkSemaphoreTypeCreateInfo);
    timeline_type_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
    timeline_type_info.semaphoreType = c.VK_SEMAPHORE_TYPE_TIMELINE;
    timeline_type_info.initialValue = 0;

    var create_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    create_info.pNext = &timeline_type_info;

    result = c.vkCreateSemaphore(mgr.device, &create_info, null, &mgr.timeline_semaphore);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[SYNC_MANAGER] Failed to recreate timeline semaphore after reset: {d}", .{result});
        return false;
    }

    atomic(&mgr.global_timeline_counter).store(0, .seq_cst);
    atomic(&mgr.current_frame_value).store(0, .seq_cst);
    atomic(&mgr.image_available_value).store(0, .seq_cst);
    atomic(&mgr.render_complete_value).store(0, .seq_cst);

    mgr.value_strategy.base_value = 0;

    log.cardinal_log_info("[SYNC_MANAGER] Timeline values reset successfully", .{});
    return true;
}

pub export fn vulkan_sync_manager_optimize_value_allocation(sync_manager: ?*c.VulkanSyncManager) callconv(.c) void {
    if (sync_manager == null) return;
    const mgr = sync_manager.?;

    var remaining_values: u64 = 0;
    const at_risk = vulkan_sync_manager_check_overflow_risk(mgr, &remaining_values);

    if (at_risk) {
        log.cardinal_log_info("[SYNC_MANAGER] Optimizing timeline value allocation due to overflow risk", .{});
        if (mgr.value_strategy.auto_reset_enabled) {
             _ = vulkan_sync_manager_reset_timeline_values(mgr);
        } else {
            const current_step = mgr.value_strategy.increment_step;
            const optimized_step = remaining_values / 1000;
            if (optimized_step > 0 and optimized_step < current_step) {
                mgr.value_strategy.increment_step = optimized_step;
                log.cardinal_log_info("[SYNC_MANAGER] Reduced increment step from {d} to {d} to optimize remaining values",
                    .{current_step, optimized_step});
            }
        }
    } else {
        const current_step = mgr.value_strategy.increment_step;
        const optimal_step = remaining_values / 100000;
        if (optimal_step > current_step * 2) {
            mgr.value_strategy.increment_step = current_step * 2;
            log.cardinal_log_debug("[SYNC_MANAGER] Increased increment step from {d} to {d} for better performance",
                .{current_step, mgr.value_strategy.increment_step});
        }
    }
}

pub export fn vulkan_sync_manager_is_timeline_value_reached(sync_manager: ?*c.VulkanSyncManager,
                                                       value: u64, reached: ?*bool) callconv(.c) c.VkResult {
    if (sync_manager == null or reached == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    var current_value: u64 = 0;
    const result = c.vkGetSemaphoreCounterValue(mgr.device, mgr.timeline_semaphore, &current_value);
    if (result != c.VK_SUCCESS) return result;

    reached.?.* = (current_value >= value);
    return c.VK_SUCCESS;
}

pub export fn vulkan_sync_manager_get_timeline_stats(sync_manager: ?*c.VulkanSyncManager,
                                                wait_count: ?*u64, signal_count: ?*u64,
                                                current_value: ?*u64) callconv(.c) c.VkResult {
    if (sync_manager == null) return c.VK_ERROR_INITIALIZATION_FAILED;
    const mgr = sync_manager.?;
    if (!mgr.initialized) return c.VK_ERROR_INITIALIZATION_FAILED;

    if (wait_count) |wc| {
        wc.* = atomic(&mgr.timeline_wait_count).load(.seq_cst);
    }
    if (signal_count) |sc| {
        sc.* = atomic(&mgr.timeline_signal_count).load(.seq_cst);
    }
    if (current_value) |cv| {
        const result = c.vkGetSemaphoreCounterValue(mgr.device, mgr.timeline_semaphore, cv);
        if (result != c.VK_SUCCESS) return result;
    }

    return c.VK_SUCCESS;
}
