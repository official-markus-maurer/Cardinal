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
#include <cardinal/cardinal.h>
#include <cardinal/assets/loader.h>
#include <cardinal/assets/scene.h>

#include <vector>
#include <string>
#include <algorithm>
#include <filesystem>
namespace fs = std::filesystem;

static CardinalRenderer* g_renderer = NULL;
static VkDescriptorPool g_descriptor_pool = VK_NULL_HANDLE;
static bool g_scene_loaded = false;
static CardinalScene g_scene; // zero-initialized on start
static char g_scene_path[512] = "";
static char g_status_msg[256] = "";

// Asset browser state
static char g_assets_dir[512] = "assets";
struct AssetEntry {
    std::string display; // label shown in UI (rootName/relativePath)
    std::string fullPath; // full path (or cwd-relative) used for loading
    bool is_gltf;
    bool is_glb;
};
static std::vector<AssetEntry> g_asset_entries;

// Load scene helper
static void load_scene_from_path(const char* path) {
    if (!path || !path[0]) {
        return;
    }
    if (g_scene_loaded) {
        cardinal_scene_destroy(&g_scene);
        memset(&g_scene, 0, sizeof(g_scene));
        g_scene_loaded = false;
        // Clear previous GPU scene
        if (g_renderer) cardinal_renderer_clear_scene(g_renderer);
    }
    if (cardinal_scene_load(path, &g_scene)) {
        g_scene_loaded = true;
        // Upload to GPU for drawing
        if (g_renderer) cardinal_renderer_upload_scene(g_renderer, &g_scene);
        snprintf(g_status_msg, sizeof(g_status_msg), "Loaded scene: %u mesh(es) from %s", (unsigned)g_scene.mesh_count, path);
    } else {
        snprintf(g_status_msg, sizeof(g_status_msg), "Failed to load: %s", path);
    }
    // Update the input field to reflect last attempted path
    snprintf(g_scene_path, sizeof(g_scene_path), "%s", path);
}
static void setup_imgui_style() {
    ImGui::StyleColorsDark();
}

static void scan_assets_dir() {
    g_asset_entries.clear();
    try {
        fs::path root = fs::path(g_assets_dir);
        if (!root.empty() && fs::exists(root) && fs::is_directory(root)) {
            const std::string rootName = root.filename().string().empty() ? root.string() : root.filename().string();
            for (auto const& it : fs::recursive_directory_iterator(root)) {
                if (it.is_regular_file()) {
                    fs::path rel;
                    try { rel = fs::relative(it.path(), root); } catch (...) { rel = it.path().filename(); }
                    std::string label = rootName + std::string("/") + rel.generic_string();
                    std::string full = it.path().string();
                    std::replace(label.begin(), label.end(), '\\', '/');
                    std::replace(full.begin(), full.end(), '\\', '/');
                    std::string lower = full;
                    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c){ return (char)std::tolower(c); });
                    bool is_gltf = lower.size() >= 5 && lower.compare(lower.size()-5, 5, ".gltf") == 0;
                    bool is_glb  = lower.size() >= 4 && lower.compare(lower.size()-4, 4, ".glb") == 0;
                    g_asset_entries.push_back(AssetEntry{label, full, is_gltf, is_glb});
                }
            }
            std::sort(g_asset_entries.begin(), g_asset_entries.end(), [](const AssetEntry& a, const AssetEntry& b){ return a.display < b.display; });
        }
    } catch (...) {
        // Silently ignore scanning errors; UI will reflect empty list or message
    }
}

bool editor_layer_init(CardinalWindow* window, CardinalRenderer* renderer) {
    g_renderer = renderer;
    g_scene_loaded = false;
    memset(&g_scene, 0, sizeof(g_scene));
    g_scene_path[0] = '\0';
    g_status_msg[0] = '\0';

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable;

    setup_imgui_style();
    if (io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) {
        ImGuiStyle& style = ImGui::GetStyle();
        style.WindowRounding = 0.0f;
        style.Colors[ImGuiCol_WindowBg].w = 1.0f;
    }

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
    if (vkCreateDescriptorPool(device, &pool_info, NULL, &g_descriptor_pool) != VK_SUCCESS) {
        fprintf(stderr, "Failed to create descriptor pool\n");
        return false;
    }

    ImGui_ImplVulkan_InitInfo init_info{};
    init_info.Instance = cardinal_renderer_internal_instance(renderer);
    init_info.PhysicalDevice = cardinal_renderer_internal_physical_device(renderer);
    init_info.Device = device;
    init_info.QueueFamily = cardinal_renderer_internal_graphics_queue_family(renderer);
    init_info.Queue = cardinal_renderer_internal_graphics_queue(renderer);
    init_info.DescriptorPool = g_descriptor_pool;
    init_info.MinImageCount = cardinal_renderer_internal_swapchain_image_count(renderer);
    init_info.ImageCount = cardinal_renderer_internal_swapchain_image_count(renderer);
    init_info.MSAASamples = VK_SAMPLE_COUNT_1_BIT;
    init_info.RenderPass = cardinal_renderer_internal_render_pass(renderer);

    if (!ImGui_ImplVulkan_Init(&init_info)) {
        fprintf(stderr, "ImGui Vulkan init failed\n");
        return false;
    }

    // Font upload is handled automatically by ImGui Vulkan backend

    // Initial asset scan
    scan_assets_dir();

    return true;
}

static void draw_scene_graph_panel() {
    if (ImGui::Begin("Scene Graph")) {
        if (ImGui::TreeNode("Root")) {
            ImGui::BulletText("Camera");
            ImGui::BulletText("Directional Light");
            if (g_scene_loaded) {
                if (ImGui::TreeNode("Loaded Scene")) {
                    ImGui::Text("Meshes: %u", (unsigned)g_scene.mesh_count);
                    for (uint32_t i = 0; i < g_scene.mesh_count; ++i) {
                        const CardinalMesh& m = g_scene.meshes[i];
                        ImGui::BulletText("Mesh %u: %u vertices, %u indices", (unsigned)i, (unsigned)m.vertex_count, (unsigned)m.index_count);
                    }
                    ImGui::TreePop();
                }
            }
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

        // Assets directory controls
        ImGui::Text("Assets Directory:");
        ImGui::SetNextItemWidth(-FLT_MIN);
        if (ImGui::InputTextWithHint("##assets_dir", "Relative or absolute path to assets folder", g_assets_dir, sizeof(g_assets_dir))) {
            // Optionally debounce; for simplicity, re-scan when text changes
            scan_assets_dir();
        }
        if (ImGui::Button("Refresh")) {
            scan_assets_dir();
        }

        ImGui::Separator();

        // Simple scene load controls
        ImGui::Text("Load Scene (glTF/glb)");
        ImGui::SetNextItemWidth(-FLT_MIN);
        ImGui::InputTextWithHint("##scene_path", "C:/path/to/scene.gltf or .glb", g_scene_path, sizeof(g_scene_path));
        if (ImGui::Button("Load")) {
            load_scene_from_path(g_scene_path);
        }
        if (g_status_msg[0] != '\0') {
            ImGui::TextWrapped("%s", g_status_msg);
        }

        ImGui::Separator();
        
        // Dynamic assets list
        if (g_asset_entries.empty()) {
            ImGui::TextDisabled("No assets found in '%s'", g_assets_dir);
        } else {
            if (ImGui::BeginChild("##assets_list", ImVec2(0, 0), true)) {
                for (const auto& e : g_asset_entries) {
                    if (ImGui::Selectable(e.display.c_str())) {
                        // Always populate the path field with the real full path
                        snprintf(g_scene_path, sizeof(g_scene_path), "%s", e.fullPath.c_str());
                        // If it's a glTF/GLB, load on single click for convenience
                        if (e.is_gltf || e.is_glb) {
                            load_scene_from_path(e.fullPath.c_str());
                        }
                    }
                    // Additionally, support double-click to load if hovered
                    if ((e.is_gltf || e.is_glb) && ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(0)) {
                        load_scene_from_path(e.fullPath.c_str());
                    }
                }
            }
            ImGui::EndChild();
        }
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

    // Create a central dockspace so panels can appear and be interactive
    ImGuiID dock_id = ImGui::GetID("EditorDockSpace");
    ImGui::DockSpace(dock_id, ImVec2(0.0f, 0.0f));

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

    ImGuiIO& io = ImGui::GetIO();
    if (io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) {
        ImGui::UpdatePlatformWindows();
        ImGui::RenderPlatformWindowsDefault();
    }
}

void editor_layer_shutdown(void) {
    if (g_renderer) {
        cardinal_renderer_set_ui_callback(g_renderer, NULL);
    }
    if (g_scene_loaded) {
        cardinal_scene_destroy(&g_scene);
        memset(&g_scene, 0, sizeof(g_scene));
        g_scene_loaded = false;
    }
    ImGui_ImplVulkan_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    if (g_descriptor_pool != VK_NULL_HANDLE) {
        VkDevice device = cardinal_renderer_internal_device(g_renderer);
        vkDestroyDescriptorPool(device, g_descriptor_pool, NULL);
        g_descriptor_pool = VK_NULL_HANDLE;
    }
    ImGui::DestroyContext();
}
