//! Editor shared state.
//!
//! Owns the editor's UI toggles, selected entities/models, camera settings, and a view of loaded
//! scene data. This is passed across editor panels and systems each frame.
const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const window = engine.window;
const renderer = engine.vulkan_renderer;
const types = engine.vulkan_types;
const model_manager = engine.model_manager;
const scene = engine.scene;
const components = engine.ecs_components;
const loader = engine.loader;
const async_loader = engine.async_loader;
const animation = engine.animation;

const c = @import("c.zig").c;
const undo = @import("undo.zig");

/// Finds the active `EditorGlobals` entity, preferring `preferred` when valid.
pub fn resolveEditorGlobalsEntity(registry: *engine.ecs_registry.Registry, preferred: engine.ecs_entity.Entity) ?engine.ecs_entity.Entity {
    if (registry.entity_manager.is_alive(preferred) and registry.get(components.EditorGlobals, preferred) != null) {
        return preferred;
    }

    var view = registry.view(components.EditorGlobals);
    var it = view.iterator();
    if (it.next()) |entry| {
        if (registry.entity_manager.is_alive(entry.entity)) {
            return entry.entity;
        }
    }

    return null;
}

/// Asset browser UI state (directory, filters, and cached entries).
pub const AssetState = struct {
    entries: std.ArrayListUnmanaged(AssetEntry) = .{},
    filtered_entries: std.ArrayListUnmanaged(AssetEntry) = .{},
    current_dir: [:0]u8 = undefined,
    assets_dir: [:0]u8 = undefined,
    search_filter: []u8 = undefined,
    show_folders_only: bool = false,
    show_gltf_only: bool = false,
    show_textures_only: bool = false,
    last_scan_dir_hash: u64 = 0,
    last_scan_dir_mtime_ns: u64 = 0,

    pub const AssetType = enum {
        FOLDER,
        GLTF,
        GLB,
        TEXTURE,
        KFM,
        NIF,
        OTHER,
    };

    pub const AssetEntry = struct {
        display: [:0]u8,
        full_path: [:0]u8,
        relative_path: [:0]u8,
        type: AssetType,
        is_directory: bool,

        pub fn deinit(self: AssetEntry, alloc: std.mem.Allocator) void {
            alloc.free(self.display[0 .. self.display.len + 1]);
            alloc.free(self.full_path[0 .. self.full_path.len + 1]);
            alloc.free(self.relative_path[0 .. self.relative_path.len + 1]);
        }
    };
};

/// Tracks an async scene load and its eventual ECS import target.
pub const LoadingTaskInfo = struct {
    task: *async_loader.CardinalAsyncTask,
    path: [:0]u8,
    target_entity: ?engine.ecs_entity.Entity = null,
};

/// Cached terrain editing buffers and GPU texture indices.
///
/// `*_handle` fields store bindless texture indices owned by the renderer.
pub const TerrainData = struct {
    dims: u32,
    height: []f32,
    bottom_height: []f32,
    splat: []u8,
    height_handle: u32 = std.math.maxInt(u32),
    splat_handle: u32 = std.math.maxInt(u32),
    layer_handles: [4]u32 = .{
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(u32),
    },
    layer_imgui_ids: [4]u64 = .{ 0, 0, 0, 0 },
    layer_imgui_generations: [4]u64 = .{ 0, 0, 0, 0 },
};

pub const VolumetricTerrainData = struct {
    dims: u32,
    density: []f32,
    splat: []u8,
    splat_handle: u32 = std.math.maxInt(u32),
    layer_handles: [4]u32 = .{
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(u32),
    },
};

pub const VolumetricDirtyBox = struct {
    min_x: u32,
    min_y: u32,
    min_z: u32,
    max_x: u32,
    max_y: u32,
    max_z: u32,
};

pub const VolumetricBrickKey = struct {
    entity_id: u64,
    brick_id: u32,
};

pub const VolumetricBrickLodKey = struct {
    entity_id: u64,
    brick_id: u32,
    lod: u8,
};

pub const VolumetricTileMesh = struct {
    vertices: []scene.CardinalVertex,
    indices: []u32,
    vertex_count: u32 = 0,
    index_count: u32 = 0,
};

pub const VolumetricBrickTileCache = struct {
    data_id: u64 = 0,
    tiles: [8]VolumetricTileMesh = .{
        .{ .vertices = @constCast(&[_]scene.CardinalVertex{}), .indices = @constCast(&[_]u32{}), .vertex_count = 0, .index_count = 0 },
        .{ .vertices = @constCast(&[_]scene.CardinalVertex{}), .indices = @constCast(&[_]u32{}), .vertex_count = 0, .index_count = 0 },
        .{ .vertices = @constCast(&[_]scene.CardinalVertex{}), .indices = @constCast(&[_]u32{}), .vertex_count = 0, .index_count = 0 },
        .{ .vertices = @constCast(&[_]scene.CardinalVertex{}), .indices = @constCast(&[_]u32{}), .vertex_count = 0, .index_count = 0 },
        .{ .vertices = @constCast(&[_]scene.CardinalVertex{}), .indices = @constCast(&[_]u32{}), .vertex_count = 0, .index_count = 0 },
        .{ .vertices = @constCast(&[_]scene.CardinalVertex{}), .indices = @constCast(&[_]u32{}), .vertex_count = 0, .index_count = 0 },
        .{ .vertices = @constCast(&[_]scene.CardinalVertex{}), .indices = @constCast(&[_]u32{}), .vertex_count = 0, .index_count = 0 },
        .{ .vertices = @constCast(&[_]scene.CardinalVertex{}), .indices = @constCast(&[_]u32{}), .vertex_count = 0, .index_count = 0 },
    },
};

pub const VolumetricDensitySnapshotKey = struct {
    entity_id: u64,
    data_id: u64,
};

pub const VolumetricDensitySnapshot = struct {
    density: []f32,
    splat: []u8,
    ref_count: u32 = 0,
};

pub const MeshCapacity = struct {
    vertex_cap: u32,
    index_cap: u32,
};

pub const InspectorComponentOrder = struct {
    len: u8 = 0,
    order: [16]u8 = [_]u8{0} ** 16,
};

pub const ComponentClipboard = struct {
    has: bool = false,

    has_name: bool = false,
    name: components.Name = std.mem.zeroes(components.Name),

    has_transform: bool = false,
    transform: components.Transform = std.mem.zeroes(components.Transform),

    has_node: bool = false,
    node: components.Node = std.mem.zeroes(components.Node),

    has_mesh_renderer: bool = false,
    mesh_renderer: components.MeshRenderer = std.mem.zeroes(components.MeshRenderer),

    has_light: bool = false,
    light: components.Light = std.mem.zeroes(components.Light),

    has_camera: bool = false,
    camera: components.Camera = std.mem.zeroes(components.Camera),

    has_skybox: bool = false,
    skybox: components.Skybox = std.mem.zeroes(components.Skybox),

    has_script: bool = false,
    script: components.Script = std.mem.zeroes(components.Script),
};

pub const TerrainDirtyRect = struct {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
};

pub const VolumetricSplatDirtyRect = struct {
    min_x: u32,
    min_z: u32,
    max_x: u32,
    max_z: u32,
};

pub const AssetThumbnail = struct {
    handle: u32 = std.math.maxInt(u32),
    imgui_id: u64 = 0,
    imgui_backend_user_data_ptr: u64 = 0,
    imgui_vulkan_generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// Per-frame runtime state shared across editor panels and systems.
pub const EditorRuntimeState = struct {
    renderer: *types.CardinalRenderer = undefined,
    window: *window.CardinalWindow = undefined,
    registry: *engine.ecs_registry.Registry = undefined,
    descriptor_pool: c.VkDescriptorPool = null,

    /// Temporary arena used for per-frame allocations in editor code.
    arena: std.heap.ArenaAllocator = undefined,
    arena_allocator: std.mem.Allocator = undefined,

    /// Persistent config manager for editor settings and recent projects.
    config_manager: engine.config.ConfigManager = undefined,

    /// Runtime model manager used by the editor.
    model_manager: model_manager.CardinalModelManager = undefined,
    /// Aggregated scene used for editor UI display and import/export.
    combined_scene: scene.CardinalScene = undefined,
    scene_loaded: bool = false,
    loading_tasks: std.ArrayListUnmanaged(LoadingTaskInfo) = .{},
    is_loading: bool = false,

    /// When set, the renderer should upload `pending_scene` next frame.
    scene_upload_pending: bool = false,
    pending_scene: scene.CardinalScene = undefined,

    /// Skybox path used by the renderer (HDR/EXR only).
    skybox_path: ?[:0]u8 = null,

    transform_overrides: std.AutoHashMapUnmanaged(u64, void) = .{},
    mesh_owner_by_mesh_index: std.AutoHashMapUnmanaged(u32, u64) = .{},
    mesh_entity_by_mesh_index: std.AutoHashMapUnmanaged(u32, u64) = .{},
    model_root_by_id: std.AutoHashMapUnmanaged(u32, u64) = .{},
    terrain_data_by_entity: std.AutoHashMapUnmanaged(u64, TerrainData) = .{},
    terrain_dirty_rects: std.AutoHashMapUnmanaged(u64, TerrainDirtyRect) = .{},
    volumetric_terrain_data_by_entity: std.AutoHashMapUnmanaged(u64, VolumetricTerrainData) = .{},
    volumetric_splat_dirty_rects: std.AutoHashMapUnmanaged(u64, VolumetricSplatDirtyRect) = .{},
    volumetric_dirty_boxes: std.AutoHashMapUnmanaged(u64, VolumetricDirtyBox) = .{},
    volumetric_dirty_lod_masks: std.AutoHashMapUnmanaged(u64, u8) = .{},
    volumetric_remesh_tasks: std.AutoHashMapUnmanaged(u64, *async_loader.CardinalAsyncTask) = .{},
    volumetric_lod_by_entity: std.AutoHashMapUnmanaged(u64, u8) = .{},
    volumetric_visible_by_entity: std.AutoHashMapUnmanaged(u64, bool) = .{},
    volumetric_mesh_caps: std.AutoHashMapUnmanaged(u32, MeshCapacity) = .{},
    volumetric_dirty_brick_boxes: std.AutoHashMapUnmanaged(VolumetricBrickKey, VolumetricDirtyBox) = .{},
    volumetric_dirty_brick_lod_masks: std.AutoHashMapUnmanaged(VolumetricBrickKey, u8) = .{},
    volumetric_brick_generation: std.AutoHashMapUnmanaged(VolumetricBrickKey, u32) = .{},
    volumetric_brick_remesh_tasks: std.AutoHashMapUnmanaged(VolumetricBrickKey, *async_loader.CardinalAsyncTask) = .{},
    volumetric_brick_last_schedule_ms: std.AutoHashMapUnmanaged(VolumetricBrickKey, u64) = .{},
    volumetric_brick_tile_cache: std.AutoHashMapUnmanaged(VolumetricBrickLodKey, VolumetricBrickTileCache) = .{},
    volumetric_density_snapshots: std.AutoHashMapUnmanaged(VolumetricDensitySnapshotKey, VolumetricDensitySnapshot) = .{},
    asset_thumbnails: std.StringHashMapUnmanaged(AssetThumbnail) = .{},

    /// Camera state passed to the renderer.
    camera: types.CardinalCamera = undefined,
    /// Primary light passed to the renderer.
    light: types.CardinalLight = undefined,
    pbr_enabled: bool = true,
    enable_directional_light: bool = false,
    enable_shadows: bool = true,

    post_process: types.PostProcessParams = .{
        .exposure = 1.0,
        .contrast = 1.0,
        .saturation = 1.0,
        .bloomIntensity = 0.04,
        .bloomThreshold = 1.0,
        .bloomKnee = 0.1,
        .padding = .{ 0.0, 0.0 },
    },

    /// Whether the editor has captured the mouse (FPS camera mode).
    mouse_captured: bool = false,
    picking_cache_dirty: bool = false,
    yaw: f32 = 90.0,
    pitch: f32 = 0.0,
    camera_speed: f32 = 5.0,
    mouse_sensitivity: f32 = 0.1,

    /// Create-node popup state.
    create_node_parent: ?engine.ecs_entity.Entity = null,
    create_node_search: [128]u8 = [_]u8{0} ** 128,

    globals_entity: engine.ecs_entity.Entity = .{ .id = std.math.maxInt(u64) },
    preview_game_camera: bool = false,

    /// Marks `root` and all descendants so their render meshes will be driven by ECS transforms.
    ///
    /// This is used by the inspector and gizmo to make edits immediately visible, while keeping
    /// untouched meshes controlled by the model manager / animation system.
    pub fn mark_transform_override_tree(self: *EditorRuntimeState, root: engine.ecs_entity.Entity) void {
        const allocator = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

        var stack: std.ArrayListUnmanaged(engine.ecs_entity.Entity) = .{};
        defer stack.deinit(allocator);

        stack.append(allocator, root) catch return;

        while (stack.items.len > 0) {
            const last = stack.items.len - 1;
            const e = stack.items[last];
            stack.items.len = last;

            self.transform_overrides.put(allocator, e.id, {}) catch {};

            const h = self.registry.get(engine.ecs_components.Hierarchy, e) orelse continue;
            var child = h.first_child;
            var guard: u32 = 0;
            while (child) |c_ent| {
                if (guard > 100000) break;
                guard += 1;

                stack.append(allocator, c_ent) catch return;

                const ch = self.registry.get(engine.ecs_components.Hierarchy, c_ent) orelse break;
                child = ch.next_sibling;
            }
        }
    }
};

/// UI state for all editor panels and popups.
pub const EditorUiState = struct {
    status_msg: [256]u8 = [_]u8{0} ** 256,
    scene_path: [512]u8 = [_]u8{0} ** 512,
    save_scene_name: [256]u8 = [_]u8{0} ** 256,
    available_scenes: std.ArrayListUnmanaged([]const u8) = .{},
    scene_context_menu_name: [256]u8 = [_]u8{0} ** 256,
    rename_scene_buffer: [256]u8 = [_]u8{0} ** 256,
    open_rename_popup: bool = false,
    open_delete_popup: bool = false,

    enable_viewports: bool = false,

    selected_model_id: u32 = 0,
    selected_entity: engine.ecs_entity.Entity = .{ .id = std.math.maxInt(u64) },
    selected_entities: std.AutoHashMapUnmanaged(u64, void) = .{},
    scene_graph_focus_target_id: u64 = std.math.maxInt(u64),
    scene_graph_focus_pending: bool = false,
    scene_graph_open_chain: [128]u64 = [_]u64{0} ** 128,
    scene_graph_open_chain_len: u8 = 0,
    scene_graph_open_state: std.AutoHashMapUnmanaged(u64, bool) = .{},
    scene_graph_search: [128]u8 = [_]u8{0} ** 128,
    scene_graph_filter_meshes: bool = false,
    scene_graph_filter_lights: bool = false,
    scene_graph_filter_cameras: bool = false,

    renaming_entity: engine.ecs_entity.Entity = .{ .id = std.math.maxInt(u64) },
    rename_buffer: [256]u8 = [_]u8{0} ** 256,
    inspector_last_entity_id: u64 = std.math.maxInt(u64),
    inspector_name_buffer: [256]u8 = [_]u8{0} ** 256,
    inspector_skybox_buffer: [256]u8 = [_]u8{0} ** 256,
    inspector_node_type_search: [128]u8 = [_]u8{0} ** 128,
    inspector_add_component_search: [128]u8 = [_]u8{0} ** 128,
    inspector_rotation_euler_deg: [3]f32 = .{ 0.0, 0.0, 0.0 },
    inspector_rotation_editing: bool = false,
    inspector_rotation_world_euler_deg: [3]f32 = .{ 0.0, 0.0, 0.0 },
    inspector_rotation_world_editing: bool = false,
    inspector_force_open: i8 = 0,
    inspector_pinned_mask: u32 = 0,
    inspector_component_order_by_entity: std.AutoHashMapUnmanaged(u64, InspectorComponentOrder) = .{},
    transform_space_world: bool = false,
    transform_clipboard_valid: bool = false,
    transform_clipboard_pos: [3]f32 = .{ 0.0, 0.0, 0.0 },
    transform_clipboard_rot: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    transform_clipboard_scale: [3]f32 = .{ 1.0, 1.0, 1.0 },
    component_clipboard: ComponentClipboard = .{},
    inspector_last_model_id: u32 = 0,
    inspector_model_rotation_euler_deg: [3]f32 = .{ 0.0, 0.0, 0.0 },
    inspector_model_rotation_editing: bool = false,

    show_scene_graph: bool = true,
    show_scene_view: bool = true,
    show_game_view: bool = false,
    show_assets: bool = true,
    show_model_manager: bool = true,
    show_entity_inspector: bool = true,
    show_scene_manager: bool = true,
    show_pbr_settings: bool = true,
    show_animation: bool = true,
    show_terrain_panel: bool = true,
    show_project_manager: bool = true,

    assets: AssetState = .{},

    selected_animation: i32 = -1,
    animation_time: f32 = 0.0,
    animation_playing: bool = false,
    animation_looping: bool = true,
    animation_speed: f32 = 1.0,

    material_override_enabled: bool = false,
    material_albedo: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    material_metallic: f32 = 0.0,
    material_roughness: f32 = 0.5,
    material_emissive: [3]f32 = .{ 0.0, 0.0, 0.0 },
    material_normal_scale: f32 = 1.0,
    material_ao_strength: f32 = 1.0,

    show_material_0_toggle: bool = true,
    show_grid_axes: bool = true,
    show_performance_panel: bool = true,

    terrain_sculpt_enabled: bool = false,
    terrain_tool: i32 = 0,
    terrain_sculpt_mode: i32 = 0,
    terrain_sculpt_surface: i32 = 0,
    terrain_paint_color: [3]f32 = .{ 0.8, 0.2, 0.2 },
    terrain_paint_layer: i32 = 0,
    terrain_carve_mode: i32 = 0,
    terrain_brush_radius: f32 = 2.0,
    terrain_brush_strength: f32 = 0.5,
    terrain_brush_falloff: i32 = 0,
    terrain_brush_spacing: f32 = 0.0,
    terrain_brush_stamp_valid: bool = false,
    terrain_brush_stamp_pos: [3]f32 = .{ 0.0, 0.0, 0.0 },
    terrain_brush_last_mouse_down: bool = false,
    terrain_create_resolution: f32 = 128.0,
    terrain_create_size: f32 = 64.0,
    terrain_create_thickness: f32 = 8.0,
    terrain_create_volume: bool = true,
    volumetric_grid_x: i32 = 2,
    volumetric_grid_z: i32 = 2,
    terrain_default_texture_path: [512]u8 = [_]u8{0} ** 512,
    terrain_texture_tiling: f32 = 8.0,
    terrain_brush_outline_enabled: bool = false,
    terrain_brush_outline_pos: [3]f32 = .{ 0.0, 0.0, 0.0 },
    terrain_brush_outline_radius: f32 = 0.0,
    terrain_brush_outline_strength: f32 = 0.0,
    terrain_brush_outline_tool: i32 = 0,
    terrain_brush_outline_mode: i32 = 0,
    terrain_brush_outline_surface: i32 = 0,

    undo: undo.UndoState = .{},

    project: ?@import("project.zig").Project = null,
    project_loaded: bool = false,
};

/// Top-level editor state passed to editor systems each frame.
pub const EditorState = struct {
    runtime: EditorRuntimeState = .{},
    ui: EditorUiState = .{},
};
