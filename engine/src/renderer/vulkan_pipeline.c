#include <stdlib.h>
#include <vulkan/vulkan.h>
#include "vulkan_state.h"
#include "vulkan_pipeline.h"

bool vk_create_renderpass_pipeline(VulkanState* s) {
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

// No pipeline creation; render pass clear only
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

void vk_destroy_renderpass_pipeline(VulkanState* s) {
if (!s) return;
if (s->framebuffers) {
for (uint32_t i=0;i<s->swapchain_image_count;i++) {
vkDestroyFramebuffer(s->device, s->framebuffers[i], NULL);
}
free(s->framebuffers);
s->framebuffers = NULL;
}
if (s->pipeline) { vkDestroyPipeline(s->device, s->pipeline, NULL); s->pipeline = VK_NULL_HANDLE; }
if (s->pipeline_layout) { vkDestroyPipelineLayout(s->device, s->pipeline_layout, NULL); s->pipeline_layout = VK_NULL_HANDLE; }
if (s->render_pass) { vkDestroyRenderPass(s->device, s->render_pass, NULL); s->render_pass = VK_NULL_HANDLE; }
}