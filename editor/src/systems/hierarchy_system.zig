//! Editor hierarchy mutation helpers.
//!
//! Provides shared utilities for reparenting and deleting entity subtrees while keeping editor
//! runtime maps consistent.
const std = @import("std");
const engine = @import("cardinal_engine");
const components = engine.ecs_components;
const EditorState = @import("../editor_state.zig").EditorState;

/// Unlinks an entity from its parent and sibling list, leaving it as a root.
pub fn unlink_entity_from_parent(state: *EditorState, entity: engine.ecs_entity.Entity) void {
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

    if (parent_h.last_child) |lc| {
        if (lc.id == entity.id) {
            parent_h.last_child = hierarchy.prev_sibling;
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
    if (parent_h.child_count == 0) {
        parent_h.first_child = null;
        parent_h.last_child = null;
    } else if (parent_h.first_child == null) {
        parent_h.last_child = null;
    }
    state.runtime.registry.add(parent, parent_h) catch {};

    hierarchy.parent = null;
    hierarchy.prev_sibling = null;
    hierarchy.next_sibling = null;
    state.runtime.registry.add(entity, hierarchy) catch {};
}

/// Removes runtime maps (transform overrides and mesh ownership maps) for a subtree.
pub fn cleanup_deleted_entities(state: *EditorState, root: engine.ecs_entity.Entity) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    var deleted: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer deleted.deinit(alloc);

    var stack: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
    defer stack.deinit(alloc);

    stack.append(alloc, root) catch return;

    while (stack.items.len != 0) {
        const last_index = stack.items.len - 1;
        const e = stack.items[last_index];
        stack.items.len = last_index;
        if (deleted.contains(e.id)) continue;
        deleted.put(alloc, e.id, {}) catch {};

        if (state.runtime.registry.get(components.Hierarchy, e)) |h_ptr| {
            const h = h_ptr.*;
            var child = h.first_child;
            var loop_guard: u32 = 0;
            while (child) |c_ent| {
                if (loop_guard > 100000) break;
                loop_guard += 1;

                stack.append(alloc, c_ent) catch {};
                child = if (state.runtime.registry.get(components.Hierarchy, c_ent)) |ch| ch.next_sibling else null;
            }
        }
    }

    if (deleted.contains(state.ui.selected_entity.id)) {
        state.ui.selected_entity = .{ .id = std.math.maxInt(u64) };
    }

    var deleted_it = deleted.iterator();
    while (deleted_it.next()) |entry| {
        _ = state.runtime.transform_overrides.remove(entry.key_ptr.*);
    }

    var mesh_keys_to_remove: std.ArrayListUnmanaged(u32) = .{};
    defer mesh_keys_to_remove.deinit(alloc);

    var owner_it = state.runtime.mesh_owner_by_mesh_index.iterator();
    while (owner_it.next()) |entry| {
        if (deleted.contains(entry.value_ptr.*)) {
            mesh_keys_to_remove.append(alloc, entry.key_ptr.*) catch {};
        }
    }
    for (mesh_keys_to_remove.items) |k| {
        _ = state.runtime.mesh_owner_by_mesh_index.remove(k);
    }

    mesh_keys_to_remove.clearRetainingCapacity();
    var mesh_ent_it = state.runtime.mesh_entity_by_mesh_index.iterator();
    while (mesh_ent_it.next()) |entry| {
        if (deleted.contains(entry.value_ptr.*)) {
            mesh_keys_to_remove.append(alloc, entry.key_ptr.*) catch {};
        }
    }
    for (mesh_keys_to_remove.items) |k| {
        _ = state.runtime.mesh_entity_by_mesh_index.remove(k);
    }
}

/// Destroys an entity and its descendants from the ECS registry.
pub fn destroy_entity_recursive(state: *EditorState, entity: engine.ecs_entity.Entity, depth: u32) void {
    if (depth > 2048) return;

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

/// Removes a subtree from the hierarchy and destroys its entities.
pub fn remove_entity_subtree(state: *EditorState, root: engine.ecs_entity.Entity) void {
    cleanup_deleted_entities(state, root);
    unlink_entity_from_parent(state, root);
    destroy_entity_recursive(state, root, 0);
}
