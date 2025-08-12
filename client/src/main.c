#include <cardinal/cardinal.h>
#include <cardinal/core/log.h>
#include <string.h>
#include <stdio.h>

static void print_usage(const char* program_name) {
    printf("Usage: %s [options]\n", program_name);
    printf("Options:\n");
    printf("  --log-level <level>  Set log level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)\n");
    printf("  --help               Show this help message\n");
}

int main(int argc, char* argv[]) {
    CardinalLogLevel log_level = CARDINAL_LOG_LEVEL_WARN; // Default
    
    // Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--log-level") == 0 && i + 1 < argc) {
            log_level = cardinal_log_parse_level(argv[i + 1]);
            i++; // Skip the next argument
        } else if (strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        }
    }
    
    cardinal_log_init_with_level(log_level);
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
