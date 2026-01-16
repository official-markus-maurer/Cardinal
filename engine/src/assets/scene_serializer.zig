const std = @import("std");
const registry_pkg = @import("../ecs/registry.zig");
const entity_pkg = @import("../ecs/entity.zig");
const components = @import("../ecs/components.zig");
const math = @import("../core/math.zig");
const model_manager_pkg = @import("model_manager.zig");
const transform_math = @import("../core/transform.zig");

const serializer_log = std.log.scoped(.scene_serializer);

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
        // Nothing to deinit currently, but good practice to have
    }

    pub fn serialize(self: *SceneSerializer, writer: anytype, root_path: ?[]const u8) !void {
        var json_writer = JsonWriter(@TypeOf(writer)).init(self.allocator, writer);
        defer json_writer.deinit();

        try json_writer.beginObject();
        try json_writer.objectField("version");
        try json_writer.write(2);

        // Serialize Models
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

        // Iterate alive entities
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

                // Serialize Name
                if (self.registry.get(components.Name, entity)) |name| {
                    try json_writer.objectField("Name");
                    try serializeName(&json_writer, name);
                }

                // Serialize Hierarchy
                if (self.registry.get(components.Hierarchy, entity)) |hierarchy| {
                    try json_writer.objectField("Hierarchy");
                    try serializeHierarchy(&json_writer, hierarchy);
                }

                // Serialize Transform
                if (self.registry.get(components.Transform, entity)) |transform| {
                    try json_writer.objectField("Transform");
                    try serializeTransform(&json_writer, transform);
                }

                // Serialize MeshRenderer
                if (self.registry.get(components.MeshRenderer, entity)) |mesh_renderer| {
                    try json_writer.objectField("MeshRenderer");
                    try serializeMeshRenderer(&json_writer, mesh_renderer);
                }

                // Serialize Light
                if (self.registry.get(components.Light, entity)) |light| {
                    try json_writer.objectField("Light");
                    try serializeLight(&json_writer, light);
                }

                // Serialize Camera
                if (self.registry.get(components.Camera, entity)) |camera| {
                    try json_writer.objectField("Camera");
                    try serializeCamera(&json_writer, camera);
                }

                // Serialize Script
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
        serializer_log.info("instantiateScene start", .{});
        const root = data.parsed.value;
        serializer_log.info("Root tag: {any}", .{root});
        const root_path = data.root_path;

        if (root != .object) {
            serializer_log.err("Root is not object", .{});
            return error.InvalidSceneFormat;
        }

        // Check version
        if (root.object.get("version")) |ver| {
            if (ver.integer > 2) return error.UnsupportedVersion;
        }

        var total_mesh_count: u32 = 0;

        // Deserialize Models
        if (self.model_manager) |mgr| {
            if (root.object.get("models")) |models_val| {
                if (models_val == .array) {
                    serializer_log.info("Found {d} models to load", .{models_val.array.items.len});
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

                                // Load model (blocking)
                                serializer_log.info("Loading model: {s}", .{path_slice});
                                const model_id = model_manager_pkg.cardinal_model_manager_load_model(mgr, path_z.ptr, null);
                                serializer_log.info("Model loaded. ID: {d}", .{model_id});

                                if (model_id != 0) {
                                    // Apply transform and visibility
                                    const model_idx = model_manager_pkg.find_model_index(mgr, model_id);
                                    if (model_idx >= 0 and mgr.models != null) {
                                        var model = &mgr.models.?[@intCast(model_idx)];

                                        if (model_val.object.get("visible")) |v| model.visible = v.bool;
                                        if (model_val.object.get("transform")) |t| {
                                            model.transform = try deserializeMat4(t);
                                        }

                                        // Mark scene dirty to ensure rebuild
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

        // Calculate total mesh count for validation
        serializer_log.info("Calculating total mesh count...", .{});
        if (self.model_manager) |mgr| {
             if (mgr.models) |models| {
                 var i: u32 = 0;
                 while (i < mgr.model_count) : (i += 1) {
                     serializer_log.info("Model {d} mesh count: {d}", .{i, models[i].scene.mesh_count});
                     total_mesh_count += models[i].scene.mesh_count;
                 }
             }
        }
        serializer_log.info("Total mesh count: {d}", .{total_mesh_count});

        if (root.object.get("entities")) |entities| {
            if (entities != .array) {
                serializer_log.err("Invalid entities format: expected array", .{});
                return error.InvalidSceneFormat;
            }

            // First pass: Create entities and build ID map
            var id_map = std.AutoHashMap(u32, entity_pkg.Entity).init(self.allocator);
            defer id_map.deinit();

            // Store created entities to add components in second pass
            const CreatedEntity = struct {
                entity: entity_pkg.Entity,
                val: std.json.Value,
            };
            var created_entities = std.ArrayListUnmanaged(CreatedEntity){};
            defer created_entities.deinit(self.allocator);

            for (entities.array.items) |entity_val| {
                if (entity_val != .object) continue;

                const entity = try self.registry.create();

                if (entity_val.object.get("id")) |id_val| {
                    if (id_val == .integer) {
                        try id_map.put(@intCast(id_val.integer), entity);
                    }
                }

                try created_entities.append(self.allocator, .{ .entity = entity, .val = entity_val });
            }

            // Second pass: Add components
            for (created_entities.items) |item| {
                const entity = item.entity;
                const entity_val = item.val;

                if (entity_val.object.get("components")) |comps| {
                    if (comps != .object) continue;

                    if (comps.object.get("Name")) |val| {
                        if (deserializeName(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Name component to entity {d}: {}", .{entity.index(), e});
                        } else |err| {
                            serializer_log.err("Failed to deserialize Name for entity {d}: {}", .{entity.index(), err});
                        }
                    }

                    if (comps.object.get("Transform")) |val| {
                        if (deserializeTransform(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Transform component to entity {d}: {}", .{entity.index(), e});
                        } else |err| {
                            serializer_log.err("Failed to deserialize Transform for entity {d}: {}", .{entity.index(), err});
                        }
                    }

                    if (comps.object.get("Hierarchy")) |val| {
                        if (deserializeHierarchy(val, &id_map)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Hierarchy component to entity {d}: {}", .{entity.index(), e});
                        } else |err| {
                            serializer_log.err("Failed to deserialize Hierarchy for entity {d}: {}", .{entity.index(), err});
                        }
                    }

                    if (comps.object.get("MeshRenderer")) |val| {
                        if (deserializeMeshRenderer(val)) |comp| {
                            // Validate mesh index
                            if (comp.mesh.index < total_mesh_count) {
                                self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add MeshRenderer component to entity {d}: {}", .{entity.index(), e});
                            } else {
                                serializer_log.warn("Skipping MeshRenderer for entity {d}: mesh_id {d} out of bounds (total meshes: {d})", .{entity.index(), comp.mesh.index, total_mesh_count});
                            }
                        } else |err| {
                            serializer_log.err("Failed to deserialize MeshRenderer for entity {d}: {}", .{entity.index(), err});
                        }
                    }

                    if (comps.object.get("Light")) |val| {
                        if (deserializeLight(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Light component to entity {d}: {}", .{entity.index(), e});
                        } else |err| {
                            serializer_log.err("Failed to deserialize Light for entity {d}: {}", .{entity.index(), err});
                        }
                    }

                    if (comps.object.get("Camera")) |val| {
                        if (deserializeCamera(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Camera component to entity {d}: {}", .{entity.index(), e});
                        } else |err| {
                            serializer_log.err("Failed to deserialize Camera for entity {d}: {}", .{entity.index(), err});
                        }
                    }

                    if (comps.object.get("Script")) |val| {
                        if (deserializeScript(val)) |comp| {
                            self.registry.add(entity, comp) catch |e| serializer_log.err("Failed to add Script component to entity {d}: {}", .{entity.index(), e});
                        } else |err| {
                            serializer_log.err("Failed to deserialize Script for entity {d}: {}", .{entity.index(), err});
                        }
                    }
                }
            }
        }
    }

    pub fn deserialize(self: *SceneSerializer, reader: anytype, root_path: ?[]const u8) !void {
        serializer_log.info("deserialize start", .{});
        const json_content = try reader.readAllAlloc(self.allocator, std.math.maxInt(usize));
        serializer_log.info("json read. len={d}", .{json_content.len});
        // We do NOT defer free json_content here; it's passed to loadSceneData which stores it in ParsedScene.
        // ParsedScene.deinit will free it.
        errdefer self.allocator.free(json_content);

        var data = try loadSceneData(self.allocator, json_content, root_path);
        defer data.deinit();

        serializer_log.info("loadSceneData done.", .{});
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
