#include <cardinal/cardinal.h>
#include <cardinal/core/log.h>
#include <cardinal/core/memory.h>
#include <cardinal/core/async_loader.h>
#include <cardinal/assets/texture_loader.h>
#include <cardinal/assets/mesh_loader.h>
#include <cardinal/assets/material_loader.h>
#include <stdio.h>
#include <string.h>

/**
 * @brief Prints usage information for the program.
 *
 * @param program_name The name of the program.
 *
 * @todo Add more detailed help information and examples.
 */
static void print_usage(const char* program_name) {
    printf("Usage: %s [options]\n", program_name);
    printf("Options:\n");
    printf("  --log-level <level>  Set log level (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)\n");
    printf("  --help               Show this help message\n");
}

/**
 * @brief Main entry point for the Cardinal Client application.
 *
 * @param argc Number of command-line arguments.
 * @param argv Array of command-line arguments.
 * @return Exit code (0 for success).
 *
 * @todo Implement advanced command-line parsing library.
 * @todo Add support for configuration files.
 * @todo Integrate profiling and performance metrics.
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

    cardinal_log_init_with_level(log_level);
    
    // Initialize memory system
    cardinal_memory_init(1024 * 1024 * 64); // 64MB default capacity
    
    // Initialize async loader with multi-threading support
    CardinalAsyncLoaderConfig async_config = {
        .worker_thread_count = 4,
        .max_queue_size = 256,
        .enable_priority_queue = true
    };
    
    if (!cardinal_async_loader_init(&async_config)) {
        CARDINAL_LOG_ERROR("Failed to initialize async loader");
        cardinal_memory_shutdown();
        cardinal_log_shutdown();
        return -1;
    }
    
    // Initialize asset caches with multi-threading support
    texture_cache_initialize(1000);
    mesh_cache_initialize(1000);
    material_cache_initialize(1000);
    
    CARDINAL_LOG_INFO("Multi-threaded engine initialized successfully");
    
    // Create a window
    CardinalWindowConfig config = {
        .title = "Cardinal Client", .width = 1024, .height = 768, .resizable = true};

    CardinalWindow* window = cardinal_window_create(&config);
    if (!window) {
        cardinal_log_shutdown();
        return -1;
    }

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
    
    // Shutdown multi-threaded systems
    CARDINAL_LOG_INFO("Shutting down multi-threaded engine systems");
    
    // Shutdown asset caches
    texture_cache_shutdown_system();
    mesh_cache_shutdown_system();
    material_cache_shutdown_system();
    
    // Shutdown async loader
    cardinal_async_loader_shutdown();
    
    // Shutdown memory system
    cardinal_memory_shutdown();
    
    cardinal_log_shutdown();

    return 0;
}
