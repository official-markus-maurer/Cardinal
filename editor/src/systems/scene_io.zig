const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const scene_serializer = engine.scene_serializer;
const EditorState = @import("../editor_state.zig").EditorState;
const math = engine.math;
const components = engine.ecs_components;

pub fn import_scene_graph(state: *EditorState) void {
    const scene = &state.combined_scene;
    if (scene.all_nodes == null or scene.all_node_count == 0) return;

    log.cardinal_log_info("[SCENE_IO] Importing {d} nodes to ECS...", .{scene.all_node_count});

    // Map from scene node index to Entity ID
    var node_to_entity = state.arena_allocator.alloc(u64, scene.all_node_count) catch return;
    @memset(node_to_entity, std.math.maxInt(u64));

    var i: u32 = 0;
    while (i < scene.all_node_count) : (i += 1) {
        if (scene.all_nodes.?[i]) |node| {
            // Create Entity
            const entity = state.registry.create() catch |err| {
                log.cardinal_log_error("Failed to create entity: {}", .{err});
                continue;
            };
            node_to_entity[i] = entity.id;

            // Name
            if (node.name) |name| {
                const name_comp = components.Name.init(std.mem.span(name));
                state.registry.add(entity, name_comp) catch {};
            }

            // Transform
            var transform = components.Transform{};
            const m = math.Mat4.fromArray(node.world_transform);
            const decomposed = m.decompose();
            transform.position = decomposed.t;
            transform.rotation = decomposed.r;
            transform.scale = decomposed.s;

            state.registry.add(entity, transform) catch {};

            // MeshRenderer
            if (node.mesh_count > 0 and node.mesh_indices != null) {
                var m_idx: u32 = 0;
                while (m_idx < node.mesh_count) : (m_idx += 1) {
                    const mesh_index = node.mesh_indices.?[m_idx];

                    var target_entity = entity;
                    if (m_idx > 0) {
                        target_entity = state.registry.create() catch continue;
                        state.registry.add(target_entity, transform) catch {};
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

                    state.registry.add(target_entity, mesh_renderer) catch {};
                }
            }

            // Light
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

                        state.registry.add(entity, light_comp) catch {};
                    }
                }
            }
        }
    }

    // Second pass: Build Hierarchy
    i = 0;
    while (i < scene.all_node_count) : (i += 1) {
        if (scene.all_nodes.?[i]) |node| {
            const entity = engine.ecs_entity.Entity{ .id = node_to_entity[i] };
            if (entity.id == std.math.maxInt(u64)) continue;

            var parent_idx: u32 = 0xFFFFFFFF;
            if (node.parent_index >= 0) {
                parent_idx = @intCast(node.parent_index);
            } else if (node.parent) |parent| {
                // Fallback search (slow, O(N))
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
                    // Add Hierarchy component
                    var hierarchy = if (state.registry.get(components.Hierarchy, entity)) |h| h.* else components.Hierarchy{};
                    hierarchy.parent = parent_entity;
                    state.registry.add(entity, hierarchy) catch {};

                    // Update parent's hierarchy
                    var parent_hierarchy = if (state.registry.get(components.Hierarchy, parent_entity)) |h| h.* else components.Hierarchy{};

                    // Link as child
                    if (parent_hierarchy.first_child) |first_child_entity| {
                        // Find last child
                        var curr_entity = first_child_entity;
                        while (true) {
                            if (state.registry.get(components.Hierarchy, curr_entity)) |h| {
                                if (h.next_sibling) |next| {
                                    curr_entity = next;
                                } else {
                                    // Link new entity as next sibling of last child
                                    var last_h = h.*;
                                    last_h.next_sibling = entity;
                                    state.registry.add(curr_entity, last_h) catch {};

                                    // Set prev sibling of new entity
                                    hierarchy.prev_sibling = curr_entity;
                                    state.registry.add(entity, hierarchy) catch {};
                                    break;
                                }
                            } else {
                                break;
                            }
                        }
                    } else {
                        // First child
                        parent_hierarchy.first_child = entity;
                    }

                    parent_hierarchy.child_count += 1;
                    state.registry.add(parent_entity, parent_hierarchy) catch {};
                }
            }
        }
    }

    log.cardinal_log_info("[SCENE_IO] Imported {d} nodes to ECS.", .{scene.all_node_count});
}

pub fn save_scene(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    // Ensure directory exists if path contains directory separators
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        log.cardinal_log_error("Failed to create scene file '{s}': {}", .{ path, err });
        _ = std.fmt.bufPrintZ(&state.status_msg, "Failed to save scene", .{}) catch {};
        return;
    };
    defer file.close();

    var serializer = scene_serializer.SceneSerializer.init(allocator, state.registry, &state.model_manager);
    defer serializer.deinit();

    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);

    const cwd = std.fs.cwd();
    const root_path = cwd.realpathAlloc(allocator, ".") catch null;
    defer if (root_path) |p| allocator.free(p);

    serializer.serialize(buffer.writer(allocator), root_path) catch |err| {
        log.cardinal_log_error("Failed to serialize scene: {}", .{err});
        _ = std.fmt.bufPrintZ(&state.status_msg, "Failed to save scene", .{}) catch {};
        return;
    };

    file.writeAll(buffer.items) catch |err| {
        log.cardinal_log_error("Failed to write scene to file: {}", .{err});
        return;
    };

    log.cardinal_log_info("[EDITOR] Scene saved to {s}", .{path});
    _ = std.fmt.bufPrintZ(&state.status_msg, "Scene saved to {s}", .{path}) catch {};
}

pub fn load_scene(state: *EditorState, allocator: std.mem.Allocator, path: []const u8) void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        log.cardinal_log_error("Failed to open scene file '{s}': {}", .{ path, err });
        _ = std.fmt.bufPrintZ(&state.status_msg, "Failed to load scene (file not found)", .{}) catch {};
        return;
    };
    defer file.close();

    // Reset Registry
    state.registry.deinit();
    state.registry.* = engine.ecs_registry.Registry.init(allocator);

    // Reset Model Manager
    engine.model_manager.cardinal_model_manager_destroy(&state.model_manager);
    _ = engine.model_manager.cardinal_model_manager_init(&state.model_manager);

    var serializer = scene_serializer.SceneSerializer.init(allocator, state.registry, &state.model_manager);
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
        _ = std.fmt.bufPrintZ(&state.status_msg, "Failed to load scene (parse error)", .{}) catch {};
        return;
    };

    // Force rebuild of combined scene and update editor state
    if (engine.model_manager.cardinal_model_manager_get_combined_scene(&state.model_manager)) |combined| {
        state.combined_scene = combined.*;
        state.scene_loaded = true;
    }

    // Check if we need to generate hierarchy
    const hierarchy_count = state.registry.view(components.Hierarchy).count();
    if (hierarchy_count == 0 and state.model_manager.model_count > 0) {
        import_scene_graph(state);
    }

    // Schedule upload to renderer
    state.pending_scene = state.combined_scene;
    state.scene_upload_pending = true;

    log.cardinal_log_info("[EDITOR] Scene loaded from {s}", .{path});
    _ = std.fmt.bufPrintZ(&state.status_msg, "Scene loaded from {s}", .{path}) catch {};
}

pub fn refresh_available_scenes(state: *EditorState, allocator: std.mem.Allocator) void {
    // Clear existing
    for (state.available_scenes.items) |item| {
        allocator.free(item);
    }
    state.available_scenes.clearRetainingCapacity();

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
            state.available_scenes.append(allocator, name_copy) catch {
                allocator.free(name_copy);
                continue;
            };
        }
    }
}
