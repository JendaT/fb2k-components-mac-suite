//
//  ScrobbleRules.h
//  foo_scrobble_mac
//
//  Official Last.fm scrobbling rules implementation
//

#pragma once

#include <algorithm>
#include <cmath>

namespace ScrobbleRules {

// Track must be at least 30 seconds
constexpr double kMinTrackLength = 30.0;

// Scrobble after 50% of duration OR 4 minutes, whichever is first
constexpr double kMaxRequiredPlaytime = 240.0;  // 4 minutes
constexpr double kScrobblePercentage = 0.5;     // 50%

// Now Playing sent after 3 seconds
constexpr double kNowPlayingThreshold = 3.0;

// Maximum reasonable track length (24 hours)
constexpr double kMaxTrackLength = 86400.0;

// Earliest valid timestamp (Last.fm launch date: 2005-02-16)
constexpr int64_t kLastFmEpoch = 1108540800;

// Maximum field lengths for API
constexpr size_t kMaxArtistLength = 1024;
constexpr size_t kMaxTitleLength = 1024;
constexpr size_t kMaxAlbumLength = 1024;

/// Calculate required playback time for a track to be scrobbled
inline double requiredPlaytime(double duration) {
    return std::min(duration * kScrobblePercentage, kMaxRequiredPlaytime);
}

/// Check if a track is eligible for scrobbling based on duration and played time
inline bool isEligibleForScrobble(double duration, double playedTime) {
    if (duration < kMinTrackLength) return false;
    if (duration > kMaxTrackLength) return false;
    return playedTime >= requiredPlaytime(duration);
}

/// Check if enough time has passed to send Now Playing
inline bool isEligibleForNowPlaying(double playedTime) {
    return playedTime >= kNowPlayingThreshold;
}

/// Validate timestamp is within reasonable bounds
inline bool isValidTimestamp(int64_t timestamp) {
    int64_t now = static_cast<int64_t>(time(nullptr));
    // Allow 60 seconds into future (clock skew), not before Last.fm existed
    return timestamp >= kLastFmEpoch && timestamp <= now + 60;
}

/// Check if track is long enough to be scrobbled
inline bool isTrackLongEnough(double duration) {
    return duration >= kMinTrackLength && duration <= kMaxTrackLength;
}

/// Alias for isEligibleForScrobble
inline bool canScrobble(double duration, double playedTime) {
    return isEligibleForScrobble(duration, playedTime);
}

} // namespace ScrobbleRules
