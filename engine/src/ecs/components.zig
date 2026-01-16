const std = @import("std");
const math = @import("../core/math.zig");
const handles = @import("../core/handles.zig");

pub const Transform = struct {
    position: math.Vec3 = math.Vec3.zero(),
    rotation: math.Quat = math.Quat.identity(),
    scale: math.Vec3 = math.Vec3.one(),

    // Cached world matrix
    world_matrix: math.Mat4 = math.Mat4.identity(),
    dirty: bool = true,

    pub fn get_matrix(self: *Transform) math.Mat4 {
        if (self.dirty) {
            self.world_matrix = math.Mat4.fromTRS(self.position, self.rotation, self.scale);
            self.dirty = false;
        }
        return self.world_matrix;
    }
};

pub const MeshRenderer = struct {
    mesh: handles.MeshHandle,
    material: handles.MaterialHandle,
    visible: bool = true,
    cast_shadows: bool = true,
    receive_shadows: bool = true,
};

pub const LightType = enum {
    Directional,
    Point,
    Spot,
};

pub const Light = struct {
    type: LightType,
    color: math.Vec3 = math.Vec3.one(),
    intensity: f32 = 1.0,
    range: f32 = 10.0,
    inner_cone_angle: f32 = 0.0,
    outer_cone_angle: f32 = 0.0,
    cast_shadows: bool = false,
};

pub const CameraType = enum {
    Perspective,
    Orthographic,
};

pub const Camera = struct {
    type: CameraType,
    fov: f32 = 45.0, // Degrees
    aspect_ratio: f32 = 1.777,
    near_plane: f32 = 0.1,
    far_plane: f32 = 1000.0,
    ortho_size: f32 = 10.0,

    // View and Projection matrices are calculated by the system
    view_matrix: math.Mat4 = math.Mat4.identity(),
    projection_matrix: math.Mat4 = math.Mat4.identity(),
};

pub const Script = struct {
    // This would likely point to a script resource or state
    // For now, using a simple ID or pointer
    script_id: u64 = 0,
    data: ?*anyopaque = null,

    // Function pointers for callbacks could go here
    on_update: ?*const fn (data: ?*anyopaque, delta_time: f32) void = null,
};

pub const Name = struct {
    value: [64]u8 = [_]u8{0} ** 64,

    pub fn init(name: []const u8) Name {
        var n = Name{};
        const len = @min(name.len, 63);
        @memcpy(n.value[0..len], name[0..len]);
        n.value[len] = 0;
        return n;
    }

    pub fn slice(self: *const Name) []const u8 {
        return std.mem.sliceTo(&self.value, 0);
    }
};

pub const Hierarchy = struct {
    parent: ?u32 = null, // Entity ID
    first_child: ?u32 = null,
    next_sibling: ?u32 = null,
    prev_sibling: ?u32 = null,
    child_count: u32 = 0,
};
