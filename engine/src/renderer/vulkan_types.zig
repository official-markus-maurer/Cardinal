const std = @import("std");
const builtin = @import("builtin");
const scene = @import("../assets/scene.zig");
const c = @import("vulkan_c.zig").c;
const window = @import("../core/window.zig");
const math = @import("../core/math.zig");

// Constants
pub const CARDINAL_MAX_SECONDARY_COMMAND_BUFFERS = 512;
pub const CARDINAL_MAX_MT_THREADS = 16;

// Forward declarations for external types
pub const CardinalWindow = window.CardinalWindow;
pub const CardinalRenderer = extern struct {
    _opaque: ?*anyopaque,
};
pub const CardinalScene = scene.CardinalScene;
pub const CardinalMesh = scene.CardinalMesh;
pub const CardinalVertex = scene.CardinalVertex;
pub const CardinalMaterial = scene.CardinalMaterial;
pub const CardinalSceneNode = scene.CardinalSceneNode;

pub const cardinal_mutex_t = ?*anyopaque;
pub const cardinal_cond_t = ?*anyopaque;
pub const cardinal_thread_id_t = std.Thread.Id;
pub const cardinal_thread_handle_t = std.Thread;

pub const CardinalRenderingMode = enum(c_int) {
    NORMAL = 0,
    MESH_SHADER = 1,
    DEBUG = 2,
    UV = 3,
    WIREFRAME = 4,
};

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

pub const CardinalResourceAccessType = enum(c_int) {
    CARDINAL_ACCESS_NONE = 0,
    CARDINAL_ACCESS_READ = 1,
    CARDINAL_ACCESS_WRITE = 2,
    CARDINAL_ACCESS_READ_WRITE = 3,
};

pub const CardinalCamera = extern struct {
    position: math.Vec3,
    target: math.Vec3,
    up: math.Vec3,
    fov: f32,
    aspect: f32,
    near_plane: f32,
    far_plane: f32,
};

pub const CardinalLight = extern struct {
    direction: math.Vec3,
    position: math.Vec3,
    color: math.Vec3,
    intensity: f32,
    ambient: math.Vec3,
    range: f32,
    type: i32, // 0=Directional, 1=Point, 2=Spot
};

pub const CardinalMTTaskType = enum(c_int) {
    CARDINAL_MT_TASK_COMMAND_RECORD = 0,
    CARDINAL_MT_TASK_TEXTURE_LOAD = 1,
    CARDINAL_MT_TASK_MESH_LOAD = 2,
};

pub const CardinalMTTask = extern struct {
    type: CardinalMTTaskType,
    data: ?*anyopaque,
    execute_func: ?*const fn (?*anyopaque) callconv(.c) void,
    callback_func: ?*const fn (?*anyopaque, bool) callconv(.c) void,
    success: bool,
    is_completed: bool,
    next: ?*CardinalMTTask,
};

pub const CardinalMTTaskQueue = extern struct {
    head: ?*CardinalMTTask,
    tail: ?*CardinalMTTask,
    task_count: u32,
    queue_mutex: cardinal_mutex_t,
    queue_condition: cardinal_cond_t,
};

pub const CardinalMTThreadPool = extern struct {
    threads: ?[*]cardinal_thread_handle_t,
    thread_count: u32,
    is_active: bool,
    queue: ?*CardinalMTTaskQueue,
};

pub const CardinalMTCommandManager = extern struct {
    vulkan_state: ?*VulkanState,
    thread_pools: ?[*]CardinalThreadCommandPool,
    is_initialized: bool,
    pool_mutex: cardinal_mutex_t,
    active_thread_count: u32,
};

pub const CardinalMTSubsystem = struct {
    pending_queue: CardinalMTTaskQueue,
    completed_queue: CardinalMTTaskQueue,
    command_manager: CardinalMTCommandManager,
    is_running: bool,
    worker_thread_count: u32,
    worker_threads: []?cardinal_thread_handle_t,
    subsystem_mutex: cardinal_mutex_t,
};

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

// PBR Types
pub const PBRTextureTransform = extern struct {
    offset: math.Vec2,
    scale: math.Vec2,
    rotation: f32,
};

pub const PBRUniformBufferObject = extern struct {
    model: [16]f32,
    view: [16]f32,
    proj: [16]f32,
    viewPos: [3]f32,
    debugFlags: f32,
};

pub const PBRLight = extern struct {
    lightDirection: [4]f32, // w = type (0=Directional, 1=Point, 2=Spot)
    lightColor: [4]f32, // w = intensity
    ambientColor: [4]f32, // w = range
    lightPosition: [4]f32, // xyz = position, w = unused
};

pub const MAX_LIGHTS = 128;

pub const PBRLightingBuffer = extern struct {
    count: u32,
    _padding: [3]u32,
    lights: [MAX_LIGHTS]PBRLight,
};

pub const PBRMaterialProperties = extern struct {
    albedoFactor: [4]f32, // vec4 in shader
    metallicFactor: f32,
    roughnessFactor: f32,
    emissiveFactor: [4]f32, // vec4 in shader (xyz + padding/roughness) - shader uses separate float for roughness but zig struct might pack it

    normalScale: f32,
    aoStrength: f32,
    albedoTextureIndex: u32,
    normalTextureIndex: u32,
    metallicRoughnessTextureIndex: u32,
    aoTextureIndex: u32,
    emissiveTextureIndex: u32,
    supportsDescriptorIndexing: u32,
};

pub const PBRPushConstants = extern struct {
    modelMatrix: math.Mat4,

    // Material data (offset 64)
    // vec4 albedoAndMetallic;
    albedoFactor: [3]f32,
    metallicFactor: f32,

    // vec4 emissiveAndRoughness;
    emissiveFactor: [3]f32,
    roughnessFactor: f32,

    normalScale: f32,
    aoStrength: f32,

    albedoTextureIndex: u32,
    normalTextureIndex: u32,
    metallicRoughnessTextureIndex: u32,
    aoTextureIndex: u32,
    emissiveTextureIndex: u32,

    flags: u32,
    alphaCutoff: f32,

    uvSetIndices: u32, // Packed UV indices (3 bits per texture)

    albedoTransform: PBRTextureTransform,
    _padding1: f32,

    normalTransform: PBRTextureTransform,
    _padding2: f32,

    metallicRoughnessTransform: PBRTextureTransform,
    _padding3: f32,

    aoTransform: PBRTextureTransform,
    _padding4: f32,

    emissiveTransform: PBRTextureTransform,
    _padding5: f32,
};

pub const MeshShaderUniformBuffer = extern struct {
    model: [16]f32,
    view: [16]f32,
    proj: [16]f32,
    materialIndex: u32,
    _padding: [3]u32,
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

// Resource IDs for RenderGraph
pub const RESOURCE_ID_BACKBUFFER: u64 = 1;
pub const RESOURCE_ID_DEPTHBUFFER: u64 = 2;

pub const VulkanDescriptorManager = extern struct {
    bindings: ?[*]const VulkanDescriptorBinding,
    bindingCount: u32,
    maxSets: u32,
    useDescriptorBuffers: bool,
    descriptorPool: c.VkDescriptorPool,
    device: c.VkDevice,
    descriptorSetLayout: c.VkDescriptorSetLayout,
    descriptorSetSize: c.VkDeviceSize,
    descriptorBufferSize: c.VkDeviceSize,
    descriptorBuffer: VulkanBuffer,
    allocator: ?*VulkanAllocator,

    // Additional fields found in usage
    descriptorSets: ?[*]c.VkDescriptorSet,
    descriptorSetCount: u32,
    bindingOffsets: ?[*]c.VkDeviceSize,
    bindingOffsetCount: u32,
    initialized: bool,
    vulkan_state: ?*VulkanState,
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
    descriptor_buffer_uniform_buffer_size: c.VkDeviceSize,
    descriptor_buffer_storage_buffer_size: c.VkDeviceSize,
    descriptor_buffer_combined_image_sampler_size: c.VkDeviceSize,

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

    graphics_queue: c.VkQueue,
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

pub const DeviceLossRecovery = extern struct {
    recovery_in_progress: bool,
    attempt_count: u32,
    max_attempts: u32,
    device_lost: bool,
    device_loss_callback: ?*const fn (?*anyopaque) callconv(.c) void,
    recovery_complete_callback: ?*const fn (?*anyopaque, bool) callconv(.c) void,
    callback_user_data: ?*anyopaque,
    window: ?*CardinalWindow,
};

pub const VulkanTimelineError = enum(c_int) {
    NONE = 0,
    TIMEOUT = 1,
    DEVICE_LOST = 2,
    OUT_OF_MEMORY = 3,
    INVALID_VALUE = 4,
    SEMAPHORE_INVALID = 5,
    UNKNOWN = 6,
};

pub const VulkanTimelineErrorInfo = extern struct {
    error_type: VulkanTimelineError,
    vulkan_result: c.VkResult,
    timeline_value: u64,
    timeout_ns: u64,
    error_message: [256]u8,
};

pub const TimelineValueStrategy = extern struct {
    base_value: u64,
    increment_step: u64,
    max_safe_value: u64,
    overflow_threshold: u64,
    auto_reset_enabled: bool,
};

pub const VulkanSyncManager = extern struct {
    device: c.VkDevice,
    graphics_queue: c.VkQueue,
    max_frames_in_flight: u32,
    current_frame: u32,
    image_acquired_semaphores: ?[*]c.VkSemaphore,
    render_finished_semaphores: ?[*]c.VkSemaphore,
    in_flight_fences: ?[*]c.VkFence,
    timeline_semaphore: c.VkSemaphore,
    initialized: bool,
    global_timeline_counter: u64,
    current_frame_value: u64,
    timeline_wait_count: u64,
    image_available_value: u64,
    render_complete_value: u64,
    timeline_signal_count: u64,
    value_strategy: TimelineValueStrategy,
};

pub const VulkanCommands = extern struct {
    pools: ?[*]c.VkCommandPool,
    buffers: ?[*]c.VkCommandBuffer,
    secondary_buffers: ?[*]c.VkCommandBuffer,
    current_buffer_index: u32,
};

// Texture Manager Types
pub const VulkanManagedTexture = extern struct {
    image: c.VkImage,
    view: c.VkImageView,
    memory: c.VkDeviceMemory,
    allocation: c.VmaAllocation,
    sampler: c.VkSampler,
    descriptor_set: c.VkDescriptorSet,
    width: u32,
    height: u32,
    channels: u32,
    format: c.VkFormat,
    mip_levels: u32,
    layer_count: u32,
    is_allocated: bool,
    isPlaceholder: bool,
    path: ?[*:0]u8,
    bindless_index: u32,
    generation: u32,
    is_hdr: bool,
    resource: ?*anyopaque, // ref_counting.CardinalRefCountedResource (void* to avoid circular dep)
    is_updating: bool,
};

pub const VulkanTextureManagerConfig = extern struct {
    device: c.VkDevice,
    allocator: *VulkanAllocator,
    commandPool: c.VkCommandPool,
    graphicsQueue: c.VkQueue,
    syncManager: ?*VulkanSyncManager,
    initialCapacity: u32,
    vulkan_state: ?*VulkanState,
};

pub const VulkanTextureManager = extern struct {
    device: c.VkDevice,
    physicalDevice: c.VkPhysicalDevice,
    allocator: ?*VulkanAllocator,
    commandPool: c.VkCommandPool,
    graphicsQueue: c.VkQueue,
    syncManager: ?*VulkanSyncManager,

    textures: ?[*]VulkanManagedTexture,
    textureCount: u32,
    textureCapacity: u32,

    defaultSampler: c.VkSampler,
    initialized: bool,

    vkQueueSubmit2: c.PFN_vkQueueSubmit2,

    manager_mutex: cardinal_mutex_t,
    hasPlaceholder: bool,
    bindless_pool: BindlessTexturePool,
    pending_updates: ?*anyopaque,
};

// Compute Pipeline Types
pub const ComputePipelineConfig = extern struct {
    compute_shader_path: ?[*:0]const u8,
    local_size_x: u32,
    local_size_y: u32,
    local_size_z: u32,
    push_constant_size: u32,
    push_constant_stages: c.VkShaderStageFlags,
    descriptor_set_count: u32,
    descriptor_layouts: ?[*]c.VkDescriptorSetLayout,
};

pub const ComputePipeline = extern struct {
    pipeline: c.VkPipeline,
    pipeline_layout: c.VkPipelineLayout,
    descriptor_layouts: ?[*]c.VkDescriptorSetLayout,
    descriptor_set_count: u32,
    push_constant_size: u32,
    push_constant_stages: c.VkShaderStageFlags,
    local_size_x: u32,
    local_size_y: u32,
    local_size_z: u32,
    initialized: bool,
};

pub const ComputeDispatchInfo = extern struct {
    descriptor_sets: ?[*]c.VkDescriptorSet,
    descriptor_set_count: u32,
    push_constants: ?*const anyopaque,
    push_constant_size: u32,
    group_count_x: u32,
    group_count_y: u32,
    group_count_z: u32,
};

pub const ComputeMemoryBarrier = extern struct {
    src_access_mask: c.VkAccessFlags,
    dst_access_mask: c.VkAccessFlags,
    src_stage_mask: c.VkPipelineStageFlags,
    dst_stage_mask: c.VkPipelineStageFlags,
};

// Bindless Texture Types
pub const BindlessTexture = extern struct {
    image: c.VkImage,
    image_view: c.VkImageView,
    memory: c.VkDeviceMemory,
    allocation: c.VmaAllocation,
    sampler: c.VkSampler,
    descriptor_index: u32,
    is_allocated: bool,
    format: c.VkFormat,
    extent: c.VkExtent3D,
    mip_levels: u32,
    owns_resources: bool,
};

pub const BindlessTextureCreateInfo = extern struct {
    format: c.VkFormat,
    extent: c.VkExtent3D,
    mip_levels: u32,
    samples: c.VkSampleCountFlagBits,
    usage: c.VkImageUsageFlags,
    custom_sampler: c.VkSampler,
};

pub const BindlessTexturePool = extern struct {
    device: c.VkDevice,
    physical_device: c.VkPhysicalDevice,
    allocator: *VulkanAllocator,

    textures: ?[*]BindlessTexture,
    max_textures: u32,
    allocated_count: u32,

    free_indices: ?[*]u32,
    free_count: u32,

    descriptor_pool: c.VkDescriptorPool,
    descriptor_layout: c.VkDescriptorSetLayout,
    descriptor_set: c.VkDescriptorSet,

    // Descriptor Buffer Support
    use_descriptor_buffer: bool,
    descriptor_buffer: VulkanBuffer,
    descriptor_set_size: c.VkDeviceSize,
    descriptor_offset: c.VkDeviceSize,
    descriptor_size: c.VkDeviceSize,
    descriptor_buffer_address: c.VkDeviceAddress,
    vkGetDescriptorEXT: c.PFN_vkGetDescriptorEXT,
    vkCmdBindDescriptorBuffersEXT: c.PFN_vkCmdBindDescriptorBuffersEXT,
    vkCmdSetDescriptorBufferOffsetsEXT: c.PFN_vkCmdSetDescriptorBufferOffsetsEXT,

    default_sampler: c.VkSampler,

    // Pending updates for flush
    pending_updates: ?[*]u32,
    pending_update_count: u32,
    needs_descriptor_update: bool,
};

// Mesh Shader Types
pub const MeshShaderPipelineConfig = extern struct {
    mesh_shader_path: ?[*:0]const u8,
    task_shader_path: ?[*:0]const u8,
    fragment_shader_path: ?[*:0]const u8, // Using 'fragment_' to match likely usage or just 'frag_'? Checked code: cfg.fragment_shader_path in vulkan_mesh_shader.zig:107
    max_vertices_per_meshlet: u32,
    max_primitives_per_meshlet: u32,

    polygon_mode: c.VkPolygonMode,
    cull_mode: c.VkCullModeFlags,
    front_face: c.VkFrontFace,
    depth_test_enable: bool,
    depth_write_enable: bool,
    depth_compare_op: c.VkCompareOp,
    blend_enable: bool,
    src_color_blend_factor: c.VkBlendFactor,
    dst_color_blend_factor: c.VkBlendFactor,
    color_blend_op: c.VkBlendOp,
    topology: c.VkPrimitiveTopology,
};

pub const MeshShaderPipeline = extern struct {
    pipeline: c.VkPipeline,
    pipeline_layout: c.VkPipelineLayout,
    set0_manager: ?*VulkanDescriptorManager,
    set1_manager: ?*VulkanDescriptorManager,
    global_descriptor_set: c.VkDescriptorSet,
    has_task_shader: bool,
    max_meshlets_per_workgroup: u32,
    max_vertices_per_meshlet: u32,
    initialized: bool,
    defaultMaterialBuffer: VulkanBuffer,
};

pub const MeshShaderDrawData = extern struct {
    descriptor_set: c.VkDescriptorSet,
    vertex_buffer: c.VkBuffer,
    vertex_memory: c.VkDeviceMemory,
    vertex_allocation: c.VmaAllocation,
    vertex_buffer_size: c.VkDeviceSize,
    meshlet_buffer: c.VkBuffer,
    meshlet_memory: c.VkDeviceMemory,
    meshlet_allocation: c.VmaAllocation,
    meshlet_buffer_size: c.VkDeviceSize,
    primitive_buffer: c.VkBuffer,
    primitive_memory: c.VkDeviceMemory,
    primitive_allocation: c.VmaAllocation,
    primitive_buffer_size: c.VkDeviceSize,
    draw_command_buffer: c.VkBuffer,
    draw_command_memory: c.VkDeviceMemory,
    draw_command_allocation: c.VmaAllocation,
    draw_command_buffer_size: c.VkDeviceSize,
    uniform_buffer: c.VkBuffer,
    uniform_memory: c.VkDeviceMemory,
    uniform_allocation: c.VmaAllocation,
    uniform_buffer_size: c.VkDeviceSize,
    meshlet_count: u32,
    uniform_mapped: ?*anyopaque,
    draw_command_count: u32,
};

pub const GpuMeshlet = extern struct {
    vertex_offset: u32,
    vertex_count: u32,
    primitive_offset: u32,
    primitive_count: u32,
};

pub const GpuMesh = extern struct {
    vertex_offset: u32,
    vertex_count: u32,
    index_offset: u32,
    index_count: u32,
    vtx_stride: u32,
    material_index: u32,
    transform: [16]f32,
    bounding_box_min: [3]f32,
    bounding_box_max: [3]f32,
    vbuf: c.VkBuffer,
    ibuf: c.VkBuffer,
    vmem: c.VkDeviceMemory,
    imem: c.VkDeviceMemory,
    v_allocation: c.VmaAllocation,
    i_allocation: c.VmaAllocation,
};

pub const SkyboxPipeline = extern struct {
    pipeline: c.VkPipeline,
    pipelineLayout: c.VkPipelineLayout,
    descriptorManager: ?*VulkanDescriptorManager,
    descriptorSet: c.VkDescriptorSet,
    texture: VulkanManagedTexture,
    initialized: bool,
};

pub const VulkanPipelines = extern struct {
    mesh_shader_pipeline: MeshShaderPipeline,
    simple_descriptor_manager: ?*VulkanDescriptorManager,
    pbr_pipeline: VulkanPBRPipeline,
    skybox_pipeline: SkyboxPipeline,
    use_pbr_pipeline: bool,
    use_skybox_pipeline: bool,

    use_mesh_shader_pipeline: bool,
    compute_shader_initialized: bool,
    simple_uniform_buffer: c.VkBuffer,
    simple_uniform_buffer_memory: c.VkDeviceMemory,
    simple_uniform_buffer_allocation: c.VmaAllocation,
    simple_descriptor_set: c.VkDescriptorSet,
    uv_pipeline: c.VkPipeline,
    uv_pipeline_layout: c.VkPipelineLayout,
    simple_uniform_buffer_mapped: ?*anyopaque,

    wireframe_pipeline: c.VkPipeline,
    wireframe_pipeline_layout: c.VkPipelineLayout,

    compute_descriptor_pool: c.VkDescriptorPool,
    compute_command_pool: c.VkCommandPool,
    compute_command_buffer: c.VkCommandBuffer,
};

pub const VulkanPBRPipeline = extern struct {
    pipeline: c.VkPipeline,
    pipelineLayout: c.VkPipelineLayout,
    descriptorManager: ?*VulkanDescriptorManager,
    textureManager: ?*VulkanTextureManager,

    // Buffers
    uniformBuffer: c.VkBuffer,
    uniformBufferMemory: c.VkDeviceMemory,
    uniformBufferAllocation: c.VmaAllocation,
    uniformBufferMapped: ?*anyopaque,

    lightingBuffer: c.VkBuffer,
    lightingBufferMemory: c.VkDeviceMemory,
    lightingBufferAllocation: c.VmaAllocation,
    lightingBufferMapped: ?*anyopaque,

    // Shadow Mapping
    shadowPipeline: c.VkPipeline,
    shadowAlphaPipeline: c.VkPipeline,
    shadowPipelineLayout: c.VkPipelineLayout,
    shadowDescriptorManager: ?*VulkanDescriptorManager,
    shadowDescriptorSet: c.VkDescriptorSet,
    shadowMapImage: c.VkImage,
    shadowMapMemory: c.VkDeviceMemory,
    shadowMapAllocation: c.VmaAllocation,
    shadowMapView: c.VkImageView,
    shadowCascadeViews: [4]c.VkImageView, // SHADOW_CASCADE_COUNT
    shadowMapSampler: c.VkSampler,
    shadowUBO: c.VkBuffer,
    shadowUBOMemory: c.VkDeviceMemory,
    shadowUBOAllocation: c.VmaAllocation,
    shadowUBOMapped: ?*anyopaque,

    // Bone Matrices
    boneMatricesBuffer: c.VkBuffer,
    boneMatricesBufferMemory: c.VkDeviceMemory,
    boneMatricesBufferAllocation: c.VmaAllocation,
    boneMatricesBufferMapped: ?*anyopaque,
    maxBones: u32,

    // Common
    vertexBuffer: c.VkBuffer,
    indexBuffer: c.VkBuffer,
    vertexBufferMemory: c.VkDeviceMemory,
    indexBufferMemory: c.VkDeviceMemory,
    vertexBufferAllocation: c.VmaAllocation,
    indexBufferAllocation: c.VmaAllocation,

    totalIndexCount: u32,
    initialized: bool,
    supportsDescriptorIndexing: bool,
    pipelineBlend: c.VkPipeline,

    debug_flags: f32,
};

// Main State
pub const VulkanState = extern struct {
    context: VulkanContext,
    swapchain: VulkanSwapchain,
    commands: VulkanCommands,
    sync: VulkanSyncManager,
    recovery: DeviceLossRecovery,
    allocator: VulkanAllocator,
    descriptor_manager: VulkanDescriptorManager,
    pipelines: VulkanPipelines,

    pending_cleanup_lists: ?[*]?[*]MeshShaderDrawData,
    pending_cleanup_counts: ?[*]u32,
    pending_cleanup_capacities: ?[*]u32,

    sync_manager: ?*VulkanSyncManager,
    current_rendering_mode: CardinalRenderingMode,
    current_scene: ?*CardinalScene,
    scene_meshes: ?[*]GpuMesh,
    scene_mesh_count: u32,

    pending_scene_upload: ?*anyopaque,
    scene_upload_pending: bool,
    ui_record_callback: ?*const fn (c.VkCommandBuffer) callconv(.c) void,
    render_graph: ?*anyopaque,
    current_image_index: u32,

    // Material System
    material_system: ?*anyopaque, // Pointer to MaterialSystem (opaque to avoid circular deps)

    // Frame Allocator
    frame_allocator: ?*anyopaque, // Pointer to StackAllocator
};

// Secondary Command Context (from texture manager usage)
pub const CardinalSecondaryCommandContext = extern struct {
    command_buffer: c.VkCommandBuffer,
    is_recording: bool,
    thread_index: u32,
    inheritance: c.VkCommandBufferInheritanceInfo,
};

pub const CardinalThreadCommandPool = extern struct {
    primary_pool: c.VkCommandPool,
    secondary_pool: c.VkCommandPool,
    secondary_buffers: ?[*]c.VkCommandBuffer,
    secondary_buffer_count: u32,
    next_secondary_index: u32,
    is_active: bool,
    thread_id: cardinal_thread_id_t,
};
