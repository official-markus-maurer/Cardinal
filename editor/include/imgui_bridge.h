#ifndef IMGUI_BRIDGE_H
#define IMGUI_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
#include <imgui.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Opaque types
typedef struct GLFWwindow GLFWwindow;
typedef struct VkInstance_T* VkInstance;
typedef struct VkPhysicalDevice_T* VkPhysicalDevice;
typedef struct VkDevice_T* VkDevice;
typedef struct VkQueue_T* VkQueue;
typedef struct VkCommandBuffer_T* VkCommandBuffer;
typedef struct VkDescriptorPool_T* VkDescriptorPool;
typedef struct VkRenderPass_T* VkRenderPass;

#ifndef __cplusplus

typedef enum ImGuiStyleVar_ {
    ImGuiStyleVar_Alpha                     = 0,
    ImGuiStyleVar_DisabledAlpha             = 1,
    ImGuiStyleVar_WindowPadding             = 2,
    ImGuiStyleVar_WindowRounding            = 3,
    ImGuiStyleVar_WindowBorderSize          = 4,
    ImGuiStyleVar_WindowMinSize             = 5,
    ImGuiStyleVar_WindowTitleAlign          = 6,
    ImGuiStyleVar_ChildRounding             = 7,
    ImGuiStyleVar_ChildBorderSize           = 8,
    ImGuiStyleVar_PopupRounding             = 9,
    ImGuiStyleVar_PopupBorderSize           = 10,
    ImGuiStyleVar_FramePadding              = 11,
    ImGuiStyleVar_FrameRounding             = 12,
    ImGuiStyleVar_FrameBorderSize           = 13,
    ImGuiStyleVar_ItemSpacing               = 14,
    ImGuiStyleVar_ItemInnerSpacing          = 15,
    ImGuiStyleVar_IndentSpacing             = 16,
    ImGuiStyleVar_CellPadding               = 17,
    ImGuiStyleVar_ScrollbarSize             = 18,
    ImGuiStyleVar_ScrollbarRounding         = 19,
    ImGuiStyleVar_GrabMinSize               = 20,
    ImGuiStyleVar_GrabRounding              = 21,
    ImGuiStyleVar_TabRounding               = 22,
    ImGuiStyleVar_ButtonTextAlign           = 23,
    ImGuiStyleVar_SelectableTextAlign       = 24,
    ImGuiStyleVar_SeparatorTextBorderSize   = 25,
    ImGuiStyleVar_SeparatorTextAlign        = 26,
    ImGuiStyleVar_SeparatorTextPadding      = 27,
    ImGuiStyleVar_DockingSeparatorSize      = 28,
} ImGuiStyleVar_;

typedef struct ImGuiViewport ImGuiViewport;
typedef struct ImVec2 { float x, y; } ImVec2;

typedef enum ImGuiWindowFlags_ {
    ImGuiWindowFlags_None                   = 0,
    ImGuiWindowFlags_NoTitleBar             = 1 << 0,
    ImGuiWindowFlags_NoResize               = 1 << 1,
    ImGuiWindowFlags_NoMove                 = 1 << 2,
    ImGuiWindowFlags_NoScrollbar            = 1 << 3,
    ImGuiWindowFlags_NoScrollWithMouse      = 1 << 4,
    ImGuiWindowFlags_NoCollapse             = 1 << 5,
    ImGuiWindowFlags_AlwaysAutoResize       = 1 << 6,
    ImGuiWindowFlags_NoBackground           = 1 << 7,
    ImGuiWindowFlags_NoSavedSettings        = 1 << 8,
    ImGuiWindowFlags_NoMouseInputs          = 1 << 9,
    ImGuiWindowFlags_MenuBar                = 1 << 10,
    ImGuiWindowFlags_HorizontalScrollbar    = 1 << 11,
    ImGuiWindowFlags_NoFocusOnAppearing     = 1 << 12,
    ImGuiWindowFlags_NoBringToFrontOnFocus  = 1 << 13,
    ImGuiWindowFlags_AlwaysVerticalScrollbar= 1 << 14,
    ImGuiWindowFlags_AlwaysHorizontalScrollbar=1<< 15,
    ImGuiWindowFlags_AlwaysUseWindowPadding = 1 << 16,
    ImGuiWindowFlags_NoNavInputs            = 1 << 18,
    ImGuiWindowFlags_NoNavFocus             = 1 << 19,
    ImGuiWindowFlags_UnsavedDocument        = 1 << 20,
    ImGuiWindowFlags_NoDocking              = 1 << 21,
    ImGuiWindowFlags_NoNav                  = ImGuiWindowFlags_NoNavInputs | ImGuiWindowFlags_NoNavFocus,
    ImGuiWindowFlags_NoDecoration           = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoCollapse,
    ImGuiWindowFlags_NoInputs               = ImGuiWindowFlags_NoMouseInputs | ImGuiWindowFlags_NoNavInputs | ImGuiWindowFlags_NoNavFocus,
} ImGuiWindowFlags_;

typedef enum ImGuiTreeNodeFlags_ {
    ImGuiTreeNodeFlags_None                 = 0,
    ImGuiTreeNodeFlags_Selected             = 1 << 0,
    ImGuiTreeNodeFlags_Framed               = 1 << 1,
    ImGuiTreeNodeFlags_AllowItemOverlap     = 1 << 2,
    ImGuiTreeNodeFlags_NoTreePushOnOpen     = 1 << 3,
    ImGuiTreeNodeFlags_NoAutoOpenOnLog      = 1 << 4,
    ImGuiTreeNodeFlags_DefaultOpen          = 1 << 5,
    ImGuiTreeNodeFlags_OpenOnDoubleClick    = 1 << 6,
    ImGuiTreeNodeFlags_OpenOnArrow          = 1 << 7,
    ImGuiTreeNodeFlags_Leaf                 = 1 << 8,
    ImGuiTreeNodeFlags_Bullet               = 1 << 9,
    ImGuiTreeNodeFlags_FramePadding         = 1 << 10,
    ImGuiTreeNodeFlags_SpanAvailWidth       = 1 << 11,
    ImGuiTreeNodeFlags_SpanFullWidth        = 1 << 12,
    ImGuiTreeNodeFlags_NavLeftJumpsBackHere = 1 << 13,
} ImGuiTreeNodeFlags_;

typedef enum ImGuiDockNodeFlags_ {
    ImGuiDockNodeFlags_None                 = 0,
    ImGuiDockNodeFlags_KeepAliveOnly        = 1 << 0,
    ImGuiDockNodeFlags_NoDockingInCentralNode = 1 << 2,
    ImGuiDockNodeFlags_PassthruCentralNode  = 1 << 3,
    ImGuiDockNodeFlags_NoSplit              = 1 << 4,
    ImGuiDockNodeFlags_NoResize             = 1 << 5,
    ImGuiDockNodeFlags_AutoHideTabBar       = 1 << 6,
} ImGuiDockNodeFlags_;

#endif // __cplusplus

// Main Viewport & Layout
const ImGuiViewport* imgui_bridge_get_main_viewport(void);
void imgui_bridge_viewport_get_work_pos(const ImGuiViewport* viewport, ImVec2* out_pos);
void imgui_bridge_viewport_get_work_size(const ImGuiViewport* viewport, ImVec2* out_size);
void imgui_bridge_set_next_window_pos(const ImVec2* pos, int cond, const ImVec2* pivot);
void imgui_bridge_set_next_window_size(const ImVec2* size, int cond);
void imgui_bridge_push_style_var_vec2(int idx, const ImVec2* val);
void imgui_bridge_pop_style_var(int count);
unsigned int imgui_bridge_get_id(const char* str_id);

// Bridge API
void imgui_bridge_create_context(void);
void imgui_bridge_destroy_context(void);
void imgui_bridge_style_colors_dark(void);
void imgui_bridge_enable_docking(bool enable);
void imgui_bridge_enable_keyboard(bool enable);

bool imgui_bridge_impl_glfw_init_for_vulkan(GLFWwindow* window, bool install_callbacks);
void imgui_bridge_impl_glfw_shutdown(void);
void imgui_bridge_impl_glfw_new_frame(void);

// Simplified InitInfo for Vulkan
typedef struct ImGuiBridgeVulkanInitInfo {
    VkInstance instance;
    VkPhysicalDevice physical_device;
    VkDevice device;
    uint32_t queue_family;
    VkQueue queue;
    VkDescriptorPool descriptor_pool;
    uint32_t min_image_count;
    uint32_t image_count;
    uint32_t msaa_samples;
    bool use_dynamic_rendering;
    uint32_t color_attachment_format; // VkFormat
    uint32_t depth_attachment_format; // VkFormat
} ImGuiBridgeVulkanInitInfo;

bool imgui_bridge_impl_vulkan_init(ImGuiBridgeVulkanInitInfo* info);
void imgui_bridge_impl_vulkan_shutdown(void);
void imgui_bridge_impl_vulkan_new_frame(void);
void imgui_bridge_impl_vulkan_render_draw_data(VkCommandBuffer command_buffer);

void imgui_bridge_new_frame(void);
void imgui_bridge_render(void);

// UI Widgets
bool imgui_bridge_begin(const char* name, bool* p_open, int flags);
void imgui_bridge_end(void);
void imgui_bridge_text(const char* fmt, ...);
void imgui_bridge_text_disabled(const char* fmt, ...);
void imgui_bridge_text_wrapped(const char* fmt, ...);
bool imgui_bridge_button(const char* label);
void imgui_bridge_same_line(float offset_from_start_x, float spacing);
bool imgui_bridge_checkbox(const char* label, bool* v);
bool imgui_bridge_slider_float(const char* label, float* v, float v_min, float v_max, const char* format);
void imgui_bridge_separator(void);
bool imgui_bridge_begin_child(const char* str_id, float width, float height, bool border, int flags);
void imgui_bridge_end_child(void);
bool imgui_bridge_selectable(const char* label, bool selected, int flags);
bool imgui_bridge_collapsing_header(const char* label, int flags);
void imgui_bridge_set_next_item_width(float width);
float imgui_bridge_get_content_region_avail_x(void);
bool imgui_bridge_input_text(const char* label, char* buf, size_t buf_size);
bool imgui_bridge_input_text_with_hint(const char* label, const char* hint, char* buf, size_t buf_size);

// Docking & Menus
void imgui_bridge_dock_space(unsigned int id, const ImVec2* size, int flags);
void imgui_bridge_dock_space_over_viewport(void);
bool imgui_bridge_begin_main_menu_bar(void);
void imgui_bridge_end_main_menu_bar(void);
bool imgui_bridge_begin_menu(const char* label, bool enabled);
void imgui_bridge_end_menu(void);
bool imgui_bridge_menu_item(const char* label, const char* shortcut, bool selected, bool enabled);

// Tree & Layout
bool imgui_bridge_tree_node(const char* label);
void imgui_bridge_tree_pop(void);
void imgui_bridge_bullet_text(const char* fmt, ...);
void imgui_bridge_indent(float indent_w);
void imgui_bridge_unindent(float indent_w);
void imgui_bridge_push_id_int(int int_id);
void imgui_bridge_pop_id(void);

// Tooltips & Interaction
void imgui_bridge_set_tooltip(const char* fmt, ...);
bool imgui_bridge_is_item_hovered(int flags);
bool imgui_bridge_is_mouse_double_clicked(int button);

// Widgets
bool imgui_bridge_drag_float(const char* label, float* v, float v_speed, float v_min, float v_max, const char* format, int flags);
bool imgui_bridge_drag_float3(const char* label, float v[3], float v_speed, float v_min, float v_max, const char* format, int flags);
bool imgui_bridge_color_edit3(const char* label, float col[3], int flags);
bool imgui_bridge_combo(const char* label, int* current_item, const char* const items[], int items_count, int popup_max_height_in_items);

// IO
float imgui_bridge_get_io_delta_time(void);

#ifdef __cplusplus
}
#endif

#endif // IMGUI_BRIDGE_H
