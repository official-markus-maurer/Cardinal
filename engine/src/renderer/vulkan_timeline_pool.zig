const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const tl_pool_log = log.ScopedLogger("TL_POOL");
const platform = @import("../core/platform.zig");
const types = @import("vulkan_timeline_types.zig");

const c = types.c;

const memory = @import("../core/memory.zig");

// Platform-specific mutex helpers
fn pool_mutex_init(mutex: *?*anyopaque) bool {
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

fn pool_mutex_destroy(mutex: *?*anyopaque) void {
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

fn pool_mutex_lock(mutex: ?*anyopaque) void {
    if (mutex) |m| {
        if (builtin.os.tag == .windows) {
            c.EnterCriticalSection(@ptrCast(@alignCast(m)));
        } else {
            _ = c.pthread_mutex_lock(@ptrCast(@alignCast(m)));
        }
    }
}

fn pool_mutex_unlock(mutex: ?*anyopaque) void {
    if (mutex) |m| {
        if (builtin.os.tag == .windows) {
            c.LeaveCriticalSection(@ptrCast(@alignCast(m)));
        } else {
            _ = c.pthread_mutex_unlock(@ptrCast(@alignCast(m)));
        }
    }
}

fn get_current_time_ns() u64 {
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

fn create_timeline_semaphore(device: c.VkDevice, semaphore: *c.VkSemaphore) bool {
    var timeline_info = c.VkSemaphoreTypeCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
        .pNext = null,
        .semaphoreType = c.VK_SEMAPHORE_TYPE_TIMELINE,
        .initialValue = 0,
    };

    var create_info = c.VkSemaphoreCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &timeline_info,
        .flags = 0,
    };

    const result = c.vkCreateSemaphore(device, &create_info, null, semaphore);
    if (result != c.VK_SUCCESS) {
        tl_pool_log.err("Failed to create timeline semaphore: {d}", .{result});
        return false;
    }

    return true;
}

pub export fn vulkan_timeline_pool_init(pool: *types.VulkanTimelinePool, device: c.VkDevice, initial_size: u32, max_size: u32) callconv(.c) bool {
    if (initial_size == 0) {
        return false;
    }

    pool.device = device;
    pool.pool_size = 0;
    pool.max_pool_size = if (max_size > 0) max_size else std.math.maxInt(u32);
    @atomicStore(u32, &pool.active_count, 0, .seq_cst);

    // Allocate entries array
    const entries_size = @sizeOf(types.VulkanTimelinePoolEntry) * pool.max_pool_size;
    const entries_ptr = std.heap.c_allocator.alloc(u8, entries_size) catch {
        tl_pool_log.err("Failed to allocate pool entries", .{});
        return false;
    };
    @memset(entries_ptr, 0);
    pool.entries = @ptrCast(@alignCast(entries_ptr.ptr));

    // Initialize mutex
    if (!pool_mutex_init(&pool.mutex)) {
        tl_pool_log.err("Failed to allocate mutex", .{});
        std.heap.c_allocator.free(entries_ptr);
        return false;
    }

    // Initialize statistics
    @atomicStore(u64, &pool.allocations, 0, .seq_cst);
    @atomicStore(u64, &pool.deallocations, 0, .seq_cst);
    @atomicStore(u64, &pool.cache_hits, 0, .seq_cst);
    @atomicStore(u64, &pool.cache_misses, 0, .seq_cst);

    // Default configuration
    pool.max_idle_time_ns = 5000000000; // 5 seconds
    pool.auto_cleanup_enabled = true;

    // Pre-allocate initial semaphores
    const current_time = get_current_time_ns();
    var i: u32 = 0;
    while (i < initial_size and i < pool.max_pool_size) : (i += 1) {
        if (create_timeline_semaphore(device, &pool.entries[i].semaphore)) {
            pool.entries[i].last_signaled_value = 0;
            pool.entries[i].in_use = false;
            pool.entries[i].creation_time = current_time;
            pool.pool_size += 1;
        } else {
            tl_pool_log.warn("Failed to pre-allocate semaphore {d}", .{i});
            break;
        }
    }

    pool.initialized = true;
    tl_pool_log.info("Initialized with {d}/{d} semaphores (max: {d})", .{ pool.pool_size, initial_size, pool.max_pool_size });

    return true;
}

pub export fn vulkan_timeline_pool_destroy(pool: *types.VulkanTimelinePool) callconv(.c) void {
    if (!pool.initialized) {
        return;
    }

    pool_mutex_lock(pool.mutex);

    // Destroy all semaphores
    var i: u32 = 0;
    while (i < pool.pool_size) : (i += 1) {
        if (pool.entries[i].semaphore != null) {
            c.vkDestroySemaphore(pool.device, pool.entries[i].semaphore, null);
        }
    }

    pool_mutex_unlock(pool.mutex);

    // Cleanup resources
    pool_mutex_destroy(&pool.mutex);

    // Free entries
    const entries_slice = @as([*]u8, @ptrCast(pool.entries))[0..(@sizeOf(types.VulkanTimelinePoolEntry) * pool.max_pool_size)];
    const allocator = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    allocator.free(entries_slice);

    // Zero out struct
    _ = c.memset(pool, 0, @sizeOf(types.VulkanTimelinePool));

    tl_pool_log.info("Destroyed", .{});
}

pub export fn vulkan_timeline_pool_allocate(pool: *types.VulkanTimelinePool, allocation: *types.VulkanTimelinePoolAllocation) callconv(.c) bool {
    if (!pool.initialized) {
        return false;
    }

    pool_mutex_lock(pool.mutex);

    // Try to find an unused semaphore
    var i: u32 = 0;
    while (i < pool.pool_size) : (i += 1) {
        if (!pool.entries[i].in_use and pool.entries[i].semaphore != null) {
            pool.entries[i].in_use = true;
            allocation.semaphore = pool.entries[i].semaphore;
            allocation.pool_index = i;
            allocation.from_cache = true;

            _ = @atomicRmw(u32, &pool.active_count, .Add, 1, .seq_cst);
            _ = @atomicRmw(u64, &pool.allocations, .Add, 1, .seq_cst);
            _ = @atomicRmw(u64, &pool.cache_hits, .Add, 1, .seq_cst);

            pool_mutex_unlock(pool.mutex);
            return true;
        }
    }

    // No free semaphore found, create new one if possible
    if (pool.pool_size < pool.max_pool_size) {
        const new_index = pool.pool_size;
        if (create_timeline_semaphore(pool.device, &pool.entries[new_index].semaphore)) {
            pool.entries[new_index].last_signaled_value = 0;
            pool.entries[new_index].in_use = true;
            pool.entries[new_index].creation_time = platform.get_time_ns();

            allocation.semaphore = pool.entries[new_index].semaphore;
            allocation.pool_index = new_index;
            allocation.from_cache = false;

            pool.pool_size += 1;
            _ = @atomicRmw(u32, &pool.active_count, .Add, 1, .seq_cst);
            _ = @atomicRmw(u64, &pool.allocations, .Add, 1, .seq_cst);
            _ = @atomicRmw(u64, &pool.cache_misses, .Add, 1, .seq_cst);

            pool_mutex_unlock(pool.mutex);
            return true;
        }
    }

    pool_mutex_unlock(pool.mutex);
    return false;
}

pub export fn vulkan_timeline_pool_deallocate(pool: *types.VulkanTimelinePool, pool_index: u32, last_value: u64) callconv(.c) void {
    if (!pool.initialized or pool_index >= pool.pool_size) {
        return;
    }

    pool_mutex_lock(pool.mutex);

    if (pool.entries[pool_index].in_use) {
        pool.entries[pool_index].in_use = false;
        pool.entries[pool_index].last_signaled_value = last_value;

        _ = @atomicRmw(u32, &pool.active_count, .Sub, 1, .seq_cst);
        _ = @atomicRmw(u64, &pool.deallocations, .Add, 1, .seq_cst);
    }

    pool_mutex_unlock(pool.mutex);
}

pub export fn vulkan_timeline_pool_cleanup_idle(pool: *types.VulkanTimelinePool, current_time_ns: u64) callconv(.c) u32 {
    if (!pool.initialized) {
        return 0;
    }

    pool_mutex_lock(pool.mutex);

    var cleaned_up: u32 = 0;

    // Only cleanup if auto-cleanup is enabled
    if (pool.auto_cleanup_enabled) {
        var i: u32 = 0;
        while (i < pool.pool_size) : (i += 1) {
            if (!pool.entries[i].in_use and pool.entries[i].semaphore != null and
                (current_time_ns - pool.entries[i].creation_time) > pool.max_idle_time_ns)
            {
                c.vkDestroySemaphore(pool.device, pool.entries[i].semaphore, null);
                pool.entries[i].semaphore = null;
                cleaned_up += 1;
            }
        }
    }

    pool_mutex_unlock(pool.mutex);

    if (cleaned_up > 0) {
        tl_pool_log.debug("Cleaned up {d} idle semaphores", .{cleaned_up});
    }

    return cleaned_up;
}

pub export fn vulkan_timeline_pool_get_stats(pool: *types.VulkanTimelinePool, active_count: ?*u32, total_allocations: ?*u64, cache_hit_rate: ?*f32) callconv(.c) bool {
    if (!pool.initialized) {
        return false;
    }

    if (active_count) |ptr| {
        ptr.* = @atomicLoad(u32, &pool.active_count, .seq_cst);
    }

    if (total_allocations) |ptr| {
        ptr.* = @atomicLoad(u64, &pool.allocations, .seq_cst);
    }

    if (cache_hit_rate) |ptr| {
        const hits = @atomicLoad(u64, &pool.cache_hits, .seq_cst);
        const total = @atomicLoad(u64, &pool.allocations, .seq_cst);
        ptr.* = if (total > 0) @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(total)) else 0.0;
    }

    return true;
}

pub export fn vulkan_timeline_pool_configure_cleanup(pool: *types.VulkanTimelinePool, enabled: bool, max_idle_time_ns: u64) callconv(.c) void {
    if (!pool.initialized) {
        return;
    }

    pool_mutex_lock(pool.mutex);
    pool.auto_cleanup_enabled = enabled;
    pool.max_idle_time_ns = max_idle_time_ns;
    pool_mutex_unlock(pool.mutex);

    tl_pool_log.info("Auto-cleanup {s}, max idle time: {d} ns", .{ if (enabled) "enabled" else "disabled", max_idle_time_ns });
}

pub export fn vulkan_timeline_pool_reset_stats(pool: *types.VulkanTimelinePool) callconv(.c) void {
    if (!pool.initialized) {
        return;
    }

    @atomicStore(u64, &pool.allocations, 0, .seq_cst);
    @atomicStore(u64, &pool.deallocations, 0, .seq_cst);
    @atomicStore(u64, &pool.cache_hits, 0, .seq_cst);
    @atomicStore(u64, &pool.cache_misses, 0, .seq_cst);

    tl_pool_log.info("Statistics reset", .{});
}
