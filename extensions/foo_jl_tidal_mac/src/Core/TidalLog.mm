//
//  TidalLog.mm
//  foo_jl_tidal_mac
//

#include "TidalLog.h"

namespace tidal {

namespace {

void noopBackend(LogLevel, const char*) {}

LogBackend g_backend = noopBackend;

} // anonymous namespace

void setLogBackend(LogBackend backend) {
    g_backend = backend ? backend : noopBackend;
}

bool& debugLoggingCacheRef() {
#ifdef DEBUG
    static bool s_cached = true;
#else
    static bool s_cached = false;
#endif
    return s_cached;
}

void logMessage(LogLevel level, const char* message) {
    std::string msg = "[Tidal] ";
    msg += message;
    g_backend(level, msg.c_str());
}

} // namespace tidal
