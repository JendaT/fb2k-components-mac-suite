#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <optional>
#include <functional>
#include <atomic>
#include "../Core/CloudErrors.h"
#include "../Core/TrackInfo.h"

namespace cloud_streamer {

// Result of stream resolution
struct ResolveResult {
    bool success;
    JLCloudError error;
    std::string errorMessage;
    std::string streamURL;
    std::optional<TrackInfo> trackInfo;
};

// Callback for async resolution
using ResolveCallback = std::function<void(const ResolveResult&)>;

// Stream URL resolver - coordinates caching and yt-dlp extraction
class StreamResolver {
public:
    static StreamResolver& shared();

    // Resolve stream URL for internal URL (e.g., "mixcloud://user/track")
    // Checks cache first, then falls back to yt-dlp extraction
    // abortFlag can be used to cancel long-running operations
    ResolveResult resolve(const std::string& internalURL,
                          std::atomic<bool>* abortFlag = nullptr);

    // Async version - callback is called on main thread
    void resolveAsync(const std::string& internalURL,
                      ResolveCallback callback,
                      std::atomic<bool>* abortFlag = nullptr);

    // Resolve bypassing cache (for 403 retry)
    ResolveResult resolveBypassCache(const std::string& internalURL,
                                     std::atomic<bool>* abortFlag = nullptr);

    // Prefetch stream URL and metadata in background
    // Does not block, results are cached for later use
    void prefetch(const std::string& internalURL);

    // Cancel all pending prefetch operations
    void cancelPrefetch();

    // Get metadata only (uses cache, triggers fetch if not cached)
    std::optional<TrackInfo> getMetadata(const std::string& internalURL,
                                         std::atomic<bool>* abortFlag = nullptr);

    // Check if a URL is currently being resolved
    bool isResolving(const std::string& internalURL);

    // Initialize resolver
    void initialize();

    // Shutdown resolver
    void shutdown();

private:
    StreamResolver();
    ~StreamResolver();

    // Non-copyable
    StreamResolver(const StreamResolver&) = delete;
    StreamResolver& operator=(const StreamResolver&) = delete;

    // Internal resolve implementation
    ResolveResult doResolve(const std::string& internalURL,
                            bool bypassCache,
                            std::atomic<bool>* abortFlag);

    // Get web URL from internal URL
    std::string internalToWebURL(const std::string& internalURL);

    // Track currently resolving URLs
    dispatch_queue_t m_queue;
    NSMutableSet<NSString*>* m_resolvingURLs;
    bool m_shutdown;
    bool m_initialized;
};

} // namespace cloud_streamer
