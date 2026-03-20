//! Shader module cache helpers.
//!
//! Manages shader module caching without coupling to pipeline creation logic.

const std = @import("std");
const memory = @import("../../core/memory.zig");
const c = @import("../vulkan_c.zig").c;

/// Pointer-based view over a shader module cache embedded in another struct.
pub const CacheView = struct {
    shader_modules: *?[*]c.VkShaderModule,
    shader_paths: *?[*][*c]u8,
    shader_module_count: *u32,
    shader_module_capacity: *u32,
};

/// Grows the backing arrays if needed.
pub fn ensure_capacity(view: *CacheView) bool {
    if (view.shader_module_count.* >= view.shader_module_capacity.*) {
        const new_capacity = if (view.shader_module_capacity.* == 0) 16 else view.shader_module_capacity.* * 2;
        const alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        const new_modules = memory.cardinal_realloc(alloc, @as(?*anyopaque, @ptrCast(view.shader_modules.*)), @sizeOf(c.VkShaderModule) * new_capacity);
        const new_paths = memory.cardinal_realloc(alloc, @as(?*anyopaque, @ptrCast(view.shader_paths.*)), @sizeOf([*c]u8) * new_capacity);

        if (new_modules == null or new_paths == null) {
            return false;
        }
        view.shader_modules.* = @ptrCast(@alignCast(new_modules));
        view.shader_paths.* = @ptrCast(@alignCast(new_paths));
        view.shader_module_capacity.* = new_capacity;
    }
    return true;
}

/// Returns the index of `shader_path`, or -1 if not present.
pub fn find_index(view: *const CacheView, shader_path: [*c]const u8) i32 {
    var i: u32 = 0;
    while (i < view.shader_module_count.*) : (i += 1) {
        if (view.shader_paths.*.?[i] != null and c.strcmp(view.shader_paths.*.?[i], shader_path) == 0) {
            return @intCast(i);
        }
    }
    return -1;
}

/// Returns a cached shader module for `shader_path`, or null if absent.
pub fn get_cached_shader(view: *const CacheView, shader_path: [*c]const u8) c.VkShaderModule {
    const index = find_index(view, shader_path);
    if (index >= 0) {
        return view.shader_modules.*.?[@intCast(index)];
    }
    return null;
}

/// Inserts a shader module into the cache, taking ownership of a copied path.
pub fn add_shader(view: *CacheView, shader_path: [*c]const u8, module: c.VkShaderModule) bool {
    if (!ensure_capacity(view)) return false;

    const index = view.shader_module_count.*;
    view.shader_module_count.* += 1;
    view.shader_modules.*.?[index] = module;

    const src = std.mem.span(shader_path);
    const alloc = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();
    const buf = alloc.alloc(u8, src.len + 1) catch return false;
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;

    view.shader_paths.*.?[index] = @ptrCast(buf.ptr);
    return true;
}

/// Destroys cached shader modules and frees copied paths.
pub fn clear(view: *CacheView, device: c.VkDevice) void {
    const alloc = memory.cardinal_get_allocator_for_category(.RENDERER).as_allocator();

    var i: u32 = 0;
    while (i < view.shader_module_count.*) : (i += 1) {
        if (view.shader_modules.*.?[i] != null) {
            c.vkDestroyShaderModule(device, view.shader_modules.*.?[i], null);
        }
        if (view.shader_paths.*.?[i] != null) {
            const p = view.shader_paths.*.?[i];
            const len = c.strlen(p);
            alloc.free(@as([*]u8, @ptrCast(p))[0 .. len + 1]);
        }
    }
    view.shader_module_count.* = 0;
}
