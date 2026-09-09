//
//  TidalConfig.h
//  foo_jl_tidal_mac
//
//  Configuration storage using fb2k::configStore (persists on macOS)
//

#pragma once

#include "../fb2k_sdk.h"
#include "../API/TidalConstants.h"
#include "TidalLog.h"
#include <string>

namespace tidal {

// Configuration key prefix
static const char* const kConfigPrefix = "tidal.";

// Configuration keys
static const char* const kPreferredQuality = "preferred_quality";
static const char* const kDebugLogging = "debug_logging";
static const char* const kCacheStreamUrls = "cache_stream_urls";
static const char* const kDASHEnabled = "dash_enabled";
static const char* const kLibraryRoot = "library_root";
static const char* const kGenreMap = "genre_map";

// Default values
constexpr int kDefaultPreferredQuality = static_cast<int>(JLTidalQualityHiResLossless);
#ifdef DEBUG
constexpr bool kDefaultDebugLogging = true;
#else
constexpr bool kDefaultDebugLogging = false;
#endif
constexpr bool kDefaultCacheStreamUrls = true;
constexpr bool kDefaultDASHEnabled = true;

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

    // Enable DASH segment streaming for LOSSLESS/HiRes (default on, see
    // kDefaultDASHEnabled). When enabled, the decoder downloads all DASH
    // segments for a track upfront, assembles them into an in-memory fMP4
    // file, and hands it to fb2k's MP4 decoder. Disable if playback breaks.
    static bool isDASHEnabled();
    static void setDASHEnabled(bool enabled);

    // Personal library export ("Save to library"). Empty root disables the
    // feature entirely (context menu hidden) — this is the gate for now.
    static std::string getLibraryRoot();
    static void setLibraryRoot(const std::string& path);

    // Persisted artist -> genre-collection choices, serialized JSON object.
    static std::string getGenreMapJSON();
    static void setGenreMapJSON(const std::string& json);
};

// Sync the TidalLog debug-flag cache from the stored pref.
// Call after changing the setting (and once at component init).
inline void refreshDebugLoggingCache() {
    debugLoggingCacheRef() = TidalConfig::isDebugLoggingEnabled();
}

} // namespace tidal
