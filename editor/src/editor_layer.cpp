// Editor Layer - Placeholder for future UI/editing functionality
#include <GLFW/glfw3.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#include <backends/imgui_impl_glfw.h>
#include <backends/imgui_impl_vulkan.h>
#include <imgui.h>

#include "editor_layer.h"
#include <cardinal/assets/loader.h>
#include <cardinal/assets/scene.h>
#include <cardinal/cardinal.h>
#include <cardinal/core/async_loader.h>
#include <cardinal/core/window.h>
#include <cardinal/renderer/renderer.h>
#include <cardinal/renderer/renderer_internal.h>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <string>
#include <vector>
namespace fs = std::filesystem;

static CardinalRenderer *g_renderer = NULL;
static VkDescriptorPool g_descriptor_pool = VK_NULL_HANDLE;
static bool g_scene_loaded = false;
static CardinalAsyncTask *g_loading_task = nullptr;
static bool g_is_loading = false;
static CardinalScene g_scene; // zero-initialized on start
static char g_scene_path[512] = "";
static char g_status_msg[256] = "";

// PBR settings
static bool g_pbr_enabled = true; // Enable by default to match renderer
static CardinalCamera g_camera = {
    .position = {0.0f, 0.0f, 2.0f}, // Simple camera position looking down -Z
    .target = {0.0f, 0.0f, 0.0f},   // Looking at origin
    .up = {0.0f, 1.0f, 0.0f},
    .fov = 65.0f,
    .aspect = 16.0f / 9.0f,
    .near_plane = 0.1f,
    .far_plane = 100.0f};
static CardinalLight g_light = {
    .direction = {-0.3f, -0.7f, -0.5f}, // Better directional light angle
    .color = {1.0f, 1.0f, 0.95f},       // Slightly warmer light
    .intensity = 8.0f,                  // Increase intensity significantly
    .ambient = {0.3f, 0.3f, 0.35f}      // Brighter ambient for visibility
};

// Material factor overrides for testing
static float g_material_albedo[3] = {1.0f, 1.0f, 1.0f};
static float g_material_metallic = 0.0f;
static float g_material_roughness = 0.5f;
static float g_material_emissive[3] = {0.0f, 0.0f, 0.0f};
static float g_material_normal_scale = 1.0f;
static float g_material_ao_strength = 1.0f;
static bool g_material_override_enabled = false;

// Camera movement state
static bool g_mouse_captured = false;
static double g_last_mouse_x = 0.0;
static double g_last_mouse_y = 0.0;
static bool g_first_mouse = true;
static float g_yaw =
    90.0f; // Initially looking down -Z axis (adjusted for coordinate system)
static float g_pitch = 0.0f;
static float g_camera_speed = 5.0f;
static float g_mouse_sensitivity = 0.1f;

// Input state
static bool g_tab_pressed_last_frame = false;

// Window handle for input
static GLFWwindow *g_window_handle = nullptr;

// Asset browser state
static char g_assets_dir[512] = "assets";
static char g_current_dir[512] = "assets"; // Current browsing directory
static char g_search_filter[256] = ""; // Search filter text
static bool g_show_folders_only = false;
static bool g_show_gltf_only = false;
static bool g_show_textures_only = false;

enum AssetType {
  ASSET_TYPE_FOLDER,
  ASSET_TYPE_GLTF,
  ASSET_TYPE_GLB,
  ASSET_TYPE_TEXTURE,
  ASSET_TYPE_OTHER
};

struct AssetEntry {
  std::string display;     // label shown in UI (filename or folder name)
  std::string fullPath;    // full path used for loading/navigation
  std::string relativePath; // relative path from assets root
  AssetType type;
  bool is_directory;
};
static std::vector<AssetEntry> g_asset_entries;
static std::vector<AssetEntry> g_filtered_entries; // Filtered results

// Load scene helper
/**
 * @brief Callback function for async scene loading completion
 */
static void scene_load_callback(CardinalAsyncTask *task, void *user_data) {
  const char *path = (const char *)user_data;

  if (cardinal_async_get_task_status(task) == CARDINAL_ASYNC_STATUS_COMPLETED) {
    CardinalScene loaded_scene;
    if (cardinal_async_get_scene_result(task, &loaded_scene)) {
      // Scene was already cleared in load_scene_from_path, just assign new one
      g_scene = loaded_scene;
      g_scene_loaded = true;

      // Upload to GPU for drawing
      if (g_renderer) {
        cardinal_renderer_upload_scene(g_renderer, &g_scene);
        
        // Update camera and lighting after scene upload to ensure proper rendering
        if (g_pbr_enabled) {
          cardinal_renderer_set_camera(g_renderer, &g_camera);
          cardinal_renderer_set_lighting(g_renderer, &g_light);
        }
      }

      snprintf(g_status_msg, sizeof(g_status_msg),
               "Loaded scene: %u mesh(es) from %s",
               (unsigned)g_scene.mesh_count, path);
    } else {
      snprintf(g_status_msg, sizeof(g_status_msg),
               "Failed to process loaded scene: %s", path);
    }
  } else {
    const char *error_msg = cardinal_async_get_error_message(task);
    snprintf(g_status_msg, sizeof(g_status_msg), "Failed to load: %s - %s",
             path, error_msg ? error_msg : "Unknown error");
  }

  // Cleanup
  cardinal_async_free_task(task);
  g_loading_task = nullptr;
  g_is_loading = false;

  // Free the path copy
  free((void *)path);
}

/**
 * @brief Loads a scene from the given file path asynchronously.
 *
 * This function attempts to load a glTF or glb scene file asynchronously
 * to prevent UI blocking, updates the global scene state, and sets status
 * messages accordingly.
 *
 * @param path The file path to the scene file.
 * @param use_async Whether to use asynchronous loading (true) or synchronous
 * (false)
 *
 * @todo Support loading other scene formats besides glTF/glb.
 * @todo Add progress reporting during loading.
 */
static void load_scene_from_path(const char *path, bool use_async = true) {
  if (!path || !path[0]) {
    return;
  }

  // Prevent multiple simultaneous loads to avoid race conditions
  // TODO: Obviously want multiple models to be loadable simultaneously but not the same one at the same time.
  if (g_is_loading) {
    snprintf(g_status_msg, sizeof(g_status_msg), "Already loading a scene, please wait...");
    return;
  }

  // Cancel any existing loading task
  if (g_loading_task) {
    cardinal_async_cancel_task(g_loading_task);
    cardinal_async_free_task(g_loading_task);
    g_loading_task = nullptr;
    g_is_loading = false;
  }

  // Clean up current scene before loading new one (prevents double-loading conflicts)
  if (g_scene_loaded) {
    cardinal_scene_destroy(&g_scene);
    memset(&g_scene, 0, sizeof(g_scene));
    g_scene_loaded = false;
    // Clear previous GPU scene
    if (g_renderer)
      cardinal_renderer_clear_scene(g_renderer);
  }

  // Update the input field to reflect attempted path
  snprintf(g_scene_path, sizeof(g_scene_path), "%s", path);

  if (use_async && cardinal_async_loader_is_initialized()) {
    // Asynchronous loading
    g_is_loading = true;
    snprintf(g_status_msg, sizeof(g_status_msg), "Loading scene: %s...", path);

    // Create a copy of the path for the callback
    char *path_copy = (char *)malloc(strlen(path) + 1);
    if (path_copy) {
      strcpy_s(path_copy, strlen(path) + 1, path);

      g_loading_task = cardinal_scene_load_async(
          path, CARDINAL_ASYNC_PRIORITY_HIGH, scene_load_callback, path_copy);
      if (!g_loading_task) {
        snprintf(g_status_msg, sizeof(g_status_msg),
                 "Failed to start async loading: %s", path);
        g_is_loading = false;
        free(path_copy);
      }
    } else {
      snprintf(g_status_msg, sizeof(g_status_msg),
               "Memory allocation failed for: %s", path);
      g_is_loading = false;
    }
  } else {
    // Synchronous loading (fallback)
    if (g_scene_loaded) {
      cardinal_scene_destroy(&g_scene);
      memset(&g_scene, 0, sizeof(g_scene));
      g_scene_loaded = false;
      // Clear previous GPU scene
      if (g_renderer)
        cardinal_renderer_clear_scene(g_renderer);
    }

    if (cardinal_scene_load(path, &g_scene)) {
      g_scene_loaded = true;
      // Upload to GPU for drawing
      if (g_renderer)
        cardinal_renderer_upload_scene(g_renderer, &g_scene);
      snprintf(g_status_msg, sizeof(g_status_msg),
               "Loaded scene: %u mesh(es) from %s",
               (unsigned)g_scene.mesh_count, path);
    } else {
      snprintf(g_status_msg, sizeof(g_status_msg), "Failed to load: %s", path);
    }
  }
}
/**
 * @brief Configures the ImGui style for the editor.
 *
 * Sets up colors and styles for a dark theme.
 *
 * @todo Allow customizable themes or light/dark mode switching.
 * @todo Optimize style for better accessibility.
 */
static void setup_imgui_style() { ImGui::StyleColorsDark(); }

/**
 * @brief Determines the asset type based on file extension.
 */
static AssetType get_asset_type(const std::string& path) {
  std::string lower = path;
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](unsigned char c) { return (char)std::tolower(c); });
  
  if (lower.size() >= 5 && lower.compare(lower.size() - 5, 5, ".gltf") == 0) {
    return ASSET_TYPE_GLTF;
  }
  if (lower.size() >= 4 && lower.compare(lower.size() - 4, 4, ".glb") == 0) {
    return ASSET_TYPE_GLB;
  }
  if (lower.size() >= 4 && (
      lower.compare(lower.size() - 4, 4, ".png") == 0 ||
      lower.compare(lower.size() - 4, 4, ".jpg") == 0 ||
      lower.compare(lower.size() - 4, 4, ".tga") == 0 ||
      lower.compare(lower.size() - 4, 4, ".bmp") == 0)) {
    return ASSET_TYPE_TEXTURE;
  }
  if (lower.size() >= 5 && lower.compare(lower.size() - 5, 5, ".jpeg") == 0) {
    return ASSET_TYPE_TEXTURE;
  }
  return ASSET_TYPE_OTHER;
}

/**
 * @brief Gets the appropriate icon for an asset type.
 */
static const char* get_asset_icon(AssetType type) {
  switch (type) {
    case ASSET_TYPE_FOLDER: return "📁";
    case ASSET_TYPE_GLTF:
    case ASSET_TYPE_GLB: return "🧊";
    case ASSET_TYPE_TEXTURE: return "🖼️";
    default: return "📄";
  }
}

/**
 * @brief Checks if an entry matches the current search filter.
 */
static bool matches_filter(const AssetEntry& entry) {
  // Text search filter
  if (strlen(g_search_filter) > 0) {
    std::string lower_display = entry.display;
    std::string lower_filter = g_search_filter;
    std::transform(lower_display.begin(), lower_display.end(), lower_display.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    std::transform(lower_filter.begin(), lower_filter.end(), lower_filter.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    if (lower_display.find(lower_filter) == std::string::npos) {
      return false;
    }
  }
  
  // Type filters
  if (g_show_folders_only && entry.type != ASSET_TYPE_FOLDER) return false;
  if (g_show_gltf_only && entry.type != ASSET_TYPE_GLTF && entry.type != ASSET_TYPE_GLB) return false;
  if (g_show_textures_only && entry.type != ASSET_TYPE_TEXTURE) return false;
  
  return true;
}

/**
 * @brief Scans the current directory and populates the asset entries list.
 *
 * Scans only the current directory (non-recursive) and categorizes files and folders.
 * Supports subdirectory navigation, file type icons, and filtering.
 */
static void scan_assets_dir() {
  g_asset_entries.clear();
  g_filtered_entries.clear();
  
  try {
    fs::path current_path = fs::path(g_current_dir);
    fs::path assets_root = fs::path(g_assets_dir);
    
    if (!current_path.empty() && fs::exists(current_path) && fs::is_directory(current_path)) {
      // Add ".." entry for parent directory navigation (if not at root)
      if (current_path != assets_root && current_path.has_parent_path()) {
        fs::path parent = current_path.parent_path();
        std::string parent_str = parent.string();
        std::replace(parent_str.begin(), parent_str.end(), '\\', '/');
        
        AssetEntry parent_entry;
        parent_entry.display = "..";
        parent_entry.fullPath = parent_str;
        parent_entry.relativePath = "..";
        parent_entry.type = ASSET_TYPE_FOLDER;
        parent_entry.is_directory = true;
        g_asset_entries.push_back(parent_entry);
      }
      
      // Scan current directory (non-recursive)
      for (auto const &it : fs::directory_iterator(current_path)) {
        AssetEntry entry;
        entry.fullPath = it.path().string();
        std::replace(entry.fullPath.begin(), entry.fullPath.end(), '\\', '/');
        entry.display = it.path().filename().string();
        
        // Calculate relative path from assets root
        try {
          fs::path rel = fs::relative(it.path(), assets_root);
          entry.relativePath = rel.generic_string();
        } catch (...) {
          entry.relativePath = entry.display;
        }
        
        if (it.is_directory()) {
          entry.type = ASSET_TYPE_FOLDER;
          entry.is_directory = true;
        } else if (it.is_regular_file()) {
          entry.type = get_asset_type(entry.fullPath);
          entry.is_directory = false;
        } else {
          continue; // Skip special files
        }
        
        g_asset_entries.push_back(entry);
      }
      
      // Sort entries: directories first, then files, alphabetically within each group
      std::sort(g_asset_entries.begin(), g_asset_entries.end(),
                [](const AssetEntry &a, const AssetEntry &b) {
                  if (a.display == "..") return true;
                  if (b.display == "..") return false;
                  if (a.is_directory != b.is_directory) {
                    return a.is_directory > b.is_directory;
                  }
                  return a.display < b.display;
                });
      
      // Apply filters
      for (const auto& entry : g_asset_entries) {
        if (matches_filter(entry)) {
          g_filtered_entries.push_back(entry);
        }
      }
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
  if (g_pitch > 89.0f)
    g_pitch = 89.0f;
  if (g_pitch < -89.0f)
    g_pitch = -89.0f;
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
  float len = sqrtf(fx * fx + fy * fy + fz * fz);
  if (len > 0.0f) {
    fx /= len;
    fy /= len;
    fz /= len;
  }

  // Update target as position + forward
  g_camera.target[0] = g_camera.position[0] + fx;
  g_camera.target[1] = g_camera.position[1] + fy;
  g_camera.target[2] = g_camera.position[2] + fz;
}

// Remove GLFW callbacks approach; we will poll input each frame to avoid
// clobbering ImGui backend callbacks

/**
 * @brief Sets mouse capture state for camera control.
 *
 * @param capture Whether to capture the mouse.
 *
 * @todo Handle mouse capture conflicts with ImGui.
 */
static void set_mouse_capture(bool capture) {
  g_mouse_captured = capture;
  if (!g_window_handle)
    return;
  glfwSetInputMode(g_window_handle, GLFW_CURSOR,
                   capture ? GLFW_CURSOR_DISABLED : GLFW_CURSOR_NORMAL);
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
  if (!g_window_handle)
    return;

  // Error checking for degenerate cases
  if (dt <= 0.0f || !isfinite(dt)) {
    return; // Invalid delta time
  }

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
    double yoffset =
        g_last_mouse_y - ypos; // reverse since y increases downward
    g_last_mouse_x = xpos;
    g_last_mouse_y = ypos;

    g_yaw += (float)xoffset * g_mouse_sensitivity;
    g_pitch += (float)yoffset * g_mouse_sensitivity;
    clamp_pitch();
    update_camera_from_angles();
  }

  // Poll keys
  int ctrl =
      (glfwGetKey(g_window_handle, GLFW_KEY_LEFT_CONTROL) == GLFW_PRESS) ||
      (glfwGetKey(g_window_handle, GLFW_KEY_RIGHT_CONTROL) == GLFW_PRESS);
  int shift =
      (glfwGetKey(g_window_handle, GLFW_KEY_LEFT_SHIFT) == GLFW_PRESS) ||
      (glfwGetKey(g_window_handle, GLFW_KEY_RIGHT_SHIFT) == GLFW_PRESS);
  int w = glfwGetKey(g_window_handle, GLFW_KEY_W) == GLFW_PRESS;
  int a = glfwGetKey(g_window_handle, GLFW_KEY_A) == GLFW_PRESS;
  int s = glfwGetKey(g_window_handle, GLFW_KEY_S) == GLFW_PRESS;
  int d = glfwGetKey(g_window_handle, GLFW_KEY_D) == GLFW_PRESS;
  int space = glfwGetKey(g_window_handle, GLFW_KEY_SPACE) == GLFW_PRESS;

  // Calculate forward/right vectors from yaw/pitch
  float radYaw = g_yaw * kPI / 180.0f;
  float radPitch = g_pitch * kPI / 180.0f;
  float forward[3] = {cosf(radYaw) * cosf(radPitch), sinf(radPitch),
                      sinf(radYaw) * cosf(radPitch)};
  float fl = sqrtf(forward[0] * forward[0] + forward[1] * forward[1] +
                   forward[2] * forward[2]);
  if (fl > 0.0f) {
    forward[0] /= fl;
    forward[1] /= fl;
    forward[2] /= fl;
  }
  float up[3] = {0.0f, 1.0f, 0.0f};
  // Calculate right vector as cross product of forward and up (standard
  // right-handed)
  float right[3] = {forward[1] * up[2] - forward[2] * up[1],
                    forward[2] * up[0] - forward[0] * up[2],
                    forward[0] * up[1] - forward[1] * up[0]};
  float rl =
      sqrtf(right[0] * right[0] + right[1] * right[1] + right[2] * right[2]);
  if (rl > 0.0f) {
    right[0] /= rl;
    right[1] /= rl;
    right[2] /= rl;
  }

  float speed = g_camera_speed * (ctrl ? 4.0f : 1.0f);
  float delta = speed * dt;

  // Error checking for degenerate movement values
  if (!isfinite(speed) || !isfinite(delta)) {
    return; // Invalid movement calculations
  }

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
bool editor_layer_init(CardinalWindow *window, CardinalRenderer *renderer) {
  g_renderer = renderer;
  g_scene_loaded = false;
  memset(&g_scene, 0, sizeof(g_scene));

  // Store window handle for input
  g_window_handle = window ? (GLFWwindow *)window->handle : nullptr;

  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO &io = ImGui::GetIO();
  io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
  io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
  // TODO: Disable multi-viewport for now to avoid Vulkan sync conflicts,
  // implement later io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable;

  setup_imgui_style();
  if (io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) {
    ImGuiStyle &style = ImGui::GetStyle();
    style.WindowRounding = 0.0f;
    style.Colors[ImGuiCol_WindowBg].w = 1.0f;
  }

  if (!ImGui_ImplGlfw_InitForVulkan(window->handle, true)) {
    fprintf(stderr, "ImGui GLFW init failed\n");
    return false;
  }

  // Create descriptor pool for ImGui
  VkDescriptorPoolSize pool_sizes[] = {
      {VK_DESCRIPTOR_TYPE_SAMPLER, 1000},
      {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1000},
      {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1000},
      {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1000},
      {VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1000},
      {VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1000},
      {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1000},
      {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1000},
      {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1000},
      {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1000},
      {VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1000}};
  VkDescriptorPoolCreateInfo pool_info{};
  pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  pool_info.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
  pool_info.maxSets = 1000 * 11;
  pool_info.poolSizeCount = 11;
  pool_info.pPoolSizes = pool_sizes;

  VkDevice device = cardinal_renderer_internal_device(renderer);
  if (vkCreateDescriptorPool(device, &pool_info, NULL, &g_descriptor_pool) !=
      VK_SUCCESS) {
    fprintf(stderr, "Failed to create descriptor pool\n");
    return false;
  }

  ImGui_ImplVulkan_InitInfo init_info{};
  init_info.Instance = cardinal_renderer_internal_instance(renderer);
  init_info.PhysicalDevice =
      cardinal_renderer_internal_physical_device(renderer);
  init_info.Device = device;
  init_info.QueueFamily =
      cardinal_renderer_internal_graphics_queue_family(renderer);
  init_info.Queue = cardinal_renderer_internal_graphics_queue(renderer);
  init_info.DescriptorPool = g_descriptor_pool;
  init_info.MinImageCount =
      cardinal_renderer_internal_swapchain_image_count(renderer);
  init_info.ImageCount =
      cardinal_renderer_internal_swapchain_image_count(renderer);
  init_info.MSAASamples = VK_SAMPLE_COUNT_1_BIT;

  // Dynamic rendering is required; configure ImGui accordingly
  init_info.UseDynamicRendering = true;
  init_info.PipelineRenderingCreateInfo.sType =
      VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
  init_info.PipelineRenderingCreateInfo.pNext = NULL;

  // Get swapchain format for color attachment
  VkFormat colorFormat = cardinal_renderer_internal_swapchain_format(renderer);
  init_info.PipelineRenderingCreateInfo.colorAttachmentCount = 1;
  init_info.PipelineRenderingCreateInfo.pColorAttachmentFormats = &colorFormat;
  init_info.PipelineRenderingCreateInfo.depthAttachmentFormat =
      cardinal_renderer_internal_depth_format(renderer);
  init_info.PipelineRenderingCreateInfo.stencilAttachmentFormat =
      VK_FORMAT_UNDEFINED;

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
// Helper function to recursively draw scene nodes
static void draw_scene_node(CardinalSceneNode* node, int depth = 0) {
  if (!node) return;
  
  // Create a unique ID for ImGui tree node
  char node_id[256];
  snprintf(node_id, sizeof(node_id), "%s##%p", node->name ? node->name : "Unnamed Node", (void*)node);
  
  bool node_open = ImGui::TreeNode(node_id);
  
  // Show node info on the same line
  ImGui::SameLine();
  ImGui::TextDisabled("(meshes: %u, children: %u)", node->mesh_count, node->child_count);
  
  if (node_open) {
    // Show transform information
    if (ImGui::TreeNode("Transform")) {
      ImGui::Text("Local Transform:");
      ImGui::Text("  Translation: (%.2f, %.2f, %.2f)", 
                  node->local_transform[12], node->local_transform[13], node->local_transform[14]);
      
      ImGui::Text("World Transform:");
      ImGui::Text("  Translation: (%.2f, %.2f, %.2f)", 
                  node->world_transform[12], node->world_transform[13], node->world_transform[14]);
      ImGui::TreePop();
    }
    
    // Show attached meshes
    if (node->mesh_count > 0 && ImGui::TreeNode("Meshes")) {
      for (uint32_t i = 0; i < node->mesh_count; ++i) {
        uint32_t mesh_idx = node->mesh_indices[i];
        if (mesh_idx < g_scene.mesh_count) {
          const CardinalMesh &m = g_scene.meshes[mesh_idx];
          ImGui::BulletText("Mesh %u: %u vertices, %u indices", mesh_idx,
                            (unsigned)m.vertex_count, (unsigned)m.index_count);
        }
      }
      ImGui::TreePop();
    }
    
    // Recursively draw child nodes
    for (uint32_t i = 0; i < node->child_count; ++i) {
      draw_scene_node(node->children[i], depth + 1);
    }
    
    ImGui::TreePop();
  }
}

static void draw_scene_graph_panel() {
  if (ImGui::Begin("Scene Graph")) {
    if (ImGui::TreeNode("Scene")) {
      ImGui::BulletText("Camera");
      ImGui::BulletText("Directional Light");
      
      if (g_scene_loaded) {
        if (ImGui::TreeNode("Loaded Scene")) {
          ImGui::Text("Total Meshes: %u", (unsigned)g_scene.mesh_count);
          ImGui::Text("Root Nodes: %u", (unsigned)g_scene.root_node_count);
          
          // Display hierarchical scene nodes
          if (g_scene.root_node_count > 0) {
            ImGui::Separator();
            for (uint32_t i = 0; i < g_scene.root_node_count; ++i) {
              draw_scene_node(g_scene.root_nodes[i]);
            }
          } else {
            // Fallback to old mesh display if no hierarchy
            ImGui::Text("No scene hierarchy - showing flat mesh list:");
            for (uint32_t i = 0; i < g_scene.mesh_count; ++i) {
              const CardinalMesh &m = g_scene.meshes[i];
              ImGui::BulletText("Mesh %u: %u vertices, %u indices", (unsigned)i,
                                (unsigned)m.vertex_count, (unsigned)m.index_count);
            }
          }
          
          ImGui::TreePop();
        }
      }
      
      ImGui::TreePop();
    }
  }
  ImGui::End();
}

/**
 * @brief Draws the asset browser panel.
 *
 * Displays assets list with subdirectory navigation, search, filtering, and file icons.
 * Supports loading scenes and browsing through directory structure.
 */
static void draw_asset_browser_panel() {
  if (ImGui::Begin("Assets")) {
    ImGui::Text("Project Assets");
    ImGui::Separator();

    // Assets directory controls
    ImGui::Text("Assets Root:");
    ImGui::SetNextItemWidth(-FLT_MIN);
    if (ImGui::InputTextWithHint("##assets_dir",
                                 "Relative or absolute path to assets folder",
                                 g_assets_dir, sizeof(g_assets_dir))) {
      // Update current directory to match new root
      strncpy(g_current_dir, g_assets_dir, sizeof(g_current_dir) - 1);
      g_current_dir[sizeof(g_current_dir) - 1] = '\0';
      scan_assets_dir();
    }
    if (ImGui::Button("Refresh")) {
      scan_assets_dir();
    }
    
    // Current directory display
    ImGui::Text("Current: %s", g_current_dir);
    
    ImGui::Separator();
    
    // Search and filter controls
    ImGui::Text("Search & Filter:");
    ImGui::SetNextItemWidth(-FLT_MIN);
    if (ImGui::InputTextWithHint("##search_filter", "Search files...",
                                 g_search_filter, sizeof(g_search_filter))) {
      scan_assets_dir(); // Re-apply filters
    }
    
    // Filter checkboxes
    bool filter_changed = false;
    if (ImGui::Checkbox("Folders Only", &g_show_folders_only)) filter_changed = true;
    ImGui::SameLine();
    if (ImGui::Checkbox("glTF/GLB", &g_show_gltf_only)) filter_changed = true;
    ImGui::SameLine();
    if (ImGui::Checkbox("Textures", &g_show_textures_only)) filter_changed = true;
    
    if (filter_changed) {
      scan_assets_dir(); // Re-apply filters
    }
    
    if (ImGui::Button("Clear Filters")) {
      g_search_filter[0] = '\0';
      g_show_folders_only = false;
      g_show_gltf_only = false;
      g_show_textures_only = false;
      scan_assets_dir();
    }

    ImGui::Separator();

    // Simple scene load controls
    ImGui::Text("Load Scene (glTF/glb)");
    ImGui::SetNextItemWidth(-FLT_MIN);
    ImGui::InputTextWithHint("##scene_path", "C:/path/to/scene.gltf or .glb",
                             g_scene_path, sizeof(g_scene_path));
    if (ImGui::Button("Load")) {
      load_scene_from_path(g_scene_path);
    }

    // Show loading indicator if async loading is in progress
    if (g_is_loading) {
      ImGui::SameLine();
      // Simple spinner animation
      static float spinner_time = 0.0f;
      spinner_time += ImGui::GetIO().DeltaTime;
      const char *spinner_chars = "|/-\\";
      int spinner_index = (int)(spinner_time * 4.0f) % 4;
      ImGui::Text("%c Loading...", spinner_chars[spinner_index]);
    }

    if (g_status_msg[0] != '\0') {
      ImGui::TextWrapped("%s", g_status_msg);
    }

    ImGui::Separator();

    // Dynamic assets list with icons and navigation
    const auto& entries_to_show = g_filtered_entries.empty() ? g_asset_entries : g_filtered_entries;
    
    if (entries_to_show.empty()) {
      ImGui::TextDisabled("No assets found in '%s'", g_current_dir);
    } else {
      if (ImGui::BeginChild("##assets_list", ImVec2(0, 0), true)) {
        for (const auto &e : entries_to_show) {
          // Display icon and name
          ImGui::Text("%s", get_asset_icon(e.type));
          ImGui::SameLine();
          
          if (ImGui::Selectable(e.display.c_str())) {
            if (e.is_directory) {
              // Navigate to directory
              if (e.display == "..") {
                // Go to parent directory
                strncpy(g_current_dir, e.fullPath.c_str(), sizeof(g_current_dir) - 1);
                g_current_dir[sizeof(g_current_dir) - 1] = '\0';
              } else {
                // Enter subdirectory
                strncpy(g_current_dir, e.fullPath.c_str(), sizeof(g_current_dir) - 1);
                g_current_dir[sizeof(g_current_dir) - 1] = '\0';
              }
              scan_assets_dir();
            } else {
              // Select file for loading
              snprintf(g_scene_path, sizeof(g_scene_path), "%s", e.fullPath.c_str());
              // Auto-load glTF/GLB files
              if (e.type == ASSET_TYPE_GLTF || e.type == ASSET_TYPE_GLB) {
                load_scene_from_path(e.fullPath.c_str());
              }
            }
          }
          
          // Double-click support for files
          if (!e.is_directory && ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(0)) {
            if (e.type == ASSET_TYPE_GLTF || e.type == ASSET_TYPE_GLB) {
              load_scene_from_path(e.fullPath.c_str());
            }
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

      camera_changed |=
          ImGui::SliderFloat3("Position", g_camera.position, -10.0f, 10.0f);
      camera_changed |=
          ImGui::SliderFloat3("Target", g_camera.target, -10.0f, 10.0f);
      camera_changed |= ImGui::SliderFloat("FOV", &g_camera.fov, 10.0f, 120.0f);
      camera_changed |=
          ImGui::SliderFloat("Aspect Ratio", &g_camera.aspect, 0.5f, 3.0f);
      camera_changed |=
          ImGui::SliderFloat("Near Plane", &g_camera.near_plane, 0.01f, 1.0f);
      camera_changed |=
          ImGui::SliderFloat("Far Plane", &g_camera.far_plane, 10.0f, 1000.0f);

      if (camera_changed && g_pbr_enabled && g_renderer) {
        cardinal_renderer_set_camera(g_renderer, &g_camera);
      }
    }

    ImGui::Separator();

    // Lighting Settings
    if (ImGui::CollapsingHeader("Lighting", ImGuiTreeNodeFlags_DefaultOpen)) {
      bool light_changed = false;

      light_changed |=
          ImGui::SliderFloat3("Direction", g_light.direction, -1.0f, 1.0f);
      light_changed |= ImGui::ColorEdit3("Color", g_light.color);
      light_changed |=
          ImGui::SliderFloat("Intensity", &g_light.intensity, 0.0f, 10.0f);
      light_changed |= ImGui::ColorEdit3("Ambient", g_light.ambient);

      if (light_changed && g_pbr_enabled && g_renderer) {
        cardinal_renderer_set_lighting(g_renderer, &g_light);
        printf(
            "Lighting updated: dir=[%.3f,%.3f,%.3f], color=[%.3f,%.3f,%.3f], "
            "intensity=%.3f, ambient=[%.3f,%.3f,%.3f]\n",
            g_light.direction[0], g_light.direction[1], g_light.direction[2],
            g_light.color[0], g_light.color[1], g_light.color[2],
            g_light.intensity, g_light.ambient[0], g_light.ambient[1],
            g_light.ambient[2]);
      }
    }

    ImGui::Separator();

    // Material Settings
    if (ImGui::CollapsingHeader("Material Override",
                                ImGuiTreeNodeFlags_DefaultOpen)) {
      ImGui::Checkbox("Enable Material Override", &g_material_override_enabled);

      if (g_material_override_enabled) {
        ImGui::Separator();
        ImGui::ColorEdit3("Albedo Factor", g_material_albedo);
        ImGui::SliderFloat("Metallic Factor", &g_material_metallic, 0.0f, 1.0f);
        ImGui::SliderFloat("Roughness Factor", &g_material_roughness, 0.0f,
                           1.0f);
        ImGui::ColorEdit3("Emissive Factor", g_material_emissive);
        ImGui::SliderFloat("Normal Scale", &g_material_normal_scale, 0.0f,
                           2.0f);
        ImGui::SliderFloat("AO Strength", &g_material_ao_strength, 0.0f, 1.0f);

        if (ImGui::Button("Apply to All Materials")) {
          if (g_scene_loaded && g_scene.material_count > 0) {
            // Apply override values to all materials in the scene
            for (uint32_t i = 0; i < g_scene.material_count; i++) {
              CardinalMaterial *mat = &g_scene.materials[i];

              // Store original values for logging
              float orig_albedo[3] = {mat->albedo_factor[0],
                                      mat->albedo_factor[1],
                                      mat->albedo_factor[2]};
              float orig_metallic = mat->metallic_factor;
              float orig_roughness = mat->roughness_factor;

              // Apply albedo factor
              mat->albedo_factor[0] = g_material_albedo[0];
              mat->albedo_factor[1] = g_material_albedo[1];
              mat->albedo_factor[2] = g_material_albedo[2];

              // Apply other factors
              mat->metallic_factor = g_material_metallic;
              mat->roughness_factor = g_material_roughness;
              mat->emissive_factor[0] = g_material_emissive[0];
              mat->emissive_factor[1] = g_material_emissive[1];
              mat->emissive_factor[2] = g_material_emissive[2];
              mat->normal_scale = g_material_normal_scale;
              mat->ao_strength = g_material_ao_strength;

              // Debug logging
              printf("Material %u: albedo [%.3f,%.3f,%.3f]->[%.3f,%.3f,%.3f], "
                     "metallic %.3f->%.3f, roughness %.3f->%.3f\n",
                     i, orig_albedo[0], orig_albedo[1], orig_albedo[2],
                     mat->albedo_factor[0], mat->albedo_factor[1],
                     mat->albedo_factor[2], orig_metallic, mat->metallic_factor,
                     orig_roughness, mat->roughness_factor);
            }

            // Re-upload the scene to apply changes
            if (g_renderer) {
              cardinal_renderer_upload_scene(g_renderer, &g_scene);
              printf("Scene re-uploaded to renderer\n");
            }

            snprintf(g_status_msg, sizeof(g_status_msg),
                     "Applied material override to %u materials",
                     g_scene.material_count);
          } else {
            snprintf(g_status_msg, sizeof(g_status_msg),
                     "No scene loaded or no materials to modify");
          }
        }
      }
    }

    ImGui::Separator();

    // Status
    if (g_renderer) {
      bool is_pbr_active = cardinal_renderer_is_pbr_enabled(g_renderer);
      ImGui::Text("PBR Status: %s", is_pbr_active ? "Active" : "Inactive");
    }

    ImGui::Separator();

    // Rendering Mode Settings
    if (ImGui::CollapsingHeader("Rendering Mode",
                                ImGuiTreeNodeFlags_DefaultOpen)) {
      if (g_renderer) {
        CardinalRenderingMode current_mode =
            cardinal_renderer_get_rendering_mode(g_renderer);
        const char *mode_names[] = {"Normal", "UV Visualization", "Wireframe"};
        int current_item = (int)current_mode;

        if (ImGui::Combo("Mode", &current_item, mode_names, 3)) {
          CardinalRenderingMode new_mode = (CardinalRenderingMode)current_item;
          cardinal_renderer_set_rendering_mode(g_renderer, new_mode);
        }

        // Display mode description
        switch (current_mode) {
        case CARDINAL_RENDERING_MODE_NORMAL:
          ImGui::TextWrapped(
              "Normal rendering with full PBR shading and materials.");
          break;
        case CARDINAL_RENDERING_MODE_UV:
          ImGui::TextWrapped(
              "UV coordinate visualization. Red = U axis, Green = V axis.");
          break;
        case CARDINAL_RENDERING_MODE_WIREFRAME:
          ImGui::TextWrapped("Wireframe rendering showing mesh topology.");
          break;
        }
      } else {
        ImGui::Text("Renderer not available");
      }
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
  ImDrawData *dd = ImGui::GetDrawData();
  ImGui_ImplVulkan_RenderDrawData(dd, cmd);
}

void editor_layer_update(void) {
  // Process completed async tasks to execute callbacks
  cardinal_async_process_completed_tasks(0);
  
  // Process async loading tasks
  if (g_loading_task && g_is_loading) {
    CardinalAsyncStatus status = cardinal_async_get_task_status(g_loading_task);
    if (status == CARDINAL_ASYNC_STATUS_COMPLETED ||
        status == CARDINAL_ASYNC_STATUS_FAILED) {
      // Task is done, callback has already been called
      cardinal_async_free_task(g_loading_task);
      g_loading_task = nullptr;
      g_is_loading = false;
    }
  }

  // Toggle mouse capture with Tab (edge detection)
  bool tab_down = g_window_handle &&
                  (glfwGetKey(g_window_handle, GLFW_KEY_TAB) == GLFW_PRESS);
  if (tab_down && !g_tab_pressed_last_frame) {
    set_mouse_capture(!g_mouse_captured);
  }
  g_tab_pressed_last_frame = tab_down;

  ImGuiIO &io = ImGui::GetIO();
  float dt = io.DeltaTime > 0.0f ? io.DeltaTime : 1.0f / 60.0f;

  if (g_mouse_captured) {
    io.WantCaptureMouse = false;
    io.WantCaptureKeyboard = false;
  }

  process_input_and_move_camera(dt);

  // Keep camera aspect synced with the window/swapchain size since the scene
  // renders in the background
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

  ImGuiWindowFlags window_flags =
      ImGuiWindowFlags_MenuBar | ImGuiWindowFlags_NoTitleBar |
      ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoResize |
      ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoBringToFrontOnFocus |
      ImGuiWindowFlags_NoNavFocus | ImGuiWindowFlags_NoDocking |
      ImGuiWindowFlags_NoBackground;

  const ImGuiViewport *viewport = ImGui::GetMainViewport();
  ImGui::SetNextWindowPos(viewport->WorkPos);
  ImGui::SetNextWindowSize(viewport->WorkSize);

  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
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
  ImGuiIO &io = ImGui::GetIO();
  if ((io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) != 0) {
    ImGui::UpdatePlatformWindows();
    ImGui::RenderPlatformWindowsDefault();
  }
}

void editor_layer_shutdown(void) {
  VkDevice device = VK_NULL_HANDLE;
  if (g_renderer) {
    cardinal_renderer_set_ui_callback(g_renderer, NULL);
    // Wait for device idle before cleanup to avoid destroying resources in use
    cardinal_renderer_wait_idle(g_renderer);
    // Get device handle before ImGui shutdown
    device = cardinal_renderer_internal_device(g_renderer);
  }
  if (g_scene_loaded) {
    cardinal_scene_destroy(&g_scene);
    memset(&g_scene, 0, sizeof(g_scene));
    g_scene_loaded = false;
  }
  ImGui_ImplVulkan_Shutdown();
  ImGui_ImplGlfw_Shutdown();
  if (g_descriptor_pool != VK_NULL_HANDLE && device != VK_NULL_HANDLE) {
    vkDestroyDescriptorPool(device, g_descriptor_pool, NULL);
    g_descriptor_pool = VK_NULL_HANDLE;
  }
  ImGui::DestroyContext();
}
