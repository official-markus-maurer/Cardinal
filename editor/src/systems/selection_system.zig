//! Editor selection orchestration.
//!
//! This module intentionally stays small and delegates to specialized systems:
//! - `selection_raycast` for picking and selection helpers
//! - `gizmo_system` for manipulation widgets
const std = @import("std");
const engine = @import("cardinal_engine");
const components = engine.ecs_components;
const EditorState = @import("../editor_state.zig").EditorState;
const c = @import("../c.zig").c;
const gizmo_system = @import("gizmo_system.zig");
const selection_raycast = @import("selection_raycast.zig");

pub const GizmoMode = gizmo_system.GizmoMode;

/// Clears cached data used by picking.
pub fn reset_picking_cache() void {
    selection_raycast.reset_picking_cache();
}

/// Frames `root` in the scene view based on its computed bounds.
pub fn frame_entity_in_scene_view(state: *EditorState, root: engine.ecs_entity.Entity) void {
    selection_raycast.frame_entity_in_scene_view(state, root);
}

/// Updates selection and gizmo interaction for the current frame.
pub fn update(state: *EditorState) void {
    gizmo_system.pre_update(state);

    const want_capture = c.imgui_bridge_want_capture_mouse();
    if (!state.runtime.mouse_captured and c.imgui_bridge_is_mouse_clicked(0) and !want_capture and gizmo_system.allow_scene_pick()) {
        selection_raycast.pick_under_mouse(state);
    }

    if (state.ui.selected_entity.id != std.math.maxInt(u64)) {
        selection_raycast.draw_selection_xray(state, state.ui.selected_entity);
        if (state.runtime.registry.get(components.Transform, state.ui.selected_entity)) |t| {
            gizmo_system.draw_entity_gizmo(state, t);
            return;
        }
    }

    state.ui.selected_model_id = 0;
}
