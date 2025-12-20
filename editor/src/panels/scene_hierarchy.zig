const std = @import("std");
const engine = @import("cardinal_engine");
const scene = engine.scene;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;

fn draw_scene_node(state: *EditorState, node: *scene.CardinalSceneNode, depth: i32) void {
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
                    if (mesh_idx < state.combined_scene.mesh_count) {
                        if (state.combined_scene.meshes) |meshes| {
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
                    draw_scene_node(state, child, depth + 1);
                }
            }
        }

        c.imgui_bridge_tree_pop();
    }
}

pub fn draw_scene_graph_panel(state: *EditorState) void {
    if (state.show_scene_graph) {
        const open = c.imgui_bridge_begin("Scene Graph", &state.show_scene_graph, 0);
        defer c.imgui_bridge_end();
        
        if (open) {
            if (c.imgui_bridge_tree_node("Scene")) {
                c.imgui_bridge_bullet_text("Camera");
                c.imgui_bridge_bullet_text("Directional Light");

                if (state.scene_loaded) {
                    if (c.imgui_bridge_tree_node("Loaded Scene")) {
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
                                        draw_scene_node(state, root, 0);
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
                c.imgui_bridge_tree_pop();
            }
        }
    }
}
