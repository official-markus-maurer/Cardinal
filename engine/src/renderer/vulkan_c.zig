const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cDefine("CARDINAL_ZIG_BUILD", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("stdio.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("GLFW/glfw3.h");
    
    if (builtin.os.tag == .windows) {
        @cInclude("windows.h");
    } else {
        @cInclude("pthread.h");
        @cInclude("unistd.h");
        @cInclude("sys/syscall.h");
        @cInclude("time.h");
    }
});
