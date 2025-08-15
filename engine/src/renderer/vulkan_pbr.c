#include <cardinal/renderer/vulkan_pbr.h>
#include <cardinal/core/log.h>
#include "vulkan_state.h"
#include <string.h>
#include <stdlib.h>

// Helper function to find memory type
/**
 * @brief Finds a suitable memory type index.
 * @param physicalDevice Physical device.
 * @param typeFilter Memory type filter.
 * @param properties Required memory properties.
 * @return Memory type index or UINT32_MAX on failure.
 * 
 * @todo Cache memory properties for performance.
 */
__attribute__((unused)) static uint32_t findMemoryType(VkPhysicalDevice physicalDevice, uint32_t typeFilter, VkMemoryPropertyFlags properties) {
    VkPhysicalDeviceMemoryProperties memProperties;
    vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProperties);
    
    CARDINAL_LOG_DEBUG("Searching for memory type: typeFilter=0x%X, properties=0x%X, available types=%u", 
                      typeFilter, properties, memProperties.memoryTypeCount);
    
    for (uint32_t i = 0; i < memProperties.memoryTypeCount; i++) {
        bool typeMatches = (typeFilter & (1 << i)) != 0;
        bool propertiesMatch = (memProperties.memoryTypes[i].propertyFlags & properties) == properties;
        
        CARDINAL_LOG_DEBUG("  Type %u: heap=%u, flags=0x%X, typeMatch=%s, propMatch=%s", 
                          i, memProperties.memoryTypes[i].heapIndex, 
                          memProperties.memoryTypes[i].propertyFlags,
                          typeMatches ? "yes" : "no", propertiesMatch ? "yes" : "no");
        
        if (typeMatches && propertiesMatch) {
            CARDINAL_LOG_DEBUG("Found suitable memory type: index=%u, heap=%u, size=%llu MB", 
                              i, memProperties.memoryTypes[i].heapIndex,
                              memProperties.memoryHeaps[memProperties.memoryTypes[i].heapIndex].size / (1024 * 1024));
            return i;
        }
    }
    
    CARDINAL_LOG_ERROR("Failed to find suitable memory type! typeFilter=0x%X, properties=0x%X", typeFilter, properties);
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
static bool createBuffer(VulkanAllocator* allocator, VkDeviceSize size,
                        VkBufferUsageFlags usage, VkMemoryPropertyFlags properties,
                        VkBuffer* buffer, VkDeviceMemory* bufferMemory);

__attribute__((unused))
/**
 * @brief Creates a Vulkan texture from CardinalTexture data.
 * @param device Logical device.
 * @param physicalDevice Physical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param texture Input texture data.
 * @param textureImage Output image handle.
 * @param textureImageMemory Output memory handle.
 * @param textureImageView Output image view handle.
 * @return true on success, false on failure.
 * 
 * @todo Implement mipmapping generation.
 * @todo Support asynchronous texture loading.
 */
static bool createTextureFromData(VulkanAllocator* allocator, VkDevice device,
                                 VkCommandPool commandPool, VkQueue graphicsQueue,
                                 const CardinalTexture* texture, 
                                 VkImage* textureImage, VkDeviceMemory* textureImageMemory,
                                 VkImageView* textureImageView) {
    if (!texture || !texture->data || texture->width == 0 || texture->height == 0) {
        CARDINAL_LOG_ERROR("Invalid texture data");
        return false;
    }
    if (!allocator) {
        CARDINAL_LOG_ERROR("Allocator is null in createTextureFromData");
        return false;
    }
    
    CARDINAL_LOG_DEBUG("Creating texture from data: %ux%u, channels=%d", texture->width, texture->height, texture->channels);

    const VkFormat format = VK_FORMAT_R8G8B8A8_SRGB;
    VkDeviceSize imageSize = texture->width * texture->height * 4; // Force RGBA
    
    // Create staging buffer
    VkBuffer stagingBuffer;
    VkDeviceMemory stagingBufferMemory;
    
    if (!createBuffer(allocator, imageSize,
                     VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &stagingBuffer, &stagingBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create staging buffer for texture upload (size=%llu)", (unsigned long long)imageSize);
        return false;
    }
    
    void* data;
    VkResult mapResult = vkMapMemory(device, stagingBufferMemory, 0, imageSize, 0, &data);
    if (mapResult != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map staging buffer memory for texture: %d", mapResult);
        vk_allocator_free_buffer(allocator, stagingBuffer, stagingBufferMemory);
        return false;
    }
    CARDINAL_LOG_DEBUG("Staging buffer mapped for texture data copy");
    
    // If texture has different channel count, we need to convert to RGBA
    if (texture->channels == 4) {
        memcpy(data, texture->data, (size_t)imageSize);
    } else {
        // Convert to RGBA
        unsigned char* src = texture->data;
        unsigned char* dst = (unsigned char*)data;
        
        for (uint32_t i = 0; i < texture->width * texture->height; i++) {
            if (texture->channels == 3) {
                dst[i * 4 + 0] = src[i * 3 + 0]; // R
                dst[i * 4 + 1] = src[i * 3 + 1]; // G
                dst[i * 4 + 2] = src[i * 3 + 2]; // B
                dst[i * 4 + 3] = 255;            // A
            } else if (texture->channels == 1) {
                dst[i * 4 + 0] = src[i];  // R
                dst[i * 4 + 1] = src[i];  // G
                dst[i * 4 + 2] = src[i];  // B
                dst[i * 4 + 3] = 255;     // A
            } else {
                // Unsupported channel count, fill with white
                dst[i * 4 + 0] = 255;
                dst[i * 4 + 1] = 255;
                dst[i * 4 + 2] = 255;
                dst[i * 4 + 3] = 255;
            }
        }
    }
    
    vkUnmapMemory(device, stagingBufferMemory);
    CARDINAL_LOG_DEBUG("Staging buffer unmapped; proceeding to create VkImage");
    
    // Create image
    VkImageCreateInfo imageInfo = {0};
    imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = texture->width;
    imageInfo.extent.height = texture->height;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = format;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    
    // Allocate image and memory via allocator
    if (!vk_allocator_allocate_image(allocator, &imageInfo, textureImage, textureImageMemory, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
        CARDINAL_LOG_ERROR("Allocator failed to create/allocate texture image (%ux%u)", texture->width, texture->height);
        vk_allocator_free_buffer(allocator, stagingBuffer, stagingBufferMemory);
        return false;
    }
    CARDINAL_LOG_DEBUG("Texture image allocated via allocator: image=%p memory=%p", (void*)(uintptr_t)(*textureImage), (void*)(uintptr_t)(*textureImageMemory));
    
    // Copy buffer to image with proper layout transitions
    VkCommandBufferAllocateInfo allocInfo2 = {0};
    allocInfo2.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo2.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo2.commandPool = commandPool;
    allocInfo2.commandBufferCount = 1;
    
    VkCommandBuffer commandBuffer;
    vkAllocateCommandBuffers(device, &allocInfo2, &commandBuffer);
    CARDINAL_LOG_DEBUG("Allocated command buffer for placeholder upload: cmd=%p", (void*)(uintptr_t)commandBuffer);
    
    VkCommandBufferBeginInfo beginInfo = {0};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    
    vkBeginCommandBuffer(commandBuffer, &beginInfo);
    CARDINAL_LOG_DEBUG("Began command buffer for placeholder upload");
    
    // Vulkan 1.3 sync2 requirement - no fallbacks
    CARDINAL_LOG_DEBUG("Using vkCmdPipelineBarrier2 for pipeline barriers in texture upload");
    
    // Transition to transfer destination
    VkImageMemoryBarrier2 barrier2 = {0};
    barrier2.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier2.srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
    barrier2.srcAccessMask = 0;
    barrier2.dstStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier2.dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier2.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier2.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier2.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier2.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier2.image = *textureImage;
    barrier2.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier2.subresourceRange.baseMipLevel = 0;
    barrier2.subresourceRange.levelCount = 1;
    barrier2.subresourceRange.baseArrayLayer = 0;
    barrier2.subresourceRange.layerCount = 1;

    VkDependencyInfo dep = {0};
    dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &barrier2;
    vkCmdPipelineBarrier2(commandBuffer, &dep);
    
    VkBufferImageCopy region = {0};
    region.bufferOffset = 0;
    region.bufferRowLength = 0;
    region.bufferImageHeight = 0;
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel = 0;
    region.imageSubresource.baseArrayLayer = 0;
    region.imageSubresource.layerCount = 1;
    region.imageOffset.x = 0;
    region.imageOffset.y = 0;
    region.imageOffset.z = 0;
    region.imageExtent.width = texture->width;
    region.imageExtent.height = texture->height;
    region.imageExtent.depth = 1;
    
    vkCmdCopyBufferToImage(commandBuffer, stagingBuffer, *textureImage,
                          VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    
    // Transition to shader read
    VkImageMemoryBarrier2 barrier3 = {0};
    barrier3.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier3.srcStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier3.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier3.dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    barrier3.dstAccessMask = VK_ACCESS_2_SHADER_READ_BIT;
    barrier3.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier3.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier3.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier3.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier3.image = *textureImage;
    barrier3.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier3.subresourceRange.baseMipLevel = 0;
    barrier3.subresourceRange.levelCount = 1;
    barrier3.subresourceRange.baseArrayLayer = 0;
    barrier3.subresourceRange.layerCount = 1;

    VkDependencyInfo dep2 = {0};
    dep2.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep2.imageMemoryBarrierCount = 1;
    dep2.pImageMemoryBarriers = &barrier3;
    vkCmdPipelineBarrier2(commandBuffer, &dep2);
    
    vkEndCommandBuffer(commandBuffer);
    
    // Submit using VkSubmitInfo2 with vkQueueSubmit2
    VkCommandBufferSubmitInfo cmdSubmitInfo = {0};
    cmdSubmitInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    cmdSubmitInfo.commandBuffer = commandBuffer;
    cmdSubmitInfo.deviceMask = 0; // Single device
    
    VkSubmitInfo2 submitInfo2 = {0};
    submitInfo2.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    submitInfo2.commandBufferInfoCount = 1;
    submitInfo2.pCommandBufferInfos = &cmdSubmitInfo;
    
    vkQueueSubmit2(graphicsQueue, 1, &submitInfo2, VK_NULL_HANDLE);
    vkQueueWaitIdle(graphicsQueue);
    
    vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
    vk_allocator_free_buffer(allocator, stagingBuffer, stagingBufferMemory);
    
    // Create image view
    VkImageViewCreateInfo viewInfo = {0};
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = *textureImage;
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = format;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;
    
    return vkCreateImageView(device, &viewInfo, NULL, textureImageView) == VK_SUCCESS;
}

/**
 * @brief Creates a 1x1 white placeholder texture.
 * @param device Logical device.
 * @param physicalDevice Physical device.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @param textureImage Output image handle.
 * @param textureImageMemory Output memory handle.
 * @param textureImageView Output image view handle.
 * @param textureSampler Output sampler handle.
 * @return true on success, false on failure.
 * 
 * @todo Support different placeholder colors or patterns.
 * @todo Integrate with asset caching system to avoid recreation.
 */
static bool createPlaceholderTexture(VulkanAllocator* allocator, VkDevice device,
                                    VkCommandPool commandPool, VkQueue graphicsQueue,
                                    VkImage* textureImage, VkDeviceMemory* textureImageMemory,
                                    VkImageView* textureImageView, VkSampler* textureSampler) {
    // Create a 1x1 white texture
    const uint32_t width = 1, height = 1;
    const VkFormat format = VK_FORMAT_R8G8B8A8_SRGB;
    unsigned char whitePixel[4] = {255, 255, 255, 255};
    
    CARDINAL_LOG_DEBUG("Creating placeholder texture: %ux%u, format=%u", width, height, format);
    
    // Create staging buffer
    VkBuffer stagingBuffer;
    VkDeviceMemory stagingBufferMemory;
    VkDeviceSize imageSize = width * height * 4;
    
    CARDINAL_LOG_DEBUG("Creating staging buffer for placeholder: size=%llu", (unsigned long long)imageSize);
    if (!createBuffer(allocator, imageSize,
                     VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &stagingBuffer, &stagingBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create staging buffer for placeholder texture");
        return false;
    }
    
    void* data;
    vkMapMemory(device, stagingBufferMemory, 0, imageSize, 0, &data);
    memcpy(data, whitePixel, (size_t)imageSize);
    vkUnmapMemory(device, stagingBufferMemory);
    
    // Create image via allocator
    VkImageCreateInfo imageInfo = {0};
    imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    imageInfo.imageType = VK_IMAGE_TYPE_2D;
    imageInfo.extent.width = width;
    imageInfo.extent.height = height;
    imageInfo.extent.depth = 1;
    imageInfo.mipLevels = 1;
    imageInfo.arrayLayers = 1;
    imageInfo.format = format;
    imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
    imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    imageInfo.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
    imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    
    if (!vk_allocator_allocate_image(allocator, &imageInfo, textureImage, textureImageMemory, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
        CARDINAL_LOG_ERROR("Failed to create/allocate placeholder image via allocator");
        vk_allocator_free_buffer(allocator, stagingBuffer, stagingBufferMemory);
        return false;
    }
    CARDINAL_LOG_DEBUG("Placeholder image created via allocator: handle=%p", (void*)(uintptr_t)(*textureImage));
    
    // Copy buffer to image (simplified, without proper layout transitions)
    VkCommandBufferAllocateInfo allocInfo2 = {0};
    allocInfo2.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo2.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo2.commandPool = commandPool;
    allocInfo2.commandBufferCount = 1;
    
    VkCommandBuffer commandBuffer;
    vkAllocateCommandBuffers(device, &allocInfo2, &commandBuffer);
    
    VkCommandBufferBeginInfo beginInfo = {0};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    
    vkBeginCommandBuffer(commandBuffer, &beginInfo);
    
    // Vulkan 1.3 sync2 requirement - no fallbacks
    
    // Transition to transfer destination
    VkImageMemoryBarrier2 barrier2b = {0};
    barrier2b.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier2b.srcStageMask = VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT;
    barrier2b.srcAccessMask = 0;
    barrier2b.dstStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier2b.dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier2b.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier2b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier2b.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier2b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier2b.image = *textureImage;
    barrier2b.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier2b.subresourceRange.baseMipLevel = 0;
    barrier2b.subresourceRange.levelCount = 1;
    barrier2b.subresourceRange.baseArrayLayer = 0;
    barrier2b.subresourceRange.layerCount = 1;

    VkDependencyInfo dep3 = {0};
    dep3.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep3.imageMemoryBarrierCount = 1;
    dep3.pImageMemoryBarriers = &barrier2b;
    vkCmdPipelineBarrier2(commandBuffer, &dep3);
    
    VkBufferImageCopy region = {0};
    region.bufferOffset = 0;
    region.bufferRowLength = 0;
    region.bufferImageHeight = 0;
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel = 0;
    region.imageSubresource.baseArrayLayer = 0;
    region.imageSubresource.layerCount = 1;
    region.imageOffset.x = 0;
    region.imageOffset.y = 0;
    region.imageOffset.z = 0;
    region.imageExtent.width = width;
    region.imageExtent.height = height;
    region.imageExtent.depth = 1;
    
    vkCmdCopyBufferToImage(commandBuffer, stagingBuffer, *textureImage,
                          VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    
    // Transition to shader read
    VkImageMemoryBarrier2 barrier2 = {0};
    barrier2.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    barrier2.srcStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier2.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier2.dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    barrier2.dstAccessMask = VK_ACCESS_2_SHADER_READ_BIT;
    barrier2.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier2.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier2.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier2.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier2.image = *textureImage;
    barrier2.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier2.subresourceRange.baseMipLevel = 0;
    barrier2.subresourceRange.levelCount = 1;
    barrier2.subresourceRange.baseArrayLayer = 0;
    barrier2.subresourceRange.layerCount = 1;

    VkDependencyInfo dep = {0};
    dep.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dep.imageMemoryBarrierCount = 1;
    dep.pImageMemoryBarriers = &barrier2;
    vkCmdPipelineBarrier2(commandBuffer, &dep);
    
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
    vk_allocator_free_buffer(allocator, stagingBuffer, stagingBufferMemory);
    
    // Create image view
    VkImageViewCreateInfo viewInfo = {0};
    viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    viewInfo.image = *textureImage;
    viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
    viewInfo.format = format;
    viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    viewInfo.subresourceRange.baseMipLevel = 0;
    viewInfo.subresourceRange.levelCount = 1;
    viewInfo.subresourceRange.baseArrayLayer = 0;
    viewInfo.subresourceRange.layerCount = 1;
    
    if (vkCreateImageView(device, &viewInfo, NULL, textureImageView) != VK_SUCCESS) {
        return false;
    }
    
    // Create sampler
    VkSamplerCreateInfo samplerInfo = {0};
    samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = VK_FILTER_LINEAR;
    samplerInfo.minFilter = VK_FILTER_LINEAR;
    samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.anisotropyEnable = VK_FALSE;
    samplerInfo.maxAnisotropy = 1.0f;
    samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    samplerInfo.unnormalizedCoordinates = VK_FALSE;
    samplerInfo.compareEnable = VK_FALSE;
    samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
    samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    samplerInfo.mipLodBias = 0.0f;
    samplerInfo.minLod = 0.0f;
    samplerInfo.maxLod = 0.0f;
    
    return vkCreateSampler(device, &samplerInfo, NULL, textureSampler) == VK_SUCCESS;
}

// Helper function to create buffer
static bool createBuffer(VulkanAllocator* allocator, VkDeviceSize size,
                        VkBufferUsageFlags usage, VkMemoryPropertyFlags properties,
                        VkBuffer* buffer, VkDeviceMemory* bufferMemory) {
    if (size == 0) {
        CARDINAL_LOG_ERROR("Cannot create buffer with size 0");
        return false;
    }
    if (!allocator) {
        CARDINAL_LOG_ERROR("Allocator is null in createBuffer");
        return false;
    }

    CARDINAL_LOG_DEBUG("Creating buffer via allocator: size=%llu bytes, usage=0x%X, properties=0x%X", size, usage, properties);

    VkBufferCreateInfo bufferInfo = {0};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = size;
    bufferInfo.usage = usage;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    // Use allocator to create buffer + allocate/bind memory
    if (!vk_allocator_allocate_buffer(allocator, &bufferInfo, buffer, bufferMemory, properties)) {
        CARDINAL_LOG_ERROR("Allocator failed to create/allocate buffer (size=%llu, usage=0x%X)", size, usage);
        return false;
    }

    CARDINAL_LOG_DEBUG("Buffer created via allocator: buffer=%p, memory=%p", (void*)(uintptr_t)(*buffer), (void*)(uintptr_t)(*bufferMemory));
    return true;
}

__attribute__((unused))
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
static void copyBuffer(VkDevice device, VkCommandPool commandPool, VkQueue graphicsQueue,
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

// Helper function to load shader module
/**
 * @brief Loads and creates a shader module from SPIR-V file.
 * @param device Logical device.
 * @param filename Path to SPIR-V file.
 * @return Shader module or VK_NULL_HANDLE on failure.
 * 
 * @todo Implement shader caching to avoid repeated loading.
 */
static VkShaderModule createShaderModule(VkDevice device, const char* filename) {
    CARDINAL_LOG_DEBUG("[PBR] Attempting to load shader file: %s", filename);
    
    FILE* file = fopen(filename, "rb");
    if (!file) {
        CARDINAL_LOG_ERROR("[PBR] Failed to open shader file: %s", filename);
        return VK_NULL_HANDLE;
    }
    
    fseek(file, 0, SEEK_END);
    size_t fileSize = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    CARDINAL_LOG_DEBUG("[PBR] Shader file size: %zu bytes", fileSize);
    
    char* code = malloc(fileSize);
    if (!code) {
        CARDINAL_LOG_ERROR("[PBR] Failed to allocate memory for shader code");
        fclose(file);
        return VK_NULL_HANDLE;
    }
    
    size_t bytesRead = fread(code, 1, fileSize, file);
    fclose(file);
    
    if (bytesRead != fileSize) {
        CARDINAL_LOG_ERROR("[PBR] Failed to read complete shader file. Expected %zu bytes, read %zu", fileSize, bytesRead);
        free(code);
        return VK_NULL_HANDLE;
    }
    
    CARDINAL_LOG_DEBUG("[PBR] Successfully read %zu bytes from shader file", bytesRead);
    
    VkShaderModuleCreateInfo createInfo = {0};
    createInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    createInfo.codeSize = fileSize;
    createInfo.pCode = (const uint32_t*)code;
    
    VkShaderModule shaderModule;
    VkResult result = vkCreateShaderModule(device, &createInfo, NULL, &shaderModule);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[PBR] Failed to create shader module (VkResult: %d): %s", result, filename);
        free(code);
        return VK_NULL_HANDLE;
    }
    
    CARDINAL_LOG_INFO("[PBR] Successfully created shader module: %s", filename);
    free(code);
    return shaderModule;
}

/**
 * @brief Initializes the PBR rendering pipeline using dynamic rendering.
 * @param pipeline PBR pipeline structure.
 * @param device Logical device.
 * @param physicalDevice Physical device.
 * @param swapchainFormat Color attachment format.
 * @param depthFormat Depth attachment format.
 * @param commandPool Command pool.
 * @param graphicsQueue Graphics queue.
 * @return true on success, false on failure.
 * 
 * @todo Support dynamic state for viewport/scissor.
 * @todo Add push constants for material properties.
 */
bool vk_pbr_pipeline_create(VulkanPBRPipeline* pipeline, VkDevice device, VkPhysicalDevice physicalDevice,
                            VkFormat swapchainFormat, VkFormat depthFormat,
                            VkCommandPool commandPool, VkQueue graphicsQueue, VulkanAllocator* allocator) {
    // Suppress unused parameter warnings
    (void)commandPool;
    (void)graphicsQueue;
    
    CARDINAL_LOG_DEBUG("Starting PBR pipeline creation");
    
    // Declare variables at the top for C89 compatibility
    VkPhysicalDeviceVulkan12Features vulkan12Features = {0};
    VkPhysicalDeviceFeatures2 deviceFeatures2 = {0};
    bool supportsDescriptorIndexing;
    
    memset(pipeline, 0, sizeof(VulkanPBRPipeline));
    
    // Query Vulkan 1.2 features for descriptor indexing support
    vulkan12Features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    
    deviceFeatures2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    deviceFeatures2.pNext = &vulkan12Features;
    
    vkGetPhysicalDeviceFeatures2(physicalDevice, &deviceFeatures2);
    CARDINAL_LOG_DEBUG("Queried Vulkan 1.2 features for descriptor indexing capabilities");
    
    // Check if descriptor indexing features are available
    supportsDescriptorIndexing = vulkan12Features.descriptorIndexing &&
                                vulkan12Features.runtimeDescriptorArray &&
                                vulkan12Features.shaderSampledImageArrayNonUniformIndexing;
    
    // Store descriptor indexing support in pipeline structure
    pipeline->supportsDescriptorIndexing = supportsDescriptorIndexing;
    
    CARDINAL_LOG_INFO("[PBR] Descriptor indexing support: %s", supportsDescriptorIndexing ? "enabled" : "disabled");
    CARDINAL_LOG_DEBUG("Creating descriptor set layout with %d bindings", supportsDescriptorIndexing ? 9 : 8);
    
    // Create descriptor set layout  
    VkDescriptorSetLayoutBinding bindings[9] = {0};
    
    // UBO binding
    bindings[0].binding = 0;
    bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[0].descriptorCount = 1;
    bindings[0].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    
    // Texture bindings - use the same bindings as traditional mode but with enhanced capabilities if supported
    if (supportsDescriptorIndexing) {
        // albedoMap - standard binding
        bindings[1].binding = 1;
        bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // normalMap - standard binding
        bindings[2].binding = 2;
        bindings[2].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[2].descriptorCount = 1;
        bindings[2].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // metallicRoughnessMap - standard binding
        bindings[3].binding = 3;
        bindings[3].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[3].descriptorCount = 1;
        bindings[3].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // aoMap - standard binding
        bindings[4].binding = 4;
        bindings[4].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[4].descriptorCount = 1;
        bindings[4].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // emissiveMap - standard binding
        bindings[5].binding = 5;
        bindings[5].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[5].descriptorCount = 1;
        bindings[5].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // Material properties binding
        bindings[6].binding = 6;
        bindings[6].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        bindings[6].descriptorCount = 1;
        bindings[6].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // Lighting data binding
        bindings[7].binding = 7;
        bindings[7].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        bindings[7].descriptorCount = 1;
        bindings[7].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // Texture array binding with variable count - MUST be highest binding number
        bindings[8].binding = 8;
        bindings[8].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[8].descriptorCount = 1024; // Large array for future expansion
        bindings[8].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    } else {
        // Traditional fixed bindings matching shader expectations
        // albedoMap
        bindings[1].binding = 1;
        bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // normalMap
        bindings[2].binding = 2;
        bindings[2].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[2].descriptorCount = 1;
        bindings[2].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // metallicRoughnessMap
        bindings[3].binding = 3;
        bindings[3].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[3].descriptorCount = 1;
        bindings[3].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // aoMap
        bindings[4].binding = 4;
        bindings[4].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[4].descriptorCount = 1;
        bindings[4].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // emissiveMap
        bindings[5].binding = 5;
        bindings[5].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[5].descriptorCount = 1;
        bindings[5].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // Material properties binding
        bindings[6].binding = 6;
        bindings[6].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        bindings[6].descriptorCount = 1;
        bindings[6].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        
        // Lighting data binding
        bindings[7].binding = 7;
        bindings[7].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        bindings[7].descriptorCount = 1;
        bindings[7].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    }
    
    // Setup descriptor set layout create info
    VkDescriptorSetLayoutCreateInfo layoutInfo = {0};
    layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = supportsDescriptorIndexing ? 9 : 8; // Use extra binding (8) only when indexing is enabled
    layoutInfo.pBindings = bindings;
    
    // Enable descriptor indexing flags if supported
    VkDescriptorSetLayoutBindingFlagsCreateInfo bindingFlags = {0};
    VkDescriptorBindingFlags flags[9] = {0};
    
    if (supportsDescriptorIndexing) {
        // Set flags for the highest binding (binding 8) where variable descriptor count is used
        flags[8] = VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT |
                   VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT |
                   VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT;
        
        bindingFlags.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO;
        bindingFlags.bindingCount = 9;
        bindingFlags.pBindingFlags = flags;
        
        layoutInfo.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT;
        layoutInfo.pNext = &bindingFlags;
    }
    
    if (vkCreateDescriptorSetLayout(device, &layoutInfo, NULL, &pipeline->descriptorSetLayout) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor set layout!");
        return false;
    }
    CARDINAL_LOG_DEBUG("Descriptor set layout created: handle=%p", (void*)(uintptr_t)pipeline->descriptorSetLayout);
    
    // Create pipeline layout
    VkPipelineLayoutCreateInfo pipelineLayoutInfo = (VkPipelineLayoutCreateInfo){0};
    pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipelineLayoutInfo.setLayoutCount = 1;
    pipelineLayoutInfo.pSetLayouts = &pipeline->descriptorSetLayout;
    
    if (vkCreatePipelineLayout(device, &pipelineLayoutInfo, NULL, &pipeline->pipelineLayout) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create pipeline layout!");
        return false;
    }
    CARDINAL_LOG_DEBUG("Pipeline layout created: handle=%p", (void*)(uintptr_t)pipeline->pipelineLayout);
    
    // Load shaders
    VkShaderModule vertShaderModule = createShaderModule(device, "assets/shaders/pbr.vert.spv");
    VkShaderModule fragShaderModule = createShaderModule(device, "assets/shaders/pbr.frag.spv");
    
    if (vertShaderModule == VK_NULL_HANDLE || fragShaderModule == VK_NULL_HANDLE) {
        CARDINAL_LOG_ERROR("Failed to load PBR shaders!");
        return false;
    }
    CARDINAL_LOG_DEBUG("Shader modules loaded: vert=%p, frag=%p", (void*)(uintptr_t)vertShaderModule, (void*)(uintptr_t)fragShaderModule);
    
    VkPipelineShaderStageCreateInfo shaderStages[2] = {0};
    shaderStages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    shaderStages[0].module = vertShaderModule;
    shaderStages[0].pName = "main";
    
    shaderStages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    shaderStages[1].module = fragShaderModule;
    shaderStages[1].pName = "main";
    
    // Vertex input
    VkVertexInputBindingDescription bindingDescription = {0};
    bindingDescription.binding = 0;
    bindingDescription.stride = sizeof(CardinalVertex);
    bindingDescription.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
    
    VkVertexInputAttributeDescription attributeDescriptions[3] = {0};
    // Position
    attributeDescriptions[0].binding = 0;
    attributeDescriptions[0].location = 0;
    attributeDescriptions[0].format = VK_FORMAT_R32G32B32_SFLOAT;
    attributeDescriptions[0].offset = 0;
    
    // Normal
    attributeDescriptions[1].binding = 0;
    attributeDescriptions[1].location = 1;
    attributeDescriptions[1].format = VK_FORMAT_R32G32B32_SFLOAT;
    attributeDescriptions[1].offset = sizeof(float) * 3;
    
    // Texture coordinates
    attributeDescriptions[2].binding = 0;
    attributeDescriptions[2].location = 2;
    attributeDescriptions[2].format = VK_FORMAT_R32G32_SFLOAT;
    attributeDescriptions[2].offset = sizeof(float) * 6;
    
    VkPipelineVertexInputStateCreateInfo vertexInputInfo = {0};
    vertexInputInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertexInputInfo.vertexBindingDescriptionCount = 1;
    vertexInputInfo.pVertexBindingDescriptions = &bindingDescription;
    vertexInputInfo.vertexAttributeDescriptionCount = 3;
    vertexInputInfo.pVertexAttributeDescriptions = attributeDescriptions;
    
    // Input assembly
    VkPipelineInputAssemblyStateCreateInfo inputAssembly = {0};
    inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    inputAssembly.primitiveRestartEnable = VK_FALSE;
    
    // Viewport and scissor (dynamic)
    VkPipelineViewportStateCreateInfo viewportState = {0};
    viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewportState.viewportCount = 1;
    viewportState.scissorCount = 1;
    
    // Rasterizer
    VkPipelineRasterizationStateCreateInfo rasterizer = {0};
    rasterizer.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.depthClampEnable = VK_FALSE;
    rasterizer.rasterizerDiscardEnable = VK_FALSE;
    rasterizer.polygonMode = VK_POLYGON_MODE_FILL;
    rasterizer.lineWidth = 1.0f;
    rasterizer.cullMode = VK_CULL_MODE_NONE;  // TODO: Temporarily disable culling, activate once we render.
    rasterizer.frontFace = VK_FRONT_FACE_CLOCKWISE;
    rasterizer.depthBiasEnable = VK_FALSE;
    
    // Multisampling
    VkPipelineMultisampleStateCreateInfo multisampling = {0};
    multisampling.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.sampleShadingEnable = VK_FALSE;
    multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    
    // Depth and stencil testing - ENABLED now that render pass has a depth attachment
    VkPipelineDepthStencilStateCreateInfo depthStencil = {0};
    depthStencil.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depthStencil.depthTestEnable = VK_TRUE;
    depthStencil.depthWriteEnable = VK_TRUE;
    depthStencil.depthCompareOp = VK_COMPARE_OP_LESS;
    depthStencil.depthBoundsTestEnable = VK_FALSE;
    depthStencil.stencilTestEnable = VK_FALSE;
    
    // Color blending
    VkPipelineColorBlendAttachmentState colorBlendAttachment = {0};
    colorBlendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                         VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    colorBlendAttachment.blendEnable = VK_FALSE;
    
    VkPipelineColorBlendStateCreateInfo colorBlending = {0};
    colorBlending.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    colorBlending.logicOpEnable = VK_FALSE;
    colorBlending.attachmentCount = 1;
    colorBlending.pAttachments = &colorBlendAttachment;
    
    // Dynamic state
    VkDynamicState dynamicStates[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamicState = {0};
    dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicState.dynamicStateCount = 2;
    dynamicState.pDynamicStates = dynamicStates;
    
    // Create graphics pipeline
    VkGraphicsPipelineCreateInfo pipelineInfo = {0};
    pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipelineInfo.stageCount = 2;
    pipelineInfo.pStages = shaderStages;
    pipelineInfo.pVertexInputState = &vertexInputInfo;
    pipelineInfo.pInputAssemblyState = &inputAssembly;
    pipelineInfo.pViewportState = &viewportState;
    pipelineInfo.pRasterizationState = &rasterizer;
    pipelineInfo.pMultisampleState = &multisampling;
    pipelineInfo.pDepthStencilState = &depthStencil;
    pipelineInfo.pColorBlendState = &colorBlending;
    pipelineInfo.pDynamicState = &dynamicState;
    pipelineInfo.layout = pipeline->pipelineLayout;
    
    // Always use dynamic rendering pipeline info
    VkPipelineRenderingCreateInfo pipelineRenderingInfo = {0};
    pipelineRenderingInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    pipelineRenderingInfo.colorAttachmentCount = 1;
    VkFormat colorFormat = swapchainFormat;
    pipelineRenderingInfo.pColorAttachmentFormats = &colorFormat;
    pipelineRenderingInfo.depthAttachmentFormat = depthFormat;
    pipelineRenderingInfo.stencilAttachmentFormat = VK_FORMAT_UNDEFINED;
    pipelineInfo.pNext = &pipelineRenderingInfo;
    pipelineInfo.renderPass = VK_NULL_HANDLE;
    pipelineInfo.subpass = 0;
    
    if (vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, NULL, &pipeline->pipeline) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create graphics pipeline!");
        vkDestroyShaderModule(device, vertShaderModule, NULL);
        vkDestroyShaderModule(device, fragShaderModule, NULL);
        return false;
    }
    CARDINAL_LOG_DEBUG("Graphics pipeline created: handle=%p", (void*)(uintptr_t)pipeline->pipeline);
    
    vkDestroyShaderModule(device, vertShaderModule, NULL);
    vkDestroyShaderModule(device, fragShaderModule, NULL);
    
    // Create uniform buffers
    VkDeviceSize uboSize = sizeof(PBRUniformBufferObject);
    if (!createBuffer(allocator, uboSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &pipeline->uniformBuffer, &pipeline->uniformBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create PBR UBO buffer (size=%llu)", (unsigned long long)uboSize);
        return false;
    }
    CARDINAL_LOG_DEBUG("UBO buffer created: buffer=%p, memory=%p", (void*)(uintptr_t)pipeline->uniformBuffer, (void*)(uintptr_t)pipeline->uniformBufferMemory);
    
    VkResult result = vkMapMemory(device, pipeline->uniformBufferMemory, 0, uboSize, 0, &pipeline->uniformBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map uniform buffer memory: %d", result);
        return false;
    }
    CARDINAL_LOG_DEBUG("UBO memory mapped at %p", pipeline->uniformBufferMapped);
    
    VkDeviceSize materialSize = sizeof(PBRMaterialProperties);
    if (!createBuffer(allocator, materialSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &pipeline->materialBuffer, &pipeline->materialBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create PBR material buffer (size=%llu)", (unsigned long long)materialSize);
        return false;
    }
    CARDINAL_LOG_DEBUG("Material buffer created: buffer=%p, memory=%p", (void*)(uintptr_t)pipeline->materialBuffer, (void*)(uintptr_t)pipeline->materialBufferMemory);
    
    result = vkMapMemory(device, pipeline->materialBufferMemory, 0, materialSize, 0, &pipeline->materialBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map material buffer memory: %d", result);
        return false;
    }
    CARDINAL_LOG_DEBUG("Material memory mapped at %p", pipeline->materialBufferMapped);
    
    VkDeviceSize lightingSize = sizeof(PBRLightingData);
    if (!createBuffer(allocator, lightingSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &pipeline->lightingBuffer, &pipeline->lightingBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create PBR lighting buffer (size=%llu)", (unsigned long long)lightingSize);
        return false;
    }
    CARDINAL_LOG_DEBUG("Lighting buffer created: buffer=%p, memory=%p", (void*)(uintptr_t)pipeline->lightingBuffer, (void*)(uintptr_t)pipeline->lightingBufferMemory);
    
    result = vkMapMemory(device, pipeline->lightingBufferMemory, 0, lightingSize, 0, &pipeline->lightingBufferMapped);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map lighting buffer memory: %d", result);
        return false;
    }
    CARDINAL_LOG_DEBUG("Lighting memory mapped at %p", pipeline->lightingBufferMapped);
    
    // Initialize default material properties
    PBRMaterialProperties defaultMaterial = {0};
    defaultMaterial.albedoFactor[0] = 0.8f;  // Light gray
    defaultMaterial.albedoFactor[1] = 0.8f;
    defaultMaterial.albedoFactor[2] = 0.8f;
    defaultMaterial.metallicFactor = 0.0f;
    defaultMaterial.roughnessFactor = 0.5f;
    defaultMaterial.emissiveFactor[0] = 0.0f;
    defaultMaterial.emissiveFactor[1] = 0.0f;
    defaultMaterial.emissiveFactor[2] = 0.0f;
    defaultMaterial.normalScale = 1.0f;
    defaultMaterial.aoStrength = 1.0f;
    
    // Initialize texture indices to 0 (placeholder texture)
    defaultMaterial.albedoTextureIndex = 0;
    defaultMaterial.normalTextureIndex = 0;
    defaultMaterial.metallicRoughnessTextureIndex = 0;
    defaultMaterial.aoTextureIndex = 0;
    defaultMaterial.emissiveTextureIndex = 0;
    // Propagate descriptor indexing support to shader side
    defaultMaterial.supportsDescriptorIndexing = pipeline->supportsDescriptorIndexing ? 1u : 0u;
    
    memcpy(pipeline->materialBufferMapped, &defaultMaterial, sizeof(PBRMaterialProperties));
    
    // Initialize default lighting
    PBRLightingData defaultLighting = {0};
    defaultLighting.lightDirection[0] = -0.5f;
    defaultLighting.lightDirection[1] = -1.0f;
    defaultLighting.lightDirection[2] = -0.3f;
    defaultLighting.lightColor[0] = 1.0f;
    defaultLighting.lightColor[1] = 1.0f;
    defaultLighting.lightColor[2] = 1.0f;
    defaultLighting.lightIntensity = 1.0f;  // Reduced from 3.0f
    defaultLighting.ambientColor[0] = 0.03f;  // Reduced from 0.1f
    defaultLighting.ambientColor[1] = 0.03f;
    defaultLighting.ambientColor[2] = 0.03f;
    memcpy(pipeline->lightingBufferMapped, &defaultLighting, sizeof(PBRLightingData));
    
    pipeline->initialized = true;
    CARDINAL_LOG_INFO("PBR pipeline created successfully");
    return true;
}

/**
 * @brief Destroys the PBR pipeline and frees all associated resources.
 *
 * @param pipeline Pointer to the VulkanPBRPipeline structure to destroy.
 * @param device The Vulkan logical device.
 *
 * @todo Optimize resource cleanup to handle partial destructions.
 * @todo Add support for Vulkan memory allocator extensions.
 */
void vk_pbr_pipeline_destroy(VulkanPBRPipeline* pipeline, VkDevice device, VulkanAllocator* allocator) {
    if (!pipeline->initialized) return;
    
    // Destroy textures
    if (pipeline->textureImages) {
        for (uint32_t i = 0; i < pipeline->textureCount; i++) {
            if (pipeline->textureImageViews[i] != VK_NULL_HANDLE) {
                vkDestroyImageView(device, pipeline->textureImageViews[i], NULL);
            }
            vk_allocator_free_image(allocator, pipeline->textureImages[i], pipeline->textureImageMemories[i]);
        }
        free(pipeline->textureImages);
        free(pipeline->textureImageMemories);
        free(pipeline->textureImageViews);
    }
    
    if (pipeline->textureSampler != VK_NULL_HANDLE) {
        vkDestroySampler(device, pipeline->textureSampler, NULL);
    }
    
    // Destroy vertex and index buffers
    if (pipeline->vertexBuffer != VK_NULL_HANDLE || pipeline->vertexBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->vertexBuffer, pipeline->vertexBufferMemory);
    }
    
    if (pipeline->indexBuffer != VK_NULL_HANDLE || pipeline->indexBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->indexBuffer, pipeline->indexBufferMemory);
    }
    
    // Destroy uniform buffers
    if (pipeline->uniformBuffer != VK_NULL_HANDLE || pipeline->uniformBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->uniformBuffer, pipeline->uniformBufferMemory);
    }
    
    if (pipeline->materialBuffer != VK_NULL_HANDLE || pipeline->materialBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->materialBuffer, pipeline->materialBufferMemory);
    }
    
    if (pipeline->lightingBuffer != VK_NULL_HANDLE || pipeline->lightingBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->lightingBuffer, pipeline->lightingBufferMemory);
    }
    
    // Free descriptor sets explicitly before destroying pool
    if (pipeline->descriptorSets && pipeline->descriptorPool != VK_NULL_HANDLE) {
        vkFreeDescriptorSets(device, pipeline->descriptorPool, pipeline->descriptorSetCount, pipeline->descriptorSets);
        free(pipeline->descriptorSets);
        pipeline->descriptorSets = NULL;
    }
    
    // Destroy descriptor pool
    if (pipeline->descriptorPool != VK_NULL_HANDLE) {
        vkDestroyDescriptorPool(device, pipeline->descriptorPool, NULL);
        pipeline->descriptorPool = VK_NULL_HANDLE;
    }
    
    // Destroy pipeline and layout
    if (pipeline->pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(device, pipeline->pipeline, NULL);
    }
    
    if (pipeline->pipelineLayout != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(device, pipeline->pipelineLayout, NULL);
    }
    
    if (pipeline->descriptorSetLayout != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(device, pipeline->descriptorSetLayout, NULL);
    }
    
    memset(pipeline, 0, sizeof(VulkanPBRPipeline));
    CARDINAL_LOG_INFO("PBR pipeline destroyed");
}

/**
 * @brief Updates the uniform buffers for the PBR pipeline.
 *
 * @param pipeline Pointer to the VulkanPBRPipeline structure.
 * @param ubo Pointer to the uniform buffer object data.
 * @param lighting Pointer to the lighting data.
 *
 * @todo Implement dynamic uniform buffer updates for real-time changes.
 * @todo Add support for multiple light sources in lighting data.
 */
void vk_pbr_update_uniforms(VulkanPBRPipeline* pipeline, const PBRUniformBufferObject* ubo,
                            const PBRLightingData* lighting) {
    if (!pipeline->initialized) return;
    
    // Update UBO
    memcpy(pipeline->uniformBufferMapped, ubo, sizeof(PBRUniformBufferObject));
    
    // Update lighting data
    memcpy(pipeline->lightingBufferMapped, lighting, sizeof(PBRLightingData));
}

/**
 * @brief Renders the PBR scene using the pipeline.
 *
 * @param pipeline Pointer to the VulkanPBRPipeline structure.
 * @param commandBuffer The command buffer to record rendering commands into.
 * @param scene Pointer to the scene data to render.
 *
 * @todo Implement multi-pass rendering for advanced effects like shadows.
 * @todo Add support for instanced rendering.
 */
void vk_pbr_render(VulkanPBRPipeline* pipeline, VkCommandBuffer commandBuffer, const CardinalScene* scene) {
    if (!pipeline->initialized || !scene) return;
    
    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline->pipeline);
    
    VkBuffer vertexBuffers[] = {pipeline->vertexBuffer};
    VkDeviceSize offsets[] = {0};
    vkCmdBindVertexBuffers(commandBuffer, 0, 1, vertexBuffers, offsets);
    vkCmdBindIndexBuffer(commandBuffer, pipeline->indexBuffer, 0, VK_INDEX_TYPE_UINT32);
    
    // Render each mesh
    uint32_t indexOffset = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* mesh = &scene->meshes[i];
        
        // Update material properties for this mesh
        if (mesh->material_index < scene->material_count) {
            const CardinalMaterial* material = &scene->materials[mesh->material_index];
            
            PBRMaterialProperties matProps = (PBRMaterialProperties){0};
            memcpy(matProps.albedoFactor, material->albedo_factor, sizeof(float) * 3);
            matProps.metallicFactor = material->metallic_factor;
            matProps.roughnessFactor = material->roughness_factor;
            memcpy(matProps.emissiveFactor, material->emissive_factor, sizeof(float) * 3);
            matProps.normalScale = material->normal_scale;
            matProps.aoStrength = material->ao_strength;
            
            // Set texture indices - preserve UINT32_MAX for missing textures, fallback to 0 only for invalid indices
            matProps.albedoTextureIndex = (material->albedo_texture == UINT32_MAX) ? UINT32_MAX : 
                                          (material->albedo_texture < pipeline->textureCount) ? material->albedo_texture : 0;
            matProps.normalTextureIndex = (material->normal_texture == UINT32_MAX) ? UINT32_MAX : 
                                          (material->normal_texture < pipeline->textureCount) ? material->normal_texture : 0;
            matProps.metallicRoughnessTextureIndex = (material->metallic_roughness_texture == UINT32_MAX) ? UINT32_MAX : 
                                                     (material->metallic_roughness_texture < pipeline->textureCount) ? material->metallic_roughness_texture : 0;
            matProps.aoTextureIndex = (material->ao_texture == UINT32_MAX) ? UINT32_MAX : 
                                      (material->ao_texture < pipeline->textureCount) ? material->ao_texture : 0;
            matProps.emissiveTextureIndex = (material->emissive_texture == UINT32_MAX) ? UINT32_MAX : 
                                            (material->emissive_texture < pipeline->textureCount) ? material->emissive_texture : 0;
            
            // CRITICAL: Set descriptor indexing flag for shader (only if textures are available)
            matProps.supportsDescriptorIndexing = (pipeline->supportsDescriptorIndexing && pipeline->textureCount > 0) ? 1u : 0u;
            
            // Debug logging for material properties
            CARDINAL_LOG_DEBUG("Material %d: albedo_idx=%u, normal_idx=%u, mr_idx=%u, ao_idx=%u, emissive_idx=%u", 
                              i, matProps.albedoTextureIndex, matProps.normalTextureIndex, matProps.metallicRoughnessTextureIndex, 
                              matProps.aoTextureIndex, matProps.emissiveTextureIndex);
            CARDINAL_LOG_DEBUG("Material %d factors: albedo=[%.3f,%.3f,%.3f], emissive=[%.3f,%.3f,%.3f], metallic=%.3f, roughness=%.3f",
                              i, matProps.albedoFactor[0], matProps.albedoFactor[1], matProps.albedoFactor[2],
                              matProps.emissiveFactor[0], matProps.emissiveFactor[1], matProps.emissiveFactor[2], 
                              matProps.metallicFactor, matProps.roughnessFactor);
            
            memcpy(pipeline->materialBufferMapped, &matProps, sizeof(PBRMaterialProperties));
        }
        
        // Bind descriptor set AFTER updating material properties so the latest data is used for this draw
        if (pipeline->descriptorSetCount > 0) {
            vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                    pipeline->pipelineLayout, 0, 1,
                                    &pipeline->descriptorSets[0], 0, NULL);
        }
        
        // Draw the mesh
        vkCmdDrawIndexed(commandBuffer, mesh->index_count, 1, indexOffset, 0, 0);
        indexOffset += mesh->index_count;
    }
}

/**
 * @brief Loads scene data into the PBR pipeline buffers.
 *
 * @param pipeline Pointer to the VulkanPBRPipeline structure.
 * @param device The Vulkan logical device.
 * @param physicalDevice The Vulkan physical device.
 * @param commandPool The command pool for temporary commands.
 * @param graphicsQueue The graphics queue for submissions.
 * @param scene Pointer to the scene data to load.
 * @return true if loading was successful, false otherwise.
 *
 * @todo Implement scene streaming for large models.
 * @todo Add support for loading multiple texture sets per material.
 * @todo Integrate image-based lighting (IBL) textures.
 */
bool vk_pbr_load_scene(VulkanPBRPipeline* pipeline, VkDevice device, VkPhysicalDevice physicalDevice,
                       VkCommandPool commandPool, VkQueue graphicsQueue, const CardinalScene* scene, VulkanAllocator* allocator) {
    (void)physicalDevice; // Unused parameter
    
    if (!pipeline->initialized || !scene || scene->mesh_count == 0) {
        CARDINAL_LOG_WARN("PBR pipeline not initialized or no scene data");
        return true;
    }
    
    // Count total vertices and indices
    uint32_t totalVertices = 0;
    uint32_t totalIndices = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        totalVertices += scene->meshes[i].vertex_count;
        totalIndices += scene->meshes[i].index_count;
    }
    
    if (totalVertices == 0) {
        CARDINAL_LOG_WARN("Scene has no vertices");
        return true;
    }
    
    CARDINAL_LOG_INFO("Loading PBR scene: %u meshes, %u vertices, %u indices", 
                     scene->mesh_count, totalVertices, totalIndices);
    
    // Clean up previous buffers if they exist
    if (pipeline->vertexBuffer != VK_NULL_HANDLE || pipeline->vertexBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->vertexBuffer, pipeline->vertexBufferMemory);
        pipeline->vertexBuffer = VK_NULL_HANDLE;
        pipeline->vertexBufferMemory = VK_NULL_HANDLE;
    }
    
    if (pipeline->indexBuffer != VK_NULL_HANDLE || pipeline->indexBufferMemory != VK_NULL_HANDLE) {
        vk_allocator_free_buffer(allocator, pipeline->indexBuffer, pipeline->indexBufferMemory);
        pipeline->indexBuffer = VK_NULL_HANDLE;
        pipeline->indexBufferMemory = VK_NULL_HANDLE;
    }
    
    // Create vertex buffer
    VkDeviceSize vertexBufferSize = totalVertices * sizeof(CardinalVertex);
    if (!createBuffer(allocator, vertexBufferSize,
                     VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &pipeline->vertexBuffer, &pipeline->vertexBufferMemory)) {
        CARDINAL_LOG_ERROR("Failed to create PBR vertex buffer");
        return false;
    }
    
    // Map and upload vertex data
    void* vertexData;
    if (vkMapMemory(device, pipeline->vertexBufferMemory, 0, vertexBufferSize, 0, &vertexData) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to map vertex buffer memory");
        return false;
    }
    
    CardinalVertex* mappedVertices = (CardinalVertex*)vertexData;
    uint32_t vertexOffset = 0;
    for (uint32_t i = 0; i < scene->mesh_count; i++) {
        const CardinalMesh* mesh = &scene->meshes[i];
        memcpy(&mappedVertices[vertexOffset], mesh->vertices, mesh->vertex_count * sizeof(CardinalVertex));
        vertexOffset += mesh->vertex_count;
    }
    vkUnmapMemory(device, pipeline->vertexBufferMemory);
    
    // Create index buffer if we have indices
    if (totalIndices > 0) {
        VkDeviceSize indexBufferSize = totalIndices * sizeof(uint32_t);
        if (!createBuffer(allocator, indexBufferSize,
                         VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &pipeline->indexBuffer, &pipeline->indexBufferMemory)) {
            CARDINAL_LOG_ERROR("Failed to create PBR index buffer");
            return false;
        }
        
        void* indexData;
        if (vkMapMemory(device, pipeline->indexBufferMemory, 0, indexBufferSize, 0, &indexData) != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("Failed to map index buffer memory");
            return false;
        }
        
        uint32_t* mappedIndices = (uint32_t*)indexData;
        uint32_t indexOffset = 0;
        uint32_t vertexBaseOffset = 0;
        for (uint32_t i = 0; i < scene->mesh_count; i++) {
            const CardinalMesh* mesh = &scene->meshes[i];
            if (mesh->index_count > 0) {
                for (uint32_t j = 0; j < mesh->index_count; j++) {
                    mappedIndices[indexOffset + j] = mesh->indices[j] + vertexBaseOffset;
                }
                indexOffset += mesh->index_count;
            }
            vertexBaseOffset += mesh->vertex_count;
        }
        vkUnmapMemory(device, pipeline->indexBufferMemory);
    }
    
    // Clean up existing textures if any
    if (pipeline->textureImages) {
        for (uint32_t i = 0; i < pipeline->textureCount; i++) {
            if (pipeline->textureImageViews && pipeline->textureImageViews[i] != VK_NULL_HANDLE) {
                vkDestroyImageView(device, pipeline->textureImageViews[i], NULL);
            }
            if (pipeline->textureImages[i] != VK_NULL_HANDLE || (pipeline->textureImageMemories && pipeline->textureImageMemories[i] != VK_NULL_HANDLE)) {
                vk_allocator_free_image(allocator, pipeline->textureImages[i], pipeline->textureImageMemories[i]);
            }
        }
        free(pipeline->textureImages);
        free(pipeline->textureImageMemories);
        free(pipeline->textureImageViews);
        pipeline->textureImages = NULL;
        pipeline->textureImageMemories = NULL;
        pipeline->textureImageViews = NULL;
    }
    
    if (pipeline->textureSampler != VK_NULL_HANDLE) {
        vkDestroySampler(device, pipeline->textureSampler, NULL);
        pipeline->textureSampler = VK_NULL_HANDLE;
    }
    
    // Determine how many textures we need to upload
    uint32_t textureCount = (scene->texture_count > 0) ? scene->texture_count : 1;
    bool hasSceneTextures = (scene->texture_count > 0 && scene->textures != NULL);
    
    CARDINAL_LOG_INFO("Loading %u textures (%u from scene)", textureCount, scene->texture_count);
    
    // Allocate texture arrays
    pipeline->textureCount = textureCount;
    pipeline->textureImages = (VkImage*)malloc(textureCount * sizeof(VkImage));
    pipeline->textureImageMemories = (VkDeviceMemory*)malloc(textureCount * sizeof(VkDeviceMemory));
    pipeline->textureImageViews = (VkImageView*)malloc(textureCount * sizeof(VkImageView));
    
    // Initialize arrays
    for (uint32_t i = 0; i < textureCount; i++) {
        pipeline->textureImages[i] = VK_NULL_HANDLE;
        pipeline->textureImageMemories[i] = VK_NULL_HANDLE;
        pipeline->textureImageViews[i] = VK_NULL_HANDLE;
    }
    
    // Create texture sampler (shared by all textures)
    VkSamplerCreateInfo samplerInfo = {0};
    samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = VK_FILTER_LINEAR;
    samplerInfo.minFilter = VK_FILTER_LINEAR;
    samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    samplerInfo.anisotropyEnable = VK_FALSE;
    samplerInfo.maxAnisotropy = 1.0f;
    samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    samplerInfo.unnormalizedCoordinates = VK_FALSE;
    samplerInfo.compareEnable = VK_FALSE;
    samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
    samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    samplerInfo.mipLodBias = 0.0f;
    samplerInfo.minLod = 0.0f;
    samplerInfo.maxLod = 0.0f;
    
    if (vkCreateSampler(device, &samplerInfo, NULL, &pipeline->textureSampler) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create texture sampler");
        return false;
    }
    CARDINAL_LOG_DEBUG("Texture sampler created: handle=%p", (void*)(uintptr_t)pipeline->textureSampler);
    
    // Upload scene textures or create placeholder
    uint32_t successfulUploads = 0;
    
    if (hasSceneTextures) {
        // Upload real textures from scene
        for (uint32_t i = 0; i < scene->texture_count; i++) {
            const CardinalTexture* texture = &scene->textures[i];
            
            // Skip invalid textures and create placeholder for them
            if (!texture->data || texture->width == 0 || texture->height == 0) {
                CARDINAL_LOG_WARN("Skipping invalid texture %u (%s) - creating placeholder", i, texture->path ? texture->path : "unknown");
                // Create fallback placeholder for invalid texture slot
                if (!createPlaceholderTexture(allocator, device, commandPool, graphicsQueue,
                                            &pipeline->textureImages[i], &pipeline->textureImageMemories[i],
                                            &pipeline->textureImageViews[i], NULL)) {
                    CARDINAL_LOG_ERROR("Failed to create fallback texture for slot %u", i);
                    return false;
                }
                continue;
            }
            
            CARDINAL_LOG_INFO("Uploading texture %u: %ux%u, %d channels (%s)", 
                             i, texture->width, texture->height, texture->channels,
                             texture->path ? texture->path : "unknown");
            
            if (createTextureFromData(allocator, device, commandPool, graphicsQueue,
                                     texture, &pipeline->textureImages[i], 
                                     &pipeline->textureImageMemories[i], 
                                     &pipeline->textureImageViews[i])) {
                successfulUploads++;
            } else {
                CARDINAL_LOG_ERROR("Failed to upload texture %u (%s) - creating placeholder", i, texture->path ? texture->path : "unknown");
                // Create fallback placeholder for this slot to ensure valid image view
                if (!createPlaceholderTexture(allocator, device, commandPool, graphicsQueue,
                                            &pipeline->textureImages[i], &pipeline->textureImageMemories[i],
                                            &pipeline->textureImageViews[i], NULL)) {
                    CARDINAL_LOG_ERROR("Failed to create fallback texture for slot %u", i);
                    return false;
                }
            }
        }
        
#ifdef _DEBUG
        CARDINAL_LOG_INFO("Successfully uploaded %u/%u textures", successfulUploads, scene->texture_count);
#else
        (void)successfulUploads; // Silence unused variable warning in release builds
#endif
        
        // Fill remaining slots with placeholders if scene had fewer textures than allocated
        for (uint32_t i = scene->texture_count; i < textureCount; i++) {
            CARDINAL_LOG_DEBUG("Creating placeholder texture for unused slot %u", i);
            if (!createPlaceholderTexture(allocator, device, commandPool, graphicsQueue,
                                        &pipeline->textureImages[i], &pipeline->textureImageMemories[i],
                                        &pipeline->textureImageViews[i], NULL)) {
                CARDINAL_LOG_ERROR("Failed to create placeholder texture for slot %u", i);
                return false;
            }
        }
    }
    
    // If no scene textures, create a single placeholder
    if (!hasSceneTextures) {
        CARDINAL_LOG_INFO("Creating placeholder texture (no scene textures available)");
        if (!createPlaceholderTexture(allocator, device, commandPool, graphicsQueue,
                                     &pipeline->textureImages[0], &pipeline->textureImageMemories[0],
                                     &pipeline->textureImageViews[0], NULL)) {
            CARDINAL_LOG_ERROR("Failed to create placeholder texture");
            return false;
        }
        // Ensure we only have one texture slot when using fallback
        pipeline->textureCount = 1;
    }
    
    // Create descriptor pool and sets
    VkDescriptorPoolSize poolSizes[3] = {0};
    poolSizes[0].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    poolSizes[0].descriptorCount = 2; // UBO + Material
    poolSizes[1].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    // Allocate descriptors: 5 fixed + extra capacity if descriptor indexing is enabled for binding 8
    poolSizes[1].descriptorCount = pipeline->supportsDescriptorIndexing ? (5 + 1024) : 5; // 5 fixed + 1024 variable
    poolSizes[2].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    poolSizes[2].descriptorCount = 1; // Lighting
    
    VkDescriptorPoolCreateInfo poolInfo = {0};
    poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    poolInfo.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    // Enable update after bind if using descriptor indexing
    if (pipeline->supportsDescriptorIndexing) {
        poolInfo.flags |= VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT;
    }
    poolInfo.poolSizeCount = 3;
    poolInfo.pPoolSizes = poolSizes;
    poolInfo.maxSets = 1; // One descriptor set for now
    
    if (vkCreateDescriptorPool(device, &poolInfo, NULL, &pipeline->descriptorPool) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create descriptor pool");
        return false;
    }
    CARDINAL_LOG_DEBUG("Descriptor pool created: handle=%p, flags=0x%X, counts: UBO=%u, IMG=%u, LIGHT=%u",
                      (void*)(uintptr_t)pipeline->descriptorPool, poolInfo.flags, poolSizes[0].descriptorCount, poolSizes[1].descriptorCount, poolSizes[2].descriptorCount);
    
    // Allocate descriptor set
    pipeline->descriptorSetCount = 1;
    pipeline->descriptorSets = (VkDescriptorSet*)malloc(sizeof(VkDescriptorSet));
    
    VkDescriptorSetAllocateInfo allocInfo = {0};
    allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocInfo.descriptorPool = pipeline->descriptorPool;
    allocInfo.descriptorSetCount = 1;
    allocInfo.pSetLayouts = &pipeline->descriptorSetLayout;
    
    // Handle variable descriptor count for descriptor indexing (binding 8)
    VkDescriptorSetVariableDescriptorCountAllocateInfo variableCountInfo = {0};
    // Use the actual number of textures we will bind for the variable descriptor array
    uint32_t variableDescriptorCount = pipeline->supportsDescriptorIndexing ? pipeline->textureCount : 0;
    
    if (pipeline->supportsDescriptorIndexing) {
        variableCountInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO;
        variableCountInfo.descriptorSetCount = 1;
        variableCountInfo.pDescriptorCounts = &variableDescriptorCount;
        allocInfo.pNext = &variableCountInfo;
    }
    
    if (vkAllocateDescriptorSets(device, &allocInfo, pipeline->descriptorSets) != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to allocate descriptor sets");
        return false;
    }
    CARDINAL_LOG_DEBUG("Allocated descriptor set: set=%p, variableCount=%u (supported=%s)",
                      (void*)(uintptr_t)pipeline->descriptorSets[0], variableDescriptorCount, pipeline->supportsDescriptorIndexing ? "yes" : "no");
    
    // Update descriptor sets with uniform buffers and textures
    // variable descriptor indexing path can emit up to 9 writes (UBO + 5 textures + variable array + 2 UBOs)
    VkWriteDescriptorSet descriptorWrites[10] = {0};
    uint32_t writeCount = 0;
    
    VkDescriptorBufferInfo bufferInfo = {0};
    bufferInfo.buffer = pipeline->uniformBuffer;
    bufferInfo.offset = 0;
    bufferInfo.range = sizeof(PBRUniformBufferObject);
    
    descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[writeCount].dstBinding = 0;
    descriptorWrites[writeCount].dstArrayElement = 0;
    descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[writeCount].descriptorCount = 1;
    descriptorWrites[writeCount].pBufferInfo = &bufferInfo;
    writeCount++;
    
    // Prepare image infos for material texture slots (albedo, normal, metallicRoughness, ao, emissive)
    VkDescriptorImageInfo imageInfos[5];
    for (uint32_t i = 0; i < 5; ++i) {
        imageInfos[i].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        // When descriptor indexing is enabled, fixed bindings 1-5 should use placeholder (index 0)
        // to avoid confusion with the variable array. Only use direct texture mapping when indexing is disabled.
        uint32_t texIndex = pipeline->supportsDescriptorIndexing ? 0 : ((i < pipeline->textureCount) ? i : 0);
        imageInfos[i].imageView = pipeline->textureImageViews[texIndex];
        imageInfos[i].sampler = pipeline->textureSampler;
        CARDINAL_LOG_DEBUG("Fixed binding %u uses texture index %u (imageView=%p)", i + 1, texIndex, (void*)(uintptr_t)pipeline->textureImageViews[texIndex]);
    }
    
    if (pipeline->supportsDescriptorIndexing) {
        // Bind placeholders for fixed bindings 1-5 (shader will use variable array for actual textures)
        for (uint32_t b = 1; b <= 5; ++b) {
            descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
            descriptorWrites[writeCount].dstBinding = b;
            descriptorWrites[writeCount].dstArrayElement = 0;
            descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            descriptorWrites[writeCount].descriptorCount = 1;
            descriptorWrites[writeCount].pImageInfo = &imageInfos[b - 1];
            writeCount++;
        }
        // Variable descriptor array: bind all available textures (or 1 if only placeholder)
        descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
        descriptorWrites[writeCount].dstBinding = 8; // variable count binding
        descriptorWrites[writeCount].dstArrayElement = 0;
        descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        descriptorWrites[writeCount].descriptorCount = pipeline->textureCount;
        
        // Build a temporary array of VkDescriptorImageInfo for binding 8
        VkDescriptorImageInfo* varInfos = (VkDescriptorImageInfo*)malloc(sizeof(VkDescriptorImageInfo) * pipeline->textureCount);
        if (!varInfos) {
            CARDINAL_LOG_ERROR("Failed to allocate memory for descriptor image infos");
            return false;
        }
        for (uint32_t i = 0; i < pipeline->textureCount; ++i) {
            varInfos[i].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            varInfos[i].imageView = pipeline->textureImageViews[i];
            varInfos[i].sampler = pipeline->textureSampler;
            if (i < 8) {
                CARDINAL_LOG_DEBUG("Variable binding 8, array[%u] -> imageView=%p", i, (void*)(uintptr_t)pipeline->textureImageViews[i]);
            }
        }
        descriptorWrites[writeCount].pImageInfo = varInfos;
        writeCount++;
        
        // Update descriptor sets for descriptor indexing path
        VkDescriptorBufferInfo materialBufferInfo = {0};
        materialBufferInfo.buffer = pipeline->materialBuffer;
        materialBufferInfo.offset = 0;
        materialBufferInfo.range = sizeof(PBRMaterialProperties);
        
        descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
        descriptorWrites[writeCount].dstBinding = 6;
        descriptorWrites[writeCount].dstArrayElement = 0;
        descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        descriptorWrites[writeCount].descriptorCount = 1;
        descriptorWrites[writeCount].pBufferInfo = &materialBufferInfo;
        writeCount++;
        
        VkDescriptorBufferInfo lightingBufferInfo = {0};
        lightingBufferInfo.buffer = pipeline->lightingBuffer;
        lightingBufferInfo.offset = 0;
        lightingBufferInfo.range = sizeof(PBRLightingData);
        
        descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
        descriptorWrites[writeCount].dstBinding = 7;
        descriptorWrites[writeCount].dstArrayElement = 0;
        descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        descriptorWrites[writeCount].descriptorCount = 1;
        descriptorWrites[writeCount].pBufferInfo = &lightingBufferInfo;
        writeCount++;
        
        // Apply descriptor writes
        CARDINAL_LOG_DEBUG("Updating descriptor sets (variable binding): writes=%u, sampler=%p, ubo=%p, material=%p, lighting=%p", writeCount,
                           (void*)(uintptr_t)pipeline->textureSampler,
                           (void*)(uintptr_t)pipeline->uniformBuffer,
                           (void*)(uintptr_t)pipeline->materialBuffer,
                           (void*)(uintptr_t)pipeline->lightingBuffer);
        vkUpdateDescriptorSets(device, writeCount, descriptorWrites, 0, NULL);
        CARDINAL_LOG_DEBUG("Descriptor sets updated for variable binding");
        
        // Free temporary allocation
        free(varInfos);
        
        CARDINAL_LOG_INFO("PBR scene loaded successfully");
        return true;
    } else {
        // Traditional individual bindings 1-5 use corresponding imageInfos
        for (uint32_t b = 1; b <= 5; ++b) {
            descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
            descriptorWrites[writeCount].dstBinding = b;
            descriptorWrites[writeCount].dstArrayElement = 0;
            descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            descriptorWrites[writeCount].descriptorCount = 1;
            descriptorWrites[writeCount].pImageInfo = &imageInfos[b - 1];
            writeCount++;
        }
    }
    
    VkDescriptorBufferInfo materialBufferInfo = {0};
    materialBufferInfo.buffer = pipeline->materialBuffer;
    materialBufferInfo.offset = 0;
    materialBufferInfo.range = sizeof(PBRMaterialProperties);
    
    descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[writeCount].dstBinding = 6;
    descriptorWrites[writeCount].dstArrayElement = 0;
    descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[writeCount].descriptorCount = 1;
    descriptorWrites[writeCount].pBufferInfo = &materialBufferInfo;
    writeCount++;
    
    VkDescriptorBufferInfo lightingBufferInfo = {0};
    lightingBufferInfo.buffer = pipeline->lightingBuffer;
    lightingBufferInfo.offset = 0;
    lightingBufferInfo.range = sizeof(PBRLightingData);
    
    descriptorWrites[writeCount].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    descriptorWrites[writeCount].dstSet = pipeline->descriptorSets[0];
    descriptorWrites[writeCount].dstBinding = 7;
    descriptorWrites[writeCount].dstArrayElement = 0;
    descriptorWrites[writeCount].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    descriptorWrites[writeCount].descriptorCount = 1;
    descriptorWrites[writeCount].pBufferInfo = &lightingBufferInfo;
    writeCount++;
    
    CARDINAL_LOG_DEBUG("Updating descriptor sets (fixed bindings): writes=%u, sampler=%p, ubo=%p, material=%p, lighting=%p", writeCount,
                       (void*)(uintptr_t)pipeline->textureSampler,
                       (void*)(uintptr_t)pipeline->uniformBuffer,
                       (void*)(uintptr_t)pipeline->materialBuffer,
                       (void*)(uintptr_t)pipeline->lightingBuffer);
    vkUpdateDescriptorSets(device, writeCount, descriptorWrites, 0, NULL);
    CARDINAL_LOG_DEBUG("Descriptor sets updated for fixed bindings");
    
    CARDINAL_LOG_INFO("PBR scene loaded successfully");
    return true;
}
