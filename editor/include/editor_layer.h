#ifndef EDITOR_LAYER_H
#define EDITOR_LAYER_H

#include <stdbool.h>

// Forward declarations
typedef struct CardinalWindow CardinalWindow;
typedef struct CardinalRenderer CardinalRenderer;

#ifdef __cplusplus
extern "C" {
#endif

bool editor_layer_init(CardinalWindow* window, CardinalRenderer* renderer);
void editor_layer_update(void);
void editor_layer_render(void);
void editor_layer_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif // EDITOR_LAYER_H