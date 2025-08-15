/**
 * @file renderer.h
 * @brief Cardinal Engine Vulkan Renderer
 * 
 * This module provides the main rendering interface for Cardinal Engine,
 * implementing a modern Vulkan-based PBR (Physically Based Rendering) pipeline.
 */

#ifndef CARDINAL_RENDERER_RENDERER_H
#define CARDINAL_RENDERER_RENDERER_H

#include <stdbool.h>
#include <stdint.h>

/**
 * @brief Forward declarations
 */
struct GLFWwindow;
typedef struct CardinalWindow CardinalWindow;
typedef struct CardinalScene CardinalScene;

/**
 * @brief Camera configuration for 3D rendering
 * 
 * Defines the camera parameters used for view and projection matrix calculations
 * in the PBR rendering pipeline.
 */
typedef struct CardinalCamera {
    float position[3];    /**< Camera world position (x, y, z) */
    float target[3];      /**< Camera look-at target (x, y, z) */
    float up[3];          /**< Camera up vector (x, y, z) */
    float fov;            /**< Field of view in degrees */
    float aspect;         /**< Aspect ratio (width/height) */
    float near_plane;     /**< Near clipping plane distance */
    float far_plane;      /**< Far clipping plane distance */
} CardinalCamera;

/**
 * @brief Lighting configuration for PBR rendering
 * 
 * Defines the lighting parameters used in the physically based rendering
 * calculations, including directional light and ambient lighting.
 */
typedef struct CardinalLight {
    float direction[3];   /**< Directional light direction (normalized) */
    float color[3];       /**< Light color (RGB, 0.0-1.0) */
    float intensity;      /**< Light intensity multiplier */
    float ambient[3];     /**< Ambient light color (RGB, 0.0-1.0) */
} CardinalLight;

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Opaque renderer handle
 * 
 * Contains internal Vulkan state and resources. Users should not
 * access the internal data directly.
 */
typedef struct CardinalRenderer {
    void* _opaque; /**< Internal renderer state (do not access directly) */
} CardinalRenderer;

/**
 * @brief Create and initialize the renderer
 * @param out_renderer Pointer to renderer structure to initialize
 * @param window Window to render to
 * @return true on success, false on failure
 */
bool cardinal_renderer_create(CardinalRenderer* out_renderer, CardinalWindow* window);

/**
 * @brief Render a single frame
 * @param renderer Pointer to initialized renderer
 */
void cardinal_renderer_draw_frame(CardinalRenderer* renderer);

/**
 * @brief Wait for all rendering operations to complete
 * @param renderer Pointer to initialized renderer
 */
void cardinal_renderer_wait_idle(CardinalRenderer* renderer);

/**
 * @brief Destroy the renderer and free resources
 * @param renderer Pointer to renderer to destroy
 */
void cardinal_renderer_destroy(CardinalRenderer* renderer);

/**
 * @brief Upload a scene to the renderer
 * @param renderer Pointer to initialized renderer
 * @param scene Scene data to upload
 */
void cardinal_renderer_upload_scene(CardinalRenderer* renderer, const CardinalScene* scene);

/**
 * @brief Clear the current scene from the renderer
 * @param renderer Pointer to initialized renderer
 */
void cardinal_renderer_clear_scene(CardinalRenderer* renderer);

/**
 * @brief Set the camera parameters for rendering
 * @param renderer Pointer to initialized renderer
 * @param camera Camera configuration to use
 */
void cardinal_renderer_set_camera(CardinalRenderer* renderer, const CardinalCamera* camera);

/**
 * @brief Set the lighting parameters for PBR rendering
 * @param renderer Pointer to initialized renderer
 * @param light Lighting configuration to use
 */
void cardinal_renderer_set_lighting(CardinalRenderer* renderer, const CardinalLight* light);
void cardinal_renderer_enable_pbr(CardinalRenderer* renderer, bool enable);
bool cardinal_renderer_is_pbr_enabled(CardinalRenderer* renderer);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_RENDERER_RENDERER_H
