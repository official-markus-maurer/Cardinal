#include <cardinal/cardinal.h>
#include <cardinal/core/log.h>

int main(void) {
    cardinal_log_init();
    // Create a window
    CardinalWindowConfig config = {
        .title = "Cardinal Client",
        .width = 1024,
        .height = 768,
        .resizable = true
    };
    
    CardinalWindow* window = cardinal_window_create(&config);
    if (!window) { cardinal_log_shutdown(); return -1; }
    
    // Create renderer
    CardinalRenderer renderer;
    if (!cardinal_renderer_create(&renderer, window)) {
        cardinal_window_destroy(window);
        cardinal_log_shutdown();
        return -1;
    }
    
    // Main loop
    while (!cardinal_window_should_close(window)) {
        cardinal_window_poll(window);
        cardinal_renderer_draw_frame(&renderer);
    }
    
    // Cleanup
    cardinal_renderer_wait_idle(&renderer);
    cardinal_renderer_destroy(&renderer);
    cardinal_window_destroy(window);
    cardinal_log_shutdown();
    
    return 0;
}
