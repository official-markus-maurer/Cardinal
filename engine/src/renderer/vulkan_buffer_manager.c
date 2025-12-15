#include "vulkan_buffer_manager.h"
#include "cardinal/core/log.h"
#include "vulkan_state.h"
#include <assert.h>
#include <string.h>

#ifdef _WIN32
    #include <windows.h>
#else
    #include <stdatomic.h>
#endif

/**
 * @brief Helper function to begin a single-time command buffer.
 */
static VkCommandBuffer begin_single_time_commands(VkDevice device, VkCommandPool commandPool) {
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
    return commandBuffer;
}

/**
 * @brief Helper function to end and submit a single-time command buffer with proper timeline
 * synchronization.
 */
static void end_single_time_commands(VkDevice device, VkCommandPool commandPool, VkQueue queue,
                                     VkCommandBuffer commandBuffer, VulkanState* vulkan_state) {
    CARDINAL_LOG_INFO("[BUFFER_MANAGER] CMD_END_START: Ending command buffer %p",
                      (void*)commandBuffer);
    VkResult result = vkEndCommandBuffer(commandBuffer);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[BUFFER_MANAGER] CMD_END_FAILED: Failed to end command buffer %p: %d",
                           (void*)commandBuffer, result);
        vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        return;
    }
    CARDINAL_LOG_INFO("[BUFFER_MANAGER] CMD_END_SUCCESS: Command buffer %p ended successfully",
                      (void*)commandBuffer);

    // Get current semaphore value first to ensure our value is always greater
    uint64_t current_value = 0;
    CARDINAL_LOG_INFO(
        "[BUFFER_MANAGER] SEMAPHORE_QUERY: Getting timeline semaphore value for cmd %p",
        (void*)commandBuffer);
    result = vulkan_state->context.vkGetSemaphoreCounterValue(
        vulkan_state->context.device, vulkan_state->sync.timeline_semaphore, &current_value);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[BUFFER_MANAGER] SEMAPHORE_QUERY_FAILED: Failed to get timeline "
                           "semaphore value for cmd %p: %d",
                           (void*)commandBuffer, result);
        vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        return;
    }
    CARDINAL_LOG_INFO(
        "[BUFFER_MANAGER] SEMAPHORE_QUERY_SUCCESS: Current timeline value=%llu for cmd %p",
        (unsigned long long)current_value, (void*)commandBuffer);

    // Use atomic increment starting from current semaphore value + 1
    // This ensures we always get a value greater than the current semaphore value
#ifdef _WIN32
    static volatile LONGLONG buffer_timeline_counter = 0;

    // Initialize counter if it's behind the current semaphore value
    LONGLONG counter_val = buffer_timeline_counter;
    if ((uint64_t)counter_val <= current_value) {
        InterlockedExchange64(&buffer_timeline_counter, (LONGLONG)(current_value + 1));
    }

    uint64_t timeline_value = (uint64_t)InterlockedIncrement64(&buffer_timeline_counter);
#else
    static atomic_uint_fast64_t buffer_timeline_counter = 0;

    // Initialize counter if it's behind the current semaphore value
    uint64_t counter_val = atomic_load(&buffer_timeline_counter);
    if (counter_val <= current_value) {
        atomic_store(&buffer_timeline_counter, current_value + 1);
    }

    uint64_t timeline_value = atomic_fetch_add(&buffer_timeline_counter, 1) + 1;
#endif

    // Handle overflow by resetting to current_value + 1
    if (timeline_value >= (UINT64_MAX - 10000)) {
        CARDINAL_LOG_WARN("[BUFFER_MANAGER] Timeline counter near overflow, resetting");
        timeline_value = current_value + 1;
#ifdef _WIN32
        InterlockedExchange64(&buffer_timeline_counter, (LONGLONG)(timeline_value + 1));
#else
        atomic_store(&buffer_timeline_counter, timeline_value + 1);
#endif
    }

    // Validate timeline semaphore before use
    if (vulkan_state->sync.timeline_semaphore == VK_NULL_HANDLE) {
        CARDINAL_LOG_ERROR("[BUFFER_MANAGER] Timeline semaphore is NULL!");
        vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        return;
    }

    // Ensure timeline value is never 0
    if (timeline_value == 0) {
        CARDINAL_LOG_ERROR("[BUFFER_MANAGER] Timeline value is 0! Forcing to 1");
        timeline_value = 1;
    }

    CARDINAL_LOG_DEBUG("[BUFFER_MANAGER] Using timeline value: %llu (current: %llu)",
                       timeline_value, current_value);

    // Submit command buffer with timeline semaphore signaling
    VkCommandBufferSubmitInfo cmd_buffer_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = commandBuffer};

    VkSemaphoreSubmitInfo signal_semaphore_info = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .semaphore = vulkan_state->sync.timeline_semaphore,
        .value = timeline_value,
        .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT};

    CARDINAL_LOG_DEBUG("[BUFFER_MANAGER] About to submit with semaphore %p, value %llu",
                       (void*)vulkan_state->sync.timeline_semaphore, timeline_value);

    VkSubmitInfo2 submit_info = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
                                 .commandBufferInfoCount = 1,
                                 .pCommandBufferInfos = &cmd_buffer_info,
                                 .signalSemaphoreInfoCount = 1,
                                 .pSignalSemaphoreInfos = &signal_semaphore_info};

    CARDINAL_LOG_INFO(
        "[BUFFER_MANAGER] CMD_SUBMIT: Submitting command buffer %p with timeline value %llu",
        (void*)commandBuffer, timeline_value);
    result = vulkan_state->context.vkQueueSubmit2(queue, 1, &submit_info, VK_NULL_HANDLE);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR(
            "[BUFFER_MANAGER] CMD_SUBMIT_FAILED: Failed to submit command buffer %p: %d",
            (void*)commandBuffer, result);
        CARDINAL_LOG_WARN("[BUFFER_MANAGER] CMD_LEAK_WARNING: Command buffer %p may leak due to "
                          "submit failure - cannot free while potentially in pending state",
                          (void*)commandBuffer);
        return;
    }
    CARDINAL_LOG_INFO(
        "[BUFFER_MANAGER] CMD_SUBMIT_SUCCESS: Command buffer %p submitted with timeline value %llu",
        (void*)commandBuffer, timeline_value);

    // Wait for completion using timeline semaphore with reasonable timeout
    VkSemaphoreWaitInfo wait_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                                     .semaphoreCount = 1,
                                     .pSemaphores = &vulkan_state->sync.timeline_semaphore,
                                     .pValues = &timeline_value};

    CARDINAL_LOG_INFO(
        "[BUFFER_MANAGER] CMD_WAIT: Waiting for command buffer %p completion (timeline value %llu)",
        (void*)commandBuffer, timeline_value);
    result = vulkan_state->context.vkWaitSemaphores(vulkan_state->context.device, &wait_info,
                                                    10000000000ULL); // 10 second timeout
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[BUFFER_MANAGER] CMD_WAIT_FAILED: Timeline semaphore wait failed for "
                           "cmd %p (timeline %llu): %d",
                           (void*)commandBuffer, timeline_value, result);
        CARDINAL_LOG_WARN("[BUFFER_MANAGER] CMD_LEAK_WARNING: Command buffer %p may leak due to "
                          "wait failure - cannot free while potentially in pending state",
                          (void*)commandBuffer);
        return;
    }
    CARDINAL_LOG_INFO(
        "[BUFFER_MANAGER] CMD_WAIT_SUCCESS: Command buffer %p completed (timeline value %llu)",
        (void*)commandBuffer, timeline_value);

    // Update VulkanState timeline tracking to maintain coordination
    // This ensures other systems know about the latest completed timeline value
    if (timeline_value > vulkan_state->sync.current_frame_value) {
        vulkan_state->sync.current_frame_value = timeline_value;
        CARDINAL_LOG_INFO(
            "[BUFFER_MANAGER] TIMELINE_UPDATE: Updated current_frame_value to %llu for cmd %p",
            timeline_value, (void*)commandBuffer);
    }

    // Free the command buffer after completion
    CARDINAL_LOG_INFO("[BUFFER_MANAGER] CMD_FREE: Freeing command buffer %p", (void*)commandBuffer);
    vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
    CARDINAL_LOG_INFO("[BUFFER_MANAGER] CMD_FREE_SUCCESS: Command buffer %p freed",
                      (void*)commandBuffer);

    CARDINAL_LOG_INFO("[BUFFER_MANAGER] CMD_COMPLETE: Buffer operation completed successfully with "
                      "timeline value %llu",
                      timeline_value);
}

bool vk_buffer_create(VulkanBuffer* buffer, VkDevice device, VulkanAllocator* allocator,
                      const VulkanBufferCreateInfo* createInfo) {
    if (!buffer || !device || !allocator || !createInfo) {
        CARDINAL_LOG_ERROR("Invalid parameters for buffer creation");
        return false;
    }

    if (createInfo->size == 0) {
        CARDINAL_LOG_ERROR("Buffer size cannot be zero");
        return false;
    }

    memset(buffer, 0, sizeof(VulkanBuffer));

    // Create buffer
    VkBufferCreateInfo bufferInfo = {0};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = createInfo->size;
    bufferInfo.usage = createInfo->usage;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    // Allocate buffer and memory using allocator
    if (!vk_allocator_allocate_buffer(allocator, &bufferInfo, &buffer->handle, &buffer->memory,
                                      createInfo->properties)) {
        CARDINAL_LOG_ERROR("Failed to create and allocate buffer");
        return false;
    }

    buffer->size = createInfo->size;
    buffer->usage = createInfo->usage;
    buffer->properties = createInfo->properties;
    buffer->mapped = NULL;

    // Map memory if requested
    if (createInfo->persistentlyMapped) {
        buffer->mapped = vk_buffer_map(buffer, device, 0, VK_WHOLE_SIZE);
        if (!buffer->mapped) {
            CARDINAL_LOG_WARN("Failed to persistently map buffer memory");
        }
    }

    CARDINAL_LOG_DEBUG("Created buffer with size %llu bytes", (unsigned long long)createInfo->size);
    return true;
}

static void wait_for_buffer_idle(VulkanBuffer* buffer, VkDevice device, VulkanState* vulkan_state) {
    if (vulkan_state && vulkan_state->sync.timeline_semaphore != VK_NULL_HANDLE) {
        uint64_t current_value = 0;
        CARDINAL_LOG_INFO(
            "[BUFFER_MANAGER] SYNC_CHECK: Getting timeline semaphore value for buffer=%p",
            (void*)buffer->handle);
        VkResult result = vulkan_state->context.vkGetSemaphoreCounterValue(
            vulkan_state->context.device, vulkan_state->sync.timeline_semaphore, &current_value);
        CARDINAL_LOG_INFO("[BUFFER_MANAGER] SYNC_VALUE: buffer=%p semaphore_value=%llu result=%d",
                          (void*)buffer->handle, (unsigned long long)current_value, result);

        if (result == VK_SUCCESS && current_value > 0) {
            // Wait for all submitted operations to complete
            VkSemaphoreWaitInfo wait_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                                             .semaphoreCount = 1,
                                             .pSemaphores = &vulkan_state->sync.timeline_semaphore,
                                             .pValues = &current_value};

            CARDINAL_LOG_INFO("[BUFFER_MANAGER] SYNC_WAIT: Waiting for timeline semaphore value "
                              "%llu for buffer=%p",
                              (unsigned long long)current_value, (void*)buffer->handle);
            result = vulkan_state->context.vkWaitSemaphores(
                vulkan_state->context.device, &wait_info, 5000000000ULL); // 5 second timeout
            if (result != VK_SUCCESS) {
                CARDINAL_LOG_ERROR("[BUFFER_MANAGER] SYNC_FAILED: Timeline semaphore wait failed "
                                   "for buffer=%p: %d, falling back to device wait idle",
                                   (void*)buffer->handle, result);
                VkResult idle_result = vkDeviceWaitIdle(device);
                CARDINAL_LOG_INFO("[BUFFER_MANAGER] DEVICE_WAIT_IDLE: result=%d for buffer=%p",
                                  idle_result, (void*)buffer->handle);
            } else {
                CARDINAL_LOG_INFO("[BUFFER_MANAGER] SYNC_SUCCESS: Timeline semaphore wait "
                                  "completed for buffer=%p",
                                  (void*)buffer->handle);
            }
        } else {
            // Fallback to device wait idle if timeline semaphore query fails
            CARDINAL_LOG_WARN("[BUFFER_MANAGER] SYNC_FALLBACK: Failed to get timeline semaphore "
                              "value (result=%d, value=%llu), using device wait idle for buffer=%p",
                              result, (unsigned long long)current_value, (void*)buffer->handle);
            VkResult idle_result = vkDeviceWaitIdle(device);
            CARDINAL_LOG_INFO("[BUFFER_MANAGER] DEVICE_WAIT_IDLE: result=%d for buffer=%p",
                              idle_result, (void*)buffer->handle);
        }
    } else {
        // Fallback to device wait idle if no timeline semaphore available
        CARDINAL_LOG_WARN(
            "[BUFFER_MANAGER] NO_TIMELINE_SEMAPHORE: Using device wait idle for buffer=%p",
            (void*)buffer->handle);
        VkResult idle_result = vkDeviceWaitIdle(device);
        CARDINAL_LOG_INFO("[BUFFER_MANAGER] DEVICE_WAIT_IDLE: result=%d for buffer=%p", idle_result,
                          (void*)buffer->handle);
    }
}

static void cleanup_buffer_resources(VulkanBuffer* buffer, VkDevice device,
                                     VulkanAllocator* allocator) {
    // Unmap if mapped
    if (buffer->mapped) {
        CARDINAL_LOG_INFO("[BUFFER_MANAGER] UNMAP: Unmapping buffer=%p", (void*)buffer->handle);
        vk_buffer_unmap(buffer, device);
        CARDINAL_LOG_INFO("[BUFFER_MANAGER] UNMAPPED: buffer=%p", (void*)buffer->handle);
    }

    // Free buffer and memory
    CARDINAL_LOG_INFO("[BUFFER_MANAGER] FREE_START: About to free buffer=%p memory=%p",
                      (void*)buffer->handle, (void*)buffer->memory);
    vk_allocator_free_buffer(allocator, buffer->handle, buffer->memory);
    CARDINAL_LOG_INFO("[BUFFER_MANAGER] FREE_COMPLETE: Freed buffer=%p memory=%p",
                      (void*)buffer->handle, (void*)buffer->memory);

    // Clear structure
    memset(buffer, 0, sizeof(VulkanBuffer));
}

void vk_buffer_destroy(VulkanBuffer* buffer, VkDevice device, VulkanAllocator* allocator,
                       VulkanState* vulkan_state) {
    if (!buffer || buffer->handle == VK_NULL_HANDLE) {
        CARDINAL_LOG_WARN("[BUFFER_MANAGER] DESTROY_SKIP: Invalid buffer or null handle");
        return;
    }

    CARDINAL_LOG_INFO("[BUFFER_MANAGER] DESTROY_START: buffer=%p handle=%p memory=%p mapped=%p",
                      (void*)buffer, (void*)buffer->handle, (void*)buffer->memory, buffer->mapped);

    // Wait for buffer to be idle
    wait_for_buffer_idle(buffer, device, vulkan_state);

    // Cleanup resources
    cleanup_buffer_resources(buffer, device, allocator);

    CARDINAL_LOG_INFO("[BUFFER_MANAGER] DESTROY_COMPLETE: Buffer structure cleared");
}

bool vk_buffer_upload_data(VulkanBuffer* buffer, VkDevice device, const void* data,
                           VkDeviceSize size, VkDeviceSize offset) {
    if (!buffer || !data || buffer->handle == VK_NULL_HANDLE) {
        CARDINAL_LOG_ERROR("Invalid parameters for buffer data upload");
        return false;
    }

    if (offset + size > buffer->size) {
        CARDINAL_LOG_ERROR("Upload data exceeds buffer size");
        return false;
    }

    // Check if buffer is host visible
    if (!(buffer->properties & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
        CARDINAL_LOG_ERROR("Buffer is not host visible, cannot upload data directly");
        return false;
    }

    void* mappedData;
    if (buffer->mapped) {
        // Use existing mapping
        mappedData = (char*)buffer->mapped + offset;
        memcpy(mappedData, data, size);
    } else {
        // Temporary mapping
        if (vkMapMemory(device, buffer->memory, offset, size, 0, &mappedData) != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("Failed to map buffer memory for data upload");
            return false;
        }

        memcpy(mappedData, data, size);
        vkUnmapMemory(device, buffer->memory);
    }

    // Flush if memory is not coherent
    if (!(buffer->properties & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
        VkMappedMemoryRange range = {0};
        range.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        range.memory = buffer->memory;
        range.offset = offset;
        range.size = size;
        vkFlushMappedMemoryRanges(device, 1, &range);
    }

    return true;
}

void* vk_buffer_map(VulkanBuffer* buffer, VkDevice device, VkDeviceSize offset, VkDeviceSize size) {
    if (!buffer || buffer->handle == VK_NULL_HANDLE) {
        CARDINAL_LOG_ERROR("Invalid buffer for mapping");
        return NULL;
    }

    if (!(buffer->properties & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
        CARDINAL_LOG_ERROR("Buffer is not host visible, cannot map");
        return NULL;
    }

    void* mappedData;
    if (vkMapMemory(device, buffer->memory, offset, size, 0, &mappedData) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map buffer memory");
        return NULL;
    }

    if (!buffer->mapped && size == VK_WHOLE_SIZE) {
        buffer->mapped = mappedData;
    }

    return mappedData;
}

void vk_buffer_unmap(VulkanBuffer* buffer, VkDevice device) {
    if (!buffer || buffer->handle == VK_NULL_HANDLE) {
        return;
    }

    if (buffer->mapped) {
        vkUnmapMemory(device, buffer->memory);
        buffer->mapped = NULL;
    }
}

bool vk_buffer_create_device_local(VulkanBuffer* buffer, VkDevice device,
                                   VulkanAllocator* allocator, VkCommandPool commandPool,
                                   VkQueue queue, const void* data, VkDeviceSize size,
                                   VkBufferUsageFlags usage, VulkanState* vulkan_state) {
    if (!data || size == 0) {
        return false;
    }

    // Create staging buffer
    VulkanBufferCreateInfo stagingInfo = {0};
    stagingInfo.size = size;
    stagingInfo.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    stagingInfo.properties =
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    stagingInfo.persistentlyMapped = false;

    VulkanBuffer stagingBuffer;
    if (!vk_buffer_create(&stagingBuffer, device, allocator, &stagingInfo)) {
        CARDINAL_LOG_ERROR("Failed to create staging buffer");
        return false;
    }

    // Upload data to staging buffer
    if (!vk_buffer_upload_data(&stagingBuffer, device, data, size, 0)) {
        CARDINAL_LOG_ERROR("Failed to upload data to staging buffer");
        vk_buffer_destroy(&stagingBuffer, device, allocator, vulkan_state);
        return false;
    }

    // Create device local buffer
    VulkanBufferCreateInfo deviceBufferInfo = {0};
    deviceBufferInfo.size = size;
    deviceBufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | usage;
    deviceBufferInfo.properties = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    deviceBufferInfo.persistentlyMapped = false;

    if (!vk_buffer_create(buffer, device, allocator, &deviceBufferInfo)) {
        CARDINAL_LOG_ERROR("Failed to create device local buffer");
        vk_buffer_destroy(&stagingBuffer, device, allocator, vulkan_state);
        return false;
    }

    // Copy from staging to device buffer
    if (!vk_buffer_copy(device, commandPool, queue, stagingBuffer.handle, buffer->handle, size, 0,
                        0, vulkan_state)) {
        CARDINAL_LOG_ERROR("Failed to copy data to device buffer");
        vk_buffer_destroy(buffer, device, allocator, vulkan_state);
        vk_buffer_destroy(&stagingBuffer, device, allocator, vulkan_state);
        return false;
    }

    // Clean up staging buffer
    vk_buffer_destroy(&stagingBuffer, device, allocator, vulkan_state);

    return true;
}

bool vk_buffer_create_vertex(VulkanBuffer* buffer, VkDevice device, VulkanAllocator* allocator,
                             VkCommandPool commandPool, VkQueue queue, const void* vertices,
                             VkDeviceSize vertexSize, VulkanState* vulkan_state) {
    if (!vertices || vertexSize == 0) {
        CARDINAL_LOG_ERROR("Invalid vertex data for buffer creation");
        return false;
    }

    if (!vk_buffer_create_device_local(buffer, device, allocator, commandPool, queue, vertices,
                                       vertexSize, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                                       vulkan_state)) {
        CARDINAL_LOG_ERROR("Failed to create vertex buffer");
        return false;
    }

    CARDINAL_LOG_DEBUG("Created vertex buffer with %llu bytes", (unsigned long long)vertexSize);
    return true;
}

bool vk_buffer_create_index(VulkanBuffer* buffer, VkDevice device, VulkanAllocator* allocator,
                            VkCommandPool commandPool, VkQueue queue, const void* indices,
                            VkDeviceSize indexSize, VulkanState* vulkan_state) {
    if (!indices || indexSize == 0) {
        CARDINAL_LOG_ERROR("Invalid index data for buffer creation");
        return false;
    }

    if (!vk_buffer_create_device_local(buffer, device, allocator, commandPool, queue, indices,
                                       indexSize, VK_BUFFER_USAGE_INDEX_BUFFER_BIT, vulkan_state)) {
        CARDINAL_LOG_ERROR("Failed to create index buffer");
        return false;
    }

    CARDINAL_LOG_DEBUG("Created index buffer with %llu bytes", (unsigned long long)indexSize);
    return true;
}

bool vk_buffer_create_uniform(VulkanBuffer* buffer, VkDevice device, VulkanAllocator* allocator,
                              VkDeviceSize size) {
    if (size == 0) {
        CARDINAL_LOG_ERROR("Uniform buffer size cannot be zero");
        return false;
    }

    VulkanBufferCreateInfo uniformInfo = {0};
    uniformInfo.size = size;
    uniformInfo.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    uniformInfo.properties =
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uniformInfo.persistentlyMapped = true;

    if (!vk_buffer_create(buffer, device, allocator, &uniformInfo)) {
        CARDINAL_LOG_ERROR("Failed to create uniform buffer");
        return false;
    }

    CARDINAL_LOG_DEBUG("Created uniform buffer with %llu bytes", (unsigned long long)size);
    return true;
}

bool vk_buffer_copy(VkDevice device, VkCommandPool commandPool, VkQueue queue, VkBuffer srcBuffer,
                    VkBuffer dstBuffer, VkDeviceSize size, VkDeviceSize srcOffset,
                    VkDeviceSize dstOffset, VulkanState* vulkan_state) {
    if (srcBuffer == VK_NULL_HANDLE || dstBuffer == VK_NULL_HANDLE || size == 0) {
        CARDINAL_LOG_ERROR("Invalid parameters for buffer copy");
        return false;
    }

    VkCommandBuffer commandBuffer = begin_single_time_commands(device, commandPool);
    if (commandBuffer == VK_NULL_HANDLE) {
        CARDINAL_LOG_ERROR("Failed to begin command buffer for buffer copy");
        return false;
    }

    VkBufferCopy copyRegion = {0};
    copyRegion.srcOffset = srcOffset;
    copyRegion.dstOffset = dstOffset;
    copyRegion.size = size;

    vkCmdCopyBuffer(commandBuffer, srcBuffer, dstBuffer, 1, &copyRegion);

    end_single_time_commands(device, commandPool, queue, commandBuffer, vulkan_state);

    return true;
}
