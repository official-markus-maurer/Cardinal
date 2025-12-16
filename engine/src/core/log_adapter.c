#include <cardinal/core/log.h>

void cardinal_log_from_zig(CardinalLogLevel level, const char *file, int line, const char *msg) {
    cardinal_log_output(level, file, line, "%s", msg);
}
