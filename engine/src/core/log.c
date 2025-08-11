#include "cardinal/core/log.h"
#include <time.h>
#include <string.h>
#include <stdlib.h>

static FILE* s_log_file = NULL;

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

void cardinal_log_init(void) {
#ifdef _DEBUG
    s_log_file = fopen("cardinal_log.txt", "w");
    if (!s_log_file) {
        s_log_file = fopen("cardinal_log.txt", "a");
    }
    if (s_log_file) {
        fprintf(s_log_file, "==== Cardinal Log Start ====%s", "\n");
        fflush(s_log_file);
    }
#else
    // In release builds, we still create the log file to capture WARN/ERROR/FATAL if desired
    s_log_file = fopen("cardinal_log.txt", "a");
#endif
}

void cardinal_log_shutdown(void) {
    if (s_log_file) {
        fprintf(s_log_file, "==== Cardinal Log End ====%s", "\n");
        fclose(s_log_file);
        s_log_file = NULL;
    }
}

void cardinal_log_output(CardinalLogLevel level, const char* file, int line, const char* fmt, ...) {
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