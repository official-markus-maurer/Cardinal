#include "../vulkan_buffer_manager.h"
#include "../vulkan_state.h"
#include <cardinal/core/log.h>
#include <cardinal/renderer/util/vulkan_buffer_utils.h>
#include <cardinal/renderer/util/vulkan_texture_utils.h>
#include <cardinal/renderer/vulkan_barrier_validation.h>
#include <cardinal/renderer/vulkan_sync_manager.h>
#include <stdlib.h>
#include <string.h>

// Structure to track staging buffers for deferred cleanup
typedef struct StagingBufferCleanup {
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkDevice device;
    uint64_t timeline_value;
    struct StagingBufferCleanup* next;
} StagingBufferCleanup;

// Global list of staging buffers awaiting cleanup
static StagingBufferCleanup* g_pending_cleanups = NULL;
static bool g_cleanup_system_initialized = false;

#ifdef _WIN32
    #include <windows.h>
#else
    #include <sys/syscall.h>
    #include <unistd.h>
#endif

// Helper function to get current thread ID
static uint32_t get_current_thread_id(void) {
#ifdef _WIN32
    return GetCurrentThreadId();
#else
    return (uint32_t)syscall(SYS_gettid);
#endif
}

// Add staging buffer to deferred cleanup list
static void add_staging_buffer_cleanup(VkBuffer buffer, VkDeviceMemory memory, VkDevice device,
                                       uint64_t timeline_value) {
    StagingBufferCleanup* cleanup = (StagingBufferCleanup*)malloc(sizeof(StagingBufferCleanup));
    if (!cleanup) {
        CARDINAL_LOG_ERROR(
            "[TEXTURE_UTILS] Failed to allocate cleanup tracking, immediate cleanup");
        vkDestroyBuffer(device, buffer, NULL);
        vkFreeMemory(device, memory, NULL);
        return;
    }

    cleanup->buffer = buffer;
    cleanup->memory = memory;
    cleanup->device = device;
    cleanup->timeline_value = timeline_value;
    cleanup->next = g_pending_cleanups;
    g_pending_cleanups = cleanup;
    g_cleanup_system_initialized = true;

    CARDINAL_LOG_DEBUG(
        "[TEXTURE_UTILS] Added staging buffer %p to deferred cleanup (timeline: %llu)",
        (void*)buffer, timeline_value);
}

// Process completed staging buffer cleanups
static void process_staging_buffer_cleanups(VulkanSyncManager* sync_manager) {
    if (!g_cleanup_system_initialized || !sync_manager) {
        return;
    }

    StagingBufferCleanup** current = &g_pending_cleanups;
    while (*current) {
        StagingBufferCleanup* cleanup = *current;

        // Check if this timeline value has completed
        bool reached = false;
        if (vulkan_sync_manager_is_timeline_value_reached(sync_manager, cleanup->timeline_value,
                                                          &reached) == VK_SUCCESS &&
            reached) {
            CARDINAL_LOG_DEBUG(
                "[TEXTURE_UTILS] Cleaning up completed staging buffer %p (timeline: %llu)",
                (void*)cleanup->buffer, cleanup->timeline_value);

            vkDestroyBuffer(cleanup->device, cleanup->buffer, NULL);
            vkFreeMemory(cleanup->device, cleanup->memory, NULL);

            // Remove from list
            *current = cleanup->next;
            free(cleanup);
        } else {
            current = &cleanup->next;
        }
    }
}

static bool create_staging_buffer_with_data(VulkanAllocator* allocator, VkDevice device,
                                            const CardinalTexture* texture,
                                            VkBuffer* outStagingBuffer,
                                            VkDeviceMemory* outStagingMemory) {
    VkDeviceSize imageSize = texture->width * texture->height * 4; // Always RGBA

    // Create staging buffer
    VulkanBuffer stagingBufferObj = {0};
    VulkanBufferCreateInfo stagingCreateInfo = {.size = imageSize,
                                                .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                                .properties = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                              VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                                .persistentlyMapped = true};

    if (!vk_buffer_create(&stagingBufferObj, device, allocator, &stagingCreateInfo)) {
        CARDINAL_LOG_ERROR("Failed to create staging buffer for texture");
        return false;
    }

    *outStagingBuffer = stagingBufferObj.handle;
    *outStagingMemory = stagingBufferObj.memory;
    void* data = stagingBufferObj.mapped;

    if (texture->channels == 4) {
        memcpy(data, texture->data, imageSize);
    } else if (texture->channels == 3) {
        unsigned char* src = (unsigned char*)texture->data;
        unsigned char* dst = (unsigned char*)data;
        for (uint32_t i = 0; i < texture->width * texture->height; i++) {
            dst[i * 4 + 0] = src[i * 3 + 0]; // R
            dst[i * 4 + 1] = src[i * 3 + 1]; // G
            dst[i * 4 + 2] = src[i * 3 + 2]; // B
            dst[i * 4 + 3] = 255;            // A
        }
    } else {
        CARDINAL_LOG_ERROR("Unsupported texture channel count: %d", texture->channels);
        vkDestroyBuffer(device, *outStagingBuffer, NULL);
        vkFreeMemory(device, *outStagingMemory, NULL);
        return false;
    }

    return true;
}

static bool create_image_and_memory(VulkanAllocator* allocator, VkDevice device, uint32_t width,
                                    uint32_t height, VkImage* outImage, VkDeviceMemory* outMemory) {
    VkImageCreateInfo imageInfo = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .extent.width = width,
        .extent.height = height,
        .extent.depth = 1,
        .mipLevels = 1,
        .arrayLayers = 1,
        .format = VK_FORMAT_R8G8B8A8_SRGB,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };

    if (vkCreateImage(device, &imageInfo, NULL, outImage) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create texture image");
        return false;
    }

    VkMemoryRequirements memRequirements;
    vkGetImageMemoryRequirements(device, *outImage, &memRequirements);

    VkMemoryAllocateInfo allocInfo = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = memRequirements.size,
        .memoryTypeIndex =
            vk_buffer_find_memory_type(allocator->physical_device, memRequirements.memoryTypeBits,
                                       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};

    if (vkAllocateMemory(device, &allocInfo, NULL, outMemory) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate texture image memory");
        vkDestroyImage(device, *outImage, NULL);
        return false;
    }

    vkBindImageMemory(device, *outImage, *outMemory, 0);
    return true;
}

static void record_texture_copy_commands(VkCommandBuffer commandBuffer, VkBuffer stagingBuffer,
                                         VkImage textureImage, uint32_t width, uint32_t height) {
    VkCommandBufferBeginInfo beginInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vkBeginCommandBuffer(commandBuffer, &beginInfo);

    VkImageMemoryBarrier2 barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
        .srcAccessMask = 0,
        .dstStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT,
        .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = textureImage,
        .subresourceRange = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                             .baseMipLevel = 0,
                             .levelCount = 1,
                             .baseArrayLayer = 0,
                             .layerCount = 1}
    };

    VkDependencyInfo dependencyInfo = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    };

    uint32_t thread_id = get_current_thread_id();
    if (!cardinal_barrier_validation_validate_pipeline_barrier(&dependencyInfo, commandBuffer,
                                                               thread_id)) {
        CARDINAL_LOG_WARN("Pipeline barrier validation failed for texture transfer transition");
    }

    vkCmdPipelineBarrier2(commandBuffer, &dependencyInfo);

    VkBufferImageCopy region = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                             .mipLevel = 0,
                             .baseArrayLayer = 0,
                             .layerCount = 1},
        .imageOffset = {0, 0, 0},
        .imageExtent = {width, height, 1}
    };

    vkCmdCopyBufferToImage(commandBuffer, stagingBuffer, textureImage,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    barrier.srcStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier.dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    barrier.dstAccessMask = VK_ACCESS_2_SHADER_READ_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    if (!cardinal_barrier_validation_validate_pipeline_barrier(&dependencyInfo, commandBuffer,
                                                               thread_id)) {
        CARDINAL_LOG_WARN("Pipeline barrier validation failed for texture shader read transition");
    }

    vkCmdPipelineBarrier2(commandBuffer, &dependencyInfo);
    vkEndCommandBuffer(commandBuffer);
}

static bool submit_texture_upload(VkDevice device, VkQueue graphicsQueue,
                                  VkCommandBuffer commandBuffer, VulkanSyncManager* sync_manager,
                                  uint64_t* outTimelineValue) {
    VkCommandBufferSubmitInfo cmdBufSubmitInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .commandBuffer = commandBuffer,
    };

    VkSubmitInfo2 submitInfo = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmdBufSubmitInfo,
    };

    if (sync_manager) {
        uint64_t timeline_value = vulkan_sync_manager_get_next_timeline_value(sync_manager);
        if (outTimelineValue)
            *outTimelineValue = timeline_value;

        VkSemaphoreSubmitInfo signal_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                                             .semaphore = sync_manager->timeline_semaphore,
                                             .value = timeline_value,
                                             .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT};

        submitInfo.signalSemaphoreInfoCount = 1;
        submitInfo.pSignalSemaphoreInfos = &signal_info;

        VkFence uploadFence = VK_NULL_HANDLE;
        VkFenceCreateInfo fenceInfo = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        if (vkCreateFence(device, &fenceInfo, NULL, &uploadFence) != VK_SUCCESS) {
            return false;
        }

        if (vkQueueSubmit2(graphicsQueue, 1, &submitInfo, uploadFence) != VK_SUCCESS) {
            vkDestroyFence(device, uploadFence, NULL);
            return false;
        }

        if (vkWaitForFences(device, 1, &uploadFence, VK_TRUE, 5000000000ULL) != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("Texture upload fence wait failed or timed out");
        }
        vkDestroyFence(device, uploadFence, NULL);

        VkSemaphoreWaitInfo waitInfo = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                                        .semaphoreCount = 1,
                                        .pSemaphores = &sync_manager->timeline_semaphore,
                                        .pValues = &timeline_value};
        vkWaitSemaphores(device, &waitInfo, UINT64_MAX);
    } else {
        if (vkQueueSubmit2(graphicsQueue, 1, &submitInfo, VK_NULL_HANDLE) != VK_SUCCESS) {
            return false;
        }
        vkQueueWaitIdle(graphicsQueue);
    }
    return true;
}

static bool create_texture_image_view(VkDevice device, VkImage image, VkImageView* outImageView) {
    VkImageViewCreateInfo viewInfo = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_SRGB,
        .subresourceRange = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                             .baseMipLevel = 0,
                             .levelCount = 1,
                             .baseArrayLayer = 0,
                             .layerCount = 1}
    };

    if (vkCreateImageView(device, &viewInfo, NULL, outImageView) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create texture image view");
        return false;
    }
    return true;
}

bool vk_texture_create_from_data(VulkanAllocator* allocator, VkDevice device,
                                 VkCommandPool commandPool, VkQueue graphicsQueue,
                                 VulkanSyncManager* sync_manager, const CardinalTexture* texture,
                                 VkImage* textureImage, VkDeviceMemory* textureImageMemory,
                                 VkImageView* textureImageView, uint64_t* outTimelineValue) {
    if (!texture || !texture->data || !textureImage || !textureImageMemory || !textureImageView) {
        CARDINAL_LOG_ERROR("Invalid parameters for texture creation");
        return false;
    }

    VkBuffer stagingBuffer;
    VkDeviceMemory stagingBufferMemory;
    if (!create_staging_buffer_with_data(allocator, device, texture, &stagingBuffer,
                                         &stagingBufferMemory)) {
        return false;
    }

    if (!create_image_and_memory(allocator, device, texture->width, texture->height, textureImage,
                                 textureImageMemory)) {
        vkDestroyBuffer(device, stagingBuffer, NULL);
        vkFreeMemory(device, stagingBufferMemory, NULL);
        return false;
    }

    VkCommandBufferAllocateInfo allocInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = commandPool,
        .commandBufferCount = 1,
    };

    VkCommandBuffer commandBuffer;
    vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);

    record_texture_copy_commands(commandBuffer, stagingBuffer, *textureImage, texture->width,
                                 texture->height);

    if (!submit_texture_upload(device, graphicsQueue, commandBuffer, sync_manager,
                               outTimelineValue)) {
        CARDINAL_LOG_ERROR("Failed to submit texture upload");
        vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        vkDestroyBuffer(device, stagingBuffer, NULL);
        vkFreeMemory(device, stagingBufferMemory, NULL);
        vkDestroyImage(device, *textureImage, NULL);
        vkFreeMemory(device, *textureImageMemory, NULL);
        return false;
    }

    vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);

    if (sync_manager && outTimelineValue) {
        add_staging_buffer_cleanup(stagingBuffer, stagingBufferMemory, device, *outTimelineValue);
        process_staging_buffer_cleanups(sync_manager);
    } else {
        vkDestroyBuffer(device, stagingBuffer, NULL);
        vkFreeMemory(device, stagingBufferMemory, NULL);
    }

    if (!create_texture_image_view(device, *textureImage, textureImageView)) {
        vkDestroyImage(device, *textureImage, NULL);
        vkFreeMemory(device, *textureImageMemory, NULL);
        return false;
    }

    return true;
}

bool vk_texture_create_placeholder(VulkanAllocator* allocator, VkDevice device,
                                   VkCommandPool commandPool, VkQueue graphicsQueue,
                                   VkImage* textureImage, VkDeviceMemory* textureImageMemory,
                                   VkImageView* textureImageView, const VkFormat* format) {
    (void)format; // Unused parameter
    // Create 1x1 white texture data
    unsigned char whitePixel[4] = {255, 255, 255, 255};

    CardinalTexture placeholderTexture = {
        .data = whitePixel, .width = 1, .height = 1, .channels = 4, .path = "placeholder"};

    return vk_texture_create_from_data(allocator, device, commandPool, graphicsQueue, NULL,
                                       &placeholderTexture, textureImage, textureImageMemory,
                                       textureImageView, NULL);
}

bool vk_texture_create_sampler(VkDevice device, VkPhysicalDevice physicalDevice,
                               VkSampler* sampler) {
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(physicalDevice, &properties);

    VkSamplerCreateInfo samplerInfo = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_LINEAR,
        .minFilter = VK_FILTER_LINEAR,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .anisotropyEnable = VK_TRUE,
        .maxAnisotropy = properties.limits.maxSamplerAnisotropy,
        .borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = VK_FALSE,
        .compareEnable = VK_FALSE,
        .compareOp = VK_COMPARE_OP_ALWAYS,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .mipLodBias = 0.0f,
        .minLod = 0.0f,
        .maxLod = 0.0f,
    };

    if (vkCreateSampler(device, &samplerInfo, NULL, sampler) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create texture sampler");
        return false;
    }

    return true;
}
