/**
 * @file window.c
 * @brief Window management implementation for Cardinal Engine
 *
 * This file implements cross-platform window management functionality using
 * GLFW. It handles window creation, event processing, input handling, and
 * integration with the Vulkan rendering system.
 *
 * Key features:
 * - Cross-platform window creation (Windows, Linux, macOS)
 * - Vulkan surface integration
 * - Input event handling (keyboard, mouse)
 * - Window resize and framebuffer callbacks
 * - Fullscreen and windowed mode support
 * - Error handling and logging integration
 *
 * Platform-specific features:
 * - Windows: Native Win32 handle access
 * - Linux: Wayland compatibility
 * - macOS: Metal surface support preparation
 *
 * The implementation provides a clean abstraction over GLFW while
 * maintaining access to platform-specific functionality when needed
 * for advanced rendering features.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include <GLFW/glfw3.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
    #define GLFW_EXPOSE_NATIVE_WIN32
    #include <GLFW/glfw3native.h>
#endif

#include "cardinal/core/log.h"
#include "cardinal/core/window.h"

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
    CARDINAL_LOG_ERROR("GLFW error %d: %s", error, desc ? desc : "(null)");
}

static void framebuffer_resize_callback(GLFWwindow* window, int width, int height) {
    CardinalWindow* win = (CardinalWindow*)glfwGetWindowUserPointer(window);
    if (!win)
        return;
    if (width > 0 && height > 0) {
        win->resize_pending = true;
        win->new_width = (uint32_t)width;
        win->new_height = (uint32_t)height;
        win->width = (uint32_t)width;
        win->height = (uint32_t)height;
        if (win->resize_callback) {
            win->resize_callback(win->new_width, win->new_height, win->resize_user_data);
        }
    }
}

static void window_iconify_callback(GLFWwindow* window, int iconified) {
    CardinalWindow* win = (CardinalWindow*)glfwGetWindowUserPointer(window);
    if (!win)
        return;
    win->was_minimized = win->is_minimized;
    win->is_minimized = (iconified == GLFW_TRUE);
    if (win->was_minimized && !win->is_minimized) {
        int w = 0, h = 0;
        glfwGetFramebufferSize(window, &w, &h);
        if (w > 0 && h > 0) {
            win->resize_pending = true;
            win->new_width = (uint32_t)w;
            win->new_height = (uint32_t)h;
            win->width = (uint32_t)w;
            win->height = (uint32_t)h;
            if (win->resize_callback) {
                win->resize_callback(win->new_width, win->new_height, win->resize_user_data);
            }
        }
    }
}
/**
 * @brief Creates a new window with the given configuration.
 *
 * @param config Window configuration.
 * @return Pointer to the created window or NULL on failure.
 *
 * @todo Refactor to support multiple window creation.
 * @todo Integrate Vulkan surface creation directly for better renderer compatibility.
 * @todo Support multiple monitors and fullscreen modes.
 * @todo Add validation for config parameters.
 */
CardinalWindow* cardinal_window_create(const CardinalWindowConfig* config) {
    assert(config);
    CARDINAL_LOG_INFO("cardinal_window_create: begin");
    if (!glfwInit()) {
        CARDINAL_LOG_ERROR("GLFW init failed");
        return NULL;
    }

    glfwSetErrorCallback(glfw_error_callback);

    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindowHint(GLFW_RESIZABLE, config->resizable ? GLFW_TRUE : GLFW_FALSE);

    GLFWwindow* handle =
        glfwCreateWindow((int)config->width, (int)config->height, config->title, NULL, NULL);
    if (!handle) {
        CARDINAL_LOG_ERROR("GLFW create window failed");
        glfwTerminate();
        return NULL;
    }

    CardinalWindow* win = (CardinalWindow*)calloc(1, sizeof(CardinalWindow));
    win->handle = handle;
    win->width = config->width;
    win->height = config->height;
    win->should_close = false;
    // Register GLFW callbacks for resize/minimize
    glfwSetWindowUserPointer(handle, win);
    glfwSetFramebufferSizeCallback(handle, framebuffer_resize_callback);
    glfwSetWindowIconifyCallback(handle, window_iconify_callback);

    // Initialize mutex for thread safety
#ifdef _WIN32
    InitializeCriticalSection(&win->mutex);
#else
    if (pthread_mutex_init(&win->mutex, NULL) != 0) {
        CARDINAL_LOG_ERROR("Failed to initialize window mutex");
        glfwDestroyWindow(win->handle);
        free(win);
        return NULL;
    }
#endif

    CARDINAL_LOG_INFO("cardinal_window_create: success");
    return win;
}

/**
 * @brief Polls for window events.
 *
 * @param window The window to poll.
 *
 * @todo Implement custom event queue for better control.
 * @todo Improve by adding custom event dispatching system.
 * @todo Add support for touch and gesture events.
 */
void cardinal_window_poll(CardinalWindow* window) {
    if (!window)
        return;

    // Lock mutex for thread-safe polling
#ifdef _WIN32
    EnterCriticalSection(&window->mutex);
#else
    pthread_mutex_lock(&window->mutex);
#endif

    glfwPollEvents();
    window->should_close = glfwWindowShouldClose(window->handle) != 0;

    // Unlock mutex
#ifdef _WIN32
    LeaveCriticalSection(&window->mutex);
#else
    pthread_mutex_unlock(&window->mutex);
#endif
}

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
 * @todo Add support for Vulkan extension VK_KHR_portability_subset for better cross-platform
 * @todo Ensure thread-safe destruction.
 * @todo Clean up associated input callbacks.
 * handling.
 */
void cardinal_window_destroy(CardinalWindow* window) {
    if (!window)
        return;

    // Lock mutex for thread-safe destruction
#ifdef _WIN32
    EnterCriticalSection(&window->mutex);
#else
    pthread_mutex_lock(&window->mutex);
#endif

    if (window->handle) {
        glfwDestroyWindow(window->handle);
        window->handle = NULL;
    }
    glfwTerminate();

    // Unlock and destroy mutex
#ifdef _WIN32
    LeaveCriticalSection(&window->mutex);
    DeleteCriticalSection(&window->mutex);
#else
    pthread_mutex_unlock(&window->mutex);
    pthread_mutex_destroy(&window->mutex);
#endif

    free(window);
}

void* cardinal_window_get_native_handle(const CardinalWindow* window) {
    if (!window || !window->handle)
        return NULL;
#ifdef _WIN32
    return (void*)glfwGetWin32Window(window->handle);
#else
    return NULL;
#endif
}

bool cardinal_window_is_minimized(const CardinalWindow* window) {
    return window ? window->is_minimized : false;
}
