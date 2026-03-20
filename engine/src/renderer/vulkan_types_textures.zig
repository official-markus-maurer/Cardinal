//! Texture management types.
//!
//! Shared structs for classic texture arrays and bindless texture pools.
const c = @import("vulkan_c.zig").c;
const core = @import("vulkan_types_core.zig");
const sync = @import("vulkan_types_sync.zig");

/// Texture record tracked by the texture manager.
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
    resource: ?*anyopaque,
    is_updating: bool,
    update_failed: bool,
};

/// Configuration used when initializing a texture manager.
pub const VulkanTextureManagerConfig = extern struct {
    device: c.VkDevice,
    allocator: *core.VulkanAllocator,
    commandPool: c.VkCommandPool,
    graphicsQueue: c.VkQueue,
    syncManager: ?*sync.VulkanSyncManager,
    initialCapacity: u32,
    vulkan_state: ?*anyopaque,
    bindless_pool_capacity: u32,
};

/// Bindless texture slot stored in the bindless pool.
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

/// Parameters used when creating a bindless texture.
pub const BindlessTextureCreateInfo = extern struct {
    format: c.VkFormat,
    extent: c.VkExtent3D,
    mip_levels: u32,
    samples: c.VkSampleCountFlagBits,
    usage: c.VkImageUsageFlags,
    custom_sampler: c.VkSampler,
};

/// Fixed-capacity pool managing bindless texture slots and descriptors.
pub const BindlessTexturePool = extern struct {
    device: c.VkDevice,
    physical_device: c.VkPhysicalDevice,
    allocator: *core.VulkanAllocator,

    textures: ?[*]BindlessTexture,
    max_textures: u32,
    allocated_count: u32,

    free_indices: ?[*]u32,
    free_count: u32,

    descriptor_layout: c.VkDescriptorSetLayout,

    use_descriptor_buffer: bool,
    descriptor_buffer: core.VulkanBuffer,
    descriptor_set_size: c.VkDeviceSize,
    descriptor_offset: c.VkDeviceSize,
    descriptor_size: c.VkDeviceSize,
    descriptor_buffer_address: c.VkDeviceAddress,
    vkGetDescriptorEXT: c.PFN_vkGetDescriptorEXT,
    vkCmdBindDescriptorBuffersEXT: c.PFN_vkCmdBindDescriptorBuffersEXT,
    vkCmdSetDescriptorBufferOffsetsEXT: c.PFN_vkCmdSetDescriptorBufferOffsetsEXT,

    default_sampler: c.VkSampler,

    pending_updates: ?[*]u32,
    pending_update_count: u32,
    needs_descriptor_update: bool,
};

pub const VulkanTextureManager = extern struct {
    device: c.VkDevice,
    physicalDevice: c.VkPhysicalDevice,
    allocator: ?*core.VulkanAllocator,
    commandPool: c.VkCommandPool,
    graphicsQueue: c.VkQueue,
    syncManager: ?*sync.VulkanSyncManager,

    textures: ?[*]VulkanManagedTexture,
    textureCount: u32,
    textureCapacity: u32,

    defaultSampler: c.VkSampler,
    initialized: bool,

    vkQueueSubmit2: c.PFN_vkQueueSubmit2,

    manager_mutex: core.cardinal_mutex_t,
    hasPlaceholder: bool,
    bindless_pool: BindlessTexturePool,
    pending_updates: ?*anyopaque,

    upload_command_buffers: [core.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,
    upload_fence_values: [core.MAX_FRAMES_IN_FLIGHT]u64,
    upload_buffer_index: u32,
};
