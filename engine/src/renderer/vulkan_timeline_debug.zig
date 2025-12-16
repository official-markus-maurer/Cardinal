const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("stdint.h");
    @cInclude("stdio.h");
    
    // Skip stdatomic.h and define types manually to avoid C import errors
    @cDefine("__STDATOMIC_H", "1");
    @cDefine("_STDATOMIC_H", "1");
    @cDefine("__CLANG_STDATOMIC_H", "1");
    @cDefine("__zig_translate_c__", "1");
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    
    @cDefine("memory_order", "int");
    @cDefine("memory_order_relaxed", "0");
    @cDefine("memory_order_consume", "1");
    @cDefine("memory_order_acquire", "2");
    @cDefine("memory_order_release", "3");
    @cDefine("memory_order_acq_rel", "4");
    @cDefine("memory_order_seq_cst", "5");
    
    @cInclude("vulkan/vulkan.h");
    @cInclude("cardinal/renderer/vulkan_timeline_debug.h");
    
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
        @cInclude("processthreadsapi.h");
    } else {
        @cInclude("pthread.h");
        @cInclude("time.h");
        @cInclude("unistd.h");
        @cInclude("sys/syscall.h");
    }
});

// Platform-specific mutex helpers
fn debug_mutex_init(mutex: *?*anyopaque) bool {
    if (builtin.os.tag == .windows) {
        const cs = std.heap.c_allocator.create(c.CRITICAL_SECTION) catch return false;
        c.InitializeCriticalSection(cs);
        mutex.* = cs;
        return true;
    } else {
        const m = std.heap.c_allocator.create(c.pthread_mutex_t) catch return false;
        if (c.pthread_mutex_init(m, null) != 0) {
            std.heap.c_allocator.destroy(m);
            return false;
        }
        mutex.* = m;
        return true;
    }
}

fn debug_mutex_destroy(mutex: *?*anyopaque) void {
    if (mutex.*) |m| {
        if (builtin.os.tag == .windows) {
            const cs: *c.CRITICAL_SECTION = @ptrCast(@alignCast(m));
            c.DeleteCriticalSection(cs);
            std.heap.c_allocator.destroy(cs);
        } else {
            const pm: *c.pthread_mutex_t = @ptrCast(@alignCast(m));
            _ = c.pthread_mutex_destroy(pm);
            std.heap.c_allocator.destroy(pm);
        }
        mutex.* = null;
    }
}

fn debug_mutex_lock(mutex: ?*anyopaque) void {
    if (mutex) |m| {
        if (builtin.os.tag == .windows) {
            c.EnterCriticalSection(@ptrCast(@alignCast(m)));
        } else {
            _ = c.pthread_mutex_lock(@ptrCast(@alignCast(m)));
        }
    }
}

fn debug_mutex_unlock(mutex: ?*anyopaque) void {
    if (mutex) |m| {
        if (builtin.os.tag == .windows) {
            c.LeaveCriticalSection(@ptrCast(@alignCast(m)));
        } else {
            _ = c.pthread_mutex_unlock(@ptrCast(@alignCast(m)));
        }
    }
}

pub export fn vulkan_timeline_debug_get_timestamp_ns() callconv(.c) u64 {
    if (builtin.os.tag == .windows) {
        var frequency: c.LARGE_INTEGER = undefined;
        var counter: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceFrequency(&frequency);
        _ = c.QueryPerformanceCounter(&counter);
        return @intCast(@divTrunc(counter.QuadPart * 1000000000, frequency.QuadPart));
    } else {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1000000000 + @as(u64, @intCast(ts.tv_nsec));
    }
}

pub export fn vulkan_timeline_debug_get_thread_id() callconv(.c) u32 {
    if (builtin.os.tag == .windows) {
        return c.GetCurrentThreadId();
    } else {
        // SYS_gettid might not be available directly in all libc bindings
        // Using pthread_self might be safer but returns pointer/opaque
        // C code used syscall(SYS_gettid), let's try to mimic
        return @intCast(c.syscall(c.SYS_gettid));
    }
}

pub export fn vulkan_timeline_debug_event_type_to_string(type_enum: c.VulkanTimelineEventType) callconv(.c) [*c]const u8 {
    return switch (type_enum) {
        c.VULKAN_TIMELINE_EVENT_WAIT_START => "WAIT_START",
        c.VULKAN_TIMELINE_EVENT_WAIT_END => "WAIT_END",
        c.VULKAN_TIMELINE_EVENT_SIGNAL_START => "SIGNAL_START",
        c.VULKAN_TIMELINE_EVENT_SIGNAL_END => "SIGNAL_END",
        c.VULKAN_TIMELINE_EVENT_VALUE_QUERY => "VALUE_QUERY",
        c.VULKAN_TIMELINE_EVENT_ERROR => "ERROR",
        c.VULKAN_TIMELINE_EVENT_RECOVERY => "RECOVERY",
        c.VULKAN_TIMELINE_EVENT_POOL_ALLOC => "POOL_ALLOC",
        c.VULKAN_TIMELINE_EVENT_POOL_DEALLOC => "POOL_DEALLOC",
        else => "UNKNOWN",
    };
}

pub export fn vulkan_timeline_debug_init(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) bool {
    @memset(@as([*]u8, @ptrCast(debug_ctx))[0..@sizeOf(c.VulkanTimelineDebugContext)], 0);

    if (!debug_mutex_init(&debug_ctx.mutex)) {
        log.cardinal_log_error("[TIMELINE_DEBUG] Failed to allocate mutex", .{});
        return false;
    }

    @atomicStore(u32, &debug_ctx.event_write_index, 0, .seq_cst);
    @atomicStore(u32, &debug_ctx.event_count, 0, .seq_cst);

    @atomicStore(u64, &debug_ctx.metrics.total_waits, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.total_signals, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.total_wait_time_ns, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.total_signal_time_ns, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.max_wait_time_ns, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.max_signal_time_ns, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.timeout_count, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.error_count, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.recovery_count, 0, .seq_cst);

    debug_ctx.enabled = true;
    debug_ctx.collect_events = true;
    debug_ctx.collect_performance = true;
    debug_ctx.verbose_logging = false;
    debug_ctx.snapshot_interval_ns = 1000000000; // 1 second
    debug_ctx.last_snapshot_time = vulkan_timeline_debug_get_timestamp_ns();

    log.cardinal_log_info("[TIMELINE_DEBUG] Debug context initialized", .{});
    return true;
}

pub export fn vulkan_timeline_debug_destroy(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) void {
    if (debug_ctx.mutex == null) return;

    debug_mutex_destroy(&debug_ctx.mutex);
    @memset(@as([*]u8, @ptrCast(debug_ctx))[0..@sizeOf(c.VulkanTimelineDebugContext)], 0);

    log.cardinal_log_info("[TIMELINE_DEBUG] Debug context destroyed", .{});
}

pub export fn vulkan_timeline_debug_reset(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) void {
    if (!debug_ctx.enabled) return;

    debug_mutex_lock(debug_ctx.mutex);

    @atomicStore(u32, &debug_ctx.event_write_index, 0, .seq_cst);
    @atomicStore(u32, &debug_ctx.event_count, 0, .seq_cst);
    @memset(@as([*]u8, @ptrCast(&debug_ctx.events))[0..@sizeOf(@TypeOf(debug_ctx.events))], 0);

    @atomicStore(u64, &debug_ctx.metrics.total_waits, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.total_signals, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.total_wait_time_ns, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.total_signal_time_ns, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.max_wait_time_ns, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.max_signal_time_ns, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.timeout_count, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.error_count, 0, .seq_cst);
    @atomicStore(u64, &debug_ctx.metrics.recovery_count, 0, .seq_cst);

    debug_ctx.last_snapshot_time = vulkan_timeline_debug_get_timestamp_ns();

    debug_mutex_unlock(debug_ctx.mutex);

    log.cardinal_log_info("[TIMELINE_DEBUG] Debug context reset", .{});
}

pub export fn vulkan_timeline_debug_set_enabled(debug_ctx: *c.VulkanTimelineDebugContext, enabled: bool) callconv(.c) void {
    debug_ctx.enabled = enabled;
    log.cardinal_log_info("[TIMELINE_DEBUG] Debug {s}", .{if (enabled) "enabled" else "disabled"});
}

pub export fn vulkan_timeline_debug_set_event_collection(debug_ctx: *c.VulkanTimelineDebugContext, enabled: bool) callconv(.c) void {
    debug_ctx.collect_events = enabled;
}

pub export fn vulkan_timeline_debug_set_performance_collection(debug_ctx: *c.VulkanTimelineDebugContext, enabled: bool) callconv(.c) void {
    debug_ctx.collect_performance = enabled;
}

pub export fn vulkan_timeline_debug_set_verbose_logging(debug_ctx: *c.VulkanTimelineDebugContext, enabled: bool) callconv(.c) void {
    debug_ctx.verbose_logging = enabled;
}

pub export fn vulkan_timeline_debug_set_snapshot_interval(debug_ctx: *c.VulkanTimelineDebugContext, interval_ns: u64) callconv(.c) void {
    debug_ctx.snapshot_interval_ns = interval_ns;
}

pub export fn vulkan_timeline_debug_log_event(debug_ctx: *c.VulkanTimelineDebugContext, type_enum: c.VulkanTimelineEventType, timeline_value: u64, result: c.VkResult, name: [*c]const u8, details: [*c]const u8) callconv(.c) void {
    if (!debug_ctx.enabled or !debug_ctx.collect_events) return;

    const index = @atomicRmw(u32, &debug_ctx.event_write_index, .Add, 1, .seq_cst) % c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
    const event = &debug_ctx.events[index];

    event.type = type_enum;
    event.timestamp_ns = vulkan_timeline_debug_get_timestamp_ns();
    event.timeline_value = timeline_value;
    event.duration_ns = 0;
    event.result = result;
    event.thread_id = vulkan_timeline_debug_get_thread_id();

    if (name != null) {
        _ = c.strncpy(&event.name, name, c.VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH - 1);
        event.name[c.VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH - 1] = 0;
    } else {
        event.name[0] = 0;
    }

    if (details != null) {
        _ = c.strncpy(&event.details, details, 127);
        event.details[127] = 0;
    } else {
        event.details[0] = 0;
    }

    _ = @atomicRmw(u32, &debug_ctx.event_count, .Add, 1, .seq_cst);

    if (debug_ctx.verbose_logging) {
        const name_slice = if (name != null) std.mem.span(name) else "<unnamed>";
        const type_str = std.mem.span(vulkan_timeline_debug_event_type_to_string(type_enum));
        log.cardinal_log_debug("[TIMELINE_DEBUG] {s}: value={d}, result={d}, thread={d}, name={s}", 
            .{type_str, timeline_value, result, event.thread_id, name_slice});
    }
}

pub export fn vulkan_timeline_debug_log_wait_start(debug_ctx: *c.VulkanTimelineDebugContext, value: u64, timeout_ns: u64, name: [*c]const u8) callconv(.c) void {
    var details: [128]u8 = undefined;
    _ = std.fmt.bufPrintZ(&details, "timeout={d} ns", .{timeout_ns}) catch {};
    vulkan_timeline_debug_log_event(debug_ctx, c.VULKAN_TIMELINE_EVENT_WAIT_START, value, c.VK_SUCCESS, name, @ptrCast(&details));
}

pub export fn vulkan_timeline_debug_log_wait_end(debug_ctx: *c.VulkanTimelineDebugContext, value: u64, result: c.VkResult, duration_ns: u64, name: [*c]const u8) callconv(.c) void {
    var details: [128]u8 = undefined;
    _ = std.fmt.bufPrintZ(&details, "duration={d} ns", .{duration_ns}) catch {};

    const current_index = @atomicLoad(u32, &debug_ctx.event_write_index, .seq_cst);
    const event_count = @atomicLoad(u32, &debug_ctx.event_count, .seq_cst);
    
    var i: u32 = 0;
    while (i < c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS and i < event_count) : (i += 1) {
        // Handle wrapping manually since % operator behavior on negative numbers in C vs Zig might differ or just be safe
        // (current_index - 1 - i) can underflow u32, but wrapping arithmetic is fine for modulo if power of 2, 
        // but MAX_EVENTS is 1000.
        // Let's do it safely:
        const check_index = (current_index + c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS - 1 - i) % c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        const event = &debug_ctx.events[check_index];

        if (event.type == c.VULKAN_TIMELINE_EVENT_WAIT_START and event.timeline_value == value and
            event.thread_id == vulkan_timeline_debug_get_thread_id() and event.duration_ns == 0) {
            event.duration_ns = duration_ns;
            break;
        }
    }

    vulkan_timeline_debug_log_event(debug_ctx, c.VULKAN_TIMELINE_EVENT_WAIT_END, value, result, name, @ptrCast(&details));

    if (debug_ctx.collect_performance) {
        vulkan_timeline_debug_update_wait_metrics(debug_ctx, duration_ns, result == c.VK_TIMEOUT);
    }
}

pub export fn vulkan_timeline_debug_log_signal_start(debug_ctx: *c.VulkanTimelineDebugContext, value: u64, name: [*c]const u8) callconv(.c) void {
    vulkan_timeline_debug_log_event(debug_ctx, c.VULKAN_TIMELINE_EVENT_SIGNAL_START, value, c.VK_SUCCESS, name, null);
}

pub export fn vulkan_timeline_debug_log_signal_end(debug_ctx: *c.VulkanTimelineDebugContext, value: u64, result: c.VkResult, duration_ns: u64, name: [*c]const u8) callconv(.c) void {
    var details: [128]u8 = undefined;
    _ = std.fmt.bufPrintZ(&details, "duration={d} ns", .{duration_ns}) catch {};

    const current_index = @atomicLoad(u32, &debug_ctx.event_write_index, .seq_cst);
    const event_count = @atomicLoad(u32, &debug_ctx.event_count, .seq_cst);

    var i: u32 = 0;
    while (i < c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS and i < event_count) : (i += 1) {
        const check_index = (current_index + c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS - 1 - i) % c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        const event = &debug_ctx.events[check_index];

        if (event.type == c.VULKAN_TIMELINE_EVENT_SIGNAL_START and event.timeline_value == value and
            event.thread_id == vulkan_timeline_debug_get_thread_id() and event.duration_ns == 0) {
            event.duration_ns = duration_ns;
            break;
        }
    }

    vulkan_timeline_debug_log_event(debug_ctx, c.VULKAN_TIMELINE_EVENT_SIGNAL_END, value, result, name, @ptrCast(&details));

    if (debug_ctx.collect_performance) {
        vulkan_timeline_debug_update_signal_metrics(debug_ctx, duration_ns);
    }
}

pub export fn vulkan_timeline_debug_update_wait_metrics(debug_ctx: *c.VulkanTimelineDebugContext, duration_ns: u64, timed_out: bool) callconv(.c) void {
    if (!debug_ctx.enabled or !debug_ctx.collect_performance) return;

    _ = @atomicRmw(u64, &debug_ctx.metrics.total_waits, .Add, 1, .seq_cst);
    _ = @atomicRmw(u64, &debug_ctx.metrics.total_wait_time_ns, .Add, duration_ns, .seq_cst);

    if (timed_out) {
        _ = @atomicRmw(u64, &debug_ctx.metrics.timeout_count, .Add, 1, .seq_cst);
    }

    var current_max = @atomicLoad(u64, &debug_ctx.metrics.max_wait_time_ns, .seq_cst);
    while (duration_ns > current_max) {
        if (@atomicRmw(u64, &debug_ctx.metrics.max_wait_time_ns, .Xchg, duration_ns, .seq_cst) == current_max) {
             // Actually Xchg isn't CAS, but close enough if we just want to update max? 
             // Zig's cmpxchg is better.
             // But wait, cmpxchg returns a struct/tuple.
             // Let's use loop with cmpxchgWeak
             // No, wait, if Xchg swaps, we might overwrite a larger value from another thread?
             // CAS is better.
             // However, atomicRmw .Max might exist? Zig doc check... .Max exists!
             break;
        }
        current_max = @atomicLoad(u64, &debug_ctx.metrics.max_wait_time_ns, .seq_cst);
    }
    // Using Max is safer and easier
    _ = @atomicRmw(u64, &debug_ctx.metrics.max_wait_time_ns, .Max, duration_ns, .seq_cst);
}

pub export fn vulkan_timeline_debug_update_signal_metrics(debug_ctx: *c.VulkanTimelineDebugContext, duration_ns: u64) callconv(.c) void {
    if (!debug_ctx.enabled or !debug_ctx.collect_performance) return;

    _ = @atomicRmw(u64, &debug_ctx.metrics.total_signals, .Add, 1, .seq_cst);
    _ = @atomicRmw(u64, &debug_ctx.metrics.total_signal_time_ns, .Add, duration_ns, .seq_cst);

    _ = @atomicRmw(u64, &debug_ctx.metrics.max_signal_time_ns, .Max, duration_ns, .seq_cst);
}

pub export fn vulkan_timeline_debug_increment_error_count(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) void {
    if (debug_ctx.enabled and debug_ctx.collect_performance) {
        _ = @atomicRmw(u64, &debug_ctx.metrics.error_count, .Add, 1, .seq_cst);
    }
}

pub export fn vulkan_timeline_debug_increment_recovery_count(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) void {
    if (debug_ctx.enabled and debug_ctx.collect_performance) {
        _ = @atomicRmw(u64, &debug_ctx.metrics.recovery_count, .Add, 1, .seq_cst);
    }
}

pub export fn vulkan_timeline_debug_take_snapshot(debug_ctx: *c.VulkanTimelineDebugContext, device: c.VkDevice, timeline_semaphore: c.VkSemaphore) callconv(.c) void {
    if (!debug_ctx.enabled or device == null or timeline_semaphore == null) return;

    debug_mutex_lock(debug_ctx.mutex);

    const snapshot = &debug_ctx.last_snapshot;
    const result = c.vkGetSemaphoreCounterValue(device, timeline_semaphore, &snapshot.current_value);
    snapshot.is_valid = (result == c.VK_SUCCESS);
    snapshot.last_error = result;

    if (snapshot.is_valid) {
        snapshot.pending_signals = 0;
        snapshot.pending_waits = 0;
        snapshot.last_signaled_value = snapshot.current_value;
        snapshot.next_expected_value = snapshot.current_value + 1;
    }

    debug_ctx.last_snapshot_time = vulkan_timeline_debug_get_timestamp_ns();

    debug_mutex_unlock(debug_ctx.mutex);

    if (debug_ctx.verbose_logging) {
        log.cardinal_log_debug("[TIMELINE_DEBUG] Snapshot taken: value={d}, valid={s}",
            .{snapshot.current_value, if (snapshot.is_valid) "true" else "false"});
    }
}

pub export fn vulkan_timeline_debug_should_take_snapshot(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) bool {
    if (!debug_ctx.enabled) return false;
    const current_time = vulkan_timeline_debug_get_timestamp_ns();
    return (current_time - debug_ctx.last_snapshot_time) >= debug_ctx.snapshot_interval_ns;
}

pub export fn vulkan_timeline_debug_get_performance_metrics(debug_ctx: *c.VulkanTimelineDebugContext, metrics: *c.VulkanTimelinePerformanceMetrics) callconv(.c) bool {
    metrics.total_waits = @atomicLoad(u64, &debug_ctx.metrics.total_waits, .seq_cst);
    metrics.total_signals = @atomicLoad(u64, &debug_ctx.metrics.total_signals, .seq_cst);
    metrics.total_wait_time_ns = @atomicLoad(u64, &debug_ctx.metrics.total_wait_time_ns, .seq_cst);
    metrics.total_signal_time_ns = @atomicLoad(u64, &debug_ctx.metrics.total_signal_time_ns, .seq_cst);
    metrics.max_wait_time_ns = @atomicLoad(u64, &debug_ctx.metrics.max_wait_time_ns, .seq_cst);
    metrics.max_signal_time_ns = @atomicLoad(u64, &debug_ctx.metrics.max_signal_time_ns, .seq_cst);
    metrics.timeout_count = @atomicLoad(u64, &debug_ctx.metrics.timeout_count, .seq_cst);
    metrics.error_count = @atomicLoad(u64, &debug_ctx.metrics.error_count, .seq_cst);
    metrics.recovery_count = @atomicLoad(u64, &debug_ctx.metrics.recovery_count, .seq_cst);
    return true;
}

pub export fn vulkan_timeline_debug_get_last_snapshot(debug_ctx: *c.VulkanTimelineDebugContext, snapshot: *c.VulkanTimelineStateSnapshot) callconv(.c) bool {
    debug_mutex_lock(debug_ctx.mutex);
    snapshot.* = debug_ctx.last_snapshot;
    debug_mutex_unlock(debug_ctx.mutex);
    return true;
}

pub export fn vulkan_timeline_debug_get_event_count(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) u32 {
    const count = @atomicLoad(u32, &debug_ctx.event_count, .seq_cst);
    return if (count > c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS) c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS else count;
}

pub export fn vulkan_timeline_debug_get_events(debug_ctx: *c.VulkanTimelineDebugContext, events: [*]c.VulkanTimelineDebugEvent, max_events: u32, actual_count: *u32) callconv(.c) bool {
    debug_mutex_lock(debug_ctx.mutex);

    const available_events = vulkan_timeline_debug_get_event_count(debug_ctx);
    const copy_count = if (available_events < max_events) available_events else max_events;

    var start_index = @atomicLoad(u32, &debug_ctx.event_write_index, .seq_cst);
    if (available_events < c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS) {
        start_index = 0;
    } else {
        start_index = (start_index + c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS - available_events) % c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
    }

    var i: u32 = 0;
    while (i < copy_count) : (i += 1) {
        const index = (start_index + i) % c.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        events[i] = debug_ctx.events[index];
    }

    actual_count.* = copy_count;

    debug_mutex_unlock(debug_ctx.mutex);
    return true;
}

pub export fn vulkan_timeline_debug_print_performance_report(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) void {
    var metrics: c.VulkanTimelinePerformanceMetrics = undefined;
    if (!vulkan_timeline_debug_get_performance_metrics(debug_ctx, &metrics)) return;

    log.cardinal_log_info("[TIMELINE_DEBUG] === Performance Report ===", .{});
    log.cardinal_log_info("[TIMELINE_DEBUG] Total waits: {d}", .{metrics.total_waits});
    log.cardinal_log_info("[TIMELINE_DEBUG] Total signals: {d}", .{metrics.total_signals});

    if (metrics.total_waits > 0) {
        const avg_wait = metrics.total_wait_time_ns / metrics.total_waits;
        log.cardinal_log_info("[TIMELINE_DEBUG] Average wait time: {d} ns ({d:.3} ms)", .{avg_wait, @as(f64, @floatFromInt(avg_wait)) / 1000000.0});
        log.cardinal_log_info("[TIMELINE_DEBUG] Max wait time: {d} ns ({d:.3} ms)", .{metrics.max_wait_time_ns, @as(f64, @floatFromInt(metrics.max_wait_time_ns)) / 1000000.0});
    }

    if (metrics.total_signals > 0) {
        const avg_signal = metrics.total_signal_time_ns / metrics.total_signals;
        log.cardinal_log_info("[TIMELINE_DEBUG] Average signal time: {d} ns ({d:.3} ms)", .{avg_signal, @as(f64, @floatFromInt(avg_signal)) / 1000000.0});
        log.cardinal_log_info("[TIMELINE_DEBUG] Max signal time: {d} ns ({d:.3} ms)", .{metrics.max_signal_time_ns, @as(f64, @floatFromInt(metrics.max_signal_time_ns)) / 1000000.0});
    }

    log.cardinal_log_info("[TIMELINE_DEBUG] Timeouts: {d}", .{metrics.timeout_count});
    log.cardinal_log_info("[TIMELINE_DEBUG] Errors: {d}", .{metrics.error_count});
    log.cardinal_log_info("[TIMELINE_DEBUG] Recoveries: {d}", .{metrics.recovery_count});
    log.cardinal_log_info("[TIMELINE_DEBUG] =========================", .{});
}

pub export fn vulkan_timeline_debug_print_event_summary(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) void {
    const event_count = vulkan_timeline_debug_get_event_count(debug_ctx);
    log.cardinal_log_info("[TIMELINE_DEBUG] === Event Summary ===", .{});
    log.cardinal_log_info("[TIMELINE_DEBUG] Total events recorded: {d}", .{event_count});

    var type_counts: [9]u32 = std.mem.zeroes([9]u32);
    
    // Allocate temp buffer
    const events = std.heap.c_allocator.alloc(c.VulkanTimelineDebugEvent, event_count) catch return;
    defer std.heap.c_allocator.free(events);

    var actual_count: u32 = 0;
    if (vulkan_timeline_debug_get_events(debug_ctx, events.ptr, event_count, &actual_count)) {
        var i: u32 = 0;
        while (i < actual_count) : (i += 1) {
            // events[i].type is c_uint, not an enum in Zig's C import if not typedeffed perfectly
            // But we know it's VulkanTimelineEventType.
            // If the error says 'expected enum or tagged union, found c_uint', it means @intFromEnum is wrong because it's already an int.
            const t = events[i].type;
            if (t < 9) {
                type_counts[t] += 1;
            }
        }
    }

    var i: u32 = 0;
    while (i < 9) : (i += 1) {
        if (type_counts[i] > 0) {
            const type_str = std.mem.span(vulkan_timeline_debug_event_type_to_string(@as(c.VulkanTimelineEventType, i)));
            log.cardinal_log_info("[TIMELINE_DEBUG] {s}: {d}", .{type_str, type_counts[i]});
        }
    }

    log.cardinal_log_info("[TIMELINE_DEBUG] ===================", .{});
}

pub export fn vulkan_timeline_debug_print_state_report(debug_ctx: *c.VulkanTimelineDebugContext) callconv(.c) void {
    var snapshot: c.VulkanTimelineStateSnapshot = undefined;
    if (!vulkan_timeline_debug_get_last_snapshot(debug_ctx, &snapshot)) return;

    log.cardinal_log_info("[TIMELINE_DEBUG] === State Report ===", .{});
    log.cardinal_log_info("[TIMELINE_DEBUG] Current value: {d}", .{snapshot.current_value});
    log.cardinal_log_info("[TIMELINE_DEBUG] Last signaled: {d}", .{snapshot.last_signaled_value});
    log.cardinal_log_info("[TIMELINE_DEBUG] Next expected: {d}", .{snapshot.next_expected_value});
    log.cardinal_log_info("[TIMELINE_DEBUG] Pending signals: {d}", .{snapshot.pending_signals});
    log.cardinal_log_info("[TIMELINE_DEBUG] Pending waits: {d}", .{snapshot.pending_waits});
    log.cardinal_log_info("[TIMELINE_DEBUG] Valid: {s}", .{if (snapshot.is_valid) "true" else "false"});
    if (!snapshot.is_valid) {
        log.cardinal_log_info("[TIMELINE_DEBUG] Last error: {d}", .{snapshot.last_error});
    }
    log.cardinal_log_info("[TIMELINE_DEBUG] =================", .{});
}

// Export functions (simplified)
pub export fn vulkan_timeline_debug_export_events_csv(debug_ctx: *c.VulkanTimelineDebugContext, filename: [*c]const u8) callconv(.c) bool {
    if (filename == null) {
        log.cardinal_log_error("[TIMELINE_DEBUG] Invalid filename for CSV export", .{});
        return false;
    }
    const fname = std.mem.span(filename);
    
    const file = std.fs.cwd().createFile(fname, .{}) catch |err| {
        log.cardinal_log_error("[TIMELINE_DEBUG] Failed to open file for CSV export: {s} (error: {any})", .{fname, err});
        return false;
    };
    defer file.close();
    
    file.writeAll("timestamp_ns,type,timeline_value,duration_ns,result,thread_id,name,details\n") catch return false;

    const event_count = vulkan_timeline_debug_get_event_count(debug_ctx);
    const events = std.heap.c_allocator.alloc(c.VulkanTimelineDebugEvent, event_count) catch return false;
    defer std.heap.c_allocator.free(events);

    var actual_count: u32 = 0;
    if (vulkan_timeline_debug_get_events(debug_ctx, events.ptr, event_count, &actual_count)) {
        var i: u32 = 0;
        var buf: [1024]u8 = undefined;
        while (i < actual_count) : (i += 1) {
            const ev = events[i];
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ev.name)));
            const details = std.mem.span(@as([*:0]const u8, @ptrCast(&ev.details)));
            
            const line = std.fmt.bufPrint(&buf, "{d},{s},{d},{d},{d},{d},\"{s}\",\"{s}\"\n", .{
                ev.timestamp_ns,
                std.mem.span(vulkan_timeline_debug_event_type_to_string(ev.type)),
                ev.timeline_value,
                ev.duration_ns,
                ev.result,
                ev.thread_id,
                name,
                details
            }) catch return false;
            
            file.writeAll(line) catch return false;
        }
    }

    log.cardinal_log_info("[TIMELINE_DEBUG] Events exported to CSV: {s}", .{fname});
    return true;
}

pub export fn vulkan_timeline_debug_export_performance_json(debug_ctx: *c.VulkanTimelineDebugContext, filename: [*c]const u8) callconv(.c) bool {
    var metrics: c.VulkanTimelinePerformanceMetrics = undefined;
    if (!vulkan_timeline_debug_get_performance_metrics(debug_ctx, &metrics)) return false;

    if (filename == null) {
        log.cardinal_log_error("[TIMELINE_DEBUG] Invalid filename for JSON export", .{});
        return false;
    }
    const fname = std.mem.span(filename);
    
    const file = std.fs.cwd().createFile(fname, .{}) catch |err| {
        log.cardinal_log_error("[TIMELINE_DEBUG] Failed to open file for JSON export: {s} (error: {any})", .{fname, err});
        return false;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const json_str = std.fmt.bufPrint(&buf,
        "{{\n" ++
        "  \"total_waits\": {d},\n" ++
        "  \"total_signals\": {d},\n" ++
        "  \"total_wait_time_ns\": {d},\n" ++
        "  \"total_signal_time_ns\": {d},\n" ++
        "  \"max_wait_time_ns\": {d},\n" ++
        "  \"max_signal_time_ns\": {d},\n" ++
        "  \"timeout_count\": {d},\n" ++
        "  \"error_count\": {d},\n" ++
        "  \"recovery_count\": {d}\n" ++
        "}}\n",
        .{
            metrics.total_waits,
            metrics.total_signals,
            metrics.total_wait_time_ns,
            metrics.total_signal_time_ns,
            metrics.max_wait_time_ns,
            metrics.max_signal_time_ns,
            metrics.timeout_count,
            metrics.error_count,
            metrics.recovery_count
        }
    ) catch return false;

    file.writeAll(json_str) catch return false;

    log.cardinal_log_info("[TIMELINE_DEBUG] Performance metrics exported to JSON: {s}", .{fname});
    return true;
}
