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
        OTHER,
    };

    pub const AssetEntry = struct {
        display: [:0]u8,
        full_path: [:0]u8,
        relative_path: [:0]u8,
        type: AssetType,
        is_directory: bool,

        pub fn deinit(self: AssetEntry, alloc: std.mem.Allocator) void {
            // Free the full allocated size (len + 1 for sentinel)
            alloc.free(self.display[0 .. self.display.len + 1]);
            alloc.free(self.full_path[0 .. self.full_path.len + 1]);
            alloc.free(self.relative_path[0 .. self.relative_path.len + 1]);
        }
    };
};

pub const LoadingTaskInfo = struct {
    task: *async_loader.CardinalAsyncTask,
    path: [:0]u8,
};

pub const EditorState = struct {
    renderer: *types.CardinalRenderer = undefined,
    window: *window.CardinalWindow = undefined,
    registry: *engine.ecs_registry.Registry = undefined,
    descriptor_pool: c.VkDescriptorPool = null,

    // Temporary Arena
    arena: std.heap.ArenaAllocator = undefined,
    arena_allocator: std.mem.Allocator = undefined,

    // Config
    config_manager: engine.config.ConfigManager = undefined,

    // Scene & Models
    model_manager: model_manager.CardinalModelManager = undefined,
    combined_scene: scene.CardinalScene = undefined,
    scene_loaded: bool = false,
    loading_tasks: std.ArrayListUnmanaged(LoadingTaskInfo) = .{},
    is_loading: bool = false,

    // Scene Upload
    scene_upload_pending: bool = false,
    pending_scene: scene.CardinalScene = undefined,

    // Skybox Loading
    skybox_path: ?[:0]u8 = null,

    // UI State
    status_msg: [256]u8 = [_]u8{0} ** 256,
    scene_path: [512]u8 = [_]u8{0} ** 512,
    save_scene_name: [256]u8 = [_]u8{0} ** 256, // New: for saving with name
    available_scenes: std.ArrayListUnmanaged([]const u8) = .{}, // New: for listing scenes
    scene_context_menu_name: [256]u8 = [_]u8{0} ** 256,
    rename_scene_buffer: [256]u8 = [_]u8{0} ** 256,
    open_rename_popup: bool = false,
    open_delete_popup: bool = false,
    selected_model_id: u32 = 0,

    // Panel Visibility
    show_scene_graph: bool = true,
    show_assets: bool = true,
    show_model_manager: bool = true,
    show_scene_manager: bool = true,
    show_pbr_settings: bool = true,
    show_animation: bool = true,
    show_memory_stats: bool = false,

    // Assets
    assets: AssetState = .{},

    // Camera & Light
    camera: types.CardinalCamera = undefined,
    light: types.CardinalLight = undefined,
    pbr_enabled: bool = true,
    enable_directional_light: bool = true,

    // Camera Control
    mouse_captured: bool = false,
    // last_mouse_x/y and first_mouse handled by engine input
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

    // UI Toggles
    show_material_0_toggle: bool = true,
    tab_key_pressed: bool = false,
};
