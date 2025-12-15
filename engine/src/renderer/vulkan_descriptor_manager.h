#ifndef VULKAN_DESCRIPTOR_MANAGER_H
#define VULKAN_DESCRIPTOR_MANAGER_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

// Forward declarations
typedef struct VulkanAllocator VulkanAllocator;
typedef struct VulkanState VulkanState;

/**
 * @brief Descriptor binding information for layout creation.
 */
typedef struct VulkanDescriptorBinding {
  uint32_t binding;                ///< Binding index
  VkDescriptorType descriptorType; ///< Type of descriptor
  uint32_t descriptorCount;        ///< Number of descriptors
  VkShaderStageFlags stageFlags;   ///< Shader stages that access this binding
  VkSampler *pImmutableSamplers;   ///< Immutable samplers (optional)
} VulkanDescriptorBinding;

/**
 * @brief Descriptor manager for handling both descriptor sets and descriptor
 * buffers.
 */
typedef struct VulkanDescriptorManager {
  VkDevice device;            ///< Vulkan logical device
  VulkanAllocator *allocator; ///< Memory allocator
  VulkanState *vulkan_state; ///< Vulkan state (for descriptor buffer extension)

  // Descriptor set layout
  VkDescriptorSetLayout layout;      ///< Descriptor set layout
  VulkanDescriptorBinding *bindings; ///< Array of binding descriptions
  uint32_t bindingCount;             ///< Number of bindings

  // Traditional descriptor sets
  VkDescriptorPool descriptorPool; ///< Descriptor pool for allocation
  VkDescriptorSet *descriptorSets; ///< Allocated descriptor sets
  uint32_t descriptorSetCount;     ///< Number of descriptor sets
  uint32_t maxSets;                ///< Maximum number of descriptor sets (capacity)

  // Descriptor buffers (VK_EXT_descriptor_buffer)
  bool useDescriptorBuffers;             ///< Whether to use descriptor buffers
  VkBuffer descriptorBuffer;             ///< Descriptor buffer handle
  VkDeviceMemory descriptorBufferMemory; ///< Descriptor buffer memory
  VkDeviceSize descriptorBufferSize;     ///< Size of descriptor buffer
  void *descriptorBufferMapped;          ///< Mapped descriptor buffer memory
  VkDeviceSize descriptorSetSize; ///< Size of each descriptor set in buffer
  VkDeviceSize *bindingOffsets;   ///< Per-binding offsets in set (indexed by
                                  ///< binding number)
  uint32_t bindingOffsetCount;    ///< Size of bindingOffsets array

  // Resource tracking
  bool initialized; ///< Whether the manager is initialized
} VulkanDescriptorManager;

/**
 * @brief Configuration for descriptor manager creation.
 */
typedef struct VulkanDescriptorManagerCreateInfo {
  VulkanDescriptorBinding *bindings; ///< Array of binding descriptions
  uint32_t bindingCount;             ///< Number of bindings
  uint32_t maxSets;                  ///< Maximum number of descriptor sets
  bool preferDescriptorBuffers;      ///< Prefer descriptor buffers if available
  VkDescriptorPoolCreateFlags poolFlags; ///< Descriptor pool creation flags
} VulkanDescriptorManagerCreateInfo;

/**
 * @brief Creates a descriptor manager with the specified configuration.
 *
 * @param manager Pointer to VulkanDescriptorManager to initialize
 * @param device Vulkan logical device
 * @param allocator Vulkan memory allocator
 * @param createInfo Manager creation configuration
 * @return true on success, false on failure
 */
bool vk_descriptor_manager_create(
    VulkanDescriptorManager *manager, VkDevice device,
    VulkanAllocator *allocator,
    const VulkanDescriptorManagerCreateInfo *createInfo,
    VulkanState *vulkan_state);

/**
 * @brief Destroys a descriptor manager and frees all resources.
 *
 * @param manager Pointer to VulkanDescriptorManager to destroy
 */
void vk_descriptor_manager_destroy(VulkanDescriptorManager *manager);

/**
 * @brief Allocates descriptor sets from the manager.
 *
 * @param manager Descriptor manager
 * @param setCount Number of sets to allocate
 * @param pDescriptorSets Output array for allocated sets
 * @return true on success, false on failure
 */
bool vk_descriptor_manager_allocate_sets(VulkanDescriptorManager *manager,
                                         uint32_t setCount,
                                         VkDescriptorSet *pDescriptorSets);

/**
 * @brief Updates descriptor sets with buffer information.
 *
 * @param manager Descriptor manager
 * @param setIndex Index of the descriptor set to update
 * @param binding Binding index to update
 * @param buffer Buffer handle
 * @param offset Offset in the buffer
 * @param range Size of the buffer range
 * @return true on success, false on failure
 */
bool vk_descriptor_manager_update_buffer(VulkanDescriptorManager *manager,
                                         uint32_t setIndex, uint32_t binding,
                                         VkBuffer buffer, VkDeviceSize offset,
                                         VkDeviceSize range);

/**
 * @brief Updates descriptor sets with image information.
 *
 * @param manager Descriptor manager
 * @param setIndex Index of the descriptor set to update
 * @param binding Binding index to update
 * @param imageView Image view handle
 * @param sampler Sampler handle
 * @param imageLayout Image layout
 * @return true on success, false on failure
 */
bool vk_descriptor_manager_update_image(VulkanDescriptorManager *manager,
                                        uint32_t setIndex, uint32_t binding,
                                        VkImageView imageView,
                                        VkSampler sampler,
                                        VkImageLayout imageLayout);

/**
 * @brief Updates descriptor sets with multiple textures (for bindless
 * rendering).
 *
 * @param manager Descriptor manager
 * @param setIndex Index of the descriptor set to update
 * @param binding Binding index to update
 * @param imageViews Array of image view handles
 * @param sampler Sampler handle (shared)
 * @param imageLayout Image layout (shared)
 * @param count Number of textures
 * @return true on success, false on failure
 */
bool vk_descriptor_manager_update_textures(VulkanDescriptorManager *manager,
                                           uint32_t setIndex, uint32_t binding,
                                           VkImageView *imageViews,
                                           VkSampler sampler,
                                           VkImageLayout imageLayout,
                                           uint32_t count);

/**
 * @brief Updates descriptor sets with multiple textures and unique samplers.
 *
 * @param manager Descriptor manager
 * @param setIndex Index of the descriptor set to update
 * @param binding Binding index to update
 * @param imageViews Array of image view handles
 * @param samplers Array of sampler handles
 * @param imageLayout Image layout (shared)
 * @param count Number of textures
 * @return true on success, false on failure
 */
bool vk_descriptor_manager_update_textures_with_samplers(VulkanDescriptorManager *manager,
                                           uint32_t setIndex, uint32_t binding,
                                           VkImageView *imageViews,
                                           VkSampler *samplers,
                                           VkImageLayout imageLayout,
                                           uint32_t count);

/**
 * @brief Binds descriptor sets to a command buffer.
 *
 * @param manager Descriptor manager
 * @param commandBuffer Command buffer to bind to
 * @param pipelineLayout Pipeline layout
 * @param firstSet First descriptor set index
 * @param setCount Number of descriptor sets to bind
 * @param pDescriptorSets Array of descriptor sets to bind
 * @param dynamicOffsetCount Number of dynamic offsets
 * @param pDynamicOffsets Array of dynamic offsets
 */
void vk_descriptor_manager_bind_sets(VulkanDescriptorManager *manager,
                                     VkCommandBuffer commandBuffer,
                                     VkPipelineLayout pipelineLayout,
                                     uint32_t firstSet, uint32_t setCount,
                                     const VkDescriptorSet *pDescriptorSets,
                                     uint32_t dynamicOffsetCount,
                                     const uint32_t *pDynamicOffsets);

/**
 * @brief Gets the descriptor set layout from the manager.
 *
 * @param manager Descriptor manager
 * @return Descriptor set layout handle
 */
VkDescriptorSetLayout
vk_descriptor_manager_get_layout(const VulkanDescriptorManager *manager);

/**
 * @brief Checks if the manager is using descriptor buffers.
 *
 * @param manager Descriptor manager
 * @return true if using descriptor buffers, false if using traditional sets
 */
bool vk_descriptor_manager_uses_buffers(const VulkanDescriptorManager *manager);

/**
 * @brief Gets the size of a descriptor set in the descriptor buffer.
 *
 * @param manager Descriptor manager
 * @return Size of each descriptor set in bytes
 */
VkDeviceSize
vk_descriptor_manager_get_set_size(const VulkanDescriptorManager *manager);

/**
 * @brief Gets a pointer to descriptor data in the descriptor buffer.
 *
 * @param manager Descriptor manager
 * @param setIndex Index of the descriptor set
 * @return Pointer to descriptor data, or NULL if not using descriptor buffers
 */
void *vk_descriptor_manager_get_set_data(VulkanDescriptorManager *manager,
                                         uint32_t setIndex);

#endif // VULKAN_DESCRIPTOR_MANAGER_H
