#include "vulkan_state.h"
#include "cardinal/core/memory.h"
#include "cardinal/core/log.h"
#include <string.h>

/**
 * @brief Initializes the VulkanAllocator with device context and maintenance4 support.
 * @param alloc The allocator to initialize.
 * @param phys Physical device handle.
 * @param dev Device handle.
 * @param maintenance4 Whether maintenance4 is supported.
 * @param bufReq Function pointer for device buffer memory requirements.
 * @param imgReq Function pointer for device image memory requirements.
 * @return true on success, false on failure.
 */
bool vk_allocator_init(VulkanAllocator* alloc, VkPhysicalDevice phys, VkDevice dev, bool maintenance4,
                       PFN_vkGetDeviceBufferMemoryRequirements bufReq,
                       PFN_vkGetDeviceImageMemoryRequirements imgReq) {
    if (!alloc || !phys || !dev) {
        CARDINAL_LOG_ERROR("[VkAllocator] Invalid parameters for allocator init");
        return false;
    }
    
    memset(alloc, 0, sizeof(VulkanAllocator));
    alloc->device = dev;
    alloc->physical_device = phys;
    alloc->use_maintenance4 = maintenance4;
    alloc->fpGetDeviceBufferMemReq = bufReq;
    alloc->fpGetDeviceImageMemReq = imgReq;
    alloc->total_device_mem_allocated = 0;
    alloc->total_device_mem_freed = 0;
    
    CARDINAL_LOG_INFO("[VkAllocator] Initialized - maintenance4: %s", maintenance4 ? "enabled" : "disabled");
    return true;
}

/**
 * @brief Shuts down the VulkanAllocator and logs statistics.
 * @param alloc The allocator to shutdown.
 */
void vk_allocator_shutdown(VulkanAllocator* alloc) {
    if (!alloc) return;
    
    uint64_t net = alloc->total_device_mem_allocated - alloc->total_device_mem_freed;
    CARDINAL_LOG_INFO("[VkAllocator] Shutdown - Total allocated: %llu bytes, freed: %llu bytes, net: %llu bytes",
                      (unsigned long long)alloc->total_device_mem_allocated,
                      (unsigned long long)alloc->total_device_mem_freed,
                      (unsigned long long)net);
    
    if (net > 0) {
        CARDINAL_LOG_WARN("[VkAllocator] Memory leak detected: %llu bytes not freed", (unsigned long long)net);
    }
    
    memset(alloc, 0, sizeof(VulkanAllocator));
}

/**
 * @brief Helper function to find a suitable memory type.
 * @param alloc The allocator context.
 * @param type_filter Memory type requirements.
 * @param properties Required memory properties.
 * @param out_type_index Output memory type index.
 * @return true if found, false otherwise.
 */
static bool find_memory_type(VulkanAllocator* alloc, uint32_t type_filter, VkMemoryPropertyFlags properties, uint32_t* out_type_index) {
    VkPhysicalDeviceMemoryProperties mem_props;
    vkGetPhysicalDeviceMemoryProperties(alloc->physical_device, &mem_props);
    
    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
        if ((type_filter & (1 << i)) && 
            (mem_props.memoryTypes[i].propertyFlags & properties) == properties) {
            *out_type_index = i;
            return true;
        }
    }
    
    return false;
}

/**
 * @brief Allocates memory for an image using maintenance4 or legacy methods.
 * @param alloc The allocator instance.
 * @param image_ci Image create info for maintenance4 queries.
 * @param out_image Output image handle.
 * @param out_memory Output device memory handle.
 * @param required_props Required memory properties.
 * @return true on success, false on failure.
 */
bool vk_allocator_allocate_image(VulkanAllocator* alloc,
                                 const VkImageCreateInfo* image_ci,
                                 VkImage* out_image,
                                 VkDeviceMemory* out_memory,
                                 VkMemoryPropertyFlags required_props) {
    if (!alloc || !image_ci || !out_image || !out_memory) {
        CARDINAL_LOG_ERROR("[VkAllocator] Invalid parameters for image allocation");
        return false;
    }
    CARDINAL_LOG_INFO("[VkAllocator] allocate_image: extent=%ux%u fmt=%u usage=0x%x props=0x%x maint4=%d",
                      image_ci->extent.width, image_ci->extent.height, image_ci->format, image_ci->usage,
                      (unsigned)required_props, alloc->use_maintenance4);
    
    // Create the image first
    VkResult result = vkCreateImage(alloc->device, image_ci, NULL, out_image);
    CARDINAL_LOG_INFO("[VkAllocator] vkCreateImage => %d, handle=%p", result, (void*)(*out_image));
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[VkAllocator] Failed to create image: %d", result);
        return false;
    }
    
    // Get memory requirements
    VkMemoryRequirements mem_requirements;
    if (alloc->use_maintenance4 && alloc->fpGetDeviceImageMemReq) {
        // Use maintenance4 device-level query for better optimization
        VkDeviceImageMemoryRequirements device_req = {0};
        device_req.sType = VK_STRUCTURE_TYPE_DEVICE_IMAGE_MEMORY_REQUIREMENTS;
        device_req.pNext = NULL;
        device_req.pCreateInfo = image_ci;
        
        VkMemoryRequirements2 mem_req2 = {0};
        mem_req2.sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2;
        mem_req2.pNext = NULL;
        alloc->fpGetDeviceImageMemReq(alloc->device, &device_req, &mem_req2);
        mem_requirements = mem_req2.memoryRequirements;
        CARDINAL_LOG_INFO("[VkAllocator] Image mem reqs: size=%llu align=%llu types=0x%x",
                          (unsigned long long)mem_requirements.size,
                          (unsigned long long)mem_requirements.alignment,
                          mem_requirements.memoryTypeBits);
    } else {
        // Fall back to legacy method
        vkGetImageMemoryRequirements(alloc->device, *out_image, &mem_requirements);
        CARDINAL_LOG_INFO("[VkAllocator] Image mem reqs (legacy): size=%llu align=%llu types=0x%x",
                          (unsigned long long)mem_requirements.size,
                          (unsigned long long)mem_requirements.alignment,
                          mem_requirements.memoryTypeBits);
    }
    
    if (mem_requirements.size == 0 || mem_requirements.memoryTypeBits == 0) {
        CARDINAL_LOG_ERROR("[VkAllocator] Invalid image memory requirements (size=%llu, types=0x%x)",
                           (unsigned long long)mem_requirements.size, mem_requirements.memoryTypeBits);
        vkDestroyImage(alloc->device, *out_image, NULL);
        *out_image = VK_NULL_HANDLE;
        return false;
    }
    
    // Find suitable memory type
    uint32_t memory_type_index;
    if (!find_memory_type(alloc, mem_requirements.memoryTypeBits, required_props, &memory_type_index)) {
        CARDINAL_LOG_ERROR("[VkAllocator] Failed to find suitable memory type for image (required_props=0x%x)", (unsigned)required_props);
        vkDestroyImage(alloc->device, *out_image, NULL);
        *out_image = VK_NULL_HANDLE;
        return false;
    }
    CARDINAL_LOG_INFO("[VkAllocator] Image memory type index: %u", memory_type_index);
    
    // Allocate memory
    VkMemoryAllocateInfo alloc_info = {0};
    alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_requirements.size;
    alloc_info.memoryTypeIndex = memory_type_index;
    
    result = vkAllocateMemory(alloc->device, &alloc_info, NULL, out_memory);
    CARDINAL_LOG_INFO("[VkAllocator] vkAllocateMemory(Image) => %d, mem=%p size=%llu", result, (void*)(*out_memory), (unsigned long long)alloc_info.allocationSize);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[VkAllocator] Failed to allocate image memory: %d", result);
        vkDestroyImage(alloc->device, *out_image, NULL);
        *out_image = VK_NULL_HANDLE;
        return false;
    }
    
    // Bind memory to image
    result = vkBindImageMemory(alloc->device, *out_image, *out_memory, 0);
    CARDINAL_LOG_INFO("[VkAllocator] vkBindImageMemory => %d", result);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[VkAllocator] Failed to bind image memory: %d", result);
        vkFreeMemory(alloc->device, *out_memory, NULL);
        vkDestroyImage(alloc->device, *out_image, NULL);
        *out_image = VK_NULL_HANDLE;
        *out_memory = VK_NULL_HANDLE;
        return false;
    }
    
    // Update statistics and Cardinal memory tracking
    alloc->total_device_mem_allocated += mem_requirements.size;
    
    // NOTE: Do not touch Cardinal memory subsystem here; Vulkan device memory is managed by Vulkan
    // and the memory system may not be initialized at this point. We only track local stats.
    
    CARDINAL_LOG_DEBUG("[VkAllocator] Allocated image memory: %llu bytes (type: %u)", 
                       (unsigned long long)mem_requirements.size, memory_type_index);
    
    return true;
}

/**
 * @brief Allocates memory for a buffer using maintenance4 or legacy methods.
 * @param alloc The allocator instance.
 * @param buffer_ci Buffer create info for maintenance4 queries.
 * @param out_buffer Output buffer handle.
 * @param out_memory Output device memory handle.
 * @param required_props Required memory properties.
 * @return true on success, false on failure.
 */
bool vk_allocator_allocate_buffer(VulkanAllocator* alloc,
                                  const VkBufferCreateInfo* buffer_ci,
                                  VkBuffer* out_buffer,
                                  VkDeviceMemory* out_memory,
                                  VkMemoryPropertyFlags required_props) {
    if (!alloc || !buffer_ci || !out_buffer || !out_memory) {
        CARDINAL_LOG_ERROR("[VkAllocator] Invalid parameters for buffer allocation");
        return false;
    }
    CARDINAL_LOG_INFO("[VkAllocator] allocate_buffer: size=%llu usage=0x%x sharingMode=%u props=0x%x maint4=%d",
                      (unsigned long long)buffer_ci->size, buffer_ci->usage, buffer_ci->sharingMode,
                      (unsigned)required_props, alloc->use_maintenance4);
    
    // Create the buffer first
    VkResult result = vkCreateBuffer(alloc->device, buffer_ci, NULL, out_buffer);
    CARDINAL_LOG_INFO("[VkAllocator] vkCreateBuffer => %d, handle=%p", result, (void*)(*out_buffer));
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[VkAllocator] Failed to create buffer: %d", result);
        return false;
    }
    
    // Get memory requirements
    VkMemoryRequirements mem_requirements;
    if (alloc->use_maintenance4 && alloc->fpGetDeviceBufferMemReq) {
        // Use maintenance4 device-level query for better optimization
        VkDeviceBufferMemoryRequirements device_req = {0};
        device_req.sType = VK_STRUCTURE_TYPE_DEVICE_BUFFER_MEMORY_REQUIREMENTS;
        device_req.pNext = NULL;
        device_req.pCreateInfo = buffer_ci;
        
        VkMemoryRequirements2 mem_req2 = {0};
        mem_req2.sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2;
        mem_req2.pNext = NULL;
        alloc->fpGetDeviceBufferMemReq(alloc->device, &device_req, &mem_req2);
        mem_requirements = mem_req2.memoryRequirements;
        CARDINAL_LOG_INFO("[VkAllocator] Buffer mem reqs: size=%llu align=%llu types=0x%x",
                          (unsigned long long)mem_requirements.size,
                          (unsigned long long)mem_requirements.alignment,
                          mem_requirements.memoryTypeBits);
    } else {
        // Fall back to legacy method
        vkGetBufferMemoryRequirements(alloc->device, *out_buffer, &mem_requirements);
        CARDINAL_LOG_INFO("[VkAllocator] Buffer mem reqs (legacy): size=%llu align=%llu types=0x%x",
                          (unsigned long long)mem_requirements.size,
                          (unsigned long long)mem_requirements.alignment,
                          mem_requirements.memoryTypeBits);
    }
    
    if (mem_requirements.size == 0 || mem_requirements.memoryTypeBits == 0) {
        CARDINAL_LOG_ERROR("[VkAllocator] Invalid buffer memory requirements (size=%llu, types=0x%x)",
                           (unsigned long long)mem_requirements.size, mem_requirements.memoryTypeBits);
        vkDestroyBuffer(alloc->device, *out_buffer, NULL);
        *out_buffer = VK_NULL_HANDLE;
        return false;
    }
    
    // Find suitable memory type
    uint32_t memory_type_index;
    if (!find_memory_type(alloc, mem_requirements.memoryTypeBits, required_props, &memory_type_index)) {
        CARDINAL_LOG_ERROR("[VkAllocator] Failed to find suitable memory type for buffer (required_props=0x%x)", (unsigned)required_props);
        vkDestroyBuffer(alloc->device, *out_buffer, NULL);
        *out_buffer = VK_NULL_HANDLE;
        return false;
    }
    CARDINAL_LOG_INFO("[VkAllocator] Buffer memory type index: %u", memory_type_index);
    
    // Allocate memory
    VkMemoryAllocateInfo alloc_info = {0};
    alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_requirements.size;
    alloc_info.memoryTypeIndex = memory_type_index;
    
    result = vkAllocateMemory(alloc->device, &alloc_info, NULL, out_memory);
    CARDINAL_LOG_INFO("[VkAllocator] vkAllocateMemory(Buffer) => %d, mem=%p size=%llu", result, (void*)(*out_memory), (unsigned long long)alloc_info.allocationSize);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[VkAllocator] Failed to allocate buffer memory: %d", result);
        vkDestroyBuffer(alloc->device, *out_buffer, NULL);
        *out_buffer = VK_NULL_HANDLE;
        return false;
    }
    
    // Bind memory to buffer
    result = vkBindBufferMemory(alloc->device, *out_buffer, *out_memory, 0);
    CARDINAL_LOG_INFO("[VkAllocator] vkBindBufferMemory => %d", result);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[VkAllocator] Failed to bind buffer memory: %d", result);
        vkFreeMemory(alloc->device, *out_memory, NULL);
        vkDestroyBuffer(alloc->device, *out_buffer, NULL);
        *out_buffer = VK_NULL_HANDLE;
        *out_memory = VK_NULL_HANDLE;
        return false;
    }
    
    // Update statistics and Cardinal memory tracking
    alloc->total_device_mem_allocated += mem_requirements.size;
    
    CARDINAL_LOG_DEBUG("[VkAllocator] Allocated buffer memory: %llu bytes (type: %u)", 
                       (unsigned long long)mem_requirements.size, memory_type_index);
    
    return true;
}

/**
 * @brief Frees image and its associated memory.
 * @param alloc The allocator instance.
 * @param image Image handle to destroy.
 * @param memory Memory handle to free.
 */
void vk_allocator_free_image(VulkanAllocator* alloc, VkImage image, VkDeviceMemory memory) {
    if (!alloc) return;
    CARDINAL_LOG_INFO("[VkAllocator] free_image: image=%p mem=%p", (void*)image, (void*)memory);
    
    VkDeviceSize size = 0;
    if (memory != VK_NULL_HANDLE) {
        // Try to get the memory size for statistics (not always available)
        VkMemoryRequirements mem_req;
        if (image != VK_NULL_HANDLE) {
            vkGetImageMemoryRequirements(alloc->device, image, &mem_req);
            size = mem_req.size;
        }
        
        vkFreeMemory(alloc->device, memory, NULL);
        alloc->total_device_mem_freed += size;
        
        CARDINAL_LOG_INFO("[VkAllocator] Freed image memory: %llu bytes", (unsigned long long)size);
    }
    
    if (image != VK_NULL_HANDLE) {
        vkDestroyImage(alloc->device, image, NULL);
    }
}

/**
 * @brief Frees buffer and its associated memory.
 * @param alloc The allocator instance.
 * @param buffer Buffer handle to destroy.
 * @param memory Memory handle to free.
 */
void vk_allocator_free_buffer(VulkanAllocator* alloc, VkBuffer buffer, VkDeviceMemory memory) {
    if (!alloc) return;
    CARDINAL_LOG_INFO("[VkAllocator] free_buffer: buffer=%p mem=%p", (void*)buffer, (void*)memory);
    
    VkDeviceSize size = 0;
    if (memory != VK_NULL_HANDLE) {
        // Try to get the memory size for statistics (not always available)
        VkMemoryRequirements mem_req;
        if (buffer != VK_NULL_HANDLE) {
            vkGetBufferMemoryRequirements(alloc->device, buffer, &mem_req);
            size = mem_req.size;
        }
        
        vkFreeMemory(alloc->device, memory, NULL);
        alloc->total_device_mem_freed += size;
        
        CARDINAL_LOG_INFO("[VkAllocator] Freed buffer memory: %llu bytes", (unsigned long long)size);
    }
    
    if (buffer != VK_NULL_HANDLE) {
        vkDestroyBuffer(alloc->device, buffer, NULL);
    }
}
