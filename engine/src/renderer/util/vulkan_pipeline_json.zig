//! Pipeline JSON loading helpers.
//!
//! Provides small utilities around `vulkan_pso.PipelineBuilder` for modules that load pipeline
//! descriptors from JSON and apply per-call overrides (formats, flags).
const std = @import("std");
const vk_pso = @import("../vulkan_pso.zig");
const log = @import("../../core/log.zig");
const c = @import("../vulkan_c.zig").c;

const json_log = log.ScopedLogger("PIPELINE_JSON");

/// Loads a pipeline descriptor from `json_path`, applies format/flag overrides, and builds it.
pub fn build_graphics_pipeline_from_json(
    allocator: std.mem.Allocator,
    device: c.VkDevice,
    pipeline_cache: c.VkPipelineCache,
    pipeline_layout: c.VkPipelineLayout,
    out_pipeline: *c.VkPipeline,
    json_path: []const u8,
    color_formats: []const c.VkFormat,
    depth_format: c.VkFormat,
    extra_flags: c.VkPipelineCreateFlags,
) bool {
    var builder = vk_pso.PipelineBuilder.init(allocator, device, pipeline_cache);

    var parsed = vk_pso.PipelineBuilder.load_from_json(allocator, json_path) catch |err| {
        json_log.err("Failed to load pipeline JSON '{s}': {s}", .{ json_path, @errorName(err) });
        return false;
    };
    defer parsed.deinit();

    var descriptor = parsed.value;
    descriptor.rendering.color_formats = color_formats;
    descriptor.rendering.depth_format = depth_format;
    descriptor.flags |= extra_flags;

    builder.build(descriptor, pipeline_layout, out_pipeline) catch |err| {
        json_log.err("Failed to build pipeline '{s}': {s}", .{ descriptor.name, @errorName(err) });
        return false;
    };

    return true;
}
