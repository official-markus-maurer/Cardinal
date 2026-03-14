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

/// Imports the currently loaded `state.combined_scene` into the ECS registry.
pub fn import_scene_graph(state: *EditorState) void {
    const scene = &state.runtime.combined_scene;
    if (scene.all_nodes == null or scene.all_node_count == 0) return;
    const map_alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

    log.cardinal_log_info("[SCENE_IO] Importing {d} nodes to ECS...", .{scene.all_node_count});

    var node_to_entity = state.runtime.arena_allocator.alloc(u64, scene.all_node_count) catch return;
    @memset(node_to_entity, std.math.maxInt(u64));

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
                    const mesh_index = node.mesh_indices.?[m_idx];

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

    // TODO: Avoid O(N^2) fallback search by building a pointer->index map.
    i = 0;
    while (i < scene.all_node_count) : (i += 1) {
        if (scene.all_nodes.?[i]) |node| {
            const entity = engine.ecs_entity.Entity{ .id = node_to_entity[i] };
            if (entity.id == std.math.maxInt(u64)) continue;

            var parent_idx: u32 = 0xFFFFFFFF;
            if (node.parent_index >= 0) {
                parent_idx = @intCast(node.parent_index);
            } else if (node.parent) |parent| {
                var k: u32 = 0;
                while (k < scene.all_node_count) : (k += 1) {
                    if (scene.all_nodes.?[k] == parent) {
                        parent_idx = k;
                        break;
                    }
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

    var mesh_offset: u32 = 0;
    var m_i: u32 = 0;
    while (m_i < state.runtime.model_manager.model_count) : (m_i += 1) {
        const m = &state.runtime.model_manager.models.?[m_i];
        if (m.id == model_id) break;
        mesh_offset += m.scene.mesh_count;
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

    i = 0;
    while (i < scene.all_node_count) : (i += 1) {
        if (scene.all_nodes.?[i]) |node| {
            const entity = engine.ecs_entity.Entity{ .id = node_to_entity[i] };
            if (entity.id == std.math.maxInt(u64)) continue;

            if (node.parent_index >= 0) {
                const parent_id = node_to_entity[@intCast(node.parent_index)];
                if (parent_id != std.math.maxInt(u64)) {
                    node_factory.append_child(state.runtime.registry, .{ .id = parent_id }, entity);
                }
            } else {
                node_factory.append_child(state.runtime.registry, parent_entity, entity);
            }
        }
    }
}

pub fn load_scene(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        log.cardinal_log_error("Failed to open scene file '{s}': {}", .{ path, err });
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Failed to load scene (file not found)", .{}) catch {};
        return;
    };
    defer file.close();

    if (state.runtime.loading_tasks.items.len > 0) {
        for (state.runtime.loading_tasks.items) |info| {
            _ = async_loader.cardinal_async_cancel_task(info.task);
            async_loader.cardinal_async_free_task(info.task);
            allocator.free(info.path);
        }
        state.runtime.loading_tasks.clearRetainingCapacity();
        state.runtime.is_loading = false;
    }

    state.runtime.scene_upload_pending = false;
    state.runtime.pending_scene = std.mem.zeroes(@TypeOf(state.runtime.pending_scene));
    state.ui.undo.clear();

    // Reset Registry
    state.runtime.registry.deinit();
    state.runtime.registry.* = engine.ecs_registry.Registry.init(allocator);
    state.runtime.transform_overrides.clearRetainingCapacity();
    state.runtime.mesh_owner_by_mesh_index.clearRetainingCapacity();
    state.runtime.mesh_entity_by_mesh_index.clearRetainingCapacity();

    // Reset Model Manager
    engine.model_manager.cardinal_model_manager_destroy(&state.runtime.model_manager);
    _ = engine.model_manager.cardinal_model_manager_init(&state.runtime.model_manager);
    state.runtime.combined_scene = std.mem.zeroes(@TypeOf(state.runtime.combined_scene));
    state.runtime.scene_loaded = false;

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

    // Force rebuild of combined scene and update editor state
    if (engine.model_manager.cardinal_model_manager_get_combined_scene(&state.runtime.model_manager)) |combined| {
        state.runtime.combined_scene = combined.*;
        state.runtime.scene_loaded = (state.runtime.combined_scene.mesh_count > 0);
    }

    // Check if we need to generate hierarchy
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

pub fn refresh_available_scenes(state: *EditorState, allocator: std.mem.Allocator) void {
    // Clear existing
    for (state.ui.available_scenes.items) |item| {
        allocator.free(item);
    }
    state.ui.available_scenes.clearRetainingCapacity();

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
