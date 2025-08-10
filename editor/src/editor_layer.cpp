// Editor Layer - Placeholder for future UI/editing functionality
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <GLFW/glfw3.h>
#include <vulkan/vulkan.h>

#include <imgui.h>
#include <backends/imgui_impl_glfw.h>
#include <backends/imgui_impl_vulkan.h>

#include "editor_layer.h"
#include <cardinal/core/window.h>
#include <cardinal/renderer/renderer.h>
#include <cardinal/renderer/renderer_internal.h>

static CardinalRenderer* g_renderer = NULL;

static void setup_imgui_style() {
    ImGui::StyleColorsDark();
}

bool editor_layer_init(CardinalWindow* window, CardinalRenderer* renderer) {
    g_renderer = renderer;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    // Disable multi-viewport for now until platform windows rendering is wired
    // io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable;

    setup_imgui_style();

    if (!ImGui_ImplGlfw_InitForVulkan(window->handle, true)) {
        fprintf(stderr, "ImGui GLFW init failed\n");
        return false;
    }

    // Create descriptor pool for ImGui
    VkDescriptorPoolSize pool_sizes[] = {
        { VK_DESCRIPTOR_TYPE_SAMPLER, 1000 },
        { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1000 },
        { VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1000 },
        { VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1000 },
        { VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1000 }
    };
    VkDescriptorPoolCreateInfo pool_info{};
    pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    pool_info.maxSets = 1000 * 11;
    pool_info.poolSizeCount = 11;
    pool_info.pPoolSizes = pool_sizes;

    VkDevice device = cardinal_renderer_internal_device(renderer);
    VkDescriptorPool descriptor_pool{};
    if (vkCreateDescriptorPool(device, &pool_info, NULL, &descriptor_pool) != VK_SUCCESS) {
        fprintf(stderr, "Failed to create descriptor pool\n");
        return false;
    }

    ImGui_ImplVulkan_InitInfo init_info{};
    init_info.Instance = cardinal_renderer_internal_instance(renderer);
    init_info.PhysicalDevice = cardinal_renderer_internal_physical_device(renderer);
    init_info.Device = device;
    init_info.QueueFamily = cardinal_renderer_internal_graphics_queue_family(renderer);
    init_info.Queue = cardinal_renderer_internal_graphics_queue(renderer);
    init_info.DescriptorPool = descriptor_pool;
    init_info.MinImageCount = cardinal_renderer_internal_swapchain_image_count(renderer);
    init_info.ImageCount = cardinal_renderer_internal_swapchain_image_count(renderer);
    init_info.MSAASamples = VK_SAMPLE_COUNT_1_BIT;
    init_info.RenderPass = cardinal_renderer_internal_render_pass(renderer);

    if (!ImGui_ImplVulkan_Init(&init_info)) {
        fprintf(stderr, "ImGui Vulkan init failed\n");
        return false;
    }

    return true;
}

static void draw_scene_graph_panel() {
    if (ImGui::Begin("Scene Graph")) {
        if (ImGui::TreeNode("Root")) {
            ImGui::BulletText("Camera");
            ImGui::BulletText("Directional Light");
            if (ImGui::TreeNode("MeshEntity")) {
                ImGui::Text("Transform");
                ImGui::Text("MeshRenderer");
                ImGui::TreePop();
            }
            ImGui::TreePop();
        }
    }
    ImGui::End();
}

static void draw_asset_browser_panel() {
    if (ImGui::Begin("Assets")) {
        ImGui::Text("Project Assets");
        ImGui::Separator();
        ImGui::Selectable("textures/brick_albedo.png");
        ImGui::Selectable("models/teapot.obj");
        ImGui::Selectable("shaders/basic.vert");
        ImGui::Selectable("shaders/basic.frag");
    }
    ImGui::End();
}

static void imgui_record(VkCommandBuffer cmd) {
    ImDrawData* dd = ImGui::GetDrawData();
    ImGui_ImplVulkan_RenderDrawData(dd, cmd);
}

void editor_layer_update(void) {
}

void editor_layer_render(void) {
    ImGui_ImplGlfw_NewFrame();
    ImGui_ImplVulkan_NewFrame();
    ImGui::NewFrame();

    ImGuiWindowFlags window_flags = ImGuiWindowFlags_MenuBar | ImGuiWindowFlags_NoTitleBar |
        ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoBringToFrontOnFocus |
        ImGuiWindowFlags_NoNavFocus | ImGuiWindowFlags_NoDocking;

    const ImGuiViewport* viewport = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(viewport->WorkPos);
    ImGui::SetNextWindowSize(viewport->WorkSize);

    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0,0));
    ImGui::Begin("DockSpace", nullptr, window_flags);
    ImGui::PopStyleVar();

    if (ImGui::BeginMenuBar()) {
        if (ImGui::BeginMenu("File")) {
            if (ImGui::MenuItem("Exit", "Ctrl+Q")) {
            }
            ImGui::EndMenu();
        }
        if (ImGui::BeginMenu("View")) {
            ImGui::MenuItem("Scene Graph", nullptr, true, true);
            ImGui::MenuItem("Assets", nullptr, true, true);
            ImGui::EndMenu();
        }
        ImGui::EndMenuBar();
    }

    draw_scene_graph_panel();
    draw_asset_browser_panel();

    ImGui::End();

    ImGui::Render();

    cardinal_renderer_set_ui_callback(g_renderer, imgui_record);
}

void editor_layer_shutdown(void) {
    if (g_renderer) {
        cardinal_renderer_set_ui_callback(g_renderer, NULL);
    }
    ImGui_ImplVulkan_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    ImGui::DestroyContext();
}
