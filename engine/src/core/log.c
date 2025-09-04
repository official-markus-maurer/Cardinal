#include "cardinal/core/log.h"
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

// spdlog integration when CARDINAL_USE_SPDLOG is enabled
#if defined(CARDINAL_USE_SPDLOG) && defined(__cplusplus)
#include <algorithm>
#include <memory>
#include <mutex>
#include <spdlog/sinks/basic_file_sink.h>
#include <spdlog/sinks/rotating_file_sink.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/async.h>
#include <spdlog/spdlog.h>
#include <string>
#include <vector>

static std::shared_ptr<spdlog::logger> s_logger;
static std::once_flag s_spdlog_init_flag;
static bool s_spdlog_available = true;
static std::vector<spdlog::sink_ptr> s_runtime_sinks;

static void ensure_spdlog_logger(CardinalLogLevel level) {
    std::call_once(s_spdlog_init_flag, [level]() {
        try {
            // Initialize async mode for better performance
            spdlog::init_thread_pool(8192, 1);
            
            // Create console sink
            auto console_sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
            
            // Create rotating file sink (5MB max, 3 backup files)
            auto file_sink = std::make_shared<spdlog::sinks::rotating_file_sink_mt>(
                "build/cardinal_debug.log", 1024 * 1024 * 5, 3);
            
            // Store sinks for runtime modification
            s_runtime_sinks = {console_sink, file_sink};
            
            // Create async logger
            s_logger = std::make_shared<spdlog::async_logger>(
                "cardinal", s_runtime_sinks.begin(), s_runtime_sinks.end(),
                spdlog::thread_pool(), spdlog::async_overflow_policy::block);
            
            spdlog::register_logger(s_logger);

            spdlog::level::level_enum lvl = spdlog::level::info;
            switch (level) {
                case CARDINAL_LOG_LEVEL_TRACE: lvl = spdlog::level::trace; break;
                case CARDINAL_LOG_LEVEL_DEBUG: lvl = spdlog::level::debug; break;
                case CARDINAL_LOG_LEVEL_INFO: lvl = spdlog::level::info; break;
                case CARDINAL_LOG_LEVEL_WARN: lvl = spdlog::level::warn; break;
                case CARDINAL_LOG_LEVEL_ERROR: lvl = spdlog::level::err; break;
                case CARDINAL_LOG_LEVEL_FATAL: lvl = spdlog::level::critical; break;
            }
            s_logger->set_level(lvl);
            s_logger->flush_on(spdlog::level::warn);
            spdlog::set_default_logger(s_logger);
            spdlog::set_pattern("[%Y-%m-%d %H:%M:%S] [%^%l%$] %v");
        } catch (const std::exception &e) {
            s_spdlog_available = false;
            fprintf(stderr, "Failed to initialize spdlog: %s\n", e.what());
        }
    });
}
#else
// Fallback C implementation when spdlog is disabled
static FILE* s_log_file = NULL;
static bool s_spdlog_available = false;
#endif

static CardinalLogLevel s_min_log_level = CARDINAL_LOG_LEVEL_WARN;

static const char* level_str(CardinalLogLevel level) {
    switch (level) {
        case CARDINAL_LOG_LEVEL_TRACE: return "TRACE";
        case CARDINAL_LOG_LEVEL_DEBUG: return "DEBUG";
        case CARDINAL_LOG_LEVEL_INFO: return "INFO";
        case CARDINAL_LOG_LEVEL_WARN: return "WARN";
        case CARDINAL_LOG_LEVEL_ERROR: return "ERROR";
        case CARDINAL_LOG_LEVEL_FATAL: return "FATAL";
        default: return "UNKNOWN";
    }
}

void cardinal_log_init(void) {
    cardinal_log_init_with_level(s_min_log_level);
}

void cardinal_log_init_with_level(CardinalLogLevel min_level) {
    s_min_log_level = min_level;
    
#if defined(CARDINAL_USE_SPDLOG) && defined(__cplusplus)
    ensure_spdlog_logger(min_level);
    if (s_logger && s_spdlog_available) {
        s_logger->info("==== Cardinal Log Start (Level: {}) ====", level_str(min_level));
        return;
    }
#endif
    
    // Fallback C implementation - use build directory for log files
    if (!s_log_file) {
        // Try to create log in build directory first, fallback to current directory
        s_log_file = fopen("build/cardinal_debug.log", "w");
        if (!s_log_file) {
            s_log_file = fopen("cardinal_debug.log", "w");
        }
    }
    
    printf("==== Cardinal Log Start (Level: %s) ====\n", level_str(min_level));
    if (s_log_file) {
        fprintf(s_log_file, "==== Cardinal Log Start (Level: %s) ====\n", level_str(min_level));
        fflush(s_log_file);
    }
}

void cardinal_log_shutdown(void) {
#if defined(CARDINAL_USE_SPDLOG) && defined(__cplusplus)
    if (s_logger && s_spdlog_available) {
        s_logger->info("==== Cardinal Log End ====");
        spdlog::shutdown();
        return;
    }
#endif
    
    // Fallback C implementation
    printf("==== Cardinal Log End ====\n");
    if (s_log_file) {
        fprintf(s_log_file, "==== Cardinal Log End ====\n");
        fclose(s_log_file);
        s_log_file = NULL;
    }
}

void cardinal_log_set_level(CardinalLogLevel level) {
    s_min_log_level = level;
    
#if defined(CARDINAL_USE_SPDLOG) && defined(__cplusplus)
    if (s_logger && s_spdlog_available) {
        spdlog::level::level_enum lvl = spdlog::level::info;
        switch (level) {
            case CARDINAL_LOG_LEVEL_TRACE: lvl = spdlog::level::trace; break;
            case CARDINAL_LOG_LEVEL_DEBUG: lvl = spdlog::level::debug; break;
            case CARDINAL_LOG_LEVEL_INFO: lvl = spdlog::level::info; break;
            case CARDINAL_LOG_LEVEL_WARN: lvl = spdlog::level::warn; break;
            case CARDINAL_LOG_LEVEL_ERROR: lvl = spdlog::level::err; break;
            case CARDINAL_LOG_LEVEL_FATAL: lvl = spdlog::level::critical; break;
        }
        s_logger->set_level(lvl);
    }
#endif
}

CardinalLogLevel cardinal_log_get_level(void) {
    return s_min_log_level;
}

CardinalLogLevel cardinal_log_parse_level(const char* level_str_input) {
    if (!level_str_input) return CARDINAL_LOG_LEVEL_INFO;
    
    if (strcmp(level_str_input, "TRACE") == 0 || strcmp(level_str_input, "trace") == 0)
        return CARDINAL_LOG_LEVEL_TRACE;
    if (strcmp(level_str_input, "DEBUG") == 0 || strcmp(level_str_input, "debug") == 0)
        return CARDINAL_LOG_LEVEL_DEBUG;
    if (strcmp(level_str_input, "INFO") == 0 || strcmp(level_str_input, "info") == 0)
        return CARDINAL_LOG_LEVEL_INFO;
    if (strcmp(level_str_input, "WARN") == 0 || strcmp(level_str_input, "warn") == 0)
        return CARDINAL_LOG_LEVEL_WARN;
    if (strcmp(level_str_input, "ERROR") == 0 || strcmp(level_str_input, "error") == 0)
        return CARDINAL_LOG_LEVEL_ERROR;
    if (strcmp(level_str_input, "FATAL") == 0 || strcmp(level_str_input, "fatal") == 0)
        return CARDINAL_LOG_LEVEL_FATAL;
    
    return CARDINAL_LOG_LEVEL_INFO;
}

void cardinal_log_output(CardinalLogLevel level, const char* file, int line, const char* fmt, ...) {
    if (level < s_min_log_level) return;
    
    va_list args;
    va_start(args, fmt);
    
    char buffer[4096];
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    
    // Extract just the filename from the full path for cleaner output
    const char* filename = file;
    const char* last_slash = strrchr(file, '/');
    const char* last_backslash = strrchr(file, '\\');
    if (last_slash && last_backslash) {
        filename = (last_slash > last_backslash) ? last_slash + 1 : last_backslash + 1;
    } else if (last_slash) {
        filename = last_slash + 1;
    } else if (last_backslash) {
        filename = last_backslash + 1;
    }
    
    // Format for VS Code compatibility: file(line): [LEVEL] message
    char final_buffer[4096];
    snprintf(final_buffer, sizeof(final_buffer), "%s(%d): [%s] %s", filename, line, level_str(level), buffer);
    
#if defined(CARDINAL_USE_SPDLOG) && defined(__cplusplus)
    if (s_logger && s_spdlog_available) {
        // Use the same VS Code-friendly format for spdlog
        switch (level) {
            case CARDINAL_LOG_LEVEL_TRACE: s_logger->trace(final_buffer); break;
            case CARDINAL_LOG_LEVEL_DEBUG: s_logger->debug(final_buffer); break;
            case CARDINAL_LOG_LEVEL_INFO: s_logger->info(final_buffer); break;
            case CARDINAL_LOG_LEVEL_WARN: s_logger->warn(final_buffer); break;
            case CARDINAL_LOG_LEVEL_ERROR: s_logger->error(final_buffer); break;
            case CARDINAL_LOG_LEVEL_FATAL: s_logger->critical(final_buffer); break;
        }
        s_logger->flush(); // Force flush to ensure logs are written to file
        va_end(args);
        return;
    }
#endif
    
    // Fallback C implementation - output to stdout/stderr based on level
    FILE* output_stream = (level >= CARDINAL_LOG_LEVEL_ERROR) ? stderr : stdout;
    fprintf(output_stream, "%s\n", final_buffer);
    fflush(output_stream);
    
    if (s_log_file) {
        fprintf(s_log_file, "%s\n", final_buffer);
        fflush(s_log_file);
    }
    
    va_end(args);
}

// Runtime hook functions for spdlog management
#if defined(CARDINAL_USE_SPDLOG) && defined(__cplusplus)
void cardinal_log_add_sink(void* sink_ptr) {
    if (!s_logger || !s_spdlog_available || !sink_ptr) return;
    
    auto sink = static_cast<spdlog::sink_ptr*>(sink_ptr);
    s_runtime_sinks.push_back(*sink);
    
    // Recreate logger with new sinks
    s_logger = std::make_shared<spdlog::async_logger>(
        "cardinal", s_runtime_sinks.begin(), s_runtime_sinks.end(),
        spdlog::thread_pool(), spdlog::async_overflow_policy::block);
    spdlog::register_logger(s_logger);
}

void cardinal_log_remove_sink(void* sink_ptr) {
    if (!s_logger || !s_spdlog_available || !sink_ptr) return;
    
    auto sink = static_cast<spdlog::sink_ptr*>(sink_ptr);
    auto it = std::find(s_runtime_sinks.begin(), s_runtime_sinks.end(), *sink);
    if (it != s_runtime_sinks.end()) {
        s_runtime_sinks.erase(it);
        
        // Recreate logger with remaining sinks
        if (!s_runtime_sinks.empty()) {
            s_logger = std::make_shared<spdlog::async_logger>(
                "cardinal", s_runtime_sinks.begin(), s_runtime_sinks.end(),
                spdlog::thread_pool(), spdlog::async_overflow_policy::block);
            spdlog::register_logger(s_logger);
        }
    }
}

void cardinal_log_set_pattern(const char* pattern) {
    if (!s_logger || !s_spdlog_available || !pattern) return;
    s_logger->set_pattern(pattern);
}

void* cardinal_log_create_file_sink(const char* filename) {
    if (!filename) return NULL;
    try {
        auto sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>(filename, true);
        return new spdlog::sink_ptr(sink);
    } catch (const std::exception&) {
        return NULL;
    }
}

void* cardinal_log_create_rotating_sink(const char* filename, size_t max_size, size_t max_files) {
    if (!filename) return NULL;
    try {
        auto sink = std::make_shared<spdlog::sinks::rotating_file_sink_mt>(filename, max_size, max_files);
        return new spdlog::sink_ptr(sink);
    } catch (const std::exception&) {
        return NULL;
    }
}

void cardinal_log_destroy_sink(void* sink_ptr) {
    if (sink_ptr) {
        delete static_cast<spdlog::sink_ptr*>(sink_ptr);
    }
}
#else
// Stub implementations when spdlog is disabled
void cardinal_log_add_sink(void* sink_ptr) { (void)sink_ptr; }
void cardinal_log_remove_sink(void* sink_ptr) { (void)sink_ptr; }
void cardinal_log_set_pattern(const char* pattern) { (void)pattern; }
void* cardinal_log_create_file_sink(const char* filename) { (void)filename; return NULL; }
void* cardinal_log_create_rotating_sink(const char* filename, size_t max_size, size_t max_files) { 
    (void)filename; (void)max_size; (void)max_files; return NULL; 
}
void cardinal_log_destroy_sink(void* sink_ptr) { (void)sink_ptr; }
#endif

#ifdef __cplusplus
}
#endif
