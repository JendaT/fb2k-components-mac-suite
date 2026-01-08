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

namespace tidal {

/// Thread-safe in-memory cache for resolved stream URLs
class StreamCache {
public:
    static StreamCache& shared();

    /// Get cached playback info for a track
    /// Returns nullptr if not cached or expired
    JLTidalPlaybackInfo* get(const std::string& trackID);

    /// Store playback info with default TTL
    void set(const std::string& trackID, JLTidalPlaybackInfo* info);

    /// Store with custom TTL (seconds)
    void setWithTTL(const std::string& trackID, JLTidalPlaybackInfo* info, int ttlSeconds);

    /// Remove specific entry
    void remove(const std::string& trackID);

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
    bool m_shutdown;
};

} // namespace tidal
