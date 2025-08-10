#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <GLFW/glfw3.h>

#include "cardinal/core/window.h"

static void glfw_error_callback(int error, const char* desc) {
    (void)error;
    (void)desc;
}

CardinalWindow* cardinal_window_create(const CardinalWindowConfig* config) {
    assert(config);
    if (!glfwInit()) return NULL;

    glfwSetErrorCallback(glfw_error_callback);

    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindowHint(GLFW_RESIZABLE, config->resizable ? GLFW_TRUE : GLFW_FALSE);

    GLFWwindow* handle = glfwCreateWindow((int)config->width, (int)config->height, config->title, NULL, NULL);
    if (!handle) {
        glfwTerminate();
        return NULL;
    }

    CardinalWindow* win = (CardinalWindow*)calloc(1, sizeof(CardinalWindow));
    win->handle = handle;
    win->width = config->width;
    win->height = config->height;
    win->should_close = false;

    return win;
}

void cardinal_window_poll(CardinalWindow* window) {
    if (!window) return;
    glfwPollEvents();
    window->should_close = glfwWindowShouldClose(window->handle) != 0;
}

bool cardinal_window_should_close(const CardinalWindow* window) {
    return window ? window->should_close : true;
}

void cardinal_window_destroy(CardinalWindow* window) {
    if (!window) return;
    if (window->handle) {
        glfwDestroyWindow(window->handle);
        window->handle = NULL;
    }
    glfwTerminate();
    free(window);
}

