#ifndef VULKAN_BUFFER_MANAGER_H
#define VULKAN_BUFFER_MANAGER_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

// Forward declarations
typedef struct VulkanAllocator VulkanAllocator;
typedef struct VulkanState VulkanState;

/**
 * @brief Represents a Vulkan buffer with its associated memory and metadata.
 */
typedef struct VulkanBuffer {
  VkBuffer handle;          ///< Vulkan buffer handle
  VkDeviceMemory memory;    ///< Associated device memory
  VkDeviceSize size;        ///< Size of the buffer in bytes
  void *mapped;             ///< Mapped memory pointer (NULL if not mapped)
  VkBufferUsageFlags usage; ///< Buffer usage flags
  VkMemoryPropertyFlags properties; ///< Memory property flags
} VulkanBuffer;

/**
 * @brief Configuration for buffer creation.
 */
typedef struct VulkanBufferCreateInfo {
  VkDeviceSize size;                ///< Size of the buffer in bytes
  VkBufferUsageFlags usage;         ///< Buffer usage flags
  VkMemoryPropertyFlags properties; ///< Memory property flags
  bool persistentlyMapped;          ///< Whether to keep the buffer mapped
} VulkanBufferCreateInfo;

/**
 * @brief Creates a Vulkan buffer with the specified configuration.
 *
 * @param buffer Pointer to VulkanBuffer structure to initialize
 * @param device Vulkan logical device
 * @param allocator Vulkan memory allocator
 * @param createInfo Buffer creation configuration
 * @return true on success, false on failure
 */
bool vk_buffer_create(VulkanBuffer *buffer, VkDevice device,
                      VulkanAllocator *allocator,
                      const VulkanBufferCreateInfo *createInfo);

/**
 * @brief Destroys a Vulkan buffer and frees associated memory.
 *
 * @param buffer Pointer to VulkanBuffer to destroy
 * @param device Vulkan logical device
 * @param allocator Vulkan memory allocator
 * @param vulkan_state Vulkan state for synchronization
 */
void vk_buffer_destroy(VulkanBuffer *buffer, VkDevice device,
                       VulkanAllocator *allocator,
                       struct VulkanState *vulkan_state);

/**
 * @brief Uploads data to a buffer.
 *
 * @param buffer Target buffer
 * @param device Vulkan logical device
 * @param data Source data pointer
 * @param size Size of data to upload
 * @param offset Offset in the buffer to start writing
 * @return true on success, false on failure
 */
bool vk_buffer_upload_data(VulkanBuffer *buffer, VkDevice device,
                           const void *data, VkDeviceSize size,
                           VkDeviceSize offset);

/**
 * @brief Maps buffer memory for CPU access.
 *
 * @param buffer Buffer to map
 * @param device Vulkan logical device
 * @param offset Offset to start mapping from
 * @param size Size to map (VK_WHOLE_SIZE for entire buffer)
 * @return Mapped memory pointer on success, NULL on failure
 */
void *vk_buffer_map(VulkanBuffer *buffer, VkDevice device, VkDeviceSize offset,
                    VkDeviceSize size);

/**
 * @brief Unmaps buffer memory.
 *
 * @param buffer Buffer to unmap
 * @param device Vulkan logical device
 */
void vk_buffer_unmap(VulkanBuffer *buffer, VkDevice device);

/**
 * @brief Creates a device-local buffer with staging transfer.
 *
 * @param buffer Pointer to VulkanBuffer structure to initialize
 * @param device Vulkan logical device
 * @param allocator Vulkan memory allocator
 * @param commandPool Command pool for staging operations
 * @param queue Graphics queue for command submission
 * @param data Source data to upload
 * @param size Size of data in bytes
 * @param usage Buffer usage flags
 * @param vulkan_state Vulkan state for synchronization
 * @return true on success, false on failure
 */
bool vk_buffer_create_device_local(VulkanBuffer *buffer, VkDevice device,
                                   VulkanAllocator *allocator,
                                   VkCommandPool commandPool, VkQueue queue,
                                   const void *data, VkDeviceSize size,
                                   VkBufferUsageFlags usage,
                                   struct VulkanState *vulkan_state);

/**
 * @brief Creates a vertex buffer with the specified data.
 *
 * @param buffer Pointer to VulkanBuffer structure to initialize
 * @param device Vulkan logical device
 * @param allocator Vulkan memory allocator
 * @param commandPool Command pool for staging operations
 * @param queue Graphics queue for command submission
 * @param vertices Vertex data
 * @param vertexSize Size of vertex data in bytes
 * @return true on success, false on failure
 */
bool vk_buffer_create_vertex(VulkanBuffer *buffer, VkDevice device,
                             VulkanAllocator *allocator,
                             VkCommandPool commandPool, VkQueue queue,
                             const void *vertices, VkDeviceSize vertexSize,
                             struct VulkanState *vulkan_state);

/**
 * @brief Creates an index buffer with the specified data.
 *
 * @param buffer Pointer to VulkanBuffer structure to initialize
 * @param device Vulkan logical device
 * @param allocator Vulkan memory allocator
 * @param commandPool Command pool for staging operations
 * @param queue Graphics queue for command submission
 * @param indices Index data
 * @param indexSize Size of index data in bytes
 * @return true on success, false on failure
 */
bool vk_buffer_create_index(VulkanBuffer *buffer, VkDevice device,
                            VulkanAllocator *allocator,
                            VkCommandPool commandPool, VkQueue queue,
                            const void *indices, VkDeviceSize indexSize,
                            struct VulkanState *vulkan_state);

/**
 * @brief Creates a uniform buffer.
 *
 * @param buffer Pointer to VulkanBuffer structure to initialize
 * @param device Vulkan logical device
 * @param allocator Vulkan memory allocator
 * @param size Size of the uniform buffer
 * @return true on success, false on failure
 */
bool vk_buffer_create_uniform(VulkanBuffer *buffer, VkDevice device,
                              VulkanAllocator *allocator, VkDeviceSize size);

/**
 * @brief Copies data from one buffer to another.
 *
 * @param device Vulkan logical device
 * @param commandPool Command pool for copy operations
 * @param queue Graphics queue for command submission
 * @param srcBuffer Source buffer
 * @param dstBuffer Destination buffer
 * @param size Size of data to copy
 * @param srcOffset Offset in source buffer
 * @param dstOffset Offset in destination buffer
 * @return true on success, false on failure
 */
bool vk_buffer_copy(VkDevice device, VkCommandPool commandPool, VkQueue queue,
                    VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size,
                    VkDeviceSize srcOffset, VkDeviceSize dstOffset,
                    struct VulkanState *vulkan_state);

#endif // VULKAN_BUFFER_MANAGER_H
