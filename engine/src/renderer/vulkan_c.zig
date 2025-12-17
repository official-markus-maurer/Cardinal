const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("stdio.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("GLFW/glfw3.h");
    @cInclude("cardinal/core/window.h");
    @cInclude("cardinal/renderer/renderer.h");
    @cInclude("cardinal/renderer/renderer_internal.h");
    @cInclude("cardinal/core/ref_counting.h");
    @cInclude("cardinal/assets/material_ref_counting.h");
    @cInclude("cardinal/core/transform.h");
    @cInclude("cardinal/renderer/util/vulkan_descriptor_buffer_utils.h");
    @cInclude("cardinal/renderer/vulkan_descriptor_indexing.h");
    @cInclude("cardinal/renderer/vulkan_compute.h");
    @cInclude("cardinal/renderer/util/vulkan_shader_utils.h");
    @cInclude("cardinal/core/log.h");
    @cInclude("cardinal/core/memory.h");
    
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
    } else {
        @cInclude("pthread.h");
        @cInclude("unistd.h");
        @cInclude("sys/syscall.h");
        @cInclude("time.h");
    }
});
