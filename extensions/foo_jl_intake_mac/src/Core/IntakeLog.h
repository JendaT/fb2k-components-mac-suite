//
//  IntakeLog.h
//  foo_jl_intake
//
//  Logging funnel with a pluggable backend and a cached level. Plain C++ with
//  no foobar2000 SDK dependency, so every Core module can log and still link
//  standalone in the unit tests. Same design as foo_jl_tidal_mac's TidalLog.h:
//  the default backend is a no-op, and Integration installs the console
//  backend in on_init and removes it in on_quit (PLAN.md 3.2, 3.10).
//
//  Thread-safety: the backend and the level are atomics, so any thread may log
//  while another swaps the backend or changes the level. A message racing a
//  backend swap may still reach the previous backend, which must therefore
//  stay callable for the process lifetime (a plain function, as here).
//

#pragma once

#include <string>

namespace intake {

// Values match the `log_level` preference (PLAN.md 3.9): 0 to 2. A message is
// delivered when its level is at or below the threshold, so Error always
// passes and Debug only passes at the highest setting.
enum class LogLevel : int { Error = 0, Info = 1, Debug = 2 };

// Receives the fully "[intake] "-prefixed message.
using LogBackend = void (*)(LogLevel level, const char *message);

// Pass nullptr to restore the no-op backend.
void setLogBackend(LogBackend backend);

// Threshold. Defaults to Debug in DEBUG builds and Info otherwise. Callers
// set it from the cached preference; it is never read from configStore on a
// hot path. Values outside 0..2 are clamped.
void setLogLevel(LogLevel level);
void setLogLevel(int level);
LogLevel logLevel();

// True when a message at `level` would be delivered. Use it to skip building
// an expensive message (string formatting) that would be dropped anyway.
bool isLogEnabled(LogLevel level);

// Gated by the threshold, then prefixed and handed to the backend. A null
// message is logged as an empty one.
void logMessage(LogLevel level, const char *message);

inline void logError(const char *message) { logMessage(LogLevel::Error, message); }
inline void logInfo(const char *message) { logMessage(LogLevel::Info, message); }
inline void logDebug(const char *message) { logMessage(LogLevel::Debug, message); }

inline void logError(const std::string &message) { logError(message.c_str()); }
inline void logInfo(const std::string &message) { logInfo(message.c_str()); }
inline void logDebug(const std::string &message) { logDebug(message.c_str()); }

} // namespace intake
