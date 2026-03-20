//! Renderer core shared types.
//!
//! C-ABI-friendly enums and structs used across renderer subsystems.
const std = @import("std");
const scene = @import("../assets/scene.zig");
const c = @import("vulkan_c.zig").c;
const window = @import("../core/window.zig");
const math = @import("../core/math.zig");

/// Global renderer limits.
pub const CARDINAL_MAX_SECONDARY_COMMAND_BUFFERS = 512;
pub const CARDINAL_MAX_MT_THREADS = 16;
pub const MAX_SHADOW_CASCADES = 8;
pub const MAX_FRAMES_IN_FLIGHT = 3;

/// Window type used by renderer-facing APIs.
pub const CardinalWindow = window.CardinalWindow;
/// Opaque renderer handle used by the C ABI.
pub const CardinalRenderer = extern struct {
    _opaque: ?*anyopaque,
};
pub const CardinalScene = scene.CardinalScene;
pub const CardinalMesh = scene.CardinalMesh;
pub const CardinalVertex = scene.CardinalVertex;
pub const CardinalMaterial = scene.CardinalMaterial;
pub const CardinalSceneNode = scene.CardinalSceneNode;

/// Opaque synchronization primitives used by the engine abstraction layer.
pub const cardinal_mutex_t = ?*anyopaque;
pub const cardinal_cond_t = ?*anyopaque;
pub const cardinal_thread_id_t = std.Thread.Id;
pub const cardinal_thread_handle_t = std.Thread;

/// High-level renderer debug/feature modes.
pub const CardinalRenderingMode = enum(c_int) {
    NORMAL = 0,
    MESH_SHADER = 1,
    DEBUG = 2,
    UV = 3,
    WIREFRAME = 4,
};

/// Resource categories used by renderer diagnostics and validation.
pub const CardinalResourceType = enum(c_int) {
    TEXTURE = 0,
    MESH = 1,
    MATERIAL = 2,
    SHADER = 3,
    PIPELINE = 4,
    DESCRIPTOR_SET = 5,
    BUFFER = 6,
    CARDINAL_RESOURCE_BUFFER = 7,
    CARDINAL_RESOURCE_IMAGE = 8,
};

/// Declares how a resource is accessed for synchronization/validation.
pub const CardinalResourceAccessType = enum(c_int) {
    CARDINAL_ACCESS_NONE = 0,
    CARDINAL_ACCESS_READ = 1,
    CARDINAL_ACCESS_WRITE = 2,
    CARDINAL_ACCESS_READ_WRITE = 3,
};

/// Minimal camera parameters used by renderer interfaces.
pub const CardinalCamera = extern struct {
    position: math.Vec3,
    target: math.Vec3,
    up: math.Vec3,
    fov: f32,
    aspect: f32,
    near_plane: f32,
    far_plane: f32,
};

/// Light parameters passed through renderer interfaces.
pub const CardinalLight = extern struct {
    direction: math.Vec3,
    position: math.Vec3,
    color: math.Vec3,
    intensity: f32,
    ambient: math.Vec3,
    range: f32,
    inner_cone: f32,
    outer_cone: f32,
    type: i32,
};

/// One validation record describing a single resource access.
pub const CardinalResourceAccess = extern struct {
    resource_id: u64,
    resource_type: CardinalResourceType,
    access_type: CardinalResourceAccessType,
    stage_mask: c.VkPipelineStageFlags2,
    access_mask: c.VkAccessFlags2,
    thread_id: u32,
    timestamp: u64,
    command_buffer: c.VkCommandBuffer,
};

pub const CardinalBarrierValidationContext = extern struct {
    resource_accesses: [*c]CardinalResourceAccess,
    access_count: u32,
    max_accesses: u32,
    validation_enabled: bool,
    strict_mode: bool,
};

pub const ValidationStats = extern struct {
    total_accesses: u32,
    validation_errors: u32,
    race_conditions: u32,
    total_messages: u32,
    error_count: u32,
    warning_count: u32,
    info_count: u32,
    validation_count: u32,
    performance_count: u32,
    general_count: u32,
    filtered_count: u32,
};

pub const VkQueueFamilyOwnershipTransferInfo = extern struct {
    src_stage_mask: c.VkPipelineStageFlags2,
    dst_stage_mask: c.VkPipelineStageFlags2,
    src_access_mask: c.VkAccessFlags2,
    dst_access_mask: c.VkAccessFlags2,
    src_queue_family: u32,
    dst_queue_family: u32,
    use_maintenance8_enhancement: bool,
};

pub const VulkanAllocator = extern struct {
    handle: c.VmaAllocator,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
};

pub const VulkanBuffer = extern struct {
    handle: c.VkBuffer,
    memory: c.VkDeviceMemory,
    allocation: c.VmaAllocation,
    size: c.VkDeviceSize,
    mapped: ?*anyopaque,
    usage: c.VkBufferUsageFlags,
    properties: c.VkMemoryPropertyFlags,
};

pub const VulkanDescriptorBinding = extern struct {
    binding: u32,
    descriptorType: c.VkDescriptorType,
    descriptorCount: u32,
    stageFlags: c.VkShaderStageFlags,
    pImmutableSamplers: ?[*]const c.VkSampler,
};

pub const VulkanBufferAlloc = extern struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    allocation: c.VmaAllocation,
    mapped_data: ?*anyopaque,
    size: c.VkDeviceSize,
    alignment: c.VkDeviceSize,
    usage: c.VkBufferUsageFlags,
};

pub const RenderGraph = @import("render_graph.zig").RenderGraph;

pub const RESOURCE_ID_BACKBUFFER: u64 = 1;
pub const RESOURCE_ID_DEPTHBUFFER: u64 = 2;
pub const RESOURCE_ID_HDR_COLOR: u64 = 3;
pub const RESOURCE_ID_SSAO_RAW: u64 = 4;
pub const RESOURCE_ID_SSAO_BLURRED: u64 = 5;
pub const RESOURCE_ID_BLOOM: u64 = 6;
pub const RESOURCE_ID_SHADOW_MAP: u64 = 7;

pub const VulkanDescriptorManager = extern struct {
    bindings: ?[*]const VulkanDescriptorBinding,
    bindingCount: u32,
    maxSets: u32,
    useDescriptorBuffers: bool,
    device: c.VkDevice,
    descriptorSetLayout: c.VkDescriptorSetLayout,
    descriptorSetSize: c.VkDeviceSize,
    descriptorBufferSize: c.VkDeviceSize,
    descriptorBuffer: VulkanBuffer,
    allocator: ?*VulkanAllocator,

    descriptorSets: ?[*]c.VkDescriptorSet,
    descriptorSetCount: u32,
    bindingOffsets: ?[*]c.VkDeviceSize,
    bindingOffsetCount: u32,
    initialized: bool,
    vulkan_state: ?*anyopaque,
    freeIndices: ?[*]u32,
    freeCount: u32,
    freeCapacity: u32,
};

pub const DescriptorBufferCreateInfo = extern struct {
    device: c.VkDevice,
    allocator: *VulkanAllocator,
    layout: c.VkDescriptorSetLayout,
    max_sets: u32,
};

pub const DescriptorBufferManager = extern struct {
    device: c.VkDevice,
    allocator: *VulkanAllocator,
    layout: c.VkDescriptorSetLayout,
    layout_size: c.VkDeviceSize,
    buffer_alignment: c.VkDeviceSize,
    buffer_alloc: VulkanBufferAlloc,
    binding_offsets: ?[*]c.VkDeviceSize,
    binding_count: u32,
    needs_update: bool,
};

pub const VulkanContext = extern struct {
    instance: c.VkInstance,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    graphics_queue_family: u32,
    compute_queue_family: u32,
    descriptor_buffer_uniform_buffer_size: c.VkDeviceSize,
    descriptor_buffer_storage_buffer_size: c.VkDeviceSize,
    descriptor_buffer_combined_image_sampler_size: c.VkDeviceSize,
    descriptor_buffer_storage_image_size: c.VkDeviceSize,
    descriptor_buffer_sampled_image_size: c.VkDeviceSize,
    descriptor_buffer_sampler_size: c.VkDeviceSize,

    vkGetDescriptorSetLayoutSizeEXT: c.PFN_vkGetDescriptorSetLayoutSizeEXT,
    vkGetDescriptorSetLayoutBindingOffsetEXT: c.PFN_vkGetDescriptorSetLayoutBindingOffsetEXT,
    vkGetBufferDeviceAddress: c.PFN_vkGetBufferDeviceAddress,
    vkGetDescriptorEXT: c.PFN_vkGetDescriptorEXT,
    vkCmdBindDescriptorBuffersEXT: c.PFN_vkCmdBindDescriptorBuffersEXT,
    vkCmdSetDescriptorBufferOffsetsEXT: c.PFN_vkCmdSetDescriptorBufferOffsetsEXT,
    vkCmdBindDescriptorBufferEmbeddedSamplersEXT: c.PFN_vkCmdBindDescriptorBufferEmbeddedSamplersEXT,
    vkGetBufferOpaqueCaptureDescriptorDataEXT: c.PFN_vkGetBufferOpaqueCaptureDescriptorDataEXT,
    vkGetImageOpaqueCaptureDescriptorDataEXT: c.PFN_vkGetImageOpaqueCaptureDescriptorDataEXT,
    vkGetImageViewOpaqueCaptureDescriptorDataEXT: c.PFN_vkGetImageViewOpaqueCaptureDescriptorDataEXT,
    vkGetSamplerOpaqueCaptureDescriptorDataEXT: c.PFN_vkGetSamplerOpaqueCaptureDescriptorDataEXT,
    vkGetSemaphoreCounterValue: c.PFN_vkGetSemaphoreCounterValue,

    supports_descriptor_indexing: bool,
    debug_messenger: c.VkDebugUtilsMessengerEXT,
    present_queue: c.VkQueue,
    graphics_queue: c.VkQueue,
    compute_queue: c.VkQueue,
    vkCmdBeginRendering: c.PFN_vkCmdBeginRendering,
    vkCmdEndRendering: c.PFN_vkCmdEndRendering,
    vkWaitSemaphores: c.PFN_vkWaitSemaphores,

    vkGetDeviceBufferMemoryRequirements: c.PFN_vkGetDeviceBufferMemoryRequirements,
    vkGetDeviceImageMemoryRequirements: c.PFN_vkGetDeviceImageMemoryRequirements,
    vkGetDeviceBufferMemoryRequirementsKHR: c.PFN_vkGetDeviceBufferMemoryRequirementsKHR,
    vkGetDeviceImageMemoryRequirementsKHR: c.PFN_vkGetDeviceImageMemoryRequirementsKHR,

    supports_maintenance8: bool,
    supports_descriptor_buffer: bool,
    descriptor_buffer_extension_available: bool,
    supports_shader_quad_control: bool,
    supports_shader_maximal_reconvergence: bool,
    supports_buffer_device_address: bool,
    supports_mesh_shader: bool,
    supports_dynamic_rendering: bool,
    supports_vulkan_12_features: bool,
    supports_vulkan_13_features: bool,
    supports_vulkan_14_features: bool,
    supports_maintenance4: bool,

    surface: c.VkSurfaceKHR,
    present_queue_family: u32,

    vkQueueSubmit2: c.PFN_vkQueueSubmit2,
    vkCmdPipelineBarrier2: c.PFN_vkCmdPipelineBarrier2,
    vkSignalSemaphore: c.PFN_vkSignalSemaphore,
};

pub const VulkanSwapchain = extern struct {
    handle: c.VkSwapchainKHR,
    images: ?[*]c.VkImage,
    image_views: ?[*]c.VkImageView,
    image_count: u32,
    extent: c.VkExtent2D,
    format: c.VkFormat,
    image_layout_initialized: ?[*]bool,
    image_layouts: ?[*]c.VkImageLayout,
    image_stage_masks: ?[*]c.VkPipelineStageFlags2,
    image_access_masks: ?[*]c.VkAccessFlags2,

    image_present_semaphores: ?[*]c.VkSemaphore,

    headless_mode: bool,
    skip_present: bool,
    depth_format: c.VkFormat,
    recreation_pending: bool,
    window_resize_pending: bool,
    frame_pacing_enabled: bool,
    last_recreation_time: u64,
    depth_image_view: c.VkImageView,

    depth_image: c.VkImage,
    depth_image_memory: c.VkDeviceMemory,
    depth_image_allocation: c.VmaAllocation,
    pending_width: u32,
    pending_height: u32,
    consecutive_recreation_failures: u32,
    recreation_count: u32,
    depth_layout_initialized: bool,
};

pub const VulkanCommands = extern struct {
    pools: ?[*]c.VkCommandPool,
    transient_pools: ?[*]c.VkCommandPool,
    compute_transient_pools: ?[*]c.VkCommandPool,
    buffers: ?[*]c.VkCommandBuffer,
    alternate_primary_buffers: ?[*]c.VkCommandBuffer,
    compute_primary_buffers: ?[*]c.VkCommandBuffer,
    current_buffer_index: u32,
    scene_secondary_buffers: ?[*]c.VkCommandBuffer,
};
