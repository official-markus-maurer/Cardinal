#ifndef CARDINAL_RENDERER_RENDERER_H
#define CARDINAL_RENDERER_RENDERER_H

#include <stdbool.h>
#include <stdint.h>

// Forward declarations
struct GLFWwindow;
typedef struct CardinalWindow CardinalWindow;
typedef struct CardinalScene CardinalScene;

// Camera structure for PBR rendering
typedef struct CardinalCamera {
    float position[3];
    float target[3];
    float up[3];
    float fov;        // Field of view in degrees
    float aspect;     // Aspect ratio
    float near_plane;
    float far_plane;
} CardinalCamera;

// Lighting structure for PBR rendering
typedef struct CardinalLight {
    float direction[3];   // Directional light direction
    float color[3];       // Light color (RGB)
    float intensity;      // Light intensity
    float ambient[3];     // Ambient light color
} CardinalLight;

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CardinalRenderer {
    void* _opaque; // internal data pointer
} CardinalRenderer;

bool cardinal_renderer_create(CardinalRenderer* out_renderer, CardinalWindow* window);
void cardinal_renderer_draw_frame(CardinalRenderer* renderer);
void cardinal_renderer_wait_idle(CardinalRenderer* renderer);
void cardinal_renderer_destroy(CardinalRenderer* renderer);

// Scene management
void cardinal_renderer_upload_scene(CardinalRenderer* renderer, const CardinalScene* scene);
void cardinal_renderer_clear_scene(CardinalRenderer* renderer);

// PBR rendering functions
void cardinal_renderer_set_camera(CardinalRenderer* renderer, const CardinalCamera* camera);
void cardinal_renderer_set_lighting(CardinalRenderer* renderer, const CardinalLight* light);
void cardinal_renderer_enable_pbr(CardinalRenderer* renderer, bool enable);
bool cardinal_renderer_is_pbr_enabled(CardinalRenderer* renderer);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_RENDERER_RENDERER_H
