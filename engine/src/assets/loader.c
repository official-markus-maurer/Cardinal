#include <string.h>
#include <ctype.h>
#include <stdbool.h>

#include "cardinal/assets/loader.h"
#include "cardinal/assets/gltf_loader.h"
#include "cardinal/core/log.h"

static const char* find_ext(const char* path) {
    if (!path) return NULL;
    const char* dot = strrchr(path, '.');
    return dot ? dot + 1 : NULL;
}

static void tolower_str(char* s) {
    if (!s) return;
    for (; *s; ++s) *s = (char)tolower((unsigned char)*s);
}

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
    strncpy_s(ext_buf, sizeof(ext_buf), ext, sizeof(ext_buf)-1);
    tolower_str(ext_buf);
    
    LOG_DEBUG("Normalized extension: %s", ext_buf);

    if (strcmp(ext_buf, "gltf") == 0 || strcmp(ext_buf, "glb") == 0) {
        LOG_DEBUG("Routing to GLTF loader");
        return cardinal_gltf_load_scene(path, out_scene);
    }

    LOG_ERROR("Unsupported file format: %s (extension: %s)", path, ext_buf);
    return false;
}
