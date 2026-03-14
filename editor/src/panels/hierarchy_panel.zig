//! Scene hierarchy panel.
//!
//! Renders the entity hierarchy tree view and supports selection, rename, and basic creation.
//!
//! TODO: Centralize hierarchy mutations in one system to avoid duplication.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const scene = engine.scene;
const model_manager = engine.model_manager;
const animation = engine.animation;
const components = engine.ecs_components;
const entity_module = engine.ecs_entity;
const node_factory = engine.ecs_node_factory;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;
const scene_io = @import("../systems/scene_io.zig");

const NodeEntry = struct {
    label: []const u8,
    node_type: components.NodeType,
};

const node_entries = [_]NodeEntry{
    .{ .label = "3D/Node3D", .node_type = .Node3D },
    .{ .label = "3D/Marker3D", .node_type = .Marker3D },
    .{ .label = "3D/Camera3D", .node_type = .Camera3D },
    .{ .label = "3D/DirectionalLight3D", .node_type = .DirectionalLight3D },
    .{ .label = "3D/PointLight3D", .node_type = .PointLight3D },
    .{ .label = "3D/SpotLight3D", .node_type = .SpotLight3D },
    .{ .label = "3D/MeshInstance3D", .node_type = .MeshInstance3D },
    .{ .label = "3D/AnimationPlayer", .node_type = .AnimationPlayer },
    .{ .label = "3D/Skeleton3D", .node_type = .Skeleton3D },
    .{ .label = "3D/StaticBody3D", .node_type = .StaticBody3D },
    .{ .label = "3D/RigidBody3D", .node_type = .RigidBody3D },
    .{ .label = "3D/CharacterBody3D", .node_type = .CharacterBody3D },
    .{ .label = "3D/Area3D", .node_type = .Area3D },
    .{ .label = "3D/CollisionShape3D", .node_type = .CollisionShape3D },
    .{ .label = "3D/NavigationRegion3D", .node_type = .NavigationRegion3D },
    .{ .label = "3D/AudioStreamPlayer3D", .node_type = .AudioStreamPlayer3D },
    .{ .label = "3D/GPUParticles3D", .node_type = .GPUParticles3D },
    .{ .label = "Environment/Skybox", .node_type = .Skybox },

    .{ .label = "2D/Node2D", .node_type = .Node2D },
    .{ .label = "2D/Camera2D", .node_type = .Camera2D },
    .{ .label = "2D/Sprite2D", .node_type = .Sprite2D },
    .{ .label = "2D/AnimatedSprite2D", .node_type = .AnimatedSprite2D },
    .{ .label = "2D/TileMap", .node_type = .TileMap },
    .{ .label = "2D/StaticBody2D", .node_type = .StaticBody2D },
    .{ .label = "2D/RigidBody2D", .node_type = .RigidBody2D },
    .{ .label = "2D/CharacterBody2D", .node_type = .CharacterBody2D },
    .{ .label = "2D/Area2D", .node_type = .Area2D },
    .{ .label = "2D/CollisionShape2D", .node_type = .CollisionShape2D },
    .{ .label = "2D/AudioStreamPlayer2D", .node_type = .AudioStreamPlayer2D },
    .{ .label = "2D/GPUParticles2D", .node_type = .GPUParticles2D },

    .{ .label = "UI/Control", .node_type = .Control },
    .{ .label = "UI/TextureRect", .node_type = .TextureRect },
    .{ .label = "UI/Label", .node_type = .Label },
    .{ .label = "UI/Button", .node_type = .Button },
    .{ .label = "UI/CheckBox", .node_type = .CheckBox },
    .{ .label = "UI/Slider", .node_type = .Slider },
    .{ .label = "UI/ProgressBar", .node_type = .ProgressBar },
    .{ .label = "UI/LineEdit", .node_type = .LineEdit },
    .{ .label = "UI/TextEdit", .node_type = .TextEdit },
    .{ .label = "UI/Panel", .node_type = .Panel },
    .{ .label = "UI/VBoxContainer", .node_type = .VBoxContainer },
    .{ .label = "UI/HBoxContainer", .node_type = .HBoxContainer },
    .{ .label = "UI/GridContainer", .node_type = .GridContainer },
    .{ .label = "UI/MarginContainer", .node_type = .MarginContainer },
    .{ .label = "UI/ScrollContainer", .node_type = .ScrollContainer },
};

fn node_prefix(t: components.NodeType) []const u8 {
    const name = @tagName(t);
    if (std.mem.endsWith(u8, name, "3D")) return "[3D] ";
    if (std.mem.endsWith(u8, name, "2D")) return "[2D] ";
    if (std.mem.endsWith(u8, name, "UI")) return "[UI] ";
    if (std.mem.endsWith(u8, name, "Container")) return "[UI] ";
    return switch (t) {
        .Control, .Label, .Button, .Panel, .TextureRect, .CheckBox, .Slider, .ProgressBar, .LineEdit, .TextEdit => "[UI] ",
        else => "",
    };
}

fn base_label(label: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, label, '/')) |idx| {
        return label[idx + 1 ..];
    }
    return label;
}

fn open_create_node_popup(state: *EditorState, parent: ?entity_module.Entity) void {
    state.runtime.create_node_parent = parent;
    c.imgui_bridge_open_popup("create_node_popup");
}

fn create_entity(state: *EditorState, parent: ?entity_module.Entity, node_type: components.NodeType, default_name: []const u8) ?entity_module.Entity {
    var opts = node_factory.CreateNodeOptions{};
    if (node_type == .Skybox and state.runtime.skybox_path != null) {
        opts.skybox_path = std.mem.span(state.runtime.skybox_path.?.ptr);
    }
    return node_factory.create_node(state.runtime.registry, parent, node_type, default_name, opts) catch null;
}

fn draw_create_node_popup(state: *EditorState) void {
    if (!c.imgui_bridge_begin_popup("create_node_popup", 0)) return;
    defer c.imgui_bridge_end_popup();

    if (c.imgui_bridge_is_window_appearing()) {
        c.imgui_bridge_set_keyboard_focus_here(0);
    }

    _ = c.imgui_bridge_input_text_with_hint("##create_node_search", "Search nodes...", @ptrCast(&state.runtime.create_node_search), state.runtime.create_node_search.len);
    c.imgui_bridge_separator();

    _ = c.imgui_bridge_begin_child("##create_node_list", 420, 260, true, 0);
    defer c.imgui_bridge_end_child();

    const query_len = std.mem.indexOfScalar(u8, &state.runtime.create_node_search, 0) orelse state.runtime.create_node_search.len;
    const query = state.runtime.create_node_search[0..query_len];

    for (node_entries) |entry| {
        if (query.len != 0) {
            if (std.ascii.indexOfIgnoreCase(entry.label, query) == null) continue;
        }

        var buf: [256]u8 = undefined;
        const label_z = std.fmt.bufPrintZ(&buf, "{s}", .{entry.label}) catch continue;
        if (c.imgui_bridge_selectable(label_z.ptr, false, 0)) {
            const name_str = base_label(entry.label);
            if (create_entity(state, state.runtime.create_node_parent, entry.node_type, name_str)) |created| {
                state.ui.selected_entity = created;
            }
            @memset(&state.runtime.create_node_search, 0);
            state.runtime.create_node_parent = null;
            c.imgui_bridge_close_current_popup();
            break;
        }
    }
}

fn unlink_entity_from_parent(state: *EditorState, entity: entity_module.Entity) void {
    const hierarchy_ptr = state.runtime.registry.get(components.Hierarchy, entity) orelse return;
    var hierarchy = hierarchy_ptr.*;

    const parent = hierarchy.parent orelse {
        hierarchy.prev_sibling = null;
        hierarchy.next_sibling = null;
        state.runtime.registry.add(entity, hierarchy) catch {};
        return;
    };

    const parent_h_ptr = state.runtime.registry.get(components.Hierarchy, parent) orelse {
        hierarchy.parent = null;
        hierarchy.prev_sibling = null;
        hierarchy.next_sibling = null;
        state.runtime.registry.add(entity, hierarchy) catch {};
        return;
    };
    var parent_h = parent_h_ptr.*;

    if (parent_h.first_child) |fc| {
        if (fc.id == entity.id) {
            parent_h.first_child = hierarchy.next_sibling;
        }
    }

    if (hierarchy.prev_sibling) |prev| {
        if (state.runtime.registry.get(components.Hierarchy, prev)) |prev_h_ptr| {
            var prev_h = prev_h_ptr.*;
            prev_h.next_sibling = hierarchy.next_sibling;
            state.runtime.registry.add(prev, prev_h) catch {};
        }
    }

    if (hierarchy.next_sibling) |next| {
        if (state.runtime.registry.get(components.Hierarchy, next)) |next_h_ptr| {
            var next_h = next_h_ptr.*;
            next_h.prev_sibling = hierarchy.prev_sibling;
            state.runtime.registry.add(next, next_h) catch {};
        }
    }

    if (parent_h.child_count > 0) parent_h.child_count -= 1;
    state.runtime.registry.add(parent, parent_h) catch {};

    hierarchy.parent = null;
    hierarchy.prev_sibling = null;
    hierarchy.next_sibling = null;
    state.runtime.registry.add(entity, hierarchy) catch {};
}

fn destroy_entity_recursive(state: *EditorState, entity: entity_module.Entity, depth: u32) void {
    if (depth > 2048) return;

    if (state.ui.selected_entity.id == entity.id) {
        state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
    }
    if (state.ui.renaming_entity.id == entity.id) {
        state.ui.renaming_entity = .{ .id = std.math.maxInt(u64) };
    }

    if (state.runtime.registry.get(components.Hierarchy, entity)) |h_ptr| {
        const h = h_ptr.*;
        var child = h.first_child;
        var loop_guard: u32 = 0;
        while (child) |c_ent| {
            if (loop_guard > 100000) break;
            loop_guard += 1;

            const next = if (state.runtime.registry.get(components.Hierarchy, c_ent)) |ch| ch.next_sibling else null;
            destroy_entity_recursive(state, c_ent, depth + 1);
            child = next;
        }
    }

    state.runtime.registry.destroy(entity);
}

fn build_focus_open_chain(state: *EditorState, entity: entity_module.Entity) void {
    state.ui.scene_graph_open_chain_len = 0;
    var current: ?entity_module.Entity = entity;
    var guard: u32 = 0;
    while (current) |e| {
        if (guard > 256) break;
        guard += 1;

        if (state.ui.scene_graph_open_chain_len < state.ui.scene_graph_open_chain.len) {
            state.ui.scene_graph_open_chain[state.ui.scene_graph_open_chain_len] = e.id;
            state.ui.scene_graph_open_chain_len += 1;
        }

        if (state.runtime.registry.get(components.Hierarchy, e)) |h| {
            current = h.parent;
        } else {
            current = null;
        }
    }
}

fn focus_chain_contains(state: *EditorState, entity_id: u64) bool {
    var i: u8 = 0;
    while (i < state.ui.scene_graph_open_chain_len) : (i += 1) {
        if (state.ui.scene_graph_open_chain[i] == entity_id) return true;
    }
    return false;
}

/// Draws one ECS entity node and recurses through its children.
fn draw_entity_node(state: *EditorState, entity: entity_module.Entity, depth: u32) void {
    if (depth > 100) return;

    const hierarchy = state.runtime.registry.get(components.Hierarchy, entity);
    if (hierarchy == null) return;

    var name_buf: [256]u8 = undefined;
    var name: []const u8 = "Entity";
    if (state.runtime.registry.get(components.Name, entity)) |n| {
        name = n.slice();
    }

    var prefix: []const u8 = "";
    if (state.runtime.registry.get(components.Node, entity)) |node_comp| {
        prefix = node_prefix(node_comp.type);
    }

    var flags: i32 = c.ImGuiTreeNodeFlags_OpenOnArrow | c.ImGuiTreeNodeFlags_SpanAvailWidth;
    if (state.ui.selected_entity.id == entity.id) {
        flags |= c.ImGuiTreeNodeFlags_Selected;
    }

    if (hierarchy.?.first_child == null) {
        flags |= c.ImGuiTreeNodeFlags_Leaf;
    }

    var open: bool = false;

    if (state.ui.renaming_entity.id == entity.id) {
        const id_label = std.fmt.bufPrintZ(&name_buf, "##{d}", .{entity.id}) catch "##";
        if (state.ui.scene_graph_focus_pending and focus_chain_contains(state, entity.id)) {
            c.imgui_bridge_set_next_item_open(true, c.ImGuiCond_Once);
        }
        open = c.imgui_bridge_tree_node_ex(id_label.ptr, flags | c.ImGuiTreeNodeFlags_AllowItemOverlap);

        c.imgui_bridge_same_line(0, 0);
        c.imgui_bridge_push_item_width(-1);

        if (state.ui.renaming_entity.id == entity.id and c.imgui_bridge_is_window_focused(0) and !c.imgui_bridge_is_any_item_active()) {
            c.imgui_bridge_set_keyboard_focus_here(0);
        }

        if (c.imgui_bridge_input_text("##Rename", @ptrCast(&state.ui.rename_buffer), state.ui.rename_buffer.len, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_AutoSelectAll)) {
            const new_len = std.mem.indexOfScalar(u8, &state.ui.rename_buffer, 0) orelse state.ui.rename_buffer.len;
            const new_name = state.ui.rename_buffer[0..new_len];
            if (new_len > 0) {
                state.runtime.registry.add(entity, components.Name.init(new_name)) catch {};
            }
            state.ui.renaming_entity.id = std.math.maxInt(u64);
        }
        c.imgui_bridge_pop_item_width();

        if (!c.imgui_bridge_is_item_active() and (c.imgui_bridge_is_mouse_clicked(0) or c.imgui_bridge_is_key_pressed(c.ImGuiKey_Escape))) {
            state.ui.renaming_entity.id = std.math.maxInt(u64);
        }
    } else {
        const label = std.fmt.bufPrintZ(&name_buf, "{s}{s}##{d}", .{ prefix, name, entity.id }) catch "Entity";
        if (state.ui.scene_graph_focus_pending and focus_chain_contains(state, entity.id)) {
            c.imgui_bridge_set_next_item_open(true, c.ImGuiCond_Once);
        }
        open = c.imgui_bridge_tree_node_ex(label.ptr, flags);

        if (c.imgui_bridge_is_item_clicked(0)) {
            state.ui.selected_entity = entity;
        }
    }

    if (state.ui.scene_graph_focus_pending and state.ui.scene_graph_focus_target_id == entity.id) {
        c.imgui_bridge_set_scroll_here_y(0.5);
        state.ui.scene_graph_focus_pending = false;
        state.ui.scene_graph_open_chain_len = 0;
        state.ui.scene_graph_focus_target_id = std.math.maxInt(u64);
    }

    if (c.imgui_bridge_begin_popup_context_item()) {
        if (c.imgui_bridge_menu_item("Create...", null, false, true)) {
            open_create_node_popup(state, entity);
        }

        if (c.imgui_bridge_menu_item("Rename", null, false, true)) {
            state.ui.renaming_entity = entity;
            @memset(&state.ui.rename_buffer, 0);
            const len = @min(name.len, 255);
            @memcpy(state.ui.rename_buffer[0..len], name[0..len]);
        }

        if (c.imgui_bridge_menu_item("Delete", null, false, true)) {
            unlink_entity_from_parent(state, entity);
            destroy_entity_recursive(state, entity, 0);
        }
        c.imgui_bridge_end_popup();
    }

    if (c.imgui_bridge_begin_drag_drop_target()) {
        if (c.imgui_bridge_accept_drag_drop_payload("ASSET_MODEL", 0)) |payload| {
            const data_ptr = c.imgui_bridge_payload_get_data(payload);
            const data_size = c.imgui_bridge_payload_get_data_size(payload);
            const data = @as([*]const u8, @ptrCast(data_ptr));
            const len = @as(usize, @intCast(data_size));
            const path = data[0..len];

            scene_io.load_model_to_entity(state, path, entity);
        }
        c.imgui_bridge_end_drag_drop_target();
    }

    if (open) {
        var child = hierarchy.?.first_child;
        var loop_guard: u32 = 0;
        while (child) |c_ent| {
            if (loop_guard > 1000) break;
            loop_guard += 1;

            draw_entity_node(state, c_ent, depth + 1);
            if (state.runtime.registry.get(components.Hierarchy, c_ent)) |h| {
                child = h.next_sibling;
            } else {
                child = null;
            }
        }
        c.imgui_bridge_tree_pop();
    }
}

/// Draws a debug tree view of an engine-loaded `CardinalSceneNode`.
fn draw_scene_node(state: *EditorState, scene_ptr: *scene.CardinalScene, node: *scene.CardinalSceneNode, depth: i32) void {
    var node_id_buf: [256]u8 = undefined;
    const node_name = if (node.name) |n| std.mem.span(n) else "Unnamed Node";
    const node_id = std.fmt.bufPrintZ(&node_id_buf, "{s}##{*}", .{ node_name, node }) catch "Node";

    const node_open = c.imgui_bridge_tree_node(node_id.ptr);

    c.imgui_bridge_same_line(0, -1);
    c.imgui_bridge_text_disabled("(meshes: %d, children: %d)", node.mesh_count, node.child_count);

    if (node_open) {
        if (c.imgui_bridge_tree_node("Transform")) {
            c.imgui_bridge_text("Local Transform:");
            c.imgui_bridge_text("  Translation: (%.2f, %.2f, %.2f)", node.local_transform[12], node.local_transform[13], node.local_transform[14]);

            c.imgui_bridge_text("World Transform:");
            c.imgui_bridge_text("  Translation: (%.2f, %.2f, %.2f)", node.world_transform[12], node.world_transform[13], node.world_transform[14]);
            c.imgui_bridge_tree_pop();
        }

        if (node.mesh_count > 0 and c.imgui_bridge_tree_node("Meshes")) {
            var i: u32 = 0;
            while (i < node.mesh_count) : (i += 1) {
                if (node.mesh_indices) |indices| {
                    const mesh_idx = indices[i];
                    if (mesh_idx < scene_ptr.mesh_count) {
                        if (scene_ptr.meshes) |meshes| {
                            const m = &meshes[mesh_idx];

                            var cb_id: [64]u8 = undefined;
                            const cb_id_z = std.fmt.bufPrintZ(&cb_id, "Visible##mesh_{d}", .{mesh_idx}) catch "Visible";

                            _ = c.imgui_bridge_checkbox(cb_id_z.ptr, &m.visible);
                            c.imgui_bridge_same_line(0, -1);
                            c.imgui_bridge_bullet_text("Mesh %d: %d vertices, %d indices", mesh_idx, m.vertex_count, m.index_count);
                        }
                    }
                }
            }
            c.imgui_bridge_tree_pop();
        }

        var i: u32 = 0;
        while (i < node.child_count) : (i += 1) {
            if (node.children) |children| {
                if (children[i]) |child| {
                    draw_scene_node(state, scene_ptr, child, depth + 1);
                }
            }
        }

        c.imgui_bridge_tree_pop();
    }
}

/// Draws the Scene Graph panel (ECS tree + optional combined-scene debug view).
pub fn draw_hierarchy_panel(state: *EditorState) void {
    if (state.ui.show_scene_graph) {
        const open = c.imgui_bridge_begin("Scene Graph", &state.ui.show_scene_graph, 0);
        defer c.imgui_bridge_end();

        if (open) {
            if (state.ui.scene_graph_focus_pending and state.ui.selected_entity.id != std.math.maxInt(u64)) {
                build_focus_open_chain(state, state.ui.selected_entity);
            }

            if (c.imgui_bridge_button("Create Node +")) {
                open_create_node_popup(state, null);
            }
            draw_create_node_popup(state);

            c.imgui_bridge_separator();

            if (state.ui.scene_graph_focus_pending) {
                c.imgui_bridge_set_next_item_open(true, c.ImGuiCond_Once);
            }
            if (c.imgui_bridge_tree_node_ex("Scene", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                c.imgui_bridge_bullet_text("Camera");
                c.imgui_bridge_bullet_text("Directional Light");

                var it = state.runtime.registry.view(components.Hierarchy).iterator();
                while (it.next()) |entry| {
                    const entity = entry.entity;
                    if (state.runtime.registry.get(components.Hierarchy, entity)) |h| {
                        if (h.parent == null or h.parent.?.id == std.math.maxInt(u64)) {
                            draw_entity_node(state, entity, 0);
                        }
                    }
                }

                c.imgui_bridge_tree_pop();
            }

            if (state.runtime.scene_loaded) {
                if (c.imgui_bridge_tree_node("Combined Scene (Debug)")) {
                    c.imgui_bridge_text("Total Meshes: %d", state.runtime.combined_scene.mesh_count);
                    c.imgui_bridge_text("Root Nodes: %d", state.runtime.combined_scene.root_node_count);

                    c.imgui_bridge_separator();
                    c.imgui_bridge_text("Bulk Visibility Controls:");

                    if (c.imgui_bridge_button("Show All Meshes")) {
                        var i: u32 = 0;
                        while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                meshes[i].visible = true;
                            }
                        }
                    }
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Hide All Meshes")) {
                        var i: u32 = 0;
                        while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                meshes[i].visible = false;
                            }
                        }
                    }

                    if (c.imgui_bridge_button("Show Only Material 0")) {
                        var i: u32 = 0;
                        while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                meshes[i].visible = (meshes[i].material_index == 0);
                            }
                        }
                    }
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Show Only Material 1")) {
                        var i: u32 = 0;
                        while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                meshes[i].visible = (meshes[i].material_index == 1);
                            }
                        }
                    }

                    if (c.imgui_bridge_button("Toggle Materials 0/1")) {
                        var i: u32 = 0;
                        while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                if (meshes[i].material_index == 0) {
                                    meshes[i].visible = state.ui.show_material_0_toggle;
                                } else if (meshes[i].material_index == 1) {
                                    meshes[i].visible = !state.ui.show_material_0_toggle;
                                }
                            }
                        }
                        state.ui.show_material_0_toggle = !state.ui.show_material_0_toggle;
                    }

                    if (state.runtime.combined_scene.root_node_count > 0) {
                        c.imgui_bridge_separator();
                        var i: u32 = 0;
                        while (i < state.runtime.combined_scene.root_node_count) : (i += 1) {
                            if (state.runtime.combined_scene.root_nodes) |root_nodes| {
                                if (root_nodes[i]) |root| {
                                    draw_scene_node(state, &state.runtime.combined_scene, root, 0);
                                }
                            }
                        }
                    } else {
                        c.imgui_bridge_text("No scene hierarchy - showing flat mesh list:");
                        var i: u32 = 0;
                        while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                const m = &meshes[i];
                                var cb_id: [64]u8 = undefined;
                                const cb_id_z = std.fmt.bufPrintZ(&cb_id, "Visible##flat_mesh_{d}", .{i}) catch "Visible";
                                _ = c.imgui_bridge_checkbox(cb_id_z.ptr, &m.visible);
                                c.imgui_bridge_same_line(0, -1);
                                c.imgui_bridge_bullet_text("Mesh %d: %d vertices, %d indices", i, m.vertex_count, m.index_count);
                            }
                        }
                    }
                    c.imgui_bridge_tree_pop();
                }
            }
        }
    }
}
