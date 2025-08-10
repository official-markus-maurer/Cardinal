#ifndef CARDINAL_RENDERER_RENDERER_H
#define CARDINAL_RENDERER_RENDERER_H

#include <stdbool.h>
#include <stdint.h>

// Forward declarations
struct GLFWwindow;
typedef struct CardinalWindow CardinalWindow;

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

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_RENDERER_RENDERER_H
