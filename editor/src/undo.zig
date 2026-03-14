const std = @import("std");
const engine = @import("cardinal_engine");
const components = engine.ecs_components;
const model_manager = engine.model_manager;

fn allocator() std.mem.Allocator {
    return engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
}

fn EntityComponentCommand(comptime T: type) type {
    return struct {
        entity_id: u64,
        before_present: bool,
        after_present: bool,
        before: T,
        after: T,
    };
}

pub const UndoCommand = union(enum) {
    EntityTransform: EntityComponentCommand(components.Transform),
    EntityName: EntityComponentCommand(components.Name),
    EntityNode: EntityComponentCommand(components.Node),
    EntityMeshRenderer: EntityComponentCommand(components.MeshRenderer),
    EntityLight: EntityComponentCommand(components.Light),
    EntityCamera: EntityComponentCommand(components.Camera),
    EntitySkybox: EntityComponentCommand(components.Skybox),
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
    ModelTransform: struct { model_id: u32, before: [16]f32 },
};

pub const UndoState = struct {
    undo_stack: std.ArrayListUnmanaged(UndoCommand) = .{},
    redo_stack: std.ArrayListUnmanaged(UndoCommand) = .{},
    capture: ?Capture = null,

    pub fn deinit(self: *UndoState, alloc: std.mem.Allocator) void {
        self.undo_stack.deinit(alloc);
        self.redo_stack.deinit(alloc);
        self.capture = null;
    }

    pub fn clear(self: *UndoState) void {
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
        self.capture = null;
    }

    pub fn push(self: *UndoState, cmd: UndoCommand) void {
        self.undo_stack.append(allocator(), cmd) catch return;
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn undo(self: *UndoState, runtime: anytype) void {
        if (self.undo_stack.items.len == 0) return;
        const idx = self.undo_stack.items.len - 1;
        const cmd = self.undo_stack.items[idx];
        self.undo_stack.items.len = idx;

        apply(runtime, cmd, false);
        self.redo_stack.append(allocator(), cmd) catch {};
    }

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
        .EntityMeshRenderer => |c| apply_entity_component(runtime, components.MeshRenderer, c, forward),
        .EntityLight => |c| apply_entity_component(runtime, components.Light, c, forward),
        .EntityCamera => |c| apply_entity_component(runtime, components.Camera, c, forward),
        .EntitySkybox => |c| apply_entity_component(runtime, components.Skybox, c, forward),
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
