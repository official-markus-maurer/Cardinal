//! Scene hierarchy panel.
//!
//! Renders the entity hierarchy tree view and supports selection, rename, and basic creation.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const scene = engine.scene;
const animation = engine.animation;
const renderer = engine.vulkan_renderer;
const components = engine.ecs_components;
const entity_module = engine.ecs_entity;
const node_factory = engine.ecs_node_factory;
const c = @import("../c.zig").c;
const EditorState = @import("../editor_state.zig").EditorState;
const editor_state = @import("../editor_state.zig");
const scene_io = @import("../systems/scene_io.zig");
const hierarchy_system = @import("../systems/hierarchy_system.zig");
const scene_sync = @import("../systems/editor_scene_sync.zig");
const selection_system = @import("../systems/selection_system.zig");

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
    .{ .label = "Environment/Skybox", .node_type = .Skybox },

    .{ .label = "2D/Camera2D", .node_type = .Camera2D },
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

fn capture_append_hierarchy(state: *EditorState, parent: entity_module.Entity) struct { ids: [6]u64, hier: [6]components.Hierarchy, count: u8 } {
    var ids: [6]u64 = [_]u64{0} ** 6;
    var hier: [6]components.Hierarchy = undefined;
    var count: u8 = 0;

    ids[count] = parent.id;
    count += 1;

    const parent_h = ensure_hierarchy(state, parent);
    if (parent_h.last_child) |lc| {
        ids[count] = lc.id;
        count += 1;
    } else if (parent_h.first_child) |fc| {
        var last = fc;
        var guard: u32 = 0;
        while (guard < 100000) : (guard += 1) {
            const lh = state.runtime.registry.get(components.Hierarchy, last) orelse break;
            if (lh.next_sibling) |nx| {
                last = nx;
            } else {
                break;
            }
        }
        ids[count] = last.id;
        count += 1;
    }

    var i: u8 = 0;
    while (i < count) : (i += 1) {
        hier[i] = ensure_hierarchy(state, .{ .id = ids[i] });
    }

    return .{ .ids = ids, .hier = hier, .count = count };
}

fn create_entity(state: *EditorState, parent: ?entity_module.Entity, node_type: components.NodeType, default_name: []const u8) ?entity_module.Entity {
    var opts = node_factory.CreateNodeOptions{};
    if (node_type == .Skybox and state.runtime.skybox_path != null) {
        opts.skybox_path = std.mem.span(state.runtime.skybox_path.?.ptr);
    }

    var before_ids: [6]u64 = [_]u64{0} ** 6;
    var before_h: [6]components.Hierarchy = undefined;
    var before_count: u8 = 0;
    if (parent) |p| {
        const pack = capture_append_hierarchy(state, p);
        before_ids = pack.ids;
        before_h = pack.hier;
        before_count = pack.count;
    }

    const created = node_factory.create_node(state.runtime.registry, parent, node_type, default_name, opts) catch null;
    if (created == null) return null;

    var after_h: [6]components.Hierarchy = undefined;
    var i: u8 = 0;
    while (i < before_count) : (i += 1) {
        after_h[i] = ensure_hierarchy(state, .{ .id = before_ids[i] });
    }

    state.ui.undo.push_entity_subtree(state.runtime.registry, created.?, .Create, before_ids[0..before_count], before_h[0..before_count], after_h[0..before_count]);
    return created;
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
                state.ui.scene_graph_focus_target_id = created.id;
                state.ui.scene_graph_focus_pending = true;
            }
            @memset(&state.runtime.create_node_search, 0);
            state.runtime.create_node_parent = null;
            c.imgui_bridge_close_current_popup();
            break;
        }
    }
}

fn is_descendant_of(state: *EditorState, maybe_descendant: entity_module.Entity, ancestor: entity_module.Entity) bool {
    var current: ?entity_module.Entity = maybe_descendant;
    var guard: u32 = 0;
    while (current) |e| {
        if (guard > 2048) break;
        guard += 1;
        if (e.id == ancestor.id) return true;
        const h = state.runtime.registry.get(components.Hierarchy, e) orelse break;
        current = h.parent;
    }
    return false;
}

fn ensure_hierarchy(state: *EditorState, entity: entity_module.Entity) components.Hierarchy {
    if (state.runtime.registry.get(components.Hierarchy, entity)) |h| return h.*;
    state.runtime.registry.add(entity, components.Hierarchy{}) catch {};
    return components.Hierarchy{};
}

fn push_unique_entity(ids: []u64, count: *u8, id: u64) void {
    var i: usize = 0;
    while (i < @as(usize, @intCast(count.*))) : (i += 1) {
        if (ids[i] == id) return;
    }
    const idx: usize = @intCast(count.*);
    if (idx < ids.len) {
        ids[idx] = id;
        count.* += 1;
    }
}

fn capture_reparent_before(state: *EditorState, child: entity_module.Entity, new_parent: entity_module.Entity) struct {
    ids: [6]u64,
    before: [6]components.Hierarchy,
    count: u8,
} {
    var ids: [6]u64 = [_]u64{0} ** 6;
    var before: [6]components.Hierarchy = undefined;
    var count: u8 = 0;

    const child_h = ensure_hierarchy(state, child);
    if (child_h.parent) |p| {
        push_unique_entity(ids[0..], &count, p.id);
    }
    if (child_h.prev_sibling) |p| push_unique_entity(ids[0..], &count, p.id);
    if (child_h.next_sibling) |n| push_unique_entity(ids[0..], &count, n.id);
    push_unique_entity(ids[0..], &count, new_parent.id);

    const new_parent_h = ensure_hierarchy(state, new_parent);
    if (new_parent_h.last_child) |lc| {
        push_unique_entity(ids[0..], &count, lc.id);
    } else if (new_parent_h.first_child) |fc| {
        var last = fc;
        var guard: u32 = 0;
        while (guard < 100000) : (guard += 1) {
            const lh = state.runtime.registry.get(components.Hierarchy, last) orelse break;
            if (lh.next_sibling) |nx| {
                last = nx;
            } else {
                break;
            }
        }
        push_unique_entity(ids[0..], &count, last.id);
    }

    push_unique_entity(ids[0..], &count, child.id);

    var i: u8 = 0;
    while (i < count) : (i += 1) {
        before[i] = ensure_hierarchy(state, .{ .id = ids[i] });
    }

    return .{ .ids = ids, .before = before, .count = count };
}

fn capture_reparent_after(state: *EditorState, ids: [6]u64, count: u8) [6]components.Hierarchy {
    var after: [6]components.Hierarchy = undefined;
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        after[i] = ensure_hierarchy(state, .{ .id = ids[i] });
    }
    return after;
}

fn reparent_entity(state: *EditorState, child: entity_module.Entity, new_parent: entity_module.Entity) void {
    if (child.id == new_parent.id) return;
    if (is_descendant_of(state, new_parent, child)) return;

    const capture = capture_reparent_before(state, child, new_parent);

    hierarchy_system.unlink_entity_from_parent(state, child);
    node_factory.append_child(state.runtime.registry, new_parent, child);

    const after = capture_reparent_after(state, capture.ids, capture.count);
    state.ui.undo.push_entity_reparent(capture.ids[0..capture.count], capture.before[0..capture.count], after[0..capture.count]);
}

fn set_node_type_with_undo(state: *EditorState, entity: entity_module.Entity, new_type: components.NodeType) void {
    const before_ptr = state.runtime.registry.get(components.Node, entity);
    const before_present = before_ptr != null;
    const before = if (before_ptr) |p| p.* else std.mem.zeroes(components.Node);
    var after = if (before_present) before else components.Node{ .type = .Node3D };
    after.type = new_type;
    if (before_present and after.type == before.type) return;
    state.ui.undo.push(.{ .EntityNode = .{
        .entity_id = entity.id,
        .before_present = before_present,
        .after_present = true,
        .before = before,
        .after = after,
    } });
    state.runtime.registry.add(entity, after) catch {};
}

fn reorder_entity_relative_to_sibling(state: *EditorState, dragged: entity_module.Entity, sibling: entity_module.Entity, insert_before: bool) void {
    if (dragged.id == sibling.id) return;
    const dragged_h = ensure_hierarchy(state, dragged);
    const sibling_h = ensure_hierarchy(state, sibling);
    if (dragged_h.parent == null or sibling_h.parent == null) return;
    if (dragged_h.parent.?.id != sibling_h.parent.?.id) return;

    if (insert_before) {
        if (sibling_h.prev_sibling != null and sibling_h.prev_sibling.?.id == dragged.id) return;
    } else {
        if (sibling_h.next_sibling != null and sibling_h.next_sibling.?.id == dragged.id) return;
    }

    const parent = dragged_h.parent.?;
    var ids: [7]u64 = [_]u64{0} ** 7;
    var before: [7]components.Hierarchy = undefined;
    var after: [7]components.Hierarchy = undefined;
    var count: u8 = 0;

    push_unique_entity(ids[0..], &count, parent.id);
    push_unique_entity(ids[0..], &count, dragged.id);
    push_unique_entity(ids[0..], &count, sibling.id);
    if (dragged_h.prev_sibling) |p| push_unique_entity(ids[0..], &count, p.id);
    if (dragged_h.next_sibling) |n| push_unique_entity(ids[0..], &count, n.id);
    if (sibling_h.prev_sibling) |p| push_unique_entity(ids[0..], &count, p.id);
    if (sibling_h.next_sibling) |n| push_unique_entity(ids[0..], &count, n.id);

    var i: u8 = 0;
    while (i < count) : (i += 1) {
        before[i] = ensure_hierarchy(state, .{ .id = ids[i] });
    }

    if (insert_before) {
        hierarchy_system.insert_child_before(state, parent, dragged, sibling);
    } else {
        hierarchy_system.insert_child_after(state, parent, dragged, sibling);
    }

    i = 0;
    while (i < count) : (i += 1) {
        after[i] = ensure_hierarchy(state, .{ .id = ids[i] });
    }

    state.ui.undo.push_entity_reparent(ids[0..count], before[0..count], after[0..count]);
}

fn selected_entity_list(state: *EditorState, alloc: std.mem.Allocator) std.ArrayListUnmanaged(entity_module.Entity) {
    var out: std.ArrayListUnmanaged(entity_module.Entity) = .{};
    var it = state.ui.selected_entities.iterator();
    while (it.next()) |entry| {
        const ent = entity_module.Entity{ .id = entry.key_ptr.* };
        if (!state.runtime.registry.entity_manager.is_alive(ent)) continue;
        if (state.runtime.registry.get(components.EditorGlobals, ent) != null) continue;
        out.append(alloc, ent) catch {};
    }
    if (out.items.len == 0 and state.runtime.registry.entity_manager.is_alive(state.ui.selected_entity) and state.runtime.registry.get(components.EditorGlobals, state.ui.selected_entity) == null) {
        out.append(alloc, state.ui.selected_entity) catch {};
    }
    return out;
}

fn delete_entity_with_undo(state: *EditorState, entity: entity_module.Entity) void {
    var ids: [6]u64 = [_]u64{0} ** 6;
    var before: [6]components.Hierarchy = undefined;
    var count: u8 = 0;

    const h = ensure_hierarchy(state, entity);
    if (h.parent) |p| push_unique_entity(ids[0..], &count, p.id);
    if (h.prev_sibling) |p| push_unique_entity(ids[0..], &count, p.id);
    if (h.next_sibling) |n| push_unique_entity(ids[0..], &count, n.id);

    var i: u8 = 0;
    while (i < count) : (i += 1) {
        before[i] = ensure_hierarchy(state, .{ .id = ids[i] });
    }

    const snaps = state.ui.undo.capture_entity_subtree(state.runtime.registry, entity) orelse {
        hierarchy_system.remove_entity_subtree(state, entity);
        return;
    };

    hierarchy_system.cleanup_deleted_entities(state, entity);
    hierarchy_system.unlink_entity_from_parent(state, entity);

    var after: [6]components.Hierarchy = undefined;
    i = 0;
    while (i < count) : (i += 1) {
        after[i] = ensure_hierarchy(state, .{ .id = ids[i] });
    }

    state.ui.undo.push_entity_subtree_snapshots(entity.id, .Delete, snaps, ids[0..count], before[0..count], after[0..count]);
    strip_entities_for_delete(state, snaps);
}

fn delete_selected_entities(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    if (selected.items.len == 0) return;

    var roots: std.ArrayListUnmanaged(entity_module.Entity) = .{};
    defer roots.deinit(alloc);

    for (selected.items) |ent| {
        var has_selected_ancestor = false;
        for (selected.items) |other| {
            if (ent.id == other.id) continue;
            if (is_descendant_of(state, ent, other)) {
                has_selected_ancestor = true;
                break;
            }
        }
        if (!has_selected_ancestor) roots.append(alloc, ent) catch {};
    }

    for (roots.items) |root| {
        if (state.runtime.registry.entity_manager.is_alive(root)) {
            delete_entity_with_undo(state, root);
        }
    }

    state.ui.selected_entities.clearRetainingCapacity();
    state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
}

fn duplicate_entity_subtree_with_undo(state: *EditorState, root: entity_module.Entity) ?entity_module.Entity {
    if (!state.runtime.registry.entity_manager.is_alive(root)) return null;
    if (state.runtime.registry.get(components.EditorGlobals, root) != null) return null;

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const snaps = state.ui.undo.capture_entity_subtree(state.runtime.registry, root) orelse return null;
    defer alloc.free(snaps);
    if (snaps.len == 0) return null;

    const root_h = ensure_hierarchy(state, root);
    const parent_opt = root_h.parent;
    const next_opt = root_h.next_sibling;

    var ids: [6]u64 = [_]u64{0} ** 6;
    var before: [6]components.Hierarchy = undefined;
    var count: u8 = 0;

    if (parent_opt) |p| push_unique_entity(ids[0..], &count, p.id);
    push_unique_entity(ids[0..], &count, root.id);
    if (next_opt) |n| push_unique_entity(ids[0..], &count, n.id);

    var i: u8 = 0;
    while (i < count) : (i += 1) {
        before[i] = ensure_hierarchy(state, .{ .id = ids[i] });
    }

    var map: std.AutoHashMapUnmanaged(u64, entity_module.Entity) = .{};
    defer map.deinit(alloc);

    for (snaps) |s| {
        const created = state.runtime.registry.create() catch return null;
        map.put(alloc, s.entity_id, created) catch return null;
        state.runtime.registry.add(created, components.Hierarchy{}) catch {};
    }

    for (snaps) |s| {
        const new_ent = map.get(s.entity_id) orelse continue;
        if (s.mask.name) state.runtime.registry.add(new_ent, s.name) catch {};
        if (s.mask.transform) state.runtime.registry.add(new_ent, s.transform) catch {};
        if (s.mask.node) state.runtime.registry.add(new_ent, s.node) catch {};
        if (s.mask.mesh_renderer) state.runtime.registry.add(new_ent, s.mesh_renderer) catch {};
        if (s.mask.light) state.runtime.registry.add(new_ent, s.light) catch {};
        if (s.mask.camera) state.runtime.registry.add(new_ent, s.camera) catch {};
        if (s.mask.skybox) state.runtime.registry.add(new_ent, s.skybox) catch {};
        if (s.mask.terrain) state.runtime.registry.add(new_ent, s.terrain) catch {};
        if (s.mask.script) state.runtime.registry.add(new_ent, s.script) catch {};
    }

    const new_root = map.get(root.id) orelse return null;

    if (parent_opt) |p| {
        if (state.runtime.registry.entity_manager.is_alive(p)) {
            hierarchy_system.insert_child_after(state, p, new_root, root);
        }
    }

    for (snaps) |s| {
        if (s.entity_id == root.id) continue;
        const new_ent = map.get(s.entity_id) orelse continue;
        const parent_id_opt = if (s.mask.hierarchy and s.hierarchy.parent != null) s.hierarchy.parent.?.id else root.id;
        const new_parent = map.get(parent_id_opt) orelse continue;
        hierarchy_system.append_child_end(state, new_parent, new_ent);
    }

    var after: [6]components.Hierarchy = undefined;
    i = 0;
    while (i < count) : (i += 1) {
        after[i] = ensure_hierarchy(state, .{ .id = ids[i] });
    }

    state.ui.undo.push_entity_subtree(state.runtime.registry, new_root, .Create, ids[0..count], before[0..count], after[0..count]);

    state.ui.selected_entity = new_root;
    state.ui.selected_model_id = 0;
    state.ui.scene_graph_focus_target_id = new_root.id;
    state.ui.scene_graph_focus_pending = true;
    state.ui.selected_entities.clearRetainingCapacity();
    state.ui.selected_entities.put(alloc, new_root.id, {}) catch {};

    return new_root;
}

fn duplicate_selected_entities(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    if (selected.items.len == 0) return;

    var roots: std.ArrayListUnmanaged(entity_module.Entity) = .{};
    defer roots.deinit(alloc);

    for (selected.items) |ent| {
        var has_selected_ancestor = false;
        for (selected.items) |other| {
            if (ent.id == other.id) continue;
            if (is_descendant_of(state, ent, other)) {
                has_selected_ancestor = true;
                break;
            }
        }
        if (!has_selected_ancestor) roots.append(alloc, ent) catch {};
    }

    for (roots.items) |root| {
        _ = duplicate_entity_subtree_with_undo(state, root);
    }
}

fn set_visibility_for_selected(state: *EditorState, visible: bool) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);

    var stack: std.ArrayListUnmanaged(entity_module.Entity) = .{};
    defer stack.deinit(alloc);

    var visited: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer visited.deinit(alloc);

    for (selected.items) |ent| {
        stack.append(alloc, ent) catch {};
        while (stack.items.len > 0) {
            const last = stack.items.len - 1;
            const cur = stack.items[last];
            stack.items.len = last;
            if (!state.runtime.registry.entity_manager.is_alive(cur)) continue;
            if (visited.contains(cur.id)) continue;
            visited.put(alloc, cur.id, {}) catch {};

            if (state.runtime.registry.get(components.MeshRenderer, cur)) |mr| {
                if (mr.visible != visible) {
                    const before = mr.*;
                    mr.visible = visible;
                    state.ui.undo.push(.{ .EntityMeshRenderer = .{
                        .entity_id = cur.id,
                        .before_present = true,
                        .after_present = true,
                        .before = before,
                        .after = mr.*,
                    } });
                }
            }

            if (state.runtime.registry.get(components.Hierarchy, cur)) |h| {
                var child = h.first_child;
                var guard: u32 = 0;
                while (child) |c_ent| {
                    if (guard > 100000) break;
                    guard += 1;
                    stack.append(alloc, c_ent) catch {};
                    child = if (state.runtime.registry.get(components.Hierarchy, c_ent)) |ch| ch.next_sibling else null;
                }
            }
        }
    }
}

fn batch_add_component_camera(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    for (selected.items) |ent| {
        if (state.runtime.registry.get(components.Camera, ent) != null) continue;
        const after = components.Camera{ .type = .Perspective };
        state.ui.undo.push(.{ .EntityCamera = .{
            .entity_id = ent.id,
            .before_present = false,
            .after_present = true,
            .before = std.mem.zeroes(components.Camera),
            .after = after,
        } });
        state.runtime.registry.add(ent, after) catch {};
        set_node_type_with_undo(state, ent, .Camera3D);
    }
}

fn batch_remove_component_camera(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    for (selected.items) |ent| {
        const cam_ptr = state.runtime.registry.get(components.Camera, ent) orelse continue;
        const before = cam_ptr.*;
        state.ui.undo.push(.{ .EntityCamera = .{
            .entity_id = ent.id,
            .before_present = true,
            .after_present = false,
            .before = before,
            .after = std.mem.zeroes(components.Camera),
        } });
        state.runtime.registry.remove(components.Camera, ent);
    }
}

fn batch_add_component_light(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    for (selected.items) |ent| {
        if (state.runtime.registry.get(components.Light, ent) != null) continue;
        const after = components.Light{ .type = .Directional, .cast_shadows = true };
        state.ui.undo.push(.{ .EntityLight = .{
            .entity_id = ent.id,
            .before_present = false,
            .after_present = true,
            .before = std.mem.zeroes(components.Light),
            .after = after,
        } });
        state.runtime.registry.add(ent, after) catch {};
        set_node_type_with_undo(state, ent, .DirectionalLight3D);
    }
}

fn batch_remove_component_light(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    for (selected.items) |ent| {
        const l_ptr = state.runtime.registry.get(components.Light, ent) orelse continue;
        const before = l_ptr.*;
        state.ui.undo.push(.{ .EntityLight = .{
            .entity_id = ent.id,
            .before_present = true,
            .after_present = false,
            .before = before,
            .after = std.mem.zeroes(components.Light),
        } });
        state.runtime.registry.remove(components.Light, ent);
    }
}

fn batch_add_component_mesh_renderer(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    for (selected.items) |ent| {
        if (state.runtime.registry.get(components.MeshRenderer, ent) != null) continue;
        const after = components.MeshRenderer{
            .mesh = .{ .index = std.math.maxInt(u32), .generation = 0 },
            .material = .{ .index = std.math.maxInt(u32), .generation = 0 },
            .visible = true,
            .cast_shadows = true,
            .receive_shadows = true,
        };
        state.ui.undo.push(.{ .EntityMeshRenderer = .{
            .entity_id = ent.id,
            .before_present = false,
            .after_present = true,
            .before = std.mem.zeroes(components.MeshRenderer),
            .after = after,
        } });
        state.runtime.registry.add(ent, after) catch {};
        set_node_type_with_undo(state, ent, .MeshInstance3D);
    }
}

fn batch_remove_component_mesh_renderer(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    for (selected.items) |ent| {
        const mr_ptr = state.runtime.registry.get(components.MeshRenderer, ent) orelse continue;
        const before = mr_ptr.*;
        state.ui.undo.push(.{ .EntityMeshRenderer = .{
            .entity_id = ent.id,
            .before_present = true,
            .after_present = false,
            .before = before,
            .after = std.mem.zeroes(components.MeshRenderer),
        } });
        state.runtime.registry.remove(components.MeshRenderer, ent);
    }
}

fn batch_add_component_script(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    for (selected.items) |ent| {
        if (state.runtime.registry.get(components.Script, ent) != null) continue;
        const after = components.Script{};
        state.ui.undo.push(.{ .EntityScript = .{
            .entity_id = ent.id,
            .before_present = false,
            .after_present = true,
            .before = std.mem.zeroes(components.Script),
            .after = after,
        } });
        state.runtime.registry.add(ent, after) catch {};
    }
}

fn batch_remove_component_script(state: *EditorState) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var selected = selected_entity_list(state, alloc);
    defer selected.deinit(alloc);
    for (selected.items) |ent| {
        const s_ptr = state.runtime.registry.get(components.Script, ent) orelse continue;
        const before = s_ptr.*;
        state.ui.undo.push(.{ .EntityScript = .{
            .entity_id = ent.id,
            .before_present = true,
            .after_present = false,
            .before = before,
            .after = std.mem.zeroes(components.Script),
        } });
        state.runtime.registry.remove(components.Script, ent);
    }
}

fn strip_entities_for_delete(state: *EditorState, snaps: anytype) void {
    var i: usize = 0;
    while (i < snaps.len) : (i += 1) {
        const ent = entity_module.Entity{ .id = snaps[i].entity_id };

        if (state.ui.selected_entity.id == ent.id) {
            state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
        }
        _ = state.ui.selected_entities.remove(ent.id);
        if (state.ui.renaming_entity.id == ent.id) {
            state.ui.renaming_entity = .{ .id = std.math.maxInt(u64) };
        }
        if (state.ui.scene_graph_focus_target_id == ent.id) {
            state.ui.scene_graph_focus_target_id = std.math.maxInt(u64);
            state.ui.scene_graph_focus_pending = false;
        }

        _ = state.ui.scene_graph_open_state.remove(ent.id);

        state.runtime.registry.remove(components.Name, ent);
        state.runtime.registry.remove(components.Transform, ent);
        state.runtime.registry.remove(components.Node, ent);
        state.runtime.registry.remove(components.MeshRenderer, ent);
        state.runtime.registry.remove(components.Light, ent);
        state.runtime.registry.remove(components.Camera, ent);
        state.runtime.registry.remove(components.Skybox, ent);
        state.runtime.registry.remove(components.Terrain, ent);
        state.runtime.registry.remove(components.Script, ent);
        state.runtime.registry.remove(components.EditorGlobals, ent);
        state.runtime.registry.remove(components.Hierarchy, ent);

        if (state.runtime.terrain_data_by_entity.fetchRemove(ent.id)) |kv| {
            const td = kv.value;
            for (td.layer_imgui_ids) |id| {
                if (id != 0) {
                    c.imgui_bridge_vk_remove_texture(id);
                }
            }
            if (td.height_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, td.height_handle);
            }
            if (td.splat_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, td.splat_handle);
            }
            for (td.layer_handles) |h| {
                if (h != std.math.maxInt(u32)) {
                    renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, h);
                }
            }
        }
        _ = state.runtime.terrain_dirty_rects.remove(ent.id);
    }

    scene_sync.sync_mesh_visibility_from_ecs(state);
    state.runtime.pending_scene = state.runtime.combined_scene;
    state.runtime.scene_upload_pending = true;
    state.runtime.picking_cache_dirty = true;
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

const FlatNode = struct {
    entity: entity_module.Entity,
    depth: u32,
    parent_index: i32,
};

fn scene_graph_query(state: *EditorState) []const u8 {
    const len = std.mem.indexOfScalar(u8, &state.ui.scene_graph_search, 0) orelse state.ui.scene_graph_search.len;
    return state.ui.scene_graph_search[0..len];
}

fn scene_graph_filter_active(state: *EditorState) bool {
    if (scene_graph_query(state).len > 0) return true;
    return state.ui.scene_graph_filter_meshes or state.ui.scene_graph_filter_lights or state.ui.scene_graph_filter_cameras;
}

fn contains_insensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn entity_matches_scene_graph_filter(state: *EditorState, entity: entity_module.Entity, query: []const u8) bool {
    var category_ok = true;
    if (state.ui.scene_graph_filter_meshes or state.ui.scene_graph_filter_lights or state.ui.scene_graph_filter_cameras) {
        category_ok = false;
        if (state.ui.scene_graph_filter_meshes and state.runtime.registry.get(components.MeshRenderer, entity) != null) category_ok = true;
        if (state.ui.scene_graph_filter_lights and state.runtime.registry.get(components.Light, entity) != null) category_ok = true;
        if (state.ui.scene_graph_filter_cameras and state.runtime.registry.get(components.Camera, entity) != null) category_ok = true;
    }
    if (!category_ok) return false;
    if (query.len == 0) return true;

    if (state.runtime.registry.get(components.Name, entity)) |n| {
        if (contains_insensitive(n.slice(), query)) return true;
    }
    if (state.runtime.registry.get(components.Node, entity)) |node_comp| {
        if (contains_insensitive(@tagName(node_comp.type), query)) return true;
    }
    return false;
}

fn subtree_matches_filter(
    state: *EditorState,
    entity: entity_module.Entity,
    query: []const u8,
    cache: *std.AutoHashMapUnmanaged(u64, bool),
    alloc: std.mem.Allocator,
) bool {
    if (cache.get(entity.id)) |v| return v;
    const h_ptr = state.runtime.registry.get(components.Hierarchy, entity) orelse {
        cache.put(alloc, entity.id, false) catch {};
        return false;
    };

    var match = entity_matches_scene_graph_filter(state, entity, query);
    if (!match) {
        var child = h_ptr.first_child;
        var loop_guard: u32 = 0;
        while (child) |c_ent| {
            if (loop_guard > 100000) break;
            loop_guard += 1;
            if (subtree_matches_filter(state, c_ent, query, cache, alloc)) {
                match = true;
                break;
            }
            child = if (state.runtime.registry.get(components.Hierarchy, c_ent)) |ch| ch.next_sibling else null;
        }
    }

    cache.put(alloc, entity.id, match) catch {};
    return match;
}

fn flat_append_visible(state: *EditorState, alloc: std.mem.Allocator, entity: entity_module.Entity, depth: u32, parent_index: i32, out: *std.ArrayListUnmanaged(FlatNode)) void {
    if (depth > 2048) return;
    if (state.runtime.registry.get(components.Hierarchy, entity) == null) return;

    const idx: i32 = @intCast(out.items.len);
    out.append(alloc, .{ .entity = entity, .depth = depth, .parent_index = parent_index }) catch return;

    const open = state.ui.scene_graph_open_state.get(entity.id) orelse false;
    if (!open) return;

    const h_ptr = state.runtime.registry.get(components.Hierarchy, entity) orelse return;
    var child = h_ptr.first_child;
    var loop_guard: u32 = 0;
    while (child) |c_ent| {
        if (loop_guard > 100000) break;
        loop_guard += 1;

        flat_append_visible(state, alloc, c_ent, depth + 1, idx, out);
        child = if (state.runtime.registry.get(components.Hierarchy, c_ent)) |ch| ch.next_sibling else null;
    }
}

fn flat_append_filtered(
    state: *EditorState,
    alloc: std.mem.Allocator,
    entity: entity_module.Entity,
    depth: u32,
    parent_index: i32,
    query: []const u8,
    cache: *std.AutoHashMapUnmanaged(u64, bool),
    out: *std.ArrayListUnmanaged(FlatNode),
) void {
    if (depth > 2048) return;
    if (!subtree_matches_filter(state, entity, query, cache, alloc)) return;
    if (state.runtime.registry.get(components.Hierarchy, entity) == null) return;

    const idx: i32 = @intCast(out.items.len);
    out.append(alloc, .{ .entity = entity, .depth = depth, .parent_index = parent_index }) catch return;

    const h_ptr = state.runtime.registry.get(components.Hierarchy, entity) orelse return;
    var child = h_ptr.first_child;
    var loop_guard: u32 = 0;
    while (child) |c_ent| {
        if (loop_guard > 100000) break;
        loop_guard += 1;

        flat_append_filtered(state, alloc, c_ent, depth + 1, idx, query, cache, out);
        child = if (state.runtime.registry.get(components.Hierarchy, c_ent)) |ch| ch.next_sibling else null;
    }
}

fn scene_graph_globals_entity(state: *EditorState) ?entity_module.Entity {
    return editor_state.resolveEditorGlobalsEntity(state.runtime.registry, state.runtime.globals_entity);
}

fn is_scene_graph_root(h: *const components.Hierarchy) bool {
    return h.parent == null or h.parent.?.id == std.math.maxInt(u64);
}

fn build_scene_graph_flat(state: *EditorState, alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(FlatNode)) void {
    out.clearRetainingCapacity();
    const query = scene_graph_query(state);
    const filter_active = scene_graph_filter_active(state);

    var cache: std.AutoHashMapUnmanaged(u64, bool) = .{};
    defer cache.deinit(alloc);

    const globals_entity = scene_graph_globals_entity(state);
    if (globals_entity) |ge| {
        if (state.runtime.registry.get(components.Hierarchy, ge)) |h| {
            if (is_scene_graph_root(h)) {
                if (filter_active) {
                    flat_append_filtered(state, alloc, ge, 0, -1, query, &cache, out);
                } else {
                    flat_append_visible(state, alloc, ge, 0, -1, out);
                }
            }
        }
    }

    var it = state.runtime.registry.view(components.Hierarchy).iterator();
    while (it.next()) |entry| {
        const entity = entry.entity;
        if (globals_entity) |ge| {
            if (entity.id == ge.id) continue;
        }

        if (!is_scene_graph_root(entry.component)) continue;

        if (filter_active) {
            flat_append_filtered(state, alloc, entity, 0, -1, query, &cache, out);
        } else {
            flat_append_visible(state, alloc, entity, 0, -1, out);
        }
    }
}

fn draw_flat_node(state: *EditorState, node: FlatNode, indent_spacing: f32, rebuild_requested: *bool) void {
    if (!state.runtime.registry.entity_manager.is_alive(node.entity)) return;

    const hierarchy = state.runtime.registry.get(components.Hierarchy, node.entity) orelse return;
    const is_globals = state.runtime.registry.get(components.EditorGlobals, node.entity) != null;

    const filter_active = scene_graph_filter_active(state);
    const has_children = hierarchy.first_child != null and !filter_active;
    const open_before = if (has_children) (state.ui.scene_graph_open_state.get(node.entity.id) orelse false) else false;

    if (node.depth > 0) {
        c.imgui_bridge_indent(indent_spacing * @as(f32, @floatFromInt(node.depth)));
    }
    defer if (node.depth > 0) c.imgui_bridge_unindent(indent_spacing * @as(f32, @floatFromInt(node.depth)));

    var name_buf: [256]u8 = undefined;
    var name: []const u8 = "Entity";
    if (state.runtime.registry.get(components.Name, node.entity)) |n| {
        name = n.slice();
    }

    var prefix: []const u8 = "";
    if (state.runtime.registry.get(components.Node, node.entity)) |node_comp| {
        prefix = node_prefix(node_comp.type);
    }

    var flags: i32 = c.ImGuiTreeNodeFlags_OpenOnArrow | c.ImGuiTreeNodeFlags_SpanAvailWidth | c.ImGuiTreeNodeFlags_NoTreePushOnOpen;
    if (state.ui.selected_entities.contains(node.entity.id) or (state.ui.selected_entity.id == node.entity.id and state.ui.selected_entities.count() == 0)) {
        flags |= c.ImGuiTreeNodeFlags_Selected;
    }
    if (!has_children) {
        flags |= c.ImGuiTreeNodeFlags_Leaf;
    }

    const open = blk: {
        if (state.ui.renaming_entity.id == node.entity.id) {
            const id_label = std.fmt.bufPrintZ(&name_buf, "##{d}", .{node.entity.id}) catch "##";
            if (state.ui.scene_graph_focus_pending and focus_chain_contains(state, node.entity.id)) {
                c.imgui_bridge_set_next_item_open(true, c.ImGuiCond_Once);
            }
            break :blk c.imgui_bridge_tree_node_ex(id_label.ptr, flags | c.ImGuiTreeNodeFlags_AllowItemOverlap);
        }

        const label = std.fmt.bufPrintZ(&name_buf, "{s}{s}##{d}", .{ prefix, name, node.entity.id }) catch "Entity";
        if (state.ui.scene_graph_focus_pending and focus_chain_contains(state, node.entity.id)) {
            c.imgui_bridge_set_next_item_open(true, c.ImGuiCond_Once);
        }
        break :blk c.imgui_bridge_tree_node_ex(label.ptr, flags);
    };

    if (has_children and open != open_before) {
        const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
        state.ui.scene_graph_open_state.put(alloc, node.entity.id, open) catch {};
        rebuild_requested.* = true;
    }

    if (state.ui.renaming_entity.id == node.entity.id) {
        c.imgui_bridge_same_line(0, 0);
        c.imgui_bridge_push_item_width(-1);
        defer c.imgui_bridge_pop_item_width();

        if (c.imgui_bridge_is_window_focused(0) and !c.imgui_bridge_is_any_item_active()) {
            c.imgui_bridge_set_keyboard_focus_here(0);
        }

        if (c.imgui_bridge_input_text("##Rename", @ptrCast(&state.ui.rename_buffer), state.ui.rename_buffer.len, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_AutoSelectAll)) {
            const new_len = std.mem.indexOfScalar(u8, &state.ui.rename_buffer, 0) orelse state.ui.rename_buffer.len;
            const new_name = state.ui.rename_buffer[0..new_len];
            if (new_len > 0) {
                const before_ptr = state.runtime.registry.get(components.Name, node.entity);
                const before_present = before_ptr != null;
                const before = if (before_ptr) |p| p.* else std.mem.zeroes(components.Name);
                const after = components.Name.init(new_name);
                state.ui.undo.push(.{ .EntityName = .{
                    .entity_id = node.entity.id,
                    .before_present = before_present,
                    .after_present = true,
                    .before = before,
                    .after = after,
                } });
                state.runtime.registry.add(node.entity, after) catch {};
            }
            state.ui.renaming_entity.id = std.math.maxInt(u64);
        }

        if (!c.imgui_bridge_is_item_active() and (c.imgui_bridge_is_mouse_clicked(0) or c.imgui_bridge_is_key_pressed(c.ImGuiKey_Escape))) {
            state.ui.renaming_entity.id = std.math.maxInt(u64);
        }
    } else {
        if (c.imgui_bridge_is_item_clicked(0)) {
            const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
            state.ui.selected_entity = node.entity;
            if (!c.imgui_bridge_is_ctrl_down()) {
                state.ui.selected_entities.clearRetainingCapacity();
            }
            if (c.imgui_bridge_is_ctrl_down() and state.ui.selected_entities.contains(node.entity.id)) {
                _ = state.ui.selected_entities.remove(node.entity.id);
                if (state.ui.selected_entities.count() == 0) {
                    state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
                }
            } else {
                state.ui.selected_entities.put(alloc, node.entity.id, {}) catch {};
            }
        }
    }

    if (!is_globals and state.ui.renaming_entity.id != node.entity.id) {
        if (c.imgui_bridge_begin_drag_drop_source(0)) {
            const id_copy: u64 = node.entity.id;
            _ = c.imgui_bridge_set_drag_drop_payload("SCENE_ENTITY", &id_copy, @sizeOf(u64), 0);
            var drag_label_buf: [256]u8 = undefined;
            const drag_label_z = std.fmt.bufPrintZ(&drag_label_buf, "{s}{s}", .{ prefix, name }) catch "Entity";
            c.imgui_bridge_text("%s", drag_label_z.ptr);
            c.imgui_bridge_end_drag_drop_source();
        }
    }

    if (state.ui.scene_graph_focus_pending and state.ui.scene_graph_focus_target_id == node.entity.id) {
        c.imgui_bridge_set_scroll_here_y(0.5);
        state.ui.scene_graph_focus_pending = false;
        state.ui.scene_graph_open_chain_len = 0;
        state.ui.scene_graph_focus_target_id = std.math.maxInt(u64);
    }

    if (c.imgui_bridge_begin_popup_context_item()) {
        const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
        if (!state.ui.selected_entities.contains(node.entity.id)) {
            state.ui.selected_entities.clearRetainingCapacity();
            state.ui.selected_entities.put(alloc, node.entity.id, {}) catch {};
            state.ui.selected_entity = node.entity;
        }

        const selection_count: usize = state.ui.selected_entities.count();
        if (!is_globals) {
            if (c.imgui_bridge_menu_item("Create...", null, false, true)) {
                open_create_node_popup(state, node.entity);
            }

            if (c.imgui_bridge_menu_item("Rename", null, false, true)) {
                state.ui.renaming_entity = node.entity;
                @memset(&state.ui.rename_buffer, 0);
                const len = @min(name.len, 255);
                @memcpy(state.ui.rename_buffer[0..len], name[0..len]);
            }
        }

        if (c.imgui_bridge_menu_item("Frame in Scene View", null, false, true)) {
            state.ui.selected_entity = node.entity;
            selection_system.frame_entity_in_scene_view(state, node.entity);
        }

        if (!is_globals and selection_count > 1 and c.imgui_bridge_menu_item("Duplicate Selected", null, false, true)) {
            duplicate_selected_entities(state);
            c.imgui_bridge_end_popup();
            return;
        }
        if (!is_globals and selection_count == 1 and c.imgui_bridge_menu_item("Duplicate", null, false, true)) {
            _ = duplicate_entity_subtree_with_undo(state, node.entity);
            c.imgui_bridge_end_popup();
            return;
        }

        if (!is_globals and selection_count > 1 and c.imgui_bridge_menu_item("Delete Selected", null, false, true)) {
            delete_selected_entities(state);
            c.imgui_bridge_end_popup();
            return;
        }

        if (!is_globals and selection_count > 1) {
            if (c.imgui_bridge_menu_item("Set Visible (Selected)", null, false, true)) {
                set_visibility_for_selected(state, true);
            }
            if (c.imgui_bridge_menu_item("Set Hidden (Selected)", null, false, true)) {
                set_visibility_for_selected(state, false);
            }

            if (c.imgui_bridge_begin_menu("Add Component", true)) {
                if (c.imgui_bridge_menu_item("Camera", null, false, true)) batch_add_component_camera(state);
                if (c.imgui_bridge_menu_item("Light", null, false, true)) batch_add_component_light(state);
                if (c.imgui_bridge_menu_item("Mesh Renderer", null, false, true)) batch_add_component_mesh_renderer(state);
                if (c.imgui_bridge_menu_item("Script", null, false, true)) batch_add_component_script(state);
                c.imgui_bridge_end_menu();
            }
            if (c.imgui_bridge_begin_menu("Remove Component", true)) {
                if (c.imgui_bridge_menu_item("Camera", null, false, true)) batch_remove_component_camera(state);
                if (c.imgui_bridge_menu_item("Light", null, false, true)) batch_remove_component_light(state);
                if (c.imgui_bridge_menu_item("Mesh Renderer", null, false, true)) batch_remove_component_mesh_renderer(state);
                if (c.imgui_bridge_menu_item("Script", null, false, true)) batch_remove_component_script(state);
                c.imgui_bridge_end_menu();
            }
        }

        if (!is_globals and c.imgui_bridge_menu_item("Delete", null, false, true)) {
            var ids: [6]u64 = [_]u64{0} ** 6;
            var before: [6]components.Hierarchy = undefined;
            var count: u8 = 0;

            const h = ensure_hierarchy(state, node.entity);
            if (h.parent) |p| push_unique_entity(ids[0..], &count, p.id);
            if (h.prev_sibling) |p| push_unique_entity(ids[0..], &count, p.id);
            if (h.next_sibling) |n| push_unique_entity(ids[0..], &count, n.id);

            var i: u8 = 0;
            while (i < count) : (i += 1) {
                before[i] = ensure_hierarchy(state, .{ .id = ids[i] });
            }

            const snaps = state.ui.undo.capture_entity_subtree(state.runtime.registry, node.entity) orelse {
                hierarchy_system.remove_entity_subtree(state, node.entity);
                c.imgui_bridge_end_popup();
                return;
            };

            hierarchy_system.cleanup_deleted_entities(state, node.entity);
            hierarchy_system.unlink_entity_from_parent(state, node.entity);

            var after: [6]components.Hierarchy = undefined;
            i = 0;
            while (i < count) : (i += 1) {
                after[i] = ensure_hierarchy(state, .{ .id = ids[i] });
            }

            state.ui.undo.push_entity_subtree_snapshots(node.entity.id, .Delete, snaps, ids[0..count], before[0..count], after[0..count]);
            strip_entities_for_delete(state, snaps);
        }
        c.imgui_bridge_end_popup();
    }

    if (!is_globals and c.imgui_bridge_begin_drag_drop_target()) {
        if (c.imgui_bridge_accept_drag_drop_payload("ASSET_MODEL", 0)) |payload| {
            const data_ptr = c.imgui_bridge_payload_get_data(payload);
            const data_size = c.imgui_bridge_payload_get_data_size(payload);
            const data = @as([*]const u8, @ptrCast(data_ptr));
            const len = @as(usize, @intCast(data_size));
            const path = data[0..len];

            scene_io.load_model_to_entity(state, path, node.entity);
        }
        if (c.imgui_bridge_accept_drag_drop_payload("SCENE_ENTITY", 0)) |payload| {
            const data_ptr = c.imgui_bridge_payload_get_data(payload);
            const data_size = c.imgui_bridge_payload_get_data_size(payload);
            if (data_ptr != null and data_size == @sizeOf(u64)) {
                const dragged_id = @as(*const u64, @ptrCast(@alignCast(data_ptr))).*;
                const dragged = entity_module.Entity{ .id = dragged_id };
                if (state.runtime.registry.entity_manager.is_alive(dragged)) {
                    const dragged_h = ensure_hierarchy(state, dragged);
                    const target_h = ensure_hierarchy(state, node.entity);
                    if (dragged_h.parent != null and target_h.parent != null and dragged_h.parent.?.id == target_h.parent.?.id) {
                        reorder_entity_relative_to_sibling(state, dragged, node.entity, c.imgui_bridge_is_shift_down());
                    } else {
                        reparent_entity(state, dragged, node.entity);
                    }
                }
            }
        }
        c.imgui_bridge_end_drag_drop_target();
    }
}

const FlatRenderCtx = struct {
    state: *EditorState,
    nodes: []const FlatNode,
    indent_spacing: f32,
    rebuild_requested: *bool,
};

fn render_flat_range(user_data: ?*anyopaque, start: c_int, end: c_int) callconv(.c) void {
    const ctx: *FlatRenderCtx = @ptrCast(@alignCast(user_data.?));
    var i: usize = @intCast(start);
    const e: usize = @intCast(end);
    while (i < e and i < ctx.nodes.len) : (i += 1) {
        draw_flat_node(ctx.state, ctx.nodes[i], ctx.indent_spacing, ctx.rebuild_requested);
    }
}

fn combined_scene_filter_enabled(state: *EditorState) bool {
    var it = state.runtime.mesh_entity_by_mesh_index.iterator();
    return it.next() != null;
}

fn mesh_entity_for_index(state: *EditorState, mesh_index: u32) ?entity_module.Entity {
    if (state.runtime.mesh_entity_by_mesh_index.get(mesh_index)) |id| {
        const ent = entity_module.Entity{ .id = id };
        if (!state.runtime.registry.entity_manager.is_alive(ent)) return null;
        if (state.runtime.registry.get(components.MeshRenderer, ent) == null) return null;
        return ent;
    }
    return null;
}

fn is_mesh_active(state: *EditorState, mesh_index: u32, filter: bool) bool {
    if (!filter) return true;
    return mesh_entity_for_index(state, mesh_index) != null;
}

fn node_has_active_content(state: *EditorState, scene_ptr: *scene.CardinalScene, node: *scene.CardinalSceneNode, depth: u32, filter: bool) bool {
    if (depth > 2048) return false;
    if (node.mesh_count > 0 and node.mesh_indices != null) {
        var i: u32 = 0;
        while (i < node.mesh_count) : (i += 1) {
            const mesh_idx = node.mesh_indices.?[i];
            if (mesh_idx < scene_ptr.mesh_count and is_mesh_active(state, mesh_idx, filter)) return true;
        }
    }
    if (node.child_count > 0 and node.children != null) {
        var i: u32 = 0;
        while (i < node.child_count) : (i += 1) {
            if (node.children.?[i]) |child| {
                if (node_has_active_content(state, scene_ptr, child, depth + 1, filter)) return true;
            }
        }
    }
    return false;
}

/// Draws a debug tree view of an engine-loaded `CardinalSceneNode`.
fn draw_scene_node(state: *EditorState, scene_ptr: *scene.CardinalScene, node: *scene.CardinalSceneNode, depth: i32, filter: bool) bool {
    if (!node_has_active_content(state, scene_ptr, node, @intCast(@max(0, depth)), filter)) return false;

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
                    if (mesh_idx >= scene_ptr.mesh_count) continue;
                    if (!is_mesh_active(state, mesh_idx, filter)) continue;
                    if (scene_ptr.meshes) |meshes| {
                        const m = &meshes[mesh_idx];

                        var cb_id: [64]u8 = undefined;
                        const cb_id_z = std.fmt.bufPrintZ(&cb_id, "Visible##mesh_{d}", .{mesh_idx}) catch "Visible";

                        if (filter) {
                            if (mesh_entity_for_index(state, mesh_idx)) |ent| {
                                if (state.runtime.registry.get(components.MeshRenderer, ent)) |mr| {
                                    const before = mr.*;
                                    var visible = mr.visible;
                                    if (c.imgui_bridge_checkbox(cb_id_z.ptr, &visible)) {
                                        mr.visible = visible;
                                        state.ui.undo.push(.{ .EntityMeshRenderer = .{
                                            .entity_id = ent.id,
                                            .before_present = true,
                                            .after_present = true,
                                            .before = before,
                                            .after = mr.*,
                                        } });
                                    }
                                }
                            }
                        } else {
                            _ = c.imgui_bridge_checkbox(cb_id_z.ptr, &m.visible);
                        }
                        c.imgui_bridge_same_line(0, -1);
                        c.imgui_bridge_bullet_text("Mesh %d: %d vertices, %d indices", mesh_idx, m.vertex_count, m.index_count);
                    }
                }
            }
            c.imgui_bridge_tree_pop();
        }

        var i: u32 = 0;
        while (i < node.child_count) : (i += 1) {
            if (node.children) |children| {
                if (children[i]) |child| {
                    _ = draw_scene_node(state, scene_ptr, child, depth + 1, filter);
                }
            }
        }

        c.imgui_bridge_tree_pop();
    }
    return true;
}

/// Draws the Scene Graph panel (ECS tree + optional combined-scene debug view).
pub fn draw_hierarchy_panel(state: *EditorState) void {
    if (state.ui.show_scene_graph) {
        const open = c.imgui_bridge_begin("Scene Graph", &state.ui.show_scene_graph, 0);
        defer c.imgui_bridge_end();

        if (open) {
            if (state.ui.scene_graph_focus_pending and state.ui.selected_entity.id != std.math.maxInt(u64)) {
                build_focus_open_chain(state, state.ui.selected_entity);
                const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
                var i: u8 = 0;
                while (i < state.ui.scene_graph_open_chain_len) : (i += 1) {
                    state.ui.scene_graph_open_state.put(alloc, state.ui.scene_graph_open_chain[i], true) catch {};
                }
            }

            if (c.imgui_bridge_button("Create Node +")) {
                open_create_node_popup(state, null);
            }
            draw_create_node_popup(state);

            c.imgui_bridge_same_line(0, -1);
            c.imgui_bridge_push_item_width(260);
            _ = c.imgui_bridge_input_text_with_hint("##SceneGraphSearch", "Search (name/type)...", @ptrCast(&state.ui.scene_graph_search), state.ui.scene_graph_search.len);
            c.imgui_bridge_pop_item_width();
            c.imgui_bridge_same_line(0, -1);
            _ = c.imgui_bridge_checkbox("Meshes", &state.ui.scene_graph_filter_meshes);
            c.imgui_bridge_same_line(0, -1);
            _ = c.imgui_bridge_checkbox("Lights", &state.ui.scene_graph_filter_lights);
            c.imgui_bridge_same_line(0, -1);
            _ = c.imgui_bridge_checkbox("Cameras", &state.ui.scene_graph_filter_cameras);

            c.imgui_bridge_separator();

            if (state.ui.scene_graph_focus_pending) {
                c.imgui_bridge_set_next_item_open(true, c.ImGuiCond_Once);
            }
            if (c.imgui_bridge_tree_node_ex("Scene", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                c.imgui_bridge_bullet_text("Camera");
                c.imgui_bridge_bullet_text("Directional Light");

                var flat: std.ArrayListUnmanaged(FlatNode) = .{};
                const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
                defer flat.deinit(alloc);
                var rebuild_requested = false;
                build_scene_graph_flat(state, alloc, &flat);

                var pass: u8 = 0;
                while (pass < 2) : (pass += 1) {
                    const count: c_int = @intCast(flat.items.len);
                    if (count > 0) {
                        var ctx = FlatRenderCtx{
                            .state = state,
                            .nodes = flat.items,
                            .indent_spacing = c.imgui_bridge_get_style_indent_spacing(),
                            .rebuild_requested = &rebuild_requested,
                        };
                        c.imgui_bridge_list_clipper(count, -1.0, render_flat_range, @ptrCast(&ctx));
                    }
                    if (!rebuild_requested) break;
                    rebuild_requested = false;
                    build_scene_graph_flat(state, alloc, &flat);
                }

                c.imgui_bridge_tree_pop();
            }

            if (state.runtime.scene_loaded) {
                if (c.imgui_bridge_tree_node("Combined Scene (Debug)")) {
                    const filter = combined_scene_filter_enabled(state);
                    var active_meshes: u32 = 0;
                    var mi: u32 = 0;
                    while (mi < state.runtime.combined_scene.mesh_count) : (mi += 1) {
                        if (is_mesh_active(state, mi, filter)) active_meshes += 1;
                    }

                    if (filter) {
                        c.imgui_bridge_text("Meshes: %d active / %d total", active_meshes, state.runtime.combined_scene.mesh_count);
                    } else {
                        c.imgui_bridge_text("Total Meshes: %d", state.runtime.combined_scene.mesh_count);
                    }
                    c.imgui_bridge_text("Root Nodes: %d", state.runtime.combined_scene.root_node_count);

                    c.imgui_bridge_separator();
                    c.imgui_bridge_text("Bulk Visibility Controls:");

                    if (c.imgui_bridge_button("Show All Meshes")) {
                        if (filter) {
                            var view = state.runtime.registry.view(components.MeshRenderer);
                            var it = view.iterator();
                            while (it.next()) |entry| {
                                entry.component.visible = true;
                            }
                        } else {
                            var i: u32 = 0;
                            while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                                if (state.runtime.combined_scene.meshes) |meshes| {
                                    meshes[i].visible = true;
                                }
                            }
                        }
                    }
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Hide All Meshes")) {
                        if (filter) {
                            var view = state.runtime.registry.view(components.MeshRenderer);
                            var it = view.iterator();
                            while (it.next()) |entry| {
                                entry.component.visible = false;
                            }
                        } else {
                            var i: u32 = 0;
                            while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                                if (state.runtime.combined_scene.meshes) |meshes| {
                                    meshes[i].visible = false;
                                }
                            }
                        }
                    }

                    if (c.imgui_bridge_button("Show Only Material 0")) {
                        if (filter) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                var view = state.runtime.registry.view(components.MeshRenderer);
                                var it = view.iterator();
                                while (it.next()) |entry| {
                                    const mr = entry.component;
                                    if (mr.mesh.index < state.runtime.combined_scene.mesh_count) {
                                        mr.visible = (meshes[mr.mesh.index].material_index == 0);
                                    }
                                }
                            }
                        } else {
                            var i: u32 = 0;
                            while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                                if (state.runtime.combined_scene.meshes) |meshes| {
                                    meshes[i].visible = (meshes[i].material_index == 0);
                                }
                            }
                        }
                    }
                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Show Only Material 1")) {
                        if (filter) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                var view = state.runtime.registry.view(components.MeshRenderer);
                                var it = view.iterator();
                                while (it.next()) |entry| {
                                    const mr = entry.component;
                                    if (mr.mesh.index < state.runtime.combined_scene.mesh_count) {
                                        mr.visible = (meshes[mr.mesh.index].material_index == 1);
                                    }
                                }
                            }
                        } else {
                            var i: u32 = 0;
                            while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                                if (state.runtime.combined_scene.meshes) |meshes| {
                                    meshes[i].visible = (meshes[i].material_index == 1);
                                }
                            }
                        }
                    }

                    if (c.imgui_bridge_button("Toggle Materials 0/1")) {
                        if (filter) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                var view = state.runtime.registry.view(components.MeshRenderer);
                                var it = view.iterator();
                                while (it.next()) |entry| {
                                    const mr = entry.component;
                                    if (mr.mesh.index < state.runtime.combined_scene.mesh_count) {
                                        if (meshes[mr.mesh.index].material_index == 0) {
                                            mr.visible = state.ui.show_material_0_toggle;
                                        } else if (meshes[mr.mesh.index].material_index == 1) {
                                            mr.visible = !state.ui.show_material_0_toggle;
                                        }
                                    }
                                }
                            }
                            state.ui.show_material_0_toggle = !state.ui.show_material_0_toggle;
                        } else {
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
                    }

                    if (state.runtime.combined_scene.root_node_count > 0) {
                        c.imgui_bridge_separator();
                        var i: u32 = 0;
                        while (i < state.runtime.combined_scene.root_node_count) : (i += 1) {
                            if (state.runtime.combined_scene.root_nodes) |root_nodes| {
                                if (root_nodes[i]) |root| {
                                    _ = draw_scene_node(state, &state.runtime.combined_scene, root, 0, filter);
                                }
                            }
                        }
                    } else {
                        c.imgui_bridge_text("No scene hierarchy - showing flat mesh list:");
                        var i: u32 = 0;
                        while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
                            if (state.runtime.combined_scene.meshes) |meshes| {
                                if (!is_mesh_active(state, i, filter)) continue;
                                const m = &meshes[i];
                                var cb_id: [64]u8 = undefined;
                                const cb_id_z = std.fmt.bufPrintZ(&cb_id, "Visible##flat_mesh_{d}", .{i}) catch "Visible";
                                if (filter) {
                                    if (mesh_entity_for_index(state, i)) |ent| {
                                        if (state.runtime.registry.get(components.MeshRenderer, ent)) |mr| {
                                            var visible = mr.visible;
                                            if (c.imgui_bridge_checkbox(cb_id_z.ptr, &visible)) {
                                                mr.visible = visible;
                                            }
                                        }
                                    }
                                } else {
                                    _ = c.imgui_bridge_checkbox(cb_id_z.ptr, &m.visible);
                                }
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
