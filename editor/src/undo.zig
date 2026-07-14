//! Editor undo/redo stack.
//!
//! Stores discrete commands plus "capture" helpers that coalesce drag interactions into one step.
const std = @import("std");
const engine = @import("cardinal_engine");
const components = engine.ecs_components;
const model_manager = engine.model_manager;
const renderer = engine.vulkan_renderer;
const vk = @import("c.zig").c;
const terrain_volume = @import("systems/terrain_volume.zig");
const vt_common = @import("systems/volumetric_terrain/common.zig");
const async_loader = engine.async_loader;

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

const SnapshotMask = packed struct(u32) {
    name: bool = false,
    transform: bool = false,
    node: bool = false,
    hierarchy: bool = false,
    mesh_renderer: bool = false,
    light: bool = false,
    camera: bool = false,
    skybox: bool = false,
    terrain: bool = false,
    script: bool = false,
    editor_globals: bool = false,
    _pad: u21 = 0,
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
    terrain: components.Terrain = undefined,
    script: components.Script = undefined,
    editor_globals: components.EditorGlobals = undefined,
};

const HierarchyAdjacencySnapshot = struct {
    entity_ids: []u64,
    before: []components.Hierarchy,
    after: []components.Hierarchy,
};

/// Snapshot-based subtree command used for create/delete undo.
const EntitySubtreeCommand = struct {
    mode: SubtreeMode,
    root_id: u64,
    entities: []EntitySnapshot,
    hierarchy: HierarchyAdjacencySnapshot,
};

pub const TerrainMeshEditCommand = struct {
    model_id: u32,
    combined_mesh_index: u32,
    vertex_indices: []u32,
    before_y: []f32,
    after_y: []f32,
    before_color: [][4]f32,
    after_color: [][4]f32,
    before_splat: []u32,
    after_splat: []u32,
};

pub const TerrainMeshEditGroupCommand = struct {
    edits: []*TerrainMeshEditCommand,
};

pub const TerrainTexRectEditCommand = struct {
    model_id: u32,
    combined_mesh_index: u32,
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
    before_y: []f32,
    after_y: []f32,
    before_color: [][4]f32,
    after_color: [][4]f32,
    before_splat: []u32,
    after_splat: []u32,
};

pub const TerrainTexRectEditGroupCommand = struct {
    edits: []*TerrainTexRectEditCommand,
};

pub const VolumetricTerrainEditCommand = struct {
    entity_id: u64,
    dims: u32,
    before_density: []f32,
    after_density: []f32,
    before_splat: []u8,
    after_splat: []u8,
    before_data_id: u64,
    after_data_id: u64,
};

pub const VolumetricTerrainEditGroupCommand = struct {
    edits: []*VolumetricTerrainEditCommand,
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
    EntityTerrain: EntityComponentCommand(components.Terrain),
    EntityScript: EntityComponentCommand(components.Script),
    EntityEditorGlobals: EntityComponentCommand(components.EditorGlobals),
    EntityReparent: HierarchyAdjacencySnapshot,
    EntitySubtree: *EntitySubtreeCommand,
    TerrainMeshEdit: *TerrainMeshEditCommand,
    TerrainMeshEditGroup: TerrainMeshEditGroupCommand,
    TerrainTexRectEdit: *TerrainTexRectEditCommand,
    TerrainTexRectEditGroup: TerrainTexRectEditGroupCommand,
    VolumetricTerrainEdit: *VolumetricTerrainEditCommand,
    VolumetricTerrainEditGroup: VolumetricTerrainEditGroupCommand,
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
    EntityEditorGlobals: struct { entity_id: u64, before: components.EditorGlobals },
    ModelTransform: struct { model_id: u32, before: [16]f32 },
};

pub const UndoState = struct {
    undo_stack: std.ArrayListUnmanaged(UndoCommand) = .{},
    redo_stack: std.ArrayListUnmanaged(UndoCommand) = .{},
    capture: ?Capture = null,

    pub fn is_capturing_entity_light(self: *UndoState, entity_id: u64) bool {
        if (self.capture) |cap| {
            return cap == .EntityLight and cap.EntityLight.entity_id == entity_id;
        }
        return false;
    }

    pub fn is_capturing_entity_camera(self: *UndoState, entity_id: u64) bool {
        if (self.capture) |cap| {
            return cap == .EntityCamera and cap.EntityCamera.entity_id == entity_id;
        }
        return false;
    }

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

    pub fn push_entity_reparent(self: *UndoState, entity_ids: []const u64, before: []const components.Hierarchy, after: []const components.Hierarchy) void {
        const alloc = allocator();
        const count: usize = @min(entity_ids.len, @min(before.len, after.len));
        const ids_mem = alloc.alloc(u64, count) catch return;
        errdefer alloc.free(ids_mem);
        const before_mem = alloc.alloc(components.Hierarchy, count) catch {
            alloc.free(ids_mem);
            return;
        };
        errdefer alloc.free(before_mem);
        const after_mem = alloc.alloc(components.Hierarchy, count) catch {
            alloc.free(before_mem);
            alloc.free(ids_mem);
            return;
        };
        errdefer alloc.free(after_mem);

        @memcpy(ids_mem, entity_ids[0..count]);
        @memcpy(before_mem, before[0..count]);
        @memcpy(after_mem, after[0..count]);

        self.undo_stack.append(alloc, .{ .EntityReparent = .{
            .entity_ids = ids_mem,
            .before = before_mem,
            .after = after_mem,
        } }) catch {
            alloc.free(after_mem);
            alloc.free(before_mem);
            alloc.free(ids_mem);
            return;
        };

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

    pub fn begin_entity_editor_globals(self: *UndoState, entity_id: u64, before: components.EditorGlobals) void {
        if (self.capture != null) return;
        self.capture = .{ .EntityEditorGlobals = .{ .entity_id = entity_id, .before = before } };
    }

    pub fn end_entity_editor_globals(self: *UndoState, entity_id: u64, after: components.EditorGlobals) void {
        if (self.capture) |cap| {
            if (cap == .EntityEditorGlobals and cap.EntityEditorGlobals.entity_id == entity_id) {
                const before = cap.EntityEditorGlobals.before;
                self.capture = null;
                if (std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&after))) return;
                self.push(.{ .EntityEditorGlobals = .{
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
        const count: usize = @min(hierarchy_entity_ids.len, @min(hierarchy_before.len, hierarchy_after.len));
        const ids_mem = alloc.alloc(u64, count) catch {
            alloc.free(snaps);
            alloc.destroy(cmd_ptr);
            return;
        };
        errdefer alloc.free(ids_mem);
        const before_mem = alloc.alloc(components.Hierarchy, count) catch {
            alloc.free(ids_mem);
            alloc.free(snaps);
            alloc.destroy(cmd_ptr);
            return;
        };
        errdefer alloc.free(before_mem);
        const after_mem = alloc.alloc(components.Hierarchy, count) catch {
            alloc.free(before_mem);
            alloc.free(ids_mem);
            alloc.free(snaps);
            alloc.destroy(cmd_ptr);
            return;
        };
        errdefer alloc.free(after_mem);

        @memcpy(ids_mem, hierarchy_entity_ids[0..count]);
        @memcpy(before_mem, hierarchy_before[0..count]);
        @memcpy(after_mem, hierarchy_after[0..count]);

        cmd_ptr.* = .{
            .mode = mode,
            .root_id = root_id,
            .entities = snaps,
            .hierarchy = .{
                .entity_ids = ids_mem,
                .before = before_mem,
                .after = after_mem,
            },
        };

        self.undo_stack.append(alloc, .{ .EntitySubtree = cmd_ptr }) catch {
            alloc.free(after_mem);
            alloc.free(before_mem);
            alloc.free(ids_mem);
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

fn rewrite_indices_from_alpha(mesh: *engine.scene.CardinalMesh, verts_per_side: u32) void {
    if (mesh.vertices == null or mesh.indices == null) return;
    if (verts_per_side < 2) return;
    const grid: u32 = verts_per_side - 1;
    const need: u32 = grid * grid * 6;
    if (mesh.index_count < need) return;

    const verts = @as([*]engine.scene.CardinalVertex, @ptrCast(mesh.vertices.?));
    const indices = @as([*]u32, @ptrCast(mesh.indices.?));

    var quad: u32 = 0;
    var z: u32 = 0;
    while (z < grid) : (z += 1) {
        var x: u32 = 0;
        while (x < grid) : (x += 1) {
            const idx0: u32 = z * verts_per_side + x;
            const idx1: u32 = idx0 + 1;
            const idx2: u32 = idx0 + verts_per_side;
            const idx3: u32 = idx2 + 1;

            const a = (verts[idx0].color[3] + verts[idx1].color[3] + verts[idx2].color[3] + verts[idx3].color[3]) * 0.25;
            const base: usize = @as(usize, quad) * 6;
            if (a > 0.5) {
                indices[base + 0] = idx0;
                indices[base + 1] = idx2;
                indices[base + 2] = idx1;
                indices[base + 3] = idx1;
                indices[base + 4] = idx2;
                indices[base + 5] = idx3;
            } else {
                indices[base + 0] = 0;
                indices[base + 1] = 0;
                indices[base + 2] = 0;
                indices[base + 3] = 0;
                indices[base + 4] = 0;
                indices[base + 5] = 0;
            }
            quad += 1;
        }
    }
}

fn apply(runtime: anytype, cmd: UndoCommand, forward: bool) void {
    switch (cmd) {
        .EntityTransform => |c| apply_entity_component(runtime, components.Transform, c, forward),
        .EntityName => |c| apply_entity_component(runtime, components.Name, c, forward),
        .EntityNode => |c| apply_entity_component(runtime, components.Node, c, forward),
        .EntityHierarchy => |c| apply_entity_component(runtime, components.Hierarchy, c, forward),
        .EntityMeshRenderer => |c| {
            apply_entity_component(runtime, components.MeshRenderer, c, forward);
            sync_mesh_visibility_and_schedule_upload(runtime);
        },
        .EntityLight => |c| apply_entity_component(runtime, components.Light, c, forward),
        .EntityCamera => |c| apply_entity_component(runtime, components.Camera, c, forward),
        .EntitySkybox => |c| apply_entity_component(runtime, components.Skybox, c, forward),
        .EntityTerrain => |c| {
            apply_entity_component(runtime, components.Terrain, c, forward);
            if (runtime.terrain_data_by_entity.fetchRemove(c.entity_id)) |kv| {
                const td = kv.value;
                for (td.layer_imgui_ids) |id| {
                    if (id != 0) {
                        vk.imgui_bridge_vk_remove_texture(id);
                    }
                }
                if (td.height_handle != std.math.maxInt(u32)) {
                    renderer.cardinal_renderer_runtime_texture_free(runtime.renderer, td.height_handle);
                }
                if (td.splat_handle != std.math.maxInt(u32)) {
                    renderer.cardinal_renderer_runtime_texture_free(runtime.renderer, td.splat_handle);
                }
                for (td.layer_handles) |h| {
                    if (h != std.math.maxInt(u32)) {
                        renderer.cardinal_renderer_runtime_texture_free(runtime.renderer, h);
                    }
                }
            }
            _ = runtime.terrain_dirty_rects.remove(c.entity_id);

            runtime.pending_scene = runtime.combined_scene;
            runtime.scene_upload_pending = true;
            runtime.scene_loaded = (runtime.combined_scene.mesh_count > 0);
            runtime.picking_cache_dirty = true;
        },
        .EntityScript => |c| apply_entity_component(runtime, components.Script, c, forward),
        .EntityEditorGlobals => |c| apply_entity_component(runtime, components.EditorGlobals, c, forward),
        .EntityReparent => |r| {
            const count: usize = @min(r.entity_ids.len, @min(r.before.len, r.after.len));
            const src = if (forward) r.after[0..count] else r.before[0..count];
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const ent = engine.ecs_entity.Entity{ .id = r.entity_ids[i] };
                if (!runtime.registry.entity_manager.is_alive(ent)) continue;
                runtime.registry.add(ent, src[i]) catch {};
            }
        },
        .EntitySubtree => |p| {
            apply_entity_subtree(runtime, p, forward);
            sync_mesh_visibility_and_schedule_upload(runtime);
        },
        .TerrainMeshEdit => |p| apply_terrain_mesh_edit(runtime, p, forward),
        .TerrainMeshEditGroup => |g| {
            for (g.edits) |p| {
                apply_terrain_mesh_edit(runtime, p, forward);
            }
        },
        .TerrainTexRectEdit => |p| apply_terrain_tex_rect_edit(runtime, p, forward),
        .TerrainTexRectEditGroup => |g| {
            for (g.edits) |p| {
                apply_terrain_tex_rect_edit(runtime, p, forward);
            }
        },
        .VolumetricTerrainEdit => |p| apply_volumetric_terrain_edit(runtime, p, forward),
        .VolumetricTerrainEditGroup => |g| {
            for (g.edits) |p| {
                apply_volumetric_terrain_edit(runtime, p, forward);
            }
        },
        .ModelTransform => |m| {
            const mat = if (forward) m.after else m.before;
            _ = model_manager.cardinal_model_manager_set_transform(&runtime.model_manager, m.model_id, &mat);
            runtime.model_manager.transform_dirty = true;
        },
    }
}

fn brick_axis_count(base_res: u32) u32 {
    const r = if (base_res < 1) 1 else base_res;
    return (r + vt_common.brick_cells_base - 1) / vt_common.brick_cells_base;
}

fn mark_volumetric_dirty_bricks_masked(runtime: anytype, entity_id: u64, box: anytype, lod_mask: u8, base_res: u32) void {
    const Map = @TypeOf(runtime.volumetric_dirty_brick_boxes);
    const KeyT = @typeInfo(Map.KV).@"struct".fields[0].type;
    const ValT = @typeInfo(Map.KV).@"struct".fields[1].type;

    const axis = brick_axis_count(base_res);
    if (axis == 0) return;

    const bx0 = @min(axis - 1, box.min_x / vt_common.brick_cells_base);
    const by0 = @min(axis - 1, box.min_y / vt_common.brick_cells_base);
    const bz0 = @min(axis - 1, box.min_z / vt_common.brick_cells_base);
    const bx1 = @min(axis - 1, box.max_x / vt_common.brick_cells_base);
    const by1 = @min(axis - 1, box.max_y / vt_common.brick_cells_base);
    const bz1 = @min(axis - 1, box.max_z / vt_common.brick_cells_base);

    const alloc = allocator();
    var bz: u32 = bz0;
    while (bz <= bz1) : (bz += 1) {
        var by: u32 = by0;
        while (by <= by1) : (by += 1) {
            var bx: u32 = bx0;
            while (bx <= bx1) : (bx += 1) {
                const id: u32 = (bz * axis + by) * axis + bx;
                const key = KeyT{ .entity_id = entity_id, .brick_id = id };

                if (runtime.volumetric_dirty_brick_boxes.getPtr(key)) |existing| {
                    existing.min_x = @min(existing.min_x, box.min_x);
                    existing.min_y = @min(existing.min_y, box.min_y);
                    existing.min_z = @min(existing.min_z, box.min_z);
                    existing.max_x = @max(existing.max_x, box.max_x);
                    existing.max_y = @max(existing.max_y, box.max_y);
                    existing.max_z = @max(existing.max_z, box.max_z);
                } else {
                    runtime.volumetric_dirty_brick_boxes.put(alloc, key, @as(ValT, box)) catch {};
                }

                if (runtime.volumetric_dirty_brick_lod_masks.getPtr(key)) |m| {
                    m.* |= lod_mask;
                } else {
                    runtime.volumetric_dirty_brick_lod_masks.put(alloc, key, lod_mask) catch {};
                }

                if (runtime.volumetric_brick_generation.getPtr(key)) |g| {
                    g.* +%= 1;
                } else {
                    runtime.volumetric_brick_generation.put(alloc, key, 1) catch {};
                }

                if (runtime.volumetric_brick_remesh_tasks.get(key)) |t| {
                    const status = async_loader.cardinal_async_get_task_status(t);
                    if (status == .PENDING) {
                        _ = async_loader.cardinal_async_cancel_task(t);
                        async_loader.cardinal_async_free_task(t);
                        _ = runtime.volumetric_brick_remesh_tasks.remove(key);
                    }
                }
            }
        }
    }
}

fn apply_volumetric_terrain_edit(runtime: anytype, p: *VolumetricTerrainEditCommand, forward: bool) void {
    const use_density = if (forward) p.after_density else p.before_density;
    const use_splat = if (forward) p.after_splat else p.before_splat;
    const use_data_id = if (forward) p.after_data_id else p.before_data_id;

    const DirtyBoxT = @typeInfo(@TypeOf(runtime.volumetric_dirty_brick_boxes).KV).@"struct".fields[1].type;

    const ent = engine.ecs_entity.Entity{ .id = p.entity_id };
    if (!runtime.registry.entity_manager.is_alive(ent)) return;
    const vt = runtime.registry.get(components.VolumetricTerrain, ent) orelse return;
    const td = runtime.volumetric_terrain_data_by_entity.getPtr(p.entity_id) orelse return;
    if (td.dims != p.dims) return;

    if (use_density.len == td.density.len) {
        @memcpy(td.density, use_density);
    }
    if (use_splat.len == td.splat.len) {
        @memcpy(td.splat, use_splat);
    }
    vt.data_id = use_data_id;

    if (td.dims >= 2) {
        const res: u32 = td.dims - 1;
        if (res >= 1) {
            mark_volumetric_dirty_bricks_masked(runtime, p.entity_id, DirtyBoxT{
                .min_x = 0,
                .min_y = 0,
                .min_z = 0,
                .max_x = res - 1,
                .max_y = res - 1,
                .max_z = res - 1,
            }, 0xff, res);
        }
    }
    runtime.picking_cache_dirty = true;
}

fn sync_mesh_visibility_and_schedule_upload(runtime: anytype) void {
    if (!runtime.scene_loaded) return;
    if (runtime.scene_upload_pending) return;
    if (runtime.combined_scene.meshes == null or runtime.combined_scene.mesh_count == 0) return;
    const meshes = runtime.combined_scene.meshes.?;

    var i: u32 = 0;
    while (i < runtime.combined_scene.mesh_count) : (i += 1) {
        meshes[i].visible = false;
    }

    var view = runtime.registry.view(components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        const mr = entry.component;
        const mesh_index = mr.mesh.index;
        if (mesh_index >= runtime.combined_scene.mesh_count) continue;
        meshes[mesh_index].visible = mr.visible;
    }

    runtime.pending_scene = runtime.combined_scene;
    runtime.scene_upload_pending = true;
    runtime.picking_cache_dirty = true;
}

fn apply_terrain_mesh_edit(runtime: anytype, p: *TerrainMeshEditCommand, forward: bool) void {
    const use_y = if (forward) p.after_y else p.before_y;
    const use_c = if (forward) p.after_color else p.before_color;
    const use_s = if (forward) p.after_splat else p.before_splat;

    const model = model_manager.cardinal_model_manager_get_model(&runtime.model_manager, p.model_id) orelse return;
    if (model.scene.meshes == null or model.scene.mesh_count == 0) return;
    const mesh = &model.scene.meshes.?[0];
    if (mesh.vertices == null or mesh.vertex_count == 0) return;

    const verts = @as([*]engine.scene.CardinalVertex, @ptrCast(mesh.vertices.?));

    const count = @min(p.vertex_indices.len, @min(use_y.len, @min(use_c.len, use_s.len)));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const vi = p.vertex_indices[i];
        if (vi >= mesh.vertex_count) continue;
        verts[vi].py = use_y[i];
        verts[vi].color = use_c[i];
    }

    if (mesh.indices != null and mesh.index_count > 0) {
        const vc = mesh.vertex_count;
        const side_f: f64 = std.math.sqrt(@as(f64, @floatFromInt(vc)));
        const side: u32 = @intFromFloat(side_f + 0.5);
        if (side >= 2 and side * side == vc) {
            rewrite_indices_from_alpha(mesh, side);
        }
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
                    const splat_packed = use_s[j];
                    td.splat[base + 0] = @intCast(splat_packed & 0xff);
                    td.splat[base + 1] = @intCast((splat_packed >> 8) & 0xff);
                    td.splat[base + 2] = @intCast((splat_packed >> 16) & 0xff);
                    td.splat[base + 3] = @intCast((splat_packed >> 24) & 0xff);
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
        terrain_volume.update_terrain_volume_meshes(runtime, entity_id);
    }

    runtime.pending_scene = runtime.combined_scene;
    runtime.scene_upload_pending = true;
    runtime.scene_loaded = (runtime.combined_scene.mesh_count > 0);
    runtime.picking_cache_dirty = true;
}

fn apply_terrain_tex_rect_edit(runtime: anytype, p: *TerrainTexRectEditCommand, forward: bool) void {
    const use_y = if (forward) p.after_y else p.before_y;
    const use_c = if (forward) p.after_color else p.before_color;
    const use_s = if (forward) p.after_splat else p.before_splat;

    const range = get_model_combined_mesh_range(runtime, p.model_id) orelse return;
    const model = model_manager.cardinal_model_manager_get_model(&runtime.model_manager, p.model_id) orelse return;
    if (model.scene.meshes == null or model.scene.mesh_count == 0) return;
    if (p.combined_mesh_index < range.start) return;
    const local_index: u32 = p.combined_mesh_index - range.start;
    if (local_index >= model.scene.mesh_count) return;
    const mesh = &model.scene.meshes.?[local_index];
    if (mesh.vertices == null or mesh.vertex_count == 0) return;

    const verts = @as([*]engine.scene.CardinalVertex, @ptrCast(mesh.vertices.?));

    if (p.min_x > p.max_x or p.min_y > p.max_y) return;

    if (runtime.mesh_entity_by_mesh_index.get(p.combined_mesh_index)) |entity_id| {
        if (runtime.terrain_data_by_entity.getPtr(entity_id)) |td| {
            const ent = engine.ecs_entity.Entity{ .id = entity_id };
            const terr = runtime.registry.get(components.Terrain, ent) orelse return;
            const use_bottom = (p.combined_mesh_index == terr.mesh_index + 1);
            const height_map: []f32 = if (use_bottom) td.bottom_height else td.height;

            if (p.max_x >= td.dims or p.max_y >= td.dims) return;
            if (td.dims < 2) return;

            const w: u32 = p.max_x - p.min_x + 1;
            const h: u32 = p.max_y - p.min_y + 1;
            const w_usize: usize = @intCast(w);
            const h_usize: usize = @intCast(h);
            const count_expected: usize = w_usize * h_usize;
            const count = @min(count_expected, @min(use_y.len, @min(use_c.len, use_s.len)));

            var idx: usize = 0;
            var row: u32 = 0;
            while (row < h) : (row += 1) {
                const y: u32 = p.min_y + row;
                var col: u32 = 0;
                while (col < w) : (col += 1) {
                    if (idx >= count) break;
                    const x: u32 = p.min_x + col;
                    const vi: u32 = y * td.dims + x;
                    if (vi < mesh.vertex_count) {
                        verts[vi].py = use_y[idx];
                        verts[vi].color = use_c[idx];
                    }
                    const vi_usize: usize = @intCast(vi);
                    if (vi_usize < height_map.len) {
                        height_map[vi_usize] = use_y[idx];
                    }
                    const base = vi_usize * 4;
                    if (base + 3 < td.splat.len) {
                        const splat_packed = use_s[idx];
                        td.splat[base + 0] = @intCast(splat_packed & 0xff);
                        td.splat[base + 1] = @intCast((splat_packed >> 8) & 0xff);
                        td.splat[base + 2] = @intCast((splat_packed >> 16) & 0xff);
                        td.splat[base + 3] = @intCast((splat_packed >> 24) & 0xff);
                    }
                    idx += 1;
                }
            }

            if (mesh.indices != null and mesh.index_count > 0) {
                const vc = mesh.vertex_count;
                const side_f: f64 = std.math.sqrt(@as(f64, @floatFromInt(vc)));
                const side: u32 = @intFromFloat(side_f + 0.5);
                if (side >= 2 and side * side == vc) {
                    rewrite_indices_from_alpha(mesh, side);
                }
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

            if (!use_bottom) {
                if (td.height_handle == std.math.maxInt(u32)) {
                    var hndl: u32 = 0;
                    if (renderer.cardinal_renderer_runtime_texture_allocate(runtime.renderer, td.dims, td.dims, vk.VK_FORMAT_R32_SFLOAT, &hndl)) {
                        td.height_handle = hndl;
                        _ = renderer.cardinal_renderer_runtime_texture_upload_full(runtime.renderer, hndl, @ptrCast(td.height.ptr), td.height.len * @sizeOf(f32));
                    }
                }
            }
            if (td.splat_handle == std.math.maxInt(u32)) {
                var hndl: u32 = 0;
                if (renderer.cardinal_renderer_runtime_texture_allocate(runtime.renderer, td.dims, td.dims, vk.VK_FORMAT_R8G8B8A8_UNORM, &hndl)) {
                    td.splat_handle = hndl;
                    _ = renderer.cardinal_renderer_runtime_texture_upload_full(runtime.renderer, hndl, @ptrCast(td.splat.ptr), td.splat.len);
                }
            }

            if (!use_bottom) {
                if (td.height_handle != std.math.maxInt(u32) and td.splat_handle != std.math.maxInt(u32)) {
                    if (runtime.terrain_dirty_rects.getPtr(entity_id)) |r| {
                        r.min_x = @min(r.min_x, p.min_x);
                        r.min_y = @min(r.min_y, p.min_y);
                        r.max_x = @max(r.max_x, p.max_x);
                        r.max_y = @max(r.max_y, p.max_y);
                    } else {
                        runtime.terrain_dirty_rects.put(allocator(), entity_id, .{ .min_x = p.min_x, .min_y = p.min_y, .max_x = p.max_x, .max_y = p.max_y }) catch {};
                    }
                }
            }

            terrain_volume.update_terrain_volume_meshes(runtime, entity_id);
        }
    }

    runtime.pending_scene = runtime.combined_scene;
    runtime.scene_upload_pending = true;
    runtime.scene_loaded = (runtime.combined_scene.mesh_count > 0);
    runtime.picking_cache_dirty = true;
}

fn get_model_combined_mesh_range(runtime: anytype, model_id: u32) ?struct { start: u32, count: u32 } {
    if (runtime.model_manager.models == null) return null;
    const models = runtime.model_manager.models.?;
    var offset: u32 = 0;
    var i: u32 = 0;
    while (i < runtime.model_manager.model_count) : (i += 1) {
        const m = &models[i];
        if (!m.visible or m.is_loading) continue;
        if (m.id == model_id) return .{ .start = offset, .count = m.scene.mesh_count };
        offset += m.scene.mesh_count;
    }
    return null;
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
    if (registry.get(components.Terrain, ent)) |c| {
        snap.mask.terrain = true;
        snap.terrain = c.*;
    }
    if (registry.get(components.Script, ent)) |c| {
        snap.mask.script = true;
        snap.script = c.*;
    }
    if (registry.get(components.EditorGlobals, ent)) |c| {
        snap.mask.editor_globals = true;
        snap.editor_globals = c.*;
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
    if (snap.mask.terrain) registry.add(ent, snap.terrain) catch {};
    if (snap.mask.script) registry.add(ent, snap.script) catch {};
    if (snap.mask.editor_globals) registry.add(ent, snap.editor_globals) catch {};
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
    registry.remove(components.Terrain, ent);
    registry.remove(components.Hierarchy, ent);
    registry.remove(components.Script, ent);
    registry.remove(components.EditorGlobals, ent);
}

fn cleanup_runtime_maps(runtime: anytype, snaps: []const EntitySnapshot) void {
    const alloc = allocator();
    for (snaps) |snap| {
        _ = runtime.transform_overrides.remove(snap.entity_id);
    }

    for (snaps) |snap| {
        if (runtime.terrain_data_by_entity.fetchRemove(snap.entity_id)) |kv| {
            const td = kv.value;
            for (td.layer_imgui_ids) |id| {
                if (id != 0) {
                    vk.imgui_bridge_vk_remove_texture(id);
                }
            }
            if (td.height_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(runtime.renderer, td.height_handle);
            }
            if (td.splat_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(runtime.renderer, td.splat_handle);
            }
            for (td.layer_handles) |h| {
                if (h != std.math.maxInt(u32)) {
                    renderer.cardinal_renderer_runtime_texture_free(runtime.renderer, h);
                }
            }
        }
        _ = runtime.terrain_dirty_rects.remove(snap.entity_id);
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
    const h = cmd_ptr.hierarchy;
    const count: usize = @min(h.entity_ids.len, @min(h.before.len, h.after.len));
    const hier_src = if (do_delete)
        (if (cmd_ptr.mode == .Delete) h.after[0..count] else h.before[0..count])
    else
        (if (cmd_ptr.mode == .Delete) h.before[0..count] else h.after[0..count]);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const ent = engine.ecs_entity.Entity{ .id = h.entity_ids[i] };
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
        .EntityReparent => |r| {
            const alloc = allocator();
            alloc.free(r.entity_ids);
            alloc.free(r.before);
            alloc.free(r.after);
        },
        .EntitySubtree => |p| {
            const alloc = allocator();
            alloc.free(p.hierarchy.entity_ids);
            alloc.free(p.hierarchy.before);
            alloc.free(p.hierarchy.after);
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
            alloc.free(p.before_splat);
            alloc.free(p.after_splat);
            alloc.destroy(p);
        },
        .TerrainMeshEditGroup => |g| {
            const alloc = allocator();
            for (g.edits) |p| {
                alloc.free(p.vertex_indices);
                alloc.free(p.before_y);
                alloc.free(p.after_y);
                alloc.free(p.before_color);
                alloc.free(p.after_color);
                alloc.free(p.before_splat);
                alloc.free(p.after_splat);
                alloc.destroy(p);
            }
            alloc.free(g.edits);
        },
        .TerrainTexRectEdit => |p| {
            const alloc = allocator();
            alloc.free(p.before_y);
            alloc.free(p.after_y);
            alloc.free(p.before_color);
            alloc.free(p.after_color);
            alloc.free(p.before_splat);
            alloc.free(p.after_splat);
            alloc.destroy(p);
        },
        .TerrainTexRectEditGroup => |g| {
            const alloc = allocator();
            for (g.edits) |p| {
                alloc.free(p.before_y);
                alloc.free(p.after_y);
                alloc.free(p.before_color);
                alloc.free(p.after_color);
                alloc.free(p.before_splat);
                alloc.free(p.after_splat);
                alloc.destroy(p);
            }
            alloc.free(g.edits);
        },
        .VolumetricTerrainEdit => |p| {
            const alloc = allocator();
            alloc.free(p.before_density);
            alloc.free(p.after_density);
            alloc.free(p.before_splat);
            alloc.free(p.after_splat);
            alloc.destroy(p);
        },
        .VolumetricTerrainEditGroup => |g| {
            const alloc = allocator();
            for (g.edits) |p| {
                alloc.free(p.before_density);
                alloc.free(p.after_density);
                alloc.free(p.before_splat);
                alloc.free(p.after_splat);
                alloc.destroy(p);
            }
            alloc.free(g.edits);
        },
        else => {},
    }
}
