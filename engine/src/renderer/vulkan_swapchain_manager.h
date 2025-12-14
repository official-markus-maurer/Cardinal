#ifndef VULKAN_SWAPCHAIN_MANAGER_H
#define VULKAN_SWAPCHAIN_MANAGER_H

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

/**
 * @file vulkan_swapchain_manager.h
 * @brief Vulkan swapchain management module.
 *
 * This module provides a clean interface for managing Vulkan swapchains,
 * including creation, recreation, and destruction operations.
 */

/**
 * @brief Swapchain manager structure.
 */
typedef struct VulkanSwapchainManager {
  VkDevice device;                 /**< Vulkan logical device. */
  VkPhysicalDevice physicalDevice; /**< Vulkan physical device. */
  VkSurfaceKHR surface;            /**< Vulkan surface. */

  VkSwapchainKHR swapchain;     /**< Current swapchain handle. */
  VkFormat format;              /**< Swapchain image format. */
  VkExtent2D extent;            /**< Swapchain extent (width and height). */
  VkColorSpaceKHR colorSpace;   /**< Swapchain color space. */
  VkPresentModeKHR presentMode; /**< Present mode used. */

  VkImage *images;         /**< Array of swapchain images. */
  VkImageView *imageViews; /**< Array of swapchain image views. */
  uint32_t imageCount;     /**< Number of images in the swapchain. */

  // Recreation tracking
  bool recreationPending; /**< True when recreation is needed on next frame. */
  uint64_t lastRecreationTime; /**< Timestamp of last recreation (in
                                  milliseconds). */
  uint32_t recreationCount;    /**< Number of recreations performed. */

  bool initialized; /**< Whether the manager is initialized. */
} VulkanSwapchainManager;

/**
 * @brief Swapchain creation configuration.
 */
typedef struct VulkanSwapchainCreateInfo {
  VkDevice device;                 /**< Vulkan logical device. */
  VkPhysicalDevice physicalDevice; /**< Vulkan physical device. */
  VkSurfaceKHR surface;            /**< Vulkan surface. */

  uint32_t preferredImageCount; /**< Preferred number of swapchain images (0 for
                                   automatic). */
  VkFormat preferredFormat; /**< Preferred image format (VK_FORMAT_UNDEFINED for
                               automatic). */
  VkColorSpaceKHR preferredColorSpace;   /**< Preferred color space. */
  VkPresentModeKHR preferredPresentMode; /**< Preferred present mode. */

  VkExtent2D windowExtent;     /**< Current window extent. */
  VkSwapchainKHR oldSwapchain; /**< Old swapchain for recreation (can be
                                  VK_NULL_HANDLE). */
} VulkanSwapchainCreateInfo;

/**
 * @brief Surface support details.
 */
typedef struct VulkanSurfaceSupport {
  VkSurfaceCapabilitiesKHR capabilities;
  VkSurfaceFormatKHR *formats;
  uint32_t formatCount;
  VkPresentModeKHR *presentModes;
  uint32_t presentModeCount;
} VulkanSurfaceSupport;

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Creates a swapchain manager.
 * 
 * @param manager Pointer to the
 * swapchain manager to initialize.
 * @param createInfo Creation parameters.
 *
 * @return true if successful, false otherwise.
 */
bool vk_swapchain_manager_create(VulkanSwapchainManager *manager,
                                 const VulkanSwapchainCreateInfo *createInfo);

/**
 * @brief Destroys a swapchain manager and all associated resources.
 *
 * @param manager Pointer to the swapchain manager to destroy.
 */
void vk_swapchain_manager_destroy(VulkanSwapchainManager *manager);

/**
 * @brief Recreates the swapchain (e.g., for window resize).
 *
 * @param manager Pointer to the swapchain manager.
 * @param newExtent New window extent.
 * @return true if successful, false otherwise.
 */
bool vk_swapchain_manager_recreate(VulkanSwapchainManager *manager,
                                   VkExtent2D newExtent);

/**
 * @brief Acquires the next image from the swapchain.
 *
 * @param manager Pointer to the swapchain manager.
 * @param timeout Timeout in nanoseconds.
 * @param semaphore Semaphore to signal when image is available.
 * @param fence Fence to signal when image is available (can be VK_NULL_HANDLE).
 * @param imageIndex Pointer to store the acquired image index.
 * @return VkResult from vkAcquireNextImageKHR.
 */
VkResult vk_swapchain_manager_acquire_image(VulkanSwapchainManager *manager,
                                            uint64_t timeout,
                                            VkSemaphore semaphore,
                                            VkFence fence,
                                            uint32_t *imageIndex);

/**
 * @brief Presents an image to the swapchain.
 *
 * @param manager Pointer to the swapchain manager.
 * @param presentQueue Queue to present on.
 * @param imageIndex Index of the image to present.
 * @param waitSemaphoreCount Number of semaphores to wait on.
 * @param waitSemaphores Semaphores to wait on before presenting.
 * @return VkResult from vkQueuePresentKHR.
 */
VkResult vk_swapchain_manager_present(VulkanSwapchainManager *manager,
                                      VkQueue presentQueue, uint32_t imageIndex,
                                      uint32_t waitSemaphoreCount,
                                      const VkSemaphore *waitSemaphores);

/**
 * @brief Queries surface support details.
 *
 * @param physicalDevice Physical device to query.
 * @param surface Surface to query support for.
 * @param support Pointer to store support details.
 * @return true if successful, false otherwise.
 */
bool vk_swapchain_query_surface_support(VkPhysicalDevice physicalDevice,
                                        VkSurfaceKHR surface,
                                        VulkanSurfaceSupport *support);

#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Frees surface support details.
 * 
 * @param support Pointer to
 * surface support details to free.
 */
void vk_swapchain_free_surface_support(VulkanSurfaceSupport *support);

/**
 * @brief Chooses the best surface format from available formats.
 *
 * @param availableFormats Array of available formats.
 * @param formatCount Number of available formats.
 * @param preferredFormat Preferred format (VK_FORMAT_UNDEFINED for automatic).
 * @param preferredColorSpace Preferred color space.
 * @return Best surface format.
 */
VkSurfaceFormatKHR vk_swapchain_choose_surface_format(
    const VkSurfaceFormatKHR *availableFormats, uint32_t formatCount,
    VkFormat preferredFormat, VkColorSpaceKHR preferredColorSpace);

/**
 * @brief Chooses the best present mode from available modes.
 *
 * @param availableModes Array of available present modes.
 * @param modeCount Number of available modes.
 * @param preferredMode Preferred present mode.
 * @return Best present mode.
 */
VkPresentModeKHR
vk_swapchain_choose_present_mode(const VkPresentModeKHR *availableModes,
                                 uint32_t modeCount,
                                 VkPresentModeKHR preferredMode);

/**
 * @brief Chooses the swapchain extent based on surface capabilities.
 *
 * @param capabilities Surface capabilities.
 * @param windowExtent Current window extent.
 * @return Chosen swapchain extent.
 */
VkExtent2D
vk_swapchain_choose_extent(const VkSurfaceCapabilitiesKHR *capabilities,
                           VkExtent2D windowExtent);

/**
 * @brief Marks the swapchain for recreation on the next frame.
 *
 * @param manager Pointer to the swapchain manager.
 */
void vk_swapchain_manager_mark_for_recreation(VulkanSwapchainManager *manager);

/**
 * @brief Checks if swapchain recreation is pending.
 *
 * @param manager Pointer to the swapchain manager.
 * @return true if recreation is pending, false otherwise.
 */
bool vk_swapchain_manager_is_recreation_pending(
    const VulkanSwapchainManager *manager);

/**
 * @brief Gets the current swapchain handle.
 *
 * @param manager Pointer to the swapchain manager.
 * @return Current swapchain handle.
 */
VkSwapchainKHR
vk_swapchain_manager_get_swapchain(const VulkanSwapchainManager *manager);

/**
 * @brief Gets the swapchain image format.
 *
 * @param manager Pointer to the swapchain manager.
 * @return Swapchain image format.
 */
VkFormat vk_swapchain_manager_get_format(const VulkanSwapchainManager *manager);

/**
 * @brief Gets the swapchain extent.
 *
 * @param manager Pointer to the swapchain manager.
 * @return Swapchain extent.
 */
VkExtent2D
vk_swapchain_manager_get_extent(const VulkanSwapchainManager *manager);

/**
 * @brief Gets the swapchain image count.
 *
 * @param manager Pointer to the swapchain manager.
 * @return Number of swapchain images.
 */
uint32_t
vk_swapchain_manager_get_image_count(const VulkanSwapchainManager *manager);

/**
 * @brief Gets the swapchain images array.
 *
 * @param manager Pointer to the swapchain manager.
 * @return Pointer to swapchain images array.
 */
const VkImage *
vk_swapchain_manager_get_images(const VulkanSwapchainManager *manager);

/**
 * @brief Gets the swapchain image views array.
 *
 * @param manager Pointer to the swapchain manager.
 * @return Pointer to swapchain image views array.
 */
const VkImageView *
vk_swapchain_manager_get_image_views(const VulkanSwapchainManager *manager);

/**
 * @brief Gets recreation statistics.
 *
 * @param manager Pointer to the swapchain manager.
 * @param recreationCount Pointer to store recreation count.
 * @param lastRecreationTime Pointer to store last recreation time.
 */
void vk_swapchain_manager_get_recreation_stats(
    const VulkanSwapchainManager *manager, uint32_t *recreationCount,
    uint64_t *lastRecreationTime);

#ifdef __cplusplus
}
#endif

#endif // VULKAN_SWAPCHAIN_MANAGER_H
