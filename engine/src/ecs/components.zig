//! ECS component type definitions.
//!
//! Components are plain data types stored in the registry. Systems interpret and update them.
const std = @import("std");
const math = @import("../core/math.zig");
const handles = @import("../core/handles.zig");
const entity_pkg = @import("entity.zig");

/// Local-to-world transform with a cached world matrix.
pub const Transform = struct {
    position: math.Vec3 = math.Vec3.zero(),
    rotation: math.Quat = math.Quat.identity(),
    scale: math.Vec3 = math.Vec3.one(),

    /// Cached world matrix derived from TRS.
    world_matrix: math.Mat4 = math.Mat4.identity(),
    dirty: bool = true,

    /// Returns the world matrix, recomputing it if marked dirty.
    pub fn get_matrix(self: *Transform) math.Mat4 {
        if (self.dirty) {
            self.world_matrix = math.Mat4.fromTRS(self.position, self.rotation, self.scale);
            self.dirty = false;
        }
        return self.world_matrix;
    }
};

/// Renderable mesh + material binding.
pub const MeshRenderer = struct {
    mesh: handles.MeshHandle,
    material: handles.MaterialHandle,
    visible: bool = true,
    cast_shadows: bool = true,
    receive_shadows: bool = true,
};

/// Light category.
pub const LightType = enum {
    Directional,
    Point,
    Spot,
};

/// Light component interpreted by the renderer.
pub const Light = struct {
    type: LightType,
    color: math.Vec3 = math.Vec3.one(),
    intensity: f32 = 1.0,
    range: f32 = 10.0,
    inner_cone_angle: f32 = 0.0,
    outer_cone_angle: f32 = 0.0,
    cast_shadows: bool = false,
};

/// Camera projection mode.
pub const CameraType = enum {
    Perspective,
    Orthographic,
};

/// Camera component with cached view/projection matrices.
pub const Camera = struct {
    type: CameraType,
    /// Vertical field-of-view in degrees.
    fov: f32 = 45.0,
    aspect_ratio: f32 = 1.777,
    near_plane: f32 = 0.1,
    far_plane: f32 = 1000.0,
    ortho_size: f32 = 10.0,

    /// Cached view matrix computed by the camera system.
    view_matrix: math.Mat4 = math.Mat4.identity(),
    /// Cached projection matrix computed by the camera system.
    projection_matrix: math.Mat4 = math.Mat4.identity(),
};

/// Script hook component for user-defined update behavior.
pub const Script = struct {
    /// Script identifier interpreted by the script runtime.
    script_id: u64 = 0,
    /// Opaque pointer passed to callbacks.
    data: ?*anyopaque = null,

    /// Optional per-frame callback invoked by the script system.
    on_update: ?*const fn (data: ?*anyopaque, delta_time: f32) void = null,
};

/// Fixed-size, null-terminated name string.
pub const Name = struct {
    value: [64]u8 = [_]u8{0} ** 64,

    /// Builds a name by truncating `name` to fit.
    pub fn init(name: []const u8) Name {
        var n = Name{};
        const len = @min(name.len, 63);
        @memcpy(n.value[0..len], name[0..len]);
        n.value[len] = 0;
        return n;
    }

    /// Returns the string slice up to the first null terminator.
    pub fn slice(self: *const Name) []const u8 {
        return std.mem.sliceTo(&self.value, 0);
    }
};

/// Parent/child links for scene-graph traversal.
pub const Hierarchy = struct {
    parent: ?entity_pkg.Entity = null,
    first_child: ?entity_pkg.Entity = null,
    next_sibling: ?entity_pkg.Entity = null,
    prev_sibling: ?entity_pkg.Entity = null,
    child_count: u32 = 0,
};

/// High-level node category.
pub const NodeType = enum {
    Node3D,
    Node2D,
    NodeUI,
};

/// Generic node marker component.
pub const Node = struct {
    type: NodeType = .Node3D,
};
