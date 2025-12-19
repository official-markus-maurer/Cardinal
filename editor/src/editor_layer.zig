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

const editor_state = @import("editor_state.zig");
const EditorState = editor_state.EditorState;
const AssetState = editor_state.AssetState;

const scene_hierarchy = @import("panels/scene_hierarchy.zig");
const content_browser = @import("panels/content_browser.zig");
const inspector = @import("panels/inspector.zig");
const memory_stats = @import("panels/memory_stats.zig");
const input_system = @import("systems/input.zig");
const camera_controller = @import("systems/camera_controller.zig");

const c = @import("c.zig").c;

// Global allocator for editor state
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var state: EditorState = undefined;
var initialized: bool = false;

fn check_loading_status() void {
    if (!state.is_loading or state.loading_task == null) return;

    const task = state.loading_task.?;
    const status = async_loader.cardinal_async_get_task_status(task);

    if (status == .COMPLETED) {
        var loaded_scene: scene.CardinalScene = undefined;
        if (async_loader.cardinal_async_get_scene_result(task, &loaded_scene)) {
            const path = state.loading_scene_path orelse "unknown";
            const filename = std.fs.path.basename(path);
            const filename_z = allocator.dupeZ(u8, filename) catch "unknown";
            defer allocator.free(filename_z);

            // Pass pointer to path_copy which is null-terminated and kept alive in state
            const model_id = model_manager.cardinal_model_manager_add_scene(&state.model_manager, &loaded_scene, path, filename_z);

            if (model_id != 0) {
                state.selected_model_id = model_id;
                const combined = model_manager.cardinal_model_manager_get_combined_scene(&state.model_manager);
                if (combined) |comb_ptr| {
                    state.combined_scene = comb_ptr.*;
                    state.scene_loaded = true;

                    if (initialized) {
                        state.pending_scene = state.combined_scene;
                        state.scene_upload_pending = true;
                        log.cardinal_log_info("[EDITOR] Deferred scene upload scheduled", .{});
                    }

                    _ = std.fmt.bufPrintZ(&state.status_msg, "Loaded model: {d} meshes from {s} (ID: {d})", .{ loaded_scene.mesh_count, filename, model_id }) catch {};
                }
            }
        }

        async_loader.cardinal_async_free_task(task);
        state.loading_task = null;
        state.is_loading = false;
        if (state.loading_scene_path) |p| {
            allocator.free(p);
            state.loading_scene_path = null;
        }
    } else if (status == .FAILED) {
        const err_msg = async_loader.cardinal_async_get_error_message(task);
        const err_str = if (err_msg) |msg| std.mem.span(msg) else "unknown error";
        const path = state.loading_scene_path orelse "unknown";
        _ = std.fmt.bufPrintZ(&state.status_msg, "Failed to load: {s} - {s}", .{ path, err_str }) catch {};

        async_loader.cardinal_async_free_task(task);
        state.loading_task = null;
        state.is_loading = false;
        if (state.loading_scene_path) |p| {
            allocator.free(p);
            state.loading_scene_path = null;
        }
    }
}

fn draw_pbr_settings_panel() void {
    if (state.show_pbr_settings) {
        if (c.imgui_bridge_begin("PBR Settings", &state.show_pbr_settings, 0)) {
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
                if (c.imgui_bridge_drag_float3("Direction", @ptrCast(&state.light.direction), 0.01, -1.0, 1.0, "%.3f", 0)) light_changed = true;
                if (c.imgui_bridge_color_edit3("Color", @ptrCast(&state.light.color), 0)) light_changed = true;
                if (c.imgui_bridge_slider_float("Intensity", &state.light.intensity, 0.0, 10.0, "%.2f")) light_changed = true;
                if (c.imgui_bridge_color_edit3("Ambient", @ptrCast(&state.light.ambient), 0)) light_changed = true;

                if (light_changed and state.pbr_enabled) {
                    renderer.cardinal_renderer_set_lighting(state.renderer, &state.light);
                }
            }

            c.imgui_bridge_separator();

            if (c.imgui_bridge_collapsing_header("Material Override", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                _ = c.imgui_bridge_checkbox("Enable Material Override", &state.material_override_enabled);

                if (state.material_override_enabled) {
                    c.imgui_bridge_separator();
                    _ = c.imgui_bridge_color_edit3("Albedo Factor", &state.material_albedo, 0);
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

                if (c.imgui_bridge_combo("Mode", &current_item, &items, items.len, -1)) {
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
        c.imgui_bridge_end();
    }
}

fn draw_animation_panel() void {
    if (state.show_animation) {
        if (c.imgui_bridge_begin("Animation", &state.show_animation, 0)) {
            if (state.scene_loaded and state.combined_scene.animation_system != null) {
                const anim_sys_opaque = state.combined_scene.animation_system.?;
                const anim_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(anim_sys_opaque)));

                // Animation selection
                c.imgui_bridge_text("Animations (%d)", anim_sys.animation_count);
                c.imgui_bridge_separator();

                if (c.imgui_bridge_begin_child("##animation_list", 0, 120, true, 0)) {
                    var i: u32 = 0;
                    while (i < anim_sys.animation_count) : (i += 1) {
                        const anim = &anim_sys.animations.?[i];
                        const name = if (anim.name) |n| std.mem.span(n) else "Unnamed Animation";

                        const is_selected = (state.selected_animation == @as(i32, @intCast(i)));
                        if (c.imgui_bridge_selectable(name.ptr, is_selected, 0)) {
                            state.selected_animation = @as(i32, @intCast(i));
                            state.animation_time = 0.0; // Reset time
                        }

                        c.imgui_bridge_same_line(0, -1);
                        c.imgui_bridge_text_disabled("(%.2fs, %d channels)", anim.duration, anim.channel_count);
                    }
                    c.imgui_bridge_end_child();
                }

                c.imgui_bridge_separator();

                // Playback controls
                if (state.selected_animation >= 0 and state.selected_animation < anim_sys.animation_count) {
                    const current_anim = &anim_sys.animations.?[@intCast(state.selected_animation)];

                    c.imgui_bridge_text("Playback Controls");

                    if (state.animation_playing) {
                        if (c.imgui_bridge_button("Pause")) {
                            state.animation_playing = false;
                            _ = animation.cardinal_animation_pause(anim_sys, @intCast(state.selected_animation));
                        }
                    } else {
                        if (c.imgui_bridge_button("Play")) {
                            state.animation_playing = true;
                            _ = animation.cardinal_animation_play(anim_sys, @intCast(state.selected_animation), state.animation_looping, 1.0);
                        }
                    }

                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Stop")) {
                        state.animation_playing = false;
                        state.animation_time = 0.0;
                        _ = animation.cardinal_animation_stop(anim_sys, @intCast(state.selected_animation));
                    }

                    c.imgui_bridge_same_line(0, -1);
                    _ = c.imgui_bridge_checkbox("Loop", &state.animation_looping);

                    // Speed control
                    c.imgui_bridge_set_next_item_width(100);
                    if (c.imgui_bridge_slider_float("Speed", &state.animation_speed, 0.1, 3.0, "%.1fx")) {
                        _ = animation.cardinal_animation_set_speed(anim_sys, @intCast(state.selected_animation), state.animation_speed);
                    }

                    // Timeline
                    c.imgui_bridge_separator();
                    c.imgui_bridge_text("Timeline");

                    c.imgui_bridge_text("Time: %.2f / %.2f seconds", state.animation_time, current_anim.duration);

                    // Timeline scrubber
                    if (c.imgui_bridge_slider_float("##timeline", &state.animation_time, 0.0, current_anim.duration, "%.2fs")) {
                        if (state.animation_time < 0.0) state.animation_time = 0.0;
                        if (state.animation_time > current_anim.duration) {
                            if (state.animation_looping) {
                                state.animation_time = @mod(state.animation_time, current_anim.duration);
                            } else {
                                state.animation_time = current_anim.duration;
                                state.animation_playing = false;
                            }
                        }
                    }

                    c.imgui_bridge_separator();
                    c.imgui_bridge_text("Animation Info");
                    c.imgui_bridge_text("Name: %s", if (current_anim.name) |n| n else "Unnamed");
                    c.imgui_bridge_text("Duration: %.2f seconds", current_anim.duration);
                    c.imgui_bridge_text("Channels: %d", current_anim.channel_count);
                    c.imgui_bridge_text("Samplers: %d", current_anim.sampler_count);

                    if (c.imgui_bridge_collapsing_header("Channels", 0)) {
                        var i: u32 = 0;
                        while (i < current_anim.channel_count) : (i += 1) {
                            const channel = &current_anim.channels.?[i];
                            c.imgui_bridge_text("Channel %d: Node %d, Target %d", i, channel.target.node_index, @intFromEnum(channel.target.path));
                        }
                    }
                } else {
                    c.imgui_bridge_text_disabled("Select an animation to see controls");
                }
            } else {
                c.imgui_bridge_text("No animations");
                c.imgui_bridge_text_wrapped("Load a scene with animations to see animation controls.");
            }
        }
        c.imgui_bridge_end();
    }
}

const VkCommandBuffer = c.VkCommandBuffer;

fn ui_draw_callback(cmd: VkCommandBuffer) callconv(.c) void {
    c.imgui_bridge_impl_vulkan_render_draw_data(@ptrCast(cmd));
}

// Public API

pub fn init(win_ptr: *window.CardinalWindow, rnd_ptr: *types.CardinalRenderer) bool {
    if (initialized) {
        log.cardinal_log_warn("[EDITOR] Already initialized", .{});
        return true;
    }

    state = EditorState{
        .window = win_ptr,
        .renderer = rnd_ptr,
        .camera = .{
            .position = .{ .x = 0.0, .y = 0.0, .z = 2.0 },
            .target = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .up = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
            .fov = 65.0,
            .aspect = 16.0 / 9.0,
            .near_plane = 0.1,
            .far_plane = 100.0,
        },
        .light = .{
            .direction = .{ .x = -0.3, .y = -0.7, .z = -0.5 },
            .color = .{ .x = 1.0, .y = 1.0, .z = 0.95 },
            .intensity = 8.0,
            .ambient = .{ .x = 0.3, .y = 0.3, .z = 0.35 },
        },
    };

    if (!model_manager.cardinal_model_manager_init(&state.model_manager)) return false;

    const default_assets_dir = "C:/Users/admin/Documents/Cardinal/assets";
    state.assets.assets_dir = allocator.dupeZ(u8, default_assets_dir) catch return false;
    state.assets.current_dir = allocator.dupeZ(u8, default_assets_dir) catch return false;
    state.assets.search_filter = allocator.alloc(u8, 256) catch return false;
    @memset(state.assets.search_filter, 0);

    c.imgui_bridge_create_context();
    c.imgui_bridge_enable_docking(true);
    c.imgui_bridge_enable_keyboard(true);
    c.imgui_bridge_style_colors_dark();

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

    if (!c.imgui_bridge_impl_vulkan_init(&init_info)) return false;

    content_browser.scan_assets_dir(&state, allocator);

    renderer.cardinal_renderer_set_camera(rnd_ptr, &state.camera);
    renderer.cardinal_renderer_set_lighting(rnd_ptr, &state.light);
    renderer.cardinal_renderer_set_ui_callback(rnd_ptr, @ptrCast(&ui_draw_callback));

    initialized = true;
    return true;
}

pub fn on_device_loss(_: ?*anyopaque) callconv(.c) void {
    log.cardinal_log_warn("[EDITOR_LAYER] Device loss detected, shutting down ImGui", .{});

    // Always attempt to shutdown the Vulkan backend if we were initialized
    // We check if the context exists by checking if the descriptor pool was created (which happens during init)
    // Even if it's null, calling shutdown might be safer if we are unsure, but ImGui backend asserts if not initialized.
    // However, the "Already initialized" error comes from Init, not Shutdown.
    // So we must ensure Shutdown is called.

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
}

pub fn shutdown() void {
    c.imgui_bridge_impl_vulkan_shutdown();
    c.imgui_bridge_impl_glfw_shutdown();
    c.imgui_bridge_destroy_context();

    if (state.descriptor_pool != null) {
        const device = @as(c.VkDevice, @ptrCast(renderer.cardinal_renderer_internal_device(state.renderer)));
        c.vkDestroyDescriptorPool(device, state.descriptor_pool, null);
    }

    model_manager.cardinal_model_manager_destroy(&state.model_manager);

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

    if (c.imgui_bridge_begin("DockSpace", null, window_flags)) {
        c.imgui_bridge_pop_style_var(1);

        // DockSpace
        const dock_id = c.imgui_bridge_get_id("EditorDockSpace");
        const dock_flags = c.ImGuiDockNodeFlags_PassthruCentralNode;
        c.imgui_bridge_dock_space(dock_id, &zero_vec, dock_flags);

        // Main Menu Bar
        if (c.imgui_bridge_begin_main_menu_bar()) {
            if (c.imgui_bridge_begin_menu("File", true)) {
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
                if (c.imgui_bridge_menu_item("PBR Settings", null, state.show_pbr_settings, true)) state.show_pbr_settings = !state.show_pbr_settings;
                if (c.imgui_bridge_menu_item("Animation", null, state.show_animation, true)) state.show_animation = !state.show_animation;
                if (c.imgui_bridge_menu_item("Memory Stats", null, state.show_memory_stats, true)) state.show_memory_stats = !state.show_memory_stats;
                c.imgui_bridge_end_menu();
            }
            c.imgui_bridge_end_main_menu_bar();
        }

        // Panels
        scene_hierarchy.draw_scene_graph_panel(&state);
        content_browser.draw_asset_browser_panel(&state, allocator);
        inspector.draw_inspector_panel(&state);
        draw_pbr_settings_panel();
        draw_animation_panel();
        memory_stats.draw_memory_stats_panel(&state);

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
        if (c.imgui_bridge_begin("Status", null, 0)) {
            c.imgui_bridge_text("FPS: %.1f", 1.0 / dt);
            c.imgui_bridge_text("Status: %s", &state.status_msg);
            c.imgui_bridge_end();
        }
    }
    c.imgui_bridge_end(); // End DockSpace window
}

pub fn render() void {
    if (!initialized) return;
    c.imgui_bridge_render();
    // Render call is handled by callback
}

pub fn process_pending_uploads() void {
    if (state.scene_upload_pending and initialized) {
        log.cardinal_log_info("[EDITOR] Pending upload detected", .{});
        renderer.cardinal_renderer_wait_idle(state.renderer);
        renderer.cardinal_renderer_upload_scene(state.renderer, &state.pending_scene);

        state.combined_scene = state.pending_scene;
        state.scene_upload_pending = false;

        if (state.pbr_enabled) {
            renderer.cardinal_renderer_set_camera(state.renderer, &state.camera);
            renderer.cardinal_renderer_set_lighting(state.renderer, &state.light);
        }
    }
}
