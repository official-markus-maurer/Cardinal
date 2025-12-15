const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("stdint.h");
    
    // Skip stdatomic.h and define types manually
    @cDefine("__STDATOMIC_H", "1");
    @cDefine("_STDATOMIC_H", "1");
    @cDefine("__CLANG_STDATOMIC_H", "1");
    @cDefine("__zig_translate_c__", "1");
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    
    @cInclude("vulkan/vulkan.h");
    @cInclude("cardinal/renderer/vulkan_barrier_validation.h");
    @cInclude("cardinal/core/memory.h");
    @cInclude("cardinal/renderer/vulkan_mt.h");

    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
    } else {
        @cInclude("pthread.h");
        @cInclude("sys/syscall.h");
        @cInclude("unistd.h");
    }
});

// Global state
var g_validation_context: c.CardinalBarrierValidationContext = std.mem.zeroes(c.CardinalBarrierValidationContext);
var g_validation_initialized: bool = false;

// Statistics
var g_total_accesses: u32 = 0;
var g_validation_errors: u32 = 0;
var g_race_conditions: u32 = 0;

// Mutex
var g_validation_mutex: if (builtin.os.tag == .windows) c.CRITICAL_SECTION else c.pthread_mutex_t = undefined;

// Helpers
fn get_current_thread_id() u32 {
    if (builtin.os.tag == .windows) {
        return c.GetCurrentThreadId();
    } else {
        return @intCast(c.syscall(c.SYS_gettid));
    }
}

fn get_timestamp() u64 {
    if (builtin.os.tag == .windows) {
        var counter: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceCounter(&counter);
        return @intCast(counter.QuadPart);
    } else {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
    }
}

fn lock_validation_mutex() void {
    if (builtin.os.tag == .windows) {
        c.EnterCriticalSection(&g_validation_mutex);
    } else {
        _ = c.pthread_mutex_lock(&g_validation_mutex);
    }
}

fn unlock_validation_mutex() void {
    if (builtin.os.tag == .windows) {
        c.LeaveCriticalSection(&g_validation_mutex);
    } else {
        _ = c.pthread_mutex_unlock(&g_validation_mutex);
    }
}

pub export fn cardinal_barrier_validation_init(max_tracked_accesses: u32, strict_mode: bool) callconv(.c) bool {
    if (g_validation_initialized) {
        log.cardinal_log_warn("[BARRIER_VALIDATION] Already initialized", .{});
        return true;
    }

    if (builtin.os.tag == .windows) {
        c.InitializeCriticalSection(&g_validation_mutex);
    } else {
        _ = c.pthread_mutex_init(&g_validation_mutex, null);
    }

    const allocator = c.cardinal_get_allocator_for_category(c.CARDINAL_MEMORY_CATEGORY_ENGINE);

    const ptr = c.cardinal_alloc(allocator, @sizeOf(c.CardinalResourceAccess) * max_tracked_accesses);
    if (ptr == null) {
        log.cardinal_log_error("[BARRIER_VALIDATION] Failed to allocate memory for resource tracking", .{});
        return false;
    }
    
    g_validation_context.resource_accesses = @ptrCast(@alignCast(ptr));
    g_validation_context.access_count = 0;
    g_validation_context.max_accesses = max_tracked_accesses;
    g_validation_context.validation_enabled = true;
    g_validation_context.strict_mode = strict_mode;

    g_total_accesses = 0;
    g_validation_errors = 0;
    g_race_conditions = 0;

    g_validation_initialized = true;

    log.cardinal_log_info("[BARRIER_VALIDATION] Initialized with {d} max accesses, strict_mode={s}", .{max_tracked_accesses, if (strict_mode) "true" else "false"});
    return true;
}

pub export fn cardinal_barrier_validation_shutdown() callconv(.c) void {
    if (!g_validation_initialized) {
        return;
    }

    lock_validation_mutex();

    if (g_validation_context.resource_accesses != null) {
        const allocator = c.cardinal_get_allocator_for_category(c.CARDINAL_MEMORY_CATEGORY_ENGINE);
        c.cardinal_free(allocator, g_validation_context.resource_accesses);
        g_validation_context.resource_accesses = null;
    }

    g_validation_context.access_count = 0;
    g_validation_context.max_accesses = 0;
    g_validation_context.validation_enabled = false;

    unlock_validation_mutex();

    if (builtin.os.tag == .windows) {
        c.DeleteCriticalSection(&g_validation_mutex);
    } else {
        _ = c.pthread_mutex_destroy(&g_validation_mutex);
    }

    g_validation_initialized = false;

    log.cardinal_log_info("[BARRIER_VALIDATION] Shutdown complete. Stats: {d} accesses, {d} errors, {d} race conditions",
        .{g_total_accesses, g_validation_errors, g_race_conditions});
}

pub export fn cardinal_barrier_validation_set_enabled(enabled: bool) callconv(.c) void {
    if (!g_validation_initialized) {
        return;
    }

    lock_validation_mutex();
    g_validation_context.validation_enabled = enabled;
    unlock_validation_mutex();

    log.cardinal_log_debug("[BARRIER_VALIDATION] Validation {s}", .{if (enabled) "enabled" else "disabled"});
}

pub export fn cardinal_barrier_validation_track_access(resource_id: u64,
                                              resource_type: c.CardinalResourceType,
                                              access_type: c.CardinalResourceAccessType,
                                              stage_mask: c.VkPipelineStageFlags2,
                                              access_mask: c.VkAccessFlags2, thread_id: u32,
                                              command_buffer: c.VkCommandBuffer) callconv(.c) bool {
    if (!g_validation_initialized or !g_validation_context.validation_enabled) {
        return true;
    }

    lock_validation_mutex();

    // Check if we have space
    if (g_validation_context.access_count >= g_validation_context.max_accesses) {
        if (!g_validation_context.strict_mode) {
            g_validation_context.access_count = 0;
        } else {
            unlock_validation_mutex();
            log.cardinal_log_error("[BARRIER_VALIDATION] Maximum tracked accesses exceeded", .{});
            g_validation_errors += 1;
            return false;
        }
    }

    // Check for race conditions
    var i: u32 = 0;
    while (i < g_validation_context.access_count) : (i += 1) {
        const existing = &g_validation_context.resource_accesses[i];

        if (existing.resource_id == resource_id and existing.thread_id != thread_id) {
            if (access_type == c.CARDINAL_ACCESS_WRITE or existing.access_type == c.CARDINAL_ACCESS_WRITE) {
                log.cardinal_log_warn("[BARRIER_VALIDATION] Potential race condition detected: Resource 0x{x} accessed by threads {d} and {d}",
                    .{resource_id, existing.thread_id, thread_id});
                g_race_conditions += 1;
            }
        }
    }

    // Record access
    var access = &g_validation_context.resource_accesses[g_validation_context.access_count];
    access.resource_id = resource_id;
    access.resource_type = resource_type;
    access.access_type = access_type;
    access.stage_mask = stage_mask;
    access.access_mask = access_mask;
    access.thread_id = thread_id;
    access.timestamp = get_timestamp();
    access.command_buffer = command_buffer;

    g_validation_context.access_count += 1;
    g_total_accesses += 1;

    unlock_validation_mutex();
    return true;
}

pub export fn cardinal_barrier_validation_validate_memory_barrier(barrier: ?*const c.VkMemoryBarrier2,
                                                         command_buffer: c.VkCommandBuffer,
                                                         thread_id: u32) callconv(.c) bool {
    if (!g_validation_initialized or !g_validation_context.validation_enabled or barrier == null) {
        return true;
    }
    const b = barrier.?;
    var valid = true;

    if (b.srcStageMask == 0 or b.dstStageMask == 0) {
        log.cardinal_log_error("[BARRIER_VALIDATION] Invalid stage mask in memory barrier (thread {d})", .{thread_id});
        g_validation_errors += 1;
        valid = false;
    }

    if ((b.srcAccessMask & c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT) != 0 and
        (b.srcStageMask & c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT) == 0) {
        log.cardinal_log_warn("[BARRIER_VALIDATION] Access mask mismatch with stage mask (thread {d})", .{thread_id});
    }

    log.cardinal_log_debug("[BARRIER_VALIDATION] Memory barrier validated (thread {d}, cmd {*})", .{thread_id, command_buffer});
    return valid;
}

pub export fn cardinal_barrier_validation_validate_buffer_barrier(barrier: ?*const c.VkBufferMemoryBarrier2,
                                                         command_buffer: c.VkCommandBuffer,
                                                         thread_id: u32) callconv(.c) bool {
    if (!g_validation_initialized or !g_validation_context.validation_enabled or barrier == null) {
        return true;
    }
    const b = barrier.?;
    const valid = true;
    const buffer_id = @intFromPtr(b.buffer);

    var access_type: c.CardinalResourceAccessType = c.CARDINAL_ACCESS_READ_WRITE;
    if ((b.srcAccessMask & (c.VK_ACCESS_2_SHADER_WRITE_BIT | c.VK_ACCESS_2_TRANSFER_WRITE_BIT)) != 0) {
        access_type = c.CARDINAL_ACCESS_WRITE;
    } else if ((b.srcAccessMask & (c.VK_ACCESS_2_SHADER_READ_BIT | c.VK_ACCESS_2_TRANSFER_READ_BIT)) != 0) {
        access_type = c.CARDINAL_ACCESS_READ;
    }

    _ = cardinal_barrier_validation_track_access(buffer_id, c.CARDINAL_RESOURCE_BUFFER, access_type,
                                             b.srcStageMask, b.srcAccessMask,
                                             thread_id, command_buffer);

    if (b.srcQueueFamilyIndex != b.dstQueueFamilyIndex and
        (b.srcQueueFamilyIndex == c.VK_QUEUE_FAMILY_IGNORED or
         b.dstQueueFamilyIndex == c.VK_QUEUE_FAMILY_IGNORED)) {
        log.cardinal_log_warn("[BARRIER_VALIDATION] Inconsistent queue family indices in buffer barrier (thread {d})", .{thread_id});
    }

    log.cardinal_log_debug("[BARRIER_VALIDATION] Buffer barrier validated (thread {d}, buffer 0x{x})", .{thread_id, buffer_id});
    return valid;
}

pub export fn cardinal_barrier_validation_validate_image_barrier(barrier: ?*const c.VkImageMemoryBarrier2,
                                                        command_buffer: c.VkCommandBuffer,
                                                        thread_id: u32) callconv(.c) bool {
    if (!g_validation_initialized or !g_validation_context.validation_enabled or barrier == null) {
        return true;
    }
    const b = barrier.?;
    var valid = true;
    const image_id = @intFromPtr(b.image);

    var access_type: c.CardinalResourceAccessType = c.CARDINAL_ACCESS_READ_WRITE;
    if ((b.srcAccessMask & (c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)) != 0) {
        access_type = c.CARDINAL_ACCESS_WRITE;
    } else if ((b.srcAccessMask & (c.VK_ACCESS_2_SHADER_READ_BIT | c.VK_ACCESS_2_INPUT_ATTACHMENT_READ_BIT)) != 0) {
        access_type = c.CARDINAL_ACCESS_READ;
    }

    _ = cardinal_barrier_validation_track_access(image_id, c.CARDINAL_RESOURCE_IMAGE, access_type,
                                             b.srcStageMask, b.srcAccessMask,
                                             thread_id, command_buffer);

    if (b.oldLayout == b.newLayout and b.oldLayout != c.VK_IMAGE_LAYOUT_GENERAL) {
        log.cardinal_log_warn("[BARRIER_VALIDATION] Unnecessary layout transition (thread {d}, image 0x{x})", .{thread_id, image_id});
    }

    if (b.oldLayout == c.VK_IMAGE_LAYOUT_UNDEFINED and
        b.newLayout != c.VK_IMAGE_LAYOUT_PREINITIALIZED and b.srcAccessMask != 0) {
        log.cardinal_log_error("[BARRIER_VALIDATION] Invalid src access mask for UNDEFINED layout (thread {d})", .{thread_id});
        g_validation_errors += 1;
        valid = false;
    }

    log.cardinal_log_debug("[BARRIER_VALIDATION] Image barrier validated (thread {d}, image 0x{x})", .{thread_id, image_id});
    return valid;
}

pub export fn cardinal_barrier_validation_validate_pipeline_barrier(dependency_info: ?*const c.VkDependencyInfo,
                                                           command_buffer: c.VkCommandBuffer,
                                                           thread_id: u32) callconv(.c) bool {
    if (!g_validation_initialized or !g_validation_context.validation_enabled or dependency_info == null) {
        return true;
    }
    const dep = dependency_info.?;
    var valid = true;

    var i: u32 = 0;
    while (i < dep.memoryBarrierCount) : (i += 1) {
        if (!cardinal_barrier_validation_validate_memory_barrier(&dep.pMemoryBarriers[i], command_buffer, thread_id)) {
            valid = false;
        }
    }

    i = 0;
    while (i < dep.bufferMemoryBarrierCount) : (i += 1) {
        if (!cardinal_barrier_validation_validate_buffer_barrier(&dep.pBufferMemoryBarriers[i], command_buffer, thread_id)) {
            valid = false;
        }
    }

    i = 0;
    while (i < dep.imageMemoryBarrierCount) : (i += 1) {
        if (!cardinal_barrier_validation_validate_image_barrier(&dep.pImageMemoryBarriers[i], command_buffer, thread_id)) {
            valid = false;
        }
    }

    log.cardinal_log_debug("[BARRIER_VALIDATION] Pipeline barrier validated (thread {d}, cmd {*}): {d} memory, {d} buffer, {d} image barriers",
        .{thread_id, command_buffer, dep.memoryBarrierCount, dep.bufferMemoryBarrierCount, dep.imageMemoryBarrierCount});
    return valid;
}

pub export fn cardinal_barrier_validation_validate_secondary_recording(context: ?*const c.CardinalSecondaryCommandContext) callconv(.c) bool {
    if (!g_validation_initialized or !g_validation_context.validation_enabled or context == null) {
        return true;
    }
    const ctx = context.?;

    if (!ctx.is_recording) {
        log.cardinal_log_error("[BARRIER_VALIDATION] Attempting to validate non-recording secondary command buffer", .{});
        g_validation_errors += 1;
        return false;
    }

    const thread_id = get_current_thread_id();
    const cmd_buffer_id = @intFromPtr(ctx.command_buffer);
    
    _ = cardinal_barrier_validation_track_access(
        cmd_buffer_id, c.CARDINAL_RESOURCE_DESCRIPTOR_SET, c.CARDINAL_ACCESS_WRITE,
        c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, c.VK_ACCESS_2_MEMORY_WRITE_BIT, thread_id,
        ctx.command_buffer);

    log.cardinal_log_debug("[BARRIER_VALIDATION] Secondary command buffer recording validated (thread {d})", .{thread_id});
    return true;
}

pub export fn cardinal_barrier_validation_check_race_condition(thread_id1: u32, thread_id2: u32) callconv(.c) bool {
    if (!g_validation_initialized or !g_validation_context.validation_enabled) {
        return false;
    }

    lock_validation_mutex();

    var race_detected = false;

    var i: u32 = 0;
    while (i < g_validation_context.access_count) : (i += 1) {
        const access1 = &g_validation_context.resource_accesses[i];
        if (access1.thread_id != thread_id1) continue;

        var j: u32 = i + 1;
        while (j < g_validation_context.access_count) : (j += 1) {
            const access2 = &g_validation_context.resource_accesses[j];
            if (access2.thread_id != thread_id2) continue;

            if (access1.resource_id == access2.resource_id and
                (access1.access_type == c.CARDINAL_ACCESS_WRITE or access2.access_type == c.CARDINAL_ACCESS_WRITE)) {
                log.cardinal_log_warn("[BARRIER_VALIDATION] Race condition detected between threads {d} and {d} on resource 0x{x}",
                    .{thread_id1, thread_id2, access1.resource_id});
                race_detected = true;
                g_race_conditions += 1;
            }
        }
    }

    unlock_validation_mutex();
    return race_detected;
}

pub export fn cardinal_barrier_validation_get_stats(out_total_accesses: ?*u32,
                                           out_validation_errors: ?*u32,
                                           out_race_conditions: ?*u32) callconv(.c) void {
    if (out_total_accesses) |ptr| ptr.* = g_total_accesses;
    if (out_validation_errors) |ptr| ptr.* = g_validation_errors;
    if (out_race_conditions) |ptr| ptr.* = g_race_conditions;
}

pub export fn cardinal_barrier_validation_clear_accesses() callconv(.c) void {
    if (!g_validation_initialized) {
        return;
    }

    lock_validation_mutex();
    g_validation_context.access_count = 0;
    unlock_validation_mutex();

    log.cardinal_log_debug("[BARRIER_VALIDATION] Cleared all tracked accesses", .{});
}
