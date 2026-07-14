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

pub const Terrain = struct {
    size: math.Vec2 = .{ .x = 64.0, .y = 64.0 },
    resolution: u32 = 128,
    thickness: f32 = 8.0,
    model_id: u32 = 0,
    mesh_index: u32 = 0,
    data_id: u64 = 0,
};

pub const VolumetricTerrain = struct {
    size: math.Vec3 = .{ .x = 64.0, .y = 32.0, .z = 64.0 },
    resolution: u32 = 16,
    chunk_x: i32 = 0,
    chunk_y: i32 = 0,
    chunk_z: i32 = 0,
    model_id: u32 = 0,
    mesh_index: u32 = 0,
    data_id: u64 = 0,
};

pub const VolumetricTerrainBrick = struct {
    parent_id: u64 = 0,
    brick_id: u32 = 0,
};

pub const EditorOnly = struct { value: u8 = 0 };

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

pub const Skybox = struct {
    path: [256]u8 = [_]u8{0} ** 256,

    pub fn init(path: []const u8) Skybox {
        var s = Skybox{};
        const len = @min(path.len, 255);
        @memcpy(s.path[0..len], path[0..len]);
        s.path[len] = 0;
        return s;
    }

    pub fn slice(self: *const Skybox) []const u8 {
        return std.mem.sliceTo(&self.path, 0);
    }
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
    /// Cached tail pointer for O(1) appends.
    last_child: ?entity_pkg.Entity = null,
    next_sibling: ?entity_pkg.Entity = null,
    prev_sibling: ?entity_pkg.Entity = null,
    child_count: u32 = 0,
};

/// High-level node category.
pub const NodeType = enum {
    Node,

    Node3D,
    Marker3D,
    Camera3D,
    MeshInstance3D,
    Terrain3D,
    DirectionalLight3D,
    PointLight3D,
    SpotLight3D,
    Skybox,
    AnimationPlayer,
    Skeleton3D,
    StaticBody3D,
    RigidBody3D,
    CharacterBody3D,
    Area3D,
    CollisionShape3D,
    NavigationRegion3D,
    AudioStreamPlayer3D,
    GPUParticles3D,

    Node2D,
    Camera2D,
    Sprite2D,
    AnimatedSprite2D,
    TileMap,
    StaticBody2D,
    RigidBody2D,
    CharacterBody2D,
    Area2D,
    CollisionShape2D,
    AudioStreamPlayer2D,
    GPUParticles2D,

    NodeUI,
    Control,
    Label,
    Button,
    Panel,
    TextureRect,
    CheckBox,
    Slider,
    ProgressBar,
    LineEdit,
    TextEdit,
    VBoxContainer,
    HBoxContainer,
    GridContainer,
    MarginContainer,
    ScrollContainer,
};

/// Generic node marker component.
pub const Node = struct {
    type: NodeType = .Node3D,
};

pub const EditorGlobals = struct {
    camera_position: math.Vec3 = math.Vec3{ .x = 0.0, .y = 2.0, .z = 5.0 },
    camera_target: math.Vec3 = math.Vec3{ .x = 0.0, .y = 0.0, .z = 0.0 },
    camera_up: math.Vec3 = math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 },
    camera_fov: f32 = 65.0,
    camera_aspect: f32 = 16.0 / 9.0,
    camera_near: f32 = 0.1,
    camera_far: f32 = 100.0,

    selected_entity_id: u64 = std.math.maxInt(u64),

    show_scene_graph: bool = true,
    show_scene_view: bool = true,
    show_game_view: bool = true,
    show_assets: bool = true,
    show_model_manager: bool = true,
    show_entity_inspector: bool = true,
    show_scene_manager: bool = true,
    show_pbr_settings: bool = true,
    show_animation: bool = true,
    show_terrain_panel: bool = true,
    show_grid_axes: bool = true,
    show_performance_panel: bool = true,
    enable_viewports: bool = true,

    game_camera_entity_id: u64 = std.math.maxInt(u64),

    pbr_enabled: bool = true,
    enable_shadows: bool = true,
    rendering_mode: u32 = 0,

    post_exposure: f32 = 1.0,
    post_contrast: f32 = 1.0,
    post_saturation: f32 = 1.0,
    post_bloom_intensity: f32 = 0.04,
    post_bloom_threshold: f32 = 1.0,
    post_bloom_knee: f32 = 0.1,
};
