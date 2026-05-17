//
//  TidalConfig.h
//  foo_jl_tidal_mac
//
//  Configuration storage using fb2k::configStore (persists on macOS)
//

#pragma once

#include "../fb2k_sdk.h"
#include "../API/TidalConstants.h"
#include <string>

namespace tidal {

// Configuration key prefix
static const char* const kConfigPrefix = "tidal.";

// Configuration keys
static const char* const kPreferredQuality = "preferred_quality";
static const char* const kDebugLogging = "debug_logging";
static const char* const kCacheStreamUrls = "cache_stream_urls";
static const char* const kDASHEnabled = "dash_enabled";

// Default values
constexpr int kDefaultPreferredQuality = static_cast<int>(JLTidalQualityHiResLossless);
#ifdef DEBUG
constexpr bool kDefaultDebugLogging = true;
#else
constexpr bool kDefaultDebugLogging = false;
#endif
constexpr bool kDefaultCacheStreamUrls = true;
constexpr bool kDefaultDASHEnabled = false;

class TidalConfig {
public:
    // Get full configuration key with prefix
    static pfc::string8 getFullKey(const char* key);

    // Type-safe getters with defaults
    static bool getConfigBool(const char* key, bool defaultVal);
    static int getConfigInt(const char* key, int defaultVal);
    static std::string getConfigString(const char* key, const char* defaultVal);

    // Type-safe setters
    static void setConfigBool(const char* key, bool value);
    static void setConfigInt(const char* key, int value);
    static void setConfigString(const char* key, const std::string& value);

    // Convenience accessors

    // Preferred audio quality
    static JLTidalQuality getPreferredQuality();
    static void setPreferredQuality(JLTidalQuality quality);

    // Debug logging enabled
    static bool isDebugLoggingEnabled();
    static void setDebugLoggingEnabled(bool enabled);

    // Stream URL caching enabled
    static bool isCacheEnabled();
    static void setCacheEnabled(bool enabled);

    // Experimental: enable DASH segment streaming for LOSSLESS/HiRes (default off).
    // When enabled, the decoder downloads all DASH segments for a track upfront,
    // assembles them into an in-memory fMP4 file, and hands it to fb2k's MP4
    // decoder. Untested across Tidal account types — leave off if playback breaks.
    static bool isDASHEnabled();
    static void setDASHEnabled(bool enabled);
};

// Cached debug logging state (avoids configStore lookup on every call)
// Call refreshDebugLoggingCache() after changing the setting.
inline bool& debugLoggingCacheRef() {
    static bool s_cached = kDefaultDebugLogging;
    return s_cached;
}

inline bool isDebugLoggingCached() {
    return debugLoggingCacheRef();
}

inline void refreshDebugLoggingCache() {
    debugLoggingCacheRef() = TidalConfig::isDebugLoggingEnabled();
}

// Debug logging helper
inline void logDebug(const char* message) {
    if (isDebugLoggingCached()) {
        std::string msg = "[Tidal] ";
        msg += message;
        console::info(msg.c_str());
    }
}

inline void logDebug(const std::string& message) {
    logDebug(message.c_str());
}

// Always log (not conditional on debug mode)
inline void logInfo(const char* message) {
    std::string msg = "[Tidal] ";
    msg += message;
    console::info(msg.c_str());
}

inline void logError(const char* message) {
    std::string msg = "[Tidal] ";
    msg += message;
    console::error(msg.c_str());
}

} // namespace tidal
