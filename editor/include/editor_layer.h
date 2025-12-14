#ifndef EDITOR_LAYER_H
#define EDITOR_LAYER_H

#include <stdbool.h>

// Forward declarations
typedef struct CardinalWindow CardinalWindow;
typedef struct CardinalRenderer CardinalRenderer;

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initializes the editor layer.
 *
 * @param window Pointer to the CardinalWindow.
 * @param renderer Pointer to the CardinalRenderer.
 * @return true if initialization was successful, false otherwise.
 *
 * @todo Document ImGui setup and Vulkan integration details.
 * @todo Add support for customizable UI themes.
 */
bool editor_layer_init(CardinalWindow *window, CardinalRenderer *renderer);
/**
 * @brief Updates the editor layer state.
 *
 * @todo Implement input handling for editor tools.
 * @todo Add undo/redo system integration.
 */
void editor_layer_update(void);
/**
 * @brief Renders the editor layer UI.
 *
 * @todo Optimize ImGui rendering performance.
 * @todo Add viewport rendering for scene preview.
 */
void editor_layer_render(void);

/**
 * @brief Process any pending scene uploads after frame rendering is complete.
 *
 * This ensures descriptor sets aren't recreated while command buffers are
 * executing.
 */
void editor_layer_process_pending_uploads(void);

/**
 * @brief Shuts down the editor layer and frees resources.
 *
 * @todo Ensure proper cleanup of ImGui resources.
 */
void editor_layer_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif // EDITOR_LAYER_H
