/**
 * @file vulkan_maintenance8_sync.c
 * @brief Implementation of VK_KHR_maintenance8 enhanced synchronization features
 *
 * This module implements the enhanced queue family ownership transfer functionality
 * introduced by VK_KHR_maintenance8, which allows more precise synchronization
 * during queue family ownership transfers by making both stage masks meaningful.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include "vulkan_state.h"
#include "cardinal/core/log.h"
#include "cardinal/renderer/vulkan_barrier_validation.h"
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <sys/syscall.h>
#endif

// Helper function to get current thread ID in a cross-platform way
static uint32_t get_current_thread_id(void) {
#ifdef _WIN32
    return GetCurrentThreadId();
#else
    return (uint32_t)syscall(SYS_gettid);
#endif
}

bool vk_create_enhanced_image_barrier(const VkQueueFamilyOwnershipTransferInfo* transfer_info,
                                       VkImage image,
                                       VkImageLayout old_layout,
                                       VkImageLayout new_layout,
                                       VkImageSubresourceRange subresource_range,
                                       VkImageMemoryBarrier2* out_barrier) {
    if (!transfer_info || !out_barrier) {
        CARDINAL_LOG_ERROR("[MAINTENANCE8_SYNC] Invalid parameters for enhanced image barrier creation");
        return false;
    }

    // Initialize the barrier structure
    memset(out_barrier, 0, sizeof(VkImageMemoryBarrier2));
    out_barrier->sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
    out_barrier->pNext = NULL;
    
    // Set stage and access masks
    out_barrier->srcStageMask = transfer_info->src_stage_mask;
    out_barrier->dstStageMask = transfer_info->dst_stage_mask;
    out_barrier->srcAccessMask = transfer_info->src_access_mask;
    out_barrier->dstAccessMask = transfer_info->dst_access_mask;
    
    // Set layout transition
    out_barrier->oldLayout = old_layout;
    out_barrier->newLayout = new_layout;
    
    // Set queue family ownership transfer
    out_barrier->srcQueueFamilyIndex = transfer_info->src_queue_family;
    out_barrier->dstQueueFamilyIndex = transfer_info->dst_queue_family;
    
    // Set image and subresource range
    out_barrier->image = image;
    out_barrier->subresourceRange = subresource_range;
    
    CARDINAL_LOG_DEBUG("[Thread %u] Enhanced image barrier: queue families %u->%u, stages 0x%llx->0x%llx",
                        get_current_thread_id(), transfer_info->src_queue_family, transfer_info->dst_queue_family,
                        (unsigned long long)transfer_info->src_stage_mask,
                        (unsigned long long)transfer_info->dst_stage_mask);
    
    return true;
}

bool vk_create_enhanced_buffer_barrier(const VkQueueFamilyOwnershipTransferInfo* transfer_info,
                                        VkBuffer buffer,
                                        VkDeviceSize offset,
                                        VkDeviceSize size,
                                        VkBufferMemoryBarrier2* out_barrier) {
    if (!transfer_info || !out_barrier) {
        CARDINAL_LOG_ERROR("[MAINTENANCE8_SYNC] Invalid parameters for enhanced buffer barrier creation");
        return false;
    }

    // Initialize the barrier structure
    memset(out_barrier, 0, sizeof(VkBufferMemoryBarrier2));
    out_barrier->sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2;
    out_barrier->pNext = NULL;
    
    // Set stage and access masks
    out_barrier->srcStageMask = transfer_info->src_stage_mask;
    out_barrier->dstStageMask = transfer_info->dst_stage_mask;
    out_barrier->srcAccessMask = transfer_info->src_access_mask;
    out_barrier->dstAccessMask = transfer_info->dst_access_mask;
    
    // Set queue family ownership transfer
    out_barrier->srcQueueFamilyIndex = transfer_info->src_queue_family;
    out_barrier->dstQueueFamilyIndex = transfer_info->dst_queue_family;
    
    // Set buffer and range
    out_barrier->buffer = buffer;
    out_barrier->offset = offset;
    out_barrier->size = size;
    
    CARDINAL_LOG_DEBUG("[Thread %u] Enhanced buffer barrier: queue families %u->%u, stages 0x%llx->0x%llx",
                        get_current_thread_id(), transfer_info->src_queue_family, transfer_info->dst_queue_family,
                        (unsigned long long)transfer_info->src_stage_mask,
                        (unsigned long long)transfer_info->dst_stage_mask);
    
    return true;
}

bool vk_record_enhanced_ownership_transfer(VkCommandBuffer cmd,
                                            const VkQueueFamilyOwnershipTransferInfo* transfer_info,
                                            uint32_t image_barrier_count,
                                            const VkImageMemoryBarrier2* image_barriers,
                                            uint32_t buffer_barrier_count,
                                            const VkBufferMemoryBarrier2* buffer_barriers,
                                            PFN_vkCmdPipelineBarrier2 vkCmdPipelineBarrier2_func) {
    if (!cmd || !transfer_info || !vkCmdPipelineBarrier2_func) {
        CARDINAL_LOG_ERROR("[MAINTENANCE8_SYNC] Invalid parameters for enhanced ownership transfer");
        return false;
    }

    if (image_barrier_count == 0 && buffer_barrier_count == 0) {
        CARDINAL_LOG_WARN("[MAINTENANCE8_SYNC] No barriers specified for ownership transfer");
        return true;
    }

    // Create dependency info structure
    VkDependencyInfo dependency_info = {0};
    dependency_info.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
    dependency_info.pNext = NULL;
    
    // Set dependency flags based on maintenance8 support
    if (transfer_info->use_maintenance8_enhancement && 
        transfer_info->src_queue_family != transfer_info->dst_queue_family) {
        // Use maintenance8 enhancement for meaningful stage masks in queue family ownership transfers
        dependency_info.dependencyFlags = VK_DEPENDENCY_QUEUE_FAMILY_OWNERSHIP_TRANSFER_USE_ALL_STAGES_BIT_KHR;
        CARDINAL_LOG_DEBUG("[MAINTENANCE8_SYNC] Using maintenance8 enhanced synchronization for queue family ownership transfer");
    } else {
        dependency_info.dependencyFlags = 0;
        if (transfer_info->src_queue_family != transfer_info->dst_queue_family) {
            CARDINAL_LOG_DEBUG("[MAINTENANCE8_SYNC] Using standard synchronization for queue family ownership transfer");
        }
    }
    
    // Set barrier counts and pointers
    dependency_info.imageMemoryBarrierCount = image_barrier_count;
    dependency_info.pImageMemoryBarriers = image_barriers;
    dependency_info.bufferMemoryBarrierCount = buffer_barrier_count;
    dependency_info.pBufferMemoryBarriers = buffer_barriers;
    
    CARDINAL_LOG_DEBUG("[Thread %u] Recording enhanced ownership transfer: %u images, %u buffers",
                        get_current_thread_id(), image_barrier_count, buffer_barrier_count);
    
    // Validate the pipeline barrier before execution
    if (!cardinal_barrier_validation_validate_pipeline_barrier(&dependency_info, cmd, get_current_thread_id())) {
        CARDINAL_LOG_WARN("[MAINTENANCE8_SYNC] Pipeline barrier validation failed for enhanced ownership transfer");
    }
    
    // Record the pipeline barrier
    vkCmdPipelineBarrier2_func(cmd, &dependency_info);
    
    CARDINAL_LOG_INFO("[MAINTENANCE8_SYNC] Recorded enhanced ownership transfer: %u image barriers, %u buffer barriers, maintenance8=%s",
                      image_barrier_count, buffer_barrier_count,
                      transfer_info->use_maintenance8_enhancement ? "enabled" : "disabled");
    
    return true;
}

/**
 * @brief Helper function to create a standard queue family ownership transfer info
 * 
 * @param src_queue_family Source queue family index
 * @param dst_queue_family Destination queue family index
 * @param src_stage_mask Source pipeline stage mask
 * @param dst_stage_mask Destination pipeline stage mask
 * @param src_access_mask Source access mask
 * @param dst_access_mask Destination access mask
 * @param supports_maintenance8 Whether maintenance8 extension is available
 * @param out_transfer_info Output transfer info structure
 * @return true on success, false on failure
 */
bool vk_create_queue_family_transfer_info(uint32_t src_queue_family,
                                           uint32_t dst_queue_family,
                                           VkPipelineStageFlags2 src_stage_mask,
                                           VkPipelineStageFlags2 dst_stage_mask,
                                           VkAccessFlags2 src_access_mask,
                                           VkAccessFlags2 dst_access_mask,
                                           bool supports_maintenance8,
                                           VkQueueFamilyOwnershipTransferInfo* out_transfer_info) {
    if (!out_transfer_info) {
        CARDINAL_LOG_ERROR("[MAINTENANCE8_SYNC] Invalid output parameter for transfer info creation");
        return false;
    }
    
    memset(out_transfer_info, 0, sizeof(VkQueueFamilyOwnershipTransferInfo));
    out_transfer_info->src_queue_family = src_queue_family;
    out_transfer_info->dst_queue_family = dst_queue_family;
    out_transfer_info->src_stage_mask = src_stage_mask;
    out_transfer_info->dst_stage_mask = dst_stage_mask;
    out_transfer_info->src_access_mask = src_access_mask;
    out_transfer_info->dst_access_mask = dst_access_mask;
    out_transfer_info->use_maintenance8_enhancement = supports_maintenance8 && (src_queue_family != dst_queue_family);
    
    CARDINAL_LOG_DEBUG("[MAINTENANCE8_SYNC] Created queue family transfer info: %u -> %u, maintenance8=%s",
                       src_queue_family, dst_queue_family,
                       out_transfer_info->use_maintenance8_enhancement ? "enabled" : "disabled");
    
    return true;
}