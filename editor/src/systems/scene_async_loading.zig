//! Asynchronous model loading helpers for the editor.
//!
//! Starts engine loader tasks and instantiates completed models into the ECS.
const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const EditorState = @import("../editor_state.zig").EditorState;
const math = engine.math;
const components = engine.ecs_components;
const node_factory = engine.ecs_node_factory;
const async_loader = engine.async_loader;

/// Starts an async load of `path` and schedules attaching it under `parent`.
pub fn load_model_to_entity(state: *EditorState, path: []const u8, parent: engine.ecs_entity.Entity) void {
    const allocator = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    std.fs.cwd().access(path, .{}) catch {
        log.cardinal_log_error("Model file not found: {s}", .{path});
        return;
    };

    var path_z_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path}) catch return;

    const task_opt = engine.loader.cardinal_scene_load_async(path_z.ptr, .HIGH, null, null);
    if (task_opt == null) {
        log.cardinal_log_error("Failed to start model load task for: {s}", .{path});
        return;
    }
    const task = task_opt.?;

    const path_copy = allocator.dupeZ(u8, path) catch return;
    state.runtime.loading_tasks.append(allocator, .{
        .task = task,
        .path = path_copy,
        .target_entity = parent,
    }) catch {};

    state.runtime.is_loading = true;
    _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Loading model: {s}", .{path}) catch {};
}

/// Instantiates one loaded model under `parent_entity` by importing its scene nodes into the ECS.
///
/// Creates one entity per scene node, and attaches extra mesh primitives as child entities so
/// parent transforms apply to all meshes.
pub fn instantiate_model(state: *EditorState, model_id: u32, parent_entity: engine.ecs_entity.Entity) void {
    const model_ptr = engine.model_manager.cardinal_model_manager_get_model(&state.runtime.model_manager, model_id);
    if (model_ptr == null) return;
    const model = model_ptr.?;
    const scene = &model.scene;
    const map_alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    log.cardinal_log_info("[SCENE_IO] Instantiating model {d} under entity {d}...", .{ model_id, parent_entity.id });

    if (!state.runtime.registry.entity_manager.is_alive(parent_entity)) return;

    const ensure_hierarchy = struct {
        fn f(registry: *engine.ecs_registry.Registry, ent: engine.ecs_entity.Entity) components.Hierarchy {
            if (registry.get(components.Hierarchy, ent)) |h| return h.*;
            registry.add(ent, components.Hierarchy{}) catch {};
            return components.Hierarchy{};
        }
    }.f;

    var before_ids: [6]u64 = [_]u64{0} ** 6;
    var before_h: [6]components.Hierarchy = undefined;
    var after_h: [6]components.Hierarchy = undefined;
    var before_count: u8 = 0;

    before_ids[before_count] = parent_entity.id;
    before_h[before_count] = ensure_hierarchy(state.runtime.registry, parent_entity);
    before_count += 1;

    const parent_h = before_h[0];
    if (parent_h.last_child) |lc| {
        before_ids[before_count] = lc.id;
        before_h[before_count] = ensure_hierarchy(state.runtime.registry, lc);
        before_count += 1;
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
        before_ids[before_count] = last.id;
        before_h[before_count] = ensure_hierarchy(state.runtime.registry, last);
        before_count += 1;
    }

    const root_entity = state.runtime.registry.create() catch return;
    const root_name = if (model.name) |n| std.mem.span(n) else "Model";
    const root_stem = std.fs.path.stem(root_name);
    const root_label = if (root_stem.len > 0) root_stem else root_name;
    state.runtime.registry.add(root_entity, components.Name.init(root_label)) catch {};
    state.runtime.registry.add(root_entity, components.Node{ .type = .Node3D }) catch {};
    state.runtime.registry.add(root_entity, components.Transform{}) catch {};
    state.runtime.registry.add(root_entity, components.Hierarchy{}) catch {};
    node_factory.append_child(state.runtime.registry, parent_entity, root_entity);

    var h_i: u8 = 0;
    while (h_i < before_count) : (h_i += 1) {
        after_h[h_i] = ensure_hierarchy(state.runtime.registry, .{ .id = before_ids[h_i] });
    }

    state.runtime.model_root_by_id.put(map_alloc, model_id, root_entity.id) catch {};

    var mesh_offset: u32 = 0;
    var m_i: u32 = 0;
    while (m_i < state.runtime.model_manager.model_count) : (m_i += 1) {
        const m = &state.runtime.model_manager.models.?[m_i];
        if (m.id == model_id) break;
        if (m.visible and !m.is_loading) mesh_offset += m.scene.mesh_count;
    }

    var node_to_entity = state.runtime.arena_allocator.alloc(u64, scene.all_node_count) catch return;
    @memset(node_to_entity, std.math.maxInt(u64));

    var i: u32 = 0;
    while (i < scene.all_node_count) : (i += 1) {
        if (scene.all_nodes.?[i]) |node| {
            const entity = state.runtime.registry.create() catch continue;
            node_to_entity[i] = entity.id;

            if (node.name) |name| {
                const name_comp = components.Name.init(std.mem.span(name));
                state.runtime.registry.add(entity, name_comp) catch {};
            }

            state.runtime.registry.add(entity, components.Node{ .type = .Node3D }) catch {};

            var transform = components.Transform{};
            const m = math.Mat4.fromArray(node.local_transform);
            const decomposed = m.decompose();
            transform.position = decomposed.t;
            transform.rotation = decomposed.r;
            transform.scale = decomposed.s;

            state.runtime.registry.add(entity, transform) catch {};

            if (node.mesh_count > 0 and node.mesh_indices != null) {
                var m_idx: u32 = 0;
                while (m_idx < node.mesh_count) : (m_idx += 1) {
                    const local_mesh_index = node.mesh_indices.?[m_idx];
                    const mesh_index = mesh_offset + local_mesh_index;

                    var target_entity = entity;
                    if (m_idx > 0) {
                        target_entity = state.runtime.registry.create() catch continue;
                        var child_name_buf: [64]u8 = undefined;
                        const parent_name = if (node.name) |n| std.mem.span(n) else "Mesh";
                        const child_name = std.fmt.bufPrint(&child_name_buf, "{s}:{d}", .{ parent_name, m_idx }) catch parent_name;
                        state.runtime.registry.add(target_entity, components.Name.init(child_name)) catch {};
                        state.runtime.registry.add(target_entity, components.Node{ .type = .MeshInstance3D }) catch {};
                        state.runtime.registry.add(target_entity, components.Transform{}) catch {};
                        node_factory.append_child(state.runtime.registry, entity, target_entity);
                    }

                    var material_index: u32 = 0;
                    if (scene.meshes) |meshes| {
                        if (local_mesh_index < scene.mesh_count) {
                            material_index = meshes[local_mesh_index].material_index;
                        }
                    }

                    const mesh_renderer = components.MeshRenderer{
                        .mesh = .{ .index = mesh_index, .generation = 0 },
                        .material = .{ .index = material_index, .generation = 0 },
                        .visible = true,
                        .cast_shadows = true,
                        .receive_shadows = true,
                    };

                    state.runtime.registry.add(target_entity, mesh_renderer) catch {};
                    if (m_idx == 0) {
                        if (state.runtime.registry.get(components.Node, entity)) |n| n.type = .MeshInstance3D;
                    }
                    state.runtime.mesh_owner_by_mesh_index.put(map_alloc, mesh_index, entity.id) catch {};
                    state.runtime.mesh_entity_by_mesh_index.put(map_alloc, mesh_index, target_entity.id) catch {};
                }
            }
        }
    }

    var node_ptr_to_index: std.AutoHashMapUnmanaged(*engine.scene.CardinalSceneNode, u32) = .{};
    defer node_ptr_to_index.deinit(map_alloc);

    i = 0;
    while (i < scene.all_node_count) : (i += 1) {
        if (scene.all_nodes.?[i]) |node| {
            node_ptr_to_index.put(map_alloc, node, i) catch {};
        }
    }

    i = 0;
    while (i < scene.all_node_count) : (i += 1) {
        if (scene.all_nodes.?[i]) |node| {
            const entity = engine.ecs_entity.Entity{ .id = node_to_entity[i] };
            if (entity.id == std.math.maxInt(u64)) continue;

            const parent_idx = engine.scene.resolve_parent_idx(node, &node_ptr_to_index);

            if (parent_idx != 0xFFFFFFFF) {
                const parent_id = node_to_entity[parent_idx];
                if (parent_id != std.math.maxInt(u64)) {
                    node_factory.append_child(state.runtime.registry, .{ .id = parent_id }, entity);
                } else {
                    node_factory.append_child(state.runtime.registry, root_entity, entity);
                }
            } else {
                node_factory.append_child(state.runtime.registry, root_entity, entity);
            }
        }
    }

    state.ui.undo.push_entity_subtree(state.runtime.registry, root_entity, .Create, before_ids[0..before_count], before_h[0..before_count], after_h[0..before_count]);
}

/// Cancels outstanding async loading tasks and clears the list.
pub fn cancel_loading_tasks(state: *EditorState, allocator: std.mem.Allocator) void {
    if (state.runtime.loading_tasks.items.len == 0) return;
    for (state.runtime.loading_tasks.items) |info| {
        _ = async_loader.cardinal_async_cancel_task(info.task);
        async_loader.cardinal_async_free_task(info.task);
        allocator.free(info.path);
    }
    state.runtime.loading_tasks.clearRetainingCapacity();
    state.runtime.is_loading = false;
}
