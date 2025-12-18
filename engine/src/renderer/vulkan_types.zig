const std = @import("std");
const builtin = @import("builtin");
const scene = @import("../assets/scene.zig");
const c = @import("vulkan_c.zig").c;
const window = @import("../core/window.zig");


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

pub const CardinalCamera = extern struct {
    position: [3]f32,
    target: [3]f32,
    up: [3]f32,
    fov: f32,
    aspect: f32,
    near_plane: f32,
    far_plane: f32,
};

pub const CardinalLight = extern struct {
    direction: [3]f32,
    color: [3]f32,
    intensity: f32,
    ambient: [3]f32,
};

pub const ValidationStats = extern struct {
    total_messages: u32,
    error_count: u32,
    warning_count: u32,
    info_count: u32,
    performance_count: u32,
    validation_count: u32,
    general_count: u32,
    filtered_count: u32,
};

pub const CardinalResourceAccessType = enum(c_int) {
    CARDINAL_ACCESS_READ = 0,
    CARDINAL_ACCESS_WRITE = 1,
    CARDINAL_ACCESS_READ_WRITE = 2,
};

pub const CardinalResourceType = enum(c_int) {
    CARDINAL_RESOURCE_BUFFER = 0,
    CARDINAL_RESOURCE_IMAGE = 1,
    CARDINAL_RESOURCE_DESCRIPTOR_SET = 2,
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

pub const PBRTextureTransform = extern struct {
    offset: [2]f32,
    scale: [2]f32,
    rotation: f32,
};

pub const PBRUniformBufferObject = extern struct {
    model: [16]f32,
    view: [16]f32,
    proj: [16]f32,
    viewPos: [3]f32,
    _padding1: f32,
};

pub const PBRLightingData = extern struct {
    lightDirection: [3]f32,
    _padding1: f32,
    lightColor: [3]f32,
    lightIntensity: f32,
    ambientColor: [3]f32,
    _padding2: f32,
};

pub const PBRPushConstants = extern struct {
    modelMatrix: [16]f32,

    albedoFactor: [3]f32,
    metallicFactor: f32,

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
    _pad3: u32,

    albedoTransform: scene.CardinalTextureTransform,
    _padding1: f32,
    normalTransform: scene.CardinalTextureTransform,
    _padding2: f32,
    metallicRoughnessTransform: scene.CardinalTextureTransform,
    _padding3: f32,
    aoTransform: scene.CardinalTextureTransform,
    _padding4: f32,
    emissiveTransform: scene.CardinalTextureTransform,
};

pub const DescriptorBufferCreateInfo = extern struct {
    device: c.VkDevice,
    allocator: *VulkanAllocator,
    layout: c.VkDescriptorSetLayout,
    max_sets: u32,
};

pub const DescriptorBufferAllocation = extern struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: c.VkDeviceSize,
    alignment: c.VkDeviceSize,
    mapped_data: ?*anyopaque,
    usage: c.VkBufferUsageFlags,
};

pub const DescriptorBufferManager = extern struct {
    device: c.VkDevice,
    allocator: *VulkanAllocator,
    layout: c.VkDescriptorSetLayout,
    layout_size: c.VkDeviceSize,
    buffer_alignment: c.VkDeviceSize,
    buffer_alloc: DescriptorBufferAllocation,
    binding_offsets: ?[*]c.VkDeviceSize,
    binding_count: u32,
    needs_update: bool,
};

pub const PBRMaterialProperties = extern struct {
    albedoFactor: [3]f32,
    metallicFactor: f32,
    emissiveFactor: [3]f32,
    roughnessFactor: f32,
    normalScale: f32,
    aoStrength: f32,
    albedoTextureIndex: u32,
    normalTextureIndex: u32,
    metallicRoughnessTextureIndex: u32,
    aoTextureIndex: u32,
    emissiveTextureIndex: u32,
    supportsDescriptorIndexing: u32,
};

pub const VulkanAllocator = extern struct {
    device: c.VkDevice,
    physical_device: c.VkPhysicalDevice,
    // Function pointers - maintenance4 (required)
    fpGetDeviceBufferMemReq: c.PFN_vkGetDeviceBufferMemoryRequirements,
    fpGetDeviceImageMemReq: c.PFN_vkGetDeviceImageMemoryRequirements,
    fpGetBufferDeviceAddress: c.PFN_vkGetBufferDeviceAddress,
    // Function pointers - maintenance8
    fpGetDeviceBufferMemReqKHR: c.PFN_vkGetDeviceBufferMemoryRequirementsKHR,
    fpGetDeviceImageMemReqKHR: c.PFN_vkGetDeviceImageMemoryRequirementsKHR,
    supports_maintenance8: bool,
    // Stats
    total_device_mem_allocated: u64,
    total_device_mem_freed: u64,
    // Thread safety (using opaque pointer for mutex to avoid including platform headers)
    allocation_mutex: ?*anyopaque, 
};

//
// VulkanBuffer
//
pub const VulkanBuffer = extern struct {
    handle: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: c.VkDeviceSize,
    mapped: ?*anyopaque,
    usage: c.VkBufferUsageFlags,
    properties: c.VkMemoryPropertyFlags,
};

//
// VulkanContext
//
pub const VulkanContext = extern struct {
    instance: c.VkInstance,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    graphics_queue: c.VkQueue,
    present_queue: c.VkQueue,
    graphics_queue_family: u32,
    present_queue_family: u32,
    surface: c.VkSurfaceKHR,
    debug_messenger: c.VkDebugUtilsMessengerEXT,

    // Feature flags
    supports_dynamic_rendering: bool,
    supports_vulkan_12_features: bool,
    supports_vulkan_13_features: bool,
    supports_vulkan_14_features: bool,
    supports_maintenance4: bool,
    supports_maintenance8: bool,
    supports_mesh_shader: bool,
    supports_descriptor_indexing: bool,
    supports_buffer_device_address: bool,
    supports_descriptor_buffer: bool,
    supports_shader_quad_control: bool,
    supports_shader_maximal_reconvergence: bool,

    // Function pointers
    vkCmdBeginRendering: c.PFN_vkCmdBeginRendering,
    vkCmdEndRendering: c.PFN_vkCmdEndRendering,
    vkCmdPipelineBarrier2: c.PFN_vkCmdPipelineBarrier2,
    vkQueueSubmit2: c.PFN_vkQueueSubmit2,
    vkWaitSemaphores: c.PFN_vkWaitSemaphores,
    vkSignalSemaphore: c.PFN_vkSignalSemaphore,
    vkGetSemaphoreCounterValue: c.PFN_vkGetSemaphoreCounterValue,
    vkGetDeviceBufferMemoryRequirements: c.PFN_vkGetDeviceBufferMemoryRequirements,
    vkGetDeviceImageMemoryRequirements: c.PFN_vkGetDeviceImageMemoryRequirements,
    vkGetDeviceBufferMemoryRequirementsKHR: c.PFN_vkGetDeviceBufferMemoryRequirementsKHR,
    vkGetDeviceImageMemoryRequirementsKHR: c.PFN_vkGetDeviceImageMemoryRequirementsKHR,
    vkGetBufferDeviceAddress: c.PFN_vkGetBufferDeviceAddress,

    // Descriptor buffer extension function pointers
    vkGetDescriptorSetLayoutSizeEXT: c.PFN_vkGetDescriptorSetLayoutSizeEXT,
    vkGetDescriptorSetLayoutBindingOffsetEXT: c.PFN_vkGetDescriptorSetLayoutBindingOffsetEXT,
    vkGetDescriptorEXT: c.PFN_vkGetDescriptorEXT,
    vkCmdBindDescriptorBuffersEXT: c.PFN_vkCmdBindDescriptorBuffersEXT,
    vkCmdSetDescriptorBufferOffsetsEXT: c.PFN_vkCmdSetDescriptorBufferOffsetsEXT,
    vkCmdBindDescriptorBufferEmbeddedSamplersEXT: c.PFN_vkCmdBindDescriptorBufferEmbeddedSamplersEXT,
    vkGetBufferOpaqueCaptureDescriptorDataEXT: c.PFN_vkGetBufferOpaqueCaptureDescriptorDataEXT,
    vkGetImageOpaqueCaptureDescriptorDataEXT: c.PFN_vkGetImageOpaqueCaptureDescriptorDataEXT,
    vkGetImageViewOpaqueCaptureDescriptorDataEXT: c.PFN_vkGetImageViewOpaqueCaptureDescriptorDataEXT,
    vkGetSamplerOpaqueCaptureDescriptorDataEXT: c.PFN_vkGetSamplerOpaqueCaptureDescriptorDataEXT,

    // Descriptor buffer properties
    descriptor_buffer_extension_available: bool,
    descriptor_buffer_uniform_buffer_size: c.VkDeviceSize,
    descriptor_buffer_combined_image_sampler_size: c.VkDeviceSize,
};

//
// VulkanSwapchain
//
pub const VulkanSwapchain = extern struct {
    handle: c.VkSwapchainKHR,
    format: c.VkFormat,
    extent: c.VkExtent2D,
    images: ?[*]c.VkImage,
    image_views: ?[*]c.VkImageView,
    image_count: u32,

    // Depth resources
    depth_format: c.VkFormat,
    depth_image: c.VkImage,
    depth_image_memory: c.VkDeviceMemory,
    depth_image_view: c.VkImageView,
    depth_layout_initialized: bool,
    image_layout_initialized: ?[*]bool,

    // Optimization state
    recreation_pending: bool,
    last_recreation_time: u64,
    recreation_count: u32,
    consecutive_recreation_failures: u32,
    frame_pacing_enabled: bool,
    skip_present: bool,
    headless_mode: bool,

    // Resize state
    window_resize_pending: bool,
    pending_width: u32,
    pending_height: u32,
};

//
// Bindless Texture
//
pub const BindlessTexture = extern struct {
    image: c.VkImage,
    image_view: c.VkImageView,
    memory: c.VkDeviceMemory,
    sampler: c.VkSampler,
    descriptor_index: u32,
    is_allocated: bool,
    format: c.VkFormat,
    extent: c.VkExtent3D,
    mip_levels: u32,
};

pub const BindlessTexturePool = extern struct {
    device: c.VkDevice,
    physical_device: c.VkPhysicalDevice,
    allocator: *VulkanAllocator,
    descriptor_layout: c.VkDescriptorSetLayout,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_set: c.VkDescriptorSet,
    textures: ?[*]BindlessTexture,
    max_textures: u32,
    allocated_count: u32,
    free_indices: ?[*]u32,
    free_count: u32,
    default_sampler: c.VkSampler,
    needs_descriptor_update: bool,
    pending_updates: ?[*]u32,
    pending_update_count: u32,
};

pub const BindlessTextureCreateInfo = extern struct {
    extent: c.VkExtent3D,
    format: c.VkFormat,
    mip_levels: u32,
    usage: c.VkImageUsageFlags,
    samples: c.VkSampleCountFlagBits,
    custom_sampler: c.VkSampler,
    initial_data: ?*const anyopaque,
    data_size: c.VkDeviceSize,
};

//
// Compute
//
pub const ComputePipelineConfig = extern struct {
    compute_shader_path: ?[*:0]const u8,
    push_constant_size: u32,
    push_constant_stages: c.VkShaderStageFlags,
    descriptor_set_count: u32,
    descriptor_layouts: ?[*]c.VkDescriptorSetLayout,
    local_size_x: u32,
    local_size_y: u32,
    local_size_z: u32,
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
    group_count_x: u32,
    group_count_y: u32,
    group_count_z: u32,
    descriptor_sets: ?[*]c.VkDescriptorSet,
    descriptor_set_count: u32,
    push_constants: ?*const anyopaque,
    push_constant_size: u32,
};

pub const ComputeMemoryBarrier = extern struct {
    src_stage_mask: c.VkPipelineStageFlags,
    dst_stage_mask: c.VkPipelineStageFlags,
    src_access_mask: c.VkAccessFlags,
    dst_access_mask: c.VkAccessFlags,
};

//
// VulkanCommands
//
pub const VulkanCommands = extern struct {
    pools: ?[*]c.VkCommandPool,               // Per frame
    buffers: ?[*]c.VkCommandBuffer,           // Per frame
    secondary_buffers: ?[*]c.VkCommandBuffer, // Per frame (double buffering)
    scene_secondary_buffers: ?[*]c.VkCommandBuffer, // Per frame (Level Secondary)
    current_buffer_index: u32,
};

//
// VulkanSyncManager
//
pub const VulkanTimelineValueStrategy = extern struct {
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
    
    // Per-frame resources
    in_flight_fences: ?[*]c.VkFence,
    image_acquired_semaphores: ?[*]c.VkSemaphore,
    render_finished_semaphores: ?[*]c.VkSemaphore,
    
    // Timeline semaphore
    timeline_semaphore: c.VkSemaphore,
    
    // Counters
    current_frame_value: u64,
    image_available_value: u64,
    render_complete_value: u64,
    global_timeline_counter: u64,
    timeline_wait_count: u64,
    timeline_signal_count: u64,
    
    value_strategy: VulkanTimelineValueStrategy,
    initialized: bool,
};

pub const VulkanFrameSyncInfo = extern struct {
    wait_semaphore: c.VkSemaphore,
    signal_semaphore: c.VkSemaphore,
    fence: c.VkFence,
    timeline_value: u64,
    wait_stage: c.VkPipelineStageFlags,
};

pub const VkQueueFamilyOwnershipTransferInfo = extern struct {
    src_queue_family: u32,
    dst_queue_family: u32,
    src_stage_mask: c.VkPipelineStageFlags2,
    dst_stage_mask: c.VkPipelineStageFlags2,
    src_access_mask: c.VkAccessFlags2,
    dst_access_mask: c.VkAccessFlags2,
    use_maintenance8_enhancement: bool,
};

pub const VulkanFrameSync = extern struct {
    current_frame: u32,
    max_frames_in_flight: u32,
    current_frame_value: u64,
    image_available_value: u64,
    render_complete_value: u64,
    
    in_flight_fences: ?[*]c.VkFence,
    image_acquired_semaphores: ?[*]c.VkSemaphore,
    render_finished_semaphores: ?[*]c.VkSemaphore,
    
    timeline_semaphore: c.VkSemaphore,
};

pub const VulkanRecovery = extern struct {
    device_lost: bool,
    recovery_in_progress: bool,
    attempt_count: u32,
    max_attempts: u32,
    
    window: ?*CardinalWindow,
    
    device_loss_callback: ?*const fn(?*anyopaque) callconv(.c) void,
    recovery_complete_callback: ?*const fn(?*anyopaque, bool) callconv(.c) void,
    callback_user_data: ?*anyopaque,
};

//
// VulkanDescriptorManager
//
pub const VulkanDescriptorBinding = extern struct {
    binding: u32,
    descriptorType: c.VkDescriptorType,
    descriptorCount: u32,
    stageFlags: c.VkShaderStageFlags,
    pImmutableSamplers: ?*const c.VkSampler,
};

pub const VulkanDescriptorManager = extern struct {
    descriptorPool: c.VkDescriptorPool,
    descriptorSetLayout: c.VkDescriptorSetLayout,
    descriptorSets: ?[*]c.VkDescriptorSet,
    descriptorSetCount: u32,
    
    // Config
    maxSets: u32,
    bindings: ?[*]const VulkanDescriptorBinding,
    bindingCount: u32,
    
    // State
    initialized: bool,
    device: c.VkDevice,
    
    // Descriptor Buffer support
    useDescriptorBuffers: bool,
    descriptorBuffer: VulkanBuffer,
    descriptorSetSize: c.VkDeviceSize,
    descriptorBufferSize: c.VkDeviceSize,
    bindingOffsets: ?[*]c.VkDeviceSize,
    bindingOffsetCount: u32,
    descriptorBufferIndices: ?[*]u32,
    
    allocator: ?*VulkanAllocator,
    vulkan_state: ?*anyopaque,
    
    mutex: ?*anyopaque,
};

//
// VulkanTextureManager
//
pub const VulkanManagedTexture = extern struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    width: u32,
    height: u32,
    channels: u32,
    isPlaceholder: bool,
    path: [*c]u8,
};

pub const VulkanTextureManagerConfig = extern struct {
    device: c.VkDevice,
    allocator: ?*VulkanAllocator,
    commandPool: c.VkCommandPool,
    graphicsQueue: c.VkQueue,
    syncManager: ?*VulkanSyncManager,
    initialCapacity: u32,
};

pub const VulkanTextureManager = extern struct {
    textures: [*]VulkanManagedTexture,
    textureCount: u32,
    textureCapacity: u32,
    
    device: c.VkDevice,
    allocator: *VulkanAllocator,
    commandPool: c.VkCommandPool,
    graphicsQueue: c.VkQueue,
    syncManager: ?*VulkanSyncManager,
    
    defaultSampler: c.VkSampler,
    hasPlaceholder: bool,
    
    // Thread safety
    mutex: ?*anyopaque,
};

//
// VulkanTimelineDebug
//
pub const VulkanTimelineWaitInfo = extern struct {
    semaphore: c.VkSemaphore,
    fence: c.VkFence,
    timeline_value: u64,
    wait_stage: c.VkPipelineStageFlags,
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

pub const VulkanPBRPipeline = extern struct {
    pipeline: c.VkPipeline,
    pipelineBlend: c.VkPipeline,
    pipelineLayout: c.VkPipelineLayout,

    descriptorManager: ?*VulkanDescriptorManager,
    textureManager: ?*VulkanTextureManager,

    uniformBuffer: c.VkBuffer,
    uniformBufferMemory: c.VkDeviceMemory,
    uniformBufferMapped: ?*anyopaque,

    materialBuffer: c.VkBuffer,
    materialBufferMemory: c.VkDeviceMemory,
    materialBufferMapped: ?*anyopaque,

    lightingBuffer: c.VkBuffer,
    lightingBufferMemory: c.VkDeviceMemory,
    lightingBufferMapped: ?*anyopaque,

    boneMatricesBuffer: c.VkBuffer,
    boneMatricesBufferMemory: c.VkDeviceMemory,
    boneMatricesBufferMapped: ?*anyopaque,
    maxBones: u32,

    vertexBuffer: c.VkBuffer,
    vertexBufferMemory: c.VkDeviceMemory,
    indexBuffer: c.VkBuffer,
    indexBufferMemory: c.VkDeviceMemory,
    totalIndexCount: u32,

    supportsDescriptorIndexing: bool,
    initialized: bool,
};

//
// VulkanMeshShader
//
pub const MeshShaderPipelineConfig = extern struct {
    mesh_shader_path: ?[*:0]const u8,
    task_shader_path: ?[*:0]const u8,
    fragment_shader_path: ?[*:0]const u8,

    topology: c.VkPrimitiveTopology,
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

    max_vertices_per_meshlet: u32,
    max_primitives_per_meshlet: u32,
};

pub const MeshShaderPipeline = extern struct {
    pipeline: c.VkPipeline,
    pipeline_layout: c.VkPipelineLayout,

    set0_layout: c.VkDescriptorSetLayout,
    set1_layout: c.VkDescriptorSetLayout,
    global_descriptor_set: c.VkDescriptorSet,
    descriptor_pool: c.VkDescriptorPool,

    default_material_buffer: c.VkBuffer,
    default_material_memory: c.VkDeviceMemory,

    descriptor_manager: ?*VulkanDescriptorManager,

    has_task_shader: bool,
    max_meshlets_per_workgroup: u32,
    max_vertices_per_meshlet: u32,
    max_primitives_per_meshlet: u32,
};

pub const MeshShaderDrawData = extern struct {
    vertex_buffer: c.VkBuffer,
    vertex_memory: c.VkDeviceMemory,
    meshlet_buffer: c.VkBuffer,
    meshlet_memory: c.VkDeviceMemory,
    primitive_buffer: c.VkBuffer,
    primitive_memory: c.VkDeviceMemory,
    draw_command_buffer: c.VkBuffer,
    draw_command_memory: c.VkDeviceMemory,
    uniform_buffer: c.VkBuffer,
    uniform_memory: c.VkDeviceMemory,
    uniform_mapped: ?*anyopaque,

    meshlet_count: u32,
    draw_command_count: u32,

    descriptor_set: c.VkDescriptorSet,
};

pub const GpuMeshlet = extern struct {
    vertex_offset: u32,
    vertex_count: u32,
    primitive_offset: u32,
    primitive_count: u32,
};

pub const MeshShaderUniformBuffer = extern struct {
    model: [16]f32,
    view: [16]f32,
    proj: [16]f32,
    materialIndex: u32,
    _padding: [3]u32, // Align to 16 bytes if needed, or matches C struct alignment
};

//
// VulkanPipelines
//
pub const VulkanPipelines = extern struct {
    // PBR Pipeline
    use_pbr_pipeline: bool,
    pbr_pipeline: VulkanPBRPipeline,

    // Mesh Shader Pipeline
    use_mesh_shader_pipeline: bool,
    mesh_shader_pipeline: MeshShaderPipeline,

    // Compute Shader
    compute_shader_initialized: bool,
    compute_descriptor_pool: c.VkDescriptorPool,
    compute_command_pool: c.VkCommandPool,
    compute_command_buffer: c.VkCommandBuffer,

    // UV and Wireframe (Simple pipelines)
    uv_pipeline: c.VkPipeline,
    uv_pipeline_layout: c.VkPipelineLayout,
    wireframe_pipeline: c.VkPipeline,
    wireframe_pipeline_layout: c.VkPipelineLayout,

    // Shared Resources for Simple Pipelines
    simple_descriptor_layout: c.VkDescriptorSetLayout,
    simple_descriptor_pool: c.VkDescriptorPool,
    simple_descriptor_set: c.VkDescriptorSet,
    simple_uniform_buffer: c.VkBuffer,
    simple_uniform_buffer_memory: c.VkDeviceMemory,
    simple_uniform_buffer_mapped: ?*anyopaque,
};

//
// VulkanState (GpuMesh)
//
pub const GpuMesh = extern struct {
    vbuf: c.VkBuffer,
    vmem: c.VkDeviceMemory,
    ibuf: c.VkBuffer,
    imem: c.VkDeviceMemory,
    vtx_count: u32,
    idx_count: u32,
    vtx_stride: u32,
};

pub const CardinalRenderingMode = enum(c_int) {
    NORMAL = 0,
    UV = 1,
    WIREFRAME = 2,
    MESH_SHADER = 3,
};

pub const VulkanState = extern struct {
    // Modular subsystems
    context: VulkanContext,
    swapchain: VulkanSwapchain,
    commands: VulkanCommands,
    sync: VulkanFrameSync,
    pipelines: VulkanPipelines,
    recovery: VulkanRecovery,

    // Unified Vulkan memory allocator
    allocator: VulkanAllocator,

    // Centralized synchronization manager
    sync_manager: ?*VulkanSyncManager,

    // UI callback
    ui_record_callback: ?*const fn (cmd: c.VkCommandBuffer) callconv(.c) void,

    // Rendering mode state
    current_rendering_mode: CardinalRenderingMode,

    // Scene mesh buffers
    scene_meshes: ?[*]GpuMesh,
    scene_mesh_count: u32,

    // Scene
    current_scene: ?*const CardinalScene,
    pending_scene_upload: ?*const CardinalScene,
    scene_upload_pending: bool,

    // Mesh shader draw data pending cleanup (per-frame)
    pending_cleanup_lists: ?[*]?[*]MeshShaderDrawData,
    pending_cleanup_counts: ?[*]u32,
    pending_cleanup_capacities: ?[*]u32,
};

//
// Multi-Threading Types
//

pub const CARDINAL_MAX_MT_THREADS = 16;
pub const CARDINAL_MAX_SECONDARY_COMMAND_BUFFERS = 1024;

pub const cardinal_thread_handle_t = std.Thread;
pub const cardinal_thread_id_t = std.Thread.Id;
pub const cardinal_mutex_t = std.Thread.Mutex;
pub const cardinal_cond_t = std.Thread.Condition;

pub const CardinalThreadCommandPool = struct {
    primary_pool: c.VkCommandPool,
    secondary_pool: c.VkCommandPool,
    secondary_buffers: ?[*]c.VkCommandBuffer,
    secondary_buffer_count: u32,
    next_secondary_index: u32,
    thread_id: cardinal_thread_id_t,
    is_active: bool,
};

pub const CardinalMTCommandManager = struct {
    vulkan_state: ?*VulkanState,
    thread_pools: [CARDINAL_MAX_MT_THREADS]CardinalThreadCommandPool,
    active_thread_count: u32,
    pool_mutex: cardinal_mutex_t,
    is_initialized: bool,
};

pub const CardinalSecondaryCommandContext = struct {
    command_buffer: c.VkCommandBuffer,
    inheritance: c.VkCommandBufferInheritanceInfo,
    thread_index: u32,
    is_recording: bool,
};

pub const CardinalMTTaskType = enum(u32) {
    CARDINAL_MT_TASK_TEXTURE_LOAD = 0,
    CARDINAL_MT_TASK_MESH_LOAD = 1,
    CARDINAL_MT_TASK_MATERIAL_LOAD = 2,
    CARDINAL_MT_TASK_COMMAND_RECORD = 3,
    CARDINAL_MT_TASK_COUNT = 4,
};

pub const CardinalMTTask = struct {
    type: CardinalMTTaskType,
    data: ?*anyopaque,
    execute_func: ?*const fn(?*anyopaque) void,
    callback_func: ?*const fn(?*anyopaque, bool) void,
    is_completed: bool,
    success: bool,
    next: ?*CardinalMTTask,
};

pub const CardinalMTTaskQueue = struct {
    head: ?*CardinalMTTask,
    tail: ?*CardinalMTTask,
    queue_mutex: cardinal_mutex_t,
    queue_condition: cardinal_cond_t,
    task_count: u32,
};

pub const CardinalMTSubsystem = struct {
    command_manager: CardinalMTCommandManager,
    pending_queue: CardinalMTTaskQueue,
    completed_queue: CardinalMTTaskQueue,
    worker_threads: [CARDINAL_MAX_MT_THREADS]?cardinal_thread_handle_t,
    worker_thread_count: u32,
    is_running: bool,
    subsystem_mutex: cardinal_mutex_t,
};
