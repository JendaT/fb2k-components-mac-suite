//
//  TidalLog.h
//  foo_jl_tidal_mac
//
//  Logging funnel with a pluggable backend. Foundation-only — no foobar2000
//  SDK dependency — so modules that log (ManifestParser, URLUtils, StreamCache)
//  compile standalone for unit tests. The default backend is a no-op; Main.mm
//  installs the fb2k console backend at component init.
//

#pragma once

#include <string>

namespace tidal {

enum class LogLevel { Debug, Info, Error };

// Backend receives the fully "[Tidal] "-prefixed message.
using LogBackend = void (*)(LogLevel level, const char* message);

// Pass nullptr to restore the no-op backend.
void setLogBackend(LogBackend backend);

// Cached debug-logging flag (avoids a configStore lookup on every logDebug).
// TidalConfig::refreshDebugLoggingCache() syncs it from the stored pref.
bool& debugLoggingCacheRef();

inline bool isDebugLoggingCached() {
    return debugLoggingCacheRef();
}

void logMessage(LogLevel level, const char* message);

// Debug logging helper (dropped unless debug logging is enabled)
inline void logDebug(const char* message) {
    if (isDebugLoggingCached()) {
        logMessage(LogLevel::Debug, message);
    }
}

inline void logDebug(const std::string& message) {
    logDebug(message.c_str());
}

// Always log (not conditional on debug mode)
inline void logInfo(const char* message) {
    logMessage(LogLevel::Info, message);
}

inline void logError(const char* message) {
    logMessage(LogLevel::Error, message);
}

} // namespace tidal
