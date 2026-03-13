//! Performance panel.
//!
//! Displays basic frame timing and the engine's global memory statistics.
//!
//! TODO: Track per-frame allocation deltas instead of only absolute totals.
const std = @import("std");
const engine = @import("cardinal_engine");
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;
const renderer = engine.vulkan_renderer;
const memory = engine.memory;

/// Number of samples stored in the frame-time history.
const HISTORY_SIZE = 240;
var frame_time_history: [HISTORY_SIZE]f32 = [_]f32{0} ** HISTORY_SIZE;
var history_offset: usize = 0;

/// Draws the performance panel.
pub fn draw_performance_panel(state: *EditorState) void {
    if (state.show_performance_panel) {
        const open = c.imgui_bridge_begin("Performance", &state.show_performance_panel, 0);
        defer c.imgui_bridge_end();

        if (open) {
            const fps = c.imgui_bridge_get_framerate();
            const dt = if (fps > 0) 1000.0 / fps else 0.0;

            frame_time_history[history_offset] = dt;
            history_offset = (history_offset + 1) % HISTORY_SIZE;

            c.imgui_bridge_text("Frame Performance");

            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrintZ(&buf, "FPS: {d:.1} | Frame Time: {d:.3} ms", .{ fps, dt }) catch "FPS: ???";
            c.imgui_bridge_text("%s", text.ptr);

            const graph_size = c.ImVec2{ .x = 0, .y = 80 };
            c.imgui_bridge_plot_lines("##FrameTimes", &frame_time_history[0], HISTORY_SIZE, @intCast(history_offset), "Frame Time (ms)", 0.0, 33.3, &graph_size, @as(c_int, @intCast(@sizeOf(f32))));

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Memory Usage", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var stats: memory.CardinalGlobalMemoryStats = undefined;
                memory.cardinal_memory_get_stats(&stats);

                const total_mb = @as(f64, @floatFromInt(stats.total.current_usage)) / (1024.0 * 1024.0);
                const peak_mb = @as(f64, @floatFromInt(stats.total.peak_usage)) / (1024.0 * 1024.0);

                const total_text = std.fmt.bufPrintZ(&buf, "Total: {d:.2} MB (Peak: {d:.2} MB)", .{ total_mb, peak_mb }) catch "???";
                c.imgui_bridge_text("%s", total_text.ptr);

                const alloc_text = std.fmt.bufPrintZ(&buf, "Allocations: {d}", .{stats.total.allocation_count - stats.total.free_count}) catch "???";
                c.imgui_bridge_text("%s", alloc_text.ptr);

                if (c.imgui_bridge_begin_table("MemoryCategories", 4, c.ImGuiTableFlags_Borders | c.ImGuiTableFlags_RowBg | c.ImGuiTableFlags_Resizable, &c.ImVec2{ .x = 0, .y = 0 }, 0.0)) {
                    c.imgui_bridge_table_setup_column("Category", c.ImGuiTableColumnFlags_None, 0.0, 0);
                    c.imgui_bridge_table_setup_column("Usage (MB)", c.ImGuiTableColumnFlags_None, 0.0, 0);
                    c.imgui_bridge_table_setup_column("Peak (MB)", c.ImGuiTableColumnFlags_None, 0.0, 0);
                    c.imgui_bridge_table_setup_column("Count", c.ImGuiTableColumnFlags_None, 0.0, 0);
                    c.imgui_bridge_table_headers_row();

                    // TODO: Derive this from the engine memory category enum to avoid drift.
                    const categories = [_][:0]const u8{ "Unknown", "Engine", "Renderer", "Vulkan Buffers", "Vulkan Device", "Textures", "Meshes", "Assets", "Shaders", "Window", "Logging", "Temporary" };

                    var i: usize = 0;
                    while (i < categories.len) : (i += 1) {
                        const cat_stats = stats.categories[i];
                        if (cat_stats.current_usage > 0 or cat_stats.peak_usage > 0) {
                            c.imgui_bridge_table_next_row(0, 0.0);

                            c.imgui_bridge_table_set_column_index(0);
                            c.imgui_bridge_text("%s", categories[i].ptr);

                            c.imgui_bridge_table_set_column_index(1);
                            const usage_mb = @as(f64, @floatFromInt(cat_stats.current_usage)) / (1024.0 * 1024.0);
                            const cat_text = std.fmt.bufPrintZ(&buf, "{d:.2}", .{usage_mb}) catch "0.00";
                            c.imgui_bridge_text("%s", cat_text.ptr);

                            c.imgui_bridge_table_set_column_index(2);
                            const peak_mb_cat = @as(f64, @floatFromInt(cat_stats.peak_usage)) / (1024.0 * 1024.0);
                            const peak_text = std.fmt.bufPrintZ(&buf, "{d:.2}", .{peak_mb_cat}) catch "0.00";
                            c.imgui_bridge_text("%s", peak_text.ptr);

                            c.imgui_bridge_table_set_column_index(3);
                            const count_text = std.fmt.bufPrintZ(&buf, "{d}", .{cat_stats.allocation_count}) catch "0";
                            c.imgui_bridge_text("%s", count_text.ptr);
                        }
                    }

                    c.imgui_bridge_end_table();
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("External Profiling", c.ImGuiTreeNodeFlags_None)) {
                c.imgui_bridge_text("Tracy Profiler is enabled.");
                c.imgui_bridge_text("Run the Tracy Server application to connect and view detailed timeline.");
                c.imgui_bridge_text("This panel shows live aggregate stats.");
            }
        }
    }
}
