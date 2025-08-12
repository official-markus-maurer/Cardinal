#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <GLFW/glfw3.h>
#include <vulkan/vulkan.h>
#include "cardinal/core/window.h"
#include "vulkan_state.h"
#include "vulkan_instance.h"
#include "cardinal/core/log.h"

// Use centralized logger
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
    
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "VK_DEBUG [%s]: %s", severity_str, callback_data->pMessage);
    
    if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        LOG_ERROR("%s", buffer);
    } else {
        LOG_WARN("%s", buffer);
    }
    return VK_FALSE;
}

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

    // Build extension list, append debug utils in debug builds if not already present
    const char** enabled_exts = glfw_exts;
    uint32_t enabled_ext_count = glfw_count;
#ifdef _DEBUG
    CARDINAL_LOG_INFO("[INSTANCE] Debug build - enabling validation layers");
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
#else
    CARDINAL_LOG_INFO("[INSTANCE] Release build - no validation layers");
#endif

    ci.enabledExtensionCount = enabled_ext_count;
    ci.ppEnabledExtensionNames = enabled_exts;
    CARDINAL_LOG_INFO("[INSTANCE] Final extension count: %u", enabled_ext_count);
    for (uint32_t i = 0; i < enabled_ext_count; i++) {
        CARDINAL_LOG_INFO("[INSTANCE] Extension %u: %s", i, enabled_exts[i]);
    }
#ifdef _DEBUG
    ci.enabledLayerCount = 1;
    ci.ppEnabledLayerNames = layers;
    CARDINAL_LOG_INFO("[INSTANCE] Enabling validation layer: %s", layers[0]);
#else
    ci.enabledLayerCount = 0;
    ci.ppEnabledLayerNames = NULL;
#endif

#ifdef _DEBUG
    VkDebugUtilsMessengerCreateInfoEXT debug_ci = { .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT };
    debug_ci.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    debug_ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    debug_ci.pfnUserCallback = debug_callback;
    ci.pNext = &debug_ci;
    CARDINAL_LOG_INFO("[INSTANCE] Debug messenger configured for WARNING and ERROR messages");
#endif

    CARDINAL_LOG_INFO("[INSTANCE] Creating Vulkan instance...");
    VkResult result = vkCreateInstance(&ci, NULL, &s->instance);
    CARDINAL_LOG_INFO("[INSTANCE] Instance creation result: %d", result);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[INSTANCE] vkCreateInstance failed with result: %d", result);
#ifdef _DEBUG
        if (tmp_exts) free((void*)tmp_exts);
#endif
        return false;
    }

#ifdef _DEBUG
    if (tmp_exts) free((void*)tmp_exts);
    PFN_vkCreateDebugUtilsMessengerEXT dfunc = (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(s->instance, "vkCreateDebugUtilsMessengerEXT");
    if (dfunc) {
        VkDebugUtilsMessengerCreateInfoEXT dbg_ci = { .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT };
        dbg_ci.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        dbg_ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        dbg_ci.pfnUserCallback = debug_callback;
        dfunc(s->instance, &dbg_ci, NULL, &s->debug_messenger);
    }
#endif

    return true;
}

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

bool vk_create_device(VulkanState* s) {
    CARDINAL_LOG_INFO("[DEVICE] Starting logical device creation");
    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical_device, &qf_count, NULL);
    CARDINAL_LOG_INFO("[DEVICE] Found %u queue families", qf_count);
    VkQueueFamilyProperties* qfp = (VkQueueFamilyProperties*)malloc(sizeof(VkQueueFamilyProperties)*qf_count);
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical_device, &qf_count, qfp);

    uint32_t graphics_family = UINT32_MAX;
    uint32_t present_family = UINT32_MAX;
    for (uint32_t i=0;i<qf_count;i++) {
        CARDINAL_LOG_INFO("[DEVICE] Queue family %u: flags=0x%x, count=%u", i, qfp[i].queueFlags, qfp[i].queueCount);
        if (qfp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { 
            graphics_family = i; 
            CARDINAL_LOG_INFO("[DEVICE] Candidate graphics queue family: %u", i);
        }
        VkBool32 present_support = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(s->physical_device, i, s->surface, &present_support);
        if (present_support) {
            present_family = i;
            CARDINAL_LOG_INFO("[DEVICE] Candidate present queue family: %u", i);
        }
    }
    // Prefer same family for both if possible
    if (graphics_family != UINT32_MAX && present_family != UINT32_MAX && graphics_family != present_family) {
        CARDINAL_LOG_INFO("[DEVICE] Using separate graphics (%u) and present (%u) queue families", graphics_family, present_family);
    }
    if (graphics_family == UINT32_MAX || present_family == UINT32_MAX) {
        CARDINAL_LOG_ERROR("[DEVICE] Required queue families not found! graphics=%u present=%u", graphics_family, present_family);
        free(qfp);
        return false;
    }
    free(qfp);

    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci[2];
    memset(qci, 0, sizeof(qci));
    uint32_t qci_count = 0;

    qci[qci_count].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci[qci_count].queueFamilyIndex = graphics_family;
    qci[qci_count].queueCount = 1;
    qci[qci_count].pQueuePriorities = &priority;
    qci_count++;

    if (present_family != graphics_family) {
        qci[qci_count].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        qci[qci_count].queueFamilyIndex = present_family;
        qci[qci_count].queueCount = 1;
        qci[qci_count].pQueuePriorities = &priority;
        qci_count++;
    }

    const char* dev_exts[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    CARDINAL_LOG_INFO("[DEVICE] Creating device with swapchain extension");

    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = qci_count;
    dci.pQueueCreateInfos = qci;
    dci.enabledExtensionCount = 1;
    dci.ppEnabledExtensionNames = dev_exts;

    VkResult result = vkCreateDevice(s->physical_device, &dci, NULL, &s->device);
    CARDINAL_LOG_INFO("[DEVICE] Device creation result: %d", result);
    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to create logical device! Result: %d", result);
        return false;
    }
    
    s->graphics_queue_family = graphics_family;
    s->present_queue_family = present_family;
    vkGetDeviceQueue(s->device, graphics_family, 0, &s->graphics_queue);
    vkGetDeviceQueue(s->device, present_family, 0, &s->present_queue);
    CARDINAL_LOG_INFO("[DEVICE] Retrieved graphics queue: %p, present queue: %p", (void*)s->graphics_queue, (void*)s->present_queue);
    CARDINAL_LOG_INFO("[DEVICE] Logical device creation completed successfully");
    return true;
}

bool vk_create_surface(VulkanState* s, struct CardinalWindow* window) {
    return glfwCreateWindowSurface(s->instance, window->handle, NULL, &s->surface) == VK_SUCCESS;
}

void vk_destroy_device_objects(VulkanState* s) {
    if (!s) return;
    if (s->device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(s->device);
        vkDestroyDevice(s->device, NULL);
        s->device = VK_NULL_HANDLE;
    }
    if (s->surface) { vkDestroySurfaceKHR(s->instance, s->surface, NULL); s->surface = VK_NULL_HANDLE; }
    if (s->debug_messenger) {
        PFN_vkDestroyDebugUtilsMessengerEXT dfunc = (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(s->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (dfunc) { dfunc(s->instance, s->debug_messenger, NULL); }
        s->debug_messenger = VK_NULL_HANDLE;
    }
    if (s->instance) { vkDestroyInstance(s->instance, NULL); s->instance = VK_NULL_HANDLE; }
}
