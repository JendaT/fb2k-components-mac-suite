#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <optional>
#include "TrackInfo.h"

namespace cloud_streamer {

// Thread-safe persistent cache for track metadata
// Stores to JSON file in Application Support directory
class MetadataCache {
public:
    static MetadataCache& shared();

    // Current cache format version (increment on schema changes)
    static constexpr int kCacheVersion = 1;

    // Maximum entries before pruning old entries
    static constexpr size_t kMaxEntries = 5000;

    // Cache operations (all thread-safe)

    // Get cached metadata for internal URL
    std::optional<TrackInfo> get(const std::string& internalURL);

    // Store metadata
    void set(const std::string& internalURL, const TrackInfo& info);

    // Remove specific entry
    void remove(const std::string& internalURL);

    // Clear all entries
    void clear();

    // Statistics
    size_t size();

    // Disk usage in bytes
    uint64_t diskUsage();

    // Force save to disk (normally done automatically)
    void flush();

    // Initialize cache (loads from disk)
    void initialize();

    // Shutdown - saves to disk
    void shutdown();

private:
    MetadataCache();
    ~MetadataCache();

    // Non-copyable
    MetadataCache(const MetadataCache&) = delete;
    MetadataCache& operator=(const MetadataCache&) = delete;

    // Get cache file path
    NSString* getCacheFilePath();

    // Load cache from disk
    void loadFromDisk();

    // Save cache to disk
    void saveToDisk();

    // Schedule deferred save (coalesces multiple writes)
    void scheduleSave();

    // Prune old entries if over limit
    void pruneIfNeeded();

    // Migrate from older cache versions
    void migrateIfNeeded(NSDictionary* loadedData);

    // Convert TrackInfo to/from NSDictionary
    NSDictionary* trackInfoToDict(const TrackInfo& info);
    TrackInfo dictToTrackInfo(NSDictionary* dict);

    // Internal state
    dispatch_queue_t m_queue;
    NSMutableDictionary<NSString*, NSDictionary*>* m_cache;
    bool m_dirty;
    bool m_saveScheduled;
    bool m_shutdown;
    bool m_initialized;
};

} // namespace cloud_streamer
