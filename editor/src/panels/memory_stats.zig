const std = @import("std");
const engine = @import("cardinal_engine");
const memory = engine.memory;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;

fn get_category_name(cat: memory.CardinalMemoryCategory) [*:0]const u8 {
    return switch (cat) {
        .UNKNOWN => "Unknown",
        .ENGINE => "Engine",
        .RENDERER => "Renderer",
        .VULKAN_BUFFERS => "Vulkan Buffers",
        .VULKAN_DEVICE => "Vulkan Device",
        .TEXTURES => "Textures",
        .MESHES => "Meshes",
        .ASSETS => "Assets",
        .SHADERS => "Shaders",
        .WINDOW => "Window",
        .LOGGING => "Logging",
        .TEMPORARY => "Temporary",
        .MAX => "Max",
    };
}

fn format_size(size: usize, buf: *[32]u8) [*:0]const u8 {
    if (size < 1024) {
        _ = std.fmt.bufPrintZ(buf, "{d} B", .{size}) catch return "Err";
    } else if (size < 1024 * 1024) {
        _ = std.fmt.bufPrintZ(buf, "{d:.2} KB", .{@as(f64, @floatFromInt(size)) / 1024.0}) catch return "Err";
    } else {
        _ = std.fmt.bufPrintZ(buf, "{d:.2} MB", .{@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0)}) catch return "Err";
    }
    return @ptrCast(buf);
}

pub fn draw_memory_stats_panel(state: *EditorState) void {
    if (!state.show_memory_stats) return;

    const open = c.imgui_bridge_begin("Memory Stats", &state.show_memory_stats, 0);
    defer c.imgui_bridge_end();

    if (open) {
        var stats: memory.CardinalGlobalMemoryStats = undefined;
        memory.cardinal_memory_get_stats(&stats);

        c.imgui_bridge_text("Total Allocated: ");
        c.imgui_bridge_same_line(0, -1);
        var buf: [32]u8 = undefined;
        c.imgui_bridge_text("%s", format_size(stats.total.current_usage, &buf));

        c.imgui_bridge_text("Peak Usage: ");
        c.imgui_bridge_same_line(0, -1);
        c.imgui_bridge_text("%s", format_size(stats.total.peak_usage, &buf));

        c.imgui_bridge_text("Allocations: %d", stats.total.allocation_count);
        c.imgui_bridge_text("Frees: %d", stats.total.free_count);

        c.imgui_bridge_separator();

        const outer_size = c.ImVec2{ .x = 0, .y = 0 };
        if (c.imgui_bridge_begin_table("MemoryCategories", 4, c.ImGuiTableFlags_Borders | c.ImGuiTableFlags_RowBg, &outer_size, 0.0)) {
            c.imgui_bridge_table_setup_column("Category", 0, 0, 0);
            c.imgui_bridge_table_setup_column("Current", 0, 0, 0);
            c.imgui_bridge_table_setup_column("Peak", 0, 0, 0);
            c.imgui_bridge_table_setup_column("Allocs", 0, 0, 0);
            c.imgui_bridge_table_headers_row();

            var i: i32 = 0;
            const max_cat = @intFromEnum(memory.CardinalMemoryCategory.MAX);
            while (i < max_cat) : (i += 1) {
                const cat = @as(memory.CardinalMemoryCategory, @enumFromInt(i));
                const cat_stats = stats.categories[@intCast(i)];

                // Only show categories with activity
                if (cat_stats.allocation_count > 0) {
                    c.imgui_bridge_table_next_row(0, 0);

                    c.imgui_bridge_table_set_column_index(0);
                    c.imgui_bridge_text("%s", get_category_name(cat));

                    c.imgui_bridge_table_set_column_index(1);
                    c.imgui_bridge_text("%s", format_size(cat_stats.current_usage, &buf));

                    c.imgui_bridge_table_set_column_index(2);
                    c.imgui_bridge_text("%s", format_size(cat_stats.peak_usage, &buf));

                    c.imgui_bridge_table_set_column_index(3);
                    c.imgui_bridge_text("%d", cat_stats.allocation_count);
                }
            }
            c.imgui_bridge_end_table();
        }
    }
}
