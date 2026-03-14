//! ECS scene serialization and parsing.
//!
//! Writes engine state (models + ECS entities/components) to a stable JSON representation and can
//! parse it back. Intended for editor save/load workflows.
//!
//! TODO: Split component serializers into per-component modules to reduce file size and rebuild time.
const std = @import("std");
const registry_pkg = @import("../ecs/registry.zig");
const entity_pkg = @import("../ecs/entity.zig");
const components = @import("../ecs/components.zig");
const math = @import("../core/math.zig");
const model_manager_pkg = @import("model_manager.zig");
const scene_pkg = @import("scene.zig");
const transform_math = @import("../core/transform.zig");

const serializer_log = std.log.scoped(.scene_serializer);

/// JSON serializer for the ECS registry (and optional model manager state).
pub const SceneSerializer = struct {
    allocator: std.mem.Allocator,
    registry: *registry_pkg.Registry,
    model_manager: ?*model_manager_pkg.CardinalModelManager,

    pub fn init(allocator: std.mem.Allocator, registry: *registry_pkg.Registry, model_manager: ?*model_manager_pkg.CardinalModelManager) SceneSerializer {
        return .{
            .allocator = allocator,
            .registry = registry,
            .model_manager = model_manager,
        };
    }

    pub fn deinit(self: *SceneSerializer) void {
        _ = self;
    }

    /// Writes a JSON scene description to `writer`.
    pub fn serialize(self: *SceneSerializer, writer: anytype, root_path: ?[]const u8) !void {
        var json_writer = JsonWriter(@TypeOf(writer)).init(self.allocator, writer);
        defer json_writer.deinit();

        try json_writer.beginObject();
        try json_writer.objectField("version");
        try json_writer.write(3);

        if (self.model_manager) |mgr| {
            try json_writer.objectField("models");
            try json_writer.beginArray();
            if (mgr.models) |models| {
                var i: u32 = 0;
                while (i < mgr.model_count) : (i += 1) {
                    const model = &models[i];
                    try json_writer.beginObject();

                    try json_writer.objectField("file_path");
                    if (model.file_path) |path| {
                        const path_slice = std.mem.span(path);
                        if (root_path) |root| {
                            const rel_path = try std.fs.path.relative(self.allocator, root, path_slice);
                            defer self.allocator.free(rel_path);
                            try json_writer.write(rel_path);
                        } else {
                            try json_writer.write(path_slice);
                        }
                    } else {
                        try json_writer.write(null);
                    }

                    try json_writer.objectField("visible");
                    try json_writer.write(model.visible);

                    try json_writer.objectField("transform");
                    try serializeMat4(&json_writer, model.transform);

                    try json_writer.endObject();
                }
            }
            try json_writer.endArray();
        }

        try json_writer.objectField("entities");
        try json_writer.beginArray();

        const handle_mgr = &self.registry.entity_manager.handles;
        const total_slots = handle_mgr.generations.items.len;

        var is_free = try self.allocator.alloc(bool, total_slots);
        defer self.allocator.free(is_free);
        @memset(is_free, false);

        for (handle_mgr.free_indices.items) |free_idx| {
            if (free_idx < total_slots) {
                is_free[free_idx] = true;
            }
        }

        var i: u32 = 0;
        while (i < total_slots) : (i += 1) {
            if (!is_free[i]) {
                const gen = handle_mgr.generations.items[i];
                const entity = entity_pkg.Entity.make(i, gen);

                try json_writer.beginObject();

                try json_writer.objectField("id");
                try json_writer.write(entity.index());

                try json_writer.objectField("components");
                try json_writer.beginObject();

                if (self.registry.get(components.Name, entity)) |name| {
                    try json_writer.objectField("Name");
                    try serializeName(&json_writer, name);
                }

                if (self.registry.get(components.Hierarchy, entity)) |hierarchy| {
                    try json_writer.objectField("Hierarchy");
                    try serializeHierarchy(&json_writer, hierarchy);
                }

                if (self.registry.get(components.Transform, entity)) |transform| {
                    try json_writer.objectField("Transform");
                    try serializeTransform(&json_writer, transform);
                }

                if (self.registry.get(components.Node, entity)) |node| {
                    try json_writer.objectField("Node");
                    try serializeNode(&json_writer, node);
                }

                if (self.registry.get(components.MeshRenderer, entity)) |mesh_renderer| {
                    try json_writer.objectField("MeshRenderer");
                    try serializeMeshRenderer(&json_writer, mesh_renderer);
                }

                if (self.registry.get(components.Skybox, entity)) |skybox| {
                    try json_writer.objectField("Skybox");
                    try serializeSkybox(&json_writer, self.allocator, skybox, root_path);
                }

                if (self.registry.get(components.Light, entity)) |light| {
                    try json_writer.objectField("Light");
                    try serializeLight(&json_writer, light);
                }

                if (self.registry.get(components.Camera, entity)) |camera| {
                    try json_writer.objectField("Camera");
                    try serializeCamera(&json_writer, camera);
                }

                if (self.registry.get(components.Script, entity)) |script| {
                    try json_writer.objectField("Script");
                    try serializeScript(&json_writer, script);
                }

                try json_writer.endObject(); // components
                try json_writer.endObject(); // entity
            }
        }

        try json_writer.endArray(); // entities
        try json_writer.endObject(); // root
    }

    pub const ParsedScene = struct {
        parsed: std.json.Parsed(std.json.Value),
        root_path: ?[]const u8,
        allocator: std.mem.Allocator,
        json_content: ?[]u8 = null,

        pub fn deinit(self: *ParsedScene) void {
            self.parsed.deinit();
            if (self.root_path) |p| self.allocator.free(p);
            if (self.json_content) |c| self.allocator.free(c);
        }
    };

    pub fn loadSceneData(allocator: std.mem.Allocator, json_content: []u8, root_path: ?[]const u8) !ParsedScene {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});

        var root_path_copy: ?[]const u8 = null;
        if (root_path) |p| {
            root_path_copy = try allocator.dupe(u8, p);
        }

        return ParsedScene{
            .parsed = parsed,
            .root_path = root_path_copy,
            .allocator = allocator,
            .json_content = json_content,
        };
    }

    pub fn instantiateScene(self: *SceneSerializer, data: *ParsedScene) !void {
        const root = data.parsed.value;
        const root_path = data.root_path;

        if (root != .object) {
            return error.InvalidSceneFormat;
        }

        const version = if (root.object.get("version")) |ver| ver.integer else 0;
        if (version < 2) {
            return error.UnsupportedVersion;
        }
        if (version > 3) return error.UnsupportedVersion;

        var total_mesh_count: u32 = 0;

        if (self.model_manager) |mgr| {
            if (root.object.get("models")) |models_val| {
                if (models_val == .array) {
                    for (models_val.array.items) |model_val| {
                        if (model_val != .object) continue;

                        if (model_val.object.get("file_path")) |path_val| {
                            if (path_val == .string) {
                                const path_slice = path_val.string;
                                var full_path: []u8 = undefined;
                                var needs_free = false;

                                if (root_path) |root_dir| {
                                    if (!std.fs.path.isAbsolute(path_slice)) {
                                        full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ root_dir, path_slice });
                                        needs_free = true;
                                    } else {
                                        full_path = try self.allocator.dupe(u8, path_slice);
                                        needs_free = true;
                                    }
                                } else {
                                    full_path = try self.allocator.dupe(u8, path_slice);
                                    needs_free = true;
                                }
                                defer if (needs_free) self.allocator.free(full_path);

                                const path_z = try self.allocator.dupeZ(u8, full_path);
                                defer self.allocator.free(path_z);

                                const model_id = model_manager_pkg.cardinal_model_manager_load_model(mgr, path_z.ptr, null);

                                if (model_id != 0) {
                                    const model_idx = model_manager_pkg.find_model_index(mgr, model_id);
                                    if (model_idx >= 0 and mgr.models != null) {
                                        var model = &mgr.models.?[@intCast(model_idx)];

                                        if (model_val.object.get("visible")) |v| model.visible = v.bool;
                                        if (model_val.object.get("transform")) |t| {
                                            model.transform = try deserializeMat4(t);
                                        }

                                        mgr.scene_dirty = true;
                                    }
                                } else {
                                    serializer_log.err("Failed to load model: {s}", .{path_slice});
                                }
                            }
                        }
                    }
                }
            }
        }

        if (self.model_manager) |mgr| {
            if (mgr.models) |models| {
                var i: u32 = 0;
                while (i < mgr.model_count) : (i += 1) {
                    total_mesh_count += models[i].scene.mesh_count;
                }
            }
        }

        if (root.object.get("entities")) |entities| {
            if (entities != .array) {
                serializer_log.err("Invalid entities format: expected array", .{});
                return error.InvalidSceneFormat;
            }

            var id_map = std.AutoHashMap(u32, entity_pkg.Entity).init(self.allocator);
            defer id_map.deinit();

            const CreatedEntity = struct {
                entity: entity_pkg.Entity,
                val: std.json.Value,
            };
            var created_entities = std.ArrayListUnmanaged(CreatedEntity){};
            defer created_entities.deinit(self.allocator);
            var created_entity_handles = std.ArrayListUnmanaged(entity_pkg.Entity){};
            defer created_entity_handles.deinit(self.allocator);
            var entity_has_components = std.ArrayListUnmanaged(bool){};
            defer entity_has_components.deinit(self.allocator);

            for (entities.array.items) |entity_val| {
                if (entity_val != .object) continue;

                const entity = try self.registry.create();

                if (entity_val.object.get("id")) |id_val| {
                    if (id_val == .integer) {
                        try id_map.put(@intCast(id_val.integer), entity);
                    }
                }

                try created_entities.append(self.allocator, .{ .entity = entity, .val = entity_val });
                try created_entity_handles.append(self.allocator, entity);
                try entity_has_components.append(self.allocator, false);
            }

            // Second pass: Add components
            for (created_entities.items, 0..) |item, idx| {
                const entity = item.entity;
                const entity_val = item.val;

                if (entity_val.object.get("components")) |comps| {
                    if (comps != .object) continue;
                    var has_any = false;

                    if (comps.object.get("Name")) |val| {
                        has_any = true;
                        if (deserializeName(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Name component to entity {d}: {}", .{ entity.index(), e });
                        } else |err| {
                            serializer_log.err("Failed to deserialize Name for entity {d}: {}", .{ entity.index(), err });
                        }
                    }

                    if (comps.object.get("Transform")) |val| {
                        has_any = true;
                        if (deserializeTransform(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Transform component to entity {d}: {}", .{ entity.index(), e });
                        } else |err| {
                            serializer_log.err("Failed to deserialize Transform for entity {d}: {}", .{ entity.index(), err });
                        }
                    }

                    if (comps.object.get("Hierarchy")) |val| {
                        has_any = true;
                        if (deserializeHierarchy(val, &id_map)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Hierarchy component to entity {d}: {}", .{ entity.index(), e });
                        } else |err| {
                            serializer_log.err("Failed to deserialize Hierarchy for entity {d}: {}", .{ entity.index(), err });
                        }
                    }

                    if (comps.object.get("Node")) |val| {
                        has_any = true;
                        if (deserializeNode(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Node component to entity {d}: {}", .{ entity.index(), e });
                        } else |err| {
                            serializer_log.err("Failed to deserialize Node for entity {d}: {}", .{ entity.index(), err });
                        }
                    }

                    if (comps.object.get("MeshRenderer")) |val| {
                        has_any = true;
                        if (deserializeMeshRenderer(val)) |comp| {
                            // Validate mesh index
                            if (comp.mesh.index < total_mesh_count) {
                                self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add MeshRenderer component to entity {d}: {}", .{ entity.index(), e });
                            } else {
                                serializer_log.warn("Skipping MeshRenderer for entity {d}: mesh_id {d} out of bounds (total meshes: {d})", .{ entity.index(), comp.mesh.index, total_mesh_count });
                            }
                        } else |err| {
                            serializer_log.err("Failed to deserialize MeshRenderer for entity {d}: {}", .{ entity.index(), err });
                        }
                    }

                    if (comps.object.get("Skybox")) |val| {
                        has_any = true;
                        if (deserializeSkybox(self.allocator, val, root_path)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Skybox component to entity {d}: {}", .{ entity.index(), e });
                        } else |err| {
                            serializer_log.err("Failed to deserialize Skybox for entity {d}: {}", .{ entity.index(), err });
                        }
                    }

                    if (comps.object.get("Light")) |val| {
                        has_any = true;
                        if (deserializeLight(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Light component to entity {d}: {}", .{ entity.index(), e });
                        } else |err| {
                            serializer_log.err("Failed to deserialize Light for entity {d}: {}", .{ entity.index(), err });
                        }
                    }

                    if (comps.object.get("Camera")) |val| {
                        has_any = true;
                        if (deserializeCamera(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Camera component to entity {d}: {}", .{ entity.index(), e });
                        } else |err| {
                            serializer_log.err("Failed to deserialize Camera for entity {d}: {}", .{ entity.index(), err });
                        }
                    }

                    if (comps.object.get("Script")) |val| {
                        has_any = true;
                        if (deserializeScript(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Script component to entity {d}: {}", .{ entity.index(), e });
                        } else |err| {
                            serializer_log.err("Failed to deserialize Script for entity {d}: {}", .{ entity.index(), err });
                        }
                    }

                    entity_has_components.items[idx] = has_any;
                }
            }

            var referenced_as_parent = std.AutoHashMapUnmanaged(u64, void){};
            defer referenced_as_parent.deinit(self.allocator);

            for (created_entity_handles.items) |ent| {
                if (self.registry.get(components.Hierarchy, ent)) |h| {
                    if (h.parent) |p| {
                        referenced_as_parent.put(self.allocator, p.id, {}) catch {};
                    }
                }
            }

            var kept_entities = std.ArrayListUnmanaged(entity_pkg.Entity){};
            defer kept_entities.deinit(self.allocator);

            for (created_entity_handles.items, 0..) |ent, idx| {
                if (entity_has_components.items[idx] or referenced_as_parent.contains(ent.id)) {
                    kept_entities.append(self.allocator, ent) catch {};
                } else {
                    self.registry.destroy(ent);
                }
            }

            self.postprocess_loaded_entities(kept_entities.items);
        }
    }

    pub fn deserialize(self: *SceneSerializer, reader: anytype, root_path: ?[]const u8) !void {
        const json_content = try reader.readAllAlloc(self.allocator, std.math.maxInt(usize));
        // We do NOT defer free json_content here; it's passed to loadSceneData which stores it in ParsedScene.
        // ParsedScene.deinit will free it.
        errdefer self.allocator.free(json_content);

        var data = try loadSceneData(self.allocator, json_content, root_path);
        defer data.deinit();

        try self.instantiateScene(&data);
    }

    // Helpers
    fn serializeVec3(writer: anytype, v: math.Vec3) !void {
        var buf: [128]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "[{d}, {d}, {d}]", .{ v.x, v.y, v.z });
        try writer.writeRaw(str);
    }

    fn serializeMat4(writer: anytype, m: [16]f32) !void {
        var buf: [512]u8 = undefined;
        // Condensed format: [m0, m1, ..., m15]
        const str = try std.fmt.bufPrint(&buf, "[{d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}]", .{ m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15] });
        try writer.writeRaw(str);
    }

    fn deserializeVec3(val: std.json.Value) !math.Vec3 {
        if (val != .array or val.array.items.len < 3) return error.InvalidFormat;
        return math.Vec3{
            .x = try jsonToF32(val.array.items[0]),
            .y = try jsonToF32(val.array.items[1]),
            .z = try jsonToF32(val.array.items[2]),
        };
    }

    fn serializeQuat(writer: anytype, q: math.Quat) !void {
        var buf: [128]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "[{d}, {d}, {d}, {d}]", .{ q.x, q.y, q.z, q.w });
        try writer.writeRaw(str);
    }

    fn deserializeQuat(val: std.json.Value) !math.Quat {
        if (val != .array or val.array.items.len < 4) return error.InvalidFormat;
        return math.Quat{
            .x = try jsonToF32(val.array.items[0]),
            .y = try jsonToF32(val.array.items[1]),
            .z = try jsonToF32(val.array.items[2]),
            .w = try jsonToF32(val.array.items[3]),
        };
    }

    fn deserializeMat4(val: std.json.Value) ![16]f32 {
        if (val != .array or val.array.items.len < 16) return error.InvalidFormat;
        var m: [16]f32 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            m[i] = try jsonToF32(val.array.items[i]);
        }
        return m;
    }

    fn serializeTransform(writer: anytype, t: *components.Transform) !void {
        try writer.beginObject();
        try writer.objectField("position");
        try serializeVec3(writer, t.position);
        try writer.objectField("rotation");
        try serializeQuat(writer, t.rotation);
        try writer.objectField("scale");
        try serializeVec3(writer, t.scale);
        try writer.endObject();
    }

    fn deserializeTransform(val: std.json.Value) !components.Transform {
        var t = components.Transform{};
        if (val.object.get("position")) |p| t.position = try deserializeVec3(p);
        if (val.object.get("rotation")) |r| t.rotation = try deserializeQuat(r);
        if (val.object.get("scale")) |s| t.scale = try deserializeVec3(s);
        return t;
    }

    fn serializeMeshRenderer(writer: anytype, mr: *components.MeshRenderer) !void {
        try writer.beginObject();
        try writer.objectField("mesh_id");
        try writer.write(mr.mesh.index); // Assuming simple ID serialization for now
        try writer.objectField("material_id");
        try writer.write(mr.material.index);
        try writer.objectField("visible");
        try writer.write(mr.visible);
        try writer.objectField("cast_shadows");
        try writer.write(mr.cast_shadows);
        try writer.objectField("receive_shadows");
        try writer.write(mr.receive_shadows);
        try writer.endObject();
    }

    fn deserializeMeshRenderer(val: std.json.Value) !components.MeshRenderer {
        var mr = components.MeshRenderer{
            .mesh = .{ .index = 0, .generation = 0 }, // Invalid defaults
            .material = .{ .index = 0, .generation = 0 },
        };

        if (val.object.get("mesh_id")) |id| mr.mesh.index = @intCast(id.integer);
        if (val.object.get("material_id")) |id| mr.material.index = @intCast(id.integer);
        if (val.object.get("visible")) |v| mr.visible = v.bool;
        if (val.object.get("cast_shadows")) |v| mr.cast_shadows = v.bool;
        if (val.object.get("receive_shadows")) |v| mr.receive_shadows = v.bool;
        return mr;
    }

    fn serializeLight(writer: anytype, l: *components.Light) !void {
        try writer.beginObject();
        try writer.objectField("type");
        try writer.write(@intFromEnum(l.type));
        try writer.objectField("color");
        try serializeVec3(writer, l.color);
        try writer.objectField("intensity");
        try writer.write(l.intensity);
        try writer.objectField("range");
        try writer.write(l.range);
        try writer.objectField("inner_cone_angle");
        try writer.write(l.inner_cone_angle);
        try writer.objectField("outer_cone_angle");
        try writer.write(l.outer_cone_angle);
        try writer.objectField("cast_shadows");
        try writer.write(l.cast_shadows);
        try writer.endObject();
    }

    fn deserializeLight(val: std.json.Value) !components.Light {
        var l = components.Light{ .type = .Directional };
        if (val.object.get("type")) |t| l.type = @enumFromInt(t.integer);
        if (val.object.get("color")) |c| l.color = try deserializeVec3(c);
        if (val.object.get("intensity")) |i| l.intensity = try jsonToF32(i);
        if (val.object.get("range")) |r| l.range = try jsonToF32(r);
        if (val.object.get("inner_cone_angle")) |a| l.inner_cone_angle = try jsonToF32(a);
        if (val.object.get("outer_cone_angle")) |a| l.outer_cone_angle = try jsonToF32(a);
        if (val.object.get("cast_shadows")) |cs| l.cast_shadows = cs.bool;
        return l;
    }

    fn jsonToF32(val: std.json.Value) !f32 {
        return switch (val) {
            .float => |v| @floatCast(v),
            .integer => |v| @floatFromInt(v),
            else => error.InvalidFormat,
        };
    }

    fn serializeCamera(writer: anytype, c: *components.Camera) !void {
        try writer.beginObject();
        try writer.objectField("type");
        try writer.write(@intFromEnum(c.type));
        try writer.objectField("fov");
        try writer.write(c.fov);
        try writer.objectField("aspect_ratio");
        try writer.write(c.aspect_ratio);
        try writer.objectField("near_plane");
        try writer.write(c.near_plane);
        try writer.objectField("far_plane");
        try writer.write(c.far_plane);
        try writer.objectField("ortho_size");
        try writer.write(c.ortho_size);
        try writer.endObject();
    }

    fn deserializeCamera(val: std.json.Value) !components.Camera {
        var c = components.Camera{ .type = .Perspective };
        if (val.object.get("type")) |t| c.type = @enumFromInt(t.integer);
        if (val.object.get("fov")) |v| c.fov = try jsonToF32(v);
        if (val.object.get("aspect_ratio")) |v| c.aspect_ratio = try jsonToF32(v);
        if (val.object.get("near_plane")) |v| c.near_plane = try jsonToF32(v);
        if (val.object.get("far_plane")) |v| c.far_plane = try jsonToF32(v);
        if (val.object.get("ortho_size")) |v| c.ortho_size = try jsonToF32(v);
        return c;
    }

    fn serializeScript(writer: anytype, s: *components.Script) !void {
        try writer.beginObject();
        try writer.objectField("script_id");
        try writer.write(s.script_id);
        // data and on_update cannot be trivially serialized
        try writer.endObject();
    }

    fn deserializeScript(val: std.json.Value) !components.Script {
        var s = components.Script{};
        if (val.object.get("script_id")) |id| s.script_id = @intCast(id.integer);
        return s;
    }

    fn serializeName(writer: anytype, n: *components.Name) !void {
        try writer.write(n.slice());
    }

    fn deserializeName(val: std.json.Value) !components.Name {
        if (val != .string) return error.InvalidFormat;
        return components.Name.init(val.string);
    }

    fn serializeNode(writer: anytype, n: *components.Node) !void {
        try writer.beginObject();
        try writer.objectField("type");
        try writer.write(@tagName(n.type));
        try writer.endObject();
    }

    fn deserializeNode(val: std.json.Value) !components.Node {
        var n = components.Node{};
        if (val != .object) return error.InvalidFormat;
        if (val.object.get("type")) |t| {
            switch (t) {
                .string => |s| {
                    if (std.meta.stringToEnum(components.NodeType, s)) |nt| {
                        n.type = nt;
                    } else {
                        return error.InvalidFormat;
                    }
                },
                .integer => |i| n.type = @enumFromInt(i),
                else => return error.InvalidFormat,
            }
        }
        return n;
    }

    fn serializeSkybox(writer: anytype, allocator: std.mem.Allocator, s: *components.Skybox, root_path: ?[]const u8) !void {
        const path_slice = s.slice();
        if (path_slice.len == 0) {
            try writer.write("");
            return;
        }

        if (root_path) |root| {
            if (std.fs.path.isAbsolute(path_slice)) {
                const rel = std.fs.path.relative(allocator, root, path_slice) catch {
                    try writer.write(path_slice);
                    return;
                };
                defer allocator.free(rel);
                try writer.write(rel);
                return;
            }
        }

        try writer.write(path_slice);
    }

    fn deserializeSkybox(allocator: std.mem.Allocator, val: std.json.Value, root_path: ?[]const u8) !components.Skybox {
        if (val != .string) return error.InvalidFormat;
        const path_slice = val.string;
        if (path_slice.len == 0) return components.Skybox{};

        if (root_path) |root| {
            if (!std.fs.path.isAbsolute(path_slice)) {
                const full = try std.fs.path.join(allocator, &[_][]const u8{ root, path_slice });
                defer allocator.free(full);
                return components.Skybox.init(full);
            }
        }

        return components.Skybox.init(path_slice);
    }

    fn postprocess_loaded_entities(self: *SceneSerializer, entities: []const entity_pkg.Entity) void {
        var entity_ids = std.AutoHashMapUnmanaged(u64, void){};
        defer entity_ids.deinit(self.allocator);

        var node_by_name = std.StringHashMapUnmanaged(*scene_pkg.CardinalSceneNode){};
        defer node_by_name.deinit(self.allocator);
        var mesh_name_by_index = std.AutoHashMapUnmanaged(u32, []const u8){};
        defer mesh_name_by_index.deinit(self.allocator);

        const combined_scene: ?*const scene_pkg.CardinalScene = if (self.model_manager) |mgr| model_manager_pkg.cardinal_model_manager_get_combined_scene(mgr) else null;
        if (combined_scene) |scn| {
            if (scn.all_nodes) |nodes| {
                var n: u32 = 0;
                while (n < scn.all_node_count) : (n += 1) {
                    const node_opt = nodes[n];
                    if (node_opt == null) continue;
                    const node = node_opt.?;
                    if (node.name == null) continue;

                    const name = std.mem.span(node.name.?);
                    node_by_name.put(self.allocator, name, node) catch {};

                    if (node.mesh_count > 0 and node.mesh_indices != null) {
                        var m: u32 = 0;
                        while (m < node.mesh_count) : (m += 1) {
                            const mesh_index = node.mesh_indices.?[m];
                            if (!mesh_name_by_index.contains(mesh_index)) {
                                mesh_name_by_index.put(self.allocator, mesh_index, name) catch {};
                            }
                        }
                    }
                }
            }
        }

        const cap: u32 = if (entities.len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(entities.len);
        entity_ids.ensureTotalCapacity(self.allocator, cap) catch return;
        for (entities) |e| {
            entity_ids.putAssumeCapacity(e.id, {});
        }

        var i: usize = 0;
        while (i < entities.len) : (i += 1) {
            const ent = entities[i];

            if (self.registry.get(components.Transform, ent) == null) {
                self.registry.add(ent, components.Transform{}) catch {};
            }

            if (self.registry.get(components.Hierarchy, ent) == null) {
                self.registry.add(ent, components.Hierarchy{}) catch {};
            }

            const inferred = self.infer_node_type(ent);
            if (self.registry.get(components.Node, ent)) |node_ptr| {
                switch (node_ptr.type) {
                    .Node, .Node3D, .Node2D, .NodeUI => node_ptr.type = inferred,
                    else => {},
                }
            } else {
                self.registry.add(ent, components.Node{ .type = inferred }) catch {};
            }

            if (self.registry.get(components.Name, ent) == null) {
                var buf: [64]u8 = undefined;
                const name = self.suggest_entity_name(ent, i, &buf, &mesh_name_by_index);
                self.registry.add(ent, components.Name.init(name)) catch {};
            }

            if (combined_scene != null and self.registry.get(components.MeshRenderer, ent) == null) {
                const name_ptr = self.registry.get(components.Name, ent) orelse continue;
                const key = name_ptr.slice();
                if (node_by_name.get(key)) |node| {
                    if (node.mesh_count > 0 and node.mesh_indices != null and combined_scene.?.meshes != null) {
                        const meshes = combined_scene.?.meshes.?;
                        var mesh_idx_in_node: u32 = 0;
                        while (mesh_idx_in_node < node.mesh_count) : (mesh_idx_in_node += 1) {
                            const mesh_index = node.mesh_indices.?[mesh_idx_in_node];
                            if (mesh_index >= combined_scene.?.mesh_count) continue;

                            const material_index = meshes[mesh_index].material_index;
                            const mr = components.MeshRenderer{
                                .mesh = .{ .index = mesh_index, .generation = 0 },
                                .material = .{ .index = material_index, .generation = 0 },
                                .visible = true,
                                .cast_shadows = true,
                                .receive_shadows = true,
                            };

                            if (mesh_idx_in_node == 0) {
                                self.registry.add(ent, mr) catch {};
                                if (self.registry.get(components.Node, ent)) |node_ptr| {
                                    switch (node_ptr.type) {
                                        .Node, .Node3D, .Node2D, .NodeUI => node_ptr.type = .MeshInstance3D,
                                        else => {},
                                    }
                                }
                                break;
                            }
                        }
                    }
                }
            }
        }

        for (entities) |ent| {
            if (self.registry.get(components.Hierarchy, ent)) |h_ptr| {
                h_ptr.first_child = null;
                h_ptr.next_sibling = null;
                h_ptr.prev_sibling = null;
                h_ptr.child_count = 0;
                if (h_ptr.parent) |p| {
                    if (!entity_ids.contains(p.id)) {
                        h_ptr.parent = null;
                    }
                }
            }
        }

        var children = std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(entity_pkg.Entity)){};
        defer {
            var it = children.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            children.deinit(self.allocator);
        }

        for (entities) |ent| {
            const h_ptr = self.registry.get(components.Hierarchy, ent) orelse continue;
            const parent = h_ptr.parent orelse continue;

            const res = children.getOrPut(self.allocator, parent.id) catch continue;
            if (!res.found_existing) {
                res.value_ptr.* = .{};
            }
            res.value_ptr.append(self.allocator, ent) catch {};
        }

        var it = children.iterator();
        while (it.next()) |entry| {
            const parent_ent = entity_pkg.Entity{ .id = entry.key_ptr.* };
            const list = entry.value_ptr.*;
            if (list.items.len == 0) continue;

            const parent_h = self.registry.get(components.Hierarchy, parent_ent) orelse continue;
            parent_h.first_child = list.items[0];
            parent_h.child_count = @intCast(list.items.len);

            var idx: usize = 0;
            while (idx < list.items.len) : (idx += 1) {
                const child_ent = list.items[idx];
                const child_h = self.registry.get(components.Hierarchy, child_ent) orelse continue;
                child_h.parent = parent_ent;
                child_h.prev_sibling = if (idx > 0) list.items[idx - 1] else null;
                child_h.next_sibling = if (idx + 1 < list.items.len) list.items[idx + 1] else null;
            }
        }
    }

    fn infer_node_type(self: *SceneSerializer, entity: entity_pkg.Entity) components.NodeType {
        if (self.registry.get(components.Skybox, entity) != null) return .Skybox;
        if (self.registry.get(components.Light, entity)) |l| {
            return switch (l.type) {
                .Directional => .DirectionalLight3D,
                .Point => .PointLight3D,
                .Spot => .SpotLight3D,
            };
        }
        if (self.registry.get(components.Camera, entity)) |c| {
            return switch (c.type) {
                .Perspective => .Camera3D,
                .Orthographic => .Camera2D,
            };
        }
        if (self.registry.get(components.MeshRenderer, entity) != null) return .MeshInstance3D;
        if (self.registry.get(components.Transform, entity) != null) return .Node3D;
        return .Node;
    }

    fn suggest_entity_name(self: *SceneSerializer, entity: entity_pkg.Entity, idx: usize, buf: *[64]u8, mesh_name_by_index: *const std.AutoHashMapUnmanaged(u32, []const u8)) []const u8 {
        if (self.registry.get(components.Skybox, entity) != null) return "Skybox";

        if (self.registry.get(components.Light, entity)) |l| {
            return switch (l.type) {
                .Directional => "Directional Light",
                .Point => "Point Light",
                .Spot => "Spot Light",
            };
        }

        if (self.registry.get(components.Camera, entity)) |c| {
            return switch (c.type) {
                .Perspective => "Camera3D",
                .Orthographic => "Camera2D",
            };
        }

        if (self.registry.get(components.MeshRenderer, entity)) |mr| {
            if (mesh_name_by_index.get(mr.mesh.index)) |name| return name;
            return std.fmt.bufPrint(buf, "Mesh{d}", .{mr.mesh.index}) catch "Mesh";
        }

        if (self.registry.get(components.Script, entity) != null) {
            return std.fmt.bufPrint(buf, "Script{d}", .{idx}) catch "Script";
        }

        return std.fmt.bufPrint(buf, "Node{d}", .{idx}) catch "Node";
    }

    fn serializeHierarchy(writer: anytype, h: *components.Hierarchy) !void {
        try writer.beginObject();
        try writer.objectField("parent");
        if (h.parent) |p| try writer.write(p.index()) else try writer.write(null);
        try writer.objectField("first_child");
        if (h.first_child) |c| try writer.write(c.index()) else try writer.write(null);
        try writer.objectField("next_sibling");
        if (h.next_sibling) |s| try writer.write(s.index()) else try writer.write(null);
        try writer.objectField("prev_sibling");
        if (h.prev_sibling) |s| try writer.write(s.index()) else try writer.write(null);
        try writer.objectField("child_count");
        try writer.write(h.child_count);
        try writer.endObject();
    }

    fn deserializeHierarchy(val: std.json.Value, id_map: *std.AutoHashMap(u32, entity_pkg.Entity)) !components.Hierarchy {
        var h = components.Hierarchy{};
        if (val.object.get("parent")) |p| {
            if (p != .null) {
                const old_id: u32 = @intCast(p.integer);
                if (id_map.get(old_id)) |new_entity| {
                    h.parent = new_entity;
                } else {
                    // This is a normal warning, not a critical error that should crash or stop
                    serializer_log.warn("Hierarchy: parent ID {d} not found in map", .{old_id});
                }
            }
        }
        if (val.object.get("first_child")) |c| {
            if (c != .null) {
                const old_id: u32 = @intCast(c.integer);
                if (id_map.get(old_id)) |new_entity| {
                    h.first_child = new_entity;
                } else {
                    serializer_log.warn("Hierarchy: first_child ID {d} not found in map", .{old_id});
                }
            }
        }
        if (val.object.get("next_sibling")) |s| {
            if (s != .null) {
                const old_id: u32 = @intCast(s.integer);
                if (id_map.get(old_id)) |new_entity| {
                    h.next_sibling = new_entity;
                } else {
                    serializer_log.warn("Hierarchy: next_sibling ID {d} not found in map", .{old_id});
                }
            }
        }
        if (val.object.get("prev_sibling")) |s| {
            if (s != .null) {
                const old_id: u32 = @intCast(s.integer);
                if (id_map.get(old_id)) |new_entity| {
                    h.prev_sibling = new_entity;
                } else {
                    serializer_log.warn("Hierarchy: prev_sibling ID {d} not found in map", .{old_id});
                }
            }
        }
        if (val.object.get("child_count")) |c| h.child_count = @intCast(c.integer);
        return h;
    }
};

fn JsonWriter(comptime WriterType: type) type {
    return struct {
        const Scope = struct {
            is_array: bool,
            count: usize = 0,
        };

        writer: WriterType,
        allocator: std.mem.Allocator,
        stack: std.ArrayListUnmanaged(Scope) = .{},
        indent_level: u32 = 0,

        pub fn init(allocator: std.mem.Allocator, writer: WriterType) @This() {
            return .{
                .writer = writer,
                .allocator = allocator,
                .stack = .{},
            };
        }

        pub fn deinit(self: *@This()) void {
            self.stack.deinit(self.allocator);
        }

        fn writeIndent(self: *@This()) !void {
            try self.writer.writeByte('\n');
            var i: u32 = 0;
            while (i < self.indent_level) : (i += 1) {
                try self.writer.writeAll("  ");
            }
        }

        fn prepareWrite(self: *@This()) !void {
            if (self.stack.items.len == 0) return;
            var scope = &self.stack.items[self.stack.items.len - 1];
            if (scope.is_array) {
                if (scope.count > 0) try self.writer.writeAll(",");
                try self.writeIndent();
                scope.count += 1;
            }
        }

        pub fn beginObject(self: *@This()) !void {
            try self.prepareWrite();
            try self.writer.writeAll("{");
            try self.stack.append(self.allocator, .{ .is_array = false });
            self.indent_level += 1;
        }

        pub fn endObject(self: *@This()) !void {
            _ = self.stack.pop();
            self.indent_level -= 1;
            try self.writeIndent();
            try self.writer.writeAll("}");
        }

        pub fn beginArray(self: *@This()) !void {
            try self.prepareWrite();
            try self.writer.writeAll("[");
            try self.stack.append(self.allocator, .{ .is_array = true });
            self.indent_level += 1;
        }

        pub fn endArray(self: *@This()) !void {
            _ = self.stack.pop();
            self.indent_level -= 1;
            try self.writeIndent();
            try self.writer.writeAll("]");
        }

        pub fn objectField(self: *@This(), name: []const u8) !void {
            var scope = &self.stack.items[self.stack.items.len - 1];
            if (scope.count > 0) try self.writer.writeAll(",");
            try self.writeIndent();
            try self.writer.print("\"{s}\": ", .{name});
            scope.count += 1;
        }

        pub fn write(self: *@This(), val: anytype) !void {
            const T = @TypeOf(val);
            const info = @typeInfo(T);

            if (info == .optional) {
                if (val) |v| {
                    return self.write(v);
                } else {
                    try self.prepareWrite();
                    try self.writer.writeAll("null");
                    return;
                }
            }

            try self.prepareWrite();

            if (info == .null) {
                try self.writer.writeAll("null");
            } else if (info == .int or info == .comptime_int or info == .float or info == .comptime_float) {
                try self.writer.print("{d}", .{val});
            } else if (info == .bool) {
                try self.writer.print("{}", .{val});
            } else if (info == .@"enum") {
                try self.writer.print("{d}", .{@intFromEnum(val)});
            } else if ((info == .pointer and info.pointer.size == .slice and info.pointer.child == u8) or
                (info == .array and info.array.child == u8))
            {
                try self.writer.writeByte('"');
                for (val) |c| {
                    switch (c) {
                        '"' => try self.writer.writeAll("\\\""),
                        '\\' => try self.writer.writeAll("\\\\"),
                        '\n' => try self.writer.writeAll("\\n"),
                        '\r' => try self.writer.writeAll("\\r"),
                        '\t' => try self.writer.writeAll("\\t"),
                        else => try self.writer.writeByte(c),
                    }
                }
                try self.writer.writeByte('"');
            } else {
                try self.writer.print("\"{any}\"", .{val});
            }
        }

        pub fn writeRaw(self: *@This(), raw: []const u8) !void {
            try self.prepareWrite();
            try self.writer.writeAll(raw);
        }
    };
}

test "SceneSerializer instantiateScene rejects non-object root" {
    const allocator = std.testing.allocator;

    var registry = registry_pkg.Registry.init(allocator);
    defer registry.deinit();

    var serializer = SceneSerializer.init(allocator, &registry, null);

    const json_content = try allocator.dupe(u8, "\"hi\"");
    var data = try SceneSerializer.loadSceneData(allocator, json_content, null);
    defer data.deinit();

    try std.testing.expectError(error.InvalidSceneFormat, serializer.instantiateScene(&data));
}

test "SceneSerializer instantiateScene rejects unsupported version" {
    const allocator = std.testing.allocator;

    var registry = registry_pkg.Registry.init(allocator);
    defer registry.deinit();

    var serializer = SceneSerializer.init(allocator, &registry, null);

    const json_content = try allocator.dupe(u8, "{\"version\":1,\"entities\":[]}");
    var data = try SceneSerializer.loadSceneData(allocator, json_content, null);
    defer data.deinit();

    try std.testing.expectError(error.UnsupportedVersion, serializer.instantiateScene(&data));
}

test "SceneSerializer instantiateScene accepts empty scene" {
    const allocator = std.testing.allocator;

    var registry = registry_pkg.Registry.init(allocator);
    defer registry.deinit();

    var serializer = SceneSerializer.init(allocator, &registry, null);

    const json_content = try allocator.dupe(u8, "{\"version\":2,\"entities\":[]}");
    var data = try SceneSerializer.loadSceneData(allocator, json_content, null);
    defer data.deinit();

    try serializer.instantiateScene(&data);
}
