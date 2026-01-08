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

// Default values
constexpr int kDefaultPreferredQuality = static_cast<int>(JLTidalQualityHiResLossless);
constexpr bool kDefaultDebugLogging = true;  // TODO: set to false for release
constexpr bool kDefaultCacheStreamUrls = true;

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
};

// Debug logging helper
inline void logDebug(const char* message) {
    if (TidalConfig::isDebugLoggingEnabled()) {
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
