#include <cardinal/renderer/util/vulkan_texture_utils.h>
#include <cardinal/renderer/util/vulkan_buffer_utils.h>
#include "../vulkan_state.h"
#include <cardinal/core/log.h>
#include <string.h>
#include <stdlib.h>

bool vk_texture_create_from_data(VulkanAllocator* allocator, VkDevice device,
                                 VkCommandPool commandPool, VkQueue graphicsQueue,
                                 const CardinalTexture* texture, 
                                 VkImage* textureImage, VkDeviceMemory* textureImageMemory,
                                 VkImageView* textureImageView) {
    if (!texture || !texture->data || !textureImage || !textureImageMemory || !textureImageView) {
        LOG_ERROR("Invalid parameters for texture creation");
        return false;
    }

    VkDeviceSize imageSize = texture->width * texture->height * 4; // Always RGBA
    
    // Create staging buffer
    VkBuffer stagingBuffer;
    VkDeviceMemory stagingBufferMemory;
    if (!vk_buffer_create(allocator, imageSize, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &stagingBuffer, &stagingBufferMemory)) {
        LOG_ERROR("Failed to create staging buffer for texture");
        return false;
    }

    // Map memory and copy texture data
    void* data;
    vkMapMemory(device, stagingBufferMemory, 0, imageSize, 0, &data);
    
    if (texture->channels == 4) {
        // Direct copy for RGBA
        memcpy(data, texture->data, imageSize);
    } else if (texture->channels == 3) {
        // Convert RGB to RGBA
        unsigned char* src = (unsigned char*)texture->data;
        unsigned char* dst = (unsigned char*)data;
        for (uint32_t i = 0; i < texture->width * texture->height; i++) {
            dst[i * 4 + 0] = src[i * 3 + 0]; // R
            dst[i * 4 + 1] = src[i * 3 + 1]; // G
            dst[i * 4 + 2] = src[i * 3 + 2]; // B
            dst[i * 4 + 3] = 255;            // A
        }
    } else {
        LOG_ERROR("Unsupported texture channel count: %d", texture->channels);
        vkUnmapMemory(device, stagingBufferMemory);
        vkDestroyBuffer(device, stagingBuffer, NULL);
        vkFreeMemory(device, stagingBufferMemory, NULL);
        return false;
    }
    
    vkUnmapMemory(device, stagingBufferMemory);

    // Create image
    VkImageCreateInfo imageInfo = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .extent.width = texture->width,
        .extent.height = texture->height,
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

    if (vkCreateImage(device, &imageInfo, NULL, textureImage) != VK_SUCCESS) {
        LOG_ERROR("Failed to create texture image");
        vkDestroyBuffer(device, stagingBuffer, NULL);
        vkFreeMemory(device, stagingBufferMemory, NULL);
        return false;
    }

    // Allocate image memory
    VkMemoryRequirements memRequirements;
    vkGetImageMemoryRequirements(device, *textureImage, &memRequirements);

    VkMemoryAllocateInfo allocInfo = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = memRequirements.size,
        .memoryTypeIndex = vk_buffer_find_memory_type(allocator->physical_device, memRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
    };

    if (vkAllocateMemory(device, &allocInfo, NULL, textureImageMemory) != VK_SUCCESS) {
        LOG_ERROR("Failed to allocate texture image memory");
        vkDestroyImage(device, *textureImage, NULL);
        vkDestroyBuffer(device, stagingBuffer, NULL);
        vkFreeMemory(device, stagingBufferMemory, NULL);
        return false;
    }

    vkBindImageMemory(device, *textureImage, *textureImageMemory, 0);

    // Transition image layout and copy buffer to image
    VkCommandBufferAllocateInfo allocInfo2 = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = commandPool,
        .commandBufferCount = 1,
    };

    VkCommandBuffer commandBuffer;
    vkAllocateCommandBuffers(device, &allocInfo2, &commandBuffer);

    VkCommandBufferBeginInfo beginInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };

    vkBeginCommandBuffer(commandBuffer, &beginInfo);

    // Transition to transfer destination
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
        .image = *textureImage,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        }
    };

    VkDependencyInfo dependencyInfo = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    };

    vkCmdPipelineBarrier2(commandBuffer, &dependencyInfo);

    // Copy buffer to image
    VkBufferImageCopy region = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = {0, 0, 0},
        .imageExtent = {
            texture->width,
            texture->height,
            1
        }
    };

    vkCmdCopyBufferToImage(commandBuffer, stagingBuffer, *textureImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    // Transition to shader read-only
    barrier.srcStageMask = VK_PIPELINE_STAGE_2_TRANSFER_BIT;
    barrier.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier.dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    barrier.dstAccessMask = VK_ACCESS_2_SHADER_READ_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    vkCmdPipelineBarrier2(commandBuffer, &dependencyInfo);

    vkEndCommandBuffer(commandBuffer);

    // Submit command buffer
    VkCommandBufferSubmitInfo cmdBufSubmitInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .commandBuffer = commandBuffer,
    };

    VkSubmitInfo2 submitInfo = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmdBufSubmitInfo,
    };

    vkQueueSubmit2(graphicsQueue, 1, &submitInfo, VK_NULL_HANDLE);
    vkQueueWaitIdle(graphicsQueue);

    vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
    vkDestroyBuffer(device, stagingBuffer, NULL);
    vkFreeMemory(device, stagingBufferMemory, NULL);

    // Create image view
    VkImageViewCreateInfo viewInfo = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = *textureImage,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_SRGB,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        }
    };

    if (vkCreateImageView(device, &viewInfo, NULL, textureImageView) != VK_SUCCESS) {
        LOG_ERROR("Failed to create texture image view");
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
        .data = whitePixel,
        .width = 1,
        .height = 1,
        .channels = 4,
        .path = "placeholder"
    };
    
    return vk_texture_create_from_data(allocator, device, commandPool, graphicsQueue,
                                       &placeholderTexture, textureImage, textureImageMemory, textureImageView);
}

bool vk_texture_create_sampler(VkDevice device, VkPhysicalDevice physicalDevice, VkSampler* sampler) {
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
        LOG_ERROR("Failed to create texture sampler");
        return false;
    }

    return true;
}
