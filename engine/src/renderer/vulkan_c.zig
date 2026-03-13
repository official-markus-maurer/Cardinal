//! Vulkan C imports and platform defines.
//!
//! Centralizes C headers and compile-time defines used by Vulkan, VMA, and GLFW interop.
//!
//! TODO: Deduplicate C import compatibility defines with `vulkan_timeline_types.zig`.
const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("stdio.h");
    @cDefine("VMA_STATIC_VULKAN_FUNCTIONS", "0");
    @cDefine("VMA_DYNAMIC_VULKAN_FUNCTIONS", "0");
    @cDefine("VMA_EXTERNAL_MEMORY", "0");
    @cInclude("vulkan/vulkan.h");
    @cInclude("vma/vk_mem_alloc.h");
    @cInclude("GLFW/glfw3.h");

    if (builtin.os.tag == .windows) {
        @cDefine("WIN32", "1");
        @cDefine("_WIN32", "1");
        @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
        @cInclude("windows.h");
    } else {
        @cInclude("pthread.h");
        @cInclude("unistd.h");
        @cInclude("sys/syscall.h");
        @cInclude("time.h");
    }
});
