/**
 * @file vulkan_texture_manager.c
 * @brief Implementation of centralized texture management for Cardinal Engine
 *
 * This module implements a centralized texture management system that handles
 * texture loading, creation, caching, and resource management. It extracts
 * texture management functionality from vulkan_pbr.c to create a reusable
 * and maintainable texture management system.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include "vulkan_state.h"
#include <cardinal/core/log.h>
#include <cardinal/renderer/util/vulkan_texture_utils.h>
#include <cardinal/renderer/vulkan_texture_manager.h>
#include <stdlib.h>
#include <string.h>

// Internal helper functions
static bool create_default_sampler(VulkanTextureManager* manager);
static bool ensure_capacity(VulkanTextureManager* manager, uint32_t requiredCapacity);
static void destroy_texture(VulkanTextureManager* manager, uint32_t index);

bool vk_texture_manager_init(VulkanTextureManager* manager,
                             const VulkanTextureManagerConfig* config) {
    if (!manager || !config) {
        CARDINAL_LOG_ERROR("Invalid parameters for texture manager initialization");
        return false;
    }

    memset(manager, 0, sizeof(VulkanTextureManager));

    manager->device = config->device;
    manager->allocator = config->allocator;
    manager->commandPool = config->commandPool;
    manager->graphicsQueue = config->graphicsQueue;
    manager->syncManager = config->syncManager;

    // Initialize texture storage
    uint32_t initialCapacity = config->initialCapacity > 0 ? config->initialCapacity : 16;
    manager->textures =
        (VulkanManagedTexture*)calloc(initialCapacity, sizeof(VulkanManagedTexture));
    if (!manager->textures) {
        CARDINAL_LOG_ERROR("Failed to allocate texture storage");
        return false;
    }

    manager->textureCapacity = initialCapacity;
    manager->textureCount = 0;
    manager->hasPlaceholder = false;

    // Create default sampler
    if (!create_default_sampler(manager)) {
        CARDINAL_LOG_ERROR("Failed to create default sampler");
        free(manager->textures);
        return false;
    }

    CARDINAL_LOG_INFO("Texture manager initialized with capacity %u", initialCapacity);
    return true;
}

void vk_texture_manager_destroy(VulkanTextureManager* manager) {
    if (!manager) {
        return;
    }

    // Destroy all textures
    for (uint32_t i = 0; i < manager->textureCount; i++) {
        destroy_texture(manager, i);
    }

    // Destroy default sampler
    if (manager->defaultSampler != VK_NULL_HANDLE) {
        vkDestroySampler(manager->device, manager->defaultSampler, NULL);
        manager->defaultSampler = VK_NULL_HANDLE;
    }

    // Free texture storage
    free(manager->textures);

    memset(manager, 0, sizeof(VulkanTextureManager));
    CARDINAL_LOG_DEBUG("Texture manager destroyed");
}

/**
 * @brief Processes a single scene texture for loading.
 */
static void load_single_scene_texture(VulkanTextureManager* manager, const CardinalScene* scene,
                                      uint32_t index, uint32_t* successfulUploads,
                                      uint64_t* maxTimelineValue) {
    const CardinalTexture* texture = &scene->textures[index];
    uint32_t textureIndex;

    // Skip invalid textures and create placeholder for them
    if (!texture->data || texture->width == 0 || texture->height == 0) {
        CARDINAL_LOG_WARN("Skipping invalid texture %u (%s) - using placeholder", index,
                          texture->path ? texture->path : "unknown");
        return;
    }

    CARDINAL_LOG_INFO("Uploading texture %u: %ux%u, %d channels (%s)", index, texture->width,
                      texture->height, texture->channels,
                      texture->path ? texture->path : "unknown");

    uint64_t timelineValue = 0;
    if (vk_texture_manager_load_texture(manager, texture, &textureIndex, &timelineValue)) {
        (*successfulUploads)++;
        if (timelineValue > *maxTimelineValue) {
            *maxTimelineValue = timelineValue;
        }
    } else {
        CARDINAL_LOG_ERROR("Failed to upload texture %u (%s) - creating placeholder", index,
                           texture->path ? texture->path : "unknown");
        // Create a placeholder texture for the failed upload to maintain texture array
        // consistency
        uint32_t placeholderIndex;
        if (vk_texture_manager_create_placeholder(manager, &placeholderIndex)) {
            CARDINAL_LOG_INFO("Created placeholder texture at index %u for failed texture %u",
                              placeholderIndex, index);
        } else {
            CARDINAL_LOG_ERROR("Failed to create placeholder for failed texture %u", index);
        }
    }
}

bool vk_texture_manager_load_scene_textures(VulkanTextureManager* manager,
                                            const CardinalScene* scene) {
    if (!manager || !scene) {
        CARDINAL_LOG_ERROR("Invalid parameters for scene texture loading");
        return false;
    }

    // Clear existing textures (except placeholder)
    vk_texture_manager_clear_textures(manager);

    // Ensure we have a placeholder texture at index 0
    if (!manager->hasPlaceholder) {
        uint32_t placeholderIndex;
        if (!vk_texture_manager_create_placeholder(manager, &placeholderIndex)) {
            CARDINAL_LOG_ERROR("Failed to create placeholder texture");
            return false;
        }
    }

    // If no scene textures, we're done (placeholder is sufficient)
    if (scene->texture_count == 0 || !scene->textures) {
        CARDINAL_LOG_INFO("No scene textures to load, using placeholder only");
        return true;
    }

    // Ensure capacity for all scene textures
    uint32_t requiredCapacity = scene->texture_count + 1; // +1 for placeholder
    if (!ensure_capacity(manager, requiredCapacity)) {
        CARDINAL_LOG_ERROR("Failed to ensure capacity for %u textures", requiredCapacity);
        return false;
    }

    CARDINAL_LOG_INFO("Loading %u textures from scene", scene->texture_count);

    uint32_t successfulUploads = 0;
    uint64_t maxTimelineValue = 0;

    // Load scene textures starting from index 1 (index 0 is placeholder)
    for (uint32_t i = 0; i < scene->texture_count; i++) {
        load_single_scene_texture(manager, scene, i, &successfulUploads, &maxTimelineValue);
    }

    // Wait for all texture uploads to complete after loading all textures
    // Note: vk_texture_create_from_data is synchronous and waits for its own timeline value,
    // so we don't strictly need to wait here again unless we move to asynchronous uploads.
    // However, keeping a simple log message to indicate completion.
    CARDINAL_LOG_INFO("Texture loading phase completed. Max timeline value: %llu",
                      (unsigned long long)maxTimelineValue);

    // Check if we encountered device loss during uploads
    // VkGetDeviceQueue returns void, use vkDeviceWaitIdle to check device status
    VkResult deviceStatus = vkDeviceWaitIdle(manager->device);
    if (deviceStatus != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Device status check failed after texture loading: %d", deviceStatus);
    }

    if (successfulUploads < scene->texture_count) {
        CARDINAL_LOG_WARN("Uploaded %u/%u textures (some failed)", successfulUploads,
                          scene->texture_count);
    } else {
        CARDINAL_LOG_INFO("Successfully uploaded all %u textures", successfulUploads);
    }

    return true;
}

bool vk_texture_manager_load_texture(VulkanTextureManager* manager, const CardinalTexture* texture,
                                     uint32_t* outIndex, uint64_t* outTimelineValue) {
    if (!manager || !texture || !outIndex) {
        CARDINAL_LOG_ERROR("Invalid parameters for texture loading");
        return false;
    }

    // Ensure capacity
    if (!ensure_capacity(manager, manager->textureCount + 1)) {
        CARDINAL_LOG_ERROR("Failed to ensure capacity for new texture");
        return false;
    }

    uint32_t index = manager->textureCount;
    VulkanManagedTexture* managedTexture = &manager->textures[index];

    // Use existing texture utility to create the texture
    if (!vk_texture_create_from_data(manager->allocator, manager->device, manager->commandPool,
                                     manager->graphicsQueue, manager->syncManager, texture,
                                     &managedTexture->image, &managedTexture->memory,
                                     &managedTexture->view, outTimelineValue)) {
        CARDINAL_LOG_ERROR("Failed to create texture from data");
        // Don't try to free resources here, vk_texture_create_from_data cleans up on failure
        return false;
    }

    // Store texture metadata
    managedTexture->width = texture->width;
    managedTexture->height = texture->height;
    managedTexture->channels = texture->channels;
    managedTexture->isPlaceholder = false;

    // Copy path if available
    if (texture->path) {
        size_t pathLen = strlen(texture->path) + 1;
        managedTexture->path = (char*)malloc(pathLen);
        if (managedTexture->path) {
            strcpy(managedTexture->path, texture->path);
        }
    } else {
        managedTexture->path = NULL;
    }

    manager->textureCount++;
    *outIndex = index;

    CARDINAL_LOG_DEBUG("Loaded texture at index %u: %ux%u (%s)", index, managedTexture->width,
                       managedTexture->height,
                       managedTexture->path ? managedTexture->path : "unknown");

    return true;
}

bool vk_texture_manager_create_placeholder(VulkanTextureManager* manager, uint32_t* outIndex) {
    if (!manager || !outIndex) {
        CARDINAL_LOG_ERROR("Invalid parameters for placeholder creation");
        return false;
    }

    // Ensure capacity
    if (!ensure_capacity(manager, manager->textureCount + 1)) {
        CARDINAL_LOG_ERROR("Failed to ensure capacity for placeholder texture");
        return false;
    }

    uint32_t index = manager->textureCount;
    VulkanManagedTexture* managedTexture = &manager->textures[index];

    // Use existing texture utility to create placeholder
    if (!vk_texture_create_placeholder(manager->allocator, manager->device, manager->commandPool,
                                       manager->graphicsQueue, &managedTexture->image,
                                       &managedTexture->memory, &managedTexture->view, NULL)) {
        CARDINAL_LOG_ERROR("Failed to create placeholder texture");
        return false;
    }

    // Store placeholder metadata
    managedTexture->width = 1;
    managedTexture->height = 1;
    managedTexture->channels = 4;
    managedTexture->isPlaceholder = true;
    managedTexture->path = NULL;

    manager->textureCount++;
    *outIndex = index;

    // Mark that we have at least one placeholder
    if (index == 0) {
        manager->hasPlaceholder = true;
    }

    CARDINAL_LOG_DEBUG("Created placeholder texture at index %u", index);
    return true;
}

const VulkanManagedTexture* vk_texture_manager_get_texture(const VulkanTextureManager* manager,
                                                           uint32_t index) {
    if (!manager || index >= manager->textureCount) {
        return NULL;
    }

    return &manager->textures[index];
}

VkSampler vk_texture_manager_get_default_sampler(const VulkanTextureManager* manager) {
    return manager ? manager->defaultSampler : VK_NULL_HANDLE;
}

uint32_t vk_texture_manager_get_texture_count(const VulkanTextureManager* manager) {
    return manager ? manager->textureCount : 0;
}

uint32_t vk_texture_manager_get_image_views(const VulkanTextureManager* manager,
                                            VkImageView* outViews, uint32_t maxViews) {
    if (!manager || !outViews || maxViews == 0) {
        return 0;
    }

    uint32_t copyCount = (manager->textureCount < maxViews) ? manager->textureCount : maxViews;

    for (uint32_t i = 0; i < copyCount; i++) {
        outViews[i] = manager->textures[i].view;
    }

    return copyCount;
}

void vk_texture_manager_clear_textures(VulkanTextureManager* manager) {
    if (!manager) {
        return;
    }

    // Destroy all textures except placeholder (if it exists)
    uint32_t startIndex = manager->hasPlaceholder ? 1 : 0;

    for (uint32_t i = startIndex; i < manager->textureCount; i++) {
        destroy_texture(manager, i);
    }

    // Reset count but keep placeholder
    manager->textureCount = manager->hasPlaceholder ? 1 : 0;

    CARDINAL_LOG_DEBUG("Cleared textures, keeping %u textures", manager->textureCount);
}

// Internal helper functions

static bool create_default_sampler(VulkanTextureManager* manager) {
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

    if (vkCreateSampler(manager->device, &samplerInfo, NULL, &manager->defaultSampler) !=
        VK_SUCCESS) {
        CARDINAL_LOG_ERROR("Failed to create default texture sampler");
        return false;
    }

    CARDINAL_LOG_DEBUG("Default texture sampler created: handle=%p",
                       (void*)(uintptr_t)manager->defaultSampler);
    return true;
}

static bool ensure_capacity(VulkanTextureManager* manager, uint32_t requiredCapacity) {
    if (manager->textureCapacity >= requiredCapacity) {
        return true;
    }

    uint32_t newCapacity = manager->textureCapacity;
    while (newCapacity < requiredCapacity) {
        newCapacity *= 2;
    }

    VulkanManagedTexture* newTextures = (VulkanManagedTexture*)realloc(
        manager->textures, newCapacity * sizeof(VulkanManagedTexture));

    if (!newTextures) {
        CARDINAL_LOG_ERROR("Failed to reallocate texture storage for capacity %u", newCapacity);
        return false;
    }

    // Initialize new slots
    for (uint32_t i = manager->textureCapacity; i < newCapacity; i++) {
        memset(&newTextures[i], 0, sizeof(VulkanManagedTexture));
    }

    manager->textures = newTextures;
    manager->textureCapacity = newCapacity;

    CARDINAL_LOG_DEBUG("Expanded texture capacity to %u", newCapacity);
    return true;
}

static void destroy_texture(VulkanTextureManager* manager, uint32_t index) {
    if (index >= manager->textureCount) {
        return;
    }

    VulkanManagedTexture* texture = &manager->textures[index];

    if (texture->view != VK_NULL_HANDLE) {
        vkDestroyImageView(manager->device, texture->view, NULL);
        texture->view = VK_NULL_HANDLE;
    }

    if (texture->image != VK_NULL_HANDLE && texture->memory != VK_NULL_HANDLE) {
        vk_allocator_free_image(manager->allocator, texture->image, texture->memory);
        texture->image = VK_NULL_HANDLE;
        texture->memory = VK_NULL_HANDLE;
    }

    free(texture->path);
    memset(texture, 0, sizeof(VulkanManagedTexture));
}
