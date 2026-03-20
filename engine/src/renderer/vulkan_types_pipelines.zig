//! Pipeline and GPU draw types.
//!
//! Shared structs for compute pipelines, mesh shader pipelines, and post-processing pipelines.
const c = @import("vulkan_c.zig").c;
const core = @import("vulkan_types_core.zig");
const pbr = @import("vulkan_types_pbr.zig");
const tex = @import("vulkan_types_textures.zig");

/// Configuration for creating a compute pipeline.
pub const ComputePipelineConfig = extern struct {
    compute_shader_path: ?[*:0]const u8,
    descriptor_layouts: ?[*]c.VkDescriptorSetLayout,
    descriptor_set_count: u32,
    push_constant_size: u32,
    push_constant_stages: c.VkShaderStageFlags,
    local_size_x: u32,
    local_size_y: u32,
    local_size_z: u32,
};

/// Created compute pipeline and its layout metadata.
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
    owns_layouts: bool,
    initialized: bool,
};

/// Dispatch parameters for a compute pipeline.
pub const ComputeDispatchInfo = extern struct {
    descriptor_sets: ?[*]c.VkDescriptorSet,
    descriptor_set_count: u32,
    push_constants: ?*const anyopaque,
    push_constant_size: u32,
    group_count_x: u32,
    group_count_y: u32,
    group_count_z: u32,
};

/// Convenience barrier description used by compute helpers.
pub const ComputeMemoryBarrier = extern struct {
    src_access_mask: c.VkAccessFlags2,
    dst_access_mask: c.VkAccessFlags2,
    src_stage_mask: c.VkPipelineStageFlags2,
    dst_stage_mask: c.VkPipelineStageFlags2,
};

/// Configuration for the mesh shader pipeline variant.
pub const MeshShaderPipelineConfig = extern struct {
    mesh_shader_path: ?[*:0]const u8,
    task_shader_path: ?[*:0]const u8,
    fragment_shader_path: ?[*:0]const u8,
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
    set0_manager: ?*core.VulkanDescriptorManager,
    set1_manager: ?*core.VulkanDescriptorManager,
    global_descriptor_set: c.VkDescriptorSet,
    has_task_shader: bool,
    max_meshlets_per_workgroup: u32,
    max_vertices_per_meshlet: u32,
    initialized: bool,
    defaultMaterialBuffer: core.VulkanBuffer,
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
    center: [3]f32,
    radius: f32,
    cone_axis: [3]f32,
    cone_cutoff: f32,
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
    descriptorManager: ?*core.VulkanDescriptorManager,
    descriptorSets: [core.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    texture: tex.VulkanManagedTexture,
    initialized: bool,
};

pub const PostProcessParams = extern struct {
    exposure: f32,
    contrast: f32,
    saturation: f32,
    bloomIntensity: f32,
    bloomThreshold: f32,
    bloomKnee: f32,
    padding: [2]f32,
};

pub const PostProcessPipeline = extern struct {
    pipeline: c.VkPipeline,
    pipelineLayout: c.VkPipelineLayout,
    descriptorManager: ?*core.VulkanDescriptorManager,
    descriptorSets: [core.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    initialized: bool,
    sampler: c.VkSampler,

    bloom_pipeline: ComputePipeline,
    bloom_image: c.VkImage,
    bloom_view: c.VkImageView,
    bloom_memory: c.VkDeviceMemory,
    bloom_allocation: c.VmaAllocation,
    bloomDescriptorManager: ?*core.VulkanDescriptorManager,
    bloomDescriptorSets: [core.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,

    params_buffer: [core.MAX_FRAMES_IN_FLIGHT]c.VkBuffer,
    params_memory: [core.MAX_FRAMES_IN_FLIGHT]c.VkDeviceMemory,
    params_allocation: [core.MAX_FRAMES_IN_FLIGHT]c.VmaAllocation,
    params_mapped: [core.MAX_FRAMES_IN_FLIGHT]?*anyopaque,
    current_params: PostProcessParams,
};

pub const SSAOPipeline = extern struct {
    pipeline: ComputePipeline,
    blur_pipeline: ComputePipeline,

    width: u32,
    height: u32,

    ssao_image: [core.MAX_FRAMES_IN_FLIGHT]c.VkImage,
    ssao_view: [core.MAX_FRAMES_IN_FLIGHT]c.VkImageView,
    ssao_memory: [core.MAX_FRAMES_IN_FLIGHT]c.VkDeviceMemory,
    ssao_allocation: [core.MAX_FRAMES_IN_FLIGHT]c.VmaAllocation,

    ssao_blur_image: [core.MAX_FRAMES_IN_FLIGHT]c.VkImage,
    ssao_blur_view: [core.MAX_FRAMES_IN_FLIGHT]c.VkImageView,
    ssao_blur_memory: [core.MAX_FRAMES_IN_FLIGHT]c.VkDeviceMemory,
    ssao_blur_allocation: [core.MAX_FRAMES_IN_FLIGHT]c.VmaAllocation,

    noise_texture: tex.VulkanManagedTexture,
    kernel_buffer: c.VkBuffer,
    kernel_memory: c.VkDeviceMemory,
    kernel_allocation: c.VmaAllocation,

    descriptor_sets: [core.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    blur_descriptor_sets: [core.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    descriptorManager: ?*core.VulkanDescriptorManager,
    blurDescriptorManager: ?*core.VulkanDescriptorManager,

    initialized: bool,
};

pub const VulkanPipelines = extern struct {
    mesh_shader_pipeline: MeshShaderPipeline,
    simple_descriptor_manager: ?*core.VulkanDescriptorManager,
    pbr_pipeline: VulkanPBRPipeline,
    skybox_pipeline: SkyboxPipeline,
    post_process_pipeline: PostProcessPipeline,
    ssao_pipeline: SSAOPipeline,
    use_pbr_pipeline: bool,
    use_skybox_pipeline: bool,
    use_post_process: bool,
    use_ssao: bool,

    use_mesh_shader_pipeline: bool,
    compute_shader_initialized: bool,
    simple_uniform_buffer: core.VulkanBuffer,
    simple_descriptor_set: c.VkDescriptorSet,
    uv_pipeline: c.VkPipeline,
    uv_pipeline_layout: c.VkPipelineLayout,

    wireframe_pipeline: c.VkPipeline,
    wireframe_pipeline_layout: c.VkPipelineLayout,

    grid_pipeline: c.VkPipeline,
    grid_pipeline_layout: c.VkPipelineLayout,
    grid_vertex_buffer: core.VulkanBuffer,
    grid_vertex_count: u32,

    depth_pipeline: c.VkPipeline,
    depth_pipeline_layout: c.VkPipelineLayout,

    compute_descriptor_pool: c.VkDescriptorPool,
    compute_command_pool: c.VkCommandPool,
    compute_command_buffer: c.VkCommandBuffer,

    pipeline_cache: c.VkPipelineCache,
};

pub const VulkanPBRPipeline = extern struct {
    pipeline: c.VkPipeline,
    pipelineLayout: c.VkPipelineLayout,
    descriptorManager: ?*core.VulkanDescriptorManager,
    textureManager: ?*tex.VulkanTextureManager,

    uniformBuffers: [core.MAX_FRAMES_IN_FLIGHT]c.VkBuffer,
    uniformBuffersMemory: [core.MAX_FRAMES_IN_FLIGHT]c.VkDeviceMemory,
    uniformBuffersAllocation: [core.MAX_FRAMES_IN_FLIGHT]c.VmaAllocation,
    uniformBuffersMapped: [core.MAX_FRAMES_IN_FLIGHT]?*anyopaque,

    lightingBuffers: [core.MAX_FRAMES_IN_FLIGHT]c.VkBuffer,
    lightingBuffersMemory: [core.MAX_FRAMES_IN_FLIGHT]c.VkDeviceMemory,
    lightingBuffersAllocation: [core.MAX_FRAMES_IN_FLIGHT]c.VmaAllocation,
    lightingBuffersMapped: [core.MAX_FRAMES_IN_FLIGHT]?*anyopaque,

    shadowPipeline: c.VkPipeline,
    shadowAlphaPipeline: c.VkPipeline,
    shadowPipelineLayout: c.VkPipelineLayout,
    shadowDescriptorManager: ?*core.VulkanDescriptorManager,
    shadowDescriptorSets: [core.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    shadowMapImage: c.VkImage,
    shadowMapMemory: c.VkDeviceMemory,
    shadowMapAllocation: c.VmaAllocation,
    shadowMapView: c.VkImageView,
    shadowCascadeViews: [4]c.VkImageView,
    shadowMapSampler: c.VkSampler,

    shadowUBOs: [core.MAX_FRAMES_IN_FLIGHT]c.VkBuffer,
    shadowUBOsMemory: [core.MAX_FRAMES_IN_FLIGHT]c.VkDeviceMemory,
    shadowUBOsAllocation: [core.MAX_FRAMES_IN_FLIGHT]c.VmaAllocation,
    shadowUBOsMapped: [core.MAX_FRAMES_IN_FLIGHT]?*anyopaque,

    boneMatricesBuffers: [core.MAX_FRAMES_IN_FLIGHT]c.VkBuffer,
    boneMatricesBuffersMemory: [core.MAX_FRAMES_IN_FLIGHT]c.VkDeviceMemory,
    boneMatricesBuffersAllocation: [core.MAX_FRAMES_IN_FLIGHT]c.VmaAllocation,
    boneMatricesBuffersMapped: [core.MAX_FRAMES_IN_FLIGHT]?*anyopaque,
    maxBones: u32,

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

    current_ubo: pbr.PBRUniformBufferObject,
    current_lighting: pbr.PBRLightingBuffer,

    set0_binding_info: c.VkDescriptorBufferBindingInfoEXT,
    set0_binding_info_valid: bool,
};
