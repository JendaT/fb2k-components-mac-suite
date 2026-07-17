//
//  URLUtils.mm
//  foo_jl_tidal_mac
//
//  URL parsing utilities implementation
//

#import "URLUtils.h"
#import "TidalErrors.h"
#include "TidalLog.h"
#import <Foundation/Foundation.h>
#include <cctype>

namespace tidal {

// Extracted IDs are spliced verbatim into authenticated API URL paths, so
// validate them at the parse boundary. NSURL.path percent-decodes, meaning
// a crafted entry like "tidal://track/1%2F..%2Fusers" arrives here with a
// literal "/" in the ID — accepting it would let a playlist entry redirect
// an authenticated request to an attacker-chosen path/query.
static bool isValidContentID(TidalContentType type, const std::string& id) {
    if (id.empty()) return false;
    switch (type) {
        case TidalContentType::Track:
        case TidalContentType::Album:
        case TidalContentType::Artist:
            // Numeric IDs only
            for (char c : id) {
                if (!isdigit(static_cast<unsigned char>(c))) return false;
            }
            return true;
        case TidalContentType::Playlist:
            // UUID charset: hex digits and dashes
            for (char c : id) {
                if (!isxdigit(static_cast<unsigned char>(c)) && c != '-') return false;
            }
            return true;
        default:
            // Conservative allowlist for any future content type
            for (char c : id) {
                if (!isalnum(static_cast<unsigned char>(c)) && c != '-') return false;
            }
            return true;
    }
}

std::optional<TidalURL> parseURL(const std::string& url) {
    if (url.empty()) {
        logDebug("parseURL: empty URL");
        return std::nullopt;
    }

    NSString *urlStr = [NSString stringWithUTF8String:url.c_str()];
    TidalURL result;
    result.originalURL = url;
    result.type = TidalContentType::Unknown;

    // Try parsing as URL
    NSURL *nsurl = [NSURL URLWithString:urlStr];
    if (!nsurl) {
        logDebug(("parseURL: NSURL creation failed for: " + url).c_str());
        return std::nullopt;
    }

    NSString *scheme = [nsurl.scheme lowercaseString];
    NSString *host = [nsurl.host lowercaseString];
    NSString *path = nsurl.path;

    // parseURL runs per playlist item in hot paths; skip the eager
    // NSString formatting unless debug logging is actually enabled.
    if (isDebugLoggingCached()) {
        logDebug([[NSString stringWithFormat:@"parseURL: scheme=%@, host=%@, path=%@",
                   scheme ?: @"(nil)", host ?: @"(nil)", path ?: @"(nil)"] UTF8String]);
    }

    // Handle tidal:// scheme
    if ([scheme isEqualToString:@"tidal"]) {
        // tidal://track/123456
        // Host is the content type, path has the ID
        if ([host isEqualToString:@"track"]) {
            result.type = TidalContentType::Track;
        } else if ([host isEqualToString:@"album"]) {
            result.type = TidalContentType::Album;
        } else if ([host isEqualToString:@"playlist"]) {
            result.type = TidalContentType::Playlist;
        } else if ([host isEqualToString:@"artist"]) {
            result.type = TidalContentType::Artist;
        }

        // ID is in path (e.g., "/123456")
        if (path.length > 1) {
            result.id = std::string([[path substringFromIndex:1] UTF8String]);
        }
    }
    // Handle https://tidal.com or https://listen.tidal.com
    else if ([scheme isEqualToString:@"https"]) {
        if ([host hasSuffix:@"tidal.com"]) {
            // Path format: /browse/track/123456 or /track/123456
            NSArray<NSString*> *components = [path componentsSeparatedByString:@"/"];
            // Find the content type and ID in path
            for (NSUInteger i = 0; i < components.count - 1; i++) {
                NSString *component = [components[i] lowercaseString];
                if ([component isEqualToString:@"track"]) {
                    result.type = TidalContentType::Track;
                    result.id = std::string([components[i + 1] UTF8String]);
                    break;
                } else if ([component isEqualToString:@"album"]) {
                    result.type = TidalContentType::Album;
                    result.id = std::string([components[i + 1] UTF8String]);
                    break;
                } else if ([component isEqualToString:@"playlist"]) {
                    result.type = TidalContentType::Playlist;
                    result.id = std::string([components[i + 1] UTF8String]);
                    break;
                } else if ([component isEqualToString:@"artist"]) {
                    result.type = TidalContentType::Artist;
                    result.id = std::string([components[i + 1] UTF8String]);
                    break;
                }
            }
        }
    }

    if (result.isValid()) {
        if (!isValidContentID(result.type, result.id)) {
            logDebug(("parseURL: rejected ID with invalid characters in: " + url).c_str());
            return std::nullopt;
        }
        return result;
    }

    return std::nullopt;
}

std::string toExternalURL(const TidalURL& url) {
    NSString *typeStr;
    switch (url.type) {
        case TidalContentType::Track:
            typeStr = @"track";
            break;
        case TidalContentType::Album:
            typeStr = @"album";
            break;
        case TidalContentType::Playlist:
            typeStr = @"playlist";
            break;
        case TidalContentType::Artist:
            typeStr = @"artist";
            break;
        default:
            return url.originalURL;
    }

    NSString *result = [NSString stringWithFormat:@"https://tidal.com/browse/%@/%s",
                        typeStr, url.id.c_str()];
    return std::string([result UTF8String]);
}

std::string makeTrackURL(const std::string& trackID) {
    NSString *result = [NSString stringWithFormat:@"tidal://track/%s", trackID.c_str()];
    return std::string([result UTF8String]);
}

bool isTidalURL(const char* path) {
    if (!path || !*path) return false;

    // Fast path: check prefix without allocating ObjC objects
    if (strncmp(path, "tidal://", 8) == 0) return true;

    // Only allocate for https URLs that might be tidal.com
    if (strncmp(path, "https://", 8) != 0) return false;

    NSString *urlStr = [NSString stringWithUTF8String:path];
    NSURL *nsurl = [NSURL URLWithString:urlStr];
    if (!nsurl) return false;

    // Check for user-facing tidal.com URLs (not CDN URLs like audio.tidal.com)
    NSString *host = [nsurl.host lowercaseString];
    if (host) {
        // Match: tidal.com, www.tidal.com, listen.tidal.com
        // Do NOT match: lgf.audio.tidal.com, *.audio.tidal.com (CDN URLs)
        if ([host isEqualToString:@"tidal.com"] ||
            [host isEqualToString:@"www.tidal.com"] ||
            [host isEqualToString:@"listen.tidal.com"]) {
            return true;
        }
    }

    return false;
}

} // namespace tidal
