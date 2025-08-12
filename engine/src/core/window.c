#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <GLFW/glfw3.h>
#include <stdio.h>

#include "cardinal/core/window.h"
#include "cardinal/core/log.h"

/**
 * @brief GLFW error callback function.
 * @param error Error code.
 * @param desc Error description.
 */
/**
 * @brief GLFW error callback function.
 *
 * Logs GLFW errors.
 *
 * @param error Error code.
 * @param desc Error description.
 *
 * @todo Integrate with centralized error handling system.
 */
static void glfw_error_callback(int error, const char* desc) {
    LOG_ERROR("GLFW error %d: %s", error, desc ? desc : "(null)");
}

/**
 * @brief Creates a new window with the given configuration.
 * @param config Window configuration.
 * @return Pointer to the created window or NULL on failure.
 * 
 * @todo Refactor to support multiple window creation.
 * @todo Integrate Vulkan surface creation directly for better renderer compatibility.
 */
/**
 * @brief Creates a new window with the given configuration.
 *
 * @param config Window configuration.
 * @return Pointer to the created window or NULL on failure.
 *
 * @todo Support multiple monitors and fullscreen modes.
 * @todo Add validation for config parameters.
 * @todo Integrate with Vulkan surface creation.
 */
CardinalWindow* cardinal_window_create(const CardinalWindowConfig* config) {
    assert(config);
    LOG_INFO("cardinal_window_create: begin");
    if (!glfwInit()) {
        LOG_ERROR("GLFW init failed");
        return NULL;
    }

    glfwSetErrorCallback(glfw_error_callback);

    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindowHint(GLFW_RESIZABLE, config->resizable ? GLFW_TRUE : GLFW_FALSE);

    GLFWwindow* handle = glfwCreateWindow((int)config->width, (int)config->height, config->title, NULL, NULL);
    if (!handle) {
        LOG_ERROR("GLFW create window failed");
        glfwTerminate();
        return NULL;
    }

    CardinalWindow* win = (CardinalWindow*)calloc(1, sizeof(CardinalWindow));
    win->handle = handle;
    win->width = config->width;
    win->height = config->height;
    win->should_close = false;

    LOG_INFO("cardinal_window_create: success");
    return win;
}

/**
 * @brief Polls for window events.
 * @param window The window to poll.
 * 
 * @todo Improve by adding custom event dispatching system.
 */
/**
 * @brief Polls for window events.
 *
 * @param window The window to poll.
 *
 * @todo Implement custom event queue for better control.
 * @todo Add support for touch and gesture events.
 */
void cardinal_window_poll(CardinalWindow* window) {
    if (!window) return;
    glfwPollEvents();
    window->should_close = glfwWindowShouldClose(window->handle) != 0;
}

/**
 * @brief Checks if the window should close.
 * @param window The window to check.
 * @return true if should close, false otherwise.
 */
/**
 * @brief Checks if the window should close.
 *
 * @param window The window to check.
 * @return true if should close, false otherwise.
 *
 * @todo Add custom close conditions (e.g., based on application state).
 */
bool cardinal_window_should_close(const CardinalWindow* window) {
    return window ? window->should_close : true;
}

/**
 * @brief Destroys the window and cleans up resources.
 * @param window The window to destroy.
 * 
 * @todo Ensure proper cleanup of associated Vulkan resources.
 * @todo Add support for Vulkan extension VK_KHR_portability_subset for better cross-platform handling.
 */
/**
 * @brief Destroys the window and cleans up resources.
 *
 * @param window The window to destroy.
 *
 * @todo Ensure thread-safe destruction.
 * @todo Clean up associated input callbacks.
 */
void cardinal_window_destroy(CardinalWindow* window) {
    if (!window) return;
    if (window->handle) {
        glfwDestroyWindow(window->handle);
        window->handle = NULL;
    }
    glfwTerminate();
    free(window);
}

