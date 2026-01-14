const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const tl_dbg_log = log.ScopedLogger("TL_DEBUG");
const platform = @import("../core/platform.zig");
const memory = @import("../core/memory.zig");
const types = @import("vulkan_timeline_types.zig");

const c = types.c;

// Platform-specific mutex helpers
fn debug_mutex_init(mutex: *?*anyopaque) bool {
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    if (builtin.os.tag == .windows) {
        const ptr = memory.cardinal_alloc(allocator, @sizeOf(c.CRITICAL_SECTION));
        if (ptr == null) return false;
        const cs = @as(*c.CRITICAL_SECTION, @ptrCast(@alignCast(ptr)));

        c.InitializeCriticalSection(cs);
        mutex.* = cs;
        return true;
    } else {
        const ptr = memory.cardinal_alloc(allocator, @sizeOf(c.pthread_mutex_t));
        if (ptr == null) return false;
        const m = @as(*c.pthread_mutex_t, @ptrCast(@alignCast(ptr)));

        if (c.pthread_mutex_init(m, null) != 0) {
            memory.cardinal_free(allocator, m);
            return false;
        }
        mutex.* = m;
        return true;
    }
}

fn debug_mutex_destroy(mutex: *?*anyopaque) void {
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    if (mutex.*) |m| {
        if (builtin.os.tag == .windows) {
            const cs: *c.CRITICAL_SECTION = @ptrCast(@alignCast(m));
            c.DeleteCriticalSection(cs);
            memory.cardinal_free(allocator, cs);
        } else {
            const pm: *c.pthread_mutex_t = @ptrCast(@alignCast(m));
            _ = c.pthread_mutex_destroy(pm);
            memory.cardinal_free(allocator, pm);
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
    return platform.get_time_ns();
}

pub export fn vulkan_timeline_debug_get_thread_id() callconv(.c) u32 {
    return platform.get_current_thread_id();
}

pub export fn vulkan_timeline_debug_event_type_to_string(type_enum: types.VulkanTimelineEventType) callconv(.c) [*c]const u8 {
    return switch (type_enum) {
        types.VULKAN_TIMELINE_EVENT_WAIT_START => "WAIT_START",
        types.VULKAN_TIMELINE_EVENT_WAIT_END => "WAIT_END",
        types.VULKAN_TIMELINE_EVENT_SIGNAL_START => "SIGNAL_START",
        types.VULKAN_TIMELINE_EVENT_SIGNAL_END => "SIGNAL_END",
        types.VULKAN_TIMELINE_EVENT_VALUE_QUERY => "VALUE_QUERY",
        types.VULKAN_TIMELINE_EVENT_ERROR => "ERROR",
        types.VULKAN_TIMELINE_EVENT_RECOVERY => "RECOVERY",
        types.VULKAN_TIMELINE_EVENT_POOL_ALLOC => "POOL_ALLOC",
        types.VULKAN_TIMELINE_EVENT_POOL_DEALLOC => "POOL_DEALLOC",
    };
}

pub export fn vulkan_timeline_debug_init(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) bool {
    @memset(@as([*]u8, @ptrCast(debug_ctx))[0..@sizeOf(types.VulkanTimelineDebugContext)], 0);

    if (!debug_mutex_init(&debug_ctx.mutex)) {
        tl_dbg_log.err("Failed to allocate mutex", .{});
        return false;
    }

    // Allocate pool
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER);
    const ptr = memory.cardinal_alloc(allocator, @sizeOf(types.VulkanTimelineDebugEvent) * 1024); // Start with 1024 events
    if (ptr == null) {
        tl_dbg_log.err("Failed to allocate event pool", .{});
        debug_mutex_destroy(&debug_ctx.mutex);
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

    tl_dbg_log.info("Debug context initialized", .{});
    return true;
}

pub export fn vulkan_timeline_debug_destroy(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) void {
    if (debug_ctx.mutex == null) return;

    debug_mutex_destroy(&debug_ctx.mutex);
    @memset(@as([*]u8, @ptrCast(debug_ctx))[0..@sizeOf(types.VulkanTimelineDebugContext)], 0);

    tl_dbg_log.info("Debug context destroyed", .{});
}

pub export fn vulkan_timeline_debug_reset(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) void {
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

    tl_dbg_log.info("Debug context reset", .{});
}

pub export fn vulkan_timeline_debug_set_enabled(debug_ctx: *types.VulkanTimelineDebugContext, enabled: bool) callconv(.c) void {
    debug_ctx.enabled = enabled;
    tl_dbg_log.info("Debug {s}", .{if (enabled) "enabled" else "disabled"});
}

pub export fn vulkan_timeline_debug_set_event_collection(debug_ctx: *types.VulkanTimelineDebugContext, enabled: bool) callconv(.c) void {
    debug_ctx.collect_events = enabled;
}

pub export fn vulkan_timeline_debug_set_performance_collection(debug_ctx: *types.VulkanTimelineDebugContext, enabled: bool) callconv(.c) void {
    debug_ctx.collect_performance = enabled;
}

pub export fn vulkan_timeline_debug_set_verbose_logging(debug_ctx: *types.VulkanTimelineDebugContext, enabled: bool) callconv(.c) void {
    debug_ctx.verbose_logging = enabled;
}

pub export fn vulkan_timeline_debug_set_snapshot_interval(debug_ctx: *types.VulkanTimelineDebugContext, interval_ns: u64) callconv(.c) void {
    debug_ctx.snapshot_interval_ns = interval_ns;
}

pub export fn vulkan_timeline_debug_log_event(debug_ctx: *types.VulkanTimelineDebugContext, type_enum: types.VulkanTimelineEventType, timeline_value: u64, result: c.VkResult, name: [*c]const u8, details: [*c]const u8) callconv(.c) void {
    if (!debug_ctx.enabled or !debug_ctx.collect_events) return;

    const index = @atomicRmw(u32, &debug_ctx.event_write_index, .Add, 1, .seq_cst) % types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
    const event = &debug_ctx.events[index];

    event.type = type_enum;
    event.timestamp_ns = vulkan_timeline_debug_get_timestamp_ns();
    event.timeline_value = timeline_value;
    event.duration_ns = 0;
    event.result = result;
    event.thread_id = vulkan_timeline_debug_get_thread_id();

    if (name != null) {
        _ = c.strncpy(&event.name, name, types.VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH - 1);
        event.name[types.VULKAN_TIMELINE_DEBUG_MAX_NAME_LENGTH - 1] = 0;
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
        tl_dbg_log.debug("{s}: value={d}, result={d}, thread={d}, name={s}", .{ type_str, timeline_value, result, event.thread_id, name_slice });
    }
}

pub export fn vulkan_timeline_debug_log_wait_start(debug_ctx: *types.VulkanTimelineDebugContext, value: u64, timeout_ns: u64, name: [*c]const u8) callconv(.c) void {
    var details: [128]u8 = undefined;
    _ = std.fmt.bufPrintZ(&details, "timeout={d} ns", .{timeout_ns}) catch {};
    vulkan_timeline_debug_log_event(debug_ctx, types.VULKAN_TIMELINE_EVENT_WAIT_START, value, c.VK_SUCCESS, name, @ptrCast(&details));
}

pub export fn vulkan_timeline_debug_log_wait_end(debug_ctx: *types.VulkanTimelineDebugContext, value: u64, result: c.VkResult, duration_ns: u64, name: [*c]const u8) callconv(.c) void {
    var details: [128]u8 = undefined;
    _ = std.fmt.bufPrintZ(&details, "duration={d} ns", .{duration_ns}) catch {};

    const current_index = @atomicLoad(u32, &debug_ctx.event_write_index, .seq_cst);
    const event_count = @atomicLoad(u32, &debug_ctx.event_count, .seq_cst);

    var i: u32 = 0;
    while (i < types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS and i < event_count) : (i += 1) {
        const check_index = (current_index + types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS - 1 - i) % types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        const event = &debug_ctx.events[check_index];

        if (event.type == types.VULKAN_TIMELINE_EVENT_WAIT_START and event.timeline_value == value and
            event.thread_id == vulkan_timeline_debug_get_thread_id() and event.duration_ns == 0)
        {
            event.duration_ns = duration_ns;
            break;
        }
    }

    vulkan_timeline_debug_log_event(debug_ctx, types.VULKAN_TIMELINE_EVENT_WAIT_END, value, result, name, @ptrCast(&details));

    if (debug_ctx.collect_performance) {
        vulkan_timeline_debug_update_wait_metrics(debug_ctx, duration_ns, result == c.VK_TIMEOUT);
    }
}

pub export fn vulkan_timeline_debug_log_signal_start(debug_ctx: *types.VulkanTimelineDebugContext, value: u64, name: [*c]const u8) callconv(.c) void {
    vulkan_timeline_debug_log_event(debug_ctx, types.VULKAN_TIMELINE_EVENT_SIGNAL_START, value, c.VK_SUCCESS, name, null);
}

pub export fn vulkan_timeline_debug_log_signal_end(debug_ctx: *types.VulkanTimelineDebugContext, value: u64, result: c.VkResult, duration_ns: u64, name: [*c]const u8) callconv(.c) void {
    var details: [128]u8 = undefined;
    _ = std.fmt.bufPrintZ(&details, "duration={d} ns", .{duration_ns}) catch {};

    const current_index = @atomicLoad(u32, &debug_ctx.event_write_index, .seq_cst);
    const event_count = @atomicLoad(u32, &debug_ctx.event_count, .seq_cst);

    var i: u32 = 0;
    while (i < types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS and i < event_count) : (i += 1) {
        const check_index = (current_index + types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS - 1 - i) % types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        const event = &debug_ctx.events[check_index];

        if (event.type == types.VULKAN_TIMELINE_EVENT_SIGNAL_START and event.timeline_value == value and
            event.thread_id == vulkan_timeline_debug_get_thread_id() and event.duration_ns == 0)
        {
            event.duration_ns = duration_ns;
            break;
        }
    }

    vulkan_timeline_debug_log_event(debug_ctx, types.VULKAN_TIMELINE_EVENT_SIGNAL_END, value, result, name, @ptrCast(&details));

    if (debug_ctx.collect_performance) {
        vulkan_timeline_debug_update_signal_metrics(debug_ctx, duration_ns);
    }
}

pub export fn vulkan_timeline_debug_update_wait_metrics(debug_ctx: *types.VulkanTimelineDebugContext, duration_ns: u64, timed_out: bool) callconv(.c) void {
    if (!debug_ctx.enabled or !debug_ctx.collect_performance) return;

    _ = @atomicRmw(u64, &debug_ctx.metrics.total_waits, .Add, 1, .seq_cst);
    _ = @atomicRmw(u64, &debug_ctx.metrics.total_wait_time_ns, .Add, duration_ns, .seq_cst);

    if (timed_out) {
        _ = @atomicRmw(u64, &debug_ctx.metrics.timeout_count, .Add, 1, .seq_cst);
    }

    var current_max = @atomicLoad(u64, &debug_ctx.metrics.max_wait_time_ns, .seq_cst);
    while (duration_ns > current_max) {
        if (@atomicRmw(u64, &debug_ctx.metrics.max_wait_time_ns, .Xchg, duration_ns, .seq_cst) == current_max) {
            break;
        }
        current_max = @atomicLoad(u64, &debug_ctx.metrics.max_wait_time_ns, .seq_cst);
    }
    // Using Max is safer and easier
    _ = @atomicRmw(u64, &debug_ctx.metrics.max_wait_time_ns, .Max, duration_ns, .seq_cst);
}

pub export fn vulkan_timeline_debug_update_signal_metrics(debug_ctx: *types.VulkanTimelineDebugContext, duration_ns: u64) callconv(.c) void {
    if (!debug_ctx.enabled or !debug_ctx.collect_performance) return;

    _ = @atomicRmw(u64, &debug_ctx.metrics.total_signals, .Add, 1, .seq_cst);
    _ = @atomicRmw(u64, &debug_ctx.metrics.total_signal_time_ns, .Add, duration_ns, .seq_cst);

    _ = @atomicRmw(u64, &debug_ctx.metrics.max_signal_time_ns, .Max, duration_ns, .seq_cst);
}

pub export fn vulkan_timeline_debug_increment_error_count(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) void {
    if (debug_ctx.enabled and debug_ctx.collect_performance) {
        _ = @atomicRmw(u64, &debug_ctx.metrics.error_count, .Add, 1, .seq_cst);
    }
}

pub export fn vulkan_timeline_debug_increment_recovery_count(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) void {
    if (debug_ctx.enabled and debug_ctx.collect_performance) {
        _ = @atomicRmw(u64, &debug_ctx.metrics.recovery_count, .Add, 1, .seq_cst);
    }
}

pub export fn vulkan_timeline_debug_take_snapshot(debug_ctx: *types.VulkanTimelineDebugContext, device: c.VkDevice, timeline_semaphore: c.VkSemaphore) callconv(.c) void {
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
        tl_dbg_log.debug("Snapshot taken: value={d}, valid={s}", .{ snapshot.current_value, if (snapshot.is_valid) "true" else "false" });
    }
}

pub export fn vulkan_timeline_debug_should_take_snapshot(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) bool {
    if (!debug_ctx.enabled) return false;
    const current_time = vulkan_timeline_debug_get_timestamp_ns();
    return (current_time - debug_ctx.last_snapshot_time) >= debug_ctx.snapshot_interval_ns;
}

pub export fn vulkan_timeline_debug_get_performance_metrics(debug_ctx: *types.VulkanTimelineDebugContext, metrics: *types.VulkanTimelinePerformanceMetrics) callconv(.c) bool {
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

pub export fn vulkan_timeline_debug_get_last_snapshot(debug_ctx: *types.VulkanTimelineDebugContext, snapshot: *types.VulkanTimelineStateSnapshot) callconv(.c) bool {
    debug_mutex_lock(debug_ctx.mutex);
    snapshot.* = debug_ctx.last_snapshot;
    debug_mutex_unlock(debug_ctx.mutex);
    return true;
}

pub export fn vulkan_timeline_debug_get_event_count(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) u32 {
    const count = @atomicLoad(u32, &debug_ctx.event_count, .seq_cst);
    return if (count > types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS) types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS else count;
}

pub export fn vulkan_timeline_debug_get_events(debug_ctx: *types.VulkanTimelineDebugContext, events: [*]types.VulkanTimelineDebugEvent, max_events: u32, actual_count: *u32) callconv(.c) bool {
    debug_mutex_lock(debug_ctx.mutex);

    const available_events = vulkan_timeline_debug_get_event_count(debug_ctx);
    const copy_count = if (available_events < max_events) available_events else max_events;

    var start_index = @atomicLoad(u32, &debug_ctx.event_write_index, .seq_cst);
    if (available_events < types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS) {
        start_index = 0;
    } else {
        start_index = (start_index + types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS - available_events) % types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
    }

    var i: u32 = 0;
    while (i < copy_count) : (i += 1) {
        const index = (start_index + i) % types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        events[i] = debug_ctx.events[index];
    }

    actual_count.* = copy_count;

    debug_mutex_unlock(debug_ctx.mutex);
    return true;
}

pub export fn vulkan_timeline_debug_dump_events(debug_ctx: *types.VulkanTimelineDebugContext, count: u32) callconv(.c) void {
    if (!debug_ctx.enabled) return;

    tl_dbg_log.info("=== Timeline Event Dump ({d} events) ===", .{count});

    debug_mutex_lock(debug_ctx.mutex);
    defer debug_mutex_unlock(debug_ctx.mutex);

    const event_count = vulkan_timeline_debug_get_event_count(debug_ctx);
    const dump_count = if (count > event_count) event_count else count;
    const current_index = @atomicLoad(u32, &debug_ctx.event_write_index, .seq_cst);

    var i: u32 = 0;
    while (i < dump_count) : (i += 1) {
        const idx = (current_index + types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS - 1 - i) % types.VULKAN_TIMELINE_DEBUG_MAX_EVENTS;
        const event = &debug_ctx.events[idx];

        const type_str = std.mem.span(vulkan_timeline_debug_event_type_to_string(event.type));
        tl_dbg_log.info("[{d}] {s} val={d} thread={d} time={d}", .{ i, type_str, event.timeline_value, event.thread_id, event.timestamp_ns });
    }

    tl_dbg_log.info("===================", .{});
}

pub export fn vulkan_timeline_debug_print_performance_report(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) void {
    var metrics: types.VulkanTimelinePerformanceMetrics = undefined;
    if (!vulkan_timeline_debug_get_performance_metrics(debug_ctx, &metrics)) return;

    const avg_wait = if (metrics.total_waits > 0) metrics.total_wait_time_ns / metrics.total_waits else 0;
    const successes = if (metrics.total_waits >= (metrics.timeout_count + metrics.error_count)) metrics.total_waits - metrics.timeout_count - metrics.error_count else 0;

    tl_dbg_log.info("=== Performance Report ===", .{});
    tl_dbg_log.info("Avg wait time: {d} ns", .{avg_wait});
    tl_dbg_log.info("Max wait time: {d} ns", .{metrics.max_wait_time_ns});
    tl_dbg_log.info("Wait count: {d}", .{metrics.total_waits});
    tl_dbg_log.info("Signal count: {d}", .{metrics.total_signals});
    tl_dbg_log.info("Wait failures: {d}", .{metrics.error_count});
    tl_dbg_log.info("Wait timeouts: {d}", .{metrics.timeout_count});
    tl_dbg_log.info("Wait successes: {d}", .{successes});
    tl_dbg_log.info("===================", .{});
}

pub export fn vulkan_timeline_debug_print_event_summary(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) void {
    const event_count = vulkan_timeline_debug_get_event_count(debug_ctx);
    tl_dbg_log.info("=== Event Summary ===", .{});
    tl_dbg_log.info("Total events recorded: {d}", .{event_count});

    var type_counts: [9]u32 = std.mem.zeroes([9]u32);

    // Allocate temp buffer
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    const events = allocator.alloc(types.VulkanTimelineDebugEvent, event_count) catch return;
    defer allocator.free(events);

    var actual_count: u32 = 0;
    if (vulkan_timeline_debug_get_events(debug_ctx, events.ptr, event_count, &actual_count)) {
        var i: u32 = 0;
        while (i < actual_count) : (i += 1) {
            const t = @intFromEnum(events[i].type);
            if (t < 9) {
                type_counts[@intCast(t)] += 1;
            }
        }
    }

    var i: u32 = 0;
    while (i < 9) : (i += 1) {
        if (type_counts[i] > 0) {
            const type_str = std.mem.span(vulkan_timeline_debug_event_type_to_string(@as(types.VulkanTimelineEventType, @enumFromInt(i))));
            tl_dbg_log.info("{s}: {d}", .{ type_str, type_counts[i] });
        }
    }

    tl_dbg_log.info("===================", .{});
}

pub export fn vulkan_timeline_debug_print_state_report(debug_ctx: *types.VulkanTimelineDebugContext) callconv(.c) void {
    var snapshot: types.VulkanTimelineStateSnapshot = undefined;
    if (!vulkan_timeline_debug_get_last_snapshot(debug_ctx, &snapshot)) return;

    tl_dbg_log.info("=== State Report ===", .{});
    tl_dbg_log.info("Current value: {d}", .{snapshot.current_value});
    tl_dbg_log.info("Last signaled: {d}", .{snapshot.last_signaled_value});
    tl_dbg_log.info("Next expected: {d}", .{snapshot.next_expected_value});
    tl_dbg_log.info("Pending signals: {d}", .{snapshot.pending_signals});
    tl_dbg_log.info("Pending waits: {d}", .{snapshot.pending_waits});
    tl_dbg_log.info("Valid: {s}", .{if (snapshot.is_valid) "true" else "false"});
    if (!snapshot.is_valid) {
        tl_dbg_log.info("Last error: {d}", .{snapshot.last_error});
    }
    tl_dbg_log.info("=================", .{});
}

// Export functions (simplified)
pub export fn vulkan_timeline_debug_export_events_csv(debug_ctx: *types.VulkanTimelineDebugContext, filename: [*c]const u8) callconv(.c) bool {
    if (filename == null) {
        tl_dbg_log.err("Invalid filename for CSV export", .{});
        return false;
    }
    const fname = std.mem.span(filename);

    const file = std.fs.cwd().createFile(fname, .{}) catch |err| {
        tl_dbg_log.err("Failed to open file for CSV export: {s} (error: {any})", .{ fname, err });
        return false;
    };
    defer file.close();

    file.writeAll("timestamp_ns,type,timeline_value,duration_ns,result,thread_id,name,details\n") catch return false;

    const event_count = vulkan_timeline_debug_get_event_count(debug_ctx);
    const events = std.heap.c_allocator.alloc(types.VulkanTimelineDebugEvent, event_count) catch return false;
    defer std.heap.c_allocator.free(events);

    var actual_count: u32 = 0;
    if (vulkan_timeline_debug_get_events(debug_ctx, events.ptr, event_count, &actual_count)) {
        var i: u32 = 0;
        var buf: [1024]u8 = undefined;
        while (i < actual_count) : (i += 1) {
            const ev = events[i];
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ev.name)));
            const details = std.mem.span(@as([*:0]const u8, @ptrCast(&ev.details)));

            const line = std.fmt.bufPrint(&buf, "{d},{s},{d},{d},{d},{d},\"{s}\",\"{s}\"\n", .{ ev.timestamp_ns, std.mem.span(vulkan_timeline_debug_event_type_to_string(ev.type)), ev.timeline_value, ev.duration_ns, ev.result, ev.thread_id, name, details }) catch return false;

            file.writeAll(line) catch return false;
        }
    }

    tl_dbg_log.info("Events exported to CSV: {s}", .{fname});
    return true;
}

pub export fn vulkan_timeline_debug_export_performance_json(debug_ctx: *types.VulkanTimelineDebugContext, filename: [*c]const u8) callconv(.c) bool {
    var metrics: types.VulkanTimelinePerformanceMetrics = undefined;
    if (!vulkan_timeline_debug_get_performance_metrics(debug_ctx, &metrics)) return false;

    if (filename == null) {
        tl_dbg_log.err("Invalid filename for JSON export", .{});
        return false;
    }
    const fname = std.mem.span(filename);

    const file = std.fs.cwd().createFile(fname, .{}) catch |err| {
        tl_dbg_log.err("Failed to open file for JSON export: {s} (error: {any})", .{ fname, err });
        return false;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const json_str = std.fmt.bufPrint(&buf, "{{\n" ++
        "  \"total_waits\": {d},\n" ++
        "  \"total_signals\": {d},\n" ++
        "  \"total_wait_time_ns\": {d},\n" ++
        "  \"total_signal_time_ns\": {d},\n" ++
        "  \"max_wait_time_ns\": {d},\n" ++
        "  \"max_signal_time_ns\": {d},\n" ++
        "  \"timeout_count\": {d},\n" ++
        "  \"error_count\": {d},\n" ++
        "  \"recovery_count\": {d}\n" ++
        "}}\n", .{ metrics.total_waits, metrics.total_signals, metrics.total_wait_time_ns, metrics.total_signal_time_ns, metrics.max_wait_time_ns, metrics.max_signal_time_ns, metrics.timeout_count, metrics.error_count, metrics.recovery_count }) catch return false;

    file.writeAll(json_str) catch return false;

    tl_dbg_log.info("Performance metrics exported to JSON: {s}", .{fname});
    return true;
}
