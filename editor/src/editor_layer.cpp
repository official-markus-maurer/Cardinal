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
#include <cmath>
namespace fs = std::filesystem;

static CardinalRenderer* g_renderer = NULL;
static VkDescriptorPool g_descriptor_pool = VK_NULL_HANDLE;
static bool g_scene_loaded = false;
static CardinalScene g_scene; // zero-initialized on start
static char g_scene_path[512] = "";
static char g_status_msg[256] = "";

// PBR settings
static bool g_pbr_enabled = true;  // Enable by default to match renderer
static CardinalCamera g_camera = {
    .position = {0.0f, 0.0f, 2.0f},    // Simple camera position looking down -Z
    .target = {0.0f, 0.0f, 0.0f},      // Looking at origin
    .up = {0.0f, 1.0f, 0.0f},
    .fov = 65.0f,
    .aspect = 16.0f / 9.0f,
    .near_plane = 0.1f,
    .far_plane = 100.0f
};
static CardinalLight g_light = {
    .direction = {-0.3f, -0.7f, -0.5f}, // Better directional light angle
    .color = {1.0f, 1.0f, 0.95f},       // Slightly warmer light
    .intensity = 8.0f,                  // Increase intensity significantly
    .ambient = {0.3f, 0.3f, 0.35f}      // Brighter ambient for visibility
};

// Camera movement state
static bool g_mouse_captured = false;
static double g_last_mouse_x = 0.0;
static double g_last_mouse_y = 0.0;
static bool g_first_mouse = true;
static float g_yaw = -90.0f;   // Initially looking down -Z axis
static float g_pitch = 0.0f;
static float g_camera_speed = 5.0f;
static float g_mouse_sensitivity = 0.1f;

// Input state
static bool g_tab_pressed_last_frame = false;

// Window handle for input
static GLFWwindow* g_window_handle = nullptr;

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
/**
 * @brief Loads a scene from the given file path.
 *
 * This function attempts to load a glTF or glb scene file, updates the global scene state,
 * and sets status messages accordingly.
 *
 * @param path The file path to the scene file.
 *
 * @todo Support loading other scene formats besides glTF/glb.
 * @todo Implement asynchronous loading to prevent UI blocking.
 * @todo Add progress reporting during loading.
 */
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
/**
 * @brief Configures the ImGui style for the editor.
 *
 * Sets up colors and styles for a dark theme.
 *
 * @todo Allow customizable themes or light/dark mode switching.
 * @todo Optimize style for better accessibility.
 */
static void setup_imgui_style() {
    ImGui::StyleColorsDark();
}

/**
 * @brief Scans the assets directory and populates the asset entries list.
 *
 * Clears existing entries and scans the specified directory for files,
 * filtering and collecting glTF/glb files.
 *
 * @todo Support subdirectories and folder navigation in asset browser.
 * @todo Add file type icons and previews.
 * @todo Implement search and filtering in asset list.
 */
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

static const float kPI = 3.14159265358979323846f;

/**
 * @brief Clamps the camera pitch angle to valid range.
 *
 * @todo Add configurable pitch limits.
 */
static void clamp_pitch() {
    if (g_pitch > 89.0f) g_pitch = 89.0f;
    if (g_pitch < -89.0f) g_pitch = -89.0f;
}

/**
 * @brief Updates camera target based on yaw and pitch angles.
 *
 * @todo Integrate with quaternion-based rotation for smoother control.
 */
static void update_camera_from_angles() {
    // Compute forward direction from yaw/pitch
    float radYaw = g_yaw * kPI / 180.0f;
    float radPitch = g_pitch * kPI / 180.0f;
    float fx = cosf(radYaw) * cosf(radPitch);
    float fy = sinf(radPitch);
    float fz = sinf(radYaw) * cosf(radPitch);

    // Normalize forward
    float len = sqrtf(fx*fx + fy*fy + fz*fz);
    if (len > 0.0f) { fx /= len; fy /= len; fz /= len; }

    // Update target as position + forward
    g_camera.target[0] = g_camera.position[0] + fx;
    g_camera.target[1] = g_camera.position[1] + fy;
    g_camera.target[2] = g_camera.position[2] + fz;
}

// Remove GLFW callbacks approach; we will poll input each frame to avoid clobbering ImGui backend callbacks

/**
 * @brief Sets mouse capture state for camera control.
 *
 * @param capture Whether to capture the mouse.
 *
 * @todo Handle mouse capture conflicts with ImGui.
 */
static void set_mouse_capture(bool capture) {
    g_mouse_captured = capture;
    if (!g_window_handle) return;
    glfwSetInputMode(g_window_handle, GLFW_CURSOR, capture ? GLFW_CURSOR_DISABLED : GLFW_CURSOR_NORMAL);
    g_first_mouse = true;
}

/**
 * @brief Processes input and updates camera movement.
 *
 * @param dt Delta time for movement calculations.
 *
 * @todo Add configurable key bindings.
 * @todo Implement smooth acceleration/deceleration.
 * @todo Support gamepad input.
 */
static void process_input_and_move_camera(float dt) {
    if (!g_window_handle) return;

    // Mouse look when captured
    if (g_mouse_captured) {
        double xpos, ypos;
        glfwGetCursorPos(g_window_handle, &xpos, &ypos);
        if (g_first_mouse) {
            g_last_mouse_x = xpos;
            g_last_mouse_y = ypos;
            g_first_mouse = false;
        }
        double xoffset = xpos - g_last_mouse_x;
        double yoffset = g_last_mouse_y - ypos; // reverse since y increases downward
        g_last_mouse_x = xpos;
        g_last_mouse_y = ypos;

        g_yaw   += (float)xoffset * g_mouse_sensitivity;
        g_pitch += (float)yoffset * g_mouse_sensitivity;
        clamp_pitch();
        update_camera_from_angles();
    }

    // Poll keys
    int ctrl = (glfwGetKey(g_window_handle, GLFW_KEY_LEFT_CONTROL) == GLFW_PRESS) || (glfwGetKey(g_window_handle, GLFW_KEY_RIGHT_CONTROL) == GLFW_PRESS);
    int shift = (glfwGetKey(g_window_handle, GLFW_KEY_LEFT_SHIFT) == GLFW_PRESS) || (glfwGetKey(g_window_handle, GLFW_KEY_RIGHT_SHIFT) == GLFW_PRESS);
    int w = glfwGetKey(g_window_handle, GLFW_KEY_W) == GLFW_PRESS;
    int a = glfwGetKey(g_window_handle, GLFW_KEY_A) == GLFW_PRESS;
    int s = glfwGetKey(g_window_handle, GLFW_KEY_S) == GLFW_PRESS;
    int d = glfwGetKey(g_window_handle, GLFW_KEY_D) == GLFW_PRESS;
    int space = glfwGetKey(g_window_handle, GLFW_KEY_SPACE) == GLFW_PRESS;

    // Calculate forward/right vectors from yaw/pitch
    float radYaw = g_yaw * kPI / 180.0f;
    float radPitch = g_pitch * kPI / 180.0f;
    float forward[3] = { cosf(radYaw) * cosf(radPitch), sinf(radPitch), sinf(radYaw) * cosf(radPitch) };
    float fl = sqrtf(forward[0]*forward[0] + forward[1]*forward[1] + forward[2]*forward[2]);
    if (fl > 0.0f) { forward[0]/=fl; forward[1]/=fl; forward[2]/=fl; }
    float up[3] = {0.0f, 1.0f, 0.0f};
    float right[3] = {
        forward[2]*up[1] - forward[1]*up[2],
        forward[0]*up[2] - forward[2]*up[0],
        forward[1]*up[0] - forward[0]*up[1]
    };
    float rl = sqrtf(right[0]*right[0] + right[1]*right[1] + right[2]*right[2]);
    if (rl > 0.0f) { right[0]/=rl; right[1]/=rl; right[2]/=rl; }

    float speed = g_camera_speed * (ctrl ? 4.0f : 1.0f);
    float delta = speed * dt;

    if (g_mouse_captured) {
        if (w) {
            g_camera.position[0] += forward[0] * delta;
            g_camera.position[1] += forward[1] * delta;
            g_camera.position[2] += forward[2] * delta;
        }
        if (s) {
            g_camera.position[0] -= forward[0] * delta;
            g_camera.position[1] -= forward[1] * delta;
            g_camera.position[2] -= forward[2] * delta;
        }
        if (a) {
            g_camera.position[0] -= right[0] * delta;
            g_camera.position[1] -= right[1] * delta;
            g_camera.position[2] -= right[2] * delta;
        }
        if (d) {
            g_camera.position[0] += right[0] * delta;
            g_camera.position[1] += right[1] * delta;
            g_camera.position[2] += right[2] * delta;
        }
        if (space) {
            g_camera.position[1] += delta;
        }
        if (shift) {
            g_camera.position[1] -= delta;
        }

        update_camera_from_angles();

        if (g_renderer && g_pbr_enabled) {
            cardinal_renderer_set_camera(g_renderer, &g_camera);
        }
    }
}

/**
 * @brief Initializes the editor layer.
 *
 * Sets up ImGui, descriptor pools, and initial states.
 *
 * @param window The window handle.
 * @param renderer The renderer instance.
 * @return True if initialization succeeded.
 *
 * @todo Improve error handling and recovery.
 * @todo Add support for multiple renderers or backends.
 */
bool editor_layer_init(CardinalWindow* window, CardinalRenderer* renderer) {
    g_renderer = renderer;
    g_scene_loaded = false;
    memset(&g_scene, 0, sizeof(g_scene));

    // Store window handle for input
    g_window_handle = window ? (GLFWwindow*)window->handle : nullptr;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    // Disable multi-viewport for now to avoid Vulkan sync conflicts
    // io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable;

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
    
    // Dynamic rendering is required; configure ImGui accordingly
    init_info.UseDynamicRendering = true;
    init_info.PipelineRenderingCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
    init_info.PipelineRenderingCreateInfo.pNext = NULL;

    // Get swapchain format for color attachment
    VkFormat colorFormat = cardinal_renderer_internal_swapchain_format(renderer);
    init_info.PipelineRenderingCreateInfo.colorAttachmentCount = 1;
    init_info.PipelineRenderingCreateInfo.pColorAttachmentFormats = &colorFormat;
    init_info.PipelineRenderingCreateInfo.depthAttachmentFormat = cardinal_renderer_internal_depth_format(renderer);
    init_info.PipelineRenderingCreateInfo.stencilAttachmentFormat = VK_FORMAT_UNDEFINED;

    init_info.RenderPass = VK_NULL_HANDLE;

    if (!ImGui_ImplVulkan_Init(&init_info)) {
        fprintf(stderr, "ImGui Vulkan init failed\n");
        return false;
    }

    // Initial asset scan
    scan_assets_dir();

    // Initialize PBR uniforms if PBR is enabled (which it is by default)
    if (g_pbr_enabled && g_renderer) {
        cardinal_renderer_set_camera(g_renderer, &g_camera);
        cardinal_renderer_set_lighting(g_renderer, &g_light);
    }

    return true;
}

/**
 * @brief Draws the scene graph panel.
 *
 * Displays hierarchical view of scene elements.
 *
 * @todo Implement drag-and-drop for hierarchy manipulation.
 * @todo Add context menus for entities.
 * @todo Support scene hierarchy editing.
 */
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

/**
 * @brief Draws the asset browser panel.
 *
 * Displays assets list and loading controls.
 *
 * @todo Implement asset preview thumbnails.
 * @todo Add asset import and management features.
 * @todo Support drag-and-drop to scene.
 */
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

static void draw_pbr_settings_panel() {
    if (ImGui::Begin("PBR Settings")) {
        // PBR Enable/Disable
        if (ImGui::Checkbox("Enable PBR Rendering", &g_pbr_enabled)) {
            if (g_renderer) {
                cardinal_renderer_enable_pbr(g_renderer, g_pbr_enabled);
                if (g_pbr_enabled) {
                    // Update camera and lighting when enabling PBR
                    cardinal_renderer_set_camera(g_renderer, &g_camera);
                    cardinal_renderer_set_lighting(g_renderer, &g_light);
                }
            }
        }
        
        ImGui::Separator();
        
        // Camera Settings
        if (ImGui::CollapsingHeader("Camera", ImGuiTreeNodeFlags_DefaultOpen)) {
            bool camera_changed = false;
            
            camera_changed |= ImGui::SliderFloat3("Position", g_camera.position, -10.0f, 10.0f);
            camera_changed |= ImGui::SliderFloat3("Target", g_camera.target, -10.0f, 10.0f);
            camera_changed |= ImGui::SliderFloat("FOV", &g_camera.fov, 10.0f, 120.0f);
            camera_changed |= ImGui::SliderFloat("Aspect Ratio", &g_camera.aspect, 0.5f, 3.0f);
            camera_changed |= ImGui::SliderFloat("Near Plane", &g_camera.near_plane, 0.01f, 1.0f);
            camera_changed |= ImGui::SliderFloat("Far Plane", &g_camera.far_plane, 10.0f, 1000.0f);
            
            if (camera_changed && g_pbr_enabled && g_renderer) {
                cardinal_renderer_set_camera(g_renderer, &g_camera);
            }
        }
        
        ImGui::Separator();
        
        // Lighting Settings
        if (ImGui::CollapsingHeader("Lighting", ImGuiTreeNodeFlags_DefaultOpen)) {
            bool light_changed = false;
            
            light_changed |= ImGui::SliderFloat3("Direction", g_light.direction, -1.0f, 1.0f);
            light_changed |= ImGui::ColorEdit3("Color", g_light.color);
            light_changed |= ImGui::SliderFloat("Intensity", &g_light.intensity, 0.0f, 10.0f);
            light_changed |= ImGui::ColorEdit3("Ambient", g_light.ambient);
            
            if (light_changed && g_pbr_enabled && g_renderer) {
                cardinal_renderer_set_lighting(g_renderer, &g_light);
            }
        }
        
        ImGui::Separator();
        
        // Status
        if (g_renderer) {
            bool is_pbr_active = cardinal_renderer_is_pbr_enabled(g_renderer);
            ImGui::Text("PBR Status: %s", is_pbr_active ? "Active" : "Inactive");
        }
    }
    ImGui::End();
}

/**
 * @brief Draws the 3D viewport panel.
 *
 * Creates a window showing the rendered 3D scene.
 * For now, this displays a placeholder until we implement offscreen rendering.
 *
 * @todo Implement offscreen rendering to texture for proper viewport display.
 * @todo Add viewport controls like wireframe mode, camera reset.
 * @todo Handle viewport window resizing and update camera aspect ratio.
 */

static void imgui_record(VkCommandBuffer cmd) {
    ImDrawData* dd = ImGui::GetDrawData();
    ImGui_ImplVulkan_RenderDrawData(dd, cmd);
}

void editor_layer_update(void) {
    // Toggle mouse capture with Tab (edge detection)
    bool tab_down = g_window_handle && (glfwGetKey(g_window_handle, GLFW_KEY_TAB) == GLFW_PRESS);
    if (tab_down && !g_tab_pressed_last_frame) {
        set_mouse_capture(!g_mouse_captured);
    }
    g_tab_pressed_last_frame = tab_down;

    ImGuiIO& io = ImGui::GetIO();
    float dt = io.DeltaTime > 0.0f ? io.DeltaTime : 1.0f/60.0f;

    if (g_mouse_captured) {
        io.WantCaptureMouse = false;
        io.WantCaptureKeyboard = false;
    }

    process_input_and_move_camera(dt);

    // Keep camera aspect synced with the window/swapchain size since the scene renders in the background
    if (g_renderer && g_pbr_enabled) {
        VkExtent2D extent = cardinal_renderer_internal_swapchain_extent(g_renderer);
        if (extent.width > 0 && extent.height > 0) {
            float new_aspect = (float)extent.width / (float)extent.height;
            if (fabsf(new_aspect - g_camera.aspect) > 0.001f) {
                g_camera.aspect = new_aspect;
                cardinal_renderer_set_camera(g_renderer, &g_camera);
            }
        }
    }
}

// In render, keep as-is; mouse capture only affects input, not UI drawing
void editor_layer_render(void) {
    ImGui_ImplGlfw_NewFrame();
    ImGui_ImplVulkan_NewFrame();
    ImGui::NewFrame();

    ImGuiWindowFlags window_flags = ImGuiWindowFlags_MenuBar | ImGuiWindowFlags_NoTitleBar |
        ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoBringToFrontOnFocus |
        ImGuiWindowFlags_NoNavFocus | ImGuiWindowFlags_NoDocking | ImGuiWindowFlags_NoBackground;

    const ImGuiViewport* viewport = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(viewport->WorkPos);
    ImGui::SetNextWindowSize(viewport->WorkSize);

    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0,0));
    ImGui::Begin("DockSpace", nullptr, window_flags);
    ImGui::PopStyleVar();

    // Create a central dockspace so panels can appear and be interactive
    ImGuiID dock_id = ImGui::GetID("EditorDockSpace");
    ImGuiDockNodeFlags dockspace_flags = ImGuiDockNodeFlags_PassthruCentralNode;
    ImGui::DockSpace(dock_id, ImVec2(0.0f, 0.0f), dockspace_flags);

    if (ImGui::BeginMenuBar()) {
        if (ImGui::BeginMenu("File")) {
            if (ImGui::MenuItem("Exit", "Ctrl+Q")) {
            }
            ImGui::EndMenu();
        }
        if (ImGui::BeginMenu("View")) {
            ImGui::MenuItem("Scene Graph", nullptr, true, true);
            ImGui::MenuItem("Assets", nullptr, true, true);
            ImGui::MenuItem("PBR Settings", nullptr, true, true);
            ImGui::EndMenu();
        }
        ImGui::EndMenuBar();
    }

    draw_scene_graph_panel();
    draw_asset_browser_panel();
    draw_pbr_settings_panel();

    ImGui::End();

    // Set up UI callback before render to ensure proper command recording
    cardinal_renderer_set_ui_callback(g_renderer, imgui_record);

    ImGui::Render();

    // Only render platform windows if multi-viewport is enabled
    ImGuiIO& io = ImGui::GetIO();
    if ((io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) != 0) {
        ImGui::UpdatePlatformWindows();
        ImGui::RenderPlatformWindowsDefault();
    }
}

void editor_layer_shutdown(void) {
    if (g_renderer) {
        cardinal_renderer_set_ui_callback(g_renderer, NULL);
        // Wait for device idle before cleanup to avoid destroying resources in use
        cardinal_renderer_wait_idle(g_renderer);
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
