#include "cardinal/core/log.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

// C++ spdlog integration when compiled as C++
#ifdef __cplusplus
#include <memory>
#include <mutex>
#include <spdlog/sinks/basic_file_sink.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/spdlog.h>
#include <string>
#include <vector>

static std::shared_ptr<spdlog::logger> s_logger;
static std::once_flag s_spdlog_init_flag;
static bool s_spdlog_available = true;

static void ensure_spdlog_logger(CardinalLogLevel level) {
    std::call_once(s_spdlog_init_flag, [level]() {
        try {
            auto console_sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
            auto file_sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>("cardinal_log.txt", true);
            std::vector<spdlog::sink_ptr> sinks{console_sink, file_sink};
            s_logger = std::make_shared<spdlog::logger>("cardinal", sinks.begin(), sinks.end());
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
// Fallback C implementation
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
    
#ifdef __cplusplus
    ensure_spdlog_logger(min_level);
    if (s_logger && s_spdlog_available) {
        s_logger->info("==== Cardinal Log Start (Level: {}) ====", level_str(min_level));
        return;
    }
#endif
    
    // Fallback C implementation
    if (!s_log_file) {
        s_log_file = fopen("cardinal_log.txt", "w");
    }
    
    printf("==== Cardinal Log Start (Level: %s) ====\n", level_str(min_level));
    if (s_log_file) {
        fprintf(s_log_file, "==== Cardinal Log Start (Level: %s) ====\n", level_str(min_level));
        fflush(s_log_file);
    }
}

void cardinal_log_shutdown(void) {
#ifdef __cplusplus
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
    
#ifdef __cplusplus
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
    
    char final_buffer[4096];
    snprintf(final_buffer, sizeof(final_buffer), "%s:%d: %s", file, line, buffer);
    
#ifdef __cplusplus
    if (s_logger && s_spdlog_available) {
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
    
    // Fallback C implementation
    printf("[%s] %s\n", level_str(level), final_buffer);
    if (s_log_file) {
        fprintf(s_log_file, "[%s] %s\n", level_str(level), final_buffer);
        fflush(s_log_file);
    }
    
    va_end(args);
}

#ifdef __cplusplus
}
#endif
