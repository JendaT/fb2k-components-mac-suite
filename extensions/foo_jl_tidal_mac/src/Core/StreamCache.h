//
//  StreamCache.h
//  foo_jl_tidal_mac
//
//  Thread-safe TTL cache for resolved stream URLs
//

#pragma once

#import <Foundation/Foundation.h>
#import "TidalModels.h"
#include <string>
#include <optional>
#include <atomic>

namespace tidal {

/// Thread-safe in-memory cache for resolved stream URLs
class StreamCache {
public:
    static StreamCache& shared();

    // Entries are keyed by track AND requested quality: the same track can sit
    // in a playlist twice with different "?q=" pins, and those resolve to
    // different CDN URLs. A track-only key would serve one pin's stream for
    // the other.

    /// Get cached playback info for a track at a requested quality
    /// Returns nullptr if not cached or expired
    JLTidalPlaybackInfo* get(const std::string& trackID, JLTidalQuality quality);

    /// Store playback info with default TTL
    void set(const std::string& trackID, JLTidalQuality quality, JLTidalPlaybackInfo* info);

    /// Store with custom TTL (seconds)
    void setWithTTL(const std::string& trackID, JLTidalQuality quality,
                    JLTidalPlaybackInfo* info, int ttlSeconds);

    /// Remove every cached quality for a track (used when a stream URL expires:
    /// the whole track needs re-resolving, whichever pin asked for it).
    void removeTrack(const std::string& trackID);

    /// Clear all entries
    void clear();

    /// Invalidate expired entries
    void purgeExpired();

    /// Statistics
    size_t size();

    /// Shutdown - must be called before app exit
    void shutdown();

private:
    StreamCache();
    ~StreamCache();

    // Non-copyable
    StreamCache(const StreamCache&) = delete;
    StreamCache& operator=(const StreamCache&) = delete;

    dispatch_queue_t m_queue;
    NSMutableDictionary<NSString*, JLTidalStreamCacheEntry*>* m_cache;
    std::atomic<bool> m_shutdown;
};

} // namespace tidal
