//
//  CloudConfig.h
//  foo_jl_cloud_streamer_mac
//
//  Configuration storage using fb2k::configStore (persists on macOS)
//

#pragma once

#include "../fb2k_sdk.h"
#include <string>

namespace cloud_streamer {

// Configuration key prefix
static const char* const kConfigPrefix = "foo_jl_cloud_streamer.";

// Configuration keys
static const char* const kYtDlpPath = "ytdlp_path";
static const char* const kMixcloudFormat = "mixcloud_format";
static const char* const kSoundCloudFormat = "soundcloud_format";
static const char* const kCacheStreamUrls = "cache_stream_urls";
static const char* const kDebugLogging = "debug_logging";
static const char* const kStreamCacheTTLMixcloud = "stream_cache_ttl_mixcloud";
static const char* const kStreamCacheTTLSoundCloud = "stream_cache_ttl_soundcloud";

// Format options
enum class MixcloudFormat {
    Default = 0,    // HTTP (64kbps AAC - service maximum)
    HLS = 1         // HLS (if supported)
};

enum class SoundCloudFormat {
    HLS_AAC = 0,    // HLS 160kbps AAC (best quality without auth)
    HTTP_MP3 = 1    // HTTP 128kbps MP3 (fallback)
};

// Default TTL values in seconds
constexpr int kDefaultStreamCacheTTLMixcloud = 4 * 60 * 60;     // 4 hours
constexpr int kDefaultStreamCacheTTLSoundCloud = 2 * 60 * 60;   // 2 hours

class CloudConfig {
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

    // yt-dlp path (empty if not configured)
    static std::string getYtDlpPath();
    static void setYtDlpPath(const std::string& path);

    // Mixcloud format preference
    static MixcloudFormat getMixcloudFormat();
    static void setMixcloudFormat(MixcloudFormat format);

    // SoundCloud format preference
    static SoundCloudFormat getSoundCloudFormat();
    static void setSoundCloudFormat(SoundCloudFormat format);

    // Stream URL caching enabled
    static bool isCacheEnabled();
    static void setCacheEnabled(bool enabled);

    // Debug logging enabled
    static bool isDebugLoggingEnabled();
    static void setDebugLoggingEnabled(bool enabled);

    // Stream cache TTL (in seconds)
    static int getStreamCacheTTL(bool isMixcloud);
    static void setStreamCacheTTL(bool isMixcloud, int seconds);

    // Try to find yt-dlp in standard locations
    static std::string detectYtDlpPath();
};

// Debug logging helper
inline void logDebug(const char* message) {
    if (CloudConfig::isDebugLoggingEnabled()) {
        std::string msg = "[Cloud Streamer] ";
        msg += message;
        console::info(msg.c_str());
    }
}

inline void logDebug(const std::string& message) {
    logDebug(message.c_str());
}

} // namespace cloud_streamer
