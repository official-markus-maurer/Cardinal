#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <GLFW/glfw3.h>
#include <vulkan/vulkan.h>
#include "cardinal/core/window.h"
#include "vulkan_state.h"
#include "vulkan_instance.h"
#include "cardinal/core/log.h"

/**
 * @brief Vulkan debug callback for validation messages.
 * @param message_severity Severity level.
 * @param message_type Type of message.
 * @param callback_data Message data.
 * @param user_data User data (unused).
 * @return VK_FALSE.
 * 
 * @todo Make callback configurable for different severity handling.
 */
static VKAPI_ATTR VkBool32 VKAPI_CALL debug_callback(
    VkDebugUtilsMessageSeverityFlagBitsEXT message_severity,
    VkDebugUtilsMessageTypeFlagsEXT message_type,
    const VkDebugUtilsMessengerCallbackDataEXT* callback_data,
    void* user_data) {
    (void)message_type;
    (void)user_data;
    
    const char* severity_str = "UNKNOWN";
    if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) severity_str = "ERROR";
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) severity_str = "WARNING";
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) severity_str = "INFO";
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT) severity_str = "VERBOSE";
    
    const char* msg_id_name = callback_data && callback_data->pMessageIdName ? callback_data->pMessageIdName : "(no-id)";
    int32_t msg_id_num = callback_data ? callback_data->messageIdNumber : -1;

    // Compose a concise message including ID and original message
    char buffer[1400];
    snprintf(buffer, sizeof(buffer), "VK_DEBUG [%s] (%d:%s): %s", severity_str, msg_id_num, msg_id_name, callback_data ? callback_data->pMessage : "(null)");
    
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
    VkDebugUtilsMessageSeverityFlagsEXT sev = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
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
    VkApplicationInfo ai = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO };
    ai.pApplicationName = "Cardinal";
    ai.applicationVersion = VK_MAKE_VERSION(1,0,0);
    ai.pEngineName = "Cardinal";
    ai.engineVersion = VK_MAKE_VERSION(1,0,0);
    ai.apiVersion = VK_API_VERSION_1_2;
    CARDINAL_LOG_INFO("[INSTANCE] Using Vulkan API version 1.2");

    uint32_t glfw_count = 0;
    const char** glfw_exts = glfwGetRequiredInstanceExtensions(&glfw_count);
    CARDINAL_LOG_INFO("[INSTANCE] GLFW requires %u extensions", glfw_count);
    for (uint32_t i = 0; i < glfw_count; i++) {
        CARDINAL_LOG_INFO("[INSTANCE] GLFW extension %u: %s", i, glfw_exts[i]);
    }

    const char* layers[] = { "VK_LAYER_KHRONOS_validation" };
    VkInstanceCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
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
            for (uint32_t i = 0; i < glfw_count; ++i) tmp_exts[i] = glfw_exts[i];
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

        VkDebugUtilsMessengerCreateInfoEXT debug_ci = { .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT };
        debug_ci.messageSeverity = select_debug_severity_from_log_level();
        debug_ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        debug_ci.pfnUserCallback = debug_callback;
        ci.pNext = &debug_ci;
        CARDINAL_LOG_INFO("[INSTANCE] Debug messenger configured with severity flags: 0x%x", debug_ci.messageSeverity);

        CARDINAL_LOG_INFO("[INSTANCE] Creating Vulkan instance...");
        VkResult result = vkCreateInstance(&ci, NULL, &s->instance);
        CARDINAL_LOG_INFO("[INSTANCE] Instance creation result: %d", result);
        if (result != VK_SUCCESS) {
            CARDINAL_LOG_ERROR("[INSTANCE] vkCreateInstance failed with result: %d", result);
            if (tmp_exts) free((void*)tmp_exts);
            return false;
        }
        if (tmp_exts) free((void*)tmp_exts);

        PFN_vkCreateDebugUtilsMessengerEXT dfunc = (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(s->instance, "vkCreateDebugUtilsMessengerEXT");
        if (dfunc) {
            VkDebugUtilsMessengerCreateInfoEXT dbg_ci = { .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT };
            dbg_ci.messageSeverity = select_debug_severity_from_log_level();
            dbg_ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
            dbg_ci.pfnUserCallback = debug_callback;
            dfunc(s->instance, &dbg_ci, NULL, &s->debug_messenger);
        }
    } else {
        CARDINAL_LOG_INFO("[INSTANCE] Validation disabled - creating instance without validation layers");
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
    if (count == 0) {
        CARDINAL_LOG_ERROR("[DEVICE] No physical devices found!");
        return false;
    }
    VkPhysicalDevice* devices = (VkPhysicalDevice*)malloc(sizeof(VkPhysicalDevice) * count);
    result = vkEnumeratePhysicalDevices(s->instance, &count, devices);
    CARDINAL_LOG_INFO("[DEVICE] Enumerate devices result: %d", result);
    s->physical_device = devices[0];
    
    // Log device properties
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(s->physical_device, &props);
    CARDINAL_LOG_INFO("[DEVICE] Selected device: %s (API %u.%u.%u, Driver %u.%u.%u)", 
        props.deviceName,
        VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion), VK_VERSION_PATCH(props.apiVersion),
        VK_VERSION_MAJOR(props.driverVersion), VK_VERSION_MINOR(props.driverVersion), VK_VERSION_PATCH(props.driverVersion));
    
    free(devices);
    return s->physical_device != VK_NULL_HANDLE;
}

/**
 * @brief Creates the logical Vulkan device.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 * 
 * @todo Improve queue family selection for dedicated transfer queues.
 * @todo Enable device extensions like VK_KHR_dynamic_rendering for modern rendering.
 */
bool vk_create_device(VulkanState* s) {
    CARDINAL_LOG_INFO("[DEVICE] Starting logical device creation");
    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical_device, &qf_count, NULL);
    CARDINAL_LOG_INFO("[DEVICE] Found %u queue families", qf_count);
    VkQueueFamilyProperties* qfp = (VkQueueFamilyProperties*)malloc(sizeof(VkQueueFamilyProperties)*qf_count);
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical_device, &qf_count, qfp);
    
    s->graphics_queue_family = 0;
    for (uint32_t i = 0; i < qf_count; ++i) {
        if (qfp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { s->graphics_queue_family = i; break; }
    }
    CARDINAL_LOG_INFO("[DEVICE] Selected graphics family: %u", s->graphics_queue_family);

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = s->graphics_queue_family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;

    const char* device_extensions[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };

    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = (uint32_t)(sizeof(device_extensions) / sizeof(device_extensions[0]));
    dci.ppEnabledExtensionNames = device_extensions;

    CARDINAL_LOG_INFO("[DEVICE] Enabling %u device extension(s)", dci.enabledExtensionCount);
    for (uint32_t i = 0; i < dci.enabledExtensionCount; ++i) {
        CARDINAL_LOG_INFO("[DEVICE] Device extension %u: %s", i, device_extensions[i]);
    }

    VkResult result = vkCreateDevice(s->physical_device, &dci, NULL, &s->device);
    CARDINAL_LOG_INFO("[DEVICE] Device creation result: %d", result);
    free(qfp);
    if (result != VK_SUCCESS) { return false; }

    vkGetDeviceQueue(s->device, s->graphics_queue_family, 0, &s->graphics_queue);
    CARDINAL_LOG_INFO("[DEVICE] Retrieved graphics queue");
    s->present_queue_family = s->graphics_queue_family;
    s->present_queue = s->graphics_queue;

    return true;
}

bool vk_create_surface(VulkanState* s, struct CardinalWindow* window) {
    CARDINAL_LOG_INFO("[SURFACE] Creating surface from window");
    VkWin32SurfaceCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR };
    sci.hinstance = GetModuleHandle(NULL);
    sci.hwnd = (HWND)cardinal_window_get_native_handle(window);
    VkResult result = vkCreateWin32SurfaceKHR(s->instance, &sci, NULL, &s->surface);
    CARDINAL_LOG_INFO("[SURFACE] Surface create result: %d", result);
    return result == VK_SUCCESS;
}

void vk_destroy_device_objects(VulkanState* s) {
    CARDINAL_LOG_INFO("[DESTROY] Destroying device objects and cleanup");
    if (s->device) { vkDeviceWaitIdle(s->device); }
    if (s->device) { vkDestroyDevice(s->device, NULL); s->device = VK_NULL_HANDLE; }
    if (s->debug_messenger) {
        PFN_vkDestroyDebugUtilsMessengerEXT dfunc = (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(s->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (dfunc) { dfunc(s->instance, s->debug_messenger, NULL); }
        s->debug_messenger = VK_NULL_HANDLE;
    }
    if (s->surface) { vkDestroySurfaceKHR(s->instance, s->surface, NULL); s->surface = VK_NULL_HANDLE; }
    if (s->instance) { vkDestroyInstance(s->instance, NULL); s->instance = VK_NULL_HANDLE; }
}

void vk_recreate_debug_messenger(VulkanState* s) {
    if (!s || !s->instance) return;
    if (!validation_enabled()) return;
    // Destroy existing messenger if any
    if (s->debug_messenger) {
        PFN_vkDestroyDebugUtilsMessengerEXT dfunc = (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(s->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (dfunc) { dfunc(s->instance, s->debug_messenger, NULL); }
        s->debug_messenger = VK_NULL_HANDLE;
    }
    PFN_vkCreateDebugUtilsMessengerEXT cfunc = (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(s->instance, "vkCreateDebugUtilsMessengerEXT");
    if (cfunc) {
        VkDebugUtilsMessengerCreateInfoEXT ci = { .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT };
        ci.messageSeverity = select_debug_severity_from_log_level();
        ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        ci.pfnUserCallback = debug_callback;
        VkResult r = cfunc(s->instance, &ci, NULL, &s->debug_messenger);
        CARDINAL_LOG_INFO("[INSTANCE] Recreated debug messenger (result=%d) with severity flags: 0x%x", r, ci.messageSeverity);
    }
}
