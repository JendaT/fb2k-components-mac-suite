//
//  URLUtils.h
//  foo_jl_tidal_mac
//
//  URL parsing utilities for tidal:// protocol
//

#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <optional>

namespace tidal {

/// Type of Tidal content
enum class TidalContentType {
    Unknown,
    Track,
    Album,
    Playlist,
    Artist
};

/// Parsed Tidal URL
struct TidalURL {
    TidalContentType type;
    std::string id;
    std::string originalURL;

    bool isValid() const {
        return type != TidalContentType::Unknown && !id.empty();
    }
};

/// Parse a tidal:// URL
/// Supports formats:
///   - tidal://track/123456
///   - tidal://album/123456
///   - tidal://playlist/abc-def-123
///   - https://tidal.com/browse/track/123456
///   - https://listen.tidal.com/track/123456
std::optional<TidalURL> parseURL(const std::string& url);

/// Convert internal tidal:// URL back to external URL
std::string toExternalURL(const TidalURL& url);

/// Create internal URL for a track ID
std::string makeTrackURL(const std::string& trackID);

/// Check if a path is a Tidal URL
bool isTidalURL(const char* path);

} // namespace tidal
