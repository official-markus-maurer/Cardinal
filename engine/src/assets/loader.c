#include <ctype.h>
#include <stdbool.h>
#include <string.h>

#include "cardinal/assets/gltf_loader.h"
#include "cardinal/assets/loader.h"
#include "cardinal/core/async_loader.h"
#include "cardinal/core/log.h"

/**
 * @brief Finds the file extension in a path.
 *
 * @param path The file path.
 * @return Pointer to the extension string, or NULL if not found.
 *
 * @todo Handle paths with multiple dots more robustly.
 */
static const char* find_ext(const char* path) {
    if (!path)
        return NULL;
    const char* dot = strrchr(path, '.');
    return dot ? dot + 1 : NULL;
}

/**
 * @brief Converts a string to lowercase.
 *
 * @param s The string to convert.
 *
 * @todo Ensure UTF-8 compatibility for international characters.
 */
static void tolower_str(char* s) {
    if (!s)
        return;
    for (; *s; ++s)
        *s = (char)tolower((unsigned char)*s);
}

/**
 * @brief Loads a scene from a file synchronously.
 *
 * @param path Path to the scene file.
 * @param out_scene Pointer to store the loaded scene.
 * @return true if successful, false otherwise.
 *
 * @todo Add support for additional formats like OBJ and FBX.
 * @todo Enhance error reporting with specific failure reasons.
 */
bool cardinal_scene_load(const char* path, CardinalScene* out_scene) {
    if (!path || !out_scene) {
        CARDINAL_LOG_ERROR("Invalid parameters: path=%p, out_scene=%p", (void*)path,
                           (void*)out_scene);
        return false;
    }

    CARDINAL_LOG_INFO("Scene loading requested: %s", path);

    const char* ext = find_ext(path);
    if (!ext) {
        CARDINAL_LOG_ERROR("No file extension found in path: %s", path);
        return false;
    }

    CARDINAL_LOG_DEBUG("Detected file extension: %s", ext);

    char ext_buf[16] = {0};
    strncpy_s(ext_buf, sizeof(ext_buf), ext, sizeof(ext_buf) - 1);
    tolower_str(ext_buf);

    CARDINAL_LOG_DEBUG("Normalized extension: %s", ext_buf);

    if (strcmp(ext_buf, "gltf") == 0 || strcmp(ext_buf, "glb") == 0) {
        CARDINAL_LOG_DEBUG("Routing to GLTF loader");
        return cardinal_gltf_load_scene(path, out_scene);
    }

    CARDINAL_LOG_ERROR("Unsupported file format: %s (extension: %s)", path, ext_buf);
    return false;
}

/**
 * @brief Loads a scene from a file asynchronously.
 *
 * @param path Path to the scene file.
 * @param priority Loading priority.
 * @param callback Completion callback function.
 * @param user_data User data passed to callback.
 * @return Async task handle, or NULL on failure.
 *
 * @note The callback will be called on the main thread when processing
 *       completed tasks with cardinal_async_process_completed_tasks().
 */
CardinalAsyncTask* cardinal_scene_load_async(const char* path, CardinalAsyncPriority priority,
                                             CardinalAsyncCallback callback, void* user_data) {
    if (!path) {
        CARDINAL_LOG_ERROR("Invalid path parameter");
        return NULL;
    }

    if (!cardinal_async_loader_is_initialized()) {
        CARDINAL_LOG_ERROR("Async loader not initialized");
        return NULL;
    }

    CARDINAL_LOG_INFO("Async scene loading requested: %s", path);

    // Validate file extension before submitting task
    const char* ext = find_ext(path);
    if (!ext) {
        CARDINAL_LOG_ERROR("No file extension found in path: %s", path);
        return NULL;
    }

    char ext_buf[16] = {0};
    strncpy_s(ext_buf, sizeof(ext_buf), ext, sizeof(ext_buf) - 1);
    tolower_str(ext_buf);

    if (strcmp(ext_buf, "gltf") != 0 && strcmp(ext_buf, "glb") != 0) {
        CARDINAL_LOG_ERROR("Unsupported file format for async loading: %s (extension: %s)", path,
                           ext_buf);
        return NULL;
    }

    return cardinal_async_load_scene(path, priority, callback, user_data);
}
