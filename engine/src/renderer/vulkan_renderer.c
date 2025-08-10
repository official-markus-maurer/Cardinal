#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#include <GLFW/glfw3.h>

#include "cardinal/core/window.h"
#include "cardinal/renderer/renderer.h"

// Minimal Vulkan state needed for clear-color rendering
typedef struct VulkanState {
    VkInstance instance;
    VkSurfaceKHR surface;
    VkPhysicalDevice physical_device;
    VkDevice device;
    uint32_t graphics_queue_family;
    VkQueue graphics_queue;
    VkSwapchainKHR swapchain;
    VkFormat swapchain_format;
    VkExtent2D swapchain_extent;
    VkImage* swapchain_images;
    uint32_t swapchain_image_count;
    VkImageView* swapchain_image_views;
    VkRenderPass render_pass;
    VkPipelineLayout pipeline_layout;
    VkPipeline pipeline;
    VkFramebuffer* framebuffers;
    VkCommandPool command_pool;
    VkCommandBuffer* command_buffers;
    VkSemaphore image_available;
    VkSemaphore render_finished;
    VkFence in_flight;
} VulkanState;

static bool create_instance(VulkanState* s) {
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "Cardinal";
    app.applicationVersion = VK_MAKE_API_VERSION(0,1,0,0);
    app.pEngineName = "Cardinal";
    app.engineVersion = VK_MAKE_API_VERSION(0,1,0,0);
    app.apiVersion = VK_API_VERSION_1_3;

    uint32_t ext_count = 0;
    const char** extensions = glfwGetRequiredInstanceExtensions(&ext_count);
    if (!extensions || ext_count == 0) return false; // requires VK_KHR_surface + platform

    VkInstanceCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ci.pApplicationInfo = &app;
    ci.enabledExtensionCount = ext_count;
    ci.ppEnabledExtensionNames = extensions;

    return vkCreateInstance(&ci, NULL, &s->instance) == VK_SUCCESS;
}

static bool pick_physical_device(VulkanState* s) {
    uint32_t count = 0;
    vkEnumeratePhysicalDevices(s->instance, &count, NULL);
    if (count == 0) return false;
    VkPhysicalDevice* devices = (VkPhysicalDevice*)malloc(sizeof(VkPhysicalDevice) * count);
    vkEnumeratePhysicalDevices(s->instance, &count, devices);
    s->physical_device = devices[0];
    free(devices);
    return s->physical_device != VK_NULL_HANDLE;
}

static bool create_device(VulkanState* s) {
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

static bool create_surface(VulkanState* s, CardinalWindow* window) {
    if (glfwCreateWindowSurface(s->instance, window->handle, NULL, &s->surface) != VK_SUCCESS) return false;
    return true;
}

static VkSurfaceFormatKHR choose_surface_format(const VkSurfaceFormatKHR* formats, uint32_t count) {
    for (uint32_t i=0;i<count;i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM && formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            return formats[i];
    }
    return formats[0];
}

static VkPresentModeKHR choose_present_mode(const VkPresentModeKHR* modes, uint32_t count) {
    for (uint32_t i=0;i<count;i++) if (modes[i] == VK_PRESENT_MODE_MAILBOX_KHR) return VK_PRESENT_MODE_MAILBOX_KHR;
    return VK_PRESENT_MODE_FIFO_KHR;
}

static bool create_swapchain(VulkanState* s) {
    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(s->physical_device, s->surface, &caps);

    uint32_t fmt_count=0; vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical_device, s->surface, &fmt_count, NULL);
    VkSurfaceFormatKHR* fmts = (VkSurfaceFormatKHR*)malloc(sizeof(VkSurfaceFormatKHR)*fmt_count);
    vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical_device, s->surface, &fmt_count, fmts);
    VkSurfaceFormatKHR surface_fmt = choose_surface_format(fmts, fmt_count);

    uint32_t pm_count=0; vkGetPhysicalDeviceSurfacePresentModesKHR(s->physical_device, s->surface, &pm_count, NULL);
    VkPresentModeKHR* pms = (VkPresentModeKHR*)malloc(sizeof(VkPresentModeKHR)*pm_count);
    vkGetPhysicalDeviceSurfacePresentModesKHR(s->physical_device, s->surface, &pm_count, pms);
    VkPresentModeKHR present_mode = choose_present_mode(pms, pm_count);

    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        extent.width = 800; extent.height = 600;
    }

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount) image_count = caps.maxImageCount;

    VkSwapchainCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR };
    sci.surface = s->surface;
    sci.minImageCount = image_count;
    sci.imageFormat = surface_fmt.format;
    sci.imageColorSpace = surface_fmt.colorSpace;
    sci.imageExtent = extent;
    sci.imageArrayLayers = 1;
    sci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    sci.preTransform = caps.currentTransform;
    sci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    sci.presentMode = present_mode;
    sci.clipped = VK_TRUE;

    if (vkCreateSwapchainKHR(s->device, &sci, NULL, &s->swapchain) != VK_SUCCESS) return false;

    s->swapchain_extent = extent;
    s->swapchain_format = surface_fmt.format;

    vkGetSwapchainImagesKHR(s->device, s->swapchain, &s->swapchain_image_count, NULL);
    s->swapchain_images = (VkImage*)malloc(sizeof(VkImage)*s->swapchain_image_count);
    vkGetSwapchainImagesKHR(s->device, s->swapchain, &s->swapchain_image_count, s->swapchain_images);

    s->swapchain_image_views = (VkImageView*)malloc(sizeof(VkImageView)*s->swapchain_image_count);
    for (uint32_t i=0;i<s->swapchain_image_count;i++) {
        VkImageViewCreateInfo iv = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
        iv.image = s->swapchain_images[i];
        iv.viewType = VK_IMAGE_VIEW_TYPE_2D;
        iv.format = s->swapchain_format;
        iv.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        iv.subresourceRange.levelCount = 1;
        iv.subresourceRange.layerCount = 1;
        vkCreateImageView(s->device, &iv, NULL, &s->swapchain_image_views[i]);
    }

    return true;
}

static bool create_renderpass_pipeline(VulkanState* s) {
    VkAttachmentDescription color = {0};
    color.format = s->swapchain_format;
    color.samples = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference color_ref = {0};
    color_ref.attachment = 0;
    color_ref.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass = {0};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &color_ref;

    VkRenderPassCreateInfo rpci = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rpci.attachmentCount = 1;
    rpci.pAttachments = &color;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &subpass;

    if (vkCreateRenderPass(s->device, &rpci, NULL, &s->render_pass) != VK_SUCCESS) return false;

    // Minimal pipeline with no shaders (not valid). We'll not bind a pipeline and use a renderpass clear only.
    // So we won't create a graphics pipeline here to keep it minimal.

    // Framebuffers
    s->framebuffers = (VkFramebuffer*)malloc(sizeof(VkFramebuffer)*s->swapchain_image_count);
    for (uint32_t i=0;i<s->swapchain_image_count;i++) {
        VkImageView attachments[] = { s->swapchain_image_views[i] };
        VkFramebufferCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        fci.renderPass = s->render_pass;
        fci.attachmentCount = 1;
        fci.pAttachments = attachments;
        fci.width = s->swapchain_extent.width;
        fci.height = s->swapchain_extent.height;
        fci.layers = 1;
        if (vkCreateFramebuffer(s->device, &fci, NULL, &s->framebuffers[i]) != VK_SUCCESS) return false;
    }

    return true;
}

static bool create_commands_sync(VulkanState* s) {
    VkCommandPoolCreateInfo cp = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cp.queueFamilyIndex = s->graphics_queue_family;
    cp.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    if (vkCreateCommandPool(s->device, &cp, NULL, &s->command_pool) != VK_SUCCESS) return false;

    s->command_buffers = (VkCommandBuffer*)malloc(sizeof(VkCommandBuffer)*s->swapchain_image_count);
    VkCommandBufferAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    ai.commandPool = s->command_pool;
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = s->swapchain_image_count;
    if (vkAllocateCommandBuffers(s->device, &ai, s->command_buffers) != VK_SUCCESS) return false;

    VkSemaphoreCreateInfo si = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    vkCreateSemaphore(s->device, &si, NULL, &s->image_available);
    vkCreateSemaphore(s->device, &si, NULL, &s->render_finished);

    VkFenceCreateInfo fi = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    fi.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    vkCreateFence(s->device, &fi, NULL, &s->in_flight);

    return true;
}

static void record_cmd(VulkanState* s, uint32_t image_index) {
    VkCommandBuffer cmd = s->command_buffers[image_index];

    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    vkBeginCommandBuffer(cmd, &bi);

    VkClearValue clear; clear.color.float32[0]=0.05f; clear.color.float32[1]=0.05f; clear.color.float32[2]=0.08f; clear.color.float32[3]=1.0f;

    VkRenderPassBeginInfo rp = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    rp.renderPass = s->render_pass;
    rp.framebuffer = s->framebuffers[image_index];
    rp.renderArea.extent = s->swapchain_extent;
    rp.clearValueCount = 1;
    rp.pClearValues = &clear;

    vkCmdBeginRenderPass(cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);
    // No draw calls; clearing only
    vkCmdEndRenderPass(cmd);

    vkEndCommandBuffer(cmd);
}

bool cardinal_renderer_create(CardinalRenderer* out_renderer, CardinalWindow* window) {
    if (!out_renderer || !window) return false;
    VulkanState* s = (VulkanState*)calloc(1, sizeof(VulkanState));
    out_renderer->_opaque = s;

    if (!create_instance(s)) return false;
    if (!create_surface(s, window)) return false;
    if (!pick_physical_device(s)) return false;
    if (!create_device(s)) return false;
    if (!create_swapchain(s)) return false;
    if (!create_renderpass_pipeline(s)) return false;
    if (!create_commands_sync(s)) return false;

    return true;
}

void cardinal_renderer_draw_frame(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;

    vkWaitForFences(s->device, 1, &s->in_flight, VK_TRUE, UINT64_MAX);
    vkResetFences(s->device, 1, &s->in_flight);

    uint32_t image_index = 0;
    vkAcquireNextImageKHR(s->device, s->swapchain, UINT64_MAX, s->image_available, VK_NULL_HANDLE, &image_index);

    record_cmd(s, image_index);

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO };
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &s->image_available;
    submit.pWaitDstStageMask = &wait_stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &s->command_buffers[image_index];
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &s->render_finished;
    vkQueueSubmit(s->graphics_queue, 1, &submit, s->in_flight);

    VkPresentInfoKHR present = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR };
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &s->render_finished;
    present.swapchainCount = 1;
    present.pSwapchains = &s->swapchain;
    present.pImageIndices = &image_index;
    vkQueuePresentKHR(s->graphics_queue, &present);
}

void cardinal_renderer_wait_idle(CardinalRenderer* renderer) {
    VulkanState* s = (VulkanState*)renderer->_opaque;
    vkDeviceWaitIdle(s->device);
}

void cardinal_renderer_destroy(CardinalRenderer* renderer) {
    if (!renderer || !renderer->_opaque) return;
    VulkanState* s = (VulkanState*)renderer->_opaque;

    vkDeviceWaitIdle(s->device);

    for (uint32_t i=0;i<s->swapchain_image_count;i++) {
        vkDestroyFramebuffer(s->device, s->framebuffers[i], NULL);
        vkDestroyImageView(s->device, s->swapchain_image_views[i], NULL);
    }
    free(s->framebuffers);
    free(s->swapchain_image_views);
    free(s->swapchain_images);

    vkDestroyFence(s->device, s->in_flight, NULL);
    vkDestroySemaphore(s->device, s->render_finished, NULL);
    vkDestroySemaphore(s->device, s->image_available, NULL);

    vkDestroyCommandPool(s->device, s->command_pool, NULL);
    vkDestroyRenderPass(s->device, s->render_pass, NULL);
    vkDestroySwapchainKHR(s->device, s->swapchain, NULL);
    vkDestroyDevice(s->device, NULL);
    vkDestroySurfaceKHR(s->instance, s->surface, NULL);
    vkDestroyInstance(s->instance, NULL);

    free(s->command_buffers);
    free(s);
    renderer->_opaque = NULL;
}
