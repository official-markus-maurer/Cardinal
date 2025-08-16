/**
 * @file log.h
 * @brief Logging system for Cardinal Engine
 *
 * This module provides a comprehensive logging system with multiple severity
 * levels, runtime level filtering, and convenient macros for easy use
 * throughout the engine. The logging system supports both debug and release
 * builds with different behavior.
 *
 * Features:
 * - Multiple log levels (TRACE, DEBUG, INFO, WARN, ERROR, FATAL)
 * - Runtime log level filtering
 * - File and line number tracking
 * - Debug/Release build optimizations
 * - Thread-safe logging operations
 * - Convenient macro interface
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_CORE_LOG_H
#define CARDINAL_CORE_LOG_H

#include <stdarg.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Log severity levels
 *
 * Defines the different severity levels for logging messages. Lower numeric
 * values indicate more verbose logging levels. The logging system can be
 * configured to filter out messages below a certain level.
 */
typedef enum {
  CARDINAL_LOG_LEVEL_TRACE = 0, /**< Most verbose level for detailed tracing */
  CARDINAL_LOG_LEVEL_DEBUG = 1, /**< Debug information for development */
  CARDINAL_LOG_LEVEL_INFO = 2,  /**< General informational messages */
  CARDINAL_LOG_LEVEL_WARN = 3,  /**< Warning messages for potential issues */
  CARDINAL_LOG_LEVEL_ERROR = 4, /**< Error messages for recoverable failures */
  CARDINAL_LOG_LEVEL_FATAL = 5  /**< Fatal errors that may cause termination */
} CardinalLogLevel;

/**
 * @brief Initialize the logging system with default settings
 *
 * Initializes the logging system with INFO level as the minimum log level.
 * This function should be called once at application startup before any
 * logging operations.
 */
void cardinal_log_init(void);

/**
 * @brief Initialize the logging system with a specific minimum log level
 *
 * Initializes the logging system and sets the minimum log level. Messages
 * below this level will be filtered out and not displayed.
 *
 * @param min_level Minimum log level to display
 */
void cardinal_log_init_with_level(CardinalLogLevel min_level);

/**
 * @brief Set the runtime minimum log level
 *
 * Changes the minimum log level at runtime. This allows dynamic control
 * over logging verbosity without restarting the application.
 *
 * @param min_level New minimum log level to display
 */
void cardinal_log_set_level(CardinalLogLevel min_level);

/**
 * @brief Get the current minimum log level
 *
 * Returns the currently configured minimum log level that determines
 * which messages are displayed.
 *
 * @return Current minimum log level
 */
CardinalLogLevel cardinal_log_get_level(void);

/**
 * @brief Shutdown the logging system
 *
 * Cleans up the logging system and releases any resources. Should be
 * called once at application shutdown after all logging operations
 * are complete.
 */
void cardinal_log_shutdown(void);

/**
 * @brief Core logging function for outputting messages
 *
 * This is the main logging function that handles message formatting and
 * output. It includes file and line information for debugging purposes.
 * Typically not called directly - use the logging macros instead.
 *
 * @param level Severity level of the message
 * @param file Source file name where the log was called
 * @param line Line number where the log was called
 * @param fmt Printf-style format string
 * @param ... Variable arguments for format string
 *
 * @see CARDINAL_LOG_TRACE, CARDINAL_LOG_DEBUG, CARDINAL_LOG_INFO
 * @see CARDINAL_LOG_WARN, CARDINAL_LOG_ERROR, CARDINAL_LOG_FATAL
 */
void cardinal_log_output(CardinalLogLevel level, const char *file, int line,
                         const char *fmt, ...);

/**
 * @brief Parse log level from string representation
 *
 * Converts a string representation of a log level to the corresponding
 * enum value. Useful for parsing command line arguments or configuration
 * files. Case-insensitive matching is performed.
 *
 * Supported strings: "trace", "debug", "info", "warn", "error", "fatal"
 *
 * @param level_str String representation of the log level
 * @return Corresponding CardinalLogLevel enum value, or CARDINAL_LOG_LEVEL_INFO
 * if invalid
 */
CardinalLogLevel cardinal_log_parse_level(const char *level_str);

/**
 * @defgroup LoggingMacros Logging Macros
 * @brief Convenient macros for logging at different severity levels
 *
 * These macros provide an easy-to-use interface for logging messages.
 * They automatically include file and line information and handle
 * different behavior between debug and release builds.
 *
 * In debug builds (_DEBUG defined):
 * - All log levels are active
 * - Messages include full file path and line numbers
 *
 * In release builds:
 * - TRACE, DEBUG, and INFO are compiled out (no-op)
 * - Only WARN, ERROR, and FATAL messages are logged
 * - Optimized for performance
 *
 * Usage example:
 * @code
 * CARDINAL_LOG_INFO("Engine initialized successfully");
 * CARDINAL_LOG_WARN("Low memory warning: %d MB remaining", memory_mb);
 * CARDINAL_LOG_ERROR("Failed to load texture: %s", filename);
 * @endcode
 *
 * @{
 */

// Suppress GNU extension warnings for variadic macros
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu-zero-variadic-macro-arguments"

#ifdef _DEBUG
/** @brief Log trace message (debug builds only) */
#define CARDINAL_LOG_TRACE(fmt, ...)                                           \
  cardinal_log_output(CARDINAL_LOG_LEVEL_TRACE, __FILE__, __LINE__, fmt,       \
                      ##__VA_ARGS__)
/** @brief Log debug message (debug builds only) */
#define CARDINAL_LOG_DEBUG(fmt, ...)                                           \
  cardinal_log_output(CARDINAL_LOG_LEVEL_DEBUG, __FILE__, __LINE__, fmt,       \
                      ##__VA_ARGS__)
/** @brief Log info message (debug builds only) */
#define CARDINAL_LOG_INFO(fmt, ...)                                            \
  cardinal_log_output(CARDINAL_LOG_LEVEL_INFO, __FILE__, __LINE__, fmt,        \
                      ##__VA_ARGS__)
/** @brief Log warning message */
#define CARDINAL_LOG_WARN(fmt, ...)                                            \
  cardinal_log_output(CARDINAL_LOG_LEVEL_WARN, __FILE__, __LINE__, fmt,        \
                      ##__VA_ARGS__)
/** @brief Log error message */
#define CARDINAL_LOG_ERROR(fmt, ...)                                           \
  cardinal_log_output(CARDINAL_LOG_LEVEL_ERROR, __FILE__, __LINE__, fmt,       \
                      ##__VA_ARGS__)
/** @brief Log fatal error message */
#define CARDINAL_LOG_FATAL(fmt, ...)                                           \
  cardinal_log_output(CARDINAL_LOG_LEVEL_FATAL, __FILE__, __LINE__, fmt,       \
                      ##__VA_ARGS__)
#else
// In release builds, only allow WARN, ERROR, and FATAL logs
/** @brief Log trace message (no-op in release builds) */
#define CARDINAL_LOG_TRACE(fmt, ...) ((void)0)
/** @brief Log debug message (no-op in release builds) */
#define CARDINAL_LOG_DEBUG(fmt, ...) ((void)0)
/** @brief Log info message (no-op in release builds) */
#define CARDINAL_LOG_INFO(fmt, ...) ((void)0)
/** @brief Log warning message */
#define CARDINAL_LOG_WARN(fmt, ...)                                            \
  cardinal_log_output(CARDINAL_LOG_LEVEL_WARN, __FILE__, __LINE__, fmt,        \
                      ##__VA_ARGS__)
/** @brief Log error message */
#define CARDINAL_LOG_ERROR(fmt, ...)                                           \
  cardinal_log_output(CARDINAL_LOG_LEVEL_ERROR, __FILE__, __LINE__, fmt,       \
                      ##__VA_ARGS__)
/** @brief Log fatal error message */
#define CARDINAL_LOG_FATAL(fmt, ...)                                           \
  cardinal_log_output(CARDINAL_LOG_LEVEL_FATAL, __FILE__, __LINE__, fmt,       \
                      ##__VA_ARGS__)
#endif

#pragma clang diagnostic pop

/**
 * @brief Convenience macros with shorter names
 *
 * These macros provide shorter aliases for the main logging macros,
 * making code more concise while maintaining the same functionality.
 *
 * @{
 */
#define LOG_TRACE                                                              \
  CARDINAL_LOG_TRACE /**< Short alias for CARDINAL_LOG_TRACE                   \
                      */
#define LOG_DEBUG                                                              \
  CARDINAL_LOG_DEBUG               /**< Short alias for CARDINAL_LOG_DEBUG     \
                                    */
#define LOG_INFO CARDINAL_LOG_INFO /**< Short alias for CARDINAL_LOG_INFO */
#define LOG_WARN CARDINAL_LOG_WARN /**< Short alias for CARDINAL_LOG_WARN */
#define LOG_ERROR                                                              \
  CARDINAL_LOG_ERROR /**< Short alias for CARDINAL_LOG_ERROR                   \
                      */
#define LOG_FATAL                                                              \
  CARDINAL_LOG_FATAL /**< Short alias for CARDINAL_LOG_FATAL                   \
                      */
/** @} */

/** @} */ // End of LoggingMacros group

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_LOG_H
