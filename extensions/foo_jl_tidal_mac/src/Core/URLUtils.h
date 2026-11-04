//
//  URLUtils.h
//  foo_jl_tidal_mac
//
//  URL parsing utilities for tidal:// protocol
//

#pragma once

#import <Foundation/Foundation.h>
#import "../API/TidalConstants.h"
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

    /// Quality pinned on this entry via "?q=<token>", empty when the entry
    /// carries no pin and playback should follow the global preference.
    std::optional<JLTidalQuality> quality;

    bool isValid() const {
        return type != TidalContentType::Unknown && !id.empty();
    }
};

/// Parse a tidal:// URL
/// Supports formats:
///   - tidal://track/123456
///   - tidal://track/123456?q=LOSSLESS   (quality pinned on the entry)
///   - tidal://album/123456
///   - tidal://playlist/abc-def-123
///   - https://tidal.com/browse/track/123456
///   - https://listen.tidal.com/track/123456
std::optional<TidalURL> parseURL(const std::string& url);

/// Convert internal tidal:// URL back to external URL
std::string toExternalURL(const TidalURL& url);

/// Create internal URL for a track ID
std::string makeTrackURL(const std::string& trackID);

/// Create internal URL for a track ID with a pinned quality, e.g.
/// "tidal://track/123456?q=LOSSLESS". The pin is a request, not a guarantee:
/// resolution still falls back when Tidal does not carry that tier.
std::string makeTrackURL(const std::string& trackID, JLTidalQuality quality);

/// Check if a path is a Tidal URL
bool isTidalURL(const char* path);

} // namespace tidal
