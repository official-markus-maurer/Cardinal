//! Platform mutex helpers for timeline modules.
//!
//! Provides a small C-ABI friendly mutex abstraction used by timeline debug/pool code.
const builtin = @import("builtin");
const types = @import("../vulkan_timeline_types.zig");
const c = types.c;

/// Initializes an inline mutex.
pub fn init(mutex: *types.VulkanTimelineMutex) bool {
    if (builtin.os.tag == .windows) {
        const cs: *c.CRITICAL_SECTION = @ptrCast(@alignCast(&mutex.storage));
        c.InitializeCriticalSection(cs);
        mutex.initialized = 1;
        return true;
    } else {
        const m: *c.pthread_mutex_t = @ptrCast(@alignCast(&mutex.storage));
        if (c.pthread_mutex_init(m, null) != 0) {
            return false;
        }
        mutex.initialized = 1;
        return true;
    }
}

/// Destroys an initialized mutex and marks it as uninitialized.
pub fn destroy(mutex: *types.VulkanTimelineMutex) void {
    if (mutex.initialized == 0) return;
    if (builtin.os.tag == .windows) {
        const cs: *c.CRITICAL_SECTION = @ptrCast(@alignCast(&mutex.storage));
        c.DeleteCriticalSection(cs);
    } else {
        const pm: *c.pthread_mutex_t = @ptrCast(@alignCast(&mutex.storage));
        _ = c.pthread_mutex_destroy(pm);
    }
    mutex.initialized = 0;
}

/// Locks an initialized mutex.
pub fn lock(mutex: *types.VulkanTimelineMutex) void {
    if (mutex.initialized == 0) return;
    if (builtin.os.tag == .windows) {
        c.EnterCriticalSection(@ptrCast(@alignCast(&mutex.storage)));
    } else {
        _ = c.pthread_mutex_lock(@ptrCast(@alignCast(&mutex.storage)));
    }
}

/// Unlocks an initialized mutex.
pub fn unlock(mutex: *types.VulkanTimelineMutex) void {
    if (mutex.initialized == 0) return;
    if (builtin.os.tag == .windows) {
        c.LeaveCriticalSection(@ptrCast(@alignCast(&mutex.storage)));
    } else {
        _ = c.pthread_mutex_unlock(@ptrCast(@alignCast(&mutex.storage)));
    }
}
