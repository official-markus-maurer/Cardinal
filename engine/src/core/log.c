#include "cardinal/core/log.h"
#include <time.h>
#include <string.h>
#include <stdlib.h>

static FILE* s_log_file = NULL;
static CardinalLogLevel s_min_log_level = CARDINAL_LOG_LEVEL_WARN; // Default to WARN to reduce spam

/**
 * @brief Returns string representation of log level.
 * @param level The log level.
 * @return String name of the level.
 */
static const char* level_str(CardinalLogLevel level) {
    switch (level) {
        case CARDINAL_LOG_LEVEL_TRACE: return "TRACE";
        case CARDINAL_LOG_LEVEL_DEBUG: return "DEBUG";
        case CARDINAL_LOG_LEVEL_INFO:  return "INFO";
        case CARDINAL_LOG_LEVEL_WARN:  return "WARN";
        case CARDINAL_LOG_LEVEL_ERROR: return "ERROR";
        case CARDINAL_LOG_LEVEL_FATAL: return "FATAL";
        default: return "?";
    }
}

/**
 * @brief Initializes the logging system with default level.
 * 
 * @todo Refactor to use a configurable logging backend (e.g., spdlog).
 */
void cardinal_log_init(void) {
    cardinal_log_init_with_level(s_min_log_level);
}

/**
 * @brief Initializes logging with specified minimum level.
 * @param min_level Minimum level to log.
 * 
 * @todo Integrate Vulkan debug utils extension (VK_EXT_debug_utils) for GPU-side logging.
 */
void cardinal_log_init_with_level(CardinalLogLevel min_level) {
    s_min_log_level = min_level;
    
#ifdef _DEBUG
    errno_t err = fopen_s(&s_log_file, "cardinal_log.txt", "w");
    if (err != 0 || !s_log_file) {
        err = fopen_s(&s_log_file, "cardinal_log.txt", "a");
    }
    if (s_log_file) {
        fprintf(s_log_file, "==== Cardinal Log Start (Level: %s) ====%s", level_str(min_level), "\n");
        fflush(s_log_file);
    }
#else
    // In release builds, we still create the log file to capture WARN/ERROR/FATAL if desired
    s_log_file = fopen("cardinal_log.txt", "a");
    if (s_log_file) {
        fprintf(s_log_file, "==== Cardinal Log Start (Level: %s) ====%s", level_str(min_level), "\n");
        fflush(s_log_file);
    }
#endif
}

/**
 * @brief Sets the minimum log level.
 * @param min_level New minimum level.
 */
void cardinal_log_set_level(CardinalLogLevel min_level) {
    s_min_log_level = min_level;
    if (s_log_file) {
        fprintf(s_log_file, "[LOG] Log level changed to: %s\n", level_str(min_level));
        fflush(s_log_file);
    }
}

/**
 * @brief Gets the current minimum log level.
 * @return Current log level.
 */
CardinalLogLevel cardinal_log_get_level(void) {
    return s_min_log_level;
}

/**
 * @brief Parses a string to a log level.
 * @param level_str_input String representation.
 * @return Corresponding log level or default.
 */
CardinalLogLevel cardinal_log_parse_level(const char* level_str_input) {
    if (!level_str_input) return CARDINAL_LOG_LEVEL_INFO;
    
    if (strcmp(level_str_input, "TRACE") == 0 || strcmp(level_str_input, "trace") == 0) return CARDINAL_LOG_LEVEL_TRACE;
    if (strcmp(level_str_input, "DEBUG") == 0 || strcmp(level_str_input, "debug") == 0) return CARDINAL_LOG_LEVEL_DEBUG;
    if (strcmp(level_str_input, "INFO") == 0 || strcmp(level_str_input, "info") == 0) return CARDINAL_LOG_LEVEL_INFO;
    if (strcmp(level_str_input, "WARN") == 0 || strcmp(level_str_input, "warn") == 0) return CARDINAL_LOG_LEVEL_WARN;
    if (strcmp(level_str_input, "ERROR") == 0 || strcmp(level_str_input, "error") == 0) return CARDINAL_LOG_LEVEL_ERROR;
    if (strcmp(level_str_input, "FATAL") == 0 || strcmp(level_str_input, "fatal") == 0) return CARDINAL_LOG_LEVEL_FATAL;
    
    return CARDINAL_LOG_LEVEL_INFO; // Default fallback
}

/**
 * @brief Shuts down the logging system.
 * 
 * @todo Ensure thread-safety for multi-threaded environments.
 */
void cardinal_log_shutdown(void) {
    if (s_log_file) {
        fprintf(s_log_file, "==== Cardinal Log End ====%s", "\n");
        fclose(s_log_file);
        s_log_file = NULL;
    }
}

/**
 * @brief Outputs a log message.
 * @param level Log level.
 * @param file Source file.
 * @param line Line number.
 * @param fmt Format string.
 * @param ... Arguments.
 * 
 * @todo Improve performance by implementing asynchronous logging.
 * @todo Add support for colored console output.
 */
void cardinal_log_output(CardinalLogLevel level, const char* file, int line, const char* fmt, ...) {
    // Filter based on minimum log level
    if (level < s_min_log_level) {
        return;
    }
    
    char timebuf[64];
    time_t t = time(NULL);
    struct tm tm_info;
#if defined(_WIN32)
    localtime_s(&tm_info, &t);
#else
    localtime_r(&t, &tm_info);
#endif
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%d %H:%M:%S", &tm_info);

    char msgbuf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(msgbuf, sizeof(msgbuf), fmt, args);
    va_end(args);

    // Console output
    FILE* out = (level >= CARDINAL_LOG_LEVEL_WARN) ? stderr : stdout;
    fprintf(out, "[%s] %-5s %s:%d: %s\n", timebuf, level_str(level), file, line, msgbuf);

    // File output
    if (s_log_file) {
        fprintf(s_log_file, "[%s] %-5s %s:%d: %s\n", timebuf, level_str(level), file, line, msgbuf);
        fflush(s_log_file);
    }

    if (level == CARDINAL_LOG_LEVEL_FATAL) {
        // For fatal error, flush and abort in debug builds to get a crash dump
#ifdef _DEBUG
        if (s_log_file) fflush(s_log_file);
        abort();
#endif
    }
}
