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
#include <cardinal/assets/model_manager.h>
#include <cardinal/assets/scene.h>
#include <cardinal/cardinal.h>
#include <cardinal/core/async_loader.h>
#include <cardinal/core/log.h>
#include <cardinal/core/transform.h>
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
static CardinalModelManager
    g_model_manager;                   // Model manager for multiple models
static CardinalScene g_combined_scene; // Combined scene from model manager
static char g_scene_path[512] = "";
static char g_status_msg[256] = "";
static uint32_t g_selected_model_id = 0; // Currently selected model

// Scene upload synchronization
static bool g_scene_upload_pending = false;
static CardinalScene g_pending_scene; // Scene waiting to be uploaded

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
static char g_assets_dir[512] = "C:/Users/admin/Documents/Cardinal/assets";
static char g_current_dir[512] =
    "C:/Users/admin/Documents/Cardinal/assets"; // Current browsing directory
static char g_search_filter[256] = "";          // Search filter text
static bool g_show_folders_only = false;
static bool g_show_gltf_only = false;
static bool g_show_textures_only = false;

// Animation system state
static int g_selected_animation = -1;
static float g_animation_time = 0.0f;
static bool g_animation_playing = false;
static bool g_animation_looping = true;
static float g_animation_speed = 1.0f;
static float g_timeline_zoom = 1.0f;

enum AssetType {
  ASSET_TYPE_FOLDER,
  ASSET_TYPE_GLTF,
  ASSET_TYPE_GLB,
  ASSET_TYPE_TEXTURE,
  ASSET_TYPE_OTHER
};

struct AssetEntry {
  std::string display;      // label shown in UI (filename or folder name)
  std::string fullPath;     // full path used for loading/navigation
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
      // Extract filename for model name
      const char *filename = strrchr(path, '/');
      if (!filename)
        filename = strrchr(path, '\\');
      if (!filename)
        filename = path;
      else
        filename++; // Skip the separator

      // Add the already-loaded scene to the model manager (avoids
      // double-loading)
      uint32_t model_id = cardinal_model_manager_add_scene(
          &g_model_manager, &loaded_scene, path, filename);
      if (model_id != 0) {
        g_selected_model_id = model_id;

        // Get the combined scene and upload to GPU
        const CardinalScene *combined =
            cardinal_model_manager_get_combined_scene(&g_model_manager);
        if (combined) {
          g_combined_scene = *combined; // Copy the scene
          g_scene_loaded = true;

          // Defer upload to avoid racing with in-flight command buffers
          if (g_renderer) {
            g_pending_scene = *combined;
            g_scene_upload_pending = true;
            CARDINAL_LOG_INFO("[EDITOR] Deferred scene upload scheduled");
          }

          snprintf(g_status_msg, sizeof(g_status_msg),
                   "Loaded model: %u mesh(es) from %s (ID: %u)",
                   (unsigned)loaded_scene.mesh_count, filename, model_id);
        } else {
          snprintf(g_status_msg, sizeof(g_status_msg),
                   "Model loaded but failed to get combined scene: %s",
                   filename);
        }
      } else {
        snprintf(g_status_msg, sizeof(g_status_msg),
                 "Failed to add model to manager: %s", filename);
      }
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

  // Check if file exists and get its size
  try {
    if (!fs::exists(path)) {
      snprintf(g_status_msg, sizeof(g_status_msg), "File does not exist: %s",
               path);
      return;
    }

    std::error_code ec;
    auto file_size = fs::file_size(path, ec);
    if (ec) {
      snprintf(g_status_msg, sizeof(g_status_msg), "Cannot access file: %s",
               path);
      return;
    }

    // Warn about very large files (over 500MB)
    if (file_size > 524288000) {
      snprintf(g_status_msg, sizeof(g_status_msg),
               "Warning: Large file (%.1f MB), loading may take time: %s",
               file_size / 1048576.0, path);
    }

    // Refuse to load files over 1GB
    if (file_size > 1073741824) {
      snprintf(g_status_msg, sizeof(g_status_msg),
               "File too large (%.1f GB), refusing to load: %s",
               file_size / 1073741824.0, path);
      return;
    }
  } catch (...) {
    snprintf(g_status_msg, sizeof(g_status_msg), "Error checking file: %s",
             path);
    return;
  }

  // Prevent multiple simultaneous loads to avoid race conditions
  // TODO: Obviously want multiple models to be loadable simultaneously but not
  // the same one at the same time.
  if (g_is_loading) {
    snprintf(g_status_msg, sizeof(g_status_msg),
             "Already loading a scene, please wait...");
    return;
  }

  // Cancel any existing loading task
  if (g_loading_task) {
    cardinal_async_cancel_task(g_loading_task);
    cardinal_async_free_task(g_loading_task);
    g_loading_task = nullptr;
    g_is_loading = false;
  }

  // Note: No need to clear scene - model manager handles multiple models

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
    // Synchronous loading not supported with model manager
    snprintf(g_status_msg, sizeof(g_status_msg), "Async loading failed for: %s",
             path);
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
static AssetType get_asset_type(const std::string &path) {
  std::string lower = path;
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](unsigned char c) { return (char)std::tolower(c); });

  if (lower.size() >= 5 && lower.compare(lower.size() - 5, 5, ".gltf") == 0) {
    return ASSET_TYPE_GLTF;
  }
  if (lower.size() >= 4 && lower.compare(lower.size() - 4, 4, ".glb") == 0) {
    return ASSET_TYPE_GLB;
  }
  if (lower.size() >= 4 && (lower.compare(lower.size() - 4, 4, ".png") == 0 ||
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
static const char *get_asset_icon(AssetType type) {
  switch (type) {
  case ASSET_TYPE_FOLDER:
    return "📁";
  case ASSET_TYPE_GLTF:
  case ASSET_TYPE_GLB:
    return "🧊";
  case ASSET_TYPE_TEXTURE:
    return "🖼️";
  default:
    return "📄";
  }
}

/**
 * @brief Checks if an entry matches the current search filter.
 */
static bool matches_filter(const AssetEntry &entry) {
  // Text search filter
  if (strlen(g_search_filter) > 0) {
    std::string lower_display = entry.display;
    std::string lower_filter = g_search_filter;
    std::transform(lower_display.begin(), lower_display.end(),
                   lower_display.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    std::transform(lower_filter.begin(), lower_filter.end(),
                   lower_filter.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    if (lower_display.find(lower_filter) == std::string::npos) {
      return false;
    }
  }

  // Type filters
  if (g_show_folders_only && entry.type != ASSET_TYPE_FOLDER)
    return false;
  if (g_show_gltf_only && entry.type != ASSET_TYPE_GLTF &&
      entry.type != ASSET_TYPE_GLB)
    return false;
  if (g_show_textures_only && entry.type != ASSET_TYPE_TEXTURE)
    return false;

  return true;
}

/**
 * @brief Scans the current directory and populates the asset entries list.
 *
 * Scans only the current directory (non-recursive) and categorizes files and
 * folders. Supports subdirectory navigation, file type icons, and filtering.
 */
static void scan_assets_dir() {
  CARDINAL_LOG_INFO("Starting asset directory scan for: %s", g_current_dir);
  g_asset_entries.clear();
  g_filtered_entries.clear();

  try {
    fs::path current_path = fs::path(g_current_dir);
    fs::path assets_root = fs::path(g_assets_dir);

    CARDINAL_LOG_DEBUG("Current path: %s, Assets root: %s",
                       current_path.string().c_str(),
                       assets_root.string().c_str());

    if (!current_path.empty() && fs::exists(current_path) &&
        fs::is_directory(current_path)) {
      CARDINAL_LOG_DEBUG("Path exists and is directory, proceeding with scan");

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
        CARDINAL_LOG_DEBUG("Added parent directory entry: %s",
                           parent_str.c_str());
      }

      // Scan current directory (non-recursive)
      CARDINAL_LOG_DEBUG("Starting directory iteration");
      size_t entry_count = 0;
      for (auto const &it : fs::directory_iterator(current_path)) {
        try {
          entry_count++;
          AssetEntry entry;
          entry.fullPath = it.path().string();
          std::replace(entry.fullPath.begin(), entry.fullPath.end(), '\\', '/');
          entry.display = it.path().filename().string();

          CARDINAL_LOG_DEBUG("Processing entry #%zu: %s (full: %s)",
                             entry_count, entry.display.c_str(),
                             entry.fullPath.c_str());

          // Calculate relative path from assets root
          try {
            fs::path rel = fs::relative(it.path(), assets_root);
            entry.relativePath = rel.generic_string();
            CARDINAL_LOG_DEBUG("Relative path: %s", entry.relativePath.c_str());
          } catch (const std::exception &e) {
            CARDINAL_LOG_WARN("Failed to calculate relative path for %s: %s",
                              entry.display.c_str(), e.what());
            entry.relativePath = entry.display;
          } catch (...) {
            CARDINAL_LOG_WARN("Unknown error calculating relative path for %s",
                              entry.display.c_str());
            entry.relativePath = entry.display;
          }

          if (it.is_directory()) {
            entry.type = ASSET_TYPE_FOLDER;
            entry.is_directory = true;
            CARDINAL_LOG_DEBUG("Entry is directory: %s", entry.display.c_str());
          } else if (it.is_regular_file()) {
            entry.type = get_asset_type(entry.fullPath);
            entry.is_directory = false;
            CARDINAL_LOG_DEBUG("Entry is file: %s (type: %d)",
                               entry.display.c_str(), entry.type);
          } else {
            CARDINAL_LOG_DEBUG("Skipping special file: %s",
                               entry.display.c_str());
            continue; // Skip special files
          }

          g_asset_entries.push_back(entry);
          CARDINAL_LOG_DEBUG("Successfully added entry: %s",
                             entry.display.c_str());
        } catch (const std::exception &e) {
          CARDINAL_LOG_ERROR("Exception processing entry #%zu (%s): %s",
                             entry_count, it.path().filename().string().c_str(),
                             e.what());
          continue;
        } catch (...) {
          CARDINAL_LOG_ERROR("Unknown exception processing entry #%zu (%s)",
                             entry_count,
                             it.path().filename().string().c_str());
          continue;
        }
      }

      CARDINAL_LOG_INFO("Found %zu entries before sorting and filtering",
                        g_asset_entries.size());

      // Sort entries: directories first, then files, alphabetically within each
      // group
      std::sort(g_asset_entries.begin(), g_asset_entries.end(),
                [](const AssetEntry &a, const AssetEntry &b) {
                  if (a.display == "..")
                    return true;
                  if (b.display == "..")
                    return false;
                  if (a.is_directory != b.is_directory) {
                    return a.is_directory > b.is_directory;
                  }
                  return a.display < b.display;
                });

      CARDINAL_LOG_DEBUG("Entries sorted, applying filters");

      // Apply filters
      for (const auto &entry : g_asset_entries) {
        if (matches_filter(entry)) {
          g_filtered_entries.push_back(entry);
        }
      }

      CARDINAL_LOG_INFO(
          "Asset scan completed: %zu total entries, %zu after filtering",
          g_asset_entries.size(), g_filtered_entries.size());
    } else {
      CARDINAL_LOG_ERROR(
          "Current path is invalid: empty=%d, exists=%d, is_directory=%d",
          current_path.empty(), fs::exists(current_path),
          fs::is_directory(current_path));
    }
  } catch (const std::exception &e) {
    CARDINAL_LOG_ERROR("Exception during asset directory scan: %s", e.what());
  } catch (...) {
    CARDINAL_LOG_ERROR("Unknown exception during asset directory scan");
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
 * @brief Process pending scene uploads safely after frame rendering is complete
 */
void editor_layer_process_pending_uploads() {
  if (g_scene_upload_pending && g_renderer) {
    CARDINAL_LOG_INFO(
        "[EDITOR] Pending upload detected; waiting for device idle");
    // Wait for any pending GPU work to complete before uploading scene
    cardinal_renderer_wait_idle(g_renderer);
    CARDINAL_LOG_DEBUG("[EDITOR] Device idle; uploading pending scene");

    // Now it's safe to upload the scene
    cardinal_renderer_upload_scene(g_renderer, &g_pending_scene);
    g_combined_scene = g_pending_scene; // Update our local copy

    // Update camera and lighting after scene upload
    if (g_pbr_enabled) {
      cardinal_renderer_set_camera(g_renderer, &g_camera);
      cardinal_renderer_set_lighting(g_renderer, &g_light);
    }

    g_scene_upload_pending = false;
    CARDINAL_LOG_INFO("[EDITOR] Deferred scene upload completed");
  }
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
  memset(&g_combined_scene, 0, sizeof(g_combined_scene));

  // Initialize model manager
  cardinal_model_manager_init(&g_model_manager);

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
  // Set API version for ImGui Vulkan backend
  init_info.ApiVersion = VK_API_VERSION_1_3;
  // Configure pipeline info for main viewport
  init_info.PipelineInfoMain.MSAASamples = VK_SAMPLE_COUNT_1_BIT;

  // Dynamic rendering is required; configure ImGui accordingly
  init_info.UseDynamicRendering = true;
  init_info.PipelineInfoMain.PipelineRenderingCreateInfo.sType =
      VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
  init_info.PipelineInfoMain.PipelineRenderingCreateInfo.pNext = NULL;

  // Get swapchain format for color attachment
  VkFormat colorFormat = cardinal_renderer_internal_swapchain_format(renderer);
  init_info.PipelineInfoMain.PipelineRenderingCreateInfo.colorAttachmentCount =
      1;
  init_info.PipelineInfoMain.PipelineRenderingCreateInfo
      .pColorAttachmentFormats = &colorFormat;
  init_info.PipelineInfoMain.PipelineRenderingCreateInfo.depthAttachmentFormat =
      cardinal_renderer_internal_depth_format(renderer);
  init_info.PipelineInfoMain.PipelineRenderingCreateInfo
      .stencilAttachmentFormat = VK_FORMAT_UNDEFINED;

  // No render pass when using dynamic rendering
  init_info.PipelineInfoMain.RenderPass = VK_NULL_HANDLE;

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
 * @brief Draws the animation controls panel with timeline and playback
 * controls.
 *
 * Displays available animations, playback controls, timeline scrubbing,
 * and animation properties for the currently loaded scene.
 */
static void draw_animation_panel() {
  if (ImGui::Begin("Animation")) {
    if (!g_scene_loaded || !g_combined_scene.animation_system ||
        g_combined_scene.animation_system->animation_count == 0) {
      ImGui::TextDisabled("No animations available");
      ImGui::TextWrapped(
          "Load a scene with animations to see animation controls.");
      ImGui::End();
      return;
    }

    CardinalAnimationSystem *anim_sys = g_combined_scene.animation_system;

    // Animation selection
    ImGui::Text("Animations (%u)", anim_sys->animation_count);
    ImGui::Separator();

    // Animation list
    if (ImGui::BeginChild("##animation_list", ImVec2(0, 120), true)) {
      for (uint32_t i = 0; i < anim_sys->animation_count; ++i) {
        CardinalAnimation *anim = &anim_sys->animations[i];
        const char *name = anim->name ? anim->name : "Unnamed Animation";

        bool is_selected = (g_selected_animation == (int)i);
        if (ImGui::Selectable(name, is_selected)) {
          g_selected_animation = (int)i;
          g_animation_time = 0.0f; // Reset time when switching animations
        }

        // Show animation info
        ImGui::SameLine();
        ImGui::TextDisabled("(%.2fs, %u channels)", anim->duration,
                            anim->channel_count);
      }
    }
    ImGui::EndChild();

    ImGui::Separator();

    // Playback controls
    if (g_selected_animation >= 0 &&
        g_selected_animation < (int)anim_sys->animation_count) {
      CardinalAnimation *current_anim =
          &anim_sys->animations[g_selected_animation];

      ImGui::Text("Playback Controls");

      // Play/Pause button
      if (g_animation_playing) {
        if (ImGui::Button("Pause")) {
          g_animation_playing = false;
          cardinal_animation_pause(anim_sys, g_selected_animation);
        }
      } else {
        if (ImGui::Button("Play")) {
          g_animation_playing = true;
          cardinal_animation_play(anim_sys, g_selected_animation,
                                  g_animation_looping, 1.0f);
        }
      }

      ImGui::SameLine();
      if (ImGui::Button("Stop")) {
        g_animation_playing = false;
        g_animation_time = 0.0f;
        cardinal_animation_stop(anim_sys, g_selected_animation);
      }

      ImGui::SameLine();
      if (ImGui::Checkbox("Loop", &g_animation_looping)) {
        // Update looping state if animation is playing
        if (g_animation_playing) {
          cardinal_animation_play(anim_sys, g_selected_animation,
                                  g_animation_looping, 1.0f);
        }
      }

      // Speed control
      ImGui::SetNextItemWidth(100);
      if (ImGui::SliderFloat("Speed", &g_animation_speed, 0.1f, 3.0f,
                             "%.1fx")) {
        cardinal_animation_set_speed(anim_sys, g_selected_animation,
                                     g_animation_speed);
      }

      // Timeline
      ImGui::Separator();
      ImGui::Text("Timeline");

      // Time display
      ImGui::Text("Time: %.2f / %.2f seconds", g_animation_time,
                  current_anim->duration);

      // Timeline scrubber
      float timeline_width = ImGui::GetContentRegionAvail().x - 20;
      ImGui::SetNextItemWidth(timeline_width);
      if (ImGui::SliderFloat("##timeline", &g_animation_time, 0.0f,
                             current_anim->duration, "%.2fs")) {
        // User is scrubbing the timeline
        if (g_animation_time < 0.0f)
          g_animation_time = 0.0f;
        if (g_animation_time > current_anim->duration) {
          if (g_animation_looping) {
            g_animation_time = fmodf(g_animation_time, current_anim->duration);
          } else {
            g_animation_time = current_anim->duration;
            g_animation_playing = false;
          }
        }
      }

      // Update animation time during playback
      if (g_animation_playing) {
        ImGuiIO &io = ImGui::GetIO();
        g_animation_time += io.DeltaTime * g_animation_speed;

        if (g_animation_time >= current_anim->duration) {
          if (g_animation_looping) {
            g_animation_time = fmodf(g_animation_time, current_anim->duration);
          } else {
            g_animation_time = current_anim->duration;
            g_animation_playing = false;
          }
        }
      }

      // Animation info
      ImGui::Separator();
      ImGui::Text("Animation Info");
      ImGui::Text("Name: %s",
                  current_anim->name ? current_anim->name : "Unnamed");
      ImGui::Text("Duration: %.2f seconds", current_anim->duration);
      ImGui::Text("Channels: %u", current_anim->channel_count);
      ImGui::Text("Samplers: %u", current_anim->sampler_count);

      // Channel details (collapsible)
      if (ImGui::CollapsingHeader("Channels")) {
        for (uint32_t i = 0; i < current_anim->channel_count; ++i) {
          CardinalAnimationChannel *channel = &current_anim->channels[i];
          ImGui::Text("Channel %u: Node %u, Target %d", i,
                      channel->target.node_index, (int)channel->target.path);
        }
      }
    } else {
      ImGui::TextDisabled("Select an animation to see controls");
    }
  }
  ImGui::End();
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
static void draw_scene_node(CardinalSceneNode *node, int depth = 0) {
  if (!node)
    return;

  // Create a unique ID for ImGui tree node
  char node_id[256];
  snprintf(node_id, sizeof(node_id), "%s##%p",
           node->name ? node->name : "Unnamed Node", (void *)node);

  bool node_open = ImGui::TreeNode(node_id);

  // Show node info on the same line
  ImGui::SameLine();
  ImGui::TextDisabled("(meshes: %u, children: %u)", node->mesh_count,
                      node->child_count);

  if (node_open) {
    // Show transform information
    if (ImGui::TreeNode("Transform")) {
      ImGui::Text("Local Transform:");
      ImGui::Text("  Translation: (%.2f, %.2f, %.2f)",
                  node->local_transform[12], node->local_transform[13],
                  node->local_transform[14]);

      ImGui::Text("World Transform:");
      ImGui::Text("  Translation: (%.2f, %.2f, %.2f)",
                  node->world_transform[12], node->world_transform[13],
                  node->world_transform[14]);
      ImGui::TreePop();
    }

    // Show attached meshes
    if (node->mesh_count > 0 && ImGui::TreeNode("Meshes")) {
      for (uint32_t i = 0; i < node->mesh_count; ++i) {
        uint32_t mesh_idx = node->mesh_indices[i];
        if (mesh_idx < g_combined_scene.mesh_count) {
          CardinalMesh &m = g_combined_scene.meshes[mesh_idx];

          // Create unique ID for the checkbox
          char checkbox_id[64];
          snprintf(checkbox_id, sizeof(checkbox_id), "Visible##mesh_%u",
                   mesh_idx);

          // Visibility checkbox
          ImGui::Checkbox(checkbox_id, &m.visible);
          ImGui::SameLine();

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
          ImGui::Text("Total Meshes: %u",
                      (unsigned)g_combined_scene.mesh_count);
          ImGui::Text("Root Nodes: %u",
                      (unsigned)g_combined_scene.root_node_count);

          // Bulk visibility controls
          ImGui::Separator();
          ImGui::Text("Bulk Visibility Controls:");

          if (ImGui::Button("Show All Meshes")) {
            for (uint32_t i = 0; i < g_combined_scene.mesh_count; ++i) {
              g_combined_scene.meshes[i].visible = true;
            }
          }
          ImGui::SameLine();
          if (ImGui::Button("Hide All Meshes")) {
            for (uint32_t i = 0; i < g_combined_scene.mesh_count; ++i) {
              g_combined_scene.meshes[i].visible = false;
            }
          }

          // Material-based visibility controls
          if (ImGui::Button("Show Only Material 0")) {
            for (uint32_t i = 0; i < g_combined_scene.mesh_count; ++i) {
              g_combined_scene.meshes[i].visible =
                  (g_combined_scene.meshes[i].material_index == 0);
            }
          }
          ImGui::SameLine();
          if (ImGui::Button("Show Only Material 1")) {
            for (uint32_t i = 0; i < g_combined_scene.mesh_count; ++i) {
              g_combined_scene.meshes[i].visible =
                  (g_combined_scene.meshes[i].material_index == 1);
            }
          }

          // Toggle between materials
          if (ImGui::Button("Toggle Materials 0/1")) {
            static bool show_material_0 = true;
            for (uint32_t i = 0; i < g_combined_scene.mesh_count; ++i) {
              if (g_combined_scene.meshes[i].material_index == 0) {
                g_combined_scene.meshes[i].visible = show_material_0;
              } else if (g_combined_scene.meshes[i].material_index == 1) {
                g_combined_scene.meshes[i].visible = !show_material_0;
              }
            }
            show_material_0 = !show_material_0;
          }

          // Display hierarchical scene nodes
          if (g_combined_scene.root_node_count > 0) {
            ImGui::Separator();
            for (uint32_t i = 0; i < g_combined_scene.root_node_count; ++i) {
              draw_scene_node(g_combined_scene.root_nodes[i]);
            }
          } else {
            // Fallback to old mesh display if no hierarchy
            ImGui::Text("No scene hierarchy - showing flat mesh list:");
            for (uint32_t i = 0; i < g_combined_scene.mesh_count; ++i) {
              CardinalMesh &m = g_combined_scene.meshes[i];

              // Create unique ID for the checkbox
              char checkbox_id[64];
              snprintf(checkbox_id, sizeof(checkbox_id),
                       "Visible##flat_mesh_%u", i);

              // Visibility checkbox
              ImGui::Checkbox(checkbox_id, &m.visible);
              ImGui::SameLine();

              ImGui::BulletText("Mesh %u: %u vertices, %u indices", (unsigned)i,
                                (unsigned)m.vertex_count,
                                (unsigned)m.index_count);
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
 * Displays assets list with subdirectory navigation, search, filtering, and
 * file icons. Supports loading scenes and browsing through directory structure.
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
    if (ImGui::Checkbox("Folders Only", &g_show_folders_only))
      filter_changed = true;
    ImGui::SameLine();
    if (ImGui::Checkbox("glTF/GLB", &g_show_gltf_only))
      filter_changed = true;
    ImGui::SameLine();
    if (ImGui::Checkbox("Textures", &g_show_textures_only))
      filter_changed = true;

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
    CARDINAL_LOG_DEBUG("Starting asset browser UI rendering");
    const auto &entries_to_show =
        g_filtered_entries.empty() ? g_asset_entries : g_filtered_entries;
    CARDINAL_LOG_DEBUG("Using %s entries, count: %zu",
                       g_filtered_entries.empty() ? "asset" : "filtered",
                       entries_to_show.size());

    if (entries_to_show.empty()) {
      CARDINAL_LOG_DEBUG("No entries to show, displaying empty message");
      ImGui::TextDisabled("No assets found in '%s'", g_current_dir);
    } else {
      CARDINAL_LOG_DEBUG("Beginning asset list child window");
      if (ImGui::BeginChild("##assets_list", ImVec2(0, 0), true)) {
        CARDINAL_LOG_DEBUG(
            "Asset list child window created, iterating %zu entries",
            entries_to_show.size());
        for (size_t i = 0; i < entries_to_show.size(); ++i) {
          const auto &e = entries_to_show[i];
          CARDINAL_LOG_TRACE("Rendering entry %zu: %s", i, e.display.c_str());

          // Display icon and name
          CARDINAL_LOG_TRACE("About to render icon for entry %zu", i);
          ImGui::Text("%s", get_asset_icon(e.type));
          CARDINAL_LOG_TRACE("Icon rendered, adding SameLine");
          ImGui::SameLine();

          CARDINAL_LOG_TRACE("About to render Selectable for: %s",
                             e.display.c_str());
          bool selected = ImGui::Selectable(e.display.c_str());
          CARDINAL_LOG_TRACE("Selectable rendered, selected: %d", selected);

          if (selected) {
            CARDINAL_LOG_INFO(
                "Asset browser item clicked: %s (is_directory: %d, type: %d)",
                e.display.c_str(), e.is_directory, e.type);

            if (e.is_directory) {
              // Navigate to directory
              CARDINAL_LOG_INFO("Navigating to directory: %s -> %s",
                                g_current_dir, e.fullPath.c_str());

              if (e.display == "..") {
                // Go to parent directory
                CARDINAL_LOG_DEBUG("Going to parent directory: %s",
                                   e.fullPath.c_str());
                strncpy(g_current_dir, e.fullPath.c_str(),
                        sizeof(g_current_dir) - 1);
                g_current_dir[sizeof(g_current_dir) - 1] = '\0';
              } else {
                // Enter subdirectory
                CARDINAL_LOG_DEBUG("Entering subdirectory: %s",
                                   e.fullPath.c_str());
                strncpy(g_current_dir, e.fullPath.c_str(),
                        sizeof(g_current_dir) - 1);
                g_current_dir[sizeof(g_current_dir) - 1] = '\0';
              }

              CARDINAL_LOG_DEBUG("Current directory updated to: %s",
                                 g_current_dir);
              CARDINAL_LOG_DEBUG(
                  "Calling scan_assets_dir() after directory navigation");

              try {
                scan_assets_dir();
                CARDINAL_LOG_DEBUG("scan_assets_dir() completed successfully");
              } catch (const std::exception &e) {
                CARDINAL_LOG_ERROR("Exception in scan_assets_dir(): %s",
                                   e.what());
              } catch (...) {
                CARDINAL_LOG_ERROR("Unknown exception in scan_assets_dir()");
              }
            } else {
              // Select file for loading
              CARDINAL_LOG_INFO("File selected: %s (type: %d)",
                                e.fullPath.c_str(), e.type);
              snprintf(g_scene_path, sizeof(g_scene_path), "%s",
                       e.fullPath.c_str());
              // Auto-load glTF/GLB files
              if (e.type == ASSET_TYPE_GLTF || e.type == ASSET_TYPE_GLB) {
                CARDINAL_LOG_INFO("Auto-loading glTF/GLB file: %s",
                                  e.fullPath.c_str());
                load_scene_from_path(e.fullPath.c_str());
              }
            }
          }

          // Double-click support for files
          if (!e.is_directory && ImGui::IsItemHovered() &&
              ImGui::IsMouseDoubleClicked(0)) {
            if (e.type == ASSET_TYPE_GLTF || e.type == ASSET_TYPE_GLB) {
              load_scene_from_path(e.fullPath.c_str());
            }
          }
        }
        CARDINAL_LOG_DEBUG("Finished iterating all entries");
      }
      CARDINAL_LOG_DEBUG("Ending asset list child window");
      ImGui::EndChild();
      CARDINAL_LOG_DEBUG("Asset list child window ended successfully");
    }
    CARDINAL_LOG_DEBUG("Asset browser UI rendering completed");
  }
  CARDINAL_LOG_DEBUG("Ending asset browser window");
  ImGui::End();
  CARDINAL_LOG_DEBUG("Asset browser window ended successfully");
}

static void draw_model_manager_panel() {
  if (ImGui::Begin("Model Manager")) {
    ImGui::Text("Loaded Models:");
    ImGui::Separator();

    // Get model count
    uint32_t model_count = g_model_manager.model_count;

    if (model_count == 0) {
      ImGui::Text("No models loaded");
      ImGui::TextWrapped("Load models from the Assets panel to see them here.");
    } else {
      // Model list with operations
      if (ImGui::BeginChild("##model_list", ImVec2(0, 300), true)) {
        for (uint32_t i = 0; i < model_count; i++) {
          CardinalModelInstance *model =
              cardinal_model_manager_get_model_by_index(&g_model_manager, i);
          if (!model)
            continue;

          ImGui::PushID((int)model->id);

          // Model header with selection
          bool is_selected = (g_selected_model_id == model->id);
          if (ImGui::Selectable(model->name ? model->name : "Unnamed Model",
                                is_selected)) {
            g_selected_model_id = model->id;
            cardinal_model_manager_set_selected(&g_model_manager, model->id);
          }

          // Model controls on same line
          ImGui::SameLine();

          // Visibility toggle
          bool visible = model->visible;
          if (ImGui::Checkbox("##visible", &visible)) {
            cardinal_model_manager_set_visible(&g_model_manager, model->id,
                                               visible);
          }
          if (ImGui::IsItemHovered()) {
            ImGui::SetTooltip("Toggle visibility");
          }

          ImGui::SameLine();

          // Remove button
          if (ImGui::Button("Remove")) {
            cardinal_model_manager_remove_model(&g_model_manager, model->id);
            if (g_selected_model_id == model->id) {
              g_selected_model_id = 0;
            }
            ImGui::PopID();
            break; // Exit loop since we modified the array
          }

          // Show model info when selected
          if (is_selected) {
            ImGui::Indent();
            ImGui::Text("ID: %u", model->id);
            ImGui::Text("Meshes: %u", model->scene.mesh_count);
            ImGui::Text("Materials: %u", model->scene.material_count);
            if (model->file_path) {
              ImGui::Text("Path: %s", model->file_path);
            }

            // Transform controls
            ImGui::Separator();
            ImGui::Text("Transform:");

            // Position (extract from transform matrix)
            float pos[3] = {model->transform[12], model->transform[13],
                            model->transform[14]};
            if (ImGui::DragFloat3("Position", pos, 0.1f)) {
              float new_transform[16];
              memcpy(new_transform, model->transform, sizeof(new_transform));
              new_transform[12] = pos[0];
              new_transform[13] = pos[1];
              new_transform[14] = pos[2];
              cardinal_model_manager_set_transform(&g_model_manager, model->id,
                                                   new_transform);
            }

            // Scale (extract from transform matrix - assume uniform scale)
            float current_scale =
                sqrtf(model->transform[0] * model->transform[0] +
                      model->transform[1] * model->transform[1] +
                      model->transform[2] * model->transform[2]);
            float scale = current_scale;
            if (ImGui::DragFloat("Scale", &scale, 0.01f, 0.01f, 10.0f)) {
              float scale_matrix[16];
              cardinal_matrix_identity(scale_matrix);
              scale_matrix[0] = scale_matrix[5] = scale_matrix[10] = scale;
              scale_matrix[12] = pos[0];
              scale_matrix[13] = pos[1];
              scale_matrix[14] = pos[2];
              cardinal_model_manager_set_transform(&g_model_manager, model->id,
                                                   scale_matrix);
            }

            // Reset transform button
            if (ImGui::Button("Reset Transform")) {
              float identity[16];
              cardinal_matrix_identity(identity);
              cardinal_model_manager_set_transform(&g_model_manager, model->id,
                                                   identity);
            }

            ImGui::Unindent();
          }

          ImGui::PopID();
        }
      }
      ImGui::EndChild();

      ImGui::Separator();

      // Bulk operations
      ImGui::Text("Bulk Operations:");
      if (ImGui::Button("Show All")) {
        for (uint32_t i = 0; i < model_count; i++) {
          CardinalModelInstance *model =
              cardinal_model_manager_get_model_by_index(&g_model_manager, i);
          if (model) {
            cardinal_model_manager_set_visible(&g_model_manager, model->id,
                                               true);
          }
        }
      }
      ImGui::SameLine();
      if (ImGui::Button("Hide All")) {
        for (uint32_t i = 0; i < model_count; i++) {
          CardinalModelInstance *model =
              cardinal_model_manager_get_model_by_index(&g_model_manager, i);
          if (model) {
            cardinal_model_manager_set_visible(&g_model_manager, model->id,
                                               false);
          }
        }
      }
      ImGui::SameLine();
      if (ImGui::Button("Remove All")) {
        // Remove all models (iterate backwards to avoid index issues)
        for (int i = (int)model_count - 1; i >= 0; i--) {
          CardinalModelInstance *model =
              cardinal_model_manager_get_model_by_index(&g_model_manager,
                                                        (uint32_t)i);
          if (model) {
            cardinal_model_manager_remove_model(&g_model_manager, model->id);
          }
        }
        g_selected_model_id = 0;
      }
    }

    ImGui::Separator();
    ImGui::Text("Total Models: %u", model_count);
    ImGui::Text("Total Meshes: %u",
                cardinal_model_manager_get_total_mesh_count(&g_model_manager));
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
          if (g_scene_loaded && g_combined_scene.material_count > 0) {
            // Apply override values to all materials in the scene
            for (uint32_t i = 0; i < g_combined_scene.material_count; i++) {
              CardinalMaterial *mat = &g_combined_scene.materials[i];

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
              cardinal_renderer_upload_scene(g_renderer, &g_combined_scene);
              printf("Scene re-uploaded to renderer\n");
            }

            snprintf(g_status_msg, sizeof(g_status_msg),
                     "Applied material override to %u materials",
                     g_combined_scene.material_count);
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
        const char *mode_names[] = {"Normal", "UV Visualization", "Wireframe",
                                    "Mesh Shader"};
        int current_item = (int)current_mode;

        if (ImGui::Combo("Mode", &current_item, mode_names, 4)) {
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
        case CARDINAL_RENDERING_MODE_MESH_SHADER:
          ImGui::TextWrapped(
              "GPU-driven mesh shader rendering with task/mesh shaders.");
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

  // Update model manager (processes async loading and marks scene dirty when
  // needed)
  cardinal_model_manager_update(&g_model_manager);

  // Check if combined scene needs to be re-uploaded to renderer
  const CardinalScene *combined =
      cardinal_model_manager_get_combined_scene(&g_model_manager);
  if (combined && g_renderer) {
    // Always re-upload when we get a combined scene since the model manager
    // rebuilds the scene in-place when dirty, so pointer comparison isn't
    // reliable
    static uint32_t last_mesh_count = 0;
    static uint32_t last_material_count = 0;
    static uint32_t last_texture_count = 0;

    // Check if scene content has changed by comparing counts
    bool scene_changed = (combined->mesh_count != last_mesh_count ||
                          combined->material_count != last_material_count ||
                          combined->texture_count != last_texture_count);

    if (scene_changed) {
      // Instead of uploading immediately, defer the upload to avoid race
      // conditions with command buffer recording
      g_pending_scene = *combined;
      g_scene_upload_pending = true;

      // Update tracking variables
      last_mesh_count = combined->mesh_count;
      last_material_count = combined->material_count;
      last_texture_count = combined->texture_count;
    }
  }

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

  // Update animation system if scene is loaded
  if (g_scene_loaded && g_combined_scene.animation_system) {
    ImGuiIO &io = ImGui::GetIO();
    float dt = io.DeltaTime > 0.0f ? io.DeltaTime : 1.0f / 60.0f;
    cardinal_animation_system_update(g_combined_scene.animation_system,
                                     g_combined_scene.all_nodes,
                                     g_combined_scene.all_node_count, dt);

    // Sync editor animation time with animation system state
    if (g_selected_animation >= 0 &&
        g_selected_animation <
            (int)g_combined_scene.animation_system->animation_count) {
      // Find the animation state for the selected animation
      for (uint32_t i = 0; i < g_combined_scene.animation_system->state_count;
           ++i) {
        CardinalAnimationState *state =
            &g_combined_scene.animation_system->states[i];
        if (state->animation_index == (uint32_t)g_selected_animation) {
          g_animation_time = state->current_time;
          g_animation_playing = state->is_playing;
          g_animation_looping = state->is_looping;
          g_animation_speed = state->playback_speed;
          break;
        }
      }
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
      ImGui::MenuItem("Model Manager", nullptr, true, true);
      ImGui::MenuItem("PBR Settings", nullptr, true, true);
      ImGui::MenuItem("Animation", nullptr, true, true);
      ImGui::EndMenu();
    }
    ImGui::EndMenuBar();
  }

  CARDINAL_LOG_DEBUG("Drawing scene graph panel");
  draw_scene_graph_panel();
  CARDINAL_LOG_DEBUG("Scene graph panel completed");

  CARDINAL_LOG_DEBUG("Drawing asset browser panel");
  draw_asset_browser_panel();
  CARDINAL_LOG_DEBUG("Asset browser panel completed");

  CARDINAL_LOG_DEBUG("Drawing model manager panel");
  draw_model_manager_panel();
  CARDINAL_LOG_DEBUG("Model manager panel completed");

  CARDINAL_LOG_DEBUG("Drawing PBR settings panel");
  draw_pbr_settings_panel();
  CARDINAL_LOG_DEBUG("PBR settings panel completed");

  CARDINAL_LOG_DEBUG("Drawing animation panel");
  draw_animation_panel();
  CARDINAL_LOG_DEBUG("Animation panel completed");

  CARDINAL_LOG_DEBUG("Ending main dockspace window");
  ImGui::End();
  CARDINAL_LOG_DEBUG("Main dockspace window ended");

  // Set up UI callback before render to ensure proper command recording
  CARDINAL_LOG_DEBUG("Setting UI callback for renderer");
  cardinal_renderer_set_ui_callback(g_renderer, imgui_record);
  CARDINAL_LOG_DEBUG("UI callback set, calling ImGui::Render()");

  ImGui::Render();
  CARDINAL_LOG_DEBUG("ImGui::Render() completed");

  // Only render platform windows if multi-viewport is enabled
  ImGuiIO &io = ImGui::GetIO();
  if ((io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) != 0) {
    ImGui::UpdatePlatformWindows();
    ImGui::RenderPlatformWindowsDefault();
  }

  // Scene uploads are now processed in main loop after frame rendering
}

void editor_layer_shutdown(void) {
  if (g_renderer) {
    cardinal_renderer_set_ui_callback(g_renderer, NULL);
    // Wait for device idle before cleanup to avoid destroying resources in use
    cardinal_renderer_wait_idle(g_renderer);
  }

  if (g_scene_loaded) {
    cardinal_scene_destroy(&g_combined_scene);
    memset(&g_combined_scene, 0, sizeof(g_combined_scene));
    g_scene_loaded = false;
  }

  // Clean up model manager
  cardinal_model_manager_destroy(&g_model_manager);

  // Shutdown ImGui and destroy descriptor pool BEFORE renderer destruction
  // This ensures the Vulkan device is still valid when we clean up ImGui
  // resources
  ImGui_ImplVulkan_Shutdown();
  ImGui_ImplGlfw_Shutdown();

  // NOTE: ImGui_ImplVulkan_Shutdown() handles descriptor pool cleanup
  // internally Manual descriptor pool destruction removed to prevent
  // double-free heap corruption The descriptor pool will be cleaned up by
  // ImGui's internal shutdown process
  if (g_descriptor_pool != VK_NULL_HANDLE) {
      if (g_renderer) {
          VkDevice device = cardinal_renderer_internal_device(g_renderer);
          printf("[EDITOR] Destroying descriptor pool: %p using device: %p\n", (void*)g_descriptor_pool, (void*)device);
          vkDestroyDescriptorPool(device, g_descriptor_pool, NULL);
      } else {
          printf("[EDITOR] Cannot destroy descriptor pool: g_renderer is NULL\n");
      }
  } else {
      printf("[EDITOR] Descriptor pool is already NULL\n");
  }
  g_descriptor_pool = VK_NULL_HANDLE;

  ImGui::DestroyContext();
}
