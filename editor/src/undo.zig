//! Editor undo/redo stack.
//!
//! Stores discrete commands plus "capture" helpers that coalesce drag interactions into one step.
//!
//! TODO: Replace fixed-size reparent snapshots with a dynamic adjacency snapshot.
const std = @import("std");
const engine = @import("cardinal_engine");
const components = engine.ecs_components;
const model_manager = engine.model_manager;
const renderer = engine.vulkan_renderer;
const vk = @import("c.zig").c;

fn allocator() std.mem.Allocator {
    return engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
}

/// Generic "before/after" component diff for a single entity.
fn EntityComponentCommand(comptime T: type) type {
    return struct {
        entity_id: u64,
        before_present: bool,
        after_present: bool,
        before: T,
        after: T,
    };
}

const SubtreeMode = enum {
    Create,
    Delete,
};

const SnapshotMask = packed struct(u16) {
    name: bool = false,
    transform: bool = false,
    node: bool = false,
    hierarchy: bool = false,
    mesh_renderer: bool = false,
    light: bool = false,
    camera: bool = false,
    skybox: bool = false,
    _pad: u8 = 0,
};

const EntitySnapshot = struct {
    entity_id: u64,
    mask: SnapshotMask,
    name: components.Name = undefined,
    transform: components.Transform = undefined,
    node: components.Node = undefined,
    hierarchy: components.Hierarchy = undefined,
    mesh_renderer: components.MeshRenderer = undefined,
    light: components.Light = undefined,
    camera: components.Camera = undefined,
    skybox: components.Skybox = undefined,
};

/// Snapshot-based subtree command used for create/delete undo.
const EntitySubtreeCommand = struct {
    mode: SubtreeMode,
    root_id: u64,
    entities: []EntitySnapshot,
    hierarchy_entity_ids: [6]u64,
    hierarchy_before: [6]components.Hierarchy,
    hierarchy_after: [6]components.Hierarchy,
    hierarchy_count: u8,
};

pub const TerrainMeshEditCommand = struct {
    model_id: u32,
    combined_mesh_index: u32,
    vertex_indices: []u32,
    before_y: []f32,
    after_y: []f32,
    before_color: [][4]f32,
    after_color: [][4]f32,
};

/// Undoable editor command.
pub const UndoCommand = union(enum) {
    EntityTransform: EntityComponentCommand(components.Transform),
    EntityName: EntityComponentCommand(components.Name),
    EntityNode: EntityComponentCommand(components.Node),
    EntityHierarchy: EntityComponentCommand(components.Hierarchy),
    EntityMeshRenderer: EntityComponentCommand(components.MeshRenderer),
    EntityLight: EntityComponentCommand(components.Light),
    EntityCamera: EntityComponentCommand(components.Camera),
    EntitySkybox: EntityComponentCommand(components.Skybox),
    EntityReparent: struct {
        entity_ids: [6]u64,
        before: [6]components.Hierarchy,
        after: [6]components.Hierarchy,
        count: u8,
    },
    EntitySubtree: *EntitySubtreeCommand,
    TerrainMeshEdit: *TerrainMeshEditCommand,
    ModelTransform: struct {
        model_id: u32,
        before: [16]f32,
        after: [16]f32,
    },
};

const Capture = union(enum) {
    EntityTransform: struct { entity_id: u64, before: components.Transform },
    EntityName: struct { entity_id: u64, before: components.Name },
    EntitySkybox: struct { entity_id: u64, before: components.Skybox },
    EntityLight: struct { entity_id: u64, before: components.Light },
    EntityCamera: struct { entity_id: u64, before: components.Camera },
    ModelTransform: struct { model_id: u32, before: [16]f32 },
};

pub const UndoState = struct {
    undo_stack: std.ArrayListUnmanaged(UndoCommand) = .{},
    redo_stack: std.ArrayListUnmanaged(UndoCommand) = .{},
    capture: ?Capture = null,

    /// Releases any heap-backed commands and clears stacks.
    pub fn deinit(self: *UndoState, alloc: std.mem.Allocator) void {
        free_stack_items(self.undo_stack.items);
        free_stack_items(self.redo_stack.items);
        self.undo_stack.deinit(alloc);
        self.redo_stack.deinit(alloc);
        self.capture = null;
    }

    /// Clears all undo/redo state.
    pub fn clear(self: *UndoState) void {
        free_stack_items(self.undo_stack.items);
        free_stack_items(self.redo_stack.items);
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
        self.capture = null;
    }

    /// Pushes a new undo command and clears redo.
    pub fn push(self: *UndoState, cmd: UndoCommand) void {
        self.undo_stack.append(allocator(), cmd) catch return;
        free_stack_items(self.redo_stack.items);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Applies the latest undo command and moves it to redo.
    pub fn undo(self: *UndoState, runtime: anytype) void {
        if (self.undo_stack.items.len == 0) return;
        const idx = self.undo_stack.items.len - 1;
        const cmd = self.undo_stack.items[idx];
        self.undo_stack.items.len = idx;

        apply(runtime, cmd, false);
        self.redo_stack.append(allocator(), cmd) catch {};
    }

    /// Applies the latest redo command and moves it back to undo.
    pub fn redo(self: *UndoState, runtime: anytype) void {
        if (self.redo_stack.items.len == 0) return;
        const idx = self.redo_stack.items.len - 1;
        const cmd = self.redo_stack.items[idx];
        self.redo_stack.items.len = idx;

        apply(runtime, cmd, true);
        self.undo_stack.append(allocator(), cmd) catch {};
    }

    pub fn begin_entity_transform(self: *UndoState, entity_id: u64, before: components.Transform) void {
        if (self.capture != null) return;
        self.capture = .{ .EntityTransform = .{ .entity_id = entity_id, .before = before } };
    }

    pub fn end_entity_transform(self: *UndoState, entity_id: u64, after: components.Transform) void {
        if (self.capture) |cap| {
            if (cap == .EntityTransform and cap.EntityTransform.entity_id == entity_id) {
                const before = cap.EntityTransform.before;
                self.capture = null;
                if (before.position.x == after.position.x and before.position.y == after.position.y and before.position.z == after.position.z and
                    before.scale.x == after.scale.x and before.scale.y == after.scale.y and before.scale.z == after.scale.z and
                    before.rotation.x == after.rotation.x and before.rotation.y == after.rotation.y and before.rotation.z == after.rotation.z and before.rotation.w == after.rotation.w)
                {
                    return;
                }
                self.push(.{ .EntityTransform = .{
                    .entity_id = entity_id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = after,
                } });
            }
        }
    }

    pub fn begin_entity_name(self: *UndoState, entity_id: u64, before: components.Name) void {
        if (self.capture != null) return;
        self.capture = .{ .EntityName = .{ .entity_id = entity_id, .before = before } };
    }

    pub fn end_entity_name(self: *UndoState, entity_id: u64, after: components.Name) void {
        if (self.capture) |cap| {
            if (cap == .EntityName and cap.EntityName.entity_id == entity_id) {
                const before = cap.EntityName.before;
                self.capture = null;
                if (std.mem.eql(u8, before.value[0..], after.value[0..])) return;
                self.push(.{ .EntityName = .{
                    .entity_id = entity_id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = after,
                } });
            }
        }
    }

    pub fn begin_entity_skybox(self: *UndoState, entity_id: u64, before: components.Skybox) void {
        if (self.capture != null) return;
        self.capture = .{ .EntitySkybox = .{ .entity_id = entity_id, .before = before } };
    }

    pub fn end_entity_skybox(self: *UndoState, entity_id: u64, after: components.Skybox) void {
        if (self.capture) |cap| {
            if (cap == .EntitySkybox and cap.EntitySkybox.entity_id == entity_id) {
                const before = cap.EntitySkybox.before;
                self.capture = null;
                if (std.mem.eql(u8, before.path[0..], after.path[0..])) return;
                self.push(.{ .EntitySkybox = .{
                    .entity_id = entity_id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = after,
                } });
            }
        }
    }

    pub fn begin_entity_light(self: *UndoState, entity_id: u64, before: components.Light) void {
        if (self.capture != null) return;
        self.capture = .{ .EntityLight = .{ .entity_id = entity_id, .before = before } };
    }

    pub fn end_entity_light(self: *UndoState, entity_id: u64, after: components.Light) void {
        if (self.capture) |cap| {
            if (cap == .EntityLight and cap.EntityLight.entity_id == entity_id) {
                const before = cap.EntityLight.before;
                self.capture = null;
                if (std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&after))) return;
                self.push(.{ .EntityLight = .{
                    .entity_id = entity_id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = after,
                } });
            }
        }
    }

    pub fn begin_entity_camera(self: *UndoState, entity_id: u64, before: components.Camera) void {
        if (self.capture != null) return;
        self.capture = .{ .EntityCamera = .{ .entity_id = entity_id, .before = before } };
    }

    pub fn end_entity_camera(self: *UndoState, entity_id: u64, after: components.Camera) void {
        if (self.capture) |cap| {
            if (cap == .EntityCamera and cap.EntityCamera.entity_id == entity_id) {
                const before = cap.EntityCamera.before;
                self.capture = null;
                if (std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&after))) return;
                self.push(.{ .EntityCamera = .{
                    .entity_id = entity_id,
                    .before_present = true,
                    .after_present = true,
                    .before = before,
                    .after = after,
                } });
            }
        }
    }

    pub fn capture_entity_subtree(self: *UndoState, registry: *engine.ecs_registry.Registry, root: engine.ecs_entity.Entity) ?[]EntitySnapshot {
        _ = self;
        const alloc = allocator();

        var entities: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
        defer entities.deinit(alloc);

        collect_subtree_entities(registry, root, &entities);
        if (entities.items.len == 0) return null;

        const snaps = alloc.alloc(EntitySnapshot, entities.items.len) catch {
            return null;
        };

        for (entities.items, 0..) |e, i| {
            snaps[i] = snapshot_entity(registry, e);
        }

        return snaps;
    }

    pub fn push_entity_subtree_snapshots(self: *UndoState, root_id: u64, mode: SubtreeMode, snaps: []EntitySnapshot, hierarchy_entity_ids: []const u64, hierarchy_before: []const components.Hierarchy, hierarchy_after: []const components.Hierarchy) void {
        const alloc = allocator();
        const cmd_ptr = alloc.create(EntitySubtreeCommand) catch {
            alloc.free(snaps);
            return;
        };
        errdefer alloc.destroy(cmd_ptr);

        var ids_arr: [6]u64 = [_]u64{0} ** 6;
        var before_arr: [6]components.Hierarchy = undefined;
        var after_arr: [6]components.Hierarchy = undefined;
        const count: u8 = @min(@as(u8, @intCast(hierarchy_entity_ids.len)), @as(u8, 6));
        var j: u8 = 0;
        while (j < count) : (j += 1) {
            ids_arr[j] = hierarchy_entity_ids[j];
            before_arr[j] = hierarchy_before[j];
            after_arr[j] = hierarchy_after[j];
        }

        cmd_ptr.* = .{
            .mode = mode,
            .root_id = root_id,
            .entities = snaps,
            .hierarchy_entity_ids = ids_arr,
            .hierarchy_before = before_arr,
            .hierarchy_after = after_arr,
            .hierarchy_count = count,
        };

        self.undo_stack.append(alloc, .{ .EntitySubtree = cmd_ptr }) catch {
            alloc.free(snaps);
            alloc.destroy(cmd_ptr);
            return;
        };
        free_stack_items(self.redo_stack.items);
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn push_entity_subtree(self: *UndoState, registry: *engine.ecs_registry.Registry, root: engine.ecs_entity.Entity, mode: SubtreeMode, hierarchy_entity_ids: []const u64, hierarchy_before: []const components.Hierarchy, hierarchy_after: []const components.Hierarchy) void {
        const snaps = self.capture_entity_subtree(registry, root) orelse return;
        self.push_entity_subtree_snapshots(root.id, mode, snaps, hierarchy_entity_ids, hierarchy_before, hierarchy_after);
    }

    pub fn begin_model_transform(self: *UndoState, model_id: u32, before: [16]f32) void {
        if (self.capture != null) return;
        self.capture = .{ .ModelTransform = .{ .model_id = model_id, .before = before } };
    }

    pub fn end_model_transform(self: *UndoState, model_id: u32, after: [16]f32) void {
        if (self.capture) |cap| {
            if (cap == .ModelTransform and cap.ModelTransform.model_id == model_id) {
                const before = cap.ModelTransform.before;
                self.capture = null;
                if (std.mem.eql(f32, before[0..], after[0..])) return;
                self.push(.{ .ModelTransform = .{ .model_id = model_id, .before = before, .after = after } });
            }
        }
    }
};

fn apply(runtime: anytype, cmd: UndoCommand, forward: bool) void {
    switch (cmd) {
        .EntityTransform => |c| apply_entity_component(runtime, components.Transform, c, forward),
        .EntityName => |c| apply_entity_component(runtime, components.Name, c, forward),
        .EntityNode => |c| apply_entity_component(runtime, components.Node, c, forward),
        .EntityHierarchy => |c| apply_entity_component(runtime, components.Hierarchy, c, forward),
        .EntityMeshRenderer => |c| apply_entity_component(runtime, components.MeshRenderer, c, forward),
        .EntityLight => |c| apply_entity_component(runtime, components.Light, c, forward),
        .EntityCamera => |c| apply_entity_component(runtime, components.Camera, c, forward),
        .EntitySkybox => |c| apply_entity_component(runtime, components.Skybox, c, forward),
        .EntityReparent => |r| {
            const src = if (forward) r.after else r.before;
            var i: u8 = 0;
            while (i < r.count) : (i += 1) {
                const ent = engine.ecs_entity.Entity{ .id = r.entity_ids[i] };
                if (!runtime.registry.entity_manager.is_alive(ent)) continue;
                runtime.registry.add(ent, src[i]) catch {};
            }
        },
        .EntitySubtree => |p| apply_entity_subtree(runtime, p, forward),
        .TerrainMeshEdit => |p| {
            const use_y = if (forward) p.after_y else p.before_y;
            const use_c = if (forward) p.after_color else p.before_color;

            const model = model_manager.cardinal_model_manager_get_model(&runtime.model_manager, p.model_id) orelse return;
            if (model.scene.meshes == null or model.scene.mesh_count == 0) return;
            const mesh = &model.scene.meshes.?[0];
            if (mesh.vertices == null or mesh.vertex_count == 0) return;

            const verts = @as([*]engine.scene.CardinalVertex, @ptrCast(mesh.vertices.?));

            const count = @min(p.vertex_indices.len, @min(use_y.len, use_c.len));
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const vi = p.vertex_indices[i];
                if (vi >= mesh.vertex_count) continue;
                verts[vi].py = use_y[i];
                verts[vi].color = use_c[i];
            }

            var min_y: f32 = std.math.floatMax(f32);
            var max_y: f32 = -std.math.floatMax(f32);
            var v: u32 = 0;
            while (v < mesh.vertex_count) : (v += 1) {
                min_y = @min(min_y, verts[v].py);
                max_y = @max(max_y, verts[v].py);
            }
            mesh.bounding_box_min[1] = min_y;
            mesh.bounding_box_max[1] = max_y;

            if (runtime.combined_scene.meshes) |meshes| {
                if (p.combined_mesh_index < runtime.combined_scene.mesh_count) {
                    meshes[p.combined_mesh_index].bounding_box_min[1] = min_y;
                    meshes[p.combined_mesh_index].bounding_box_max[1] = max_y;
                }
            }

            if (runtime.mesh_entity_by_mesh_index.get(p.combined_mesh_index)) |entity_id| {
                if (runtime.terrain_data_by_entity.getPtr(entity_id)) |td| {
                    const max_vi: usize = @min(@as(usize, mesh.vertex_count), td.height.len);
                    var j: usize = 0;
                    while (j < count) : (j += 1) {
                        const vi_u32 = p.vertex_indices[j];
                        const vi: usize = @intCast(vi_u32);
                        if (vi >= max_vi) continue;
                        td.height[vi] = verts[vi_u32].py;
                        const base = vi * 4;
                        if (base + 3 < td.splat.len) {
                            const c4 = verts[vi_u32].color;
                            td.splat[base + 0] = @intFromFloat(@min(1.0, @max(0.0, c4[0])) * 255.0 + 0.5);
                            td.splat[base + 1] = @intFromFloat(@min(1.0, @max(0.0, c4[1])) * 255.0 + 0.5);
                            td.splat[base + 2] = @intFromFloat(@min(1.0, @max(0.0, c4[2])) * 255.0 + 0.5);
                            td.splat[base + 3] = 255;
                        }
                    }

                    if (td.height_handle == std.math.maxInt(u32)) {
                        var h: u32 = 0;
                        if (renderer.cardinal_renderer_runtime_texture_allocate(runtime.renderer, td.dims, td.dims, vk.VK_FORMAT_R32_SFLOAT, &h)) {
                            td.height_handle = h;
                            _ = renderer.cardinal_renderer_runtime_texture_upload_full(runtime.renderer, h, @ptrCast(td.height.ptr), td.height.len * @sizeOf(f32));
                        }
                    }
                    if (td.splat_handle == std.math.maxInt(u32)) {
                        var h: u32 = 0;
                        if (renderer.cardinal_renderer_runtime_texture_allocate(runtime.renderer, td.dims, td.dims, vk.VK_FORMAT_R8G8B8A8_UNORM, &h)) {
                            td.splat_handle = h;
                            _ = renderer.cardinal_renderer_runtime_texture_upload_full(runtime.renderer, h, @ptrCast(td.splat.ptr), td.splat.len);
                        }
                    }

                    if (td.height_handle != std.math.maxInt(u32) and td.splat_handle != std.math.maxInt(u32) and count > 0) {
                        var min_x: u32 = std.math.maxInt(u32);
                        var min_ty: u32 = std.math.maxInt(u32);
                        var max_x: u32 = 0;
                        var max_ty: u32 = 0;

                        var k: usize = 0;
                        while (k < count) : (k += 1) {
                            const vi_u32 = p.vertex_indices[k];
                            const x: u32 = vi_u32 % td.dims;
                            const y: u32 = vi_u32 / td.dims;
                            min_x = @min(min_x, x);
                            min_ty = @min(min_ty, y);
                            max_x = @max(max_x, x);
                            max_ty = @max(max_ty, y);
                        }

                        if (min_x != std.math.maxInt(u32) and min_ty != std.math.maxInt(u32) and max_x < td.dims and max_ty < td.dims) {
                            const w: u32 = max_x - min_x + 1;
                            const h: u32 = max_ty - min_ty + 1;
                            const w_usize: usize = @intCast(w);
                            const h_usize: usize = @intCast(h);

                            const tmp_height = allocator().alloc(f32, w_usize * h_usize) catch null;
                            const tmp_splat = allocator().alloc(u8, (w_usize * h_usize) * 4) catch null;
                            if (tmp_height != null and tmp_splat != null) {
                                const th = tmp_height.?;
                                const ts = tmp_splat.?;

                                var row: u32 = 0;
                                while (row < h) : (row += 1) {
                                    const src_y: usize = @as(usize, min_ty + row);
                                    const src_base: usize = src_y * @as(usize, td.dims) + @as(usize, min_x);
                                    const dst_base: usize = @as(usize, row) * w_usize;

                                    @memcpy(th[dst_base .. dst_base + w_usize], td.height[src_base .. src_base + w_usize]);

                                    const src_s_base: usize = src_base * 4;
                                    const dst_s_base: usize = dst_base * 4;
                                    @memcpy(ts[dst_s_base .. dst_s_base + w_usize * 4], td.splat[src_s_base .. src_s_base + w_usize * 4]);
                                }

                                _ = renderer.cardinal_renderer_runtime_texture_update_subregion(runtime.renderer, td.height_handle, min_x, min_ty, w, h, @ptrCast(th.ptr), th.len * @sizeOf(f32));
                                _ = renderer.cardinal_renderer_runtime_texture_update_subregion(runtime.renderer, td.splat_handle, min_x, min_ty, w, h, @ptrCast(ts.ptr), ts.len);

                                allocator().free(ts);
                                allocator().free(th);
                            } else {
                                if (tmp_height) |th| allocator().free(th);
                                if (tmp_splat) |ts| allocator().free(ts);
                            }
                        }
                    }
                }
            }

            runtime.pending_scene = runtime.combined_scene;
            runtime.scene_upload_pending = true;
            runtime.scene_loaded = (runtime.combined_scene.mesh_count > 0);
            runtime.picking_cache_dirty = true;
        },
        .ModelTransform => |m| {
            const mat = if (forward) m.after else m.before;
            _ = model_manager.cardinal_model_manager_set_transform(&runtime.model_manager, m.model_id, &mat);
            runtime.model_manager.transform_dirty = true;
        },
    }
}

fn apply_entity_component(runtime: anytype, comptime T: type, c: EntityComponentCommand(T), forward: bool) void {
    const ent = engine.ecs_entity.Entity{ .id = c.entity_id };
    if (!runtime.registry.entity_manager.is_alive(ent)) return;

    const present = if (forward) c.after_present else c.before_present;
    const value = if (forward) c.after else c.before;

    if (present) {
        runtime.registry.add(ent, value) catch {};
        if (comptime T == components.Transform) {
            runtime.mark_transform_override_tree(ent);
        }
    } else {
        runtime.registry.remove(T, ent);
    }
}

fn snapshot_entity(registry: *engine.ecs_registry.Registry, ent: engine.ecs_entity.Entity) EntitySnapshot {
    var snap: EntitySnapshot = .{
        .entity_id = ent.id,
        .mask = .{},
    };

    if (registry.get(components.Name, ent)) |c| {
        snap.mask.name = true;
        snap.name = c.*;
    }
    if (registry.get(components.Transform, ent)) |c| {
        snap.mask.transform = true;
        snap.transform = c.*;
    }
    if (registry.get(components.Node, ent)) |c| {
        snap.mask.node = true;
        snap.node = c.*;
    }
    if (registry.get(components.Hierarchy, ent)) |c| {
        snap.mask.hierarchy = true;
        snap.hierarchy = c.*;
    }
    if (registry.get(components.MeshRenderer, ent)) |c| {
        snap.mask.mesh_renderer = true;
        snap.mesh_renderer = c.*;
    }
    if (registry.get(components.Light, ent)) |c| {
        snap.mask.light = true;
        snap.light = c.*;
    }
    if (registry.get(components.Camera, ent)) |c| {
        snap.mask.camera = true;
        snap.camera = c.*;
    }
    if (registry.get(components.Skybox, ent)) |c| {
        snap.mask.skybox = true;
        snap.skybox = c.*;
    }

    return snap;
}

fn collect_subtree_entities(registry: *engine.ecs_registry.Registry, root: engine.ecs_entity.Entity, out: *std.ArrayListUnmanaged(engine.ecs_entity.Entity)) void {
    const alloc = allocator();

    var stack: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
    defer stack.deinit(alloc);

    stack.append(alloc, root) catch return;

    while (stack.items.len != 0) {
        const last_index = stack.items.len - 1;
        const e = stack.items[last_index];
        stack.items.len = last_index;

        if (!registry.entity_manager.is_alive(e)) continue;
        out.append(alloc, e) catch {};

        const h_ptr = registry.get(components.Hierarchy, e) orelse continue;
        var child = h_ptr.first_child;
        var guard: u32 = 0;
        while (child) |c_ent| {
            if (guard > 100000) break;
            guard += 1;
            stack.append(alloc, c_ent) catch {};
            child = if (registry.get(components.Hierarchy, c_ent)) |ch| ch.next_sibling else null;
        }
    }
}

fn apply_entity_snapshot_restore(registry: *engine.ecs_registry.Registry, snap: *const EntitySnapshot) void {
    const ent = engine.ecs_entity.Entity{ .id = snap.entity_id };
    if (!registry.entity_manager.is_alive(ent)) return;

    if (snap.mask.name) registry.add(ent, snap.name) catch {};
    if (snap.mask.transform) registry.add(ent, snap.transform) catch {};
    if (snap.mask.node) registry.add(ent, snap.node) catch {};
    if (snap.mask.mesh_renderer) registry.add(ent, snap.mesh_renderer) catch {};
    if (snap.mask.light) registry.add(ent, snap.light) catch {};
    if (snap.mask.camera) registry.add(ent, snap.camera) catch {};
    if (snap.mask.skybox) registry.add(ent, snap.skybox) catch {};
    if (snap.mask.hierarchy) registry.add(ent, snap.hierarchy) catch {};
}

fn apply_entity_snapshot_delete(registry: *engine.ecs_registry.Registry, snap: *const EntitySnapshot) void {
    const ent = engine.ecs_entity.Entity{ .id = snap.entity_id };
    if (!registry.entity_manager.is_alive(ent)) return;

    registry.remove(components.Name, ent);
    registry.remove(components.Transform, ent);
    registry.remove(components.Node, ent);
    registry.remove(components.MeshRenderer, ent);
    registry.remove(components.Light, ent);
    registry.remove(components.Camera, ent);
    registry.remove(components.Skybox, ent);
    registry.remove(components.Hierarchy, ent);
}

fn cleanup_runtime_maps(runtime: anytype, snaps: []const EntitySnapshot) void {
    const alloc = allocator();
    for (snaps) |snap| {
        _ = runtime.transform_overrides.remove(snap.entity_id);
    }

    var deleted: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer deleted.deinit(alloc);
    for (snaps) |snap| {
        deleted.put(alloc, snap.entity_id, {}) catch {};
    }

    var keys: std.ArrayListUnmanaged(u32) = .{};
    defer keys.deinit(alloc);

    var it_owner = runtime.mesh_owner_by_mesh_index.iterator();
    while (it_owner.next()) |entry| {
        if (deleted.contains(entry.value_ptr.*)) {
            keys.append(alloc, entry.key_ptr.*) catch {};
        }
    }
    for (keys.items) |k| {
        _ = runtime.mesh_owner_by_mesh_index.remove(k);
    }

    keys.clearRetainingCapacity();
    var it_ent = runtime.mesh_entity_by_mesh_index.iterator();
    while (it_ent.next()) |entry| {
        if (deleted.contains(entry.value_ptr.*)) {
            keys.append(alloc, entry.key_ptr.*) catch {};
        }
    }
    for (keys.items) |k| {
        _ = runtime.mesh_entity_by_mesh_index.remove(k);
    }
}

fn apply_entity_subtree(runtime: anytype, cmd_ptr: *EntitySubtreeCommand, forward: bool) void {
    const do_delete = if (cmd_ptr.mode == .Delete) forward else !forward;
    const hier_src = if (do_delete) (if (cmd_ptr.mode == .Delete) cmd_ptr.hierarchy_after else cmd_ptr.hierarchy_before) else (if (cmd_ptr.mode == .Delete) cmd_ptr.hierarchy_before else cmd_ptr.hierarchy_after);

    var i: u8 = 0;
    while (i < cmd_ptr.hierarchy_count) : (i += 1) {
        const ent = engine.ecs_entity.Entity{ .id = cmd_ptr.hierarchy_entity_ids[i] };
        if (!runtime.registry.entity_manager.is_alive(ent)) continue;
        runtime.registry.add(ent, hier_src[i]) catch {};
    }

    if (do_delete) {
        for (cmd_ptr.entities) |*snap| {
            apply_entity_snapshot_delete(runtime.registry, snap);
        }
        cleanup_runtime_maps(runtime, cmd_ptr.entities);
    } else {
        for (cmd_ptr.entities) |*snap| {
            apply_entity_snapshot_restore(runtime.registry, snap);
        }
    }
}

fn free_stack_items(items: []UndoCommand) void {
    for (items) |cmd| {
        free_command(cmd);
    }
}

fn free_command(cmd: UndoCommand) void {
    switch (cmd) {
        .EntitySubtree => |p| {
            const alloc = allocator();
            alloc.free(p.entities);
            alloc.destroy(p);
        },
        .TerrainMeshEdit => |p| {
            const alloc = allocator();
            alloc.free(p.vertex_indices);
            alloc.free(p.before_y);
            alloc.free(p.after_y);
            alloc.free(p.before_color);
            alloc.free(p.after_color);
            alloc.destroy(p);
        },
        else => {},
    }
}
