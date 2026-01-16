const std = @import("std");
const registry_pkg = @import("registry.zig");
const components = @import("components.zig");
const system_pkg = @import("system.zig");
const command_buffer_pkg = @import("command_buffer.zig");
const log = @import("../core/log.zig");

const sys_log = log.ScopedLogger("ECS_SYSTEMS");

pub const RenderSystemDesc = system_pkg.System{
    .name = "RenderSystem",
    .update = RenderSystem.update,
    .priority = -100, // Run late
    .reads = &.{
        registry_pkg.Registry.get_type_id(components.Camera),
        registry_pkg.Registry.get_type_id(components.MeshRenderer),
        registry_pkg.Registry.get_type_id(components.Transform),
    },
};

pub const PhysicsSystemDesc = system_pkg.System{
    .name = "PhysicsSystem",
    .update = PhysicsSystem.update,
    .reads = &.{
        registry_pkg.Registry.get_type_id(components.Transform), // Actually reads and writes, but simplified
    },
    .writes = &.{
        registry_pkg.Registry.get_type_id(components.Transform),
    },
};

pub const ScriptSystemDesc = system_pkg.System{
    .name = "ScriptSystem",
    .update = ScriptSystem.update,
    .reads = &.{
        registry_pkg.Registry.get_type_id(components.Script),
    },
};

pub const RenderSystem = struct {
    pub fn update(registry: *registry_pkg.Registry, ecb: *command_buffer_pkg.CommandBuffer, delta_time: f32) void {
        _ = delta_time;
        _ = ecb;
        // 1. Find Camera
        var camera_view = registry.view(components.Camera);
        var active_camera: ?*components.Camera = null;
        var camera_transform: ?*components.Transform = null;

        var cam_it = camera_view.iterator();
        while (cam_it.next()) |entry| {
            // For now, just pick the first camera we find
            // TODO: we might have a "main" tag or flag
            active_camera = entry.component;
            camera_transform = registry.get(components.Transform, entry.entity);
            if (active_camera != null) break;
        }

        if (active_camera == null) {
            // sys_log.warn("No active camera found for rendering", .{});
            return;
        }

        // 2. Iterate Renderables
        var mesh_view = registry.view(components.MeshRenderer);
        var mesh_it = mesh_view.iterator();

        var draw_count: usize = 0;

        while (mesh_it.next()) |entry| {
            const entity = entry.entity;
            const renderer = entry.component;

            if (!renderer.visible) continue;

            if (registry.get(components.Transform, entity)) |transform| {
                // Here we would submit the draw call to the renderer
                // renderer.submit(mesh, material, transform.get_matrix());
                _ = transform;
                draw_count += 1;
            }
        }

        // sys_log.debug("RenderSystem processed {d} objects", .{draw_count});
    }
};

pub const PhysicsSystem = struct {
    pub fn update(registry: *registry_pkg.Registry, ecb: *command_buffer_pkg.CommandBuffer, delta_time: f32) void {
        // Placeholder for physics integration
        // Iterate RigidBody components, update Transforms based on velocity/forces
        _ = registry;
        _ = ecb;
        _ = delta_time;
    }
};

pub const ScriptSystem = struct {
    pub fn update(registry: *registry_pkg.Registry, ecb: *command_buffer_pkg.CommandBuffer, delta_time: f32) void {
        _ = ecb;
        var view = registry.view(components.Script);
        var it = view.iterator();

        while (it.next()) |entry| {
            const script = entry.component;
            if (script.on_update) |update_fn| {
                update_fn(script.data, delta_time);
            }
        }
    }
};
