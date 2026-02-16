const std = @import("std");
const engine = @import("cardinal_engine");
const math = engine.math;
const Vec3 = math.Vec3;
const log = engine.log;
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
const performance_panel = @import("panels/performance_panel.zig");
const input_system = @import("systems/input.zig");
const camera_controller = @import("systems/camera_controller.zig");
const scene_io = @import("systems/scene_io.zig");

const c = @import("c.zig").c;

// Global allocator for editor state
const allocator = engine.memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();

var state: EditorState = undefined;
var initialized: bool = false;
var device_recovery_failed: bool = false;

fn check_loading_status() void {
    if (state.loading_tasks.items.len == 0) {
        state.is_loading = false;
        return;
    }

    var i: usize = 0;
    while (i < state.loading_tasks.items.len) {
        const info = state.loading_tasks.items[i];
        const task = info.task;
        const status = async_loader.cardinal_async_get_task_status(task);

        if (status == .COMPLETED) {
            var loaded_scene: scene.CardinalScene = undefined;
            if (async_loader.cardinal_async_get_scene_result(task, &loaded_scene)) {
                const path = info.path;
                const filename = std.fs.path.basename(path);

                // Use Arena for temporary filename
                const filename_z = state.arena_allocator.dupeZ(u8, filename) catch "unknown";

                const model_id = model_manager.cardinal_model_manager_add_scene(&state.model_manager, &loaded_scene, path, filename_z);

                // On failure, we must destroy loaded_scene to prevent leaks.
                // If success, this is a no-op as loaded_scene is zeroed.
                scene.cardinal_scene_destroy(&loaded_scene);

                if (model_id != 0) {
                    state.selected_model_id = model_id;
                    const combined = model_manager.cardinal_model_manager_get_combined_scene(&state.model_manager);
                    if (combined) |comb_ptr| {
                        state.combined_scene = comb_ptr.*;
                        state.scene_loaded = true;

                        // Re-init ECS Registry and Import Scene
                        state.registry.deinit();
                        state.registry.* = engine.ecs_registry.Registry.init(allocator);
                        scene_io.import_scene_graph(&state);

                        if (initialized) {
                            state.pending_scene = state.combined_scene;
                            state.scene_upload_pending = true;
                            // Reset animation selection when new scene is loaded
                            state.selected_animation = -1;
                            state.animation_time = 0.0;
                            state.animation_playing = false;

                            log.cardinal_log_info("[EDITOR] Deferred scene upload scheduled", .{});
                        }

                        _ = std.fmt.bufPrintZ(&state.status_msg, "Loaded model: {d} meshes from {s} (ID: {d})", .{ loaded_scene.mesh_count, filename, model_id }) catch {};
                    }
                }
            }

            async_loader.cardinal_async_free_task(task);
            allocator.free(info.path);
            _ = state.loading_tasks.swapRemove(i);
        } else if (status == .FAILED) {
            const err_msg = async_loader.cardinal_async_get_error_message(task);
            const err_str = if (err_msg) |msg| std.mem.span(msg) else "unknown error";
            const path = info.path;
            _ = std.fmt.bufPrintZ(&state.status_msg, "Failed to load: {s} - {s}", .{ path, err_str }) catch {};

            async_loader.cardinal_async_free_task(task);
            allocator.free(info.path);
            _ = state.loading_tasks.swapRemove(i);
        } else {
            i += 1;
        }
    }

    state.is_loading = (state.loading_tasks.items.len > 0);
}

fn save_scene() void {
    // TODO: Use file dialog
    scene_io.save_scene(&state, allocator, "assets/scenes/scene.json");
}

fn load_scene() void {
    // TODO: Use file dialog
    scene_io.load_scene(&state, allocator, "assets/scenes/scene.json");
}

fn draw_pbr_settings_panel() void {
    if (state.show_pbr_settings) {
        const open = c.imgui_bridge_begin("PBR Settings", &state.show_pbr_settings, 0);
        defer c.imgui_bridge_end();

        if (open) {
            if (c.imgui_bridge_checkbox("Enable PBR Rendering", &state.pbr_enabled)) {
                renderer.cardinal_renderer_enable_pbr(state.renderer, state.pbr_enabled);
                if (state.pbr_enabled) {
                    renderer.cardinal_renderer_set_camera(state.renderer, &state.camera);
                    renderer.cardinal_renderer_set_lighting(state.renderer, &state.light);
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Camera", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var cam_changed = false;
                if (c.imgui_bridge_drag_float3("Position", @ptrCast(&state.camera.position), 0.1, 0.0, 0.0, "%.3f", 0)) cam_changed = true;
                if (c.imgui_bridge_drag_float3("Target", @ptrCast(&state.camera.target), 0.1, 0.0, 0.0, "%.3f", 0)) cam_changed = true;
                if (c.imgui_bridge_slider_float("FOV", &state.camera.fov, 10.0, 120.0, "%.1f")) cam_changed = true;

                if (cam_changed and state.pbr_enabled) {
                    renderer.cardinal_renderer_set_camera(state.renderer, &state.camera);
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Lighting", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var light_changed = false;

                // Enforce Directional Light (User request: remove choosing, always have direct light controls)
                state.enable_directional_light = true;
                state.light.type = 0; // Directional

                c.imgui_bridge_text("Directional Light (Sun)");
                if (c.imgui_bridge_drag_float3("Direction", @ptrCast(&state.light.direction), 0.01, -1.0, 1.0, "%.3f", 0)) light_changed = true;

                if (c.imgui_bridge_color_edit3("Color", @ptrCast(&state.light.color), 0)) light_changed = true;
                if (c.imgui_bridge_slider_float("Intensity##DirectionalLight", &state.light.intensity, 0.0, 20.0, "%.2f")) light_changed = true;
                if (c.imgui_bridge_color_edit3("Ambient", @ptrCast(&state.light.ambient), 0)) light_changed = true;

                if (light_changed) {
                    // Light will be updated in process_pending_uploads
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Material Override", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                _ = c.imgui_bridge_checkbox("Enable Material Override", &state.material_override_enabled);

                if (state.material_override_enabled) {
                    c.imgui_bridge_separator();
                    _ = c.imgui_bridge_color_edit3("Albedo Factor", @ptrCast(&state.material_albedo), 0);
                    _ = c.imgui_bridge_slider_float("Metallic Factor", &state.material_metallic, 0.0, 1.0, "%.3f");
                    _ = c.imgui_bridge_slider_float("Roughness Factor", &state.material_roughness, 0.0, 1.0, "%.3f");
                    _ = c.imgui_bridge_color_edit3("Emissive Factor", &state.material_emissive, 0);
                    _ = c.imgui_bridge_slider_float("Normal Scale", &state.material_normal_scale, 0.0, 2.0, "%.3f");
                    _ = c.imgui_bridge_slider_float("AO Strength", &state.material_ao_strength, 0.0, 1.0, "%.3f");

                    if (c.imgui_bridge_button("Apply to All Materials")) {
                        if (state.scene_loaded and state.combined_scene.material_count > 0) {
                            var i: u32 = 0;
                            while (i < state.combined_scene.material_count) : (i += 1) {
                                if (state.combined_scene.materials) |materials| {
                                    var mat = &materials[i];

                                    mat.albedo_factor = state.material_albedo;
                                    mat.metallic_factor = state.material_metallic;
                                    mat.roughness_factor = state.material_roughness;
                                    mat.emissive_factor = state.material_emissive;
                                    mat.normal_scale = state.material_normal_scale;
                                    mat.ao_strength = state.material_ao_strength;
                                }
                            }

                            // Schedule re-upload
                            state.pending_scene = state.combined_scene;
                            state.scene_upload_pending = true;
                            _ = std.fmt.bufPrintZ(&state.status_msg, "Applied material override to {d} materials", .{state.combined_scene.material_count}) catch {};
                        } else {
                            _ = std.fmt.bufPrintZ(&state.status_msg, "No scene loaded or no materials to modify", .{}) catch {};
                        }
                    }
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Post Process", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var pp_changed = false;
                if (c.imgui_bridge_slider_float("Exposure", &state.post_process.exposure, 0.1, 10.0, "%.2f")) pp_changed = true;
                if (c.imgui_bridge_slider_float("Contrast", &state.post_process.contrast, 0.1, 3.0, "%.2f")) pp_changed = true;
                if (c.imgui_bridge_slider_float("Saturation", &state.post_process.saturation, 0.0, 3.0, "%.2f")) pp_changed = true;

                c.imgui_bridge_separator();
                c.imgui_bridge_text("Bloom");
                if (c.imgui_bridge_slider_float("Bloom Intensity", &state.post_process.bloomIntensity, 0.0, 1.0, "%.3f")) pp_changed = true;
                if (c.imgui_bridge_slider_float("Threshold", &state.post_process.bloomThreshold, 0.0, 5.0, "%.2f")) pp_changed = true;
                if (c.imgui_bridge_slider_float("Knee", &state.post_process.bloomKnee, 0.0, 1.0, "%.2f")) pp_changed = true;

                if (pp_changed) {
                    renderer.cardinal_renderer_set_post_process_params(state.renderer, &state.post_process);
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Rendering Mode", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                const current_mode = renderer.cardinal_renderer_get_rendering_mode(state.renderer);

                // Map enum to combo index
                // 0: Normal (0)
                // 1: UV (3)
                // 2: Wireframe (4)
                // 3: Mesh Shader (1)
                var current_item: i32 = 0;
                switch (current_mode) {
                    .NORMAL => current_item = 0,
                    .UV => current_item = 1,
                    .WIREFRAME => current_item = 2,
                    .MESH_SHADER => current_item = 3,
                    else => current_item = 0,
                }

                const items = [_][*:0]const u8{ "Normal", "UV Visualization", "Wireframe", "Mesh Shader" };

                if (c.imgui_bridge_combo("Mode", &current_item, &items[0], @intCast(items.len), -1)) {
                    // Map combo index to enum
                    const new_mode: types.CardinalRenderingMode = switch (current_item) {
                        0 => .NORMAL,
                        1 => .UV,
                        2 => .WIREFRAME,
                        3 => .MESH_SHADER,
                        else => .NORMAL,
                    };
                    renderer.cardinal_renderer_set_rendering_mode(state.renderer, new_mode);
                }
            }
        }
    }
}

const VkCommandBuffer = c.VkCommandBuffer;

fn ui_draw_callback(cmd: VkCommandBuffer) callconv(.c) void {
    c.imgui_bridge_impl_vulkan_render_draw_data(@ptrCast(cmd));
}

// Public API

pub fn init(win_ptr: *window.CardinalWindow, rnd_ptr: *types.CardinalRenderer, registry: *engine.ecs_registry.Registry) bool {
    if (initialized) {
        log.cardinal_log_warn("[EDITOR] Already initialized", .{});
        return true;
    }

    // Initialize state with defaults
    state = .{};

    // Initialize Arena
    state.arena = std.heap.ArenaAllocator.init(allocator);
    state.arena_allocator = state.arena.allocator();

    state.window = win_ptr;
    state.renderer = rnd_ptr;
    state.registry = registry;
    state.camera = .{
        .position = .{ .x = 0.0, .y = 2.0, .z = 5.0 },
        .target = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
        .up = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
        .fov = 65.0,
        .aspect = 16.0 / 9.0,
        .near_plane = 0.1,
        .far_plane = 100.0,
    };
    state.light = .{
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

    if (!model_manager.cardinal_model_manager_init(&state.model_manager)) return false;

    // Init Config
    state.config_manager = engine.config.ConfigManager.init(allocator, "cardinal_config.json", .{});
    state.config_manager.load() catch |err| {
        log.cardinal_log_warn("Failed to load config: {}", .{err});
    };

    var buffer: [1024]u8 = undefined;
    var assets_path: []const u8 = undefined;

    // Check if configured path exists
    if (std.fs.openDirAbsolute(state.config_manager.config.assets_path, .{})) |_| {
        assets_path = state.config_manager.config.assets_path;
    } else |err| {
        // Fallback to relative "assets"
        log.cardinal_log_warn("Configured assets path '{s}' invalid ({}), using default", .{ state.config_manager.config.assets_path, err });
        assets_path = std.fs.cwd().realpath("assets", &buffer) catch |e| {
            log.cardinal_log_error("Failed to resolve assets directory: {}", .{e});
            return false;
        };
    }

    state.assets.assets_dir = allocator.dupeZ(u8, assets_path) catch return false;
    state.assets.current_dir = allocator.dupeZ(u8, assets_path) catch return false;
    state.assets.search_filter = allocator.alloc(u8, 256) catch return false;
    @memset(state.assets.search_filter, 0);

    // Initial scan
    content_browser.scan_assets_dir(&state, allocator);

    c.imgui_bridge_create_context();
    c.imgui_bridge_enable_docking(true);
    c.imgui_bridge_enable_keyboard(true);
    c.imgui_bridge_style_colors_dark();

    // Set high DPI scale
    var x_scale: f32 = 1.0;
    var y_scale: f32 = 1.0;
    window.cardinal_window_get_content_scale(win_ptr, &x_scale, &y_scale);
    if (x_scale > 1.0) {
        c.imgui_bridge_set_display_scale(x_scale);
        log.cardinal_log_info("High DPI detected: scale {d:.2}", .{x_scale});
    }

    const glfw_window = @as(?*c.GLFWwindow, @ptrCast(win_ptr.handle));
    if (!c.imgui_bridge_impl_glfw_init_for_vulkan(glfw_window, true)) return false;

    // Pool setup
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
    if (c.vkCreateDescriptorPool(device, &pool_info, null, &state.descriptor_pool) != c.VK_SUCCESS) return false;

    // Hack: Ensure backend data is clear before init (fixes restart/reload issues)
    c.imgui_bridge_force_clear_backend_data();

    var init_info = c.ImGuiBridgeVulkanInitInfo{
        .instance = @as(c.VkInstance, @ptrCast(renderer.cardinal_renderer_internal_instance(rnd_ptr))),
        .physical_device = @as(c.VkPhysicalDevice, @ptrCast(renderer.cardinal_renderer_internal_physical_device(rnd_ptr))),
        .device = device,
        .queue_family = renderer.cardinal_renderer_internal_graphics_queue_family(rnd_ptr),
        .queue = @as(c.VkQueue, @ptrCast(renderer.cardinal_renderer_internal_graphics_queue(rnd_ptr))),
        .descriptor_pool = state.descriptor_pool,
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

    renderer.cardinal_renderer_set_camera(rnd_ptr, &state.camera);
    std.debug.print("[EDITOR_LAYER] Camera set.\n", .{});
    renderer.cardinal_renderer_set_lighting(rnd_ptr, &state.light);
    std.debug.print("[EDITOR_LAYER] Lighting set.\n", .{});
    renderer.cardinal_renderer_set_post_process_params(rnd_ptr, &state.post_process);
    renderer.cardinal_renderer_set_ui_callback(rnd_ptr, @ptrCast(&ui_draw_callback));

    // Initialize scene list
    scene_io.refresh_available_scenes(&state, allocator);

    initialized = true;
    return true;
}

pub fn on_device_loss(_: ?*anyopaque) callconv(.c) void {
    log.cardinal_log_warn("[EDITOR_LAYER] Device loss detected, shutting down ImGui", .{});

    device_recovery_failed = false;

    // We can use the global 'initialized' flag or check descriptor_pool.
    // If descriptor_pool is set, we definitely initialized.
    if (state.descriptor_pool != null or initialized) {
        c.imgui_bridge_impl_vulkan_shutdown();
        state.descriptor_pool = null;
    }

    // Mark as uninitialized to prevent update loop from calling backend functions
    initialized = false;
}

pub fn on_device_restored(user_data: ?*anyopaque, success: bool) callconv(.c) void {
    _ = user_data;
    if (!success) {
        log.cardinal_log_error("[EDITOR_LAYER] Device recovery failed, cannot restore ImGui", .{});
        device_recovery_failed = true;
        _ = std.fmt.bufPrintZ(&state.status_msg, "Vulkan device lost; please restart editor", .{}) catch {};
        return;
    }

    log.cardinal_log_info("[EDITOR_LAYER] Device restored, re-initializing ImGui", .{});

    // Re-create descriptor pool with NEW device
    const rnd_ptr = state.renderer;
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

    if (c.vkCreateDescriptorPool(device, &pool_info, null, &state.descriptor_pool) != c.VK_SUCCESS) {
        log.cardinal_log_error("[EDITOR_LAYER] Failed to recreate descriptor pool", .{});
        return;
    }

    // Invalidate existing textures to prevent use-after-free or invalid pool errors
    c.imgui_bridge_invalidate_device_objects();

    // Ensure backend data is clear before re-init
    c.imgui_bridge_force_clear_backend_data();

    var init_info = c.ImGuiBridgeVulkanInitInfo{
        .instance = @as(c.VkInstance, @ptrCast(renderer.cardinal_renderer_internal_instance(rnd_ptr))),
        .physical_device = @as(c.VkPhysicalDevice, @ptrCast(renderer.cardinal_renderer_internal_physical_device(rnd_ptr))),
        .device = device,
        .queue_family = renderer.cardinal_renderer_internal_graphics_queue_family(rnd_ptr),
        .queue = @as(c.VkQueue, @ptrCast(renderer.cardinal_renderer_internal_graphics_queue(rnd_ptr))),
        .descriptor_pool = state.descriptor_pool,
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

    // Mark as initialized again to resume update loop
    initialized = true;
    device_recovery_failed = false;
}

pub fn has_device_recovery_failed() bool {
    return device_recovery_failed;
}

pub fn shutdown() void {
    // Process any remaining completed tasks
    _ = async_loader.cardinal_async_process_completed_tasks(0);

    // Wait for any background texture uploads to finish before we destroy the model manager (which owns the data)
    renderer.cardinal_renderer_wait_for_texture_uploads(state.renderer);

    c.imgui_bridge_impl_vulkan_shutdown();
    c.imgui_bridge_impl_glfw_shutdown();
    c.imgui_bridge_destroy_context();

    if (state.descriptor_pool != null) {
        const device = @as(c.VkDevice, @ptrCast(renderer.cardinal_renderer_internal_device(state.renderer)));
        c.vkDestroyDescriptorPool(device, state.descriptor_pool, null);
    }

    model_manager.cardinal_model_manager_destroy(&state.model_manager);

    for (state.loading_tasks.items) |info| {
        async_loader.cardinal_async_free_task(info.task);
        allocator.free(info.path);
    }
    state.loading_tasks.deinit(allocator);

    for (state.assets.entries.items) |entry| {
        entry.deinit(allocator);
    }
    state.assets.entries.deinit(allocator);
    state.assets.filtered_entries.deinit(allocator);
    allocator.free(state.assets.assets_dir[0 .. state.assets.assets_dir.len + 1]);
    allocator.free(state.assets.current_dir[0 .. state.assets.current_dir.len + 1]);
    allocator.free(state.assets.search_filter);

    initialized = false;
}

pub fn update() void {
    if (!initialized) return;

    // Process async callbacks (frees fire-and-forget tasks like textures)
    _ = async_loader.cardinal_async_process_completed_tasks(0);

    check_loading_status();

    c.imgui_bridge_impl_vulkan_new_frame();
    c.imgui_bridge_impl_glfw_new_frame();
    c.imgui_bridge_new_frame();

    const dt = c.imgui_bridge_get_io_delta_time();

    // Update animation system if scene is loaded
    if (state.scene_loaded and state.combined_scene.animation_system != null) {
        const anim_sys_opaque = state.combined_scene.animation_system.?;
        const anim_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(anim_sys_opaque)));

        animation.cardinal_animation_system_update(anim_sys, state.combined_scene.all_nodes, state.combined_scene.all_node_count, dt);

        // Propagate animation changes to world transforms
        // We iterate through models to apply model transforms and update mesh transforms
        if (state.model_manager.models) |models| {
            var mesh_offset: u32 = 0;
            var m_idx: u32 = 0;
            while (m_idx < state.model_manager.model_count) : (m_idx += 1) {
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

                                    if (combined_idx < state.combined_scene.mesh_count) {
                                        const mesh = &state.combined_scene.meshes.?[combined_idx];
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

        // Update skinning matrices
        if (anim_sys.skin_count > 0 and anim_sys.skins != null and anim_sys.bone_matrices != null) {
            const nodes_ptr = @as(?[*]?*const scene.CardinalSceneNode, @ptrCast(state.combined_scene.all_nodes));
            var s_idx: u32 = 0;
            while (s_idx < anim_sys.skin_count) : (s_idx += 1) {
                const skin = &anim_sys.skins.?[s_idx];
                _ = animation.cardinal_skin_update_bone_matrices(skin, nodes_ptr, anim_sys.bone_matrices);
            }
        }

        // Sync editor animation time with animation system state
        if (state.selected_animation >= 0 and state.selected_animation < anim_sys.animation_count) {
            var i: u32 = 0;
            while (i < anim_sys.state_count) : (i += 1) {
                const anim_state = &anim_sys.states.?[i];
                if (anim_state.animation_index == @as(u32, @intCast(state.selected_animation))) {
                    state.animation_time = anim_state.current_time;
                    state.animation_playing = anim_state.is_playing;
                    state.animation_looping = anim_state.is_looping;
                    state.animation_speed = anim_state.playback_speed;
                    break;
                }
            }
        }
    }

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

        // Main Menu Bar
        if (c.imgui_bridge_begin_menu_bar()) {
            if (c.imgui_bridge_begin_menu("File", true)) {
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
                if (c.imgui_bridge_menu_item("Scene Graph", null, state.show_scene_graph, true)) state.show_scene_graph = !state.show_scene_graph;
                if (c.imgui_bridge_menu_item("Assets", null, state.show_assets, true)) state.show_assets = !state.show_assets;
                if (c.imgui_bridge_menu_item("Model Manager", null, state.show_model_manager, true)) state.show_model_manager = !state.show_model_manager;
                if (c.imgui_bridge_menu_item("Scene Manager", null, state.show_scene_manager, true)) state.show_scene_manager = !state.show_scene_manager;
                if (c.imgui_bridge_menu_item("PBR Settings", null, state.show_pbr_settings, true)) state.show_pbr_settings = !state.show_pbr_settings;
                if (c.imgui_bridge_menu_item("Animation", null, state.show_animation, true)) state.show_animation = !state.show_animation;
                if (c.imgui_bridge_menu_item("Performance", null, state.show_performance_panel, true)) state.show_performance_panel = !state.show_performance_panel;
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

        // Check for dirty model manager and update combined scene
        if (state.model_manager.scene_dirty) {
            const combined = model_manager.cardinal_model_manager_get_combined_scene(&state.model_manager);
            if (combined) |comb_ptr| {
                state.combined_scene = comb_ptr.*;
                state.pending_scene = state.combined_scene;
                state.scene_upload_pending = true;
                log.cardinal_log_info("[EDITOR] Model manager dirty, updating combined scene", .{});
            }
        }

        // Status Bar (as a simple window for now, or part of dockspace)
        // Note: Begin() must be matched with End() regardless of return value
        const status_open = c.imgui_bridge_begin("Status", null, 0);
        defer c.imgui_bridge_end();

        if (status_open) {
            c.imgui_bridge_text("Status: %s", &state.status_msg);
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
    if (state.scene_upload_pending and initialized) {
        log.cardinal_log_info("[EDITOR] Pending upload detected", .{});
        renderer.cardinal_renderer_upload_scene(state.renderer, &state.pending_scene);

        state.combined_scene = state.pending_scene;
        state.scene_upload_pending = false;

        if (state.combined_scene.light_count > 0 and state.combined_scene.lights != null) {
            const sl = &state.combined_scene.lights.?[0];
            state.light.color = .{ .x = sl.color[0], .y = sl.color[1], .z = sl.color[2] };
            state.light.intensity = sl.intensity;
            state.light.range = sl.range;
            state.light.type = @intFromEnum(sl.type);

            if (sl.node_index < state.combined_scene.all_node_count and state.combined_scene.all_nodes != null) {
                if (state.combined_scene.all_nodes.?[sl.node_index]) |node| {
                    // Extract direction from world transform (assuming -Z is forward)
                    const m = node.world_transform;
                    // Column 2 is Z axis: m[8], m[9], m[10]
                    // Direction = -Z
                    state.light.direction = .{ .x = -m[8], .y = -m[9], .z = -m[10] };
                    // Position is column 3: m[12], m[13], m[14]
                    state.light.position = .{ .x = m[12], .y = m[13], .z = m[14] };
                    log.cardinal_log_info("Updated light transform from node {d}: Pos=({d:.2},{d:.2},{d:.2})", .{ sl.node_index, state.light.position.x, state.light.position.y, state.light.position.z });
                }
            }
        }
    }

    if (state.pbr_enabled) {
        renderer.cardinal_renderer_set_camera(state.renderer, &state.camera);

        var pbr_lights: [types.MAX_LIGHTS]types.PBRLight = undefined;
        var light_count: u32 = 0;

        // 1. Add Manual Directional Light (if enabled)
        if (state.enable_directional_light) {
            pbr_lights[light_count] = std.mem.zeroes(types.PBRLight);
            // Ensure type is Directional (0)
            pbr_lights[light_count].lightDirection = .{ state.light.direction.x, state.light.direction.y, state.light.direction.z, 0.0 };
            pbr_lights[light_count].lightPosition = .{ state.light.position.x, state.light.position.y, state.light.position.z, 0.0 };
            pbr_lights[light_count].lightColor = .{ state.light.color.x, state.light.color.y, state.light.color.z, state.light.intensity };
            pbr_lights[light_count].params = .{ state.light.range, @cos(state.light.inner_cone), @cos(state.light.outer_cone), 0.0 };
            light_count += 1;
        }

        // 2. Add Scene Lights (Point/Spot)
        if (state.combined_scene.light_count > 0 and state.combined_scene.lights != null) {
            var i: u32 = 0;
            while (i < state.combined_scene.light_count and light_count < types.MAX_LIGHTS) : (i += 1) {
                const sl = &state.combined_scene.lights.?[i];

                // User requested that manual controls be used for Directional Light (Sun),
                // and scene lights be used for Point/Spot.
                // We skip scene directional lights to ensure the manual sun is the only one.
                if (sl.type == .DIRECTIONAL) continue;

                var pos = math.Vec3{ .x = 0, .y = 0, .z = 0 };
                var dir = math.Vec3{ .x = 0, .y = -1, .z = 0 };

                if (sl.node_index < state.combined_scene.all_node_count and state.combined_scene.all_nodes != null) {
                    if (state.combined_scene.all_nodes.?[sl.node_index]) |node| {
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
            renderer.cardinal_renderer_set_lights(state.renderer, &pbr_lights, light_count);
        } else {
            // Fallback if no lights enabled (prevent crash or undefined state)
            // Just send 0 lights
            renderer.cardinal_renderer_set_lights(state.renderer, null, 0);
        }
    }
}
