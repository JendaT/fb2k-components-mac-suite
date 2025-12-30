#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <optional>
#include <functional>

namespace cloud_streamer {

// Result of thumbnail fetch
struct ThumbnailResult {
    bool success;
    std::string filePath;      // Path to cached file on disk
    NSData* imageData;         // Image data (may be nil if only path needed)
    std::string mimeType;      // image/jpeg, image/png, etc.
    std::string errorMessage;
};

// Callback for async thumbnail fetch
using ThumbnailCallback = std::function<void(const ThumbnailResult&)>;

// Thread-safe disk cache for thumbnail images
// Downloads images asynchronously and caches to disk
class ThumbnailCache {
public:
    static ThumbnailCache& shared();

    // Maximum cache size in bytes (100 MB default)
    static constexpr uint64_t kMaxCacheSize = 100 * 1024 * 1024;

    // Maximum age for cached thumbnails (30 days)
    static constexpr int kMaxAgeDays = 30;

    // Cache operations (all thread-safe)

    // Get cached thumbnail path for URL (synchronous, returns immediately)
    // Returns nullopt if not cached
    std::optional<std::string> getCachedPath(const std::string& thumbnailURL);

    // Fetch thumbnail (async, uses cache if available)
    // Callback is called on main thread
    void fetch(const std::string& thumbnailURL, ThumbnailCallback callback);

    // Fetch thumbnail and return raw data (async)
    void fetchData(const std::string& thumbnailURL, ThumbnailCallback callback);

    // Remove cached thumbnail
    void remove(const std::string& thumbnailURL);

    // Clear all cached thumbnails
    void clear();

    // Prune old/excess cache entries
    void prune();

    // Statistics
    size_t entryCount();
    uint64_t diskUsage();

    // Initialize cache
    void initialize();

    // Shutdown
    void shutdown();

private:
    ThumbnailCache();
    ~ThumbnailCache();

    // Non-copyable
    ThumbnailCache(const ThumbnailCache&) = delete;
    ThumbnailCache& operator=(const ThumbnailCache&) = delete;

    // Get cache directory
    NSString* getCacheDirectory();

    // Generate cache file name from URL
    NSString* cacheFileNameForURL(const std::string& url);

    // Get full cache path for URL
    NSString* cachePathForURL(const std::string& url);

    // Download thumbnail from URL
    void downloadThumbnail(const std::string& url,
                           NSString* cachePath,
                           ThumbnailCallback callback,
                           bool returnData);

    // Internal state
    dispatch_queue_t m_queue;
    NSURLSession* m_session;
    NSMutableDictionary<NSString*, NSMutableArray*>* m_pendingCallbacks;
    bool m_shutdown;
    bool m_initialized;
};

} // namespace cloud_streamer
