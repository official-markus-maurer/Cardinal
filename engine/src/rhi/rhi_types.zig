const std = @import("std");

pub const Format = enum(u32) {
    UNDEFINED = 0,
    R8_UNORM,
    R8_SNORM,
    R8_UINT,
    R8_SINT,
    R8G8_UNORM,
    R8G8_SNORM,
    R8G8_UINT,
    R8G8_SINT,
    R8G8B8_UNORM,
    R8G8B8_SNORM,
    R8G8B8_UINT,
    R8G8B8_SINT,
    R8G8B8A8_UNORM,
    R8G8B8A8_SNORM,
    R8G8B8A8_UINT,
    R8G8B8A8_SINT,
    R8G8B8A8_SRGB,
    B8G8R8A8_UNORM,
    B8G8R8A8_SRGB,
    R16_UNORM,
    R16_SNORM,
    R16_UINT,
    R16_SINT,
    R16_FLOAT,
    R16G16_UNORM,
    R16G16_SNORM,
    R16G16_UINT,
    R16G16_SINT,
    R16G16_FLOAT,
    R16G16B16_UNORM,
    R16G16B16_SNORM,
    R16G16B16_UINT,
    R16G16B16_SINT,
    R16G16B16_FLOAT,
    R16G16B16A16_UNORM,
    R16G16B16A16_SNORM,
    R16G16B16A16_UINT,
    R16G16B16A16_SINT,
    R16G16B16A16_FLOAT,
    R32_UINT,
    R32_SINT,
    R32_FLOAT,
    R32G32_UINT,
    R32G32_SINT,
    R32G32_FLOAT,
    R32G32B32_UINT,
    R32G32B32_SINT,
    R32G32B32_FLOAT,
    R32G32B32A32_UINT,
    R32G32B32A32_SINT,
    R32G32B32A32_FLOAT,
    D16_UNORM,
    D32_FLOAT,
    D24_UNORM_S8_UINT,
    D32_FLOAT_S8_UINT,
};

pub const IndexType = enum(u32) {
    UINT16,
    UINT32,
};

pub const PipelineBindPoint = enum(u32) {
    GRAPHICS,
    COMPUTE,
    RAY_TRACING,
};

pub const BufferUsage = packed struct {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    uniform_texel_buffer: bool = false,
    storage_texel_buffer: bool = false,
    uniform_buffer: bool = false,
    storage_buffer: bool = false,
    index_buffer: bool = false,
    vertex_buffer: bool = false,
    indirect_buffer: bool = false,
    shader_device_address: bool = false,
    _pad: u22 = 0,
};

pub const TextureUsage = packed struct {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    transient_attachment: bool = false,
    input_attachment: bool = false,
    _pad: u24 = 0,
};

pub const MemoryUsage = enum(u32) {
    GPU_ONLY,
    CPU_ONLY,
    CPU_TO_GPU,
    GPU_TO_CPU,
};

pub const ShaderStage = packed struct {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    geometry: bool = false,
    tessellation_control: bool = false,
    tessellation_evaluation: bool = false,
    mesh: bool = false,
    task: bool = false,
    raygen: bool = false,
    any_hit: bool = false,
    closest_hit: bool = false,
    miss: bool = false,
    intersection: bool = false,
    callable: bool = false,
    _pad: u18 = 0,
};

pub const Filter = enum(u32) {
    NEAREST,
    LINEAR,
};

pub const AddressMode = enum(u32) {
    REPEAT,
    MIRRORED_REPEAT,
    CLAMP_TO_EDGE,
    CLAMP_TO_BORDER,
};

pub const CompareOp = enum(u32) {
    NEVER,
    LESS,
    EQUAL,
    LESS_OR_EQUAL,
    GREATER,
    NOT_EQUAL,
    GREATER_OR_EQUAL,
    ALWAYS,
};

pub const CullMode = enum(u32) {
    NONE,
    FRONT,
    BACK,
    FRONT_AND_BACK,
};

pub const FrontFace = enum(u32) {
    COUNTER_CLOCKWISE,
    CLOCKWISE,
};

pub const PrimitiveTopology = enum(u32) {
    POINT_LIST,
    LINE_LIST,
    LINE_STRIP,
    TRIANGLE_LIST,
    TRIANGLE_STRIP,
    TRIANGLE_FAN,
};

pub const PolygonMode = enum(u32) {
    FILL,
    LINE,
    POINT,
};

pub const Viewport = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

pub const Rect2D = struct {
    offset_x: i32,
    offset_y: i32,
    extent_width: u32,
    extent_height: u32,
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const ClearValue = union(enum) {
    color: Color,
    depth_stencil: struct { depth: f32, stencil: u32 },
};

pub const BackendType = enum {
    Vulkan,
    // DirectX12,
    // Metal,
};
