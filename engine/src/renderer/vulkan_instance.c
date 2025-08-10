#include <stdlib.h>
#include <GLFW/glfw3.h>
#include <vulkan/vulkan.h>
#include "cardinal/core/window.h"
#include "vulkan_state.h"
#include "vulkan_instance.h"

bool vk_create_instance(VulkanState* s) {
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "Cardinal";
    app.applicationVersion = VK_MAKE_API_VERSION(0,1,0,0);
    app.pEngineName = "Cardinal";
    app.engineVersion = VK_MAKE_API_VERSION(0,1,0,0);
    app.apiVersion = VK_API_VERSION_1_3;

    uint32_t ext_count = 0;
    const char** extensions = glfwGetRequiredInstanceExtensions(&ext_count);
    if (!extensions || ext_count == 0) return false;

    VkInstanceCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ci.pApplicationInfo = &app;
    ci.enabledExtensionCount = ext_count;
    ci.ppEnabledExtensionNames = extensions;

    return vkCreateInstance(&ci, NULL, &s->instance) == VK_SUCCESS;
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
    if (s->instance) { vkDestroyInstance(s->instance, NULL); s->instance = VK_NULL_HANDLE; }
}