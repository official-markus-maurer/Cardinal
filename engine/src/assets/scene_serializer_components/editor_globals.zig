const std = @import("std");
const components = @import("../../ecs/components.zig");

pub fn serialize(writer: anytype, g: *components.EditorGlobals) !void {
    try writer.beginObject();

    try writer.objectField("camera_position");
    try writer.write([3]f32{ g.camera_position.x, g.camera_position.y, g.camera_position.z });

    try writer.objectField("camera_target");
    try writer.write([3]f32{ g.camera_target.x, g.camera_target.y, g.camera_target.z });

    try writer.objectField("camera_up");
    try writer.write([3]f32{ g.camera_up.x, g.camera_up.y, g.camera_up.z });

    try writer.objectField("camera_fov");
    try writer.write(g.camera_fov);

    try writer.objectField("camera_aspect");
    try writer.write(g.camera_aspect);

    try writer.objectField("camera_near");
    try writer.write(g.camera_near);

    try writer.objectField("camera_far");
    try writer.write(g.camera_far);

    try writer.objectField("selected_entity_id");
    try writer.write(g.selected_entity_id);

    try writer.objectField("show_scene_graph");
    try writer.write(g.show_scene_graph);
    try writer.objectField("show_scene_view");
    try writer.write(g.show_scene_view);
    try writer.objectField("show_game_view");
    try writer.write(g.show_game_view);
    try writer.objectField("show_assets");
    try writer.write(g.show_assets);
    try writer.objectField("show_model_manager");
    try writer.write(g.show_model_manager);
    try writer.objectField("show_entity_inspector");
    try writer.write(g.show_entity_inspector);
    try writer.objectField("show_scene_manager");
    try writer.write(g.show_scene_manager);
    try writer.objectField("show_pbr_settings");
    try writer.write(g.show_pbr_settings);
    try writer.objectField("show_animation");
    try writer.write(g.show_animation);
    try writer.objectField("show_terrain_panel");
    try writer.write(g.show_terrain_panel);
    try writer.objectField("show_grid_axes");
    try writer.write(g.show_grid_axes);
    try writer.objectField("show_performance_panel");
    try writer.write(g.show_performance_panel);
    try writer.objectField("enable_viewports");
    try writer.write(g.enable_viewports);

    try writer.objectField("game_camera_entity_id");
    try writer.write(g.game_camera_entity_id);

    try writer.objectField("pbr_enabled");
    try writer.write(g.pbr_enabled);

    try writer.objectField("rendering_mode");
    try writer.write(g.rendering_mode);

    try writer.objectField("post_exposure");
    try writer.write(g.post_exposure);
    try writer.objectField("post_contrast");
    try writer.write(g.post_contrast);
    try writer.objectField("post_saturation");
    try writer.write(g.post_saturation);
    try writer.objectField("post_bloom_intensity");
    try writer.write(g.post_bloom_intensity);
    try writer.objectField("post_bloom_threshold");
    try writer.write(g.post_bloom_threshold);
    try writer.objectField("post_bloom_knee");
    try writer.write(g.post_bloom_knee);

    try writer.endObject();
}

pub fn deserialize(val: std.json.Value) !components.EditorGlobals {
    if (val != .object) return error.InvalidFormat;
    var g = components.EditorGlobals{};

    if (val.object.get("camera_position")) |v| {
        if (v == .array and v.array.items.len >= 3) {
            if (v.array.items[0] == .float and v.array.items[1] == .float and v.array.items[2] == .float) {
                g.camera_position = .{ .x = @floatCast(v.array.items[0].float), .y = @floatCast(v.array.items[1].float), .z = @floatCast(v.array.items[2].float) };
            } else if (v.array.items[0] == .integer and v.array.items[1] == .integer and v.array.items[2] == .integer) {
                g.camera_position = .{ .x = @floatFromInt(v.array.items[0].integer), .y = @floatFromInt(v.array.items[1].integer), .z = @floatFromInt(v.array.items[2].integer) };
            }
        }
    }
    if (val.object.get("camera_target")) |v| {
        if (v == .array and v.array.items.len >= 3) {
            if (v.array.items[0] == .float and v.array.items[1] == .float and v.array.items[2] == .float) {
                g.camera_target = .{ .x = @floatCast(v.array.items[0].float), .y = @floatCast(v.array.items[1].float), .z = @floatCast(v.array.items[2].float) };
            } else if (v.array.items[0] == .integer and v.array.items[1] == .integer and v.array.items[2] == .integer) {
                g.camera_target = .{ .x = @floatFromInt(v.array.items[0].integer), .y = @floatFromInt(v.array.items[1].integer), .z = @floatFromInt(v.array.items[2].integer) };
            }
        }
    }
    if (val.object.get("camera_up")) |v| {
        if (v == .array and v.array.items.len >= 3) {
            if (v.array.items[0] == .float and v.array.items[1] == .float and v.array.items[2] == .float) {
                g.camera_up = .{ .x = @floatCast(v.array.items[0].float), .y = @floatCast(v.array.items[1].float), .z = @floatCast(v.array.items[2].float) };
            } else if (v.array.items[0] == .integer and v.array.items[1] == .integer and v.array.items[2] == .integer) {
                g.camera_up = .{ .x = @floatFromInt(v.array.items[0].integer), .y = @floatFromInt(v.array.items[1].integer), .z = @floatFromInt(v.array.items[2].integer) };
            }
        }
    }

    if (val.object.get("camera_fov")) |v| {
        if (v == .float) g.camera_fov = @floatCast(v.float) else if (v == .integer) g.camera_fov = @floatFromInt(v.integer);
    }
    if (val.object.get("camera_aspect")) |v| {
        if (v == .float) g.camera_aspect = @floatCast(v.float) else if (v == .integer) g.camera_aspect = @floatFromInt(v.integer);
    }
    if (val.object.get("camera_near")) |v| {
        if (v == .float) g.camera_near = @floatCast(v.float) else if (v == .integer) g.camera_near = @floatFromInt(v.integer);
    }
    if (val.object.get("camera_far")) |v| {
        if (v == .float) g.camera_far = @floatCast(v.float) else if (v == .integer) g.camera_far = @floatFromInt(v.integer);
    }

    if (val.object.get("selected_entity_id")) |v| {
        if (v == .integer) g.selected_entity_id = @intCast(v.integer);
    }

    if (val.object.get("show_scene_graph")) |v| {
        if (v == .bool) g.show_scene_graph = v.bool;
    }
    if (val.object.get("show_scene_view")) |v| {
        if (v == .bool) g.show_scene_view = v.bool;
    }
    if (val.object.get("show_game_view")) |v| {
        if (v == .bool) g.show_game_view = v.bool;
    }
    if (val.object.get("show_assets")) |v| {
        if (v == .bool) g.show_assets = v.bool;
    }
    if (val.object.get("show_model_manager")) |v| {
        if (v == .bool) g.show_model_manager = v.bool;
    }
    if (val.object.get("show_entity_inspector")) |v| {
        if (v == .bool) g.show_entity_inspector = v.bool;
    }
    if (val.object.get("show_scene_manager")) |v| {
        if (v == .bool) g.show_scene_manager = v.bool;
    }
    if (val.object.get("show_pbr_settings")) |v| {
        if (v == .bool) g.show_pbr_settings = v.bool;
    }
    if (val.object.get("show_animation")) |v| {
        if (v == .bool) g.show_animation = v.bool;
    }
    if (val.object.get("show_terrain_panel")) |v| {
        if (v == .bool) g.show_terrain_panel = v.bool;
    }
    if (val.object.get("show_grid_axes")) |v| {
        if (v == .bool) g.show_grid_axes = v.bool;
    }
    if (val.object.get("show_performance_panel")) |v| {
        if (v == .bool) g.show_performance_panel = v.bool;
    }
    if (val.object.get("enable_viewports")) |v| {
        if (v == .bool) g.enable_viewports = v.bool;
    }

    if (val.object.get("game_camera_entity_id")) |v| {
        if (v == .integer) g.game_camera_entity_id = @intCast(v.integer);
    }

    if (val.object.get("pbr_enabled")) |v| {
        if (v == .bool) g.pbr_enabled = v.bool;
    }
    if (val.object.get("rendering_mode")) |v| {
        if (v == .integer) g.rendering_mode = @intCast(v.integer);
    }

    if (val.object.get("post_exposure")) |v| {
        if (v == .float) g.post_exposure = @floatCast(v.float) else if (v == .integer) g.post_exposure = @floatFromInt(v.integer);
    }
    if (val.object.get("post_contrast")) |v| {
        if (v == .float) g.post_contrast = @floatCast(v.float) else if (v == .integer) g.post_contrast = @floatFromInt(v.integer);
    }
    if (val.object.get("post_saturation")) |v| {
        if (v == .float) g.post_saturation = @floatCast(v.float) else if (v == .integer) g.post_saturation = @floatFromInt(v.integer);
    }
    if (val.object.get("post_bloom_intensity")) |v| {
        if (v == .float) g.post_bloom_intensity = @floatCast(v.float) else if (v == .integer) g.post_bloom_intensity = @floatFromInt(v.integer);
    }
    if (val.object.get("post_bloom_threshold")) |v| {
        if (v == .float) g.post_bloom_threshold = @floatCast(v.float) else if (v == .integer) g.post_bloom_threshold = @floatFromInt(v.integer);
    }
    if (val.object.get("post_bloom_knee")) |v| {
        if (v == .float) g.post_bloom_knee = @floatCast(v.float) else if (v == .integer) g.post_bloom_knee = @floatFromInt(v.integer);
    }

    return g;
}
