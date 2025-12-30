//
//  URLUtils.mm
//  foo_jl_cloud_streamer_mac
//
//  URL type detection and conversion utilities
//

#import <Foundation/Foundation.h>
#include "URLUtils.h"
#include <algorithm>
#include <sstream>

namespace cloud_streamer {

ParsedCloudURL URLUtils::parseURL(const std::string& url) {
    ParsedCloudURL result;
    result.originalURL = url;

    if (url.empty()) {
        return result;
    }

    // Check for internal scheme first
    if (url.find(kMixcloudScheme) == 0) {
        result.service = CloudService::Mixcloud;
        std::string path = url.substr(strlen(kMixcloudScheme));

        // Decode URL-encoded characters (e.g., %C5%AF -> ů)
        path = decodeURLComponent(path);

        // Handle malformed URLs like mixcloud://www.mixcloud.com/user/track
        // Strip the host if accidentally included
        if (path.find("www.mixcloud.com/") == 0) {
            path = path.substr(strlen("www.mixcloud.com/"));
        } else if (path.find("mixcloud.com/") == 0) {
            path = path.substr(strlen("mixcloud.com/"));
        }

        ParsedCloudURL parsed = parseMixcloudURL(path);
        parsed.service = CloudService::Mixcloud;
        parsed.originalURL = url;
        // Rebuild correct internal URL
        if (!parsed.username.empty() && !parsed.slug.empty()) {
            parsed.internalURL = std::string(kMixcloudScheme) + parsed.username + "/" + parsed.slug;
        } else {
            parsed.internalURL = url;
        }
        return parsed;
    }

    if (url.find(kSoundCloudScheme) == 0) {
        result.service = CloudService::SoundCloud;
        std::string path = url.substr(strlen(kSoundCloudScheme));

        // Decode URL-encoded characters
        path = decodeURLComponent(path);

        // Handle malformed URLs like soundcloud://soundcloud.com/user/track
        if (path.find("www.soundcloud.com/") == 0) {
            path = path.substr(strlen("www.soundcloud.com/"));
        } else if (path.find("soundcloud.com/") == 0) {
            path = path.substr(strlen("soundcloud.com/"));
        }

        ParsedCloudURL parsed = parseSoundCloudURL(path);
        parsed.service = CloudService::SoundCloud;
        parsed.originalURL = url;
        // Rebuild correct internal URL
        if (!parsed.username.empty() && !parsed.slug.empty()) {
            parsed.internalURL = std::string(kSoundCloudScheme) + parsed.username + "/" + parsed.slug;
        } else {
            parsed.internalURL = url;
        }
        return parsed;
    }

    // Try to parse as web URL
    std::string host = extractHost(url);
    std::string path = extractPath(url);

    if (host == kMixcloudHost || host == kMixcloudWWWHost) {
        ParsedCloudURL parsed = parseMixcloudURL(path);
        parsed.service = CloudService::Mixcloud;
        parsed.originalURL = url;
        if (parsed.type == JLCloudURLType::Track || parsed.type == JLCloudURLType::DJSet) {
            parsed.internalURL = std::string(kMixcloudScheme) + parsed.username + "/" + parsed.slug;
        }
        return parsed;
    }

    if (host == kSoundCloudHost || host == kSoundCloudWWWHost) {
        ParsedCloudURL parsed = parseSoundCloudURL(path);
        parsed.service = CloudService::SoundCloud;
        parsed.originalURL = url;
        if (parsed.type == JLCloudURLType::Track) {
            parsed.internalURL = std::string(kSoundCloudScheme) + parsed.username + "/" + parsed.slug;
        }
        return parsed;
    }

    return result;
}

ParsedCloudURL URLUtils::parseMixcloudURL(const std::string& path) {
    ParsedCloudURL result;
    result.service = CloudService::Mixcloud;

    // Remove leading/trailing slashes
    std::string cleanPath = path;
    if (!cleanPath.empty() && cleanPath[0] == '/') {
        cleanPath = cleanPath.substr(1);
    }
    if (!cleanPath.empty() && cleanPath.back() == '/') {
        cleanPath = cleanPath.substr(0, cleanPath.length() - 1);
    }

    if (cleanPath.empty()) {
        result.type = JLCloudURLType::Unknown;
        return result;
    }

    // Split by /
    std::vector<std::string> parts;
    std::stringstream ss(cleanPath);
    std::string part;
    while (std::getline(ss, part, '/')) {
        if (!part.empty()) {
            parts.push_back(part);
        }
    }

    if (parts.empty()) {
        result.type = JLCloudURLType::Unknown;
        return result;
    }

    // Single part = profile
    if (parts.size() == 1) {
        result.type = JLCloudURLType::Profile;
        result.username = parts[0];
        return result;
    }

    // Check for special paths like /discover, /playlists, etc.
    if (parts[0] == "discover" || parts[0] == "search" || parts[0] == "categories") {
        result.type = JLCloudURLType::Unknown;
        return result;
    }

    // Check for playlist URLs
    if (parts.size() >= 2 && parts[1] == "playlists") {
        result.type = JLCloudURLType::Playlist;
        result.username = parts[0];
        if (parts.size() >= 3) {
            result.slug = parts[2];
        }
        return result;
    }

    // Two parts = username/track (DJ set)
    if (parts.size() == 2) {
        result.type = JLCloudURLType::Track;  // Mixcloud uses Track for DJ sets
        result.username = parts[0];
        result.slug = parts[1];
        return result;
    }

    // More parts - could be track with extra path
    result.type = JLCloudURLType::Track;
    result.username = parts[0];
    result.slug = parts[1];
    return result;
}

ParsedCloudURL URLUtils::parseSoundCloudURL(const std::string& path) {
    ParsedCloudURL result;
    result.service = CloudService::SoundCloud;

    // Remove leading/trailing slashes
    std::string cleanPath = path;
    if (!cleanPath.empty() && cleanPath[0] == '/') {
        cleanPath = cleanPath.substr(1);
    }
    if (!cleanPath.empty() && cleanPath.back() == '/') {
        cleanPath = cleanPath.substr(0, cleanPath.length() - 1);
    }

    if (cleanPath.empty()) {
        result.type = JLCloudURLType::Unknown;
        return result;
    }

    // Split by /
    std::vector<std::string> parts;
    std::stringstream ss(cleanPath);
    std::string part;
    while (std::getline(ss, part, '/')) {
        if (!part.empty()) {
            parts.push_back(part);
        }
    }

    if (parts.empty()) {
        result.type = JLCloudURLType::Unknown;
        return result;
    }

    // Single part = profile
    if (parts.size() == 1) {
        result.type = JLCloudURLType::Profile;
        result.username = parts[0];
        return result;
    }

    // Check for sets/playlists
    if (parts.size() >= 2 && parts[1] == "sets") {
        result.type = JLCloudURLType::Playlist;
        result.username = parts[0];
        if (parts.size() >= 3) {
            result.slug = parts[2];
        }
        return result;
    }

    // Check for special paths
    if (parts[0] == "discover" || parts[0] == "search" || parts[0] == "upload" ||
        parts[0] == "stream" || parts[0] == "charts") {
        result.type = JLCloudURLType::Unknown;
        return result;
    }

    // Two parts = username/track
    if (parts.size() == 2) {
        result.type = JLCloudURLType::Track;
        result.username = parts[0];
        result.slug = parts[1];
        return result;
    }

    // More parts - could be track with extra path
    result.type = JLCloudURLType::Track;
    result.username = parts[0];
    result.slug = parts[1];
    return result;
}

bool URLUtils::isInternalScheme(const std::string& url) {
    return url.find(kMixcloudScheme) == 0 || url.find(kSoundCloudScheme) == 0;
}

bool URLUtils::isCloudWebURL(const std::string& url) {
    std::string host = extractHost(url);
    return host == kMixcloudHost || host == kMixcloudWWWHost ||
           host == kSoundCloudHost || host == kSoundCloudWWWHost;
}

std::string URLUtils::webURLToInternalScheme(const std::string& webURL) {
    ParsedCloudURL parsed = parseURL(webURL);
    return parsed.internalURL;
}

std::string URLUtils::internalSchemeToWebURL(const std::string& internalURL) {
    // Use parseURL to normalize (handles malformed URLs with embedded hosts)
    ParsedCloudURL parsed = parseURL(internalURL);

    if (parsed.service == CloudService::Mixcloud &&
        !parsed.username.empty() && !parsed.slug.empty()) {
        return "https://www.mixcloud.com/" + parsed.username + "/" + parsed.slug + "/";
    }

    if (parsed.service == CloudService::SoundCloud &&
        !parsed.username.empty() && !parsed.slug.empty()) {
        return "https://soundcloud.com/" + parsed.username + "/" + parsed.slug;
    }

    return "";
}

CloudService URLUtils::getService(const std::string& url) {
    if (url.find(kMixcloudScheme) == 0) {
        return CloudService::Mixcloud;
    }
    if (url.find(kSoundCloudScheme) == 0) {
        return CloudService::SoundCloud;
    }

    std::string host = extractHost(url);
    if (host == kMixcloudHost || host == kMixcloudWWWHost) {
        return CloudService::Mixcloud;
    }
    if (host == kSoundCloudHost || host == kSoundCloudWWWHost) {
        return CloudService::SoundCloud;
    }

    return CloudService::Unknown;
}

bool URLUtils::isPlayableType(JLCloudURLType type) {
    return type == JLCloudURLType::Track || type == JLCloudURLType::DJSet;
}

const char* URLUtils::serviceName(CloudService service) {
    switch (service) {
        case CloudService::Mixcloud: return "Mixcloud";
        case CloudService::SoundCloud: return "SoundCloud";
        default: return "Unknown";
    }
}

std::string URLUtils::extractHost(const std::string& url) {
    @autoreleasepool {
        NSString* urlString = [NSString stringWithUTF8String:url.c_str()];
        NSURL* nsurl = [NSURL URLWithString:urlString];
        if (nsurl && nsurl.host) {
            return std::string([nsurl.host UTF8String]);
        }
    }
    return "";
}

std::string URLUtils::extractPath(const std::string& url) {
    @autoreleasepool {
        NSString* urlString = [NSString stringWithUTF8String:url.c_str()];
        NSURL* nsurl = [NSURL URLWithString:urlString];
        if (nsurl && nsurl.path) {
            return std::string([nsurl.path UTF8String]);
        }
    }
    return "";
}

std::string URLUtils::decodeURLComponent(const std::string& encoded) {
    @autoreleasepool {
        NSString* nsEncoded = [NSString stringWithUTF8String:encoded.c_str()];
        NSString* decoded = [nsEncoded stringByRemovingPercentEncoding];
        if (decoded) {
            return std::string([decoded UTF8String]);
        }
    }
    return encoded;  // Return original if decoding fails
}

} // namespace cloud_streamer
