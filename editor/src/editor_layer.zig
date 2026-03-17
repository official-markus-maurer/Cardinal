//! Editor layer.
//!
//! Owns editor state, panels, and per-frame UI orchestration on top of the engine runtime.
//!
//! TODO: Split this file into smaller panel/system coordinators to reduce rebuild time.
const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const Vec3 = math.Vec3;
const log = engine.log;
const platform = engine.platform;
const window = engine.window;
const renderer = engine.vulkan_renderer;
const types = engine.vulkan_types;
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
const selection_system = @import("systems/selection_system.zig");
const performance_panel = @import("panels/performance_panel.zig");
const input_system = @import("systems/input.zig");
const camera_controller = @import("systems/camera_controller.zig");
const scene_io = @import("systems/scene_io.zig");
const project_manager = @import("panels/project_manager.zig");

const c = @import("c.zig").c;

/// Global allocator for editor-owned state.
const allocator = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

var state: EditorState = undefined;
var initialized: bool = false;
var device_recovery_failed: bool = false;
var imgui_context: ?*anyopaque = null;
var world_matrix_cache: std.AutoHashMapUnmanaged(u64, math.Mat4) = .{};
var override_cache: std.AutoHashMapUnmanaged(u64, bool) = .{};

/// Syncs the active skybox asset from ECS into runtime state.
fn sync_skybox_from_ecs() void {
    var view = state.runtime.registry.view(engine.ecs_components.Skybox);
    var it = view.iterator();
    const entry = it.next() orelse return;
    const sky = entry.component;
    const path = sky.slice();
    if (path.len == 0) return;

    if (state.runtime.skybox_path) |p| {
        if (std.mem.eql(u8, std.mem.span(p.ptr), path)) return;
        allocator.free(p);
        state.runtime.skybox_path = null;
    }

    state.runtime.skybox_path = allocator.dupeZ(u8, path) catch return;
}

/// Pushes ECS-driven transforms into `state.combined_scene` so the renderer updates mesh placement.
fn sync_mesh_transforms_from_ecs() void {
    if (!state.runtime.scene_loaded) return;
    if (state.runtime.scene_upload_pending) return;
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return;
    const meshes = state.runtime.combined_scene.meshes.?;

    world_matrix_cache.clearRetainingCapacity();

    var view = state.runtime.registry.view(engine.ecs_components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        if (state.runtime.transform_overrides.get(entry.entity.id) == null) continue;
        const mr = entry.component;
        const mesh_index = mr.mesh.index;
        if (mesh_index >= state.runtime.combined_scene.mesh_count) continue;

        const m = compute_entity_world_matrix(entry.entity);
        @memcpy(meshes[mesh_index].transform[0..16], m.data[0..16]);
    }
}

/// Computes the world transform for `entity` by walking `Hierarchy` and composing `Transform`.
fn compute_entity_world_matrix(entity: engine.ecs_entity.Entity) engine.math.Mat4 {
    return compute_entity_world_matrix_cached(entity, 0);
}

/// Cached variant of `compute_entity_world_matrix` to avoid repeated hierarchy walks.
fn compute_entity_world_matrix_cached(entity: engine.ecs_entity.Entity, depth: u32) engine.math.Mat4 {
    if (world_matrix_cache.get(entity.id)) |m| return m;
    if (depth > 2048) return math.Mat4.identity();

    var parent_world = math.Mat4.identity();
    if (state.runtime.registry.get(engine.ecs_components.Hierarchy, entity)) |h| {
        if (h.parent) |p| {
            parent_world = compute_entity_world_matrix_cached(p, depth + 1);
        }
    }

    var world = parent_world;
    if (state.runtime.registry.get(engine.ecs_components.Transform, entity)) |t| {
        const local = math.Mat4.fromTRS(t.position, t.rotation, t.scale);
        world = parent_world.mul(local);
    }

    world_matrix_cache.put(allocator, entity.id, world) catch {};
    return world;
}

/// Syncs per-mesh visibility flags from ECS into the combined scene.
fn sync_mesh_visibility_from_ecs() void {
    if (!state.runtime.scene_loaded) return;
    if (state.runtime.scene_upload_pending) return;
    if (state.runtime.combined_scene.meshes == null or state.runtime.combined_scene.mesh_count == 0) return;
    const meshes = state.runtime.combined_scene.meshes.?;

    var i: u32 = 0;
    while (i < state.runtime.combined_scene.mesh_count) : (i += 1) {
        meshes[i].visible = false;
    }

    var view = state.runtime.registry.view(engine.ecs_components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        const mr = entry.component;
        const mesh_index = mr.mesh.index;
        if (mesh_index >= state.runtime.combined_scene.mesh_count) continue;
        meshes[mesh_index].visible = mr.visible;
    }
}

/// Rebuilds mesh-index -> entity maps from ECS `MeshRenderer` components.
fn sync_mesh_index_maps_from_ecs() void {
    if (!state.runtime.scene_loaded) return;

    state.runtime.mesh_entity_by_mesh_index.clearRetainingCapacity();
    state.runtime.mesh_owner_by_mesh_index.clearRetainingCapacity();

    var view = state.runtime.registry.view(engine.ecs_components.MeshRenderer);
    var it = view.iterator();
    while (it.next()) |entry| {
        const mr = entry.component;
        state.runtime.mesh_entity_by_mesh_index.put(allocator, mr.mesh.index, entry.entity.id) catch {};
        state.runtime.mesh_owner_by_mesh_index.put(allocator, mr.mesh.index, entry.entity.id) catch {};
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

                        if (info.target_entity) |parent| {
                            scene_io.instantiate_model(&state, model_id, parent);

                            if (initialized) {
                                state.runtime.pending_scene = state.runtime.combined_scene;
                                state.runtime.scene_upload_pending = true;
                            }
                        } else {
                            state.runtime.transform_overrides.clearRetainingCapacity();
                            selection_system.reset_picking_cache();
                            state.runtime.mesh_owner_by_mesh_index.clearRetainingCapacity();
                            state.runtime.mesh_entity_by_mesh_index.clearRetainingCapacity();
                            state.runtime.registry.deinit();
                            state.runtime.registry.* = engine.ecs_registry.Registry.init(allocator);
                            scene_io.import_scene_graph(&state);

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

fn draw_pbr_settings_panel() void {
    if (state.ui.show_pbr_settings) {
        const open = c.imgui_bridge_begin("PBR Settings", &state.ui.show_pbr_settings, 0);
        defer c.imgui_bridge_end();

        if (open) {
            if (c.imgui_bridge_checkbox("Enable PBR Rendering", &state.runtime.pbr_enabled)) {
                renderer.cardinal_renderer_enable_pbr(state.runtime.renderer, state.runtime.pbr_enabled);
                if (state.runtime.pbr_enabled) {
                    renderer.cardinal_renderer_set_camera(state.runtime.renderer, &state.runtime.camera);
                    renderer.cardinal_renderer_set_lighting(state.runtime.renderer, &state.runtime.light);
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Camera", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var cam_changed = false;
                if (c.imgui_bridge_drag_float3("Position", @ptrCast(&state.runtime.camera.position), 0.1, 0.0, 0.0, "%.3f", 0)) cam_changed = true;
                if (c.imgui_bridge_drag_float3("Target", @ptrCast(&state.runtime.camera.target), 0.1, 0.0, 0.0, "%.3f", 0)) cam_changed = true;
                if (c.imgui_bridge_slider_float("FOV", &state.runtime.camera.fov, 10.0, 120.0, "%.1f")) cam_changed = true;

                if (cam_changed and state.runtime.pbr_enabled) {
                    renderer.cardinal_renderer_set_camera(state.runtime.renderer, &state.runtime.camera);
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Lighting", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var light_changed = false;

                state.runtime.enable_directional_light = true;
                state.runtime.light.type = 0; // Directional

                c.imgui_bridge_text("Directional Light (Sun)");
                if (c.imgui_bridge_drag_float3("Direction", @ptrCast(&state.runtime.light.direction), 0.01, -1.0, 1.0, "%.3f", 0)) light_changed = true;

                if (c.imgui_bridge_color_edit3("Color", @ptrCast(&state.runtime.light.color), 0)) light_changed = true;
                if (c.imgui_bridge_slider_float("Intensity##DirectionalLight", &state.runtime.light.intensity, 0.0, 20.0, "%.2f")) light_changed = true;
                if (c.imgui_bridge_color_edit3("Ambient", @ptrCast(&state.runtime.light.ambient), 0)) light_changed = true;

                if (light_changed and state.runtime.pbr_enabled) {
                    renderer.cardinal_renderer_set_lighting(state.runtime.renderer, &state.runtime.light);
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Material Override", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                _ = c.imgui_bridge_checkbox("Enable Material Override", &state.ui.material_override_enabled);

                if (state.ui.material_override_enabled) {
                    c.imgui_bridge_separator();
                    _ = c.imgui_bridge_color_edit3("Albedo Factor", @ptrCast(&state.ui.material_albedo), 0);
                    _ = c.imgui_bridge_slider_float("Metallic Factor", &state.ui.material_metallic, 0.0, 1.0, "%.3f");
                    _ = c.imgui_bridge_slider_float("Roughness Factor", &state.ui.material_roughness, 0.0, 1.0, "%.3f");
                    _ = c.imgui_bridge_color_edit3("Emissive Factor", &state.ui.material_emissive, 0);
                    _ = c.imgui_bridge_slider_float("Normal Scale", &state.ui.material_normal_scale, 0.0, 2.0, "%.3f");
                    _ = c.imgui_bridge_slider_float("AO Strength", &state.ui.material_ao_strength, 0.0, 1.0, "%.3f");

                    if (c.imgui_bridge_button("Apply to All Materials")) {
                        if (state.runtime.scene_loaded and state.runtime.combined_scene.material_count > 0) {
                            var i: u32 = 0;
                            while (i < state.runtime.combined_scene.material_count) : (i += 1) {
                                if (state.runtime.combined_scene.materials) |materials| {
                                    var mat = &materials[i];

                                    mat.albedo_factor = state.ui.material_albedo;
                                    mat.metallic_factor = state.ui.material_metallic;
                                    mat.roughness_factor = state.ui.material_roughness;
                                    mat.emissive_factor = state.ui.material_emissive;
                                    mat.normal_scale = state.ui.material_normal_scale;
                                    mat.ao_strength = state.ui.material_ao_strength;
                                }
                            }

                            state.runtime.pending_scene = state.runtime.combined_scene;
                            state.runtime.scene_upload_pending = true;
                            _ = std.fmt.bufPrintZ(&state.ui.status_msg, "Applied material override to {d} materials", .{state.runtime.combined_scene.material_count}) catch {};
                        } else {
                            _ = std.fmt.bufPrintZ(&state.ui.status_msg, "No scene loaded or no materials to modify", .{}) catch {};
                        }
                    }
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Post Process", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var pp_changed = false;
                if (c.imgui_bridge_slider_float("Exposure", &state.runtime.post_process.exposure, 0.1, 10.0, "%.2f")) pp_changed = true;
                if (c.imgui_bridge_slider_float("Contrast", &state.runtime.post_process.contrast, 0.1, 3.0, "%.2f")) pp_changed = true;
                if (c.imgui_bridge_slider_float("Saturation", &state.runtime.post_process.saturation, 0.0, 3.0, "%.2f")) pp_changed = true;

                c.imgui_bridge_separator();
                c.imgui_bridge_text("Bloom");
                if (c.imgui_bridge_slider_float("Bloom Intensity", &state.runtime.post_process.bloomIntensity, 0.0, 1.0, "%.3f")) pp_changed = true;
                if (c.imgui_bridge_slider_float("Threshold", &state.runtime.post_process.bloomThreshold, 0.0, 5.0, "%.2f")) pp_changed = true;
                if (c.imgui_bridge_slider_float("Knee", &state.runtime.post_process.bloomKnee, 0.0, 1.0, "%.2f")) pp_changed = true;

                if (pp_changed) {
                    renderer.cardinal_renderer_set_post_process_params(state.runtime.renderer, &state.runtime.post_process);
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Rendering Mode", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                const current_mode = renderer.cardinal_renderer_get_rendering_mode(state.runtime.renderer);

                var current_item: i32 = rendering_mode_to_combo_index(current_mode);

                const items = [_][*:0]const u8{ "Normal", "UV Visualization", "Wireframe", "Mesh Shader" };

                if (c.imgui_bridge_combo("Mode", &current_item, &items[0], @intCast(items.len), -1)) {
                    const new_mode: types.CardinalRenderingMode = combo_index_to_rendering_mode(current_item);
                    renderer.cardinal_renderer_set_rendering_mode(state.runtime.renderer, new_mode);
                }
            }
        }
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
        .type = 0, // Directional
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

    if (state.runtime.descriptor_pool != null or initialized) {
        c.imgui_bridge_impl_vulkan_shutdown();
        c.imgui_bridge_impl_glfw_shutdown();
        state.runtime.descriptor_pool = null;
    }

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

    if (initialized or state.runtime.descriptor_pool != null) {
        log.cardinal_log_warn("[EDITOR_LAYER] Device restored but ImGui already initialized. Shutting down old instance.", .{});
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

    if (imgui_context != null) {
        c.imgui_bridge_set_current_context(imgui_context);
    }
    c.imgui_bridge_impl_vulkan_shutdown();
    c.imgui_bridge_impl_glfw_shutdown();
    c.imgui_bridge_destroy_context();
    imgui_context = null;

    if (state.runtime.descriptor_pool != null) {
        const device = @as(c.VkDevice, @ptrCast(renderer.cardinal_renderer_internal_device(state.runtime.renderer)));
        c.vkDestroyDescriptorPool(device, state.runtime.descriptor_pool, null);
    }

    model_manager.cardinal_model_manager_destroy(&state.runtime.model_manager);

    selection_system.reset_picking_cache();
    state.runtime.transform_overrides.deinit(allocator);
    state.runtime.mesh_owner_by_mesh_index.deinit(allocator);
    state.runtime.mesh_entity_by_mesh_index.deinit(allocator);
    state.runtime.model_root_by_id.deinit(allocator);

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

    state.runtime.config_manager.deinit();
    world_matrix_cache.deinit(allocator);
    override_cache.deinit(allocator);

    initialized = false;
}

pub fn update() void {
    if (!initialized) return;
    if (imgui_context != null) {
        c.imgui_bridge_set_current_context(imgui_context);
    }

    // Project Manager Modal (Blocking)
    if (!state.ui.project_loaded) {
        c.imgui_bridge_impl_vulkan_new_frame();
        c.imgui_bridge_impl_glfw_new_frame();
        c.imgui_bridge_new_frame();

        project_manager.draw_project_manager_panel(&state, allocator);
        return;
    }

    // Process async callbacks (frees fire-and-forget tasks like textures)
    _ = async_loader.cardinal_async_process_completed_tasks(0);

    check_loading_status();
    sync_skybox_from_ecs();

    if (state.runtime.model_manager.scene_dirty) {
        renderer.cardinal_renderer_clear_scene(state.runtime.renderer);
        if (model_manager.cardinal_model_manager_get_combined_scene(&state.runtime.model_manager)) |comb_ptr| {
            state.runtime.combined_scene = comb_ptr.*;
            state.runtime.pending_scene = state.runtime.combined_scene;
            state.runtime.scene_upload_pending = true;
            state.runtime.scene_loaded = (state.runtime.combined_scene.mesh_count > 0);
            state.runtime.transform_overrides.clearRetainingCapacity();
            selection_system.reset_picking_cache();
            state.ui.undo.clear();
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

    c.imgui_bridge_impl_vulkan_new_frame();
    c.imgui_bridge_impl_glfw_new_frame();
    c.imgui_bridge_new_frame();

    const dt = c.imgui_bridge_get_io_delta_time();

    // Update animation system if scene is loaded
    if (state.runtime.scene_loaded and state.runtime.combined_scene.animation_system != null) {
        const anim_sys_opaque = state.runtime.combined_scene.animation_system.?;
        const anim_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(anim_sys_opaque)));

        animation.cardinal_animation_system_update(anim_sys, state.runtime.combined_scene.all_nodes, state.runtime.combined_scene.all_node_count, dt);

        // Propagate animation changes to world transforms
        // We iterate through models to apply model transforms and update mesh transforms
        if (state.runtime.model_manager.models) |models| {
            var mesh_offset: u32 = 0;
            var m_idx: u32 = 0;
            while (m_idx < state.runtime.model_manager.model_count) : (m_idx += 1) {
                const model = &models[m_idx];
                if (!model.visible or model.is_loading) continue;

                const scn = &model.scene;

                // 1. Update root nodes with model transform
                // This propagates down the hierarchy, updating world_transform for all nodes
                if (scn.root_nodes) |roots| {
                    var r: u32 = 0;
                    while (r < scn.root_node_count) : (r += 1) {
                        // Pass model transform as parent to bake it into world transform
                        scene.cardinal_scene_node_update_transforms(roots[r], &model.transform);
                    }
                }

                // 2. Update mesh transforms from node world transforms
                // We need to iterate nodes that have meshes
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
                                        // Update mesh transform to match node world transform
                                        // Note: model transform is already baked into node world transform by step 1
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

        // Sync editor animation time with animation system state
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

    sync_mesh_visibility_from_ecs();
    sync_mesh_transforms_from_ecs();

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
    sync_mesh_index_maps_from_ecs();

    // Systems update
    input_system.update(&state);
    camera_controller.update(&state, dt);

    // --- Main DockSpace ---
    // Create a full-screen window for the dockspace
    const window_flags = c.ImGuiWindowFlags_MenuBar | c.ImGuiWindowFlags_NoTitleBar |
        c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize |
        c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoBringToFrontOnFocus |
        c.ImGuiWindowFlags_NoNavFocus | c.ImGuiWindowFlags_NoDocking |
        c.ImGuiWindowFlags_NoBackground;

    const viewport = c.imgui_bridge_get_main_viewport().?;

    // Use accessors since ImGuiViewport is opaque in Zig
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
    defer c.imgui_bridge_end(); // Ensure End() is always called

    if (dockspace_open) {
        // DockSpace
        const dock_id = c.imgui_bridge_get_id("EditorDockSpace");
        const dock_flags = c.ImGuiDockNodeFlags_PassthruCentralNode;
        c.imgui_bridge_dock_space(dock_id, &zero_vec, dock_flags);

        // Update Selection System (Gizmos)
        // Drawn into the DockSpace window (which has PassthruCentralNode), so it appears over the scene
        selection_system.update(&state);

        // Main Menu Bar
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
                if (c.imgui_bridge_menu_item("Exit", "Ctrl+Q", false, true)) {
                    // Exit logic - set window should close?
                    // We don't have direct access to window.should_close from here cleanly without externs or helpers
                    // But usually main loop handles this. For now just placeholder.
                }
                c.imgui_bridge_end_menu();
            }

            if (c.imgui_bridge_begin_menu("View", true)) {
                if (c.imgui_bridge_menu_item("Scene View", null, state.ui.show_scene_view, true)) state.ui.show_scene_view = !state.ui.show_scene_view;
                if (c.imgui_bridge_menu_item("Scene Graph", null, state.ui.show_scene_graph, true)) state.ui.show_scene_graph = !state.ui.show_scene_graph;
                if (c.imgui_bridge_menu_item("Assets", null, state.ui.show_assets, true)) state.ui.show_assets = !state.ui.show_assets;
                if (c.imgui_bridge_menu_item("Model Manager", null, state.ui.show_model_manager, true)) state.ui.show_model_manager = !state.ui.show_model_manager;
                if (c.imgui_bridge_menu_item("Inspector", null, state.ui.show_entity_inspector, true)) state.ui.show_entity_inspector = !state.ui.show_entity_inspector;
                if (c.imgui_bridge_menu_item("Scene Manager", null, state.ui.show_scene_manager, true)) state.ui.show_scene_manager = !state.ui.show_scene_manager;
                if (c.imgui_bridge_menu_item("PBR Settings", null, state.ui.show_pbr_settings, true)) state.ui.show_pbr_settings = !state.ui.show_pbr_settings;
                if (c.imgui_bridge_menu_item("Animation", null, state.ui.show_animation, true)) state.ui.show_animation = !state.ui.show_animation;
                if (c.imgui_bridge_menu_item("Performance", null, state.ui.show_performance_panel, true)) state.ui.show_performance_panel = !state.ui.show_performance_panel;
                if (c.imgui_bridge_menu_item("Grid & Axes", null, state.ui.show_grid_axes, true)) {
                    state.ui.show_grid_axes = !state.ui.show_grid_axes;
                    renderer.cardinal_renderer_set_debug_grid(state.runtime.renderer, state.ui.show_grid_axes);
                }
                c.imgui_bridge_end_menu();
            }
            c.imgui_bridge_end_menu_bar();
        }

        // Panels
        hierarchy_panel.draw_hierarchy_panel(&state);
        content_browser.draw_asset_browser_panel(&state, allocator);
        inspector.draw_inspector_panel(&state);
        draw_pbr_settings_panel();
        animation_panel.draw_animation_panel(&state);
        performance_panel.draw_performance_panel(&state);
        scene_manager_panel.draw_scene_manager_panel(&state, allocator);

        if (state.ui.show_scene_view) {
            const open_scene = c.imgui_bridge_begin("Scene", &state.ui.show_scene_view, 0);
            defer c.imgui_bridge_end();

            if (open_scene) {
                var win_pos: c.ImVec2 = undefined;
                var win_size: c.ImVec2 = undefined;
                c.imgui_bridge_get_window_pos(&win_pos);
                c.imgui_bridge_get_window_size(&win_size);

                if (state.ui.show_grid_axes) {
                    // Grid is rendered in world-space by Vulkan; only draw axes gizmo here.

                    const cam = state.runtime.camera;
                    const world_up = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
                    var forward = Vec3{
                        .x = cam.target.x - cam.position.x,
                        .y = cam.target.y - cam.position.y,
                        .z = cam.target.z - cam.position.z,
                    };
                    const forward_len = forward.length();
                    if (forward_len > 0.0001) {
                        forward = forward.mul(1.0 / forward_len);
                    } else {
                        forward = Vec3{ .x = 0.0, .y = 0.0, .z = -1.0 };
                    }

                    var right = forward.cross(world_up);
                    const right_len = right.length();
                    if (right_len > 0.0001) {
                        right = right.mul(1.0 / right_len);
                    } else {
                        right = Vec3{ .x = 1.0, .y = 0.0, .z = 0.0 };
                    }

                    var up_cam = right.cross(forward);
                    const up_len = up_cam.length();
                    if (up_len > 0.0001) {
                        up_cam = up_cam.mul(1.0 / up_len);
                    } else {
                        up_cam = world_up;
                    }

                    const origin = c.ImVec2{
                        .x = win_pos.x + 60.0,
                        .y = win_pos.y + win_size.y - 60.0,
                    };
                    const axis_size: f32 = 40.0;

                    const axes = [_]struct { dir: Vec3, color: u32 }{
                        .{ .dir = Vec3{ .x = 1.0, .y = 0.0, .z = 0.0 }, .color = 0xFFFF5555 },
                        .{ .dir = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 }, .color = 0xFF55FF55 },
                        .{ .dir = Vec3{ .x = 0.0, .y = 0.0, .z = 1.0 }, .color = 0xFF5599FF },
                    };

                    var i: usize = 0;
                    while (i < axes.len) : (i += 1) {
                        const axis_world = axes[i].dir;
                        const vx = axis_world.dot(right);
                        const vy = axis_world.dot(up_cam);

                        var sx = vx;
                        var sy = -vy;
                        const len_sq = sx * sx + sy * sy;
                        if (len_sq <= 0.0001) continue;
                        const inv_len = 1.0 / @sqrt(len_sq);
                        sx *= inv_len;
                        sy *= inv_len;

                        const end = c.ImVec2{
                            .x = origin.x + sx * axis_size,
                            .y = origin.y + sy * axis_size,
                        };

                        var p0 = origin;
                        var p1 = end;
                        c.imgui_bridge_draw_line(&p0, &p1, axes[i].color, 2.0);
                    }

                    var center = origin;
                    c.imgui_bridge_draw_circle_filled(&center, 3.0, 0xFFFFFFFF);
                }
            }
        }

        // Status Bar (as a simple window for now, or part of dockspace)
        // Note: Begin() must be matched with End() regardless of return value
        const status_open = c.imgui_bridge_begin("Status", null, 0);
        defer c.imgui_bridge_end();

        if (status_open) {
            c.imgui_bridge_text("Status: %s", &state.ui.status_msg);
        }
    }
    // c.imgui_bridge_end(); // End DockSpace window (handled by defer)
}

pub fn render() void {
    if (!initialized) return;
    c.imgui_bridge_render();
    // Render call is handled by callback
}

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
                    // Extract direction from world transform (assuming -Z is forward)
                    const m = node.world_transform;
                    // Column 2 is Z axis: m[8], m[9], m[10]
                    // Direction = -Z
                    state.runtime.light.direction = .{ .x = -m[8], .y = -m[9], .z = -m[10] };
                    // Position is column 3: m[12], m[13], m[14]
                    state.runtime.light.position = .{ .x = m[12], .y = m[13], .z = m[14] };
                    log.cardinal_log_info("Updated light transform from node {d}: Pos=({d:.2},{d:.2},{d:.2})", .{ sl.node_index, state.runtime.light.position.x, state.runtime.light.position.y, state.runtime.light.position.z });
                }
            }
        }
    }

    if (state.runtime.pbr_enabled) {
        renderer.cardinal_renderer_set_camera(state.runtime.renderer, &state.runtime.camera);

        var pbr_lights: [types.MAX_LIGHTS]types.PBRLight = undefined;
        var light_count: u32 = 0;

        // 1. Add Manual Directional Light (if enabled)
        if (state.runtime.enable_directional_light) {
            pbr_lights[light_count] = std.mem.zeroes(types.PBRLight);
            // Ensure type is Directional (0)
            pbr_lights[light_count].lightDirection = .{ state.runtime.light.direction.x, state.runtime.light.direction.y, state.runtime.light.direction.z, 0.0 };
            pbr_lights[light_count].lightPosition = .{ state.runtime.light.position.x, state.runtime.light.position.y, state.runtime.light.position.z, 0.0 };
            pbr_lights[light_count].lightColor = .{ state.runtime.light.color.x, state.runtime.light.color.y, state.runtime.light.color.z, state.runtime.light.intensity };
            pbr_lights[light_count].params = .{ state.runtime.light.range, @cos(state.runtime.light.inner_cone), @cos(state.runtime.light.outer_cone), 0.0 };
            light_count += 1;
        }

        // 2. Add Scene Lights (Point/Spot)
        if (state.runtime.combined_scene.light_count > 0 and state.runtime.combined_scene.lights != null) {
            var i: u32 = 0;
            while (i < state.runtime.combined_scene.light_count and light_count < types.MAX_LIGHTS) : (i += 1) {
                const sl = &state.runtime.combined_scene.lights.?[i];

                // User requested that manual controls be used for Directional Light (Sun),
                // and scene lights be used for Point/Spot.
                // We skip scene directional lights to ensure the manual sun is the only one.
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
                if (intensity < 100.0) intensity *= 100.0; // Auto-boost

                pbr_lights[light_count] = std.mem.zeroes(types.PBRLight);
                pbr_lights[light_count].lightDirection = .{ dir.x, dir.y, dir.z, @floatFromInt(@intFromEnum(sl.type)) };
                pbr_lights[light_count].lightPosition = .{ pos.x, pos.y, pos.z, 0.0 };
                pbr_lights[light_count].lightColor = .{ sl.color[0], sl.color[1], sl.color[2], intensity };
                // Set params (range, inner, outer)
                pbr_lights[light_count].params = .{ sl.range, @cos(sl.inner_cone_angle), @cos(sl.outer_cone_angle), 0.0 };

                light_count += 1;
            }
        }

        if (light_count > 0) {
            renderer.cardinal_renderer_set_lights(state.runtime.renderer, &pbr_lights, light_count);
        } else {
            // Fallback if no lights enabled (prevent crash or undefined state)
            // Just send 0 lights
            renderer.cardinal_renderer_set_lights(state.runtime.renderer, null, 0);
        }
    }
}
