//! Editor shared state.
//!
//! Owns the editor's UI toggles, selected entities/models, camera settings, and a view of loaded
//! scene data. This is passed across editor panels and systems each frame.
//!
//! TODO: Split renderer-facing state from UI state to reduce coupling.
const std = @import("std");
const engine = @import("cardinal_engine");
const log = engine.log;
const window = engine.window;
const renderer = engine.vulkan_renderer;
const types = engine.vulkan_types;
const model_manager = engine.model_manager;
const scene = engine.scene;
const loader = engine.loader;
const async_loader = engine.async_loader;
const animation = engine.animation;

const c = @import("c.zig").c;

pub const AssetState = struct {
    entries: std.ArrayListUnmanaged(AssetEntry) = .{},
    filtered_entries: std.ArrayListUnmanaged(AssetEntry) = .{},
    current_dir: [:0]u8 = undefined,
    assets_dir: [:0]u8 = undefined,
    search_filter: []u8 = undefined,
    show_folders_only: bool = false,
    show_gltf_only: bool = false,
    show_textures_only: bool = false,

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

pub const LoadingTaskInfo = struct {
    task: *async_loader.CardinalAsyncTask,
    path: [:0]u8,
    target_entity: ?engine.ecs_entity.Entity = null,
};

pub const EditorState = struct {
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

    /// Create-node popup state.
    create_node_parent: ?engine.ecs_entity.Entity = null,
    create_node_search: [128]u8 = [_]u8{0} ** 128,

    /// Status text shown in the editor UI.
    status_msg: [256]u8 = [_]u8{0} ** 256,
    scene_path: [512]u8 = [_]u8{0} ** 512,
    save_scene_name: [256]u8 = [_]u8{0} ** 256,
    available_scenes: std.ArrayListUnmanaged([]const u8) = .{},
    scene_context_menu_name: [256]u8 = [_]u8{0} ** 256,
    rename_scene_buffer: [256]u8 = [_]u8{0} ** 256,
    open_rename_popup: bool = false,
    open_delete_popup: bool = false,
    selected_model_id: u32 = 0,
    selected_entity: engine.ecs_entity.Entity = .{ .id = std.math.maxInt(u64) },
    scene_graph_focus_target_id: u64 = std.math.maxInt(u64),
    scene_graph_focus_pending: bool = false,
    scene_graph_open_chain: [128]u64 = [_]u64{0} ** 128,
    scene_graph_open_chain_len: u8 = 0,
    transform_overrides: std.AutoHashMapUnmanaged(u64, void) = .{},

    /// Entity currently being renamed, if any.
    renaming_entity: engine.ecs_entity.Entity = .{ .id = std.math.maxInt(u64) },
    rename_buffer: [256]u8 = [_]u8{0} ** 256,
    inspector_last_entity_id: u64 = std.math.maxInt(u64),
    inspector_name_buffer: [256]u8 = [_]u8{0} ** 256,
    inspector_skybox_buffer: [256]u8 = [_]u8{0} ** 256,
    inspector_node_type_search: [128]u8 = [_]u8{0} ** 128,
    inspector_add_component_search: [128]u8 = [_]u8{0} ** 128,
    inspector_rotation_euler_deg: [3]f32 = .{ 0.0, 0.0, 0.0 },

    /// Panel visibility toggles.
    show_scene_graph: bool = true,
    show_scene_view: bool = true,
    show_assets: bool = true,
    show_model_manager: bool = true,
    show_entity_inspector: bool = true,
    show_scene_manager: bool = true,
    show_pbr_settings: bool = true,
    show_animation: bool = true,
    show_project_manager: bool = true,

    /// Asset browser state (current directory, filter, and entry lists).
    assets: AssetState = .{},

    /// Camera state passed to the renderer.
    camera: types.CardinalCamera = undefined,
    /// Primary light passed to the renderer.
    light: types.CardinalLight = undefined,
    pbr_enabled: bool = true,
    enable_directional_light: bool = true,

    /// Whether the editor has captured the mouse (FPS camera mode).
    mouse_captured: bool = false,
    yaw: f32 = 90.0,
    pitch: f32 = 0.0,
    camera_speed: f32 = 5.0,
    mouse_sensitivity: f32 = 0.1,

    // Animation
    selected_animation: i32 = -1,
    animation_time: f32 = 0.0,
    animation_playing: bool = false,
    animation_looping: bool = true,
    animation_speed: f32 = 1.0,

    // Material Override
    material_override_enabled: bool = false,
    material_albedo: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    material_metallic: f32 = 0.0,
    material_roughness: f32 = 0.5,
    material_emissive: [3]f32 = .{ 0.0, 0.0, 0.0 },
    material_normal_scale: f32 = 1.0,
    material_ao_strength: f32 = 1.0,

    // Post Process
    post_process: types.PostProcessParams = .{
        .exposure = 1.0,
        .contrast = 1.0,
        .saturation = 1.0,
        .bloomIntensity = 0.04,
        .bloomThreshold = 1.0,
        .bloomKnee = 0.1,
        .padding = .{ 0.0, 0.0 },
    },

    // UI Toggles
    show_material_0_toggle: bool = true,
    show_grid_axes: bool = true,

    // Optimization Settings
    show_performance_panel: bool = true,

    // Project
    project: ?@import("project.zig").Project = null,
    project_loaded: bool = false,

    pub fn mark_transform_override_tree(self: *EditorState, root: engine.ecs_entity.Entity) void {
        const allocator = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

        var stack: [256]engine.ecs_entity.Entity = undefined;
        var sp: usize = 0;

        stack[sp] = root;
        sp += 1;

        while (sp > 0) {
            sp -= 1;
            const e = stack[sp];

            self.transform_overrides.put(allocator, e.id, {}) catch {};

            const h = self.registry.get(engine.ecs_components.Hierarchy, e) orelse continue;
            var child = h.first_child;
            var guard: u32 = 0;
            while (child) |c_ent| {
                if (guard > 100000) break;
                guard += 1;

                if (sp < stack.len) {
                    stack[sp] = c_ent;
                    sp += 1;
                }

                const ch = self.registry.get(engine.ecs_components.Hierarchy, c_ent) orelse break;
                child = ch.next_sibling;
            }
        }
    }
};
