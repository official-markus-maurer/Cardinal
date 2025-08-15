#include "editor_layer.h"
#include <cardinal/cardinal.h>
#include <cardinal/core/log.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
    #include <windows.h>
#endif

/**
 * @brief Prints usage information for the program.
 *
 * @param program_name The name of the program.
 *
 * @todo Add editor-specific command-line options.
 */
static void print_usage(const char* program_name) {
    printf("Usage: %s [options]\n", program_name);
    printf("Options:\n");
    printf("  --log-level <level>  Set log level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)\n");
    printf("  --help               Show this help message\n");
}

/**
 * @brief Main entry point for the Cardinal Editor application.
 *
 * @param argc Number of command-line arguments.
 * @param argv Array of command-line arguments.
 * @return Exit code (0 for success).
 *
 * @todo Implement cross-platform working directory setup.
 * @todo Add support for opening specific projects from command line.
 * @todo Integrate crash reporting and recovery.
 */
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

    // Ensure working directory is the executable's directory so relative asset paths resolve
#ifdef _WIN32
    {
        char exePath[MAX_PATH];
        DWORD len = GetModuleFileNameA(NULL, exePath, MAX_PATH);
        if (len > 0 && len < MAX_PATH) {
            // Strip filename to get directory
            for (int i = (int)len - 1; i >= 0; --i) {
                if (exePath[i] == '\\' || exePath[i] == '/') {
                    exePath[i] = '\0';
                    break;
                }
            }
            SetCurrentDirectoryA(exePath);
        }
    }
#endif

    cardinal_log_init_with_level(log_level);
    CardinalWindowConfig config = {
        .title = "Cardinal Editor", .width = 1600, .height = 900, .resizable = true};
    CardinalWindow* window = cardinal_window_create(&config);
    if (!window) {
        cardinal_log_shutdown();
        return -1;
    }

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
