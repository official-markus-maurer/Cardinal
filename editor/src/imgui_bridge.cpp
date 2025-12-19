#include "imgui_bridge.h"

#include <imgui.h>
#include <backends/imgui_impl_glfw.h>
#include <backends/imgui_impl_vulkan.h>
#include <vulkan/vulkan.h>
#include <GLFW/glfw3.h>
#include <stdarg.h>
#include <stdio.h>

extern "C" {

// Main Viewport & Layout
const ImGuiViewport* imgui_bridge_get_main_viewport(void) {
    return ImGui::GetMainViewport();
}

unsigned int imgui_bridge_get_id(const char* str_id) {
    return ImGui::GetID(str_id);
}

void imgui_bridge_viewport_get_work_pos(const ImGuiViewport* viewport, ImVec2* out_pos) {
    *out_pos = viewport->WorkPos;
}

void imgui_bridge_viewport_get_work_size(const ImGuiViewport* viewport, ImVec2* out_size) {
    *out_size = viewport->WorkSize;
}

void imgui_bridge_set_next_window_pos(const ImVec2* pos, int cond, const ImVec2* pivot) {
    ImGui::SetNextWindowPos(*pos, cond, *pivot);
}

void imgui_bridge_set_next_window_size(const ImVec2* size, int cond) {
    ImGui::SetNextWindowSize(*size, cond);
}

void imgui_bridge_push_style_var_vec2(int idx, const ImVec2* val) {
    ImGui::PushStyleVar(idx, *val);
}

void imgui_bridge_pop_style_var(int count) {
    ImGui::PopStyleVar(count);
}

void imgui_bridge_create_context(void) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
}

void imgui_bridge_destroy_context(void) {
    ImGui::DestroyContext();
}

void imgui_bridge_style_colors_dark(void) {
    ImGui::StyleColorsDark();
}

void imgui_bridge_enable_docking(bool enable) {
    ImGuiIO& io = ImGui::GetIO();
    if (enable)
        io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    else
        io.ConfigFlags &= ~ImGuiConfigFlags_DockingEnable;
}

void imgui_bridge_enable_keyboard(bool enable) {
    ImGuiIO& io = ImGui::GetIO();
    if (enable)
        io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    else
        io.ConfigFlags &= ~ImGuiConfigFlags_NavEnableKeyboard;
}

bool imgui_bridge_impl_glfw_init_for_vulkan(GLFWwindow* window, bool install_callbacks) {
    return ImGui_ImplGlfw_InitForVulkan(window, install_callbacks);
}

void imgui_bridge_impl_glfw_shutdown(void) {
    ImGui_ImplGlfw_Shutdown();
}

void imgui_bridge_impl_glfw_new_frame(void) {
    ImGui_ImplGlfw_NewFrame();
}

bool imgui_bridge_impl_vulkan_init(ImGuiBridgeVulkanInitInfo* info) {
    ImGuiIO& io = ImGui::GetIO();
    printf("[BRIDGE] Init: io=%p, UserData=%p\n", &io, io.BackendRendererUserData);

    ImGui_ImplVulkan_InitInfo init_info = {};
    init_info.Instance = info->instance;
    init_info.PhysicalDevice = info->physical_device;
    init_info.Device = info->device;
    init_info.QueueFamily = info->queue_family;
    init_info.Queue = info->queue;
    init_info.PipelineCache = VK_NULL_HANDLE;
    init_info.DescriptorPool = info->descriptor_pool;
    init_info.PipelineInfoMain.Subpass = 0;
    init_info.MinImageCount = info->min_image_count;
    init_info.ImageCount = info->image_count;
    init_info.PipelineInfoMain.MSAASamples = (VkSampleCountFlagBits)info->msaa_samples;
    init_info.Allocator = NULL;
    init_info.CheckVkResultFn = NULL;
    
    // API Version
    init_info.ApiVersion = VK_API_VERSION_1_3;

    if (info->use_dynamic_rendering) {
        init_info.UseDynamicRendering = true;
        init_info.PipelineInfoMain.MSAASamples = (VkSampleCountFlagBits)info->msaa_samples;
        init_info.PipelineInfoMain.PipelineRenderingCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
        init_info.PipelineInfoMain.PipelineRenderingCreateInfo.pNext = NULL;
        init_info.PipelineInfoMain.PipelineRenderingCreateInfo.colorAttachmentCount = 1;
        
        static VkFormat color_format; // Static to ensure pointer validity during init? Copy happens inside?
        // ImGui copies the values, so local address is fine, but let's be safe.
        // Actually ImGui_ImplVulkan_Init copies the struct, but pColorAttachmentFormats is a pointer.
        // We need to ensure the pointed memory is valid.
        // Wait, ImGui implementation might just read it during Init.
        // Let's assume it reads it.
        VkFormat color_formats[1] = { (VkFormat)info->color_attachment_format };
        init_info.PipelineInfoMain.PipelineRenderingCreateInfo.pColorAttachmentFormats = color_formats;
        init_info.PipelineInfoMain.PipelineRenderingCreateInfo.depthAttachmentFormat = (VkFormat)info->depth_attachment_format;
        init_info.PipelineInfoMain.PipelineRenderingCreateInfo.stencilAttachmentFormat = VK_FORMAT_UNDEFINED;
        init_info.PipelineInfoMain.RenderPass = VK_NULL_HANDLE;
        init_info.PipelineInfoMain.Subpass = 0;
        
        return ImGui_ImplVulkan_Init(&init_info);
    } else {
        // Not supporting render pass mode in this bridge for now as the editor uses dynamic rendering
        return false;
    }
}

void imgui_bridge_impl_vulkan_shutdown(void) {
    ImGui_ImplVulkan_Shutdown();
}

void imgui_bridge_force_clear_backend_data(void) {
    ImGuiIO& io = ImGui::GetIO();
    printf("[BRIDGE] Clear: io=%p, UserData=%p\n", &io, io.BackendRendererUserData);
    io.BackendRendererUserData = nullptr;
    io.BackendRendererName = nullptr;
}

void imgui_bridge_impl_vulkan_new_frame(void) {
    ImGui_ImplVulkan_NewFrame();
}

void imgui_bridge_impl_vulkan_render_draw_data(VkCommandBuffer command_buffer) {
    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), command_buffer);
}

void imgui_bridge_new_frame(void) {
    ImGui::NewFrame();
}

void imgui_bridge_render(void) {
    ImGui::Render();
}

bool imgui_bridge_begin(const char* name, bool* p_open, int flags) {
    return ImGui::Begin(name, p_open, flags);
}

void imgui_bridge_end(void) {
    ImGui::End();
}

void imgui_bridge_text(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    ImGui::TextV(fmt, args);
    va_end(args);
}

void imgui_bridge_text_disabled(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    ImGui::TextDisabledV(fmt, args);
    va_end(args);
}

void imgui_bridge_text_wrapped(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    ImGui::TextWrappedV(fmt, args);
    va_end(args);
}

bool imgui_bridge_button(const char* label) {
    return ImGui::Button(label);
}

void imgui_bridge_same_line(float offset_from_start_x, float spacing) {
    ImGui::SameLine(offset_from_start_x, spacing);
}

bool imgui_bridge_checkbox(const char* label, bool* v) {
    return ImGui::Checkbox(label, v);
}

bool imgui_bridge_slider_float(const char* label, float* v, float v_min, float v_max, const char* format) {
    return ImGui::SliderFloat(label, v, v_min, v_max, format);
}

void imgui_bridge_separator(void) {
    ImGui::Separator();
}

bool imgui_bridge_begin_child(const char* str_id, float width, float height, bool border, int flags) {
    return ImGui::BeginChild(str_id, ImVec2(width, height), border, flags);
}

void imgui_bridge_end_child(void) {
    ImGui::EndChild();
}

bool imgui_bridge_selectable(const char* label, bool selected, int flags) {
    return ImGui::Selectable(label, selected, flags);
}

bool imgui_bridge_collapsing_header(const char* label, int flags) {
    return ImGui::CollapsingHeader(label, flags);
}

void imgui_bridge_set_next_item_width(float width) {
    ImGui::SetNextItemWidth(width);
}

float imgui_bridge_get_content_region_avail_x(void) {
    return ImGui::GetContentRegionAvail().x;
}

bool imgui_bridge_input_text(const char* label, char* buf, size_t buf_size) {
    return ImGui::InputText(label, buf, buf_size);
}

bool imgui_bridge_input_text_with_hint(const char* label, const char* hint, char* buf, size_t buf_size) {
    return ImGui::InputTextWithHint(label, hint, buf, buf_size);
}

// Docking & Menus
void imgui_bridge_dock_space(unsigned int id, const ImVec2* size, int flags) {
    ImGui::DockSpace(id, *size, flags);
}

void imgui_bridge_dock_space_over_viewport(void) {
    ImGui::DockSpaceOverViewport(0, ImGui::GetMainViewport());
}

bool imgui_bridge_begin_main_menu_bar(void) {
    return ImGui::BeginMainMenuBar();
}

void imgui_bridge_end_main_menu_bar(void) {
    ImGui::EndMainMenuBar();
}

bool imgui_bridge_begin_menu(const char* label, bool enabled) {
    return ImGui::BeginMenu(label, enabled);
}

void imgui_bridge_end_menu(void) {
    ImGui::EndMenu();
}

bool imgui_bridge_menu_item(const char* label, const char* shortcut, bool selected, bool enabled) {
    return ImGui::MenuItem(label, shortcut, selected, enabled);
}

// Tree & Layout
bool imgui_bridge_tree_node(const char* label) {
    return ImGui::TreeNode(label);
}

void imgui_bridge_tree_pop(void) {
    ImGui::TreePop();
}

void imgui_bridge_bullet_text(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    ImGui::BulletTextV(fmt, args);
    va_end(args);
}

void imgui_bridge_indent(float indent_w) {
    ImGui::Indent(indent_w);
}

void imgui_bridge_unindent(float indent_w) {
    ImGui::Unindent(indent_w);
}

void imgui_bridge_push_id_int(int int_id) {
    ImGui::PushID(int_id);
}

void imgui_bridge_pop_id(void) {
    ImGui::PopID();
}

// Tooltips & Interaction
void imgui_bridge_set_tooltip(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    ImGui::SetTooltipV(fmt, args);
    va_end(args);
}

bool imgui_bridge_is_item_hovered(int flags) {
    return ImGui::IsItemHovered(flags);
}

bool imgui_bridge_is_mouse_double_clicked(int button) {
    return ImGui::IsMouseDoubleClicked(button);
}

// Widgets
bool imgui_bridge_drag_float(const char* label, float* v, float v_speed, float v_min, float v_max, const char* format, int flags) {
    return ImGui::DragFloat(label, v, v_speed, v_min, v_max, format, flags);
}

bool imgui_bridge_drag_float3(const char* label, float v[3], float v_speed, float v_min, float v_max, const char* format, int flags) {
    return ImGui::DragFloat3(label, v, v_speed, v_min, v_max, format, flags);
}

bool imgui_bridge_color_edit3(const char* label, float col[3], int flags) {
    return ImGui::ColorEdit3(label, col, flags);
}

bool imgui_bridge_combo(const char* label, int* current_item, const char* const items[], int items_count, int popup_max_height_in_items) {
    return ImGui::Combo(label, current_item, items, items_count, popup_max_height_in_items);
}

float imgui_bridge_get_io_delta_time(void) {
    return ImGui::GetIO().DeltaTime;
}

}
