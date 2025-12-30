//
//  URLUtils.h
//  foo_jl_cloud_streamer_mac
//
//  URL type detection and conversion utilities
//

#pragma once

#include <string>
#include <optional>

namespace cloud_streamer {

// Cloud service types
enum class CloudService {
    Unknown,
    Mixcloud,
    SoundCloud
};

// URL type classification
enum class JLCloudURLType {
    Unknown,        // Not a recognized cloud URL
    Track,          // Single playable track
    Profile,        // User profile page (not supported)
    Playlist,       // Playlist/set (not supported)
    DJSet           // DJ set/mix (treated as single track)
};

// Result of URL parsing
struct ParsedCloudURL {
    CloudService service = CloudService::Unknown;
    JLCloudURLType type = JLCloudURLType::Unknown;
    std::string username;
    std::string slug;           // Track/playlist slug
    std::string originalURL;    // Original web URL
    std::string internalURL;    // Internal scheme URL (mixcloud:// or soundcloud://)
};

// Internal URL scheme prefixes
constexpr const char* kMixcloudScheme = "mixcloud://";
constexpr const char* kSoundCloudScheme = "soundcloud://";

// Web URL patterns
constexpr const char* kMixcloudHost = "mixcloud.com";
constexpr const char* kMixcloudWWWHost = "www.mixcloud.com";
constexpr const char* kSoundCloudHost = "soundcloud.com";
constexpr const char* kSoundCloudWWWHost = "www.soundcloud.com";

class URLUtils {
public:
    // Parse a URL (web or internal scheme) and classify it
    static ParsedCloudURL parseURL(const std::string& url);

    // Check if URL uses internal scheme (mixcloud:// or soundcloud://)
    static bool isInternalScheme(const std::string& url);

    // Check if URL is a web URL from supported services
    static bool isCloudWebURL(const std::string& url);

    // Convert web URL to internal scheme
    // Returns empty string if conversion fails
    static std::string webURLToInternalScheme(const std::string& webURL);

    // Convert internal scheme to web URL for yt-dlp
    static std::string internalSchemeToWebURL(const std::string& internalURL);

    // Get the service from a URL
    static CloudService getService(const std::string& url);

    // Check if URL type is playable (Track or DJSet)
    static bool isPlayableType(JLCloudURLType type);

    // Get human-readable service name
    static const char* serviceName(CloudService service);

    // Decode URL-encoded string (e.g., %C5%AF -> ů)
    static std::string decodeURLComponent(const std::string& encoded);

private:
    static ParsedCloudURL parseMixcloudURL(const std::string& path);
    static ParsedCloudURL parseSoundCloudURL(const std::string& path);
    static std::string extractPath(const std::string& url);
    static std::string extractHost(const std::string& url);
};

} // namespace cloud_streamer
