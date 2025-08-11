#include <string.h>
#include <ctype.h>
#include <stdbool.h>

#include "cardinal/assets/loader.h"
#include "cardinal/assets/gltf_loader.h"

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
    if (!path || !out_scene) return false;
    const char* ext = find_ext(path);
    if (!ext) return false;

    char ext_buf[16] = {0};
    strncpy(ext_buf, ext, sizeof(ext_buf)-1);
    tolower_str(ext_buf);

    if (strcmp(ext_buf, "gltf") == 0 || strcmp(ext_buf, "glb") == 0) {
        return cardinal_gltf_load_scene(path, out_scene);
    }

    return false;
}
