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
 * Defines the camera parameters used for view and projection matrix
 * calculations in the PBR rendering pipeline.
 */
typedef struct CardinalCamera {
  float position[3]; /**< Camera world position (x, y, z) */
  float target[3];   /**< Camera look-at target (x, y, z) */
  float up[3];       /**< Camera up vector (x, y, z) */
  float fov;         /**< Field of view in degrees */
  float aspect;      /**< Aspect ratio (width/height) */
  float near_plane;  /**< Near clipping plane distance */
  float far_plane;   /**< Far clipping plane distance */
} CardinalCamera;

/**
 * @brief Lighting configuration for PBR rendering
 *
 * Defines the lighting parameters used in the physically based rendering
 * calculations, including directional light and ambient lighting.
 */
typedef struct CardinalLight {
  float direction[3]; /**< Directional light direction (normalized) */
  float color[3];     /**< Light color (RGB, 0.0-1.0) */
  float intensity;    /**< Light intensity multiplier */
  float ambient[3];   /**< Ambient light color (RGB, 0.0-1.0) */
} CardinalLight;

/**
 * @brief Rendering mode enumeration
 *
 * Defines the different rendering modes available in the Cardinal Engine.
 * Each mode provides a different visualization of the 3D scene.
 */
typedef enum CardinalRenderingMode {
  CARDINAL_RENDERING_MODE_NORMAL =
      0, /**< Standard PBR rendering with textures and lighting */
  CARDINAL_RENDERING_MODE_UV, /**< UV coordinate visualization (shows texture
                                 coordinates as colors) */
  CARDINAL_RENDERING_MODE_WIREFRAME,  /**< Wireframe rendering (edges only) */
  CARDINAL_RENDERING_MODE_MESH_SHADER /**< GPU-driven mesh shader rendering */
} CardinalRenderingMode;

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
  void *_opaque; /**< Internal renderer state (do not access directly) */
} CardinalRenderer;

/**
 * @brief Create and initialize the renderer
 * @param out_renderer Pointer to renderer structure to initialize
 * @param window Window to render to
 * @return true on success, false on failure
 */
bool cardinal_renderer_create(CardinalRenderer *out_renderer,
                              CardinalWindow *window);

/**
 * @brief Create a headless renderer without a window/swapchain
 * @param
 * out_renderer Pointer to renderer structure to initialize
 * @param width
 * Logical framebuffer width
 * @param height Logical framebuffer height
 *
 * @return true on success, false on failure
 */
bool cardinal_renderer_create_headless(CardinalRenderer *out_renderer,
                                       uint32_t width, uint32_t height);

/**
 * @brief Render a single frame
 * @param renderer Pointer to initialized renderer
 */
void cardinal_renderer_draw_frame(CardinalRenderer *renderer);

/**
 * @brief Wait for all rendering operations to complete
 * @param renderer Pointer to initialized renderer
 */
void cardinal_renderer_wait_idle(CardinalRenderer *renderer);

/**
 * @brief Destroy the renderer and free resources
 * @param renderer Pointer to renderer to destroy
 */
void cardinal_renderer_destroy(CardinalRenderer *renderer);

/**
 * @brief Upload a scene to the renderer
 * @param renderer Pointer to initialized renderer
 * @param scene Scene data to upload
 */
void cardinal_renderer_upload_scene(CardinalRenderer *renderer,
                                    const CardinalScene *scene);

/**
 * @brief Clear the current scene from the renderer
 * @param renderer Pointer to initialized renderer
 */
void cardinal_renderer_clear_scene(CardinalRenderer *renderer);

/**
 * @brief Set the camera parameters for rendering
 * @param renderer Pointer to initialized renderer
 * @param camera Camera configuration to use
 */
void cardinal_renderer_set_camera(CardinalRenderer *renderer,
                                  const CardinalCamera *camera);

/**
 * @brief Set the lighting parameters for PBR rendering
 * @param renderer Pointer to initialized renderer
 * @param light Lighting configuration to use
 */
void cardinal_renderer_set_lighting(CardinalRenderer *renderer,
                                    const CardinalLight *light);
void cardinal_renderer_enable_pbr(CardinalRenderer *renderer, bool enable);
bool cardinal_renderer_is_pbr_enabled(CardinalRenderer *renderer);

/**
 * @brief Enable or disable mesh shader rendering pipeline
 * @param renderer Pointer to initialized renderer
 * @param enable True to enable mesh shaders, false to disable
 */
void cardinal_renderer_enable_mesh_shader(CardinalRenderer *renderer,
                                          bool enable);

/**
 * @brief Check if mesh shader pipeline is enabled
 * @param renderer Pointer to initialized renderer
 * @return True if mesh shader pipeline is enabled
 */
bool cardinal_renderer_is_mesh_shader_enabled(CardinalRenderer *renderer);

/**
 * @brief Check if mesh shaders are supported on this device
 * @param renderer Pointer to initialized renderer
 * @return True if mesh shaders are supported
 */
bool cardinal_renderer_supports_mesh_shader(CardinalRenderer *renderer);

/**
 * @brief Set the current rendering mode
 * @param renderer Pointer to initialized renderer
 * @param mode Rendering mode to use
 */
void cardinal_renderer_set_rendering_mode(CardinalRenderer *renderer,
                                          CardinalRenderingMode mode);

/**
 * @brief Get the current rendering mode
 * @param renderer Pointer to initialized renderer
 * @return Current rendering mode
 */
CardinalRenderingMode
cardinal_renderer_get_rendering_mode(CardinalRenderer *renderer);

/**
 * @brief Set device loss recovery callbacks
 * @param renderer Pointer to initialized renderer
 * @param device_loss_callback Called when device loss is detected (can be NULL)
 * @param recovery_complete_callback Called when recovery completes (can be
 * NULL)
 * @param user_data User data passed to callbacks
 */
void cardinal_renderer_set_device_loss_callbacks(
    CardinalRenderer *renderer, void (*device_loss_callback)(void *user_data),
    void (*recovery_complete_callback)(void *user_data, bool success),
    void *user_data);

/**
 * @brief Check if device is currently lost
 * @param renderer Pointer to initialized renderer
 * @return true if device is lost, false otherwise
 */
bool cardinal_renderer_is_device_lost(CardinalRenderer *renderer);

/**
 * @brief Get device loss recovery statistics
 * @param renderer Pointer to initialized renderer
 * @param out_attempt_count Pointer to store current recovery attempt count
 * @param out_max_attempts Pointer to store maximum recovery attempts
 * @return true if renderer is valid, false otherwise
 */
bool cardinal_renderer_get_recovery_stats(CardinalRenderer *renderer,
                                          uint32_t *out_attempt_count,
                                          uint32_t *out_max_attempts);

/**
 * @brief Enable or disable present skipping (test mode)
 * @param renderer
 * Pointer to initialized renderer
 * @param skip True to skip present calls,
 * false to present normally
 */
void cardinal_renderer_set_skip_present(CardinalRenderer *renderer, bool skip);

/**
 * @brief Enable or disable headless mode (no swapchain acquire/present)
 *
 * @param renderer Pointer to initialized renderer
 * @param enable True to
 * enable headless mode
 */
void cardinal_renderer_set_headless_mode(CardinalRenderer *renderer,
                                         bool enable);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_RENDERER_RENDERER_H
