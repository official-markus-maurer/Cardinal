#ifndef CARDINAL_CORE_WINDOW_H
#define CARDINAL_CORE_WINDOW_H

#include <stdint.h>
#include <stdbool.h>

// Forward declare GLFWwindow to avoid including GLFW in public header
struct GLFWwindow;

typedef struct CardinalWindowConfig {
    const char* title;
    uint32_t width;
    uint32_t height;
    bool resizable;
} CardinalWindowConfig;

typedef struct CardinalWindow {
    struct GLFWwindow* handle;
    uint32_t width;
    uint32_t height;
    bool should_close;
} CardinalWindow;

#ifdef __cplusplus
extern "C" {
#endif

CardinalWindow* cardinal_window_create(const CardinalWindowConfig* config);
void cardinal_window_poll(CardinalWindow* window);
void cardinal_window_destroy(CardinalWindow* window);
bool cardinal_window_should_close(const CardinalWindow* window);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_WINDOW_H
