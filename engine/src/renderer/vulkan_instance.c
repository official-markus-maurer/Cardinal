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
static VKAPI_ATTR VkBool32 VKAPI_CALL vk_debug_callback(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT type,
    const VkDebugUtilsMessengerCallbackDataEXT* callback_data,
    void* user_data) {
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "VK_DEBUG: %s", callback_data->pMessage);
    LOG_WARN("%s", buffer);
    return VK_FALSE;
}

bool vk_create_instance(VulkanState* s) {
    VkApplicationInfo ai = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO };
    ai.pApplicationName = "Cardinal";
    ai.applicationVersion = VK_MAKE_VERSION(1,0,0);
    ai.pEngineName = "Cardinal";
    ai.engineVersion = VK_MAKE_VERSION(1,0,0);
    ai.apiVersion = VK_API_VERSION_1_2;

    uint32_t glfw_count = 0;
    const char** glfw_exts = glfwGetRequiredInstanceExtensions(&glfw_count);

    const char* layers[] = { "VK_LAYER_KHRONOS_validation" };
    VkInstanceCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ci.pApplicationInfo = &ai;

    // Build extension list, append debug utils in debug builds if not already present
    const char** enabled_exts = glfw_exts;
    uint32_t enabled_ext_count = glfw_count;
#ifdef _DEBUG
    bool need_debug_utils = true;
    for (uint32_t i = 0; i < glfw_count; ++i) {
        if (strcmp(glfw_exts[i], VK_EXT_DEBUG_UTILS_EXTENSION_NAME) == 0) { need_debug_utils = false; break; }
    }
    const char** tmp_exts = NULL;
    if (need_debug_utils) {
        tmp_exts = (const char**)malloc(sizeof(char*) * (glfw_count + 1));
        for (uint32_t i = 0; i < glfw_count; ++i) tmp_exts[i] = glfw_exts[i];
        tmp_exts[glfw_count] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
        enabled_exts = tmp_exts;
        enabled_ext_count = glfw_count + 1;
    }
#endif

    ci.enabledExtensionCount = enabled_ext_count;
    ci.ppEnabledExtensionNames = enabled_exts;
#ifdef _DEBUG
    ci.enabledLayerCount = 1;
    ci.ppEnabledLayerNames = layers;
#else
    ci.enabledLayerCount = 0;
    ci.ppEnabledLayerNames = NULL;
#endif

#ifdef _DEBUG
    VkDebugUtilsMessengerCreateInfoEXT debug_ci = { .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT };
    debug_ci.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    debug_ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    debug_ci.pfnUserCallback = vk_debug_callback;
    ci.pNext = &debug_ci;
#endif

    if (vkCreateInstance(&ci, NULL, &s->instance) != VK_SUCCESS) {
        LOG_ERROR("vk_create_instance: vkCreateInstance failed");
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
        dbg_ci.pfnUserCallback = vk_debug_callback;
        dfunc(s->instance, &dbg_ci, NULL, &s->debug_messenger);
    }
#endif

    return true;
}

bool vk_pick_physical_device(VulkanState* s) {
    uint32_t count = 0;
    vkEnumeratePhysicalDevices(s->instance, &count, NULL);
    if (count == 0) return false;
    VkPhysicalDevice* devices = (VkPhysicalDevice*)malloc(sizeof(VkPhysicalDevice) * count);
    vkEnumeratePhysicalDevices(s->instance, &count, devices);
    s->physical_device = devices[0];
    free(devices);
    return s->physical_device != VK_NULL_HANDLE;
}

bool vk_create_device(VulkanState* s) {
    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical_device, &qf_count, NULL);
    VkQueueFamilyProperties* qfp = (VkQueueFamilyProperties*)malloc(sizeof(VkQueueFamilyProperties)*qf_count);
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical_device, &qf_count, qfp);

    uint32_t graphics_family = UINT32_MAX;
    for (uint32_t i=0;i<qf_count;i++) {
        if (qfp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { graphics_family = i; break; }
    }
    free(qfp);
    if (graphics_family == UINT32_MAX) return false;

    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = graphics_family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;

    const char* dev_exts[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };

    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = 1;
    dci.ppEnabledExtensionNames = dev_exts;

    if (vkCreateDevice(s->physical_device, &dci, NULL, &s->device) != VK_SUCCESS) return false;
    s->graphics_queue_family = graphics_family;
    vkGetDeviceQueue(s->device, graphics_family, 0, &s->graphics_queue);
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