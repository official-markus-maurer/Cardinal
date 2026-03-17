//! Scene import/export helpers for the editor.
//!
//! Bridges engine scene graphs (loaded from files) into the editor ECS and provides basic save/load
//! entrypoints for the editor UI.
//!
//! TODO: Split import/export and async-model-loading into separate modules.
const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const scene_serializer = engine.scene_serializer;
const EditorState = @import("../editor_state.zig").EditorState;
const math = engine.math;
const components = engine.ecs_components;
const node_factory = engine.ecs_node_factory;
const async_loader = engine.async_loader;
const hierarchy_system = @import("hierarchy_system.zig");

/// Imports the currently loaded `state.combined_scene` into the ECS registry.
pub fn import_scene_graph(state: *EditorState) void {
    const scene = &state.runtime.combined_scene;
    if (scene.all_nodes == null or scene.all_node_count == 0) return;
    const map_alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    log.cardinal_log_info("[SCENE_IO] Importing {d} nodes to ECS...", .{scene.all_node_count});

    var node_to_entity = state.runtime.arena_allocator.alloc(u64, scene.all_node_count) catch return;
    @memset(node_to_entity, std.math.maxInt(u64));

    var node_base_offsets = state.runtime.arena_allocator.alloc(u32, scene.all_node_count) catch return;
    var node_mesh_offsets = state.runtime.arena_allocator.alloc(u32, scene.all_node_count) catch return;
    @memset(node_base_offsets, 0);
    @memset(node_mesh_offsets, 0);

    if (state.runtime.model_manager.models) |models| {
        var node_cursor: u32 = 0;
        var mesh_cursor: u32 = 0;
        var m_i: u32 = 0;
        while (m_i < state.runtime.model_manager.model_count) : (m_i += 1) {
            const model = &models[m_i];
            if (!model.visible or model.is_loading) continue;

            var n_i: u32 = 0;
            while (n_i < model.scene.all_node_count and node_cursor + n_i < scene.all_node_count) : (n_i += 1) {
                node_base_offsets[node_cursor + n_i] = node_cursor;
                node_mesh_offsets[node_cursor + n_i] = mesh_cursor;
            }

            node_cursor += model.scene.all_node_count;
            mesh_cursor += model.scene.mesh_count;
        }

        if (node_cursor != scene.all_node_count or mesh_cursor != scene.mesh_count) {
            @memset(node_base_offsets, 0);
            @memset(node_mesh_offsets, 0);
        }
    }

    var i: u32 = 0;
    while (i < scene.all_node_count) : (i += 1) {
        if (scene.all_nodes.?[i]) |node| {
            const entity = state.runtime.registry.create() catch |err| {
                log.cardinal_log_error("Failed to create entity: {}", .{err});
                continue;
            };
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
                    const mesh_index = node_mesh_offsets[i] + local_mesh_index;
                    if (mesh_index >= scene.mesh_count) continue;

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
                        if (mesh_index < scene.mesh_count) {
                            material_index = meshes[mesh_index].material_index;
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

            if (node.light_index >= 0) {
                if (scene.lights) |lights| {
                    if (@as(u32, @intCast(node.light_index)) < scene.light_count) {
                        const l = lights[@as(u32, @intCast(node.light_index))];

                        const light_comp = components.Light{
                            .type = switch (l.type) {
                                .DIRECTIONAL => .Directional,
                                .POINT => .Point,
                                .SPOT => .Spot,
                            },
                            .color = math.Vec3.fromArray(l.color),
                            .intensity = l.intensity,
                            .range = l.range,
                            .inner_cone_angle = l.inner_cone_angle,
                            .outer_cone_angle = l.outer_cone_angle,
                            .cast_shadows = true,
                        };

                        state.runtime.registry.add(entity, light_comp) catch {};
                    }
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

            var parent_idx: u32 = 0xFFFFFFFF;
            if (node.parent) |parent| {
                if (node_ptr_to_index.get(parent)) |idx| {
                    parent_idx = idx;
                }
            } else if (node.parent_index >= 0) {
                const local_parent_idx: u32 = @intCast(node.parent_index);
                const base = node_base_offsets[i];
                if (base + local_parent_idx < scene.all_node_count) {
                    parent_idx = base + local_parent_idx;
                }
            }

            if (parent_idx != 0xFFFFFFFF) {
                const parent_id = node_to_entity[parent_idx];
                if (parent_id != std.math.maxInt(u64)) {
                    const parent_entity = engine.ecs_entity.Entity{ .id = parent_id };
                    node_factory.append_child(state.runtime.registry, parent_entity, entity);
                }
            }
        }
    }

    log.cardinal_log_info("[SCENE_IO] Imported {d} nodes to ECS.", .{scene.all_node_count});
}

/// Serializes the current ECS registry and model manager to a scene file.
pub fn save_scene(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        log.cardinal_log_error("Failed to create scene file '{s}': {}", .{ path, err });
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Failed to save scene", .{}) catch {};
        return;
    };
    defer file.close();

    var serializer = scene_serializer.SceneSerializer.init(allocator, state.runtime.registry, &state.runtime.model_manager);
    defer serializer.deinit();

    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);

    const cwd = std.fs.cwd();
    const root_path = cwd.realpathAlloc(allocator, ".") catch null;
    defer if (root_path) |p| allocator.free(p);

    serializer.serialize(buffer.writer(allocator), root_path) catch |err| {
        log.cardinal_log_error("Failed to serialize scene: {}", .{err});
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Failed to save scene", .{}) catch {};
        return;
    };

    file.writeAll(buffer.items) catch |err| {
        log.cardinal_log_error("Failed to write scene to file: {}", .{err});
        return;
    };

    log.cardinal_log_info("[EDITOR] Scene saved to {s}", .{path});
    _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Scene saved to {s}", .{path}) catch {};
}

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

    const root_entity = state.runtime.registry.create() catch return;
    const root_name = if (model.name) |n| std.mem.span(n) else "Model";
    var root_name_buf: [320]u8 = undefined;
    const root_name_full = std.fmt.bufPrint(&root_name_buf, "Model: {s}", .{root_name}) catch root_name;
    state.runtime.registry.add(root_entity, components.Name.init(root_name_full)) catch {};
    state.runtime.registry.add(root_entity, components.Node{ .type = .Node3D }) catch {};
    state.runtime.registry.add(root_entity, components.Transform{}) catch {};
    state.runtime.registry.add(root_entity, components.Hierarchy{}) catch {};
    node_factory.append_child(state.runtime.registry, parent_entity, root_entity);
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
}

fn get_model_combined_mesh_range(state: *EditorState, model_id: u32) ?struct { start: u32, count: u32 } {
    if (state.runtime.model_manager.models == null) return null;
    const models = state.runtime.model_manager.models.?;

    var offset: u32 = 0;
    var i: u32 = 0;
    while (i < state.runtime.model_manager.model_count) : (i += 1) {
        const m = &models[i];
        if (!m.visible or m.is_loading) continue;
        if (m.id == model_id) return .{ .start = offset, .count = m.scene.mesh_count };
        offset += m.scene.mesh_count;
    }
    return null;
}

fn remove_entity_subtree(state: *EditorState, root: engine.ecs_entity.Entity) void {
    hierarchy_system.remove_entity_subtree(state, root);
}

fn ascend_to_top_root(state: *EditorState, entity: engine.ecs_entity.Entity) engine.ecs_entity.Entity {
    var current = entity;
    var guard: u32 = 0;
    while (guard < 2048) : (guard += 1) {
        const h = state.runtime.registry.get(components.Hierarchy, current) orelse break;
        const p = h.parent orelse break;
        current = p;
    }
    return current;
}

fn rebase_mesh_maps_and_components(state: *EditorState, start: u32, count: u32) void {
    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const end = start + count;

    var view = state.runtime.registry.view(components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        const mr = entry.component;
        if (mr.mesh.index >= end) {
            mr.mesh.index -= count;
        }
    }

    var new_owner: std.AutoHashMapUnmanaged(u32, u64) = .{};
    var owner_it = state.runtime.mesh_owner_by_mesh_index.iterator();
    while (owner_it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (k >= start and k < end) continue;
        const nk = if (k >= end) k - count else k;
        new_owner.put(alloc, nk, v) catch {};
    }
    state.runtime.mesh_owner_by_mesh_index.deinit(alloc);
    state.runtime.mesh_owner_by_mesh_index = new_owner;

    var new_ent: std.AutoHashMapUnmanaged(u32, u64) = .{};
    var ent_it = state.runtime.mesh_entity_by_mesh_index.iterator();
    while (ent_it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (k >= start and k < end) continue;
        const nk = if (k >= end) k - count else k;
        new_ent.put(alloc, nk, v) catch {};
    }
    state.runtime.mesh_entity_by_mesh_index.deinit(alloc);
    state.runtime.mesh_entity_by_mesh_index = new_ent;
}

pub fn remove_model_entities_and_rebase(state: *EditorState, model_id: u32) void {
    const range = get_model_combined_mesh_range(state, model_id) orelse return;
    if (range.count == 0) return;
    const start = range.start;
    const count = range.count;
    const end = start + count;

    if (state.runtime.model_root_by_id.get(model_id)) |root_id| {
        remove_entity_subtree(state, .{ .id = root_id });
        _ = state.runtime.model_root_by_id.remove(model_id);
        rebase_mesh_maps_and_components(state, start, count);
        return;
    }

    const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var roots: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer roots.deinit(alloc);

    var mesh_idx: u32 = start;
    while (mesh_idx < end) : (mesh_idx += 1) {
        const owner_id = state.runtime.mesh_owner_by_mesh_index.get(mesh_idx) orelse state.runtime.mesh_entity_by_mesh_index.get(mesh_idx);
        if (owner_id == null) continue;
        const root = ascend_to_top_root(state, .{ .id = owner_id.? });
        roots.put(alloc, root.id, {}) catch {};
    }

    var root_it = roots.iterator();
    while (root_it.next()) |entry| {
        remove_entity_subtree(state, .{ .id = entry.key_ptr.* });
    }

    rebase_mesh_maps_and_components(state, start, count);
}

/// Cancels outstanding async loading tasks and clears the list.
fn cancel_loading_tasks(state: *EditorState, allocator: std.mem.Allocator) void {
    if (state.runtime.loading_tasks.items.len == 0) return;
    for (state.runtime.loading_tasks.items) |info| {
        _ = async_loader.cardinal_async_cancel_task(info.task);
        async_loader.cardinal_async_free_task(info.task);
        allocator.free(info.path);
    }
    state.runtime.loading_tasks.clearRetainingCapacity();
    state.runtime.is_loading = false;
}

/// Resets runtime state prior to deserializing a new scene.
fn reset_state_for_scene_load(state: *EditorState, allocator: std.mem.Allocator) void {
    state.runtime.scene_upload_pending = false;
    state.runtime.pending_scene = std.mem.zeroes(@TypeOf(state.runtime.pending_scene));
    state.ui.undo.clear();

    {
        var it = state.runtime.terrain_data_by_entity.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.height_handle != std.math.maxInt(u32)) {
                engine.vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, entry.value_ptr.height_handle);
            }
            if (entry.value_ptr.splat_handle != std.math.maxInt(u32)) {
                engine.vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, entry.value_ptr.splat_handle);
            }
            for (entry.value_ptr.layer_handles) |h| {
                if (h != std.math.maxInt(u32)) {
                    engine.vulkan_renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, h);
                }
            }
            allocator.free(entry.value_ptr.height);
            allocator.free(entry.value_ptr.splat);
        }
        state.runtime.terrain_data_by_entity.clearRetainingCapacity();
    }

    state.runtime.registry.deinit();
    state.runtime.registry.* = engine.ecs_registry.Registry.init(allocator);
    state.runtime.transform_overrides.clearRetainingCapacity();
    state.runtime.mesh_owner_by_mesh_index.clearRetainingCapacity();
    state.runtime.mesh_entity_by_mesh_index.clearRetainingCapacity();

    engine.model_manager.cardinal_model_manager_destroy(&state.runtime.model_manager);
    _ = engine.model_manager.cardinal_model_manager_init(&state.runtime.model_manager);
    state.runtime.combined_scene = std.mem.zeroes(@TypeOf(state.runtime.combined_scene));
    state.runtime.scene_loaded = false;
}

/// Updates `combined_scene` after deserialization by querying the model manager.
fn refresh_combined_scene_after_deserialize(state: *EditorState) void {
    if (engine.model_manager.cardinal_model_manager_get_combined_scene(&state.runtime.model_manager)) |combined| {
        state.runtime.combined_scene = combined.*;
        state.runtime.scene_loaded = (state.runtime.combined_scene.mesh_count > 0);
    }
}

pub fn load_scene(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        log.cardinal_log_error("Failed to open scene file '{s}': {}", .{ path, err });
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Failed to load scene (file not found)", .{}) catch {};
        return;
    };
    defer file.close();

    cancel_loading_tasks(state, allocator);
    reset_state_for_scene_load(state, allocator);

    var serializer = scene_serializer.SceneSerializer.init(allocator, state.runtime.registry, &state.runtime.model_manager);
    defer serializer.deinit();

    const content = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |err| {
        log.cardinal_log_error("Failed to read scene file: {}", .{err});
        return;
    };
    defer allocator.free(content);

    const cwd = std.fs.cwd();
    const root_path = cwd.realpathAlloc(allocator, ".") catch null;
    defer if (root_path) |p| allocator.free(p);

    var fbs = std.io.fixedBufferStream(content);
    serializer.deserialize(fbs.reader(), root_path) catch |err| {
        log.cardinal_log_error("Failed to deserialize scene: {}", .{err});
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Failed to load scene (parse error)", .{}) catch {};
        return;
    };

    refresh_combined_scene_after_deserialize(state);

    const hierarchy_count = state.runtime.registry.view(components.Hierarchy).count();
    if (hierarchy_count == 0 and state.runtime.model_manager.model_count > 0) {
        import_scene_graph(state);
    }

    if (state.runtime.combined_scene.mesh_count > 0) {
        state.runtime.pending_scene = state.runtime.combined_scene;
        state.runtime.scene_upload_pending = true;
        log.cardinal_log_info("[EDITOR] Scene loaded from {s}", .{path});
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Scene loaded from {s}", .{path}) catch {};
    } else {
        log.cardinal_log_error("[EDITOR] Scene loaded but no meshes: {s}", .{path});
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Scene loaded but no meshes (missing assets?)", .{}) catch {};
    }
}

/// Clears `available_scenes` and frees owned strings.
fn clear_available_scenes(state: *EditorState, allocator: std.mem.Allocator) void {
    for (state.ui.available_scenes.items) |item| {
        allocator.free(item);
    }
    state.ui.available_scenes.clearRetainingCapacity();
}

pub fn refresh_available_scenes(state: *EditorState, allocator: std.mem.Allocator) void {
    clear_available_scenes(state, allocator);

    const scenes_dir = "assets/scenes";
    var dir = std.fs.cwd().openDir(scenes_dir, .{ .iterate = true }) catch |err| {
        log.cardinal_log_warn("Failed to open scenes directory: {}", .{err});
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            const name_copy = allocator.dupeZ(u8, entry.name) catch continue;
            state.ui.available_scenes.append(allocator, name_copy) catch {
                allocator.free(name_copy);
                continue;
            };
        }
    }
}
