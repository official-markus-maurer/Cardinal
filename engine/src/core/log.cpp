#include "cardinal/core/log.h"
#include <memory>
#include <mutex>
#include <vector>
#include <string>
#include <spdlog/spdlog.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/sinks/basic_file_sink.h>

static CardinalLogLevel s_min_log_level = CARDINAL_LOG_LEVEL_WARN; // Default to WARN to reduce spam
static std::shared_ptr<spdlog::logger> s_logger;
static std::once_flag s_spdlog_init_flag;

/**
 * @brief Initializes the spdlog logger with console and file sinks.
 * @param level Initial log level to set.
 */
static void ensure_spdlog_logger(CardinalLogLevel level) {
    std::call_once(s_spdlog_init_flag, [level]() {
        try {
            auto console_sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
            auto file_sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>("cardinal_log.txt", true);
            std::vector<spdlog::sink_ptr> sinks { console_sink, file_sink };
            s_logger = std::make_shared<spdlog::logger>("cardinal", sinks.begin(), sinks.end());
            spdlog::register_logger(s_logger);
            
            // Map Cardinal log level to spdlog level
            spdlog::level::level_enum lvl = spdlog::level::info;
            switch (level) {
                case CARDINAL_LOG_LEVEL_TRACE: lvl = spdlog::level::trace; break;
                case CARDINAL_LOG_LEVEL_DEBUG: lvl = spdlog::level::debug; break;
                case CARDINAL_LOG_LEVEL_INFO:  lvl = spdlog::level::info;  break;
                case CARDINAL_LOG_LEVEL_WARN:  lvl = spdlog::level::warn;  break;
                case CARDINAL_LOG_LEVEL_ERROR: lvl = spdlog::level::err;   break;
                case CARDINAL_LOG_LEVEL_FATAL: lvl = spdlog::level::critical; break;
            }
            s_logger->set_level(lvl);
            s_logger->flush_on(spdlog::level::warn);
            spdlog::set_default_logger(s_logger);
            spdlog::set_pattern("[%Y-%m-%d %H:%M:%S] [%^%l%$] %v");
        } catch (const std::exception& e) {
            // If spdlog initialization fails, we can't log the error through spdlog
            // Fall back to basic console output
            fprintf(stderr, "Failed to initialize spdlog: %s\n", e.what());
        }
    });
}

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
        default: return "UNKNOWN";
    }
}

extern "C" {

/**
 * @brief Initializes the logging system with default level.
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
    ensure_spdlog_logger(min_level);
    
    if (s_logger) {
        s_logger->info("==== Cardinal Log Start (Level: {}) ====", level_str(min_level));
    }
}

/**
 * @brief Sets the minimum log level.
 * @param min_level New minimum level.
 */
void cardinal_log_set_level(CardinalLogLevel min_level) {
    s_min_log_level = min_level;
    
    if (s_logger) {
        spdlog::level::level_enum lvl = spdlog::level::info;
        switch (min_level) {
            case CARDINAL_LOG_LEVEL_TRACE: lvl = spdlog::level::trace; break;
            case CARDINAL_LOG_LEVEL_DEBUG: lvl = spdlog::level::debug; break;
            case CARDINAL_LOG_LEVEL_INFO:  lvl = spdlog::level::info;  break;
            case CARDINAL_LOG_LEVEL_WARN:  lvl = spdlog::level::warn;  break;
            case CARDINAL_LOG_LEVEL_ERROR: lvl = spdlog::level::err;   break;
            case CARDINAL_LOG_LEVEL_FATAL: lvl = spdlog::level::critical; break;
        }
        s_logger->set_level(lvl);
        s_logger->info("[LOG] Log level changed to: {}", level_str(min_level));
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
    if (s_logger) {
        s_logger->info("==== Cardinal Log End ====");
        s_logger->flush();
        s_logger.reset();
    }
    spdlog::shutdown();
}

/**
 * @brief Outputs a log message.
 * @param level Log level.
 * @param file Source file.
 * @param line Line number.
 * @param fmt Format string.
 * @param ... Arguments.
 */
void cardinal_log_output(CardinalLogLevel level, const char* file, int line, const char* fmt, ...) {
    // Filter based on minimum log level
    if (level < s_min_log_level) {
        return;
    }

    if (!s_logger) {
        // If logger is not initialized, try to initialize it
        ensure_spdlog_logger(s_min_log_level);
        if (!s_logger) {
            return; // Still failed, can't log
        }
    }

    // Build formatted message using vsnprintf into buffer
    char msgbuf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(msgbuf, sizeof(msgbuf), fmt, args);
    va_end(args);

    // Log through spdlog
    switch (level) {
        case CARDINAL_LOG_LEVEL_TRACE: s_logger->trace("{}:{}: {}", file, line, msgbuf); break;
        case CARDINAL_LOG_LEVEL_DEBUG: s_logger->debug("{}:{}: {}", file, line, msgbuf); break;
        case CARDINAL_LOG_LEVEL_INFO:  s_logger->info ("{}:{}: {}", file, line, msgbuf); break;
        case CARDINAL_LOG_LEVEL_WARN:  s_logger->warn ("{}:{}: {}", file, line, msgbuf); break;
        case CARDINAL_LOG_LEVEL_ERROR: s_logger->error("{}:{}: {}", file, line, msgbuf); break;
        case CARDINAL_LOG_LEVEL_FATAL: s_logger->critical("{}:{}: {}", file, line, msgbuf); break;
    }

    if (level == CARDINAL_LOG_LEVEL_FATAL) {
        s_logger->flush();
#ifdef _DEBUG
        abort();
#endif
    }
}

} // extern "C"
