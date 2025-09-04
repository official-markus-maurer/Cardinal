#include "editor_layer.h"
#include <cardinal/cardinal.h>
#include <cardinal/core/async_loader.h>
#include <cardinal/core/log.h>
#include <cardinal/core/ref_counting.h>
#include <cardinal/core/resource_state.h>
#include <cardinal/assets/texture_loader.h>
#include <cardinal/assets/mesh_loader.h>
#include <cardinal/assets/material_loader.h>
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

    // Initialize memory management system
    LOG_INFO("Initializing memory management system...");
    cardinal_memory_init(4 * 1024 * 1024); // 4MB linear allocator
    LOG_INFO("Memory management system initialized");

    // Initialize reference counting system
    LOG_INFO("Initializing reference counting system...");
    if (!cardinal_ref_counting_init(1009)) {
        LOG_ERROR("Failed to initialize reference counting system");
        cardinal_memory_shutdown();
        cardinal_log_shutdown();
        return -1;
    }
    LOG_INFO("Reference counting system initialized");

    // Initialize resource state tracking system
    LOG_INFO("Initializing resource state tracking system...");
    if (!cardinal_resource_state_init(1009)) {
        LOG_ERROR("Failed to initialize resource state tracking system");
        cardinal_ref_counting_shutdown();
        cardinal_memory_shutdown();
        cardinal_log_shutdown();
        return -1;
    }
    LOG_INFO("Resource state tracking system initialized");

    // Initialize async loader system
    LOG_INFO("Initializing async loader system...");
    
    // Check memory allocator first
    if (!cardinal_get_allocator_for_category(CARDINAL_MEMORY_CATEGORY_ENGINE)) {
        LOG_ERROR("Engine memory allocator not available");
        cardinal_memory_shutdown();
        cardinal_log_shutdown();
        return -1;
    }
    LOG_INFO("Memory allocator check passed");
    
    CardinalAsyncLoaderConfig async_config = {
        .worker_thread_count = 2, // Reduce thread count for debugging
        .max_queue_size = 100,    // Reduce queue size for debugging
        .enable_priority_queue = true
    };
    
    LOG_INFO("About to call cardinal_async_loader_init...");
    if (!cardinal_async_loader_init(&async_config)) {
        LOG_ERROR("Failed to initialize async loader system");
        cardinal_memory_shutdown();
        cardinal_log_shutdown();
        return -1;
    }
    LOG_INFO("Async loader system initialized successfully");
    
    // Initialize asset caches with multi-threading support
    texture_cache_initialize(1000);
    mesh_cache_initialize(1000);
    material_cache_initialize(1000);
    
    LOG_INFO("Multi-threaded asset caches initialized successfully");

    CardinalWindowConfig config = {
        .title = "Cardinal Editor", .width = 1600, .height = 900, .resizable = true};
    CardinalWindow* window = cardinal_window_create(&config);
    if (!window) {
        cardinal_async_loader_shutdown();
        cardinal_memory_shutdown();
        cardinal_log_shutdown();
        return -1;
    }

    CardinalRenderer renderer;
    if (!cardinal_renderer_create(&renderer, window)) {
        cardinal_window_destroy(window);
        cardinal_async_loader_shutdown();
        cardinal_memory_shutdown();
        cardinal_log_shutdown();
        return -1;
    }

    // Initialize editor layer with ImGui
    if (!editor_layer_init(window, &renderer)) {
        cardinal_renderer_destroy(&renderer);
        cardinal_window_destroy(window);
        cardinal_async_loader_shutdown();
        cardinal_memory_shutdown();
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
    
    // Shutdown asset caches before async loader
    material_cache_shutdown_system();
    mesh_cache_shutdown_system();
    texture_cache_shutdown_system();
    
    cardinal_async_loader_shutdown();
    cardinal_memory_shutdown();
    cardinal_log_shutdown();
    return 0;
}
