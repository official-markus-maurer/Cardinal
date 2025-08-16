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
 * @brief Creates a Vulkan buffer and allocates memory using VulkanAllocator.
 * @param allocator VulkanAllocator instance.
 * @param size Buffer size.
 * @param usage Buffer usage flags.
 * @param properties Memory properties.
 * @param buffer Output buffer handle.
 * @param bufferMemory Output memory handle.
 * @return true on success, false on failure.
 */
bool vk_buffer_create(VulkanAllocator* allocator, VkDeviceSize size, VkBufferUsageFlags usage,
                      VkMemoryPropertyFlags properties, VkBuffer* buffer,
                      VkDeviceMemory* bufferMemory) {
    if (size == 0) {
        CARDINAL_LOG_ERROR("Cannot create buffer with size 0");
        return false;
    }
    if (!allocator) {
        CARDINAL_LOG_ERROR("Allocator is null in createBuffer");
        return false;
    }

    CARDINAL_LOG_DEBUG(
        "Creating buffer via allocator: size=%llu bytes, usage=0x%X, properties=0x%X", size, usage,
        properties);

    VkBufferCreateInfo bufferInfo = {0};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = size;
    bufferInfo.usage = usage;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    // Use allocator to create buffer + allocate/bind memory
    if (!vk_allocator_allocate_buffer(allocator, &bufferInfo, buffer, bufferMemory, properties)) {
        CARDINAL_LOG_ERROR("Allocator failed to create/allocate buffer (size=%llu, usage=0x%X)",
                           size, usage);
        return false;
    }

    CARDINAL_LOG_DEBUG("Buffer created via allocator: buffer=%p, memory=%p",
                       (void*)(uintptr_t)(*buffer), (void*)(uintptr_t)(*bufferMemory));
    return true;
}

/**
 * @brief Copies data from one buffer to another.
 * @param device Logical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param srcBuffer Source buffer.
 * @param dstBuffer Destination buffer.
 * @param size Size to copy.
 *
 * @todo Use DMA queues for better performance if available.
 */
void vk_buffer_copy(VkDevice device, VkCommandPool commandPool, VkQueue graphicsQueue,
                    VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size) {
    VkCommandBufferAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandPool = commandPool;
    allocInfo.commandBufferCount = 1;

    VkCommandBuffer commandBuffer;
    vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);

    VkCommandBufferBeginInfo beginInfo = {0};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    vkBeginCommandBuffer(commandBuffer, &beginInfo);

    VkBufferCopy copyRegion = {0};
    copyRegion.size = size;
    vkCmdCopyBuffer(commandBuffer, srcBuffer, dstBuffer, 1, &copyRegion);

    vkEndCommandBuffer(commandBuffer);

    // Vulkan 1.3 requirement: submit using vkQueueSubmit2
    VkCommandBufferSubmitInfo cmdSubmitInfo = {0};
    cmdSubmitInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    cmdSubmitInfo.commandBuffer = commandBuffer;
    cmdSubmitInfo.deviceMask = 0;

    VkSubmitInfo2 submitInfo2 = {0};
    submitInfo2.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    submitInfo2.commandBufferInfoCount = 1;
    submitInfo2.pCommandBufferInfos = &cmdSubmitInfo;

    vkQueueSubmit2(graphicsQueue, 1, &submitInfo2, VK_NULL_HANDLE);
    vkQueueWaitIdle(graphicsQueue);

    vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
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
                                   VkBuffer* buffer, VkDeviceMemory* bufferMemory) {
    if (!data || size == 0 || !allocator || !buffer || !bufferMemory) {
        CARDINAL_LOG_ERROR("Invalid parameters for staging buffer creation");
        return false;
    }

    // Create staging buffer (CPU-visible)
    VkBuffer stagingBuffer;
    VkDeviceMemory stagingBufferMemory;
    if (!vk_buffer_create(allocator, size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                              VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &stagingBuffer, &stagingBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create staging buffer");
        return false;
    }

    // Map staging buffer and copy data
    void* mappedData;
    if (vkMapMemory(device, stagingBufferMemory, 0, size, 0, &mappedData) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map staging buffer memory");
        vk_allocator_free_buffer(allocator, stagingBuffer, stagingBufferMemory);
        return false;
    }
    memcpy(mappedData, data, (size_t)size);
    vkUnmapMemory(device, stagingBufferMemory);

    // Create destination buffer (GPU-optimal)
    if (!vk_buffer_create(allocator, size, usage | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                          VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, buffer, bufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create destination buffer");
        vk_allocator_free_buffer(allocator, stagingBuffer, stagingBufferMemory);
        return false;
    }

    // Copy from staging to destination buffer
    vk_buffer_copy(device, commandPool, graphicsQueue, stagingBuffer, *buffer, size);

    // Clean up staging buffer
    vk_allocator_free_buffer(allocator, stagingBuffer, stagingBufferMemory);

    CARDINAL_LOG_DEBUG("Successfully created buffer with staging: size=%llu bytes, usage=0x%X",
                       (unsigned long long)size, usage);
    return true;
}
