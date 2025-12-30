#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <optional>
#include <chrono>
#include "CloudErrors.h"
#include "URLUtils.h"

namespace cloud_streamer {

// Cached stream URL entry
struct StreamCacheEntry {
    std::string streamURL;
    std::chrono::steady_clock::time_point expiresAt;
    CloudService service;

    bool isExpired() const {
        return std::chrono::steady_clock::now() >= expiresAt;
    }

    // Time remaining in seconds
    int64_t timeRemaining() const {
        auto now = std::chrono::steady_clock::now();
        if (now >= expiresAt) return 0;
        return std::chrono::duration_cast<std::chrono::seconds>(expiresAt - now).count();
    }
};

// Thread-safe in-memory cache for resolved stream URLs
// Uses dispatch_queue for serialization
class StreamCache {
public:
    static StreamCache& shared();

    // TTL values in seconds
    static constexpr int kMixcloudTTL = 4 * 60 * 60;      // 4 hours
    static constexpr int kSoundCloudTTL = 2 * 60 * 60;    // 2 hours
    static constexpr int kDefaultTTL = 1 * 60 * 60;       // 1 hour fallback

    // Cache operations (all thread-safe)

    // Get cached stream URL for internal URL (e.g., "mixcloud://user/track")
    // Returns nullopt if not cached or expired
    std::optional<StreamCacheEntry> get(const std::string& internalURL);

    // Store stream URL with automatic TTL based on service
    void set(const std::string& internalURL,
             const std::string& streamURL,
             CloudService service);

    // Store with custom TTL (seconds)
    void setWithTTL(const std::string& internalURL,
                    const std::string& streamURL,
                    CloudService service,
                    int ttlSeconds);

    // Remove specific entry
    void remove(const std::string& internalURL);

    // Clear all entries
    void clear();

    // Invalidate expired entries (called periodically)
    void purgeExpired();

    // Statistics
    size_t size();
    size_t expiredCount();

    // Shutdown - must be called before app exit
    void shutdown();

private:
    StreamCache();
    ~StreamCache();

    // Non-copyable
    StreamCache(const StreamCache&) = delete;
    StreamCache& operator=(const StreamCache&) = delete;

    // Get TTL for service type
    int getTTLForService(CloudService service);

    // Internal implementation
    dispatch_queue_t m_queue;
    NSMutableDictionary<NSString*, id>* m_cache;
    bool m_shutdown;
};

} // namespace cloud_streamer
