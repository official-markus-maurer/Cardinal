//! Editor layer.
//!
//! Owns editor state, panels, and per-frame UI orchestration on top of the engine runtime.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const Vec3 = math.Vec3;
const log = engine.log;
const platform = engine.platform;
const window = engine.window;
const renderer = engine.vulkan_renderer;
const types = engine.vulkan_types;
const components = engine.ecs_components;
const node_factory = engine.ecs_node_factory;
const model_manager = engine.model_manager;
const scene = engine.scene;
const loader = engine.loader;
const async_loader = engine.async_loader;
const animation = engine.animation;
const scene_serializer = engine.scene_serializer;

const editor_state = @import("editor_state.zig");
const EditorState = editor_state.EditorState;
const AssetState = editor_state.AssetState;

const hierarchy_panel = @import("panels/hierarchy_panel.zig");
const content_browser = @import("panels/content_browser.zig");
const inspector = @import("panels/inspector.zig");
const animation_panel = @import("panels/animation_panel.zig");
const scene_manager_panel = @import("panels/scene_manager_panel.zig");
const terrain_panel = @import("panels/terrain_panel.zig");
const selection_system = @import("systems/selection_system.zig");
const performance_panel = @import("panels/performance_panel.zig");
const input_system = @import("systems/input.zig");
const camera_controller = @import("systems/camera_controller.zig");
const scene_io = @import("systems/scene_io.zig");
const scene_sync = @import("systems/editor_scene_sync.zig");
const project_manager = @import("panels/project_manager.zig");

const c = @import("c.zig").c;

/// Global allocator for editor-owned state.
const allocator = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

var state: EditorState = undefined;
var initialized: bool = false;
var device_recovery_failed: bool = false;
var imgui_context: ?*anyopaque = null;
var world_matrix_cache: std.AutoHashMapUnmanaged(u64, math.Mat4) = .{};

fn ensure_globals_entity() void {
    if (editor_state.resolveEditorGlobalsEntity(state.runtime.registry, state.runtime.globals_entity)) |ent| {
        state.runtime.globals_entity = ent;
        return;
    }

    const created = node_factory.create_node(state.runtime.registry, null, components.NodeType.Node, "Globals", .{}) catch return;

    var g = components.EditorGlobals{};
    g.camera_position = state.runtime.camera.position;
    g.camera_target = state.runtime.camera.target;
    g.camera_up = state.runtime.camera.up;
    g.camera_fov = state.runtime.camera.fov;
    g.camera_aspect = state.runtime.camera.aspect;
    g.camera_near = state.runtime.camera.near_plane;
    g.camera_far = state.runtime.camera.far_plane;

    g.selected_entity_id = state.ui.selected_entity.id;

    g.show_scene_graph = state.ui.show_scene_graph;
    g.show_scene_view = state.ui.show_scene_view;
    g.show_game_view = state.ui.show_game_view;
    g.show_assets = state.ui.show_assets;
    g.show_model_manager = state.ui.show_model_manager;
    g.show_entity_inspector = state.ui.show_entity_inspector;
    g.show_scene_manager = state.ui.show_scene_manager;
    g.show_pbr_settings = state.ui.show_pbr_settings;
    g.show_animation = state.ui.show_animation;
    g.show_terrain_panel = state.ui.show_terrain_panel;
    g.show_grid_axes = state.ui.show_grid_axes;
    g.show_performance_panel = state.ui.show_performance_panel;
    g.enable_viewports = false;

    g.game_camera_entity_id = std.math.maxInt(u64);

    g.pbr_enabled = state.runtime.pbr_enabled;
    g.rendering_mode = @as(u32, @intCast(@intFromEnum(renderer.cardinal_renderer_get_rendering_mode(state.runtime.renderer))));

    g.post_exposure = state.runtime.post_process.exposure;
    g.post_contrast = state.runtime.post_process.contrast;
    g.post_saturation = state.runtime.post_process.saturation;
    g.post_bloom_intensity = state.runtime.post_process.bloomIntensity;
    g.post_bloom_threshold = state.runtime.post_process.bloomThreshold;
    g.post_bloom_knee = state.runtime.post_process.bloomKnee;

    state.runtime.registry.add(created, g) catch {};
    state.runtime.globals_entity = created;
}

fn apply_globals_to_state() void {
    ensure_globals_entity();
    const g = state.runtime.registry.get(components.EditorGlobals, state.runtime.globals_entity) orelse return;

    state.runtime.camera.position = g.camera_position;
    state.runtime.camera.target = g.camera_target;
    state.runtime.camera.up = g.camera_up;
    state.runtime.camera.fov = g.camera_fov;
    state.runtime.camera.aspect = g.camera_aspect;
    state.runtime.camera.near_plane = g.camera_near;
    state.runtime.camera.far_plane = g.camera_far;

    state.ui.show_scene_graph = g.show_scene_graph;
    state.ui.show_scene_view = g.show_scene_view;
    state.ui.show_game_view = false;
    state.ui.show_assets = g.show_assets;
    state.ui.show_model_manager = g.show_model_manager;
    state.ui.show_entity_inspector = g.show_entity_inspector;
    state.ui.show_scene_manager = g.show_scene_manager;
    state.ui.show_pbr_settings = g.show_pbr_settings;
    state.ui.show_animation = g.show_animation;
    state.ui.show_terrain_panel = g.show_terrain_panel;
    state.ui.show_performance_panel = g.show_performance_panel;

    if (state.ui.show_grid_axes != g.show_grid_axes) {
        state.ui.show_grid_axes = g.show_grid_axes;
        renderer.cardinal_renderer_set_debug_grid(state.runtime.renderer, state.ui.show_grid_axes);
    }

    if (state.ui.enable_viewports != g.enable_viewports) {
        state.ui.enable_viewports = false;
        c.imgui_bridge_enable_viewports(false);
    }

    const desired_pbr = g.pbr_enabled;
    if (state.runtime.pbr_enabled != desired_pbr) {
        state.runtime.pbr_enabled = desired_pbr;
        renderer.cardinal_renderer_enable_pbr(state.runtime.renderer, state.runtime.pbr_enabled);
        if (state.runtime.pbr_enabled) {
            renderer.cardinal_renderer_set_camera(state.runtime.renderer, &state.runtime.camera);
            renderer.cardinal_renderer_set_lighting(state.runtime.renderer, &state.runtime.light);
        }
    }

    const desired_mode: types.CardinalRenderingMode = combo_index_to_rendering_mode(@intCast(@min(g.rendering_mode, 3)));
    const current_mode = renderer.cardinal_renderer_get_rendering_mode(state.runtime.renderer);
    if (current_mode != desired_mode) {
        renderer.cardinal_renderer_set_rendering_mode(state.runtime.renderer, desired_mode);
    }

    var pp_changed = false;
    if (state.runtime.post_process.exposure != g.post_exposure) {
        state.runtime.post_process.exposure = g.post_exposure;
        pp_changed = true;
    }
    if (state.runtime.post_process.contrast != g.post_contrast) {
        state.runtime.post_process.contrast = g.post_contrast;
        pp_changed = true;
    }
    if (state.runtime.post_process.saturation != g.post_saturation) {
        state.runtime.post_process.saturation = g.post_saturation;
        pp_changed = true;
    }
    if (state.runtime.post_process.bloomIntensity != g.post_bloom_intensity) {
        state.runtime.post_process.bloomIntensity = g.post_bloom_intensity;
        pp_changed = true;
    }
    if (state.runtime.post_process.bloomThreshold != g.post_bloom_threshold) {
        state.runtime.post_process.bloomThreshold = g.post_bloom_threshold;
        pp_changed = true;
    }
    if (state.runtime.post_process.bloomKnee != g.post_bloom_knee) {
        state.runtime.post_process.bloomKnee = g.post_bloom_knee;
        pp_changed = true;
    }
    if (pp_changed) {
        renderer.cardinal_renderer_set_post_process_params(state.runtime.renderer, &state.runtime.post_process);
    }

    if (g.selected_entity_id != std.math.maxInt(u64)) {
        const ent = engine.ecs_entity.Entity{ .id = g.selected_entity_id };
        if (state.runtime.registry.entity_manager.is_alive(ent)) {
            state.ui.selected_entity = ent;
            const alloc = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
            state.ui.selected_entities.clearRetainingCapacity();
            state.ui.selected_entities.put(alloc, ent.id, {}) catch {};
        }
    }
}

fn persist_state_to_globals() void {
    const g = state.runtime.registry.get(components.EditorGlobals, state.runtime.globals_entity) orelse return;

    g.camera_position = state.runtime.camera.position;
    g.camera_target = state.runtime.camera.target;
    g.camera_up = state.runtime.camera.up;
    g.camera_fov = state.runtime.camera.fov;
    g.camera_aspect = state.runtime.camera.aspect;
    g.camera_near = state.runtime.camera.near_plane;
    g.camera_far = state.runtime.camera.far_plane;

    g.selected_entity_id = state.ui.selected_entity.id;

    g.show_scene_graph = state.ui.show_scene_graph;
    g.show_scene_view = state.ui.show_scene_view;
    g.show_game_view = false;
    g.show_assets = state.ui.show_assets;
    g.show_model_manager = state.ui.show_model_manager;
    g.show_entity_inspector = state.ui.show_entity_inspector;
    g.show_scene_manager = state.ui.show_scene_manager;
    g.show_pbr_settings = state.ui.show_pbr_settings;
    g.show_animation = state.ui.show_animation;
    g.show_terrain_panel = state.ui.show_terrain_panel;
    g.show_grid_axes = state.ui.show_grid_axes;
    g.show_performance_panel = state.ui.show_performance_panel;
    g.enable_viewports = false;

    g.pbr_enabled = state.runtime.pbr_enabled;
    g.rendering_mode = @as(u32, @intCast(@intFromEnum(renderer.cardinal_renderer_get_rendering_mode(state.runtime.renderer))));

    g.post_exposure = state.runtime.post_process.exposure;
    g.post_contrast = state.runtime.post_process.contrast;
    g.post_saturation = state.runtime.post_process.saturation;
    g.post_bloom_intensity = state.runtime.post_process.bloomIntensity;
    g.post_bloom_threshold = state.runtime.post_process.bloomThreshold;
    g.post_bloom_knee = state.runtime.post_process.bloomKnee;
}

fn compute_entity_world_matrix(entity: engine.ecs_entity.Entity, depth: u32) math.Mat4 {
    if (depth > 2048) return math.Mat4.identity();

    var parent_world = math.Mat4.identity();
    if (state.runtime.registry.get(components.Hierarchy, entity)) |h| {
        if (h.parent) |p| {
            if (state.runtime.registry.entity_manager.is_alive(p)) {
                parent_world = compute_entity_world_matrix(p, depth + 1);
            }
        }
    }

    const local = if (state.runtime.registry.get(components.Transform, entity)) |t|
        math.Mat4.fromTRS(t.position, t.rotation, t.scale)
    else
        math.Mat4.identity();

    return parent_world.mul(local);
}

fn resolve_game_camera_entity() ?engine.ecs_entity.Entity {
    ensure_globals_entity();
    const g = state.runtime.registry.get(components.EditorGlobals, state.runtime.globals_entity) orelse return null;

    if (g.game_camera_entity_id != std.math.maxInt(u64)) {
        const ent = engine.ecs_entity.Entity{ .id = g.game_camera_entity_id };
        if (state.runtime.registry.entity_manager.is_alive(ent) and state.runtime.registry.get(components.Camera, ent) != null) {
            return ent;
        }
    }

    var fallback: ?engine.ecs_entity.Entity = null;
    var view = state.runtime.registry.view(components.Camera);
    var it = view.iterator();
    while (it.next()) |entry| {
        const ent = entry.entity;
        if (!state.runtime.registry.entity_manager.is_alive(ent)) continue;
        if (state.runtime.registry.get(components.Name, ent)) |n| {
            const s = n.slice();
            if (std.mem.eql(u8, s, "MainCamera") or std.mem.eql(u8, s, "Main Camera")) return ent;
        }
        if (fallback == null) fallback = ent;
    }
    return fallback;
}

fn resolve_game_view_camera() ?types.CardinalCamera {
    const ent = resolve_game_camera_entity() orelse return null;
    const cam_comp = state.runtime.registry.get(components.Camera, ent) orelse return null;

    const world = compute_entity_world_matrix(ent, 0);
    const pos = math.Vec3{ .x = world.data[12], .y = world.data[13], .z = world.data[14] };

    var forward = math.Vec3{ .x = -world.data[8], .y = -world.data[9], .z = -world.data[10] };
    const f_len = forward.length();
    forward = if (f_len > 0.0001) forward.mul(1.0 / f_len) else math.Vec3{ .x = 0, .y = 0, .z = -1 };

    var up = math.Vec3{ .x = world.data[4], .y = world.data[5], .z = world.data[6] };
    const u_len = up.length();
    up = if (u_len > 0.0001) up.mul(1.0 / u_len) else math.Vec3{ .x = 0, .y = 1, .z = 0 };

    var out = state.runtime.camera;
    out.position = pos;
    out.target = pos.add(forward);
    out.up = up;
    if (cam_comp.type == .Perspective) {
        out.fov = cam_comp.fov;
    }
    const w = state.runtime.window.width;
    const h = state.runtime.window.height;
    const window_aspect: f32 = if (h != 0) @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h)) else out.aspect;

    out.aspect = if (cam_comp.aspect_ratio > 0.001) cam_comp.aspect_ratio else window_aspect;
    out.near_plane = if (cam_comp.near_plane > 0.00001) cam_comp.near_plane else 0.1;
    const desired_far = if (cam_comp.far_plane > out.near_plane + 0.001) cam_comp.far_plane else out.near_plane + 1000.0;
    out.far_plane = desired_far;

    return out;
}

fn free_terrain_runtime_data(entry: *editor_state.TerrainData) void {
    if (entry.height_handle != std.math.maxInt(u32)) {
        renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, entry.height_handle);
        entry.height_handle = std.math.maxInt(u32);
    }
    if (entry.splat_handle != std.math.maxInt(u32)) {
        renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, entry.splat_handle);
        entry.splat_handle = std.math.maxInt(u32);
    }
    for (entry.layer_handles, 0..) |h, i| {
        if (h != std.math.maxInt(u32)) {
            renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, h);
            entry.layer_handles[i] = std.math.maxInt(u32);
        }
    }
    allocator.free(entry.height);
    allocator.free(entry.splat);
}

fn prune_terrain_runtime_data() void {
    var dead_ids = std.ArrayListUnmanaged(u64){};
    defer dead_ids.deinit(allocator);

    var it = state.runtime.terrain_data_by_entity.iterator();
    while (it.next()) |entry| {
        const entity_id = entry.key_ptr.*;
        const ent = engine.ecs_entity.Entity{ .id = entity_id };
        const alive = state.runtime.registry.entity_manager.is_alive(ent);
        if (!alive) {
            free_terrain_runtime_data(entry.value_ptr);
            dead_ids.append(allocator, entity_id) catch {};
            continue;
        }

        const terr = state.runtime.registry.get(components.Terrain, ent);
        if (terr == null) {
            free_terrain_runtime_data(entry.value_ptr);
            dead_ids.append(allocator, entity_id) catch {};
            continue;
        }

        if (model_manager.cardinal_model_manager_get_model(&state.runtime.model_manager, terr.?.model_id) == null) {
            free_terrain_runtime_data(entry.value_ptr);
            dead_ids.append(allocator, entity_id) catch {};
            continue;
        }
    }

    for (dead_ids.items) |id| {
        _ = state.runtime.terrain_data_by_entity.remove(id);
    }
}

fn refresh_terrain_material_bindings() void {
    var view = state.runtime.registry.view(components.Terrain);
    var it = view.iterator();
    while (it.next()) |entry| {
        _ = terrain_panel.ensure_terrain_data_for_entity(&state, entry.entity);
    }
}

fn check_loading_status() void {
    if (state.runtime.loading_tasks.items.len == 0) {
        state.runtime.is_loading = false;
        return;
    }

    var i: usize = 0;
    while (i < state.runtime.loading_tasks.items.len) {
        const info = state.runtime.loading_tasks.items[i];
        const task = info.task;
        const status = async_loader.cardinal_async_get_task_status(task);

        if (status == .COMPLETED) {
            var loaded_scene: scene.CardinalScene = undefined;
            if (async_loader.cardinal_async_get_scene_result(task, &loaded_scene)) {
                const path = info.path;
                const filename = std.fs.path.basename(path);

                const filename_z = state.runtime.arena_allocator.dupeZ(u8, filename) catch "unknown";

                const model_id = model_manager.cardinal_model_manager_add_scene(&state.runtime.model_manager, &loaded_scene, path, filename_z);

                scene.cardinal_scene_destroy(&loaded_scene);

                if (model_id != 0) {
                    const combined = model_manager.cardinal_model_manager_get_combined_scene(&state.runtime.model_manager);
                    if (combined) |comb_ptr| {
                        state.runtime.combined_scene = comb_ptr.*;
                        state.runtime.scene_loaded = true;
                        refresh_terrain_material_bindings();

                        if (info.target_entity) |parent| {
                            scene_io.instantiate_model(&state, model_id, parent);

                            if (initialized) {
                                state.runtime.pending_scene = state.runtime.combined_scene;
                                state.runtime.scene_upload_pending = true;
                            }
                        } else {
                            selection_system.reset_picking_cache();
                            const parent = if (state.runtime.registry.entity_manager.is_alive(state.ui.selected_entity)) state.ui.selected_entity else blk: {
                                const root = node_factory.create_node(state.runtime.registry, null, .Node3D, "Scene Root", .{}) catch break :blk engine.ecs_entity.Entity{ .id = std.math.maxInt(u64) };
                                break :blk root;
                            };

                            if (parent.id != std.math.maxInt(u64)) {
                                scene_io.instantiate_model(&state, model_id, parent);
                            }

                            if (initialized) {
                                state.runtime.pending_scene = state.runtime.combined_scene;
                                state.runtime.scene_upload_pending = true;
                                reset_animation_ui_state();
                            }
                        }

                        log.cardinal_log_info("[EDITOR] Deferred scene upload scheduled", .{});
                        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Loaded model: {d} meshes from {s} (ID: {d})", .{ loaded_scene.mesh_count, filename, model_id }) catch {};
                    }
                }
            }

            async_loader.cardinal_async_free_task(task);
            allocator.free(info.path);
            _ = state.runtime.loading_tasks.swapRemove(i);
        } else if (status == .FAILED) {
            const err_msg = async_loader.cardinal_async_get_error_message(task);
            const err_str = if (err_msg) |msg| std.mem.span(msg) else "unknown error";
            const path = info.path;
            _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Failed to load: {s} - {s}", .{ path, err_str }) catch {};

            async_loader.cardinal_async_free_task(task);
            allocator.free(info.path);
            _ = state.runtime.loading_tasks.swapRemove(i);
        } else {
            i += 1;
        }
    }

    state.runtime.is_loading = (state.runtime.loading_tasks.items.len > 0);
}

/// Resets animation-related UI state after a scene load or replacement.
fn reset_animation_ui_state() void {
    state.ui.selected_animation = -1;
    state.ui.animation_time = 0.0;
    state.ui.animation_playing = false;
}

fn save_scene() void {
    if (platform.save_file_dialog(allocator, "Scene Files\x00*.json\x00All Files\x00*.*\x00", null)) |path| {
        defer allocator.free(path);
        scene_io.save_scene(&state, allocator, path);
        scene_io.refresh_available_scenes(&state, allocator);
    }
}

fn load_scene() void {
    if (platform.open_file_dialog(allocator, "Scene Files\x00*.json\x00All Files\x00*.*\x00", null)) |path| {
        defer allocator.free(path);
        scene_io.load_scene(&state, allocator, path);
    }
}

const VkCommandBuffer = c.VkCommandBuffer;

fn ui_draw_callback(cmd: VkCommandBuffer) callconv(.c) void {
    c.imgui_bridge_impl_vulkan_render_draw_data(@ptrCast(cmd));
}

/// Maps renderer modes to the UI combo index.
fn rendering_mode_to_combo_index(mode: types.CardinalRenderingMode) i32 {
    return switch (mode) {
        .NORMAL => 0,
        .UV => 1,
        .WIREFRAME => 2,
        .MESH_SHADER => 3,
        else => 0,
    };
}

/// Maps UI combo index to the corresponding renderer mode.
fn combo_index_to_rendering_mode(combo_index: i32) types.CardinalRenderingMode {
    return switch (combo_index) {
        0 => .NORMAL,
        1 => .UV,
        2 => .WIREFRAME,
        3 => .MESH_SHADER,
        else => .NORMAL,
    };
}

/// Initializes the editor layer and its UI backends.
///
/// TODO: Replace `std.debug.print` usage with structured logging.
pub fn init(win_ptr: *window.CardinalWindow, rnd_ptr: *types.CardinalRenderer, registry: *engine.ecs_registry.Registry) bool {
    if (initialized) {
        log.cardinal_log_warn("[EDITOR] Already initialized", .{});
        return true;
    }

    state = .{};

    state.runtime.arena = std.heap.ArenaAllocator.init(allocator);
    state.runtime.arena_allocator = state.runtime.arena.allocator();

    state.runtime.window = win_ptr;
    state.runtime.renderer = rnd_ptr;
    state.runtime.registry = registry;
    state.runtime.camera = .{
        .position = .{ .x = 0.0, .y = 2.0, .z = 5.0 },
        .target = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
        .up = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
        .fov = 65.0,
        .aspect = 16.0 / 9.0,
        .near_plane = 0.1,
        .far_plane = 100.0,
    };
    state.runtime.light = .{
        .direction = .{ .x = -0.3, .y = -0.7, .z = -0.5 },
        .position = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
        .color = .{ .x = 1.0, .y = 1.0, .z = 0.95 },
        .intensity = 1.0,
        .ambient = .{ .x = 0.1, .y = 0.1, .z = 0.1 },
        .range = 100.0,
        .inner_cone = 0.0,
        .outer_cone = 0.0,
        .type = 0,
    };

    renderer.cardinal_renderer_set_debug_grid(rnd_ptr, state.ui.show_grid_axes);

    if (!model_manager.cardinal_model_manager_init(&state.runtime.model_manager)) return false;

    state.runtime.config_manager = engine.config.ConfigManager.init(allocator, "cardinal_config.json", .{});
    state.runtime.config_manager.load() catch |err| {
        log.cardinal_log_warn("Failed to load config: {}", .{err});
    };

    var buffer: [1024]u8 = undefined;
    var assets_path: []const u8 = undefined;

    if (std.fs.cwd().openDir(state.runtime.config_manager.config.assets_path, .{})) |dir| {
        var d = dir;
        d.close();
        assets_path = std.fs.cwd().realpath(state.runtime.config_manager.config.assets_path, &buffer) catch |e| {
            log.cardinal_log_error("Failed to resolve absolute path for assets: {}", .{e});
            return false;
        };
    } else |err| {
        log.cardinal_log_warn("Configured assets path '{s}' invalid ({}), using default", .{ state.runtime.config_manager.config.assets_path, err });
        assets_path = std.fs.cwd().realpath("assets", &buffer) catch |e| {
            log.cardinal_log_error("Failed to resolve assets directory: {}", .{e});
            return false;
        };
    }

    state.ui.assets.assets_dir = allocator.dupeZ(u8, assets_path) catch return false;
    state.ui.assets.current_dir = allocator.dupeZ(u8, assets_path) catch return false;
    state.ui.assets.search_filter = allocator.alloc(u8, 256) catch return false;
    @memset(state.ui.assets.search_filter, 0);

    content_browser.scan_assets_dir(&state, allocator);

    c.imgui_bridge_create_context();
    imgui_context = c.imgui_bridge_get_current_context();
    if (imgui_context != null) {
        c.imgui_bridge_set_current_context(imgui_context);
    }
    c.imgui_bridge_enable_docking(true);
    c.imgui_bridge_enable_keyboard(true);
    c.imgui_bridge_enable_viewports(state.ui.enable_viewports);
    c.imgui_bridge_style_colors_dark();

    var x_scale: f32 = 1.0;
    var y_scale: f32 = 1.0;
    window.cardinal_window_get_content_scale(win_ptr, &x_scale, &y_scale);
    if (x_scale > 1.0) {
        c.imgui_bridge_set_display_scale(x_scale);
        log.cardinal_log_info("High DPI detected: scale {d:.2}", .{x_scale});
    }

    const glfw_window = @as(?*c.GLFWwindow, @ptrCast(win_ptr.handle));
    if (!c.imgui_bridge_impl_glfw_init_for_vulkan(glfw_window, true)) return false;

    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, .descriptorCount = 1000 },
    };

    var pool_info = c.VkDescriptorPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = 1000 * 11,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    };

    const device = @as(c.VkDevice, @ptrCast(renderer.cardinal_renderer_internal_device(rnd_ptr)));
    if (c.vkCreateDescriptorPool(device, &pool_info, null, &state.runtime.descriptor_pool) != c.VK_SUCCESS) return false;

    var init_info = c.ImGuiBridgeVulkanInitInfo{
        .instance = @as(c.VkInstance, @ptrCast(renderer.cardinal_renderer_internal_instance(rnd_ptr))),
        .physical_device = @as(c.VkPhysicalDevice, @ptrCast(renderer.cardinal_renderer_internal_physical_device(rnd_ptr))),
        .device = device,
        .queue_family = renderer.cardinal_renderer_internal_graphics_queue_family(rnd_ptr),
        .queue = @as(c.VkQueue, @ptrCast(renderer.cardinal_renderer_internal_graphics_queue(rnd_ptr))),
        .descriptor_pool = state.runtime.descriptor_pool,
        .min_image_count = renderer.cardinal_renderer_internal_swapchain_image_count(rnd_ptr),
        .image_count = renderer.cardinal_renderer_internal_swapchain_image_count(rnd_ptr),
        .msaa_samples = c.VK_SAMPLE_COUNT_1_BIT,
        .use_dynamic_rendering = true,
        .color_attachment_format = renderer.cardinal_renderer_internal_swapchain_format(rnd_ptr),
        .depth_attachment_format = renderer.cardinal_renderer_internal_depth_format(rnd_ptr),
    };

    log.cardinal_log_info("[EDITOR_LAYER] Init Info: Instance={any}, PhysDev={any}, Device={any}, QueueFam={d}, Queue={any}, Pool={any}, ImageCount={d}, ColorFmt={d}, DepthFmt={d}", .{ init_info.instance, init_info.physical_device, init_info.device, init_info.queue_family, init_info.queue, init_info.descriptor_pool, init_info.image_count, init_info.color_attachment_format, init_info.depth_attachment_format });

    if (!c.imgui_bridge_impl_vulkan_init(&init_info)) return false;

    log.cardinal_log_info("[EDITOR_LAYER] ImGui Vulkan Init successful.", .{});
    log.cardinal_log_info("[EDITOR_LAYER] Scanning assets dir...", .{});
    content_browser.scan_assets_dir(&state, allocator);
    log.cardinal_log_info("[EDITOR_LAYER] Assets dir scanned.", .{});

    renderer.cardinal_renderer_set_camera(rnd_ptr, &state.runtime.camera);
    std.debug.print("[EDITOR_LAYER] Camera set.\n", .{});
    renderer.cardinal_renderer_set_lighting(rnd_ptr, &state.runtime.light);
    std.debug.print("[EDITOR_LAYER] Lighting set.\n", .{});
    renderer.cardinal_renderer_set_post_process_params(rnd_ptr, &state.runtime.post_process);
    renderer.cardinal_renderer_set_ui_callback(rnd_ptr, @ptrCast(&ui_draw_callback));

    scene_io.refresh_available_scenes(&state, allocator);

    initialized = true;
    return true;
}

/// Handles Vulkan device loss by shutting down ImGui backends and pausing UI rendering.
pub fn on_device_loss(_: ?*anyopaque) callconv(.c) void {
    log.cardinal_log_warn("[EDITOR_LAYER] Device loss detected, shutting down ImGui", .{});

    device_recovery_failed = false;

    if (imgui_context != null) {
        c.imgui_bridge_set_current_context(imgui_context);
        c.imgui_bridge_invalidate_device_objects();
    }

    if (initialized) {
        renderer.cardinal_renderer_wait_idle(state.runtime.renderer);
        c.imgui_bridge_impl_vulkan_shutdown();
        c.imgui_bridge_impl_glfw_shutdown();
    }
    state.runtime.descriptor_pool = null;

    initialized = false;
}

/// Restores ImGui backends after a Vulkan device recreation.
pub fn on_device_restored(user_data: ?*anyopaque, success: bool) callconv(.c) void {
    _ = user_data;
    if (!success) {
        log.cardinal_log_error("[EDITOR_LAYER] Device recovery failed, cannot restore ImGui", .{});
        device_recovery_failed = true;
        _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Vulkan device lost; please restart editor", .{}) catch {};
        return;
    }

    log.cardinal_log_info("[EDITOR_LAYER] Device restored, re-initializing ImGui", .{});

    if (imgui_context != null) {
        c.imgui_bridge_set_current_context(imgui_context);
    }

    if (initialized) {
        log.cardinal_log_warn("[EDITOR_LAYER] Device restored but ImGui already initialized. Shutting down old instance.", .{});
        renderer.cardinal_renderer_wait_idle(state.runtime.renderer);
        c.imgui_bridge_impl_vulkan_shutdown();
        c.imgui_bridge_impl_glfw_shutdown();

        if (state.runtime.descriptor_pool != null) {
            const rnd_ptr = state.runtime.renderer;
            const device = @as(c.VkDevice, @ptrCast(renderer.cardinal_renderer_internal_device(rnd_ptr)));
            c.vkDestroyDescriptorPool(device, state.runtime.descriptor_pool, null);
            state.runtime.descriptor_pool = null;
        }
        initialized = false;
    }

    const native_window = @as(?*c.GLFWwindow, @ptrCast(window.cardinal_window_get_glfw_handle(state.runtime.window)));
    if (native_window == null) {
        log.cardinal_log_error("[EDITOR_LAYER] Failed to get GLFW window handle for ImGui re-init", .{});
        return;
    }

    if (!c.imgui_bridge_impl_glfw_init_for_vulkan(native_window.?, true)) {
        log.cardinal_log_error("[EDITOR_LAYER] Failed to re-initialize ImGui GLFW backend", .{});
        return;
    }

    const rnd_ptr = state.runtime.renderer;
    const device = @as(c.VkDevice, @ptrCast(renderer.cardinal_renderer_internal_device(rnd_ptr)));

    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, .descriptorCount = 1000 },
    };

    var pool_info = c.VkDescriptorPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = 1000 * 11,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = &pool_sizes,
    };

    if (c.vkCreateDescriptorPool(device, &pool_info, null, &state.runtime.descriptor_pool) != c.VK_SUCCESS) {
        log.cardinal_log_error("[EDITOR_LAYER] Failed to recreate descriptor pool", .{});
        return;
    }

    c.imgui_bridge_invalidate_device_objects();

    var init_info = c.ImGuiBridgeVulkanInitInfo{
        .instance = @as(c.VkInstance, @ptrCast(renderer.cardinal_renderer_internal_instance(rnd_ptr))),
        .physical_device = @as(c.VkPhysicalDevice, @ptrCast(renderer.cardinal_renderer_internal_physical_device(rnd_ptr))),
        .device = device,
        .queue_family = renderer.cardinal_renderer_internal_graphics_queue_family(rnd_ptr),
        .queue = @as(c.VkQueue, @ptrCast(renderer.cardinal_renderer_internal_graphics_queue(rnd_ptr))),
        .descriptor_pool = state.runtime.descriptor_pool,
        .min_image_count = renderer.cardinal_renderer_internal_swapchain_image_count(rnd_ptr),
        .image_count = renderer.cardinal_renderer_internal_swapchain_image_count(rnd_ptr),
        .msaa_samples = c.VK_SAMPLE_COUNT_1_BIT,
        .use_dynamic_rendering = true,
        .color_attachment_format = renderer.cardinal_renderer_internal_swapchain_format(rnd_ptr),
        .depth_attachment_format = renderer.cardinal_renderer_internal_depth_format(rnd_ptr),
    };

    if (!c.imgui_bridge_impl_vulkan_init(&init_info)) {
        log.cardinal_log_error("[EDITOR_LAYER] Failed to re-initialize ImGui Vulkan backend", .{});
        return;
    }

    initialized = true;
    device_recovery_failed = false;
}

fn close_project() void {
    if (state.ui.project) |*proj| {
        proj.deinit();
    }
    state.ui.project = null;
    state.ui.project_loaded = false;
    state.ui.undo.clear();

    {
        var it = state.runtime.terrain_data_by_entity.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.height_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, entry.value_ptr.height_handle);
            }
            if (entry.value_ptr.splat_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, entry.value_ptr.splat_handle);
            }
            for (entry.value_ptr.layer_handles) |h| {
                if (h != std.math.maxInt(u32)) {
                    renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, h);
                }
            }
            allocator.free(entry.value_ptr.height);
            allocator.free(entry.value_ptr.splat);
        }
        state.runtime.terrain_data_by_entity.clearRetainingCapacity();
    }
    state.runtime.terrain_dirty_rects.clearRetainingCapacity();

    engine.window.cardinal_window_restore(state.runtime.window);
    engine.window.cardinal_window_set_size(state.runtime.window, 600, 400);
    engine.window.cardinal_window_center(state.runtime.window);
    engine.window.cardinal_window_set_title(state.runtime.window, "Cardinal Project Manager");
}

pub fn has_device_recovery_failed() bool {
    return device_recovery_failed;
}

/// Shuts down editor UI resources and releases runtime allocations owned by the layer.
pub fn shutdown() void {
    _ = async_loader.cardinal_async_process_completed_tasks(0);

    renderer.cardinal_renderer_wait_for_texture_uploads(state.runtime.renderer);
    renderer.cardinal_renderer_wait_idle(state.runtime.renderer);

    if (imgui_context != null) {
        c.imgui_bridge_set_current_context(imgui_context);
    }
    if (initialized) {
        c.imgui_bridge_impl_vulkan_shutdown();
        c.imgui_bridge_impl_glfw_shutdown();
    }
    c.imgui_bridge_destroy_context();
    imgui_context = null;

    if (state.runtime.descriptor_pool != null) {
        const device = @as(c.VkDevice, @ptrCast(renderer.cardinal_renderer_internal_device(state.runtime.renderer)));
        c.vkDestroyDescriptorPool(device, state.runtime.descriptor_pool, null);
        state.runtime.descriptor_pool = null;
    }

    model_manager.cardinal_model_manager_destroy(&state.runtime.model_manager);

    selection_system.reset_picking_cache();
    state.runtime.transform_overrides.deinit(allocator);
    state.runtime.mesh_owner_by_mesh_index.deinit(allocator);
    state.runtime.mesh_entity_by_mesh_index.deinit(allocator);
    state.runtime.model_root_by_id.deinit(allocator);
    state.runtime.terrain_dirty_rects.deinit(allocator);
    {
        var it = state.runtime.terrain_data_by_entity.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.height_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, entry.value_ptr.height_handle);
            }
            if (entry.value_ptr.splat_handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, entry.value_ptr.splat_handle);
            }
            for (entry.value_ptr.layer_handles) |h| {
                if (h != std.math.maxInt(u32)) {
                    renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, h);
                }
            }
            allocator.free(entry.value_ptr.height);
            allocator.free(entry.value_ptr.splat);
        }
        state.runtime.terrain_data_by_entity.deinit(allocator);
    }

    {
        const gen = c.imgui_bridge_vk_generation();
        var it = state.runtime.asset_thumbnails.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.imgui_id != 0) {
                if (gen != 0 and entry.value_ptr.imgui_vulkan_generation == gen) {
                    c.imgui_bridge_vk_remove_texture(entry.value_ptr.imgui_id);
                }
                entry.value_ptr.imgui_id = 0;
                entry.value_ptr.imgui_backend_user_data_ptr = 0;
                entry.value_ptr.imgui_vulkan_generation = 0;
            }
            if (entry.value_ptr.handle != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, entry.value_ptr.handle);
                entry.value_ptr.handle = std.math.maxInt(u32);
            }
            allocator.free(entry.key_ptr.*);
        }
        state.runtime.asset_thumbnails.deinit(allocator);
    }

    for (state.runtime.loading_tasks.items) |info| {
        async_loader.cardinal_async_free_task(info.task);
        allocator.free(info.path);
    }
    state.runtime.loading_tasks.deinit(allocator);

    for (state.ui.assets.entries.items) |entry| {
        entry.deinit(allocator);
    }
    state.ui.assets.entries.deinit(allocator);
    state.ui.assets.filtered_entries.deinit(allocator);
    allocator.free(state.ui.assets.assets_dir[0 .. state.ui.assets.assets_dir.len + 1]);
    allocator.free(state.ui.assets.current_dir[0 .. state.ui.assets.current_dir.len + 1]);
    allocator.free(state.ui.assets.search_filter);

    state.ui.undo.deinit(allocator);
    state.ui.scene_graph_open_state.deinit(allocator);
    state.ui.selected_entities.deinit(allocator);
    state.ui.inspector_component_order_by_entity.deinit(allocator);

    state.runtime.config_manager.deinit();
    world_matrix_cache.deinit(allocator);

    initialized = false;
}

/// Advances editor state for the current frame and builds the UI.
pub fn update() void {
    if (!initialized) return;
    if (imgui_context != null) {
        c.imgui_bridge_set_current_context(imgui_context);
    }

    if (!state.ui.project_loaded) {
        c.imgui_bridge_impl_vulkan_new_frame();
        c.imgui_bridge_impl_glfw_new_frame();
        c.imgui_bridge_new_frame();

        project_manager.draw_project_manager_panel(&state, allocator);
        return;
    }

    _ = async_loader.cardinal_async_process_completed_tasks(0);

    check_loading_status();
    scene_sync.sync_skybox_from_ecs(&state, allocator);

    if (state.runtime.model_manager.scene_dirty) {
        if (model_manager.cardinal_model_manager_get_combined_scene(&state.runtime.model_manager)) |comb_ptr| {
            state.runtime.combined_scene = comb_ptr.*;
            state.runtime.pending_scene = state.runtime.combined_scene;
            state.runtime.scene_upload_pending = true;
            state.runtime.scene_loaded = (state.runtime.combined_scene.mesh_count > 0);
            state.runtime.transform_overrides.clearRetainingCapacity();
            selection_system.reset_picking_cache();
            state.ui.undo.clear();
            prune_terrain_runtime_data();
            refresh_terrain_material_bindings();
        } else {
            state.runtime.scene_loaded = false;
        }

        state.ui.selected_animation = -1;
        state.ui.animation_time = 0.0;
        state.ui.animation_playing = false;
    } else if (state.runtime.model_manager.transform_dirty) {
        if (model_manager.cardinal_model_manager_get_combined_scene(&state.runtime.model_manager)) |comb_ptr| {
            state.runtime.combined_scene = comb_ptr.*;
        }
    }

    if (state.runtime.picking_cache_dirty) {
        selection_system.reset_picking_cache();
        state.runtime.picking_cache_dirty = false;
    }

    c.imgui_bridge_impl_vulkan_new_frame();
    c.imgui_bridge_impl_glfw_new_frame();
    c.imgui_bridge_new_frame();

    const dt = c.imgui_bridge_get_io_delta_time();
    apply_globals_to_state();

    if (state.runtime.scene_loaded and state.runtime.combined_scene.animation_system != null) {
        const anim_sys_opaque = state.runtime.combined_scene.animation_system.?;
        const anim_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(anim_sys_opaque)));

        animation.cardinal_animation_system_update(anim_sys, state.runtime.combined_scene.all_nodes, state.runtime.combined_scene.all_node_count, dt);

        if (state.runtime.model_manager.models) |models| {
            var mesh_offset: u32 = 0;
            var m_idx: u32 = 0;
            while (m_idx < state.runtime.model_manager.model_count) : (m_idx += 1) {
                const model = &models[m_idx];
                if (!model.visible or model.is_loading) continue;

                const scn = &model.scene;

                if (scn.root_nodes) |roots| {
                    var r: u32 = 0;
                    while (r < scn.root_node_count) : (r += 1) {
                        scene.cardinal_scene_node_update_transforms(roots[r], &model.transform);
                    }
                }

                if (scn.all_nodes) |nodes| {
                    var n: u32 = 0;
                    while (n < scn.all_node_count) : (n += 1) {
                        if (nodes[n]) |node| {
                            if (node.mesh_count > 0 and node.mesh_indices != null) {
                                var m: u32 = 0;
                                while (m < node.mesh_count) : (m += 1) {
                                    const mesh_idx = node.mesh_indices.?[m];
                                    const combined_idx = mesh_offset + mesh_idx;

                                    if (combined_idx < state.runtime.combined_scene.mesh_count) {
                                        const mesh = &state.runtime.combined_scene.meshes.?[combined_idx];
                                        @memcpy(&mesh.transform, &node.world_transform);
                                    }
                                }
                            }
                        }
                    }
                }

                mesh_offset += scn.mesh_count;
            }
        }

        if (state.ui.selected_animation >= 0 and state.ui.selected_animation < anim_sys.animation_count) {
            var i: u32 = 0;
            while (i < anim_sys.state_count) : (i += 1) {
                const anim_state = &anim_sys.states.?[i];
                if (anim_state.animation_index == @as(u32, @intCast(state.ui.selected_animation))) {
                    state.ui.animation_time = anim_state.current_time;
                    state.ui.animation_playing = anim_state.is_playing;
                    state.ui.animation_looping = anim_state.is_looping;
                    state.ui.animation_speed = anim_state.playback_speed;
                    break;
                }
            }
        }
    }

    input_system.update(&state);
    camera_controller.update(&state, dt);

    const window_flags = c.ImGuiWindowFlags_MenuBar | c.ImGuiWindowFlags_NoTitleBar |
        c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize |
        c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoBringToFrontOnFocus |
        c.ImGuiWindowFlags_NoNavFocus | c.ImGuiWindowFlags_NoDocking |
        c.ImGuiWindowFlags_NoBackground;

    const viewport = c.imgui_bridge_get_main_viewport().?;

    var work_pos: c.ImVec2 = undefined;
    var work_size: c.ImVec2 = undefined;
    c.imgui_bridge_viewport_get_work_pos(viewport, &work_pos);
    c.imgui_bridge_viewport_get_work_size(viewport, &work_size);

    const zero_vec = c.ImVec2{ .x = 0.0, .y = 0.0 };

    c.imgui_bridge_set_next_window_pos(&work_pos, 0, &zero_vec);
    c.imgui_bridge_set_next_window_size(&work_size, 0);
    c.imgui_bridge_push_style_var_vec2(c.ImGuiStyleVar_WindowPadding, &zero_vec);

    const dockspace_open = c.imgui_bridge_begin("DockSpace", null, window_flags);
    c.imgui_bridge_pop_style_var(1);
    defer c.imgui_bridge_end();

    if (dockspace_open) {
        const dock_id = c.imgui_bridge_get_id("EditorDockSpace");
        const dock_flags = c.ImGuiDockNodeFlags_PassthruCentralNode;
        c.imgui_bridge_dock_space(dock_id, &zero_vec, dock_flags);

        if (c.imgui_bridge_begin_menu_bar()) {
            if (c.imgui_bridge_begin_menu("File", true)) {
                if (c.imgui_bridge_menu_item("New Project...", null, false, true)) {
                    close_project();
                }
                if (c.imgui_bridge_menu_item("Open Project...", null, false, true)) {
                    close_project();
                }
                c.imgui_bridge_separator();
                if (c.imgui_bridge_menu_item("Save Scene", "Ctrl+S", false, true)) {
                    save_scene();
                }
                if (c.imgui_bridge_menu_item("Load Scene", "Ctrl+O", false, true)) {
                    load_scene();
                }
                c.imgui_bridge_separator();
                if (c.imgui_bridge_menu_item("Exit", "Ctrl+Q", false, true)) {}
                c.imgui_bridge_end_menu();
            }

            if (c.imgui_bridge_begin_menu("View", true)) {
                if (c.imgui_bridge_menu_item("Scene Graph", null, state.ui.show_scene_graph, true)) state.ui.show_scene_graph = !state.ui.show_scene_graph;
                if (c.imgui_bridge_menu_item("Assets", null, state.ui.show_assets, true)) state.ui.show_assets = !state.ui.show_assets;
                if (c.imgui_bridge_menu_item("Model Manager", null, state.ui.show_model_manager, true)) state.ui.show_model_manager = !state.ui.show_model_manager;
                if (c.imgui_bridge_menu_item("Inspector", null, state.ui.show_entity_inspector, true)) state.ui.show_entity_inspector = !state.ui.show_entity_inspector;
                if (c.imgui_bridge_menu_item("Scene Manager", null, state.ui.show_scene_manager, true)) state.ui.show_scene_manager = !state.ui.show_scene_manager;
                if (c.imgui_bridge_menu_item("Animation", null, state.ui.show_animation, true)) state.ui.show_animation = !state.ui.show_animation;
                if (c.imgui_bridge_menu_item("Terrain", null, state.ui.show_terrain_panel, true)) state.ui.show_terrain_panel = !state.ui.show_terrain_panel;
                if (c.imgui_bridge_menu_item("Performance", null, state.ui.show_performance_panel, true)) state.ui.show_performance_panel = !state.ui.show_performance_panel;
                if (c.imgui_bridge_menu_item("Grid & Axes", null, state.ui.show_grid_axes, true)) {
                    state.ui.show_grid_axes = !state.ui.show_grid_axes;
                    renderer.cardinal_renderer_set_debug_grid(state.runtime.renderer, state.ui.show_grid_axes);
                }
                c.imgui_bridge_end_menu();
            }
            c.imgui_bridge_same_line(0, -1);
            if (!state.runtime.preview_game_camera) {
                if (c.imgui_bridge_button("Play")) {
                    if (state.runtime.registry.get(components.EditorGlobals, state.runtime.globals_entity)) |g| {
                        g.pbr_enabled = true;
                    }
                    state.runtime.pbr_enabled = true;
                    renderer.cardinal_renderer_enable_pbr(state.runtime.renderer, true);
                    state.runtime.preview_game_camera = true;
                }
            } else {
                if (c.imgui_bridge_button("Stop")) {
                    state.runtime.preview_game_camera = false;
                }
            }
            c.imgui_bridge_end_menu_bar();
        }

        renderer.cardinal_renderer_set_terrain_brush_preview(state.runtime.renderer, false, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0);

        hierarchy_panel.draw_hierarchy_panel(&state);
        content_browser.draw_asset_browser_panel(&state, allocator);
        inspector.draw_inspector_panel(&state);
        animation_panel.draw_animation_panel(&state);
        terrain_panel.draw_terrain_panel(&state);
        performance_panel.draw_performance_panel(&state);
        scene_manager_panel.draw_scene_manager_panel(&state, allocator);
        terrain_panel.flush_terrain_pending_uploads(&state);

        scene_sync.sync_mesh_visibility_from_ecs(&state);
        scene_sync.sync_mesh_transforms_from_ecs(&state, allocator, &world_matrix_cache);

        if (state.runtime.scene_loaded and state.runtime.combined_scene.animation_system != null) {
            const anim_sys_opaque = state.runtime.combined_scene.animation_system.?;
            const anim_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(anim_sys_opaque)));

            if (anim_sys.skin_count > 0 and anim_sys.skins != null and anim_sys.bone_matrices != null and state.runtime.combined_scene.meshes != null) {
                const nodes_ptr = @as(?[*]?*const scene.CardinalSceneNode, @ptrCast(state.runtime.combined_scene.all_nodes));
                const meshes = state.runtime.combined_scene.meshes.?;

                var s_idx: u32 = 0;
                while (s_idx < anim_sys.skin_count) : (s_idx += 1) {
                    const skin = &anim_sys.skins.?[s_idx];
                    if (skin.mesh_indices == null or skin.mesh_count == 0) continue;
                    const mesh_index = skin.mesh_indices.?[0];
                    if (mesh_index >= state.runtime.combined_scene.mesh_count) continue;

                    const base_world_ptr: *const [16]f32 = &meshes[mesh_index].transform;

                    _ = animation.cardinal_skin_update_bone_matrices_bounded_mesh_local(
                        skin,
                        nodes_ptr,
                        state.runtime.combined_scene.all_node_count,
                        base_world_ptr,
                        anim_sys.bone_matrices,
                    );
                }

                if (anim_sys.bone_matrix_count > 0) {
                    const matrices = anim_sys.bone_matrices.?;
                    renderer.cardinal_renderer_update_bone_matrices(state.runtime.renderer, matrices, anim_sys.bone_matrix_count * 16);
                }
            }
        }
        scene_sync.sync_mesh_index_maps_from_ecs(&state, allocator);
    }

    persist_state_to_globals();
}

/// Submits the UI draw data for rendering.
pub fn render() void {
    if (!initialized) return;
    c.imgui_bridge_render();
}

/// Uploads any pending scene changes to the renderer.
pub fn process_pending_uploads() void {
    if (state.runtime.scene_upload_pending and initialized) {
        log.cardinal_log_info("[EDITOR] Pending upload detected", .{});
        renderer.cardinal_renderer_upload_scene(state.runtime.renderer, &state.runtime.pending_scene);

        state.runtime.combined_scene = state.runtime.pending_scene;
        state.runtime.scene_upload_pending = false;

        if (state.runtime.combined_scene.light_count > 0 and state.runtime.combined_scene.lights != null) {
            const sl = &state.runtime.combined_scene.lights.?[0];
            state.runtime.light.color = .{ .x = sl.color[0], .y = sl.color[1], .z = sl.color[2] };
            state.runtime.light.intensity = sl.intensity;
            state.runtime.light.range = sl.range;
            state.runtime.light.type = @intFromEnum(sl.type);

            if (sl.node_index < state.runtime.combined_scene.all_node_count and state.runtime.combined_scene.all_nodes != null) {
                if (state.runtime.combined_scene.all_nodes.?[sl.node_index]) |node| {
                    const m = node.world_transform;
                    state.runtime.light.direction = .{ .x = -m[8], .y = -m[9], .z = -m[10] };
                    state.runtime.light.position = .{ .x = m[12], .y = m[13], .z = m[14] };
                    log.cardinal_log_info("Updated light transform from node {d}: Pos=({d:.2},{d:.2},{d:.2})", .{ sl.node_index, state.runtime.light.position.x, state.runtime.light.position.y, state.runtime.light.position.z });
                }
            }
        }
    }

    if (state.runtime.pbr_enabled) {
        if (state.runtime.preview_game_camera) {
            if (resolve_game_view_camera()) |cam| {
                var tmp = cam;
                renderer.cardinal_renderer_set_camera(state.runtime.renderer, &tmp);
            } else {
                renderer.cardinal_renderer_set_camera(state.runtime.renderer, &state.runtime.camera);
            }
        } else {
            renderer.cardinal_renderer_set_camera(state.runtime.renderer, &state.runtime.camera);
        }

        var pbr_lights: [types.MAX_LIGHTS]types.PBRLight = undefined;
        var light_count: u32 = 0;

        if (state.runtime.enable_directional_light) {
            pbr_lights[light_count] = std.mem.zeroes(types.PBRLight);
            pbr_lights[light_count].lightDirection = .{ state.runtime.light.direction.x, state.runtime.light.direction.y, state.runtime.light.direction.z, 0.0 };
            pbr_lights[light_count].lightPosition = .{ state.runtime.light.position.x, state.runtime.light.position.y, state.runtime.light.position.z, 0.0 };
            pbr_lights[light_count].lightColor = .{ state.runtime.light.color.x, state.runtime.light.color.y, state.runtime.light.color.z, state.runtime.light.intensity };
            pbr_lights[light_count].params = .{ state.runtime.light.range, @cos(state.runtime.light.inner_cone), @cos(state.runtime.light.outer_cone), 0.0 };
            light_count += 1;
        }

        if (state.runtime.combined_scene.light_count > 0 and state.runtime.combined_scene.lights != null) {
            var i: u32 = 0;
            while (i < state.runtime.combined_scene.light_count and light_count < types.MAX_LIGHTS) : (i += 1) {
                const sl = &state.runtime.combined_scene.lights.?[i];

                if (sl.type == .DIRECTIONAL) continue;

                var pos = math.Vec3{ .x = 0, .y = 0, .z = 0 };
                var dir = math.Vec3{ .x = 0, .y = -1, .z = 0 };

                if (sl.node_index < state.runtime.combined_scene.all_node_count and state.runtime.combined_scene.all_nodes != null) {
                    if (state.runtime.combined_scene.all_nodes.?[sl.node_index]) |node| {
                        const m = node.world_transform;
                        dir = .{ .x = -m[8], .y = -m[9], .z = -m[10] };
                        pos = .{ .x = m[12], .y = m[13], .z = m[14] };
                    }
                }

                var intensity = sl.intensity;
                if (intensity < 100.0) intensity *= 100.0;

                pbr_lights[light_count] = std.mem.zeroes(types.PBRLight);
                pbr_lights[light_count].lightDirection = .{ dir.x, dir.y, dir.z, @floatFromInt(@intFromEnum(sl.type)) };
                pbr_lights[light_count].lightPosition = .{ pos.x, pos.y, pos.z, 0.0 };
                pbr_lights[light_count].lightColor = .{ sl.color[0], sl.color[1], sl.color[2], intensity };
                pbr_lights[light_count].params = .{ sl.range, @cos(sl.inner_cone_angle), @cos(sl.outer_cone_angle), 0.0 };

                light_count += 1;
            }
        }

        if (light_count > 0) {
            renderer.cardinal_renderer_set_lights(state.runtime.renderer, &pbr_lights, light_count);
        } else {
            renderer.cardinal_renderer_set_lights(state.runtime.renderer, null, 0);
        }
    }
}
