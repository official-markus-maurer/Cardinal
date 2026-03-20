//! Renderer state and configuration types.
//!
//! Central renderer configuration and the monolithic `VulkanState` used by subsystems.
const c = @import("vulkan_c.zig").c;
const core = @import("vulkan_types_core.zig");
const sync = @import("vulkan_types_sync.zig");
const pipes = @import("vulkan_types_pipelines.zig");

/// Device-loss recovery state and callbacks.
pub const DeviceLossRecovery = extern struct {
    recovery_in_progress: bool,
    attempt_count: u32,
    max_attempts: u32,
    device_lost: bool,
    device_loss_callback: ?*const fn (?*anyopaque) callconv(.c) void,
    recovery_complete_callback: ?*const fn (?*anyopaque, bool) callconv(.c) void,
    callback_user_data: ?*anyopaque,
    window: ?*core.CardinalWindow,
};

/// Renderer configuration knobs that affect pipeline creation and frame behavior.
pub const RendererConfig = extern struct {
    pbr_clear_color: [4]f32 = .{ 0.05, 0.05, 0.08, 1.0 },
    pbr_ambient_color: [4]f32 = .{ 0.1, 0.1, 0.1, 100.0 },
    pbr_default_light_direction: [4]f32 = .{ -0.5, -1.0, -0.3, 0.0 },
    pbr_default_light_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },

    shadow_map_format: c.VkFormat = c.VK_FORMAT_D32_SFLOAT,
    shadow_cascade_count: u32 = 4,
    shadow_map_size: u32 = 4096,
    shadow_split_lambda: f32 = 0.95,
    shadow_near_clip: f32 = 0.1,
    shadow_far_clip: f32 = 1000.0,

    prefer_hdr: bool = false,

    present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR,

    shader_dir: [64]u8,
    pipeline_dir: [64]u8,
    texture_dir: [64]u8,
    model_dir: [64]u8,

    max_lights: u32 = 128,
    max_frames_in_flight: u32 = 3,
    timeline_max_ahead: u64 = 1000000,
    enable_async_compute: bool = true,
};

/// Central renderer state used by most Vulkan subsystems.
pub const VulkanState = extern struct {
    config: RendererConfig,
    context: core.VulkanContext,
    swapchain: core.VulkanSwapchain,
    commands: core.VulkanCommands,
    sync: sync.VulkanSyncManager,
    recovery: DeviceLossRecovery,
    allocator: core.VulkanAllocator,
    descriptor_manager: core.VulkanDescriptorManager,
    pipelines: pipes.VulkanPipelines,

    pending_cleanup_lists: ?[*]?[*]pipes.MeshShaderDrawData,
    pending_cleanup_counts: ?[*]u32,
    pending_cleanup_capacities: ?[*]u32,

    sync_manager: ?*sync.VulkanSyncManager,
    current_rendering_mode: core.CardinalRenderingMode,
    current_scene: ?*core.CardinalScene,
    scene_meshes: ?[*]pipes.GpuMesh,
    scene_mesh_count: u32,

    pending_scene_upload: ?*anyopaque,
    scene_upload_pending: bool,
    ui_record_callback: ?*const fn (c.VkCommandBuffer) callconv(.c) void,
    render_graph: ?*anyopaque,
    current_image_index: u32,

    material_system: ?*anyopaque,
    frame_allocator: ?*anyopaque,

    debug_grid_enabled: bool,

    current_scene_owned: bool,
};
