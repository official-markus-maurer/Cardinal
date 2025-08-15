#include "cardinal/core/log.h"
#include "cardinal/core/window.h"
#include "vulkan_state.h"
#include <GLFW/glfw3.h>
#include <cardinal/renderer/vulkan_instance.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

/**
 * @brief Vulkan debug callback for validation messages.
 * @param message_severity Severity level.
 * @param message_type Type of message.
 * @param callback_data Message data.
 * @param user_data User data (unused).
 * @return VK_FALSE.
 *
 * @todo Make callback configurable for different severity handling. (Include to spdlog?)
 */
static VKAPI_ATTR VkBool32 VKAPI_CALL
debug_callback(VkDebugUtilsMessageSeverityFlagBitsEXT message_severity,
               VkDebugUtilsMessageTypeFlagsEXT message_type,
               const VkDebugUtilsMessengerCallbackDataEXT* callback_data, void* user_data) {
    (void)message_type;
    (void)user_data;

    const char* severity_str = "UNKNOWN";
    if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
        severity_str = "ERROR";
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT)
        severity_str = "WARNING";
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT)
        severity_str = "INFO";
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT)
        severity_str = "VERBOSE";

    const char* msg_id_name =
        callback_data && callback_data->pMessageIdName ? callback_data->pMessageIdName : "(no-id)";
    int32_t msg_id_num = callback_data ? callback_data->messageIdNumber : -1;

    // Compose a concise message including ID and original message
    char buffer[1400];
    snprintf(buffer, sizeof(buffer), "VK_DEBUG [%s] (%d:%s): %s", severity_str, msg_id_num,
             msg_id_name, callback_data ? callback_data->pMessage : "(null)");

    if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        CARDINAL_LOG_ERROR("%s", buffer);
    } else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        CARDINAL_LOG_WARN("%s", buffer);
    } else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) {
        CARDINAL_LOG_INFO("%s", buffer);
    } else {
        CARDINAL_LOG_DEBUG("%s", buffer);
    }
    return VK_FALSE;
}

// Select severity flags for debug utils messenger based on current engine log level
static VkDebugUtilsMessageSeverityFlagsEXT select_debug_severity_from_log_level(void) {
    CardinalLogLevel lvl = cardinal_log_get_level();
    VkDebugUtilsMessageSeverityFlagsEXT sev = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                                              VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    if (lvl <= CARDINAL_LOG_LEVEL_INFO) {
        sev |= VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT;
    }
    if (lvl <= CARDINAL_LOG_LEVEL_DEBUG) {
        sev |= VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT;
    }
    return sev;
}

// Helper: check if validation should be enabled (debug or CMake toggle)
static bool validation_enabled(void) {
#if defined(_DEBUG) || defined(CARDINAL_ENABLE_VK_VALIDATION)
    return true;
#else
    return false;
#endif
}

/**
 * @brief Creates the Vulkan instance.
 * @param s Vulkan state structure.
 * @return true on success, false on failure.
 *
 * @todo Add support for VK_KHR_portability extension for macOS compatibility.
 */
bool vk_create_instance(VulkanState* s) {
    CARDINAL_LOG_INFO("[INSTANCE] Starting Vulkan instance creation");
    VkApplicationInfo ai = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO};
    ai.pApplicationName = "Cardinal";
    ai.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    ai.pEngineName = "Cardinal";
    ai.engineVersion = VK_MAKE_VERSION(1, 0, 0);
    ai.apiVersion = VK_MAKE_API_VERSION(0, 1, 4, 325);
    CARDINAL_LOG_INFO("[INSTANCE] Using Vulkan API version 1.4.325");

    uint32_t glfw_count = 0;
    const char** glfw_exts = glfwGetRequiredInstanceExtensions(&glfw_count);
    CARDINAL_LOG_INFO("[INSTANCE] GLFW requires %u extensions", glfw_count);
    for (uint32_t i = 0; i < glfw_count; i++) {
        CARDINAL_LOG_INFO("[INSTANCE] GLFW extension %u: %s", i, glfw_exts[i]);
    }

    const char* layers[] = {"VK_LAYER_KHRONOS_validation"};
    VkInstanceCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ci.pApplicationInfo = &ai;

    // Build extension list, append debug utils if validation is enabled and not already present
    const char** enabled_exts = glfw_exts;
    uint32_t enabled_ext_count = glfw_count;
    const bool enable_validation = validation_enabled();
    if (enable_validation) {
        CARDINAL_LOG_INFO("[INSTANCE] Validation enabled - enabling validation layers");
        bool need_debug_utils = true;
        for (uint32_t i = 0; i < glfw_count; ++i) {
            if (strcmp(glfw_exts[i], VK_EXT_DEBUG_UTILS_EXTENSION_NAME) == 0) {
                need_debug_utils = false;
                CARDINAL_LOG_INFO("[INSTANCE] Debug utils extension already in GLFW list");
                break;
            }
        }
        const char** tmp_exts = NULL;
        if (need_debug_utils) {
            CARDINAL_LOG_INFO("[INSTANCE] Adding debug utils extension");
            tmp_exts = (const char**)malloc(sizeof(char*) * (glfw_count + 1));
            for (uint32_t i = 0; i < glfw_count; ++i)
                tmp_exts[i] = glfw_exts[i];
            tmp_exts[glfw_count] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
            enabled_exts = tmp_exts;
            enabled_ext_count = glfw_count + 1;
        }
        ci.enabledLayerCount = 1;
        ci.ppEnabledLayerNames = layers;
        CARDINAL_LOG_INFO("[INSTANCE] Enabling validation layer: %s", layers[0]);

        // Ensure required instance extensions are set (GLFW + VK_EXT_debug_utils if added)
        ci.enabledExtensionCount = enabled_ext_count;
        ci.ppEnabledExtensionNames = enabled_exts;
        CARDINAL_LOG_INFO("[INSTANCE] Final extension count: %u", enabled_ext_count);
        for (uint32_t i = 0; i < enabled_ext_count; i++) {
            CARDINAL_LOG_INFO("[INSTANCE] Extension %u: %s", i, enabled_exts[i]);
        }

        VkDebugUtilsMessengerCreateInfoEXT debug_ci = {
            .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT};
        debug_ci.messageSeverity = select_debug_severity_from_log_level();
        debug_ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                               VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                               VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        debug_ci.pfnUserCallback = debug_callback;
        ci.pNext = &debug_ci;
        CARDINAL_LOG_INFO("[INSTANCE] Debug messenger configured with severity flags: 0x%x",
                          debug_ci.messageSeverity);

        CARDINAL_LOG_INFO("[INSTANCE] Creating Vulkan instance...");
        VkResult result = vkCreateInstance(&ci, NULL, &s->instance);
        CARDINAL_LOG_INFO("[INSTANCE] Instance creation result: %d", result);
        if (result != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[INSTANCE] vkCreateInstance failed with result: %d", result);
            if (tmp_exts)
                free((void*)tmp_exts);
            return false;
        }
        if (tmp_exts)
            free((void*)tmp_exts);

        PFN_vkCreateDebugUtilsMessengerEXT dfunc =
            (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
                s->instance, "vkCreateDebugUtilsMessengerEXT");
        if (dfunc) {
            VkDebugUtilsMessengerCreateInfoEXT dbg_ci = {
                .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT};
            dbg_ci.messageSeverity = select_debug_severity_from_log_level();
            dbg_ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                                 VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                                 VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
            dbg_ci.pfnUserCallback = debug_callback;
            dfunc(s->instance, &dbg_ci, NULL, &s->debug_messenger);
        }
    } else {
        CARDINAL_LOG_INFO(
            "[INSTANCE] Validation disabled - creating instance without validation layers");
        ci.enabledLayerCount = 0;
        ci.ppEnabledLayerNames = NULL;
        ci.enabledExtensionCount = enabled_ext_count;
        ci.ppEnabledExtensionNames = enabled_exts;

        CARDINAL_LOG_INFO("[INSTANCE] Final extension count: %u", enabled_ext_count);
        for (uint32_t i = 0; i < enabled_ext_count; i++) {
            CARDINAL_LOG_INFO("[INSTANCE] Extension %u: %s", i, enabled_exts[i]);
        }

        CARDINAL_LOG_INFO("[INSTANCE] Creating Vulkan instance...");
        VkResult result = vkCreateInstance(&ci, NULL, &s->instance);
        CARDINAL_LOG_INFO("[INSTANCE] Instance creation result: %d", result);
        if (result != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[INSTANCE] vkCreateInstance failed with result: %d", result);
            return false;
        }
    }

    return true;
}

/**
 * @brief Selects a suitable physical device.
 * @param s Vulkan state.
 * @return true if device selected, false otherwise.
 *
 * @todo Refactor to support multi-GPU selection with scoring.
 */
bool vk_pick_physical_device(VulkanState* s) {
    CARDINAL_LOG_INFO("[DEVICE] Starting physical device selection");
    uint32_t count = 0;
    VkResult result = vkEnumeratePhysicalDevices(s->instance, &count, NULL);
    CARDINAL_LOG_INFO("[DEVICE] Found %u physical devices, enumerate result: %d", count, result);
    (void)result; // silence unused in non-debug builds
    if (count == 0) {
        CARDINAL_LOG_ERROR("[DEVICE] No physical devices found!");
        return false;
    }
    VkPhysicalDevice* devices = (VkPhysicalDevice*)malloc(sizeof(VkPhysicalDevice) * count);
    result = vkEnumeratePhysicalDevices(s->instance, &count, devices);
    CARDINAL_LOG_INFO("[DEVICE] Enumerate devices result: %d", result);
    (void)result; // silence unused in non-debug builds
    s->physical_device = devices[0];

    // Log device properties
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(s->physical_device, &props);
    CARDINAL_LOG_INFO("[DEVICE] Selected device: %s (API %u.%u.%u, Driver %u.%u.%u)",
                      props.deviceName, VK_VERSION_MAJOR(props.apiVersion),
                      VK_VERSION_MINOR(props.apiVersion), VK_VERSION_PATCH(props.apiVersion),
                      VK_VERSION_MAJOR(props.driverVersion), VK_VERSION_MINOR(props.driverVersion),
                      VK_VERSION_PATCH(props.driverVersion));

    free(devices);
    return s->physical_device != VK_NULL_HANDLE;
}

/**
 * @brief Creates the logical Vulkan device.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 *
 * @todo Improve queue family selection for dedicated transfer queues.
 */
bool vk_create_device(VulkanState* s) {
    CARDINAL_LOG_INFO("[DEVICE] Starting logical device creation");
    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical_device, &qf_count, NULL);
    CARDINAL_LOG_INFO("[DEVICE] Found %u queue families", qf_count);
    VkQueueFamilyProperties* qfp =
        (VkQueueFamilyProperties*)malloc(sizeof(VkQueueFamilyProperties) * qf_count);
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical_device, &qf_count, qfp);

    s->graphics_queue_family = 0;
    for (uint32_t i = 0; i < qf_count; ++i) {
        if (qfp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
            s->graphics_queue_family = i;
            break;
        }
    }
    CARDINAL_LOG_INFO("[DEVICE] Selected graphics family: %u", s->graphics_queue_family);

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = s->graphics_queue_family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;

    // Query supported Vulkan API version
    VkPhysicalDeviceProperties physicalDeviceProperties;
    vkGetPhysicalDeviceProperties(s->physical_device, &physicalDeviceProperties);
    uint32_t apiVersion = physicalDeviceProperties.apiVersion;
    uint32_t majorVersion = VK_VERSION_MAJOR(apiVersion);
    uint32_t minorVersion = VK_VERSION_MINOR(apiVersion);
    CARDINAL_LOG_INFO("[DEVICE] Physical device supports Vulkan %u.%u.%u", majorVersion,
                      minorVersion, VK_VERSION_PATCH(apiVersion));

    // Require Vulkan 1.4 core support
    // Require Vulkan 1.4 as minimum - no fallbacks
    bool vulkan_14_supported = (majorVersion > 1) || (majorVersion == 1 && minorVersion >= 4);
    bool vulkan_12_supported = (majorVersion > 1) || (majorVersion == 1 && minorVersion >= 2);
    if (!vulkan_14_supported) {
        CARDINAL_LOG_ERROR("[DEVICE] Vulkan 1.4 core is required but not supported (found %u.%u)",
                           majorVersion, minorVersion);
        free(qfp);
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 core support confirmed");

    // Only require VK_KHR_swapchain extension - dynamic rendering is in 1.3 core
    const char* device_extensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    uint32_t enabled_extension_count = 1;

    // Setup Vulkan 1.4, 1.3, and 1.2 feature chain
    VkPhysicalDeviceVulkan14Features vulkan14Features = {0};
    vulkan14Features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES;
    vulkan14Features.pNext = NULL;

    VkPhysicalDeviceVulkan13Features vulkan13Features = {0};
    vulkan13Features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    vulkan13Features.pNext = &vulkan14Features;

    VkPhysicalDeviceVulkan12Features vulkan12Features = {0};
    vulkan12Features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    vulkan12Features.pNext = &vulkan13Features;

    VkPhysicalDeviceFeatures2 deviceFeatures2 = {0};
    deviceFeatures2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    deviceFeatures2.pNext = &vulkan12Features;

    // Query available Vulkan 1.2, 1.3 and 1.4 features
    vkGetPhysicalDeviceFeatures2(s->physical_device, &deviceFeatures2);
    CARDINAL_LOG_INFO("[DEVICE] Queried Vulkan 1.2, 1.3 and 1.4 features");

    // Require all essential Vulkan 1.3 features - no conditionals
    if (!vulkan13Features.dynamicRendering) {
        CARDINAL_LOG_ERROR("[DEVICE] dynamicRendering is required but not supported by device");
        free(qfp);
        return false;
    }
    if (!vulkan13Features.synchronization2) {
        CARDINAL_LOG_ERROR("[DEVICE] synchronization2 is required but not supported by device");
        free(qfp);
        return false;
    }
    if (!vulkan13Features.maintenance4) {
        CARDINAL_LOG_ERROR("[DEVICE] maintenance4 is required but not supported by device");
        free(qfp);
        return false;
    }
    if (!vulkan12Features.bufferDeviceAddress) {
        CARDINAL_LOG_ERROR("[DEVICE] bufferDeviceAddress is required but not supported by device");
        free(qfp);
        return false;
    }

    // Enable all required Vulkan 1.2 features
    vulkan12Features.bufferDeviceAddress = VK_TRUE;

    // Enable all required Vulkan 1.3 features
    vulkan13Features.dynamicRendering = VK_TRUE;
    vulkan13Features.synchronization2 = VK_TRUE;
    vulkan13Features.maintenance4 = VK_TRUE;

    // Enable useful Vulkan 1.4 features if available
    if (vulkan14Features.globalPriorityQuery) {
        vulkan14Features.globalPriorityQuery = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 globalPriorityQuery: enabled");
    }
    if (vulkan14Features.shaderSubgroupRotate) {
        vulkan14Features.shaderSubgroupRotate = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 shaderSubgroupRotate: enabled");
    }
    if (vulkan14Features.shaderFloatControls2) {
        vulkan14Features.shaderFloatControls2 = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 shaderFloatControls2: enabled");
    }
    if (vulkan14Features.shaderExpectAssume) {
        vulkan14Features.shaderExpectAssume = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 shaderExpectAssume: enabled");
    }

    // Log enabled feature status
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.2 feature status:");
    CARDINAL_LOG_INFO("[DEVICE]   bufferDeviceAddress: enabled");
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.3 feature status:");
    CARDINAL_LOG_INFO("[DEVICE]   synchronization2: enabled");
    CARDINAL_LOG_INFO("[DEVICE]   maintenance4: enabled");
    CARDINAL_LOG_INFO("[DEVICE]   dynamicRendering: enabled");

    CARDINAL_LOG_INFO("[DEVICE] Enabling required Vulkan 1.2 features: bufferDeviceAddress");
    CARDINAL_LOG_INFO("[DEVICE] Enabling required Vulkan 1.3 features: dynamicRendering + "
                      "synchronization2 + maintenance4");
    CARDINAL_LOG_INFO("[DEVICE] Enabling optional Vulkan 1.4 features where available");

    // Set up device creation with complete feature chain
    deviceFeatures2.pNext = &vulkan12Features;

    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = enabled_extension_count;
    dci.ppEnabledExtensionNames = device_extensions;
    dci.pNext = &deviceFeatures2;

    CARDINAL_LOG_INFO("[DEVICE] Enabling %u device extension(s)", dci.enabledExtensionCount);
    for (uint32_t i = 0; i < dci.enabledExtensionCount; ++i) {
        CARDINAL_LOG_INFO("[DEVICE] Device extension %u: %s", i, device_extensions[i]);
    }

    VkResult result = vkCreateDevice(s->physical_device, &dci, NULL, &s->device);
    CARDINAL_LOG_INFO("[DEVICE] Device creation result: %d", result);
    free(qfp);
    if (result != VK_SUCCESS) {
        return false;
    }

    vkGetDeviceQueue(s->device, s->graphics_queue_family, 0, &s->graphics_queue);
    CARDINAL_LOG_INFO("[DEVICE] Retrieved graphics queue");
    s->present_queue_family = s->graphics_queue_family;
    s->present_queue = s->graphics_queue;

    // Set dynamic rendering support flag and version feature flags
    s->supports_dynamic_rendering = true; // required
    s->supports_vulkan_12_features = vulkan_12_supported;
    s->supports_vulkan_13_features = true;    // required
    s->supports_vulkan_14_features = true;    // required
    s->supports_maintenance4 = true;          // required
    s->supports_buffer_device_address = true; // required
    CARDINAL_LOG_INFO("[DEVICE] Dynamic rendering support: enabled (required)");
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.2 features: %s",
                      s->supports_vulkan_12_features ? "available" : "unavailable");
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.3 features: available (required)");
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.3 maintenance4: enabled (required)");
    CARDINAL_LOG_INFO("[DEVICE] Buffer device address: enabled (required)");

    // Load dynamic rendering function pointers (core)
    s->vkCmdBeginRendering =
        (PFN_vkCmdBeginRendering)vkGetDeviceProcAddr(s->device, "vkCmdBeginRendering");
    s->vkCmdEndRendering =
        (PFN_vkCmdEndRendering)vkGetDeviceProcAddr(s->device, "vkCmdEndRendering");
    CARDINAL_LOG_INFO("[DEVICE] Loaded vkCmdBeginRendering: %p, vkCmdEndRendering: %p",
                      (void*)s->vkCmdBeginRendering, (void*)s->vkCmdEndRendering);

    // Load synchronization2 function pointer (core)
    s->vkCmdPipelineBarrier2 =
        (PFN_vkCmdPipelineBarrier2)vkGetDeviceProcAddr(s->device, "vkCmdPipelineBarrier2");
    if (!s->vkCmdPipelineBarrier2) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to load vkCmdPipelineBarrier2 (required)");
        free(qfp);
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] Synchronization2 function loaded (vkCmdPipelineBarrier2)");

    // Load maintenance4 core functions (Vulkan 1.3): vkGetDeviceBufferMemoryRequirements /
    // vkGetDeviceImageMemoryRequirements
    s->vkGetDeviceBufferMemoryRequirements =
        (PFN_vkGetDeviceBufferMemoryRequirements)vkGetDeviceProcAddr(
            s->device, "vkGetDeviceBufferMemoryRequirements");
    s->vkGetDeviceImageMemoryRequirements =
        (PFN_vkGetDeviceImageMemoryRequirements)vkGetDeviceProcAddr(
            s->device, "vkGetDeviceImageMemoryRequirements");
    if (!s->vkGetDeviceBufferMemoryRequirements || !s->vkGetDeviceImageMemoryRequirements) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to load maintenance4 functions (required)");
        free(qfp);
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] maintenance4 functions loaded: BufferReqs=%p ImageReqs=%p",
                      (void*)s->vkGetDeviceBufferMemoryRequirements,
                      (void*)s->vkGetDeviceImageMemoryRequirements);

    // Load vkQueueSubmit2 (core)
    s->vkQueueSubmit2 = (PFN_vkQueueSubmit2)vkGetDeviceProcAddr(s->device, "vkQueueSubmit2");
    if (!s->vkQueueSubmit2) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to load vkQueueSubmit2 (required)");
        free(qfp);
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] Loaded vkQueueSubmit2: %p", (void*)s->vkQueueSubmit2);

    // Load timeline semaphore function pointers (Vulkan 1.3 core - guaranteed available)
    s->vkWaitSemaphores = (PFN_vkWaitSemaphores)vkGetDeviceProcAddr(s->device, "vkWaitSemaphores");
    s->vkSignalSemaphore =
        (PFN_vkSignalSemaphore)vkGetDeviceProcAddr(s->device, "vkSignalSemaphore");
    s->vkGetSemaphoreCounterValue = (PFN_vkGetSemaphoreCounterValue)vkGetDeviceProcAddr(
        s->device, "vkGetSemaphoreCounterValue");

    CARDINAL_LOG_INFO("[DEVICE] Timeline semaphore functions loaded: vkWaitSemaphores=%p, "
                      "vkSignalSemaphore=%p, vkGetSemaphoreCounterValue=%p",
                      (void*)s->vkWaitSemaphores, (void*)s->vkSignalSemaphore,
                      (void*)s->vkGetSemaphoreCounterValue);

    // Load buffer device address function pointer (Vulkan 1.2 core, required in 1.3)
    s->vkGetBufferDeviceAddress =
        (PFN_vkGetBufferDeviceAddress)vkGetDeviceProcAddr(s->device, "vkGetBufferDeviceAddress");
    if (!s->vkGetBufferDeviceAddress) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to load vkGetBufferDeviceAddress (required)");
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] Buffer device address function loaded: vkGetBufferDeviceAddress=%p",
                      (void*)s->vkGetBufferDeviceAddress);

    // Initialize unified Vulkan allocator
    if (!vk_allocator_init(&s->allocator, s->physical_device, s->device,
                           s->vkGetDeviceBufferMemoryRequirements,
                           s->vkGetDeviceImageMemoryRequirements, s->vkGetBufferDeviceAddress)) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to initialize VulkanAllocator");
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] VulkanAllocator initialized (maintenance4=required, buffer device "
                      "address=enabled)");

    return true;
}

bool vk_create_surface(VulkanState* s, struct CardinalWindow* window) {
    CARDINAL_LOG_INFO("[SURFACE] Creating surface from window");
    VkWin32SurfaceCreateInfoKHR sci = {.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
    sci.hinstance = GetModuleHandle(NULL);
    sci.hwnd = (HWND)cardinal_window_get_native_handle(window);
    VkResult result = vkCreateWin32SurfaceKHR(s->instance, &sci, NULL, &s->surface);
    CARDINAL_LOG_INFO("[SURFACE] Surface create result: %d", result);
    return result == VK_SUCCESS;
}

void vk_destroy_device_objects(VulkanState* s) {
    CARDINAL_LOG_INFO("[DESTROY] Destroying device objects and cleanup");
    if (s->device) {
        vkDeviceWaitIdle(s->device);
    }

    // Shutdown Vulkan allocator before destroying device
    vk_allocator_shutdown(&s->allocator);

    if (s->device) {
        vkDestroyDevice(s->device, NULL);
        s->device = VK_NULL_HANDLE;
    }
    if (s->debug_messenger) {
        PFN_vkDestroyDebugUtilsMessengerEXT dfunc =
            (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
                s->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (dfunc) {
            dfunc(s->instance, s->debug_messenger, NULL);
        }
        s->debug_messenger = VK_NULL_HANDLE;
    }
    if (s->surface) {
        vkDestroySurfaceKHR(s->instance, s->surface, NULL);
        s->surface = VK_NULL_HANDLE;
    }
    if (s->instance) {
        vkDestroyInstance(s->instance, NULL);
        s->instance = VK_NULL_HANDLE;
    }
}

void vk_recreate_debug_messenger(VulkanState* s) {
    if (!s || !s->instance)
        return;
    if (!validation_enabled())
        return;
    // Destroy existing messenger if any
    if (s->debug_messenger) {
        PFN_vkDestroyDebugUtilsMessengerEXT dfunc =
            (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
                s->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (dfunc) {
            dfunc(s->instance, s->debug_messenger, NULL);
        }
        s->debug_messenger = VK_NULL_HANDLE;
    }
    PFN_vkCreateDebugUtilsMessengerEXT cfunc =
        (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(s->instance,
                                                                  "vkCreateDebugUtilsMessengerEXT");
    if (cfunc) {
        VkDebugUtilsMessengerCreateInfoEXT ci = {
            .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT};
        ci.messageSeverity = select_debug_severity_from_log_level();
        ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                         VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                         VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        ci.pfnUserCallback = debug_callback;
        VkResult r = cfunc(s->instance, &ci, NULL, &s->debug_messenger);
        CARDINAL_LOG_INFO(
            "[INSTANCE] Recreated debug messenger (result=%d) with severity flags: 0x%x", r,
            ci.messageSeverity);
        (void)r; // silence unused in non-debug builds
    }
}
