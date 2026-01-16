const std = @import("std");
const registry_pkg = @import("registry.zig");
const components = @import("components.zig");
const log = @import("../core/log.zig");

const sys_log = log.ScopedLogger("ECS_SYSTEMS");

pub const RenderSystem = struct {
    pub fn update(registry: *registry_pkg.Registry, delta_time: f32) void {
        _ = delta_time;
        // 1. Find Camera
        var camera_view = registry.view(components.Camera);
        var active_camera: ?*components.Camera = null;
        var camera_transform: ?*components.Transform = null;

        var cam_it = camera_view.iterator();
        while (cam_it.next()) |entry| {
            // For now, just pick the first camera we find
            // In a real engine, we might have a "main" tag or flag
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
    pub fn update(registry: *registry_pkg.Registry, delta_time: f32) void {
        // Placeholder for physics integration
        // Iterate RigidBody components, update Transforms based on velocity/forces
        _ = registry;
        _ = delta_time;
    }
};

pub const ScriptSystem = struct {
    pub fn update(registry: *registry_pkg.Registry, delta_time: f32) void {
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
