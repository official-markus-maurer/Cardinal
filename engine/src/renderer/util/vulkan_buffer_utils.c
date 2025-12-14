#include "../vulkan_buffer_manager.h"
#include "../vulkan_state.h"
#include <cardinal/core/log.h>
#include <cardinal/renderer/util/vulkan_buffer_utils.h>
#include <string.h>

/**
 * @brief Finds a suitable memory type index.
 * @param physicalDevice Physical device.
 * @param typeFilter Memory type filter.
 * @param properties Required memory properties.
 * @return Memory type index or UINT32_MAX on failure.
 *
 * @todo Cache memory properties for performance.
 */
uint32_t vk_buffer_find_memory_type(VkPhysicalDevice physicalDevice, uint32_t typeFilter,
                                    VkMemoryPropertyFlags properties) {
    VkPhysicalDeviceMemoryProperties memProperties;
    vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProperties);

    CARDINAL_LOG_DEBUG(
        "Searching for memory type: typeFilter=0x%X, properties=0x%X, available types=%u",
        typeFilter, properties, memProperties.memoryTypeCount);

    for (uint32_t i = 0; i < memProperties.memoryTypeCount; i++) {
        bool typeMatches = (typeFilter & (1 << i)) != 0;
        bool propertiesMatch =
            (memProperties.memoryTypes[i].propertyFlags & properties) == properties;

        CARDINAL_LOG_DEBUG("  Type %u: heap=%u, flags=0x%X, typeMatch=%s, propMatch=%s", i,
                           memProperties.memoryTypes[i].heapIndex,
                           memProperties.memoryTypes[i].propertyFlags, typeMatches ? "yes" : "no",
                           propertiesMatch ? "yes" : "no");

        if (typeMatches && propertiesMatch) {
            CARDINAL_LOG_DEBUG(
                "Found suitable memory type: index=%u, heap=%u, size=%llu MB", i,
                memProperties.memoryTypes[i].heapIndex,
                memProperties.memoryHeaps[memProperties.memoryTypes[i].heapIndex].size /
                    (1024 * 1024));
            return i;
        }
    }

    CARDINAL_LOG_ERROR("Failed to find suitable memory type! typeFilter=0x%X, properties=0x%X",
                       typeFilter, properties);
    return UINT32_MAX;
}

/**
 * @brief Creates a buffer with optimal GPU memory using staging buffer transfer.
 * @param allocator VulkanAllocator instance.
 * @param device Logical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param data Source data to upload.
 * @param size Buffer size.
 * @param usage Buffer usage flags (will add TRANSFER_DST_BIT automatically).
 * @param buffer Output buffer handle.
 * @param bufferMemory Output memory handle.
 * @return true on success, false on failure.
 */
bool vk_buffer_create_with_staging(VulkanAllocator* allocator, VkDevice device,
                                   VkCommandPool commandPool, VkQueue graphicsQueue,
                                   const void* data, VkDeviceSize size, VkBufferUsageFlags usage,
                                   VkBuffer* buffer, VkDeviceMemory* bufferMemory,
                                   VulkanState* vulkan_state) {
    if (!data || size == 0 || !allocator || !buffer || !bufferMemory) {
        CARDINAL_LOG_ERROR("Invalid parameters for staging buffer creation");
        return false;
    }

    VulkanBuffer destBufferObj = {0};
    
    // Use the core manager function
    if (!vk_buffer_create_device_local(&destBufferObj, device, allocator, commandPool,
                                       graphicsQueue, data, size, usage, vulkan_state)) {
        CARDINAL_LOG_ERROR("Failed to create device local buffer with staging");
        return false;
    }

    // Return raw handles for compatibility
    *buffer = destBufferObj.handle;
    *bufferMemory = destBufferObj.memory;

    CARDINAL_LOG_DEBUG("Successfully created buffer with staging: size=%llu bytes, usage=0x%X",
                       (unsigned long long)size, usage);
    return true;
}
