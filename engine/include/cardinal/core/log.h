#ifndef CARDINAL_CORE_LOG_H
#define CARDINAL_CORE_LOG_H

#include <stdio.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

// Log levels
typedef enum {
    CARDINAL_LOG_LEVEL_TRACE = 0,
    CARDINAL_LOG_LEVEL_DEBUG = 1,
    CARDINAL_LOG_LEVEL_INFO = 2,
    CARDINAL_LOG_LEVEL_WARN = 3,
    CARDINAL_LOG_LEVEL_ERROR = 4,
    CARDINAL_LOG_LEVEL_FATAL = 5
} CardinalLogLevel;

// Initialize logging system
void cardinal_log_init(void);

// Shutdown logging system
void cardinal_log_shutdown(void);

// Core logging function
void cardinal_log_output(CardinalLogLevel level, const char* file, int line, const char* fmt, ...);

// Macros for logging
#ifdef _DEBUG
    #define CARDINAL_LOG_TRACE(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_TRACE, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
    #define CARDINAL_LOG_DEBUG(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_DEBUG, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
    #define CARDINAL_LOG_INFO(fmt, ...)  cardinal_log_output(CARDINAL_LOG_LEVEL_INFO, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
    #define CARDINAL_LOG_WARN(fmt, ...)  cardinal_log_output(CARDINAL_LOG_LEVEL_WARN, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
    #define CARDINAL_LOG_ERROR(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_ERROR, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
    #define CARDINAL_LOG_FATAL(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_FATAL, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#else
    // In release builds, only allow WARN, ERROR, and FATAL logs
    #define CARDINAL_LOG_TRACE(fmt, ...) ((void)0)
    #define CARDINAL_LOG_DEBUG(fmt, ...) ((void)0)
    #define CARDINAL_LOG_INFO(fmt, ...)  ((void)0)
    #define CARDINAL_LOG_WARN(fmt, ...)  cardinal_log_output(CARDINAL_LOG_LEVEL_WARN, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
    #define CARDINAL_LOG_ERROR(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_ERROR, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
    #define CARDINAL_LOG_FATAL(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_FATAL, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#endif

// Convenience macros with shorter names
#define LOG_TRACE  CARDINAL_LOG_TRACE
#define LOG_DEBUG  CARDINAL_LOG_DEBUG
#define LOG_INFO   CARDINAL_LOG_INFO
#define LOG_WARN   CARDINAL_LOG_WARN
#define LOG_ERROR  CARDINAL_LOG_ERROR
#define LOG_FATAL  CARDINAL_LOG_FATAL

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_LOG_H