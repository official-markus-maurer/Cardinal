#include <ctype.h>
#include <stdbool.h>
#include <string.h>

#include "cardinal/assets/gltf_loader.h"
#include "cardinal/assets/loader.h"
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
 * @brief Loads a scene from a file.
 *
 * @param path Path to the scene file.
 * @param out_scene Pointer to store the loaded scene.
 * @return true if successful, false otherwise.
 *
 * @todo Add support for additional formats like OBJ and FBX.
 * @todo Implement asynchronous loading for better performance.
 * @todo Enhance error reporting with specific failure reasons.
 */
bool cardinal_scene_load(const char* path, CardinalScene* out_scene) {
    if (!path || !out_scene) {
        LOG_ERROR("Invalid parameters: path=%p, out_scene=%p", (void*)path, (void*)out_scene);
        return false;
    }

    LOG_INFO("Scene loading requested: %s", path);

    const char* ext = find_ext(path);
    if (!ext) {
        LOG_ERROR("No file extension found in path: %s", path);
        return false;
    }

    LOG_DEBUG("Detected file extension: %s", ext);

    char ext_buf[16] = {0};
    strncpy_s(ext_buf, sizeof(ext_buf), ext, sizeof(ext_buf) - 1);
    tolower_str(ext_buf);

    LOG_DEBUG("Normalized extension: %s", ext_buf);

    if (strcmp(ext_buf, "gltf") == 0 || strcmp(ext_buf, "glb") == 0) {
        LOG_DEBUG("Routing to GLTF loader");
        return cardinal_gltf_load_scene(path, out_scene);
    }

    LOG_ERROR("Unsupported file format: %s (extension: %s)", path, ext_buf);
    return false;
}
