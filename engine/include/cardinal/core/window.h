/**
 * @file window.h
 * @brief Cross-platform window management for Cardinal Engine
 *
 * This module provides a cross-platform window abstraction layer built on top
 * of GLFW. It handles window creation, event polling, and provides access to
 * native window handles for graphics API surface creation.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_CORE_WINDOW_H
#define CARDINAL_CORE_WINDOW_H

#include <stdbool.h>
#include <stdint.h>

/** @brief Forward declaration of GLFWwindow to avoid including GLFW in public
 * header */
struct GLFWwindow;

/**
 * @brief Configuration structure for window creation
 *
 * Contains all parameters needed to create a new window instance.
 */
typedef struct CardinalWindowConfig {
  const char *title; /**< Window title displayed in the title bar */
  uint32_t width;    /**< Initial window width in pixels */
  uint32_t height;   /**< Initial window height in pixels */
  bool resizable;    /**< Whether the window can be resized by the user */
} CardinalWindowConfig;

/**
 * @brief Window instance structure
 *
 * Represents an active window with its current state and properties.
 * This structure should be treated as opaque by client code.
 */
typedef struct CardinalWindow {
  struct GLFWwindow *handle; /**< Internal GLFW window handle */
  uint32_t width;            /**< Current window width in pixels */
  uint32_t height;           /**< Current window height in pixels */
  bool should_close;         /**< Flag indicating if window should close */
} CardinalWindow;

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Create a new window instance
 *
 * Creates and initializes a new window with the specified configuration.
 * The window will be visible and ready for rendering after creation.
 *
 * @param config Pointer to window configuration structure
 * @return Pointer to newly created window instance, or NULL on failure
 *
 * @note The returned window must be destroyed with cardinal_window_destroy()
 */
CardinalWindow *cardinal_window_create(const CardinalWindowConfig *config);

/**
 * @brief Poll window events
 *
 * Processes pending window events such as input, resize, and close requests.
 * This function should be called once per frame in the main loop.
 *
 * @param window Pointer to the window instance
 */
void cardinal_window_poll(CardinalWindow *window);

/**
 * @brief Destroy a window instance
 *
 * Properly cleans up and destroys the specified window, freeing all
 * associated resources. The window pointer becomes invalid after this call.
 *
 * @param window Pointer to the window instance to destroy
 */
void cardinal_window_destroy(CardinalWindow *window);

/**
 * @brief Check if window should close
 *
 * Returns whether the window has received a close request from the user
 * (e.g., clicking the X button or pressing Alt+F4).
 *
 * @param window Pointer to the window instance
 * @return true if the window should close, false otherwise
 */
bool cardinal_window_should_close(const CardinalWindow *window);

/**
 * @brief Get platform-native window handle
 *
 * Returns a platform-specific window handle suitable for graphics API
 * surface creation. On Windows, this returns an HWND; on Linux, this
 * returns a Window (X11) or wl_surface (Wayland).
 *
 * @param window Pointer to the window instance
 * @return Platform-native window handle, or NULL on failure
 *
 * @note The returned handle should not be freed by the caller
 */
void *cardinal_window_get_native_handle(const CardinalWindow *window);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_WINDOW_H
