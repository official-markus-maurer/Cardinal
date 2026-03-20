//! Vulkan renderer shared types.
//!
//! Defines C-ABI-friendly enums/structs shared across renderer modules and C entrypoints.
//! Some declarations mirror shader layouts and must remain layout-stable.
//!
//! This file is a facade that re-exports domain type modules.

const core = @import("vulkan_types_core.zig");
const mt = @import("vulkan_types_mt.zig");
const pbr = @import("vulkan_types_pbr.zig");
const pipes = @import("vulkan_types_pipelines.zig");
const state = @import("vulkan_types_state.zig");
const sync = @import("vulkan_types_sync.zig");
const tex = @import("vulkan_types_textures.zig");

pub const CARDINAL_MAX_SECONDARY_COMMAND_BUFFERS = core.CARDINAL_MAX_SECONDARY_COMMAND_BUFFERS;
pub const CARDINAL_MAX_MT_THREADS = core.CARDINAL_MAX_MT_THREADS;
pub const MAX_SHADOW_CASCADES = core.MAX_SHADOW_CASCADES;
pub const MAX_FRAMES_IN_FLIGHT = core.MAX_FRAMES_IN_FLIGHT;

pub const CardinalWindow = core.CardinalWindow;
pub const CardinalRenderer = core.CardinalRenderer;
pub const CardinalScene = core.CardinalScene;
pub const CardinalMesh = core.CardinalMesh;
pub const CardinalVertex = core.CardinalVertex;
pub const CardinalMaterial = core.CardinalMaterial;
pub const CardinalSceneNode = core.CardinalSceneNode;

pub const cardinal_mutex_t = core.cardinal_mutex_t;
pub const cardinal_cond_t = core.cardinal_cond_t;
pub const cardinal_thread_id_t = core.cardinal_thread_id_t;
pub const cardinal_thread_handle_t = core.cardinal_thread_handle_t;

pub const CardinalRenderingMode = core.CardinalRenderingMode;
pub const CardinalResourceType = core.CardinalResourceType;
pub const CardinalResourceAccessType = core.CardinalResourceAccessType;
pub const CardinalCamera = core.CardinalCamera;
pub const CardinalLight = core.CardinalLight;

pub const CardinalMTTaskType = mt.CardinalMTTaskType;
pub const CardinalMTTask = mt.CardinalMTTask;
pub const CardinalMTTaskQueue = mt.CardinalMTTaskQueue;
pub const CardinalMTThreadPool = mt.CardinalMTThreadPool;
pub const CardinalSecondaryCommandContext = mt.CardinalSecondaryCommandContext;
pub const CardinalThreadCommandPool = mt.CardinalThreadCommandPool;
pub const CardinalMTCommandManager = mt.CardinalMTCommandManager;
pub const CardinalMTSubsystem = mt.CardinalMTSubsystem;

pub const CardinalResourceAccess = core.CardinalResourceAccess;
pub const CardinalBarrierValidationContext = core.CardinalBarrierValidationContext;
pub const ValidationStats = core.ValidationStats;

pub const PBRTextureTransform = pbr.PBRTextureTransform;
pub const PBRUniformBufferObject = pbr.PBRUniformBufferObject;
pub const PBRLightType = pbr.PBRLightType;
pub const ShadowPushConstants = pbr.ShadowPushConstants;
pub const PBRLight = pbr.PBRLight;
pub const MAX_LIGHTS = pbr.MAX_LIGHTS;
pub const PBRLightingBuffer = pbr.PBRLightingBuffer;
pub const PBRMaterialProperties = pbr.PBRMaterialProperties;
pub const PBRPushConstants = pbr.PBRPushConstants;
pub const MeshShaderPushConstants = pbr.MeshShaderPushConstants;
pub const MeshShaderUniformBuffer = pbr.MeshShaderUniformBuffer;

pub const VkQueueFamilyOwnershipTransferInfo = core.VkQueueFamilyOwnershipTransferInfo;
pub const VulkanAllocator = core.VulkanAllocator;
pub const VulkanBuffer = core.VulkanBuffer;
pub const VulkanDescriptorBinding = core.VulkanDescriptorBinding;
pub const VulkanBufferAlloc = core.VulkanBufferAlloc;

pub const RenderGraph = core.RenderGraph;
pub const RESOURCE_ID_BACKBUFFER = core.RESOURCE_ID_BACKBUFFER;
pub const RESOURCE_ID_DEPTHBUFFER = core.RESOURCE_ID_DEPTHBUFFER;
pub const RESOURCE_ID_HDR_COLOR = core.RESOURCE_ID_HDR_COLOR;
pub const RESOURCE_ID_SSAO_RAW = core.RESOURCE_ID_SSAO_RAW;
pub const RESOURCE_ID_SSAO_BLURRED = core.RESOURCE_ID_SSAO_BLURRED;
pub const RESOURCE_ID_BLOOM = core.RESOURCE_ID_BLOOM;
pub const RESOURCE_ID_SHADOW_MAP = core.RESOURCE_ID_SHADOW_MAP;

pub const VulkanDescriptorManager = core.VulkanDescriptorManager;
pub const DescriptorBufferCreateInfo = core.DescriptorBufferCreateInfo;
pub const DescriptorBufferManager = core.DescriptorBufferManager;

pub const VulkanContext = core.VulkanContext;
pub const VulkanSwapchain = core.VulkanSwapchain;
pub const VulkanCommands = core.VulkanCommands;
pub const DeviceLossRecovery = state.DeviceLossRecovery;

pub const VulkanTimelineError = sync.VulkanTimelineError;
pub const VulkanTimelineErrorInfo = sync.VulkanTimelineErrorInfo;
pub const TimelineValueStrategy = sync.TimelineValueStrategy;
pub const VulkanSyncManager = sync.VulkanSyncManager;

pub const VulkanManagedTexture = tex.VulkanManagedTexture;
pub const VulkanTextureManagerConfig = tex.VulkanTextureManagerConfig;
pub const VulkanTextureManager = tex.VulkanTextureManager;
pub const BindlessTexture = tex.BindlessTexture;
pub const BindlessTextureCreateInfo = tex.BindlessTextureCreateInfo;
pub const BindlessTexturePool = tex.BindlessTexturePool;

pub const ComputePipelineConfig = pipes.ComputePipelineConfig;
pub const ComputePipeline = pipes.ComputePipeline;
pub const ComputeDispatchInfo = pipes.ComputeDispatchInfo;
pub const ComputeMemoryBarrier = pipes.ComputeMemoryBarrier;
pub const MeshShaderPipelineConfig = pipes.MeshShaderPipelineConfig;
pub const MeshShaderPipeline = pipes.MeshShaderPipeline;
pub const MeshShaderDrawData = pipes.MeshShaderDrawData;
pub const GpuMeshlet = pipes.GpuMeshlet;
pub const GpuMesh = pipes.GpuMesh;
pub const SkyboxPipeline = pipes.SkyboxPipeline;
pub const PostProcessParams = pipes.PostProcessParams;
pub const PostProcessPipeline = pipes.PostProcessPipeline;
pub const SSAOPipeline = pipes.SSAOPipeline;
pub const VulkanPipelines = pipes.VulkanPipelines;
pub const VulkanPBRPipeline = pipes.VulkanPBRPipeline;

pub const RendererConfig = state.RendererConfig;
pub const VulkanState = state.VulkanState;
