const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const scene = engine.scene;
const model_manager = engine.model_manager;
const animation = engine.animation;
const components = engine.ecs_components;
const entity_module = engine.ecs_entity;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;
const scene_io = @import("../systems/scene_io.zig");

fn draw_entity_node(state: *EditorState, entity: entity_module.Entity, depth: u32) void {
    if (depth > 100) return; // Prevent infinite recursion

    const hierarchy = state.registry.get(components.Hierarchy, entity);
    if (hierarchy == null) return;

    var name_buf: [256]u8 = undefined;
    var name: []const u8 = "Entity";
    if (state.registry.get(components.Name, entity)) |n| {
        name = n.slice();
    }

    // Determine Prefix
    var prefix: []const u8 = "";
    if (state.registry.get(components.Node, entity)) |node_comp| {
        switch (node_comp.type) {
            .Node3D => prefix = "[3D] ",
            .Node2D => prefix = "[2D] ",
            .NodeUI => prefix = "[UI] ",
        }
    }

    var flags: i32 = c.ImGuiTreeNodeFlags_OpenOnArrow | c.ImGuiTreeNodeFlags_SpanAvailWidth;
    if (state.selected_entity.id == entity.id) {
        flags |= c.ImGuiTreeNodeFlags_Selected;
    }

    // If no children, make it a leaf
    if (hierarchy.?.first_child == null) {
        flags |= c.ImGuiTreeNodeFlags_Leaf;
    }

    var open: bool = false;

    if (state.renaming_entity.id == entity.id) {
        // Renaming mode: Use ID as label for tree node to maintain structure, but render input text
        const id_label = std.fmt.bufPrintZ(&name_buf, "##{d}", .{entity.id}) catch "##";
        open = c.imgui_bridge_tree_node_ex(id_label.ptr, flags | c.ImGuiTreeNodeFlags_AllowItemOverlap);

        c.imgui_bridge_same_line(0, 0);
        c.imgui_bridge_push_item_width(-1);

        // Auto-focus logic handled by ImGui usually, but we can enforce it
        if (state.renaming_entity.id == entity.id and c.imgui_bridge_is_window_focused(0) and !c.imgui_bridge_is_any_item_active()) {
            c.imgui_bridge_set_keyboard_focus_here(0);
        }

        if (c.imgui_bridge_input_text("##Rename", @ptrCast(&state.rename_buffer), state.rename_buffer.len, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_AutoSelectAll)) {
            const new_len = std.mem.indexOfScalar(u8, &state.rename_buffer, 0) orelse state.rename_buffer.len;
            const new_name = state.rename_buffer[0..new_len];
            if (new_len > 0) {
                state.registry.add(entity, components.Name.init(new_name)) catch {};
            }
            state.renaming_entity.id = std.math.maxInt(u64);
        }
        c.imgui_bridge_pop_item_width();

        // Check if we clicked outside or pressed escape
        if (!c.imgui_bridge_is_item_active() and (c.imgui_bridge_is_mouse_clicked(0) or c.imgui_bridge_is_key_pressed(c.ImGuiKey_Escape))) {
            state.renaming_entity.id = std.math.maxInt(u64);
        }
    } else {
        const label = std.fmt.bufPrintZ(&name_buf, "{s}{s}##{d}", .{ prefix, name, entity.id }) catch "Entity";
        open = c.imgui_bridge_tree_node_ex(label.ptr, flags);

        if (c.imgui_bridge_is_item_clicked(0)) {
            state.selected_entity = entity;
        }
    }

    // Context Menu
    if (c.imgui_bridge_begin_popup_context_item()) {
        if (c.imgui_bridge_begin_menu("Create Node", true)) {
            if (c.imgui_bridge_menu_item("Node3D", null, false, true)) {
                create_entity(state, entity, .Node3D);
            }
            if (c.imgui_bridge_menu_item("Node2D", null, false, true)) {
                create_entity(state, entity, .Node2D);
            }
            c.imgui_bridge_end_menu();
        }

        if (c.imgui_bridge_menu_item("Rename", null, false, true)) {
            state.renaming_entity = entity;
            @memset(&state.rename_buffer, 0);
            const len = @min(name.len, 255);
            @memcpy(state.rename_buffer[0..len], name[0..len]);
        }

        if (c.imgui_bridge_menu_item("Delete", null, false, true)) {
            // Basic unlink logic (incomplete, but better than nothing for now)
            // TODO: Implement proper recursive deletion and unlink

            // Just destroy for now
            state.registry.destroy(entity);
            if (state.selected_entity.id == entity.id) {
                state.selected_entity = .{ .id = std.math.maxInt(u64) };
            }
        }
        c.imgui_bridge_end_popup();
    }

    // Drag & Drop Target
    if (c.imgui_bridge_begin_drag_drop_target()) {
        if (c.imgui_bridge_accept_drag_drop_payload("ASSET_MODEL", 0)) |payload| {
            const data_ptr = c.imgui_bridge_payload_get_data(payload);
            const data_size = c.imgui_bridge_payload_get_data_size(payload);
            const data = @as([*]const u8, @ptrCast(data_ptr));
            const len = @as(usize, @intCast(data_size));
            const path = data[0..len];

            // Trigger load and attach to this entity
            // We need a function in scene_io for this
            scene_io.load_model_to_entity(state, path, entity);
        }
        c.imgui_bridge_end_drag_drop_target();
    }

    if (open) {
        var child = hierarchy.?.first_child;
        var loop_guard: u32 = 0;
        while (child) |c_ent| {
            if (loop_guard > 1000) break; // Prevent infinite loop in siblings
            loop_guard += 1;

            draw_entity_node(state, c_ent, depth + 1);
            if (state.registry.get(components.Hierarchy, c_ent)) |h| {
                child = h.next_sibling;
            } else {
                child = null;
            }
        }
        c.imgui_bridge_tree_pop();
    }
}

fn create_entity(state: *EditorState, parent: ?entity_module.Entity, node_type: components.NodeType) void {
    const entity = state.registry.create() catch return;

    // Default components
    const name_str = switch (node_type) {
        .Node3D => "Node3D",
        .Node2D => "Node2D",
        .NodeUI => "NodeUI",
    };
    state.registry.add(entity, components.Name.init(name_str)) catch {};
    state.registry.add(entity, components.Transform{}) catch {};
    state.registry.add(entity, components.Node{ .type = node_type }) catch {};

    var h = components.Hierarchy{};
    if (parent) |p| {
        h.parent = p;

        // Link to parent
        if (state.registry.get(components.Hierarchy, p)) |parent_h| {
            var ph = parent_h.*;
            if (ph.first_child) |first| {
                // Find last child
                var last = first;
                while (true) {
                    if (state.registry.get(components.Hierarchy, last)) |lh| {
                        if (lh.next_sibling) |next| {
                            last = next;
                        } else {
                            // Link
                            var last_h = lh.*;
                            last_h.next_sibling = entity;
                            state.registry.add(last, last_h) catch {};
                            h.prev_sibling = last;
                            break;
                        }
                    } else {
                        break;
                    }
                }
            } else {
                ph.first_child = entity;
            }
            ph.child_count += 1;
            state.registry.add(p, ph) catch {};
        } else {
            // Parent has no hierarchy? Add it
            var ph = components.Hierarchy{};
            ph.first_child = entity;
            ph.child_count = 1;
            state.registry.add(p, ph) catch {};
        }
    }
    state.registry.add(entity, h) catch {};
}

fn draw_scene_node(state: *EditorState, scene_ptr: *scene.CardinalScene, node: *scene.CardinalSceneNode, depth: i32) void {
    // Node ID
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

pub fn draw_hierarchy_panel(state: *EditorState) void {
    if (state.show_scene_graph) {
        const open = c.imgui_bridge_begin("Scene Graph", &state.show_scene_graph, 0);
        defer c.imgui_bridge_end();

        if (open) {
            if (c.imgui_bridge_button("Create Node +")) {
                c.imgui_bridge_open_popup("create_node_popup");
            }

            if (c.imgui_bridge_begin_popup("create_node_popup", 0)) {
                if (c.imgui_bridge_menu_item("Node3D", null, false, true)) {
                    create_entity(state, null, .Node3D);
                }
                if (c.imgui_bridge_menu_item("Node2D", null, false, true)) {
                    create_entity(state, null, .Node2D);
                }
                c.imgui_bridge_end_popup();
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_tree_node("Scene")) {
                c.imgui_bridge_bullet_text("Camera");
                c.imgui_bridge_bullet_text("Directional Light");

                // ECS Hierarchy
                var it = state.registry.view(components.Hierarchy).iterator();
                while (it.next()) |entry| {
                    const entity = entry.entity;
                    if (state.registry.get(components.Hierarchy, entity)) |h| {
                        // If parent is invalid (maxInt), it's a root
                        if (h.parent == null or h.parent.?.id == std.math.maxInt(u64)) {
                            draw_entity_node(state, entity, 0);
                        }
                    }
                }

                c.imgui_bridge_tree_pop();
            }

            // Legacy/Debug Views
            if (state.scene_loaded) {
                if (c.imgui_bridge_tree_node("Combined Scene (Debug)")) {
                    c.imgui_bridge_text("Total Meshes: %d", state.combined_scene.mesh_count);
                    c.imgui_bridge_text("Root Nodes: %d", state.combined_scene.root_node_count);

                    c.imgui_bridge_separator();
                    c.imgui_bridge_text("Bulk Visibility Controls:");

                    if (c.imgui_bridge_button("Show All Meshes")) {
                        var i: u32 = 0;
                        while (i < state.combined_scene.mesh_count) : (i += 1) {
                            if (state.combined_scene.meshes) |meshes| {
                                meshes[i].visible = true;
                            }
                        }
                    }
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Hide All Meshes")) {
                        var i: u32 = 0;
                        while (i < state.combined_scene.mesh_count) : (i += 1) {
                            if (state.combined_scene.meshes) |meshes| {
                                meshes[i].visible = false;
                            }
                        }
                    }

                    // Material-based visibility controls
                    if (c.imgui_bridge_button("Show Only Material 0")) {
                        var i: u32 = 0;
                        while (i < state.combined_scene.mesh_count) : (i += 1) {
                            if (state.combined_scene.meshes) |meshes| {
                                meshes[i].visible = (meshes[i].material_index == 0);
                            }
                        }
                    }
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Show Only Material 1")) {
                        var i: u32 = 0;
                        while (i < state.combined_scene.mesh_count) : (i += 1) {
                            if (state.combined_scene.meshes) |meshes| {
                                meshes[i].visible = (meshes[i].material_index == 1);
                            }
                        }
                    }

                    if (c.imgui_bridge_button("Toggle Materials 0/1")) {
                        var i: u32 = 0;
                        while (i < state.combined_scene.mesh_count) : (i += 1) {
                            if (state.combined_scene.meshes) |meshes| {
                                if (meshes[i].material_index == 0) {
                                    meshes[i].visible = state.show_material_0_toggle;
                                } else if (meshes[i].material_index == 1) {
                                    meshes[i].visible = !state.show_material_0_toggle;
                                }
                            }
                        }
                        state.show_material_0_toggle = !state.show_material_0_toggle;
                    }

                    if (state.combined_scene.root_node_count > 0) {
                        c.imgui_bridge_separator();
                        var i: u32 = 0;
                        while (i < state.combined_scene.root_node_count) : (i += 1) {
                            if (state.combined_scene.root_nodes) |root_nodes| {
                                if (root_nodes[i]) |root| {
                                    draw_scene_node(state, &state.combined_scene, root, 0);
                                }
                            }
                        }
                    } else {
                        c.imgui_bridge_text("No scene hierarchy - showing flat mesh list:");
                        var i: u32 = 0;
                        while (i < state.combined_scene.mesh_count) : (i += 1) {
                            if (state.combined_scene.meshes) |meshes| {
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
