const std = @import("std");
const engine = @import("cardinal_engine");
const model_manager = engine.model_manager;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;

pub fn draw_inspector_panel(state: *EditorState) void {
    if (state.show_model_manager) {
        const open = c.imgui_bridge_begin("Model Manager", &state.show_model_manager, 0);
        defer c.imgui_bridge_end();
        
        if (open) {
            c.imgui_bridge_text("Loaded Models:");
            c.imgui_bridge_separator();

            const model_count = state.model_manager.model_count;
            if (model_count == 0) {
                c.imgui_bridge_text("No models loaded");
                c.imgui_bridge_text_wrapped("Load models from the Assets panel to see them here.");
            } else {
                const child_visible = c.imgui_bridge_begin_child("##model_list", 0, 300, true, 0);
                defer c.imgui_bridge_end_child();
                
                if (child_visible) {
                    var i: u32 = 0;
                    while (i < state.model_manager.model_count) {
                        const model_ptr = model_manager.cardinal_model_manager_get_model_by_index(&state.model_manager, i);
                        if (model_ptr) |model| {
                            c.imgui_bridge_push_id_int(@intCast(model.id));

                            const is_selected = (state.selected_model_id == model.id);
                            const name = if (model.name) |n| std.mem.span(n) else "Unnamed Model";

                            const avail_w = c.imgui_bridge_get_content_region_avail_x();
                            const controls_w: f32 = 120.0; // Checkbox + Remove button + Spacing
                            const label_w = if (avail_w > controls_w) avail_w - controls_w else 10.0;

                            if (c.imgui_bridge_selectable_size(name.ptr, is_selected, 0, label_w, 0)) {
                                state.selected_model_id = model.id;
                                model_manager.cardinal_model_manager_set_selected(&state.model_manager, model.id);
                            }

                            c.imgui_bridge_same_line(0, -1);

                            var visible = model.visible;
                            if (c.imgui_bridge_checkbox("##visible", &visible)) {
                                _ = model_manager.cardinal_model_manager_set_visible(&state.model_manager, model.id, visible);
                            }
                            if (c.imgui_bridge_is_item_hovered(0)) {
                                c.imgui_bridge_set_tooltip("Toggle visibility");
                            }

                            c.imgui_bridge_same_line(0, -1);
                            if (c.imgui_bridge_button("Remove")) {
                                _ = model_manager.cardinal_model_manager_remove_model(&state.model_manager, model.id);
                                if (state.selected_model_id == model.id) {
                                    state.selected_model_id = 0;
                                }
                                c.imgui_bridge_pop_id();
                                continue;
                            }

                            if (is_selected) {
                                c.imgui_bridge_indent(10.0);
                                c.imgui_bridge_text("ID: %d", model.id);
                                c.imgui_bridge_text("Meshes: %d", model.scene.mesh_count);
                                c.imgui_bridge_text("Materials: %d", model.scene.material_count);
                                if (model.file_path) |fp| {
                                    c.imgui_bridge_text("Path: %s", fp);
                                }

                                c.imgui_bridge_separator();
                                c.imgui_bridge_text("Transform:");

                                var pos = [3]f32{ model.transform[12], model.transform[13], model.transform[14] };
                                if (c.imgui_bridge_drag_float3("Position", &pos, 0.1, 0.0, 0.0, "%.3f", 0)) {
                                    var new_transform: [16]f32 = undefined;
                                    @memcpy(&new_transform, &model.transform);
                                    new_transform[12] = pos[0];
                                    new_transform[13] = pos[1];
                                    new_transform[14] = pos[2];
                                    _ = model_manager.cardinal_model_manager_set_transform(&state.model_manager, model.id, &new_transform);
                                }

                                // Simplified scale
                                const current_scale = std.math.sqrt(model.transform[0] * model.transform[0] + model.transform[1] * model.transform[1] + model.transform[2] * model.transform[2]);
                                var scale = current_scale;
                                if (c.imgui_bridge_drag_float("Scale", &scale, 0.01, 0.01, 10.0, "%.3f", 0)) {
                                    var scale_matrix: [16]f32 = undefined;
                                    @memset(&scale_matrix, 0);
                                    scale_matrix[0] = scale;
                                    scale_matrix[5] = scale;
                                    scale_matrix[10] = scale;
                                    scale_matrix[15] = 1.0;
                                    scale_matrix[12] = pos[0];
                                    scale_matrix[13] = pos[1];
                                    scale_matrix[14] = pos[2];
                                    _ = model_manager.cardinal_model_manager_set_transform(&state.model_manager, model.id, &scale_matrix);
                                }

                                c.imgui_bridge_unindent(10.0);
                            }

                            c.imgui_bridge_pop_id();
                        }
                        i += 1;
                    }
                }
            }
        }
    }
}
