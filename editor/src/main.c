#include <cardinal/cardinal.h>
#include <cardinal/core/log.h>
#include "editor_layer.h"

int main(void) {
    cardinal_log_init();
    CardinalWindowConfig config = {
        .title = "Cardinal Editor",
        .width = 1600,
        .height = 900,
        .resizable = true
    };
    CardinalWindow* window = cardinal_window_create(&config);
    if (!window) { cardinal_log_shutdown(); return -1; }

    CardinalRenderer renderer;
    if (!cardinal_renderer_create(&renderer, window)) {
        cardinal_window_destroy(window);
        cardinal_log_shutdown();
        return -1;
    }

    // Initialize editor layer with ImGui
    if (!editor_layer_init(window, &renderer)) {
        cardinal_renderer_destroy(&renderer);
        cardinal_window_destroy(window);
        cardinal_log_shutdown();
        return -1;
    }

    while (!cardinal_window_should_close(window)) {
        cardinal_window_poll(window);
        
        editor_layer_update();
        editor_layer_render();
        
        cardinal_renderer_draw_frame(&renderer);
    }

    cardinal_renderer_wait_idle(&renderer);
    editor_layer_shutdown();
    cardinal_renderer_destroy(&renderer);
    cardinal_window_destroy(window);
    cardinal_log_shutdown();
    return 0;
}
