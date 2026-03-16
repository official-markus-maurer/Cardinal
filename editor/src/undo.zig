//! Editor undo/redo stack.
//!
//! Stores discrete commands plus "capture" helpers that coalesce drag interactions into one step.
//!
//! TODO: Replace fixed-size reparent snapshots with a dynamic adjacency snapshot.
const std = @import("std");
const engine = @import("cardinal_engine");
const components = engine.ecs_components;
const model_manager = engine.model_manager;

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
        else => {},
    }
}
