//
//  IntakeLog.mm
//  foo_jl_intake
//

#include "IntakeLog.h"

#include <atomic>

namespace intake {

namespace {

void noopBackend(LogLevel, const char *) {}

std::atomic<LogBackend> g_backend{noopBackend};

#ifdef DEBUG
constexpr int kDefaultLevel = static_cast<int>(LogLevel::Debug);
#else
constexpr int kDefaultLevel = static_cast<int>(LogLevel::Info);
#endif

std::atomic<int> g_level{kDefaultLevel};

int clampLevel(int level) {
    if (level < static_cast<int>(LogLevel::Error)) return static_cast<int>(LogLevel::Error);
    if (level > static_cast<int>(LogLevel::Debug)) return static_cast<int>(LogLevel::Debug);
    return level;
}

} // anonymous namespace

void setLogBackend(LogBackend backend) {
    g_backend.store(backend ? backend : noopBackend, std::memory_order_release);
}

void setLogLevel(int level) {
    g_level.store(clampLevel(level), std::memory_order_relaxed);
}

void setLogLevel(LogLevel level) {
    setLogLevel(static_cast<int>(level));
}

LogLevel logLevel() {
    return static_cast<LogLevel>(g_level.load(std::memory_order_relaxed));
}

bool isLogEnabled(LogLevel level) {
    return static_cast<int>(level) <= g_level.load(std::memory_order_relaxed);
}

void logMessage(LogLevel level, const char *message) {
    if (!isLogEnabled(level)) return;
    std::string msg = "[intake] ";
    if (message) msg += message;
    g_backend.load(std::memory_order_acquire)(level, msg.c_str());
}

} // namespace intake
