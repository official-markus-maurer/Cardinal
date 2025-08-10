#include <cardinal/cardinal.h>

int main(void) {
    CardinalWindowConfig config = {
        .title = "Cardinal Editor",
        .width = 1600,
        .height = 900,
        .resizable = true
    };
    CardinalWindow* window = cardinal_window_create(&config);
    if (!window) return -1;

    CardinalRenderer renderer;
    if (!cardinal_renderer_create(&renderer, window)) {
        cardinal_window_destroy(window);
        return -1;
    }

    while (!cardinal_window_should_close(window)) {
        cardinal_window_poll(window);
        cardinal_renderer_draw_frame(&renderer);
    }

    cardinal_renderer_wait_idle(&renderer);
    cardinal_renderer_destroy(&renderer);
    cardinal_window_destroy(window);
    return 0;
}
